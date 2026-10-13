/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Defaults
import Security

/// A Notion page the user added manually in Settings.
struct NotionPageEntry: Codable, Defaults.Serializable, Equatable, Identifiable {
    var id: String          // normalized 32-char page ID (no dashes)
    var title: String       // optional user-given label; falls back to the Notion title
}

enum NotionPageID {
    /// Extracts a page ID from a pasted Notion URL or raw ID. Returns nil if none is found.
    static func parse(_ input: String) -> String? {
        let cleaned = input.replacingOccurrences(of: "-", with: "")
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{32}") else { return nil }
        let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
        // Notion URLs end with the page ID, so the last match wins.
        guard let match = matches.last, let range = Range(match.range, in: cleaned) else { return nil }
        return String(cleaned[range]).lowercased()
    }
}

struct NotionPageSnapshot: Identifiable, Equatable {
    let id: String
    var title: String
    var icon: String?
    var lastEdited: Date?
    var url: URL?
    var lines: [String]
}

enum NotionPageResult: Equatable {
    case loading
    case failure(String)
    case success(NotionPageSnapshot)
}

/// Keychain storage for the Notion integration token.
enum NotionTokenStore {
    private static let service = "com.Ebullioscopic.Atoll.Notion"
    private static let account = "notion-integration-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ token: String) -> OSStatus {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    @discardableResult
    static func delete() -> OSStatus {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// Read-only Notion sync: fetches title and a text preview for each configured page.
@MainActor
final class NotionManager: ObservableObject {
    static let shared = NotionManager()

    @Published private(set) var results: [String: NotionPageResult] = [:]
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false

    private let session: URLSession = .shared
    private let apiBase = URL(string: "https://api.notion.com/v1")!
    private let notionVersion = "2022-06-28"
    private let minRefreshInterval: TimeInterval = 30
    private var timer: Timer?

    private init() {}

    var hasToken: Bool { !(NotionTokenStore.read() ?? "").isEmpty }

    /// Refreshes all pages. Non-forced calls are throttled so reopening the notch doesn't spam the API.
    func refreshAll(force: Bool = false) {
        guard Defaults[.enableNotionFeature], !isSyncing else { return }
        if !force, let last = lastSync, Date().timeIntervalSince(last) < minRefreshInterval { return }

        let pages = Defaults[.notionPages]
        guard let token = NotionTokenStore.read(), !token.isEmpty else {
            results = Dictionary(uniqueKeysWithValues: pages.map {
                ($0.id, .failure("Add your Notion integration token in Settings."))
            })
            return
        }

        isSyncing = true
        for page in pages where results[page.id] == nil { results[page.id] = .loading }
        let validIDs = Set(pages.map(\.id))
        results = results.filter { validIDs.contains($0.key) }

        Task {
            await withTaskGroup(of: (String, NotionPageResult).self) { group in
                for page in pages {
                    group.addTask { [self] in
                        (page.id, await self.fetch(pageID: page.id, label: page.title, token: token))
                    }
                }
                for await (id, result) in group { results[id] = result }
            }
            lastSync = Date()
            isSyncing = false
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        let interval = max(60, Defaults[.notionRefreshInterval])
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(force: true) }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Networking

    private func request(_ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        req.timeoutInterval = 15
        return req
    }

    private func fetchJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            switch status {
            case 401: throw NotionError.message("Invalid token.")
            case 404: throw NotionError.message("Page not found — share it with your integration.")
            case 429: throw NotionError.message("Rate limited by Notion. Try again shortly.")
            default: throw NotionError.message("Notion error (\(status)).")
            }
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func fetch(pageID: String, label: String, token: String) async -> NotionPageResult {
        do {
            let page = try await fetchJSON(request("pages/\(pageID)", token: token))
            var children = request("blocks/\(pageID)/children", token: token)
            if var comps = URLComponents(url: children.url!, resolvingAgainstBaseURL: false) {
                comps.queryItems = [URLQueryItem(name: "page_size", value: "25")]
                children.url = comps.url
            }
            let blocks = try await fetchJSON(children)

            let title = Self.pageTitle(page)
            let snapshot = NotionPageSnapshot(
                id: pageID,
                title: label.isEmpty ? (title ?? "Untitled") : label,
                icon: (page["icon"] as? [String: Any]).flatMap { $0["emoji"] as? String },
                lastEdited: (page["last_edited_time"] as? String).flatMap(Self.parseDate),
                url: (page["url"] as? String).flatMap(URL.init(string:)),
                lines: Self.previewLines(blocks)
            )
            return .success(snapshot)
        } catch let NotionError.message(text) {
            return .failure(text)
        } catch {
            return .failure("Couldn't reach Notion.")
        }
    }

    // MARK: - Parsing

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func plainText(_ richText: Any?) -> String {
        (richText as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
    }

    private static func pageTitle(_ page: [String: Any]) -> String? {
        guard let props = page["properties"] as? [String: Any] else { return nil }
        for case let prop as [String: Any] in props.values where prop["type"] as? String == "title" {
            let text = plainText(prop["title"])
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func previewLines(_ blocks: [String: Any]) -> [String] {
        guard let results = blocks["results"] as? [[String: Any]] else { return [] }
        var lines: [String] = []
        for block in results {
            guard let type = block["type"] as? String,
                  let content = block[type] as? [String: Any] else { continue }
            let text = plainText(content["rich_text"])
            guard !text.isEmpty else { continue }
            switch type {
            case "to_do":
                lines.append(((content["checked"] as? Bool) == true ? "☑︎ " : "☐ ") + text)
            case "bulleted_list_item", "numbered_list_item":
                lines.append("• " + text)
            case "heading_1", "heading_2", "heading_3", "paragraph", "quote", "callout", "toggle":
                lines.append(text)
            default:
                continue
            }
        }
        return lines
    }
}

private enum NotionError: Error {
    case message(String)
}

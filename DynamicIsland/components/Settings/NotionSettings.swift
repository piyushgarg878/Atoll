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


import SwiftUI
import Defaults

struct NotionSettings: View {
    @ObservedObject private var manager = NotionManager.shared
    @Default(.enableNotionFeature) private var enableNotionFeature
    @Default(.notionPages) private var pages
    @Default(.notionRefreshInterval) private var refreshInterval

    @State private var tokenInput = ""
    @State private var hasToken = NotionTokenStore.read()?.isEmpty == false
    @State private var newPageInput = ""
    @State private var newPageLabel = ""
    @State private var addError: String?

    private func highlightID(_ title: String) -> String {
        SettingsTab.notion.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableNotionFeature) {
                    Text("Enable Notion tab")
                }
                .settingsHighlight(id: highlightID("Enable Notion tab"))
                .onChange(of: enableNotionFeature) { _, enabled in
                    if enabled {
                        manager.refreshAll(force: true)
                        manager.startAutoRefresh()
                    } else {
                        manager.stopAutoRefresh()
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Adds a read-only Notion tab to the notch showing a preview of the pages you add below.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if enableNotionFeature {
                Section {
                    if hasToken {
                        HStack {
                            Label("Token saved in Keychain", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                NotionTokenStore.delete()
                                hasToken = false
                                manager.refreshAll(force: true)
                            }
                        }
                    } else {
                        SecureField("Internal integration token (secret_… / ntn_…)", text: $tokenInput)
                        Button("Save token") {
                            let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            NotionTokenStore.write(trimmed)
                            tokenInput = ""
                            hasToken = true
                            manager.refreshAll(force: true)
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Integration")
                } footer: {
                    Text("Create an internal integration at notion.so/my-integrations, then open each page in Notion → ••• → Connections and add your integration so it can read the page.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Section {
                    ForEach(pages) { page in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: page))
                                Text(page.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                pages.removeAll { $0.id == page.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    TextField("Page URL or ID", text: $newPageInput)
                    TextField("Label (optional)", text: $newPageLabel)
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                    }
                    Button("Add page") { addPage() }
                        .disabled(newPageInput.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Pages")
                }

                Section {
                    Picker("Auto-refresh", selection: $refreshInterval) {
                        Text("Every minute").tag(60.0)
                        Text("Every 5 minutes").tag(300.0)
                        Text("Every 15 minutes").tag(900.0)
                        Text("Every hour").tag(3600.0)
                    }
                    .onChange(of: refreshInterval) { _, _ in manager.startAutoRefresh() }

                    HStack {
                        Button("Sync now") { manager.refreshAll(force: true) }
                            .disabled(manager.isSyncing)
                        if manager.isSyncing { ProgressView().controlSize(.small) }
                        Spacer()
                        if let last = manager.lastSync {
                            Text("Last sync \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sync")
                }
            }
        }
        .onAppear {
            if enableNotionFeature { manager.startAutoRefresh() }
        }
    }

    private func displayName(for page: NotionPageEntry) -> String {
        if !page.title.isEmpty { return page.title }
        if case .success(let snap) = manager.results[page.id] { return snap.title }
        return "Notion page"
    }

    private func addPage() {
        guard let id = NotionPageID.parse(newPageInput) else {
            addError = "Couldn't find a Notion page ID in that link."
            return
        }
        guard !pages.contains(where: { $0.id == id }) else {
            addError = "That page is already added."
            return
        }
        pages.append(NotionPageEntry(id: id, title: newPageLabel.trimmingCharacters(in: .whitespaces)))
        newPageInput = ""
        newPageLabel = ""
        addError = nil
        manager.refreshAll(force: true)
    }
}

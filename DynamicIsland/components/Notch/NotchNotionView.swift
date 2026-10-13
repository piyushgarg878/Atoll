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
import AppKit

struct NotchNotionView: View {
    @ObservedObject private var manager = NotionManager.shared
    @Default(.notionPages) private var pages

    var body: some View {
        Group {
            if pages.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(pages) { page in
                            card(for: page)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topTrailing) { syncButton }
        .onAppear {
            manager.refreshAll()
            manager.startAutoRefresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Notion pages yet")
                .font(.headline)
            Text("Add your token and pages in Settings → Notion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var syncButton: some View {
        Button {
            manager.refreshAll(force: true)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .rotationEffect(.degrees(manager.isSyncing ? 180 : 0))
                .animation(.easeInOut(duration: 0.4), value: manager.isSyncing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(6)
        .help("Sync with Notion")
    }

    @ViewBuilder
    private func card(for entry: NotionPageEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch manager.results[entry.id] ?? .loading {
            case .loading:
                Text(entry.title.isEmpty ? "Loading…" : entry.title).font(.headline).lineLimit(1)
                ProgressView().controlSize(.small)
            case .failure(let reason):
                Text(entry.title.isEmpty ? "Notion page" : entry.title).font(.headline).lineLimit(1)
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            case .success(let snap):
                HStack(spacing: 6) {
                    if let icon = snap.icon { Text(icon) }
                    Text(snap.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let url = snap.url {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open in Notion")
                    }
                }
                if let edited = snap.lastEdited {
                    Text("Edited \(edited.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if snap.lines.isEmpty {
                    Text("No text content").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(snap.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

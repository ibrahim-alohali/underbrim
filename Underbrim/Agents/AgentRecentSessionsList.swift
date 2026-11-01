//
//  AgentRecentSessionsList.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  An agent's previous sessions, to open again from its chip.
//

import SwiftUI

struct RecentSessionsList: View {
    let provider: AgentProvider
    let sessions: [RecentAgentSession]?

    var body: some View {
        if let sessions, sessions.isEmpty {
            Text("No previous sessions")
                .font(.notchBody)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: AgentsTabContent.lineHeight)
        } else if let sessions {
            let natural = CGFloat(sessions.count) * AgentsTabContent.lineHeight
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(sessions) { RecentSessionLine(session: $0).frame(height: AgentsTabContent.lineHeight) }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(natural, AgentsTabContent.listCap))
            .modifier(ListEdgeFade(overflows: natural > AgentsTabContent.listCap))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Previous sessions"))
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: AgentsTabContent.lineHeight)
        }
    }
}

private struct RecentSessionLine: View {
    let session: RecentAgentSession
    @State private var hovering = false

    private var folderName: String? { session.folder.map { ($0 as NSString).lastPathComponent } }
    private var opensIn: String {
        String(localized: "Opens this session in \(session.provider.appName)")
    }

    var body: some View {
        Button {
            if let link = session.link { AgentOpener.open(link, with: session.provider) }
        } label: {
            HStack(spacing: 6) {
                AppIconView(bundleID: session.provider.defaultHostBundleID, size: 14)
                Text(session.title)
                    .font(.notchBody.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let folderName {
                    Text(folderName)
                        .font(.notchCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                RelativeTimeText(date: session.lastActive)
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(opensIn)
        .accessibilityLabel(Text(verbatim: [session.title, folderName].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(RelativeTimeText.string(for: session.lastActive, now: .now)))
        .accessibilityHint(opensIn)
        .background(hovering ? Color.notchRowHoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            if let folder = session.folder {
                if AgentOpener.hasApp(session.provider) {
                    Button(String(localized: "New Session in This Folder")) {
                        AgentOpener.startNewSession(session.provider, folder: folder)
                    }
                }
                Button(String(localized: "Show in Finder")) { AgentOpener.showInFinder(path: folder) }
            }
        }
    }
}

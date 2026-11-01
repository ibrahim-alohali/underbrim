//
//  AgentsIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Coding Agents: sessions in the notch, on or off.
//

import Defaults
import SwiftUI

struct AgentsIsland: View {
    private let store = AgentSessionStore.shared
    @Default(.showAgentActivity) private var on

    var body: some View {
        IslandSwitch(name: String(localized: "Show coding sessions in the notch"), isOn: $on) {
            if !on {
                IslandRow(symbol: "terminal.fill", title: SettingsTab.agents.title, dim: true)
            } else if let summary = store.closedSummary, summary.waitsOnUser {
                // A request waits first, as on the closed notch, even from a session not listed.
                // Here and below, the state gets its room first and the agent's name what's left.
                HStack(spacing: 7) {
                    IslandGlyph(symbol: "terminal.fill")
                    Text(summary.provider.displayName).islandText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(summary.words)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.onNotchAccent)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.notchAccent))
                        .layoutPriority(1)
                }
                .islandShown(summary.provider.displayName, summary.words)
            } else if let session = store.spotlight {
                let status = AgentStatusStyle.of(session, quiet: store.quietSessionIDs.contains(session.id))
                HStack(spacing: 7) {
                    IslandGlyph(symbol: "terminal.fill")
                    Text(session.provider.displayName).islandText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.needsAttention {
                        Text(status.text)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.onNotchAccent)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.notchAccent))
                            .layoutPriority(1)
                    } else {
                        Text(status.text).islandText(dim: true).layoutPriority(1)
                    }
                }
                .islandShown(session.provider.displayName, status.text)
            } else if store.visibleSessions.isEmpty {
                IslandRow(symbol: "terminal.fill", title: String(localized: "No coding sessions right now"))
            } else {
                IslandRow(symbol: "terminal.fill", title: SettingsTab.agents.title)
            }
        }
    }
}

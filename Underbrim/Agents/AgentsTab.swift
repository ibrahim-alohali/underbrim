//
//  AgentsTab.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The expanded Agents tab: its sessions in groups, or what it's for when there are none.
//

import Defaults
import SwiftUI

struct AgentsTabView: View {
    var compact = false
    private let store = AgentSessionStore.shared
    private let usage = AgentUsageStore.shared
    private let roster = AgentRoster.shared

    private let requests = AgentRequestStore.shared

    var body: some View {
        // An agent waiting on an answer comes first until it has one; the sessions stay under it.
        if !requests.requests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                AgentRequestsRow(requests: requests.requests)
                let sessions = store.visibleSessions
                if !sessions.isEmpty {
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                    AgentSessionList(sessions: sessions, quiet: store.quietSessionIDs, asking: AgentAsks.shared.askingSessions,
                                     namesGroups: !compact,
                                     cap: AgentsTabContent.lineHeight * 3)
                }
            }
        } else {
            AgentsTabContent(sessions: store.visibleSessions, quiet: store.quietSessionIDs, asking: AgentAsks.shared.askingSessions,
                             usage: usage, followed: roster.followed, showsUsage: !compact)
                .onAppear {
                    usage.refreshCodex(userInitiated: false)
                    roster.refresh()
                }
        }
    }
}

/// The tab from plain values: the sessions one to a line under what they need from you, and along
/// the bottom the agents this Mac has. An agent's click shows its previous sessions (or token
/// history) in the list's place; another goes back.
struct AgentsTabContent: View {
    let sessions: [AgentSession]
    let quiet: Set<String>
    /// Sessions whose question under a reply waits on the user.
    var asking: Set<String> = []
    let usage: AgentUsageStore
    /// The agents followed through their hooks that have them on (AgentRoster).
    var followed: Set<AgentProvider> = []
    var showsUsage = true
    /// The app whose previous sessions show instead of the running ones.
    @State private var recentOf: AgentProvider?
    @State private var recent: [RecentAgentSession]?
    @State private var historyOf: AgentProvider?

    static let lineHeight: CGFloat = 28
    /// The list grows to this, about six lines, then scrolls: the island stays clear of the screen's middle.
    static let listCap: CGFloat = 170

    /// The agents this Mac has: Claude and Codex with their app here or their usage on, the others with
    /// their hooks on, and any with a session showing.
    private var agents: [AgentProvider] {
        AgentProvider.allCases.filter { provider in
            if sessions.contains(where: { $0.provider == provider }) { return true }
            return provider.readsFiles ? usage.state(for: provider) != .off || AgentOpener.hasApp(provider)
                                       : followed.contains(provider)
        }
    }

    /// Where each agent's newest session runs (the store keeps the newest first).
    private var hosts: [AgentProvider: String] {
        Dictionary(sessions.compactMap { session in session.hostBundleID.map { (session.provider, $0) } },
                   uniquingKeysWith: { newest, _ in newest })
    }

    var body: some View {
        let agents = agents
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let historyOf {
                    TokenHistoryRow(provider: historyOf)
                        .frame(height: NotchMetrics.tabHeight)
                } else if let recentOf {
                    RecentSessionsList(provider: recentOf, sessions: recent)
                } else if agents.isEmpty {
                    AgentSetupRow()
                } else {
                    AgentSessionList(sessions: sessions, quiet: quiet, asking: asking, namesGroups: showsUsage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !agents.isEmpty {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    AgentStrip(agents: agents, showsChips: showsUsage, hosts: hosts, usage: usage,
                               now: context.date, selected: recentOf ?? historyOf,
                               showRecent: showRecent, showHistory: showHistory)
                }
            }
        }
        // A session that comes to ask for something brings the running ones back.
        .onChange(of: sessions.filter(\.needsAttention).map(\.id)) { before, now in
            if recentOf != nil || historyOf != nil, !Set(now).isSubset(of: before) {
                withAnimation(StandardAnimations.open) { recentOf = nil; historyOf = nil }
            }
        }
    }

    private func showHistory(of provider: AgentProvider) {
        withAnimation(StandardAnimations.open) {
            recentOf = nil
            historyOf = historyOf == provider ? nil : provider
        }
    }

    /// The chip's click: that app's previous sessions, or back. Without the app, its usage page
    /// on the web; Claude's sessions need its app's link, so with that off the app comes forward.
    private func showRecent(of provider: AgentProvider) {
        // Over token history its own chip goes back; another chip shows that app's sessions.
        if let shown = historyOf {
            withAnimation(StandardAnimations.open) { historyOf = nil }
            if shown == provider { return }
        }
        guard AgentOpener.hasApp(provider) else {
            if let page = provider.usagePage { AgentOpener.open(page, with: provider) }
            return
        }
        if provider == .claude, !Defaults[.useClaudeDesktopSessionLinks] {
            return AppInfo.activate(provider.defaultHostBundleID)
        }
        if recentOf == provider {
            withAnimation(StandardAnimations.open) { recentOf = nil }
            return
        }
        let running = Set(sessions.filter { $0.provider == provider }.compactMap(\.appSessionID))
        recent = nil
        withAnimation(StandardAnimations.open) { recentOf = provider }
        Task {
            let found = await AgentRecentSessions.load(provider, excluding: running)
            // Still that app's (another click may have moved on meanwhile).
            if recentOf == provider { withAnimation(StandardAnimations.open) { recent = found } }
        }
    }
}

/// What a session needs from you, for the list's groups. A working session gone quiet is idle, as on
/// the closed notch: nothing says it's still at work. One whose question under a reply waits (`asking`)
/// needs you, as the closed notch says.
enum AgentSessionGroup: Int, CaseIterable, Hashable {
    case needsYou, working, idle

    init(_ session: AgentSession, quiet: Bool, asking: Bool = false) {
        self = session.needsAttention || asking ? .needsYou : session.phase == .working && !quiet ? .working : .idle
    }

    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .idle: String(localized: "Idle")
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .working: "ellipsis.circle"
        case .idle: "pause.circle"
        }
    }

    var tint: Color { self == .needsYou ? .orange : .secondary }
}

struct AgentEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No coding sessions right now")
                .font(.notchBody)
                .foregroundStyle(.white)
            Text("Coding sessions on this Mac appear here while they run.")
                .font(.notchCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }
}

/// No agent on this Mac: what the tab is for, and the way to set one up.
struct AgentSetupRow: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No coding agents set up")
                    .font(.notchBody)
                    .foregroundStyle(.white)
                Text("Sessions from Claude Code, Codex, Cursor, Antigravity, Qwen Code and Qoder show here while they run.")
                    .font(.notchCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            NotchTextButton(title: String(localized: "Set Up Coding Agents…")) {
                SettingsWindowController.shared.showWindow(tab: .agents)
            }
        }
        .padding(.horizontal, 8)
    }
}

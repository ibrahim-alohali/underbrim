//
//  AgentStrip.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Along the bottom of the Agents tab: a chip per agent, and a menu to start a session.
//

import SwiftUI

/// How much a chip says: the strip gives up the usage window's name, then the apps' names, before
/// any chip would be cut.
enum AgentChipDetail: CaseIterable {
    case full, short, compact
}

/// Along the bottom of the tab: the agents this Mac has (in compact mode, none), and a menu to start
/// a session.
struct AgentStrip: View {
    let agents: [AgentProvider]
    let showsChips: Bool
    let hosts: [AgentProvider: String]
    let usage: AgentUsageStore
    let now: Date
    let selected: AgentProvider?
    let showRecent: (AgentProvider) -> Void
    let showHistory: (AgentProvider) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsChips {
                ViewThatFits(in: .horizontal) {
                    chips(.full)
                    chips(.short)
                    chips(.compact)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Coding Agents"))
            } else {
                Spacer(minLength: 0)
            }
            NewSessionMenu(agents: agents)
        }
        .frame(height: 24)
    }

    private func chips(_ detail: AgentChipDetail) -> some View {
        HStack(spacing: 4) {
            ForEach(agents, id: \.self) { provider in
                if provider.readsFiles {
                    AgentUsageChip(provider: provider, state: usage.state(for: provider), detail: detail, now: now,
                                   showingRecent: selected == provider, showHistory: { showHistory(provider) }) {
                        showRecent(provider)
                    }
                } else {
                    // A terminal's icon says nothing of the agent in it, so those keep their names.
                    AgentAppChip(provider: provider, host: hosts[provider],
                                 showsName: detail != .compact || !provider.runsInOwnApp)
                }
            }
        }
        .fixedSize()
    }
}

/// New sessions in the apps that take a link for one, the apps that start their own, and the way
/// to set up more.
private struct NewSessionMenu: View {
    let agents: [AgentProvider]

    var body: some View {
        let starts = agents.filter(AgentOpener.hasApp).compactMap { provider in
            provider.newSessionTitle.map { (provider: provider, title: $0) }
        }
        // The apps that start their own sessions.
        let apps = agents.filter { $0.runsInOwnApp && $0.newSessionTitle == nil && AgentOpener.hasApp($0) }
        Menu {
            ForEach(starts, id: \.provider) { start in
                Button(start.title) { AgentOpener.startNewSession(start.provider) }
            }
            ForEach(apps, id: \.self) { provider in
                Button(String(localized: "Open \(provider.displayName)")) { AppInfo.activate(provider.defaultHostBundleID) }
            }
            if !starts.isEmpty || !apps.isEmpty { Divider() }
            Button(String(localized: "Set Up Coding Agents…")) { SettingsWindowController.shared.showWindow(tab: .agents) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.notchSymbol(size: 10))
                Text("New Session")
                Image(systemName: "chevron.down")
                    .font(.notchSymbol(size: 8))
            }
            .font(.notchCaption)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(.notchRowFill, in: Capsule())
            .contentShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("New Session"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// An agent with no usage to show: a click brings its app forward; for one that runs in a terminal,
/// the terminal its newest session runs in.
private struct AgentAppChip: View {
    let provider: AgentProvider
    /// Where its newest session runs, if one shows.
    let host: String?
    var showsName = true
    @State private var hovering = false

    private var app: String { host ?? provider.defaultHostBundleID }
    private var opens: String {
        String(localized: "Open \(AppInfo.name(bundleID: app) ?? provider.displayName)")
    }

    var body: some View {
        Button {
            AppInfo.activate(app)
        } label: {
            HStack(spacing: 5) {
                AppIconView(bundleID: app, size: 14)
                if showsName {
                    Text(provider.displayName).foregroundStyle(.secondary)
                }
            }
            .font(.notchCaption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(opens)
        .accessibilityLabel(Text(provider.displayName))
        .accessibilityHint(opens)
        .background(hovering ? Color.notchRowHoverFill : .clear, in: Capsule())
        .onHover { hovering = $0 }
    }
}

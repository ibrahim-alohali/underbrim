//
//  AgentUsageChip.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Claude's and Codex's chip in the Agents tab: plan usage, and their previous sessions.
//

import Defaults
import SwiftUI

/// Claude's or Codex's chip: the usage window nearest its limit (every window is in its help and in
/// what VoiceOver says). A click shows its previous sessions; the rest is in its menu.
struct AgentUsageChip: View {
    let provider: AgentProvider
    let state: AgentUsageStore.State
    var detail = AgentChipDetail.full
    let now: Date
    var showingRecent = false
    var showHistory: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.islandPointerWatch) private var islandPointer
    @Default(.useClaudeDesktopSessionLinks) private var directLinks

    private var name: String { provider.appName }
    private var page: URL? { provider.usagePage }
    private var pageTitle: String {
        page?.scheme == "codex" ? String(localized: "Codex Settings") : String(localized: "\(name) Usage Page")
    }
    private var newSessionName: String? { provider.newSessionTitle }
    private var actionName: String {
        if !AgentOpener.hasApp(provider) { return String(localized: "Opens \(pageTitle)") }
        if provider == .claude, !directLinks { return String(localized: "Open \(name)") }
        return String(localized: "Previous sessions")
    }
    /// Codex is asked on demand (debounced in the store); Claude's reading is
    /// whatever the Claude app last saved, which its usage page refreshes.
    private var refresh: (() -> Void)? {
        provider == .codex && state != .off ? { AgentUsageStore.shared.refreshCodex(userInitiated: true) } : nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                AppIconView(bundleID: provider.defaultHostBundleID, size: 14)
                if detail != .compact {
                    Text(name).foregroundStyle(.white)
                }
                summary
            }
            .font(.notchCaption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(actionName)
        .accessibilityAddTraits(showingRecent ? .isSelected : [])
        .accessibilityActions {
            if AgentOpener.hasApp(provider), let newSessionName { Button(newSessionName) { AgentOpener.startNewSession(provider) } }
            if let page { Button(String(localized: "Open \(pageTitle)")) { AgentOpener.open(page, with: provider) } }
            if let refresh { Button(String(localized: "Refresh \(name) usage"), action: refresh) }
            if let showHistory { Button(String(localized: "Token History"), action: showHistory) }
        }
        .background(hovering || showingRecent ? Color.notchRowHoverFill : .clear, in: Capsule())
        // Its sessions show: ringed as well as lit, so it doesn't rest on the shade alone.
        .overlay {
            if showingRecent {
                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if AgentOpener.hasApp(provider) {
                Button(String(localized: "Open \(name)")) { AppInfo.activate(provider.defaultHostBundleID) }
                if let newSessionName { Button(newSessionName) { AgentOpener.startNewSession(provider) } }
                Divider()
            }
            if let page { Button(String(localized: "Open \(pageTitle)")) { AgentOpener.open(page, with: provider) } }
            if let refresh { Button(String(localized: "Refresh"), action: refresh) }
            if let showHistory {
                Divider()
                // Its page shows in the island, which the item lies outside of: the island stays open for it.
                Button(String(localized: "Token History")) {
                    islandPointer?.holdAfterMenu()
                    showHistory()
                }
            }
        }
    }

    /// The window nearest its limit, orange from 90 %, and a clock once the reading is stale.
    @ViewBuilder private var summary: some View {
        switch state {
        case .off:
            if detail == .full { Text("Usage off").foregroundStyle(.secondary) }
        case .loading:
            ProgressView().controlSize(.mini)
        case .failed(_, .none):
            Image(systemName: "exclamationmark.circle")
                .font(.notchSymbol(size: 10))
                .foregroundStyle(.secondary)
        case .loaded, .failed:
            if let top = readings.max(by: { $0.used < $1.used }) {
                HStack(spacing: 4) {
                    if detail == .full { Text(top.label).foregroundStyle(.secondary) }
                    UsageMeter(used: top.used)
                    figure(top.used)
                }
            }
            if stale {
                Image(systemName: "clock")
                    .font(.notchSymbol(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var readings: [(label: String, used: Double)] {
        (state.snapshot?.windows ?? []).compactMap { window in usedPercent(window).map { (label: window.label, used: $0) } }
    }

    private var stale: Bool {
        state.snapshot.map { now.timeIntervalSince($0.fetchedAt) > $0.staleAfter } ?? false
    }

    private func figure(_ used: Double) -> Text {
        Text((used.rounded() / 100).formatted(.percent))
            .foregroundStyle(used >= 90 ? .orange : .white)
            .monospacedDigit()
    }

    /// A reading from before the window reset says nothing about now.
    private func usedPercent(_ window: AgentUsageStore.Window) -> Double? {
        if let end = window.resetsAt ?? window.expiresAt, end <= now { return nil }
        return window.usedPercent
    }

    /// What a click does, then the reading, or why there's none (the chip shows only a mark for that).
    private var help: String {
        if state.snapshot != nil { return actionName + "\n" + helpText }
        if case .failed(let message, _) = state { return actionName + "\n" + message }
        return actionName
    }

    /// Every window and the reading's age (the chip shows one window), then the plan, source and resets.
    private var helpText: String {
        guard let snapshot = state.snapshot else { return name }
        let resets = snapshot.windows.compactMap { window in
            window.resetsAt.flatMap { $0 > now ? String(localized: "\(window.label) resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") : nil }
        }
        return accessibilityText + "\n" + ([snapshot.plan, snapshot.source].compactMap { $0 } + resets).joined(separator: " · ")
    }

    private var accessibilityText: String {
        guard let snapshot = state.snapshot else {
            if case .failed(let message, _) = state { return String(localized: "\(name) usage: \(message)") }
            if state == .off { return name + ", " + String(localized: "Usage off") }
            return String(localized: "\(name) usage")
        }
        let windows = snapshot.windows.map { window in
            usedPercent(window).map { String(localized: "\(window.label) \(Int($0.rounded()))% used") }
                ?? String(localized: "\(window.label) no current reading")
        }
        let age = RelativeTimeText.string(for: snapshot.fetchedAt, now: now)
        let stale = now.timeIntervalSince(snapshot.fetchedAt) > snapshot.staleAfter
        let readings = windows.joined(separator: ", ") + ", "
            + (stale ? String(localized: "stale, updated \(age)") : String(localized: "updated \(age)"))
        return String(localized: "\(name) usage: \(readings)")
    }
}

/// A usage window's share used, as a short bar (from the leading edge, so it fills from the
/// right in Arabic, as progress does).
private struct UsageMeter: View {
    let used: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
            Capsule().fill(used >= 90 ? Color.orange : .white)
                .frame(width: 30 * min(max(used, 0), 100) / 100)
        }
        .frame(width: 30, height: 4)
        .accessibilityHidden(true)
    }
}

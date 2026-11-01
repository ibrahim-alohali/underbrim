//
//  AnsweringOffer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Answering Claude Code in the notch, offered where the island shows something only its hook can
//  bring here (an approval, a plan, a question in Terminal): the same hook as Settings' switch, written
//  only on Turn On. What is asked already stays where it was asked.
//

import SwiftUI

struct AnsweringOffer: View {
    /// The app the waiting request is in, where it stays.
    let hostName: String
    /// Why Turn On couldn't, kept by the request's view: its own button leads again then.
    @Binding var failure: String?
    let dismiss: () -> Void
    @State private var working = false
    @State private var turnedOn = false
    private var roster: AgentRoster { .shared }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // On here, or in Settings meanwhile.
            if turnedOn || roster.answering?.contains(.claude) == true {
                Label("On. What Claude Code asks from now on shows here.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let failure {
                Label(String(localized: "Couldn't turn it on: \(failure)"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NotchTextButton(title: String(localized: "Open Settings"),
                                help: String(localized: "Turn on answering in the notch in Settings")) {
                    SettingsWindowController.shared.showWindow(tab: .agents)
                }
                .fixedSize()
            } else {
                Text(Self.wholePath(String(localized: "Answer Claude Code in the notch from now on? Underbrim adds one hook to ~/.claude/settings.json. This one stays in \(hostName).")))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "Not Now"), action: dismiss)
                    .buttonStyle(RequestButtonStyle(height: 24))
                    .fixedSize()
                Button(String(localized: "Turn On"), action: turnOn)
                    .buttonStyle(RequestButtonStyle(role: .primary, height: 24))
                    .fixedSize()
                    .notchDisabled(working)
            }
        }
        .font(.notchCaption)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
        // Once the island has read the hooks again, they say whether it's on (also when Settings changes it).
        .onChange(of: roster.answering) { turnedOn = false }
    }

    /// The settings file's path on one line (a line may break after a slash).
    private static func wholePath(_ text: String) -> String {
        text.replacingOccurrences(of: "~/.claude/settings.json", with: "~/\u{2060}.claude/\u{2060}settings.json")
    }

    /// The hook into Claude Code's settings, off the main thread; the island reads it back. As in
    /// Settings, not while the hook couldn't reach this copy.
    private func turnOn() {
        guard !working else { return }
        RelayListener.shared.check()
        if let problem = RelayListener.shared.health?.problem {
            withAnimation(StandardAnimations.open) { failure = problem }
            return
        }
        working = true
        Task {
            let problem = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try HookInstaller(agent: .claude)?.install()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            AgentRoster.shared.refresh()
            withAnimation(StandardAnimations.open) {
                failure = problem
                turnedOn = problem == nil
                working = false
            }
        }
    }
}

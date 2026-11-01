//
//  AgentProvider+App.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  How the app names, opens and sets up each agent: its half of a new agent's entry
//  (the shared half, how it's reached, is AgentSpec).
//

import SwiftUI

extension AgentProvider {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .qwen: "Qwen Code"
        case .qoder: "Qoder"
        }
    }

    /// The name of the app that answers in its place ("Answer in Claude").
    var appName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor, .antigravity, .qwen, .qoder: displayName
        }
    }

    /// The app that normally hosts this agent, for an icon when the files don't name one.
    var defaultHostBundleID: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .antigravity: "com.google.antigravity"
        case .qwen, .qoder: "com.apple.Terminal"
        }
    }

    /// Its sessions run in its own app, which comes forward when nothing more exact is known.
    /// (Claude Code often runs in a terminal; only a session from the Claude app goes there.)
    var runsInOwnApp: Bool {
        switch self {
        case .codex, .cursor, .antigravity: true
        case .claude, .qwen, .qoder: false
        }
    }

    /// The link that opens one session in the agent's app: a Codex thread by its id, a Claude app
    /// session by the app's own id ("local_…"). nil for any other id or agent.
    func sessionLink(id: String) -> URL? {
        switch self {
        case .codex: UUID(uuidString: id) != nil ? URL(string: "codex://threads/\(id)") : nil
        case .claude: Relay.desktopSessionID(id) != nil ? URL(string: "claude://code/continue?session=\(id)") : nil
        case .cursor, .antigravity, .qwen, .qoder: nil
        }
    }

    /// The menu item that starts a session, for the agents whose app takes a link for one.
    var newSessionTitle: String? {
        switch self {
        case .claude: String(localized: "New Claude Code session")
        case .codex: String(localized: "New Codex chat")
        case .cursor, .antigravity, .qwen, .qoder: nil
        }
    }

    /// Where its usage chip leads, in the app if it's here, else the web. Codex links don't reach
    /// Usage & billing, so its Settings, one click away. nil for an agent without plan usage.
    @MainActor var usagePage: URL? {
        switch self {
        case .claude:
            AgentOpener.hasApp(self) ? URL(string: "claude://claude.ai/settings/usage") : URL(string: "https://claude.ai/settings/usage")
        case .codex:
            AgentOpener.hasApp(self) ? URL(string: "codex://settings") : URL(string: "https://chatgpt.com/codex/settings/usage")
        case .cursor, .antigravity, .qwen, .qoder:
            nil
        }
    }

    /// Its rows in Settings › More agents; nil for the agents read from their files.
    var hookAgentRows: HookAgentRows? {
        let handBack = Int(HookInstaller.handBackAfter / 60)
        return switch self {
        case .claude, .codex:
            nil
        case .cursor:
            HookAgentRows(follow: "Follow Cursor",
                          followNote: "Its agent's sessions in the notch, from hooks in ~/.cursor/hooks.json. Cursor asks for approvals in its own window: its hooks can't approve.")
        case .antigravity:
            HookAgentRows(follow: "Follow Antigravity",
                          followNote: "Its sessions in the notch, from a plugin folder of Underbrim's own in ~/.gemini/config/plugins. Antigravity asks for approvals in its own window.")
        case .qwen:
            HookAgentRows(follow: "Follow Qwen Code",
                          followNote: "Its sessions in the notch, from hooks in ~/.qwen/settings.json. New sessions pick them up.",
                          answer: "Answer Qwen Code in the notch",
                          answerNote: "Approvals show in the notch while its terminal isn't in front. Qwen Code waits for your answer there, and asks in the terminal again when you switch to it or after \(handBack) minutes.")
        case .qoder:
            HookAgentRows(follow: "Follow Qoder",
                          followNote: "Its sessions in the notch, from hooks in ~/.qoder/settings.json. Running sessions pick them up.",
                          answer: "Answer Qoder in the notch",
                          answerNote: "Approvals show in the notch while Qoder asks in the terminal too; whichever you answer first counts. Always Allow saves the rule Qoder suggests.")
        }
    }
}

/// An agent's switches in Settings › More agents. Titles are also their search marks.
struct HookAgentRows {
    let follow: String
    let followNote: LocalizedStringKey
    /// The switch that answers its requests in the notch, for an agent whose hook can.
    var answer: String?
    var answerNote: LocalizedStringKey?
}

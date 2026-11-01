//
//  AgentSpec.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Shared by the app and `underbrim-relay`: the coding agents Underbrim follows, and how
//  each one is reached. A new agent is a case and its entry here, its entry in the app's
//  own switch (AgentProvider+App), its creature, its hook events (RelaySanitizer) and its
//  strings; the compiler points at each.
//

import Foundation

/// In the order they're shown.
enum AgentProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case qwen
    case qoder
    case cursor
    case antigravity
}

struct AgentSpec: Sendable {
    enum Source: Sendable {
        /// Its own session files (ClaudeSessionFiles, CodexRollout).
        case files
        /// Hooks Underbrim adds to its settings file.
        case hooks
        /// A plugin folder of Underbrim's own (AntigravityPlugin).
        case plugin
    }

    /// How the agent's settings file holds hooks.
    enum HookLayout: Sendable {
        /// Claude Code's groups of handlers (Qwen Code and Qoder use it too).
        case groups
        /// Groups too, but approvals are keyed by a group's position (Codex), so ours keep their places.
        case pinnedGroups
        /// One handler per entry (Cursor).
        case handlers
    }

    struct HookFile: Sendable {
        /// Under the home folder.
        let path: String
        let layout: HookLayout
    }

    /// The reply its PermissionRequest hook takes.
    enum AnswerFormat: Sendable {
        /// Claude Code's: approvals, suggested rules, questions and plans (Qoder takes it too).
        case claude
        /// Allow or deny only (Codex; Qwen Code ignores rules from a hook).
        case allowOrDeny
    }

    /// What tells the agent's own hook from another agent reading the same settings file.
    enum AskCheck: Sendable {
        case none
        /// The agent gives its hooks its own process id in this variable.
        case processID(variable: String)
        /// The agent sets this variable for its hooks.
        case variable(String)
    }

    let source: Source
    /// The file Underbrim's hooks go in, if it adds any.
    let hookFile: HookFile?
    /// nil: its requests can't be answered from the notch.
    let answers: AnswerFormat?
    let askCheck: AskCheck
    /// The agent holds its own prompt until the hook answers, so a request is handed back when
    /// the agent is in front or after a while; the others ask at the same time.
    let waitsForHook: Bool
    /// The folder (in a project, and in the home folder) where it saves a rule it suggested.
    let rulesFolder: String?
}

extension AgentProvider {
    var spec: AgentSpec {
        switch self {
        case .claude:
            AgentSpec(source: .files, hookFile: .init(path: ".claude/settings.json", layout: .groups), answers: .claude,
                      askCheck: .processID(variable: "CLAUDE_PID"), waitsForHook: false, rulesFolder: ".claude")
        case .codex:
            AgentSpec(source: .files, hookFile: .init(path: ".codex/hooks.json", layout: .pinnedGroups), answers: .allowOrDeny,
                      askCheck: .none, waitsForHook: true, rulesFolder: nil)
        case .cursor:
            AgentSpec(source: .hooks, hookFile: .init(path: ".cursor/hooks.json", layout: .handlers), answers: nil,
                      askCheck: .none, waitsForHook: false, rulesFolder: nil)
        case .antigravity:
            AgentSpec(source: .plugin, hookFile: nil, answers: nil, askCheck: .none, waitsForHook: false, rulesFolder: nil)
        case .qwen:
            AgentSpec(source: .hooks, hookFile: .init(path: ".qwen/settings.json", layout: .groups), answers: .allowOrDeny,
                      askCheck: .variable("QWEN_CODE_SESSION_ID"), waitsForHook: true, rulesFolder: nil)
        case .qoder:
            AgentSpec(source: .hooks, hookFile: .init(path: ".qoder/settings.json", layout: .groups), answers: .claude,
                      askCheck: .variable("QODER_HOOK_SOURCE"), waitsForHook: false, rulesFolder: ".qoder")
        }
    }

    /// Its sessions come from its own files; the others' come from their hooks.
    var readsFiles: Bool {
        switch spec.source {
        case .files: true
        case .hooks, .plugin: false
        }
    }
}

//
//  AgentEvent.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What happened in a session, in Claude Code's hook vocabulary: from another agent's hook
//  through the relay (RelayMessage), or from Claude Code's and Codex's own files
//  (AgentFileWatcher). AgentSession folds these into its state.
//

import Foundation

struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStart
        case userPromptSubmit
        case preToolUse(tool: String?)
        case postToolUse(tool: String?)
        case permissionRequest(tool: String?)
        /// The tool was refused, in the agent or by its rules; the turn goes on without it.
        case permissionDenied(tool: String?)
        case notification(Notice)
        case stop
        /// The turn stopped on an API error (one of RelaySanitizer.detailTokens, when known).
        case stopFailure(reason: String?)
        case interrupt
        case sessionEnd
        /// Only the card's details or the session's folder or name changed (from files).
        case update
        /// A new name alone (from files): it brings back no session, nor counts as activity.
        case title
    }

    /// Notification types worth a state.
    enum Notice: String, Sendable {
        case permissionPrompt = "permission_prompt"
        case idlePrompt = "idle_prompt"
        case elicitationDialog = "elicitation_dialog"
        /// Codex's request_user_input tool (from its log).
        case agentNeedsInput = "agent_needs_input"
    }

    let provider: AgentProvider
    let session: String
    var kind: Kind
    /// When the hook or the file says it happened; orders late arrivals.
    var date: Date
    var cwd: String?
    /// A session title the user set.
    var title: String?
    /// How the agent was started, e.g. "claude-desktop", "cli", "sdk-ts".
    var entry: String?
    /// Claude Desktop's own session id ("local_…"), for its session deep link.
    var hostSession: String?
    var attended: Bool?
    /// The app hosting the agent.
    var host: String?
    var process: ProcessStamp?
}

/// One process, told from a later one that reuses its pid by when it started.
struct ProcessStamp: Equatable, Sendable {
    let pid: Int32
    /// µs since 1970.
    let start: UInt64
}

extension AgentEvent.Kind {
    /// An event a hook sends, by its name on the wire (`RelayEvent.kind`) with the tool or the one
    /// allowlisted word that goes with it; nil for any other name. Updates and titles come only
    /// from files.
    init?(hookEvent name: String, tool: String?, detail: String?) {
        switch name {
        case "SessionStart": self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse": self = .preToolUse(tool: tool)
        case "PostToolUse": self = .postToolUse(tool: tool)
        case "PermissionRequest": self = .permissionRequest(tool: tool)
        case "PermissionDenied": self = .permissionDenied(tool: tool)
        case "Notification":
            guard let notice = detail.flatMap(AgentEvent.Notice.init(rawValue:)) else { return nil }
            self = .notification(notice)
        case "Stop": self = .stop
        case "StopFailure": self = .stopFailure(reason: detail)
        case "Interrupt": self = .interrupt
        case "SessionEnd": self = .sessionEnd
        default: return nil
        }
    }

    /// The hook's name for it, for logs (the tool and the detail stay out).
    var name: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .userPromptSubmit: "UserPromptSubmit"
        case .preToolUse: "PreToolUse"
        case .postToolUse: "PostToolUse"
        case .permissionRequest: "PermissionRequest"
        case .permissionDenied: "PermissionDenied"
        case .notification: "Notification"
        case .stop: "Stop"
        case .stopFailure: "StopFailure"
        case .interrupt: "Interrupt"
        case .sessionEnd: "SessionEnd"
        case .update: "Update"
        case .title: "Title"
        }
    }
}

//
//  AgentPresentation.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  How a session state reads: symbol, tint and words. Every state has its
//  own symbol shape and text, so colour never carries status on its own.
//

import Defaults
import SwiftUI

/// What the closed notch needs to draw. Deliberately excludes the current
/// tool, so the big ContentView body doesn't re-run on every tool call.
struct AgentClosedSummary: Equatable {
    /// `attention`: an approval or a plan waits on the user; `question`: a question does.
    enum Kind: Equatable { case working, attention, question, finished, failed, stopped }
    let sessionID: String
    let provider: AgentProvider
    let hostBundleID: String?
    let kind: Kind
    /// When the session took this state (a request: when it started waiting).
    let since: Date
    /// When the newest request of any session began (nil: none waits on the user).
    let lastRequest: Date?
    let accessibilityText: String
    let othersActive: Int
    /// The creatures to show: the busy sessions, the featured one first, at most three.
    var creatures: [AgentCreatureItem] = []
    /// Its state in words, as the accessibility text starts.
    var words = ""
    /// A question the user set aside: it waits here without coming forward again.
    var setAside = false

    /// Waiting on the user: it stays in front of the closed notch's other activities.
    var waitsOnUser: Bool { kind == .attention || kind == .question }
}

struct AgentCreatureItem: Equatable, Identifiable {
    let id: String
    let kind: AgentCreatureKind
    let state: AgentCreatureState
    let since: Date

    /// `state` and `since`: what it shows and since when, if not the session's (a reminder asks
    /// again; a question set aside keeps asking after its turn finished).
    init(_ session: AgentSession, state: AgentCreatureState? = nil, since: Date? = nil) {
        id = session.id
        kind = AgentCreatureKind(provider: session.provider)
        self.state = state ?? AgentCreatureState(session.phase)
        self.since = since ?? session.phaseSince
    }
}

extension AgentCreatureKind {
    var displayName: String {
        switch self {
        case .agent(let provider): provider.displayName
        case .other: String(localized: "Other agents")
        }
    }
}

extension AgentCreatureState {
    init(_ phase: AgentSession.Phase) {
        self = switch phase {
        case .working: .working
        case .attention(let wait): wait.creature
        case .completed: .done
        case .failed: .failed
        case .interrupted: .stopped
        default: .idle
        }
    }
}

/// What a session waits on the user for, as every place that shows it says it: the closed notch and its
/// hover, the tab's line, the Settings island, the ask page, the cards and VoiceOver.
extension AgentSession.Attention {
    /// What its session waits on while the request does.
    init(_ request: AgentRequest) {
        switch request.kind {
        case .permission: self = .prompt(for: request.body.tool)
        case .question: self = .question
        case .plan: self = .plan
        }
    }

    var words: String {
        switch self {
        case .permission(let tool?): String(localized: "Needs approval · \(AgentToolName.readable(tool))")
        case .permission(nil): String(localized: "Needs approval")
        case .plan: String(localized: "Plan ready")
        case .question: String(localized: "Waiting for your answer")
        }
    }

    /// A plan is approved, like a tool.
    var symbol: String { self == .question ? "questionmark.bubble.fill" : "hand.raised.fill" }
    var creature: AgentCreatureState { self == .question ? .question : .permission }
    var closedKind: AgentClosedSummary.Kind { self == .question ? .question : .attention }
}

/// A tool's name as people read it, whichever agent's word for it: Claude Code's as it is ("Bash", "Edit"),
/// Codex's and Qwen Code's for the same tools as Claude Code's, an MCP tool by its name and server
/// ("create issue (github)"), and any other snake_case name as words ("view_image" → "view image").
enum AgentToolName {
    /// The other agents' names for Claude Code's tools, as RelayRequestBuilder.action reads them.
    private static let claudeNames: [String: String] = [
        "shell": "Bash", "local_shell": "Bash", "local_shell_call": "Bash", "exec_command": "Bash", "run_shell_command": "Bash",
        "apply_patch": "Edit", "edit": "Edit", "replace": "Edit", "write_file": "Write",
        "read_file": "Read", "read_many_files": "Read", "glob": "Glob", "grep_search": "Grep",
        "web_fetch": "WebFetch", "web_search": "WebSearch", "google_web_search": "WebSearch",
    ]

    /// Claude Code's name for the same tool, or the name as it is.
    static func claudeName(_ tool: String) -> String { claudeNames[tool] ?? tool }

    static func readable(_ tool: String) -> String {
        let name = claudeName(tool)
        let parts = name.components(separatedBy: "__")
        if name.hasPrefix("mcp__"), parts.count > 2 {
            return "\(parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")) (\(parts[1]))"
        }
        let words = name.split(separator: "_").joined(separator: " ")
        return words.isEmpty ? name : words
    }
}

struct AgentStatusStyle {
    let symbol: String
    let tint: Color
    let text: String
    /// What VoiceOver says when the text alone leans on the symbol (a command as written).
    var spoken: String?
    var accessibilityText: String { spoken ?? text }

    static func of(_ session: AgentSession, quiet: Bool,
                   details: Bool = Defaults[.showSessionDetails], now: Date = Date()) -> AgentStatusStyle {
        if quiet, session.phase == .working {
            // A moment's grace: a timeline's tick at the minute mustn't round to the one before.
            let minutes = max(1, Int((now.timeIntervalSince(session.lastEventAt) + 0.5) / 60))
            return .init(symbol: "clock", tint: .secondary,
                         text: String(localized: "No updates for \(minutes) min"))
        }
        switch session.phase {
        case .ready:
            return .init(symbol: "circle.dashed", tint: .secondary, text: String(localized: "Ready"))
        case .working:
            if details, session.details.subagents > 1 {
                return .init(symbol: "person.2", tint: .white,
                             text: String(localized: "\(session.details.subagents) subagents running"))
            }
            if let tool = session.tool {
                return details ? activity(tool: tool, target: session.details.target)
                               : .init(symbol: "gearshape.2", tint: .white, text: String(localized: "Running \(AgentToolName.readable(tool))"))
            }
            return .init(symbol: "ellipsis", tint: .white, text: String(localized: "Working"))
        case .attention(let wait):
            return .init(symbol: wait.symbol, tint: .orange, text: wait.words)
        case .completed:
            return .init(symbol: "checkmark.circle.fill", tint: .green, text: String(localized: "Done"))
        case .interrupted:
            return .init(symbol: "stop.circle", tint: .secondary, text: String(localized: "Interrupted"))
        case .failed(let reason):
            return .init(symbol: "exclamationmark.triangle.fill", tint: .yellow, text: failureText(reason))
        case .waitingForInput:
            return .init(symbol: "text.bubble", tint: .secondary, text: String(localized: "Waiting for your next message"))
        case .ended(.processExited):
            return .init(symbol: "bolt.horizontal.circle", tint: .secondary, text: String(localized: "Disconnected"))
        case .ended(.sessionEnd):
            return .init(symbol: "xmark.circle", tint: .secondary, text: String(localized: "Session ended"))
        }
    }

    /// A tool at work, in words with its object: the symbol says what kind of
    /// work it is, so a command can be shown as written.
    static func activity(tool: String, target: String?) -> AgentStatusStyle {
        func style(_ symbol: String, _ text: String, spoken: String? = nil) -> AgentStatusStyle {
            .init(symbol: symbol, tint: .white, text: text, spoken: spoken)
        }
        // Codex's and Qwen Code's tools by Claude Code's names for them.
        switch (AgentToolName.claudeName(tool), target) {
        case ("Read", let file?), ("NotebookRead", let file?):
            return style("doc.text", String(localized: "Reading \(file)"))
        case ("Edit", let file?), ("MultiEdit", let file?), ("NotebookEdit", let file?):
            return style("pencil", String(localized: "Editing \(file)"))
        case ("Write", let file?):
            return style("square.and.pencil", String(localized: "Writing \(file)"))
        case ("Bash", let command?), ("PowerShell", let command?):
            return style("terminal", command, spoken: String(localized: "Command: \(command)"))
        case ("Grep", let pattern?), ("Glob", let pattern?):
            return style("magnifyingglass", String(localized: "Searching \(pattern)"))
        case ("WebFetch", let host?):
            return style("globe", String(localized: "Reading \(host)"))
        case ("WebSearch", _):
            return style("globe", String(localized: "Searching the web"))
        case ("Agent", let task?), ("Task", let task?):
            return style("person.2", task, spoken: String(localized: "Subagent: \(task)"))
        case ("Agent", nil), ("Task", nil):
            return style("person.2", String(localized: "Running a subagent"))
        case ("Skill", let name?):
            return style("puzzlepiece.extension", String(localized: "Using \(name)"))
        case (_, let server?) where tool.hasPrefix("mcp__"):
            return style("puzzlepiece.extension", String(localized: "Using \(server)"))
        default:
            return style("gearshape.2", String(localized: "Running \(AgentToolName.readable(tool))"))
        }
    }

    static func failureText(_ reason: String?) -> String {
        switch reason {
        case "rate_limit": String(localized: "Stopped · usage limit reached")
        case "overloaded", "server_error": String(localized: "Stopped · service unavailable")
        case "authentication_failed", "oauth_org_not_allowed": String(localized: "Stopped · sign-in problem")
        case "billing_error", "account_on_hold": String(localized: "Stopped · account problem")
        case "max_output_tokens": String(localized: "Stopped · reply too long")
        default: String(localized: "Stopped · error")
        }
    }
}

extension AgentSession {
    /// "Claude Code · Desktop", "Codex · Terminal" …
    var originText: String {
        let surface: String? = switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": String(localized: "Desktop")
        case "cli": String(localized: "Terminal")
        case "claude-vscode": "VS Code"
        default: hostBundleID.flatMap(Self.hostName)
        }
        // Cursor's own sessions run in Cursor: no "Cursor · Cursor".
        return [provider.displayName, surface.flatMap { $0 == provider.displayName ? nil : $0 }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func hostName(_ bundleID: String) -> String? {
        if bundleID == AgentProvider.claude.defaultHostBundleID || bundleID == AgentProvider.codex.defaultHostBundleID {
            return String(localized: "Desktop")
        }
        if let editor = AgentHostApps.editors[bundleID] { return editor }
        return AgentHostApps.terminals.contains(bundleID) ? String(localized: "Terminal") : nil
    }
}

extension AgentSession {
    /// The id the agent's app knows the session by, as its previous sessions list it: the Claude
    /// app's own id, a Codex thread's id. nil for agents with no such list.
    var appSessionID: String? {
        switch provider {
        case .claude: desktopSessionID
        case .codex: sessionID
        case .qwen, .qoder, .cursor, .antigravity: nil
        }
    }
}

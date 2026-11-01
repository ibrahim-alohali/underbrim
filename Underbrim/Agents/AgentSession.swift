//
//  AgentSession.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  One coding-agent session and the pure reducer that folds events into it, from
//  Claude Code's and Codex's files or the other agents' hooks. Free of UI and timers.
//

import Foundation

struct AgentSession: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case ready
        /// A turn is running; `tool` names a tool call in flight.
        case working
        case attention(Attention)
        case completed
        /// The turn was interrupted (Esc, Ctrl-C, or a cancelled tool).
        case interrupted
        /// The turn stopped on an API error (rate limit, overload, auth…).
        case failed(reason: String?)
        case waitingForInput
        case ended(EndReason)
    }

    enum EndReason: Equatable, Sendable {
        case sessionEnd
        /// The agent process went away without one.
        case processExited
    }

    enum Attention: Equatable, Sendable {
        case permission(tool: String?)
        /// A plan to approve.
        case plan
        case question

        /// What a permission prompt for `tool` waits on: Claude Code (and Qoder, with its tool names) asks
        /// for a plan's approval and its questions through the same prompt as for a tool.
        static func prompt(for tool: String?) -> Attention {
            switch tool {
            case "ExitPlanMode": .plan
            case "AskUserQuestion": .question
            default: .permission(tool: tool)
            }
        }
    }

    let provider: AgentProvider
    let sessionID: String
    var cwd: String?
    var hostBundleID: String?
    var phase: Phase = .ready
    /// The tool call in flight while working; kept through an approval, so the request can name it.
    private var runningTool: String?
    var phaseSince: Date
    /// When the turn at work began: it runs on through the approvals and questions it waits on.
    private(set) var turnSince: Date
    /// Relay timestamp of the newest event applied; orders late arrivals.
    var lastEventAt: Date
    var agentPID: Int32?
    var title: String?
    var entrypoint: String?
    var desktopSessionID: String?
    var attended = true
    /// The agent reports this session's state itself, so silence while working is normal.
    var live = false
    var details = AgentDetails()
    /// The last event applied, so a duplicate (the same kind at the same time) is ignored.
    private var lastApplied: Applied?
    private struct Applied: Equatable, Sendable {
        let kind: AgentEvent.Kind
        let date: Date
    }

    var id: String { "\(provider.rawValue):\(sessionID)" }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return provider.displayName }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }

    var displayTitle: String { title ?? projectName }
    var hasTitle: Bool { title != nil }

    var needsAttention: Bool {
        if case .attention = phase { return true }
        return false
    }

    var isSettled: Bool { phase != .working && !needsAttention }

    var hasEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// The tool call in flight; nil unless working.
    var tool: String? { phase == .working ? runningTool : nil }

    init(provider: AgentProvider, sessionID: String, at date: Date) {
        self.provider = provider
        self.sessionID = sessionID
        phaseSince = date
        turnSince = date
        lastEventAt = date
    }

    /// Applies one event. Duplicates are ignored; events older than the
    /// newest applied one may refresh metadata but never move the phase
    /// backwards — except SessionEnd, which always wins.
    mutating func apply(_ event: AgentEvent) {
        let date = event.date
        let applied = Applied(kind: event.kind, date: date)
        guard applied != lastApplied else { return }
        lastApplied = applied

        if let cwd = event.cwd { self.cwd = cwd }
        if let title = event.title { self.title = title }
        if let entry = event.entry { entrypoint = entry }
        if let hostSession = event.hostSession { desktopSessionID = hostSession }
        if let attended = event.attended { self.attended = attended }
        let isLate = date < lastEventAt
        if !isLate { lastEventAt = date }
        if hasEnded && event.kind != .sessionStart { return }
        if isLate && event.kind != .sessionEnd { return }

        switch event.kind {
        case .sessionStart:
            if hasEnded || phase == .ready {
                set(.ready, at: date)
            }
        case .userPromptSubmit:
            runningTool = nil
            set(.working, at: date)
        case .preToolUse(let tool):
            runningTool = tool
            set(.working, at: date)
        case .postToolUse, .permissionDenied:
            // The tool ran, or was refused and the turn goes on without it: either way any permission it
            // waited on was answered, and a turn is running even if this is the first event seen for the session.
            runningTool = nil
            if needsAttention || [.working, .ready, .waitingForInput].contains(phase) { set(.working, at: date) }
        case .permissionRequest(let tool):
            set(.attention(.prompt(for: tool ?? runningTool)), at: date)
        case .notification(let notice):
            switch notice {
            case .elicitationDialog, .agentNeedsInput:
                set(.attention(.question), at: date)
            case .permissionPrompt:
                // An agent whose approvals aren't answered here says it's asking.
                if !needsAttention { set(.attention(.prompt(for: runningTool)), at: date) }
            case .idlePrompt:
                // An idle session seen at launch: it's waiting for the next message.
                if !needsAttention { runningTool = nil; set(.waitingForInput, at: date) }
            }
        case .stop:
            runningTool = nil
            set(.completed, at: date)
        case .stopFailure(let reason):
            runningTool = nil
            set(.failed(reason: reason), at: date)
        case .interrupt:
            runningTool = nil
            set(.interrupted, at: date)
        case .sessionEnd:
            runningTool = nil
            set(.ended(.sessionEnd), at: date)
        case .update, .title:
            // Metadata only.
            break
        }
    }

    /// A wait that only learns its tool keeps its start: the island knows it by when it began.
    private mutating func set(_ newPhase: Phase, at date: Date) {
        if newPhase != phase, !Self.sameWait(phase, newPhase) { phaseSince = date }
        // A turn starts with work, or a wait on the user seen first; work going on after the wait is the same turn.
        if Self.inTurn(newPhase), !Self.inTurn(phase) { turnSince = date }
        phase = newPhase
    }

    private static func inTurn(_ phase: Phase) -> Bool {
        if case .attention = phase { return true }
        return phase == .working
    }

    private static func sameWait(_ old: Phase, _ new: Phase) -> Bool {
        switch (old, new) {
        case (.attention(.permission), .attention(.permission)), (.attention(.plan), .attention(.plan)),
             (.attention(.question), .attention(.question)): true
        // A prompt whose tool turns out to be a plan or a question.
        case (.attention(.permission(tool: nil)), .attention(.plan)),
             (.attention(.permission(tool: nil)), .attention(.question)): true
        default: false
        }
    }

    /// The agent process went away without ending the session.
    mutating func markDisconnected(at date: Date) {
        runningTool = nil
        details.target = nil
        details.subagents = 0
        phase = .ended(.processExited)
        phaseSince = date
    }
}

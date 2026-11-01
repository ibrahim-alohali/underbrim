//
//  AgentRequests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Requests an agent waits on (approvals, questions, plans), answered from the notch.
//  Each holds its hook's connection; it leaves when answered here, handed back, the
//  agent goes away, or answered elsewhere. Claude Code doesn't end a hook its own
//  window answered, so its status file is watched while a request waits. Nothing is
//  ever answered without a click.
//

import AppKit
import Defaults
import Foundation
import Observation

struct AgentRequest: Identifiable, Equatable, Sendable {
    let provider: AgentProvider
    let sessionID: String?
    let cwd: String?
    let hostBundleID: String?
    /// The agent's process: Claude Code names its status file after it.
    let agentPID: Int32?
    let arrived: Date
    let body: RelayRequest

    var id: String { body.id }
    var kind: RelayRequest.Kind { body.kind }
    var sessionKey: String? { sessionID.map { "\(provider.rawValue):\($0)" } }

    /// Where a handed-back request is answered: its terminal, or the agent's own app.
    var host: String { hostBundleID ?? provider.defaultHostBundleID }

    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

@MainActor
@Observable
final class AgentRequestStore {
    static let shared = AgentRequestStore()

    /// Oldest first: the one waiting longest is answered first.
    private(set) var requests: [AgentRequest] = []
    /// Counts arrivals, so the island can open for each new one.
    private(set) var arrivals = 0

    func receive(_ arrival: AgentRequestArrival) {
        let provider = arrival.provider
        let request = AgentRequest(provider: provider, sessionID: arrival.session, cwd: arrival.cwd,
                                   hostBundleID: arrival.host, agentPID: arrival.process?.pid, arrived: Date(), body: arrival.request)
        // A scripted run nobody watches keeps to its own rules, unless the user shows those runs.
        let attended = arrival.attended ?? request.sessionKey.flatMap { key in
            AgentSessionStore.shared.sessions.first { $0.id == key }?.attended
        }
        if attended == false, !Defaults[.showBackgroundAgents] {
            RelayListener.shared.reply(nil, to: request.id)
            return
        }
        // Codex and Qwen Code wait for the hook before they ask, so with the agent (or its
        // terminal tab) in front the request goes straight back to its own prompt.
        if provider.spec.waitsForHook, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == request.host {
            deciding.insert(request.id)
            Task { [weak self] in
                let inFront = await Self.promptInFront(request)
                // Withdrawn meanwhile: the hook is gone.
                guard let self, self.deciding.remove(request.id) != nil else { return }
                if inFront { RelayListener.shared.reply(nil, to: request.id) } else { self.accept(request, arrival) }
            }
            return
        }
        accept(request, arrival)
    }

    private func accept(_ request: AgentRequest, _ arrival: AgentRequestArrival) {
        let provider = request.provider
        // Only Claude Code saves its approval requests, so the others' session cards learn it here:
        // a question as one, anything else as an approval.
        if provider != .claude, Defaults[.showAgentActivity], let session = arrival.session {
            let kind: AgentEvent.Kind = request.kind == .question
                ? .notification(.elicitationDialog) : .permissionRequest(tool: request.body.tool)
            AgentSessionStore.shared.apply(AgentEvent(provider: provider, session: session, kind: kind, date: arrival.date,
                                                      cwd: arrival.cwd, attended: arrival.attended, host: arrival.host,
                                                      process: arrival.process))
        }
        if provider.spec.waitsForHook {
            watchActivations()
            let id = request.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(HookInstaller.handBackAfter))
                self?.handBack(id)
            }
        }
        requests.append(request)
        arrivals += 1
        watchStatusFiles()
        AgentSessionStore.shared.refreshSummary()
    }

    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Requests whose agent's tab is being checked before they show.
    @ObservationIgnored private var deciding: Set<String> = []

    /// Whether the agent's own prompt is in front: its app, or in Terminal and iTerm2 its tab
    /// (the terminal, when the tab can't be told). In other terminals, the terminal.
    private static func promptInFront(_ request: AgentRequest) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == request.host else { return false }
        guard AgentOpener.inFrontNow(host: request.host, provider: request.provider) == nil else { return true }
        return await AgentOpener.isInFront(host: request.host, provider: request.provider, agentPID: request.agentPID,
                                           ifUnknown: true)
    }

    /// Switching to Codex or Qwen Code (or the terminal it runs in) hands its waiting requests back.
    private func watchActivations() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                let store = AgentRequestStore.shared
                for request in store.requests where request.provider.spec.waitsForHook && request.host == app?.bundleIdentifier {
                    Task { if await AgentRequestStore.promptInFront(request) { store.handBack(request.id) } }
                }
            }
        }
    }

    /// The hook ended without our answer: the agent went away, or stopped waiting.
    func withdraw(_ id: String) {
        deciding.remove(id)
        guard requests.contains(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        watchStatusFiles()
        AgentSessionStore.shared.refreshSummary()
    }

    // MARK: - Answered elsewhere

    @ObservationIgnored private var statusWatch: ClaudeStatusWatch?

    private func watchStatusFiles() {
        let waiting = requests.contains { $0.provider == .claude && $0.agentPID != nil }
        if waiting, statusWatch == nil {
            statusWatch = ClaudeStatusWatch { [weak self] in self?.checkClaudeSessions() }
            checkClaudeSessions()
        } else if !waiting {
            statusWatch = nil
        }
    }

    /// A Claude session whose status changed to something other than waiting
    /// after its request arrived has had it answered elsewhere (or interrupted).
    func checkClaudeSessions() {
        let folder = AgentFiles.claudeSessions(home: AgentFiles.home)
        for request in requests where request.provider == .claude {
            guard let pid = request.agentPID else { continue }
            let record = ClaudeSessionRegistry.record(at: folder.appendingPathComponent("\(pid).json"))
            guard let record, record.sessionID == request.sessionID else { continue }
            if record.status != .waiting, let changed = record.statusChangedAt,
               changed.timeIntervalSince(request.arrived) > Self.settleTime {
                handBack(request.id)
            }
        }
    }

    /// A status written within this of the request's arrival may predate it.
    static let settleTime: TimeInterval = 0.3

    /// A hook said a session moved on (a tool ran or was refused, the turn ended): its
    /// request was answered in the agent itself, as Qoder asks there at the same time.
    func sessionMovedOn(_ event: AgentEvent) {
        // A tool's own end only: another one may finish while this one waits.
        let tool: String?
        switch event.kind {
        case .postToolUse(let ended), .permissionDenied(let ended): tool = ended
        case .userPromptSubmit, .stop, .stopFailure, .sessionEnd: tool = nil
        case .sessionStart, .preToolUse, .permissionRequest, .notification, .interrupt, .update, .title: return
        }
        let provider = event.provider
        guard !provider.readsFiles else { return }
        for request in requests where request.provider == provider && request.sessionID == event.session
            && (tool == nil || tool == request.body.tool) && event.date.timeIntervalSince(request.arrived) > Self.settleTime {
            handBack(request.id)
        }
    }

    func request(_ id: String) -> AgentRequest? { requests.first { $0.id == id } }

    // MARK: - Answers

    func allow(_ id: String, suggestion: Int? = nil) {
        send(RelayAnswer(id: id, decision: .allow, suggestion: suggestion), for: id)
    }

    func deny(_ id: String, message: String? = nil) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        send(RelayAnswer(id: id, decision: .deny, message: text?.isEmpty == false ? text : nil), for: id)
    }

    /// One choice per answered question; skipped ones are left out.
    func answer(_ id: String, choices: [RelayChoice]) {
        guard !choices.isEmpty else { return deny(id, message: "The user chose not to answer these questions.") }
        send(RelayAnswer(id: id, decision: .answer, choices: choices), for: id)
    }

    func approvePlan(_ id: String, acceptEdits: Bool) {
        send(RelayAnswer(id: id, decision: .allow, mode: acceptEdits ? "acceptEdits" : "default"), for: id)
    }

    /// Leaves the request to the agent's own prompt; its session's wait stays there.
    func handBack(_ id: String) {
        send(nil, for: id)
    }

    /// The tool approvals `ids` (the cards shown), nothing that arrives later.
    func allowAll(_ ids: [String]) {
        for request in requests where request.kind == .permission && ids.contains(request.id) { allow(request.id) }
    }

    private func send(_ answer: RelayAnswer?, for id: String) {
        guard let request = requests.first(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        RelayListener.shared.reply(answer, to: id)
        if let answer { moveOn(request, answer.decision) } else { AgentAsks.shared.handedBack(request) }
        AgentSessionStore.shared.refreshSummary()
    }

    /// Answered here, its session goes back to work at once, rather than reading as waiting until the
    /// agent's next event: allowed or answered, the tool runs; refused, the turn goes on without it.
    private func moveOn(_ request: AgentRequest, _ decision: RelayAnswer.Decision) {
        guard let key = request.sessionKey, let sessionID = request.sessionID,
              AgentSessionStore.shared.sessions.contains(where: { $0.id == key && $0.needsAttention }) else { return }
        let kind: AgentEvent.Kind = switch (decision, request.kind) {
        case (.deny, _): .permissionDenied(tool: request.body.tool)
        case (_, .permission): .preToolUse(tool: request.body.tool)
        default: .postToolUse(tool: request.body.tool)
        }
        AgentSessionStore.shared.apply(AgentEvent(provider: request.provider, session: sessionID, kind: kind, date: Date()))
    }
}

/// File events in ~/.claude/sessions while it exists (FSEvents, so a file
/// replaced by a new one is seen as well as one rewritten in place).
private final class ClaudeStatusWatch {
    private var stream: FSEventStreamRef?
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        let folder = AgentFileWatcher.realPath(AgentFiles.claudeSessions(home: AgentFiles.home).path)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watch = Unmanaged<ClaudeStatusWatch>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watch.changed() }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                                               FSEventStreamCreateFlags(flags))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

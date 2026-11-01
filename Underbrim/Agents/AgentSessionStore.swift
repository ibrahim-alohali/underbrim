//
//  AgentSessionStore.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Main-actor home of the coding-agent sessions, read from the agents' session files
//  (AgentFileWatcher). No polling: FSEvents, process-exit sources, and one task that
//  sleeps until something next changes (a "Done" fading, a session going quiet).
//

import AppKit
import Defaults
import Foundation
import Observation
import os

@MainActor
@Observable
final class AgentSessionStore {
    static let shared = AgentSessionStore()

    /// Newest first; updates keep a session's place, so the list doesn't reshuffle.
    private(set) var sessions: [AgentSession] = []
    /// Working sessions silent for long: shown as "No updates for …", never as failed.
    private(set) var quietSessionIDs: Set<String> = []
    /// The session whose turn just ended, and when: it has a moment as "Done".
    private var finished: (id: String, at: Date)?
    var recentlyFinishedID: String? { finished?.id }
    /// What the closed notch shows; only reassigned when it actually changes.
    private(set) var closedSummary: AgentClosedSummary?

    /// Silence after which a working session is labelled quiet. A tool call in
    /// flight (a build, a test run) gets longer before we say anything.
    static let quietAfter: TimeInterval = 5 * 60
    static let quietAfterDuringTool: TimeInterval = 30 * 60
    static let finishedFeedback: TimeInterval = 5
    static let endedLinger: TimeInterval = 20
    static let idleRetention: TimeInterval = 90 * 60
    static let questionRetention: TimeInterval = 24 * 60 * 60
    static let replyShown: TimeInterval = 10 * 60
    static let maxSessions = 12
    static let exitGrace: TimeInterval = 1.5

    @ObservationIgnored private var listening = false
    @ObservationIgnored private var files: AgentFileWatcher?
    @ObservationIgnored private var codexObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var codexTimer: Timer?
    @ObservationIgnored private var exitSources: [Int32: DispatchSourceProcess] = [:]
    @ObservationIgnored private var housekeeping: Task<Void, Never>?
    /// Requests still waiting that were reminded of: when that wait began, and when reminded.
    @ObservationIgnored private var reminders: [String: (waitSince: Date, at: Date)] = [:]
    @ObservationIgnored private let log = Logger(subsystem: bundleIdentifier, category: "agents")

    // MARK: - Lifecycle

    func startListening() {
        guard !listening else { return }
        listening = true
        Defaults.whenChanged([.showBackgroundAgents, .hiddenAgentFolders]) { [weak self] in
            self?.settingsRevision += 1
            self?.refreshSummary()
        }
        // Questions under a reply wait on the closed notch while the island doesn't show them.
        Defaults.whenChanged([.openIslandForAgentRequests]) { [weak self] in self?.refreshSummary() }
        // A wait already going hears of a new reminder time at once: it gets no events to reschedule it.
        Defaults.whenChanged([.agentReminderMinutes, .agentSounds]) { [weak self] in self?.scheduleHousekeeping() }
        // Session files are read only while sessions are shown.
        Defaults.whenChanged([.showAgentActivity]) { [weak self] in self?.watchFiles(Defaults[.showAgentActivity]) }
        watchFiles(Defaults[.showAgentActivity])
    }

    func stopListening() {
        listening = false
        watchFiles(false)
    }

    private func watchFiles(_ on: Bool) {
        guard on != (files != nil) else { return }
        if on {
            // Whatever arrived after the last stop is stale.
            sessions.removeAll()
            quietSessionIDs.removeAll()
            finished = nil
            let files = AgentFileWatcher { outputs in
                Task { @MainActor in AgentSessionStore.shared.receive(outputs) }
            }
            files.start()
            self.files = files
            watchCodexApp(true)
        } else {
            watchCodexApp(false)
            files?.stop()
            files = nil
            sessions.removeAll()
            finished = nil
            refreshSummary()
        }
    }

    /// The Codex app loads a thread without anything FSEvents reports, so the threads it has open are
    /// looked for when it comes to the front or leaves it, and every few seconds while it's in front.
    private func watchCodexApp(_ on: Bool) {
        codexObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        codexObservers = []
        codexInFront(false)
        guard on else { return }
        let codex = AgentProvider.codex.defaultHostBundleID
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            codexObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == codex else { return }
                MainActor.assumeIsolated {
                    AgentSessionStore.shared.files?.findOpenCodexThreads()
                    AgentSessionStore.shared.codexInFront(name == NSWorkspace.didActivateApplicationNotification)
                }
            })
        }
        codexInFront(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codex)
    }

    private func codexInFront(_ inFront: Bool) {
        codexTimer?.invalidate()
        codexTimer = nil
        guard inFront else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { AgentSessionStore.shared.files?.findOpenCodexThreads() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        codexTimer = timer
    }

    func receive(_ updates: [AgentFileWatcher.Update]) {
        for update in updates { apply(update.event, live: update.live, details: update.details) }
    }

    /// A running Claude Code is older than 2.1.162, which writes no status.
    var hasOutdatedClaude: Bool {
        sessions.contains { $0.provider == .claude && !$0.live && !$0.hasEnded }
    }

    // MARK: - Derived presentation

    /// Scripted and background runs (`claude -p`, SDK apps) stay out unless asked for.
    var visibleSessions: [AgentSession] {
        _ = settingsRevision  // tracked, so views re-read when the setting flips
        let hidden = Defaults[.hiddenAgentFolders]
        return sessions.filter { session in
            (Defaults[.showBackgroundAgents] || session.attended) && !Self.isHidden(session.cwd, in: hidden)
        }
    }

    /// Exactly the folders named: hiding the home folder's sessions doesn't hide every project under it.
    nonisolated static func isHidden(_ folder: String?, in hidden: [String]) -> Bool {
        guard let folder else { return false }
        func plain(_ path: String) -> Substring { path.count > 1 && path.hasSuffix("/") ? path.dropLast() : Substring(path) }
        return hidden.contains { plain($0) == plain(folder) }
    }

    /// Leaves out this folder's sessions from now on (Settings can bring them back).
    func hideFolder(_ folder: String) {
        guard !Defaults[.hiddenAgentFolders].contains(folder) else { return }
        Defaults[.hiddenAgentFolders].append(folder)
    }

    private var settingsRevision = 0

    /// The session the closed notch should feature: something waiting on the
    /// user beats a running turn, which beats a just-finished (or stopped) one.
    var spotlight: AgentSession? {
        let candidates = visibleSessions
        if let waiting = candidates.filter(\.needsAttention).min(by: { $0.phaseSince < $1.phaseSince }) {
            return waiting
        }
        if let working = candidates.first(where: { $0.phase == .working && !quietSessionIDs.contains($0.id) }) {
            return working
        }
        // Only while it still reads finished: an agent that exits right after
        // finishing must not be featured as "Working".
        return candidates.first { session in
            guard session.id == recentlyFinishedID else { return false }
            switch session.phase {
            case .completed, .failed, .interrupted: return true
            default: return false
            }
        }
    }

    var activeCount: Int { activeKeys.count }

    /// What waits on the user or works: the sessions shown, and requests from sessions not shown (by
    /// their session, or alone). The closed notch counts them all the same way.
    private var activeKeys: Set<String> {
        var keys = Set(visibleSessions.filter { $0.needsAttention || ($0.phase == .working && !quietSessionIDs.contains($0.id)) }.map(\.id))
        for request in AgentRequestStore.shared.requests { keys.insert(request.sessionKey ?? request.id) }
        return keys
    }

    /// The oldest question under a reply that waits on the closed notch (set aside, or with the island not
    /// showing questions): its creature keeps asking beside the camera until it's answered, brought back,
    /// or its session moves on.
    private var questionSummary: AgentClosedSummary? {
        let asks = AgentAsks.shared
        let question = asks.onClosedNotch.lazy.compactMap { ask -> (AgentSession, Date, Bool)? in
            if case .nextStep(let session, let step) = ask { (session, step.at, asks.isSetAside(ask)) } else { nil }
        }.first
        guard let (session, since, setAside) = question else { return nil }
        let words = AgentSession.Attention.question.words
        return AgentClosedSummary(
            sessionID: session.id,
            provider: session.provider,
            hostBundleID: session.hostBundleID,
            kind: .question,
            since: since,
            lastRequest: nil,
            accessibilityText: "\(words) · \(session.provider.displayName) · \(session.displayTitle)",
            othersActive: activeKeys.subtracting([session.id]).count,
            creatures: creatureItems(first: session.id, asking: (session.id, since)),
            words: words,
            setAside: setAside
        )
    }

    /// The oldest request waiting in the notch, as the closed notch shows it:
    /// it needs the user even when its session isn't listed (sessions off).
    private var requestSummary: AgentClosedSummary? {
        let requests = AgentRequestStore.shared.requests
        guard let first = requests.first else { return nil }
        let session = first.sessionKey.flatMap { key in sessions.first { $0.id == key } }
        // In the words a session waiting on the same thing gets.
        let wait = AgentSession.Attention(first)
        let words = wait.words
        return AgentClosedSummary(
            sessionID: first.sessionKey ?? first.id,
            provider: first.provider,
            hostBundleID: first.hostBundleID ?? session?.hostBundleID,
            kind: wait.closedKind,
            since: first.arrived,
            lastRequest: requests.map(\.arrived).max(),
            accessibilityText: "\(words) · \(first.provider.displayName) · \(session?.displayTitle ?? first.projectName ?? "")",
            othersActive: activeKeys.subtracting([first.sessionKey ?? first.id]).count,
            creatures: creatureItems(first: first.sessionKey),
            words: words
        )
    }

    /// The busy sessions' creatures: waiting on you, then working, then just finished; `first` leads.
    /// `asking`: a session whose question was set aside, which asks from when it was asked.
    private func creatureItems(first: String?, asking: (id: String, since: Date)? = nil) -> [AgentCreatureItem] {
        let candidates = visibleSessions
        var ordered = candidates.filter(\.needsAttention).sorted { $0.phaseSince < $1.phaseSince }
            + candidates.filter { $0.phase == .working && !quietSessionIDs.contains($0.id) }
            + candidates.filter { ($0.id == recentlyFinishedID || $0.id == asking?.id) && !$0.needsAttention && $0.phase != .working }
        if let first, let index = ordered.firstIndex(where: { $0.id == first }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered.prefix(3).map { session in
            if session.id == asking?.id { return AgentCreatureItem(session, state: .question, since: asking?.since) }
            // A reminder makes the creature ask again.
            return AgentCreatureItem(session, since: reminders[session.id].flatMap { $0.waitSince == session.phaseSince ? $0.at : nil })
        }
    }

    /// When a wait is reminded of: never with sounds off, where Settings hides the reminder's choice.
    private func reminderDate(_ session: AgentSession) -> Date? {
        let minutes = Defaults[.agentReminderMinutes]
        guard minutes > 0, Defaults[.agentSounds], session.needsAttention, session.attended,
              reminders[session.id]?.waitSince != session.phaseSince
        else { return nil }
        return session.phaseSince.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Works out the closed notch's summary again, from the sessions, the requests waiting and the
    /// questions set aside; the request and question stores call it when theirs change.
    func refreshSummary() {
        AgentAsks.shared.sessionsChanged(sessions)
        AgentCues.shared.update(visibleSessions, requests: AgentRequestStore.shared.requests)
        AgentAwake.shared.update(working: visibleSessions.contains { $0.phase == .working && !quietSessionIDs.contains($0.id) })
        if let requestSummary {
            if requestSummary != closedSummary { closedSummary = requestSummary }
            return
        }
        // A question under a reply comes after a session waiting on the user, before work going on.
        if spotlight?.needsAttention != true, let questionSummary {
            if questionSummary != closedSummary { closedSummary = questionSummary }
            return
        }
        let summary: AgentClosedSummary? = spotlight.map { session in
            let kind: AgentClosedSummary.Kind
            let words: String
            switch session.phase {
            case .attention(let wait):
                kind = wait.closedKind
                words = wait.words
            case .completed:
                kind = .finished
                words = String(localized: "Done")
            case .failed(let reason):
                kind = .failed
                words = AgentStatusStyle.failureText(reason)
            case .interrupted:
                kind = .stopped
                words = String(localized: "Interrupted")
            default:
                kind = .working
                words = String(localized: "Working")
            }
            return AgentClosedSummary(
                sessionID: session.id,
                provider: session.provider,
                hostBundleID: session.hostBundleID,
                kind: kind,
                since: session.phaseSince,
                lastRequest: visibleSessions.filter(\.needsAttention).map(\.phaseSince).max(),
                // State first: the bubble's hover shows as much as fits.
                accessibilityText: "\(words) · \(session.provider.displayName) · \(session.displayTitle)",
                othersActive: activeKeys.subtracting([session.id]).count,
                creatures: creatureItems(first: session.id),
                words: words
            )
        }
        if summary != closedSummary { closedSummary = summary }
    }

    // MARK: - Events

    func apply(_ event: AgentEvent, live: Bool = false, details: AgentDetails? = nil) {
        let provider = event.provider, sessionID = event.session
        let id = "\(provider.rawValue):\(sessionID)"
        // A new name alone: it doesn't bring back a session that left the list, nor count as activity.
        if event.kind == .title {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[index].title = event.title
            refreshSummary()
            return
        }
        // Nor does other news of one that left the list (removed, or gone after it ended): a change of name,
        // folder or plan, or its end (a thread archived after it left). Only activity brings it back.
        if [.sessionEnd, .update].contains(event.kind), !sessions.contains(where: { $0.id == id }) { return }
        let date = event.date
        var session = sessions.first { $0.id == id } ?? AgentSession(provider: provider, sessionID: sessionID, at: date)
        let before = session.phase

        session.apply(event)
        if live { session.live = true }
        if let details { session.details = details }
        if let host = event.host { session.hostBundleID = host }
        var watch: ProcessStamp?
        if let process = event.process, session.agentPID != process.pid {
            session.agentPID = process.pid
            watch = process
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
            if sessions.count > Self.maxSessions, let evict = evictionCandidate() { sessions.remove(at: evict) }
        }
        quietSessionIDs.remove(id)
        // After inserting, so an agent that's already gone marks this session too.
        if let watch { watchExit(watch) }
        log.debug("\(provider.rawValue, privacy: .public) \(event.kind.name, privacy: .public) entry=\(event.entry ?? "-", privacy: .public) host=\(event.host ?? "-", privacy: .public) hostSession=\(event.hostSession != nil, privacy: .public) title=\(event.title != nil, privacy: .public) attended=\(event.attended.map(String.init) ?? "-", privacy: .public) pid=\(event.process != nil, privacy: .public) kind=\(String(describing: event.kind), privacy: .private) → \(String(describing: session.phase), privacy: .public) session=\(sessionID, privacy: .private)")

        let finished: Bool = switch session.phase {
        case .completed, .failed, .interrupted: true
        default: false
        }
        // Only a turn that just ended (or was stopped) gets the moment of "Done" (not history read at
        // launch), and not while its own window is in front: the user saw it end there.
        if finished && session.phase != before && Date().timeIntervalSince(date) < Self.finishedFeedback {
            switch AgentOpener.inFrontNow(host: session.hostBundleID, provider: provider) {
            case false?: showFinished(id)
            case true?: break
            case nil:
                let phase = session.phase
                Task { [weak self] in
                    guard await !AgentOpener.isInFront(host: session.hostBundleID, provider: provider, agentPID: session.agentPID),
                          let self, self.sessions.first(where: { $0.id == id })?.phase == phase else { return }
                    self.showFinished(id)
                    self.refreshSummary()
                    self.scheduleHousekeeping()
                }
            }
        } else if recentlyFinishedID == id && !finished {
            self.finished = nil
        }
        refreshSummary()
        scheduleHousekeeping()
    }

    private func showFinished(_ id: String) {
        finished = (id, Date())
    }

    /// Over the cap, the least useful session goes: ended ones, then background
    /// runs, then idle ones, oldest first — never one that's working or waiting
    /// on the user (it gets no events while it waits, so "oldest" would pick it).
    private func evictionCandidate() -> Int? {
        func rank(_ session: AgentSession) -> Int? {
            if session.hasEnded { return 0 }
            if !session.attended { return 1 }
            if session.needsAttention || session.phase == .working { return nil }
            return 2
        }
        return sessions.indices.dropFirst()
            .compactMap { index in rank(sessions[index]).map { (index, $0) } }
            .min { ($0.1, sessions[$0.0].lastEventAt) < ($1.1, sessions[$1.0].lastEventAt) }?.0
    }

    func dismiss(_ id: String) {
        sessions.removeAll { $0.id == id }
        if recentlyFinishedID == id { finished = nil }
        refreshSummary()
    }

    /// Removes every settled session; one still open comes back with its next event.
    func clearSettled() {
        sessions.removeAll(where: \.isSettled)
        if let id = recentlyFinishedID, !sessions.contains(where: { $0.id == id }) { finished = nil }
        refreshSummary()
    }

    // MARK: - Agent process exit (disconnects)

    private func watchExit(_ process: ProcessStamp) {
        let pid = process.pid
        guard exitSources[pid] == nil else { return }
        // Only watch the exact process the event named, not a reused pid.
        guard ProcessLineage.info(pid)?.start == process.start else {
            markDisconnected(pid: pid)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.exitSources.removeValue(forKey: pid)?.cancel()
                // A moment later, so a new process carrying the session on (a restart, a resumed
                // thread) has taken it over: only a session still on this process ends.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.exitGrace))
                    self?.markDisconnected(pid: pid)
                }
            }
        }
        exitSources[pid] = source
        source.resume()
    }

    private func markDisconnected(pid: Int32) {
        exitSources.removeValue(forKey: pid)?.cancel()
        let now = Date()
        for index in sessions.indices where sessions[index].agentPID == pid && !sessions[index].hasEnded {
            sessions[index].markDisconnected(at: now)
        }
        refreshSummary()
        scheduleHousekeeping()
    }

    // MARK: - Housekeeping (one sleeping task, no polling)

    /// Also when a question's closed: its session no longer waits for it.
    func scheduleHousekeeping() {
        housekeeping?.cancel()
        guard let deadline = nextDeadline() else { return }
        housekeeping = Task { [weak self] in
            let delay = max(0.05, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.runHousekeeping()
        }
    }

    private func nextDeadline() -> Date? {
        var deadlines = sessions.compactMap(removalDate)
        deadlines += sessions.filter { !quietSessionIDs.contains($0.id) }.compactMap(quietDate)
        if let finished {
            deadlines.append(finished.at.addingTimeInterval(Self.finishedFeedback))
        }
        deadlines += sessions.filter { $0.details.reply != nil }.map { $0.phaseSince.addingTimeInterval(Self.replyShown) }
        deadlines += visibleSessions.compactMap(reminderDate)
        return deadlines.min()
    }

    private func runHousekeeping() {
        let now = Date()
        if let finished, now.timeIntervalSince(finished.at) >= Self.finishedFeedback {
            self.finished = nil
        }
        sessions.removeAll { removalDate($0).map { now >= $0 } ?? false }
        // The reply has been on the card long enough: the title again.
        for index in sessions.indices where sessions[index].details.reply != nil
            && now.timeIntervalSince(sessions[index].phaseSince) >= Self.replyShown {
            sessions[index].details.reply = nil
        }
        for session in sessions where quietDate(session).map({ now >= $0 }) ?? false {
            quietSessionIDs.insert(session.id)
        }
        quietSessionIDs.formIntersection(sessions.map(\.id))
        for session in visibleSessions where reminderDate(session).map({ now >= $0 }) ?? false {
            reminders[session.id] = (session.phaseSince, now)
            AgentCues.shared.remind(session)
        }
        reminders = reminders.filter { id, _ in sessions.contains { $0.id == id && $0.needsAttention } }
        let livePIDs = Set(sessions.compactMap(\.agentPID))
        for (pid, source) in exitSources where !livePIDs.contains(pid) {
            source.cancel()
            exitSources[pid] = nil
        }
        refreshSummary()
        scheduleHousekeeping()
    }
}

extension AgentSessionStore {
    /// Ended sessions leave after a short linger, idle ones later; busy ones never on a timer.
    private func removalDate(_ session: AgentSession) -> Date? {
        switch session.phase {
        case .ended: session.phaseSince.addingTimeInterval(Self.endedLinger)
        case .attention, .working: nil
        // A question under the reply waits for its answer (AgentAsks), for a day at most, unless it's closed.
        default: session.details.nextStep.flatMap { AgentAsks.shared.waits(session, $0) ? $0.at.addingTimeInterval(Self.questionRetention) : nil }
            ?? session.lastEventAt.addingTimeInterval(Self.idleRetention)
        }
    }

    /// When a working session without news reads as quiet, unless the agent reports it working.
    private func quietDate(_ session: AgentSession) -> Date? {
        guard session.phase == .working, !session.live else { return nil }
        return session.lastEventAt.addingTimeInterval(session.tool == nil ? Self.quietAfter : Self.quietAfterDuringTool)
    }
}


//
//  AgentCues.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A short sound, in the agent's creature voice, when a shown session needs you,
//  finishes or fails, and once more if a request still waits. Only for fresh changes
//  (not launch history or background runs). Quiet while locked or asleep, in a Focus,
//  with the session's app in front, and while the screen is shared, recorded or mirrored.
//

import AppKit
import Defaults

@MainActor
final class AgentCues {
    static let shared = AgentCues()

    /// Only a change this recent makes a sound.
    static let fresh: TimeInterval = 10
    static let reminderChoices = [0, 2, 5, 10]

    private var phases: [String: AgentSession.Phase] = [:]
    private var requestIDs: Set<String> = []
    /// When each session (or request without one) last asked with a sound: a request and its
    /// session's state arrive apart, and one wait gets one sound.
    private var asked: [String: Date] = [:]
    /// Waking shows the lock screen: the screen is quiet until it's unlocked, not just awake.
    private var locked = CGSessionCopyCurrentDictionary().map { ($0 as NSDictionary)["CGSSessionScreenIsLocked"] as? Bool == true } ?? false
    private var asleep = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = true }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = false }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = true }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = false }
        })
    }

    func update(_ sessions: [AgentSession], requests: [AgentRequest]) {
        let now = Date()
        defer {
            phases = Dictionary(sessions.map { ($0.id, $0.phase) }, uniquingKeysWith: { first, _ in first })
            requestIDs = Set(requests.map(\.id))
        }
        for session in sessions where session.phase != phases[session.id] && now.timeIntervalSince(session.phaseSince) < Self.fresh {
            guard let cue = Self.cue(for: session.phase), cue != .attention || firstAsk(session.id, now) else { continue }
            play(cue, for: session.provider, host: session.hostBundleID)
        }
        // A request, unless its session just asked (or from a session the island doesn't list).
        for request in requests where !requestIDs.contains(request.id) && now.timeIntervalSince(request.arrived) < Self.fresh
            && firstAsk(request.sessionKey ?? request.id, now) {
            play(.attention, for: request.provider, host: request.hostBundleID)
        }
    }

    private func firstAsk(_ key: String, _ now: Date) -> Bool {
        asked = asked.filter { now.timeIntervalSince($0.value) < Self.fresh }
        guard asked[key] == nil else { return false }
        asked[key] = now
        return true
    }

    func remind(_ session: AgentSession) {
        play(.attention, for: session.provider, host: session.hostBundleID)
    }

    nonisolated static func cue(for phase: AgentSession.Phase) -> CreatureCue? {
        switch phase {
        case .attention: .attention
        case .completed: .done
        case .failed: .failed
        default: nil
        }
    }

    /// Plays a cue as `kind`, ignoring the quiet rules (Settings' preview buttons).
    func preview(_ cue: CreatureCue, for kind: AgentCreatureKind) {
        CreatureSounds.shared.play(cue, for: kind, volume: Defaults[.agentSoundVolume])
    }

    private func play(_ cue: CreatureCue, for provider: AgentProvider, host: String?) {
        guard Defaults[.agentSounds], Self.enabled(cue), !quiet(host: host ?? provider.defaultHostBundleID) else { return }
        CreatureSounds.shared.play(cue, for: AgentCreatureKind(provider: provider), volume: Defaults[.agentSoundVolume])
    }

    private static func enabled(_ cue: CreatureCue) -> Bool {
        switch cue {
        case .attention: Defaults[.agentSoundForAttention]
        case .done: Defaults[.agentSoundForDone]
        case .failed: Defaults[.agentSoundForFailed]
        }
    }

    private func quiet(host: String) -> Bool {
        if locked || asleep || FocusWatcher.shared.isOn == true || ScreenWatch.isCaptured() == true { return true }
        // Its own app in front: the user is already looking at it.
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host
    }
}

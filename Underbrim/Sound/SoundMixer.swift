//
//  SoundMixer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Sound page's levels: a volume per app (0 to 200 %, by bundle ID); an app set away from
//  100 % or muted plays through a MixerSession. Needs System Audio Recording: without it a muting
//  tap would still mute but read silence. An app in a call is left alone unless its slider moves
//  during the call, since a tap can upset its echo cancellation. Event-driven; nothing polls.
//

import AppKit
import CoreAudio
import Defaults
import os

@MainActor @Observable
final class SoundMixer {
    static let shared = SoundMixer()

    struct App: Identifiable, Equatable, Sendable {
        /// Its bundle ID, or `systemSounds`.
        let id: String
        var playing: Bool
        var inCall: Bool
        var tapped: Bool
    }

    enum Access: Equatable { case allowed, denied, notAsked }

    /// The alerts' and sound effects' process.
    nonisolated static let systemSounds = "systemsoundserverd"
    nonisolated static var isAvailable: Bool {
        if #available(macOS 14.4, *) { true } else { false }
    }
    /// Levels within this of 100 % are 100 %.
    nonisolated static let unity = 0.03

    private(set) var apps: [App] = []
    private(set) var access: Access = .notAsked
    private(set) var touchedInCall: Set<String> = []
    /// Levels while they're dragged, saved when the drag ends.
    private var live: [String: Double] = [:]
    @ObservationIgnored private var engineBox: AnyObject?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var defaultsTask: Task<Void, Never>?

    @available(macOS 14.4, *)
    private var engine: MixerEngine? { engineBox as? MixerEngine }

    private init() {}

    func startIfEnabled() {
        guard Self.isAvailable, defaultsTask == nil else { return }
        defaultsTask = Defaults.whenChanged([.soundPageEnabled, .soundBoost, .soundShowSystem, .soundLevels, .soundMuted]) {
            SoundMixer.shared.settingsChanged()
        }
        settingsChanged()
    }

    private func settingsChanged() {
        guard #available(macOS 14.4, *) else { return }
        if Defaults[.soundPageEnabled] {
            if engine == nil { start() }
            push()
        } else if let engine {
            engine.stop()
            engineBox = nil
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            observers = []
            apps = []
        }
    }

    @available(macOS 14.4, *)
    private func start() {
        let engine = MixerEngine()
        engine.onApps = { apps in
            Task { @MainActor in SoundMixer.shared.received(apps) }
        }
        engineBox = engine
        refreshAccess()
        engine.start(plan())
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoundMixer.shared.engine?.rebuild() }
        })
        // Leaving System Settings: the permission may have changed. Taken away, a tap would keep
        // its app muted while reading silence, so the taps go at once.
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.systempreferences"
            else { return }
            MainActor.assumeIsolated { SoundMixer.shared.refreshAccess() }
        })
    }

    private func received(_ apps: [App]) {
        let calls = Set(apps.filter(\.inCall).map(\.id))
        let touched = touchedInCall.intersection(calls)
        if self.apps != apps { self.apps = apps }
        if touched != touchedInCall {
            touchedInCall = touched
            push()
        }
    }

    // MARK: Levels

    func level(of app: String) -> Double {
        let level = live[app] ?? Defaults[.soundLevels][app] ?? 1
        return Defaults[.soundBoost] ? level : min(level, 1)
    }

    func isMuted(_ app: String) -> Bool { Defaults[.soundMuted].contains(app) }

    /// A slider moved (`done` when let go, which saves it). Moving it unmutes.
    func setLevel(_ value: Double, for app: String, done: Bool) {
        let value = abs(value - 1) < Self.unity ? 1 : min(max(value, 0), Defaults[.soundBoost] ? 2 : 1)
        live[app] = value
        if apps.first(where: { $0.id == app })?.inCall == true { touchedInCall.insert(app) }
        if isMuted(app) { Defaults[.soundMuted].removeAll { $0 == app } }
        if done {
            live[app] = nil
            if value == 1 { Defaults[.soundLevels][app] = nil } else { Defaults[.soundLevels][app] = value }
        }
        push()
    }

    func toggleMute(_ app: String) {
        if apps.first(where: { $0.id == app })?.inCall == true { touchedInCall.insert(app) }
        if isMuted(app) { Defaults[.soundMuted].removeAll { $0 == app } } else { Defaults[.soundMuted].append(app) }
        push()
    }

    /// Linear gain for a slider position: squared up to 100 % (so the lower half isn't mostly
    /// silence), then up to +6 dB at 200 %.
    nonisolated static func gain(level: Double, muted: Bool) -> Float {
        if muted || level <= 0 { return 0 }
        return Float(level <= 1 ? level * level : pow(2, level - 1))
    }

    private func plan() -> MixerPlan {
        var gains: [String: Float] = [:]
        let muted = Set(Defaults[.soundMuted])
        for app in Set(Defaults[.soundLevels].keys).union(live.keys).union(muted) {
            let level = level(of: app)
            if muted.contains(app) || abs(level - 1) >= Self.unity {
                gains[app] = Self.gain(level: level, muted: muted.contains(app))
            }
        }
        return MixerPlan(gains: gains, allowed: access == .allowed, touchedInCall: touchedInCall,
                                showsSystemSounds: Defaults[.soundShowSystem])
    }

    func report() {
        guard #available(macOS 14.4, *) else { return }
        engine?.report()
    }

    private func push() {
        guard #available(macOS 14.4, *) else { return }
        engine?.update(plan())
    }

    // MARK: Permission

    /// What macOS says about System Audio Recording for Underbrim; unsure counts as not asked.
    nonisolated static func currentAccess() -> Access {
        switch TCC.preflight?("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: .allowed
        case 1: .denied
        default: .notAsked
        }
    }

    func refreshAccess() {
        let now = Self.currentAccess()
        guard now != access else { return }
        access = now
        push()
    }

    func requestAccess() {
        if !Self.ask() { AudioCaptureManager.requestPermission() }
    }

    /// Asks macOS (no dialog once it's answered), then `answered` with whether it's allowed; false when
    /// Underbrim can't ask this way.
    nonisolated static func ask(_ answered: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        guard let request = TCC.request else { return false }
        request("kTCCServiceAudioCapture" as CFString, nil) { allowed in
            answered(allowed)
            Task { @MainActor in SoundMixer.shared.refreshAccess() }
        }
        return true
    }

    static let privacyPane = SystemSettings.privacy(.audioCapture)

    /// Private calls into TCC (as other audio apps use): without them, Underbrim can't tell and never taps.
    private enum TCC {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        static let preflight: Preflight? = dlsym(handle, "TCCAccessPreflight").map { unsafeBitCast($0, to: Preflight.self) }
        static let request: Request? = dlsym(handle, "TCCAccessRequest").map { unsafeBitCast($0, to: Request.self) }
    }
}

/// What the engine works to: the levels, the permission and who's been touched in a call.
struct MixerPlan: Equatable, Sendable {
    var gains: [String: Float] = [:]
    var allowed = false
    var touchedInCall: Set<String> = []
    var showsSystemSounds = false
}

@available(macOS 14.4, *)
final class MixerEngine: @unchecked Sendable {

    var onApps: (@Sendable ([SoundMixer.App]) -> Void)?

    private struct Process {
        let pid: pid_t
        let app: String?
        var playing: Bool
        var recording: Bool
    }

    private struct Watch: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        var scope = kAudioObjectPropertyScopeGlobal
    }

    private let queue = DispatchQueue(label: "\(bundleIdentifier).sound-mixer", qos: .userInitiated)
    private let log = Logger(subsystem: bundleIdentifier, category: "sound")
    private var plan = MixerPlan()
    private var running = false
    private var processes: [AudioObjectID: Process] = [:]
    private var watches: [Watch: AudioObjectPropertyListenerBlock] = [:]
    private var sessions: [String: MixerSession] = [:]
    private var heard: Set<String> = []
    /// Apps back at 100 %, and when: their session waits a moment, in case the slider moves on.
    private var released: [String: Date] = [:]
    /// Apps whose session couldn't be made, and when: tried again after a while, not on every event.
    private var failed: [String: Date] = [:]
    private var output: AudioObjectID?
    private var published: [SoundMixer.App]?

    func start(_ plan: MixerPlan) {
        queue.async { [self] in
            self.plan = plan
            running = true
            watchSystem()
            outputChanged()
            scan()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            sessions.values.forEach { $0.teardown() }
            sessions = [:]
            for (watch, block) in watches {
                var address = MixerAudio.address(watch.selector, scope: watch.scope)
                AudioObjectRemovePropertyListenerBlock(watch.object, &address, queue, block)
            }
            watches = [:]
            processes = [:]
            published = nil
        }
    }

    func update(_ plan: MixerPlan) {
        queue.async { [self] in
            guard running, plan != self.plan else { return }
            self.plan = plan
            reconcile()
        }
    }

    /// After sleep, or when Core Audio restarted: every session made afresh.
    func rebuild(restarted: Bool = false) {
        queue.async { [self] in
            guard running else { return }
            log.info("rebuilding \(self.sessions.count) sessions")
            sessions.values.forEach { $0.teardown() }
            sessions = [:]
            if restarted {
                // Core Audio forgot every listener, and its objects are new.
                watches = [:]
                processes = [:]
                output = nil
                watchSystem()
                outputChanged()
                scan()
            } else {
                reconcile()
            }
        }
    }

    func report() {
        queue.async { [self] in
            log.info("report: \(self.sessions.count) sessions, allowed \(self.plan.allowed), levels \(self.plan.gains.description, privacy: .public)")
            for app in published ?? [] {
                log.info("report app \(app.id, privacy: .public): playing \(app.playing) call \(app.inCall) tapped \(app.tapped)")
            }
            for (app, session) in sessions.sorted(by: { $0.key < $1.key }) {
                let peaks = session.takePeaks(), cycles = session.cycles
                log.info("report \(app, privacy: .public): gain \(self.plan.gains[app] ?? 1) cycles \(cycles.all) silent \(cycles.silent) in \(peaks.input) out \(peaks.output)")
            }
        }
    }

    // MARK: Watching (on the queue)

    private func watchSystem() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        watch(system, kAudioHardwarePropertyProcessObjectList) { $0.scan() }
        watch(system, kAudioHardwarePropertyDefaultOutputDevice) { $0.outputChanged() }
        watch(system, kAudioHardwarePropertyServiceRestarted) { $0.rebuild(restarted: true) }
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ action: @escaping (MixerEngine) -> Void) {
        let key = Watch(object: object, selector: selector, scope: scope)
        guard watches[key] == nil else { return }
        var address = MixerAudio.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            action(self)
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { watches[key] = block }
    }

    private func unwatch(_ object: AudioObjectID) {
        for (key, block) in watches where key.object == object {
            var address = MixerAudio.address(key.selector, scope: key.scope)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            watches[key] = nil
        }
    }

    private func scan() {
        let now = Set(Microphone.processes())
        for gone in processes.keys where !now.contains(gone) {
            unwatch(gone)
            processes[gone] = nil
        }
        for object in now where processes[object] == nil {
            var pid: pid_t = 0
            MixerAudio.get(object, kAudioProcessPropertyPID, into: &pid)
            let app = Self.app(of: object, pid: pid)
            processes[object] = Process(pid: pid, app: app, playing: false, recording: false)
            guard app != nil else { continue }
            read(object)
            // A process doesn't announce its output or input running (QuickTime, a helper already
            // playing), only running at all and its devices.
            watch(object, kAudioProcessPropertyIsRunning) { $0.read(object); $0.reconcile() }
            watch(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) { $0.read(object); $0.reconcile() }
            watch(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) { $0.read(object); $0.reconcile() }
        }
        reconcile()
    }

    private func read(_ object: AudioObjectID) {
        let playing = MixerAudio.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0 != 0
        let recording = MixerAudio.uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0 != 0
        if let process = processes[object], process.playing != playing || process.recording != recording {
            log.debug("\(process.app ?? "?", privacy: .public) (\(process.pid)): playing \(playing) recording \(recording)")
        }
        processes[object]?.playing = playing
        processes[object]?.recording = recording
    }

    private func outputChanged() {
        if let output { unwatch(output) }
        output = MixerAudio.defaultOutput
        if let output {
            watch(output, kAudioDevicePropertyNominalSampleRate) { $0.rebuild() }
        }
        if !sessions.isEmpty {
            log.info("output changed: \(self.sessions.count) sessions made again")
            sessions.values.forEach { $0.teardown() }
            sessions = [:]
        }
        reconcile()
    }

    private static func app(of object: AudioObjectID, pid: pid_t) -> String? {
        if MixerAudio.string(object, kAudioProcessPropertyBundleID) == SoundMixer.systemSounds { return SoundMixer.systemSounds }
        guard let app = Microphone.appBundleID(pid: pid), app != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    // MARK: Sessions (on the queue)

    private func reconcile() {
        guard running else { return }
        var groups: [String: (processes: [AudioObjectID], playing: Bool, inCall: Bool)] = [:]
        for (object, process) in processes {
            guard let app = process.app, app != SoundMixer.systemSounds || plan.showsSystemSounds else { continue }
            var group = groups[app] ?? ([], false, false)
            group.processes.append(object)
            group.playing = group.playing || process.playing
            group.inCall = group.inCall || process.recording
            groups[app] = group
        }
        heard.formUnion(groups.filter(\.value.playing).keys)
        let device = output.flatMap { MixerAudio.string($0, kAudioDevicePropertyDeviceUID) }
        let now = Date()
        var laterCheck: TimeInterval?

        for (app, group) in groups {
            let processes = group.processes.sorted()
            let gain = plan.gains[app]
            let wanted = plan.allowed && device != nil && (gain != nil || sessions[app] != nil)
                && (!group.inCall || plan.touchedInCall.contains(app))
            guard wanted, let device else {
                end(app)
                continue
            }
            if gain == nil {
                // Back at 100 %: plays at 1 for a moment, then goes.
                sessions[app]?.set(gain: 1)
                let since = released[app] ?? now
                released[app] = since
                if now.timeIntervalSince(since) >= 2 { end(app) } else { laterCheck = 2 }
                continue
            }
            released[app] = nil
            if let session = sessions[app], session.processes == processes, session.deviceUID == device {
                session.set(gain: gain!)
                if group.playing { session.wake() } else { session.rest() }
            } else if now.timeIntervalSince(failed[app] ?? .distantPast) >= 10 {
                sessions[app]?.teardown()
                sessions[app] = MixerSession(app: app, processes: processes, deviceUID: device, gain: gain!, playing: group.playing)
                failed[app] = sessions[app] == nil ? now : nil
                if sessions[app] == nil { laterCheck = 10 }
            }
        }
        for app in sessions.keys where groups[app] == nil { end(app) }

        let apps = groups.compactMap { app, group -> SoundMixer.App? in
            guard group.playing || heard.contains(app) || plan.gains[app] != nil || app == SoundMixer.systemSounds else { return nil }
            return SoundMixer.App(id: app, playing: group.playing, inCall: group.inCall, tapped: sessions[app] != nil)
        }.sorted { $0.id < $1.id }
        if apps != published {
            published = apps
            onApps?(apps)
        }
        if let laterCheck {
            queue.asyncAfter(deadline: .now() + laterCheck + 0.05) { [weak self] in self?.reconcile() }
        }
    }

    private func end(_ app: String) {
        released[app] = nil
        guard let session = sessions.removeValue(forKey: app) else { return }
        let cycles = session.cycles
        session.teardown()
        log.info("released \(app, privacy: .public) after \(cycles.all) cycles, \(cycles.silent) silent")
    }
}

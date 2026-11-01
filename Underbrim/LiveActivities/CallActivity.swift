//
//  CallActivity.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A call in the notch while an app records from the microphone: a green phone for call apps,
//  an orange microphone for anything else, a red one when muted. CoreAudio says when an input
//  starts, so nothing polls until then; only CoreAudio's state is read (no audio, no permission).
//

import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
import Defaults
import Observation
import SwiftUI

@MainActor
@Observable
final class CallActivity {
    static let shared = CallActivity()

    struct Call: Equatable, Sendable {
        let app: String
        let since: Date
        /// A call app (green phone) rather than something else recording (orange microphone).
        let isCall: Bool
    }

    private(set) var call: Call?
    private(set) var muted = false
    /// On a call, shown or hidden: what "never during a call" means.
    var inCall: Bool { call != nil || hiddenApp != nil }
    private(set) var canMute = false
    private(set) var others = 0
    private(set) var input: String?
    /// Hidden from its row's menu: that app's call stays out of the notch until it stops recording.
    @ObservationIgnored private var hiddenApp: String?
    #if DEBUG
    /// Test builds: an app taken to be recording (ub-debug "call:<bundle id>"; "call:" ends it).
    @ObservationIgnored var debugApp: String?
    #endif

    @ObservationIgnored private var listening: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// One listener per audio process, which says when it starts recording on any input.
    @ObservationIgnored private var processes: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var leavingDiscord: Task<Void, Never>?
    /// The Discord whose accessibility tree this switched on for its call.
    @ObservationIgnored private var warmDiscordPID: pid_t?

    /// Apps whose microphone use is a call. Browsers count: in them, it's almost always a meeting.
    nonisolated static let callApps: Set<String> = [
        "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "Cisco-Systems.Spark", "com.webex.meetingmanager", "com.apple.Safari", "com.google.Chrome",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware.Opera",
        "com.apple.Messages", "com.viber.osx", "com.signal.desktop", "org.whispersystems.signal-desktop",
    ]
    /// Apple's own apps that record on purpose; its system services (Siri, dictation) aren't shown.
    nonisolated static let appleRecorders: Set<String> = ["com.apple.FaceTime", "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX",
                                              "com.apple.Safari", "com.apple.PhotoBooth", "com.apple.Messages"]

    nonisolated static func classify(_ app: String) -> Bool? {
        if app.hasPrefix("com.apple."), !appleRecorders.contains(app) { return nil }
        return callApps.contains(app)
    }

    /// The app to show: a call app beats something else recording at the same time (a noise filter, dictation).
    nonisolated static func pick(_ apps: [String]) -> String? {
        apps.first { classify($0) == true } ?? apps.first { classify($0) == false }
    }

    func start() {
        Defaults.whenChanged([.showCallActivity]) { [weak self] in self?.applySetting() }
        applySetting()
    }

    private func applySetting() {
        if Defaults[.showCallActivity] {
            listen()
            refresh()
        } else {
            stopListening()
            poll?.cancel()
            poll = nil
            call = nil
            // A call hidden until it ends would otherwise count as a call for good (prayer alerts stay quiet).
            hiddenApp = nil
            muted = false
            warmDiscord(false)
        }
    }

    func refresh() {
        // A callback queued before the switch went off changes nothing.
        guard Defaults[.showCallActivity] else { return }
        var recording = Microphone.appsUsingInput()
        #if DEBUG
        if let debugApp { recording.insert(debugApp, at: 0) }
        #endif
        warmDiscord(recording.contains(Self.discord))
        // Hidden until its app stops recording; another app's call still shows.
        if let hiddenApp, !recording.contains(hiddenApp) { self.hiddenApp = nil }
        if let app = Self.pick(recording.filter { $0 != hiddenApp }) {
            if call?.app != app { call = Call(app: app, since: Date(), isCall: Self.classify(app) == true) }
            muted = Microphone.isMuted() ?? false
            canMute = Microphone.canMute()
            others = recording.count - 1
            input = Microphone.inputName
            startPolling()
        } else {
            call = nil
            muted = false
            poll?.cancel()
            poll = nil
        }
    }

    func hide() {
        hiddenApp = call?.app
        refresh()
    }

    nonisolated static let discord = "com.hnc.Discord"

    nonisolated static func canLeave(_ app: String) -> Bool {
        app == discord || leaveShortcut(for: app) != nil
    }

    /// The app's dependable leave shortcut: Teams hangs up, Zoom asks to leave or end; others have none.
    nonisolated static func leaveShortcut(for app: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        switch app {
        case "us.zoom.xos": (13, .maskCommand)  // ⌘W
        case "com.microsoft.teams2": (4, [.maskCommand, .maskShift])  // ⌘⇧H
        default: nil
        }
    }

    func leave() {
        if call?.app == Self.discord { return leaveDiscord() }
        guard let app = call?.app, let shortcut = Self.leaveShortcut(for: app),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.processIdentifier,
              CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return }
        AppInfo.activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: down)
                event?.flags = shortcut.flags
                event?.postToPid(pid)
            }
        }
    }

    /// Discord acts on a press only once its accessibility tree is built, about two seconds after it's
    /// asked for (AXManualAccessibility), and a hidden Discord doesn't build it at all. So it's asked for
    /// when a Discord call starts, and Leave then lands at once, whatever Discord's window is doing; it
    /// goes off when the call ends (it costs Discord no measurable CPU meanwhile). VoiceOver keeps it on
    /// itself, so with VoiceOver running it's left alone.
    private func warmDiscord(_ inCall: Bool) {
        guard inCall else {
            if let pid = warmDiscordPID {
                warmDiscordPID = nil
                Self.setTree(of: pid, on: false)
            }
            return
        }
        guard !NSWorkspace.shared.isVoiceOverEnabled, AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.discord).first?.processIdentifier,
              pid != warmDiscordPID else { return }
        warmDiscordPID = pid
        Self.setTree(of: pid, on: true)
    }

    /// In order and off the main thread: a hung Discord holds an Accessibility call for seconds.
    nonisolated private static let treeQueue = DispatchQueue(label: "Underbrim.DiscordTree", qos: .utility)

    nonisolated private static func setTree(of pid: pid_t, on: Bool) {
        treeQueue.async { AXUIElementCreateApplication(pid).set("AXManualAccessibility", on) }
    }

    /// Discord has no leave shortcut, so its Disconnect button is pressed through Accessibility.
    private func leaveDiscord() {
        // One at a time: a second click would only press again, and could bring Discord up twice.
        guard leavingDiscord == nil,
              let discord = NSRunningApplication.runningApplications(withBundleIdentifier: Self.discord).first else { return }
        guard AXIsProcessTrusted() else {
            // Asks for Accessibility; meanwhile Discord comes forward so the call can be left there.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return AppInfo.activate(Self.discord)
        }
        warmDiscord(true)  // normally done when the call started
        let pid = discord.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        leavingDiscord = Task { @MainActor in
            defer { leavingDiscord = nil }
            let front = NSWorkspace.shared.frontmostApplication
            let start = ContinuousClock.now
            var pressed = false, closedLayer = false, broughtUp = false, left = false
            // Pressed until it goes after a press, or Discord stops recording (also when the call ends by
            // itself): until its tree is built, a press does nothing.
            while ContinuousClock.now < start + .seconds(8), !discord.isTerminated {
                guard Microphone.appsUsingInput().contains(Self.discord) else { left = true; break }
                let elapsed = ContinuousClock.now - start
                if let button = await Self.button(in: app, labelled: "Disconnect") {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                    pressed = true
                } else if pressed {
                    left = true
                    break
                } else if !closedLayer, elapsed > .milliseconds(300), let close = await Self.button(in: app, labelled: "Close") {
                    // Discord's Settings (or another layer) takes the voice panel away: closed to bring it back.
                    closedLayer = true
                    AXUIElementPerformAction(close, kAXPressAction as CFString)
                } else if elapsed > .seconds(3), Self.hasWindowOnScreen(pid) {
                    break  // not there, even once a fresh tree would be built
                }
                // Not left yet with no window on screen: a hidden Discord never builds its tree, so it
                // comes up for a moment and goes again after.
                if !broughtUp, elapsed > .milliseconds(600), !Self.hasWindowOnScreen(pid) {
                    broughtUp = true
                    AppInfo.activate(Self.discord)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if left {
                if broughtUp {
                    discord.hide()
                    front?.activate()
                }
            } else if !discord.isTerminated {
                // Only English Discord's label is known; in another language Discord comes forward so the call can be left there.
                AppInfo.activate(Self.discord)
            }
        }
    }

    /// One of the app's windows is on screen (not in the menu bar, hidden or on another Space); no permission needed.
    nonisolated static func hasWindowOnScreen(_ pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }
    }

    /// The first button with this label in the app's windows, off the main thread. Chromium's own search
    /// (VoiceOver's) finds it in a millisecond however long the page; a walk is the fallback.
    nonisolated private static func button(in app: AXUIElement, labelled label: String) async -> AXUIElement? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let isIt = { (element: AXUIElement) in
                    element.string(kAXRoleAttribute) == kAXButtonRole && element.string(kAXDescriptionAttribute) == label
                }
                // Its text match is loose ("Mute" finds the Mute switch too), so the results are checked.
                let query = ["AXSearchKey": "AXButtonSearchKey", "AXSearchText": label, "AXResultsLimit": 10,
                             "AXDirection": "AXDirectionNext"] as CFDictionary
                for area in webAreas(in: app) {
                    var found: CFTypeRef?
                    AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString, query, &found)
                    if let button = (found as? [AXUIElement])?.first(where: isIt) { return done.resume(returning: button) }
                }
                done.resume(returning: app.first(where: isIt))
            }
        }
    }

    /// The web pages in the app's windows (Electron's content), not looking inside them.
    nonisolated private static func webAreas(in app: AXUIElement) -> [AXUIElement] {
        var queue = (app[kAXWindowsAttribute] as? [AXUIElement]) ?? [], areas: [AXUIElement] = [], index = 0
        while index < queue.count, index < 200 {
            let element = queue[index]
            index += 1
            if element.string(kAXRoleAttribute) == "AXWebArea" { areas.append(element) } else { queue += element.childElements }
        }
        return areas
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: CoreAudio listeners

    private func listen() {
        guard listening.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        add(system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.watchProcesses() }
        // A new default input: listen to its mute instead, once this callback has returned.
        add(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, Defaults[.showCallActivity] else { return }
                    self.stopListening()
                    self.listen()
                }
            }
        }
        if let input = Microphone.defaultInput {
            add(input, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
            // Recording starts or stops: an app recording through a child process it already had running
            // (Discord) never triggers its process's notification, but the microphone always says so.
            add(input, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        watchProcesses()
    }

    private func watchProcesses() {
        let current = Set(Microphone.processes())
        for (process, block) in processes where !current.contains(process) {
            var address = Self.recording
            AudioObjectRemovePropertyListenerBlock(process, &address, .main, block)
            processes[process] = nil
        }
        for process in current where processes[process] == nil {
            var address = Self.recording
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(process, &address, .main, block) == noErr { processes[process] = block }
        }
    }

    private static let recording = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, also: (@MainActor () -> Void)? = nil) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                also?()
                self?.refresh()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listening.append((object, address, block))
        }
    }

    private func stopListening() {
        for (object, address, block) in listening {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listening = []
        for (process, block) in processes {
            var address = Self.recording
            AudioObjectRemovePropertyListenerBlock(process, &address, .main, block)
        }
        processes = [:]
    }
}

extension CallActivity.Call {
    var tint: Color { isCall ? .green : .orange }
    var symbol: String { isCall ? "phone.fill" : "mic.fill" }

    var spokenText: String {
        let name = AppInfo.name(bundleID: app) ?? app
        return isCall ? String(localized: "On a call in \(name)") : String(localized: "\(name) is using the microphone")
    }
}

struct CallLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let call: CallActivity.Call
    private var activity: CallActivity { .shared }

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            Image(systemName: call.symbol)
                .font(.notchSymbol(size: 12))
                .foregroundStyle(call.tint)
                .frame(width: itemSize, height: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            Group {
                if activity.muted {
                    Image(systemName: "mic.slash.fill").font(.notchSymbol(size: 12)).foregroundStyle(.red)
                } else {
                    Text(call.since, style: .timer)
                        .font(.notchCaption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(call.tint)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .frame(width: itemSize + TimerLiveActivity.extraWidth, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(call.spokenText) + Text(activity.muted ? String(localized: ", muted") : ""))
    }
}

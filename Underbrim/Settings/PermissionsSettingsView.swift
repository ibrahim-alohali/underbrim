//
//  PermissionsSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings › Permissions: everything Underbrim may use, what each is for, whether it's allowed, and
//  a button that asks or opens System Settings. Nothing is asked until a button is pressed.
//  Automation lists only the apps macOS has already asked about.
//

import AVFoundation
import AppKit
import CoreBluetooth
import CoreLocation
import EventKit
import SwiftUI

@MainActor @Observable
final class PermissionStates: NSObject, CLLocationManagerDelegate {
    /// One for the page and its island, so an answer given on the page shows on both.
    static let shared = PermissionStates()

    enum State: Equatable {
        case allowed, denied, notAsked
        case partly(String)
        case restricted
    }

    private(set) var accessibility = State.notAsked
    private(set) var audio = State.notAsked
    private(set) var calendars = State.notAsked
    private(set) var reminders = State.notAsked
    private(set) var camera = State.notAsked
    private(set) var location = State.notAsked
    private(set) var bluetooth = State.notAsked
    private(set) var automation: [(name: String, allowed: Bool)] = []

    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private var bluetoothCheck: CBCentralManager?

    override init() {
        super.init()
        locations.delegate = self
    }

    var all: [State] { [accessibility, audio, calendars, reminders, camera, location, bluetooth] }
    var allowedCount: Int { all.filter { $0 == .allowed }.count }

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .allowed : .denied
        SoundMixer.shared.refreshAccess()
        audio = switch SoundMixer.shared.access {
        case .allowed: .allowed
        case .denied: .denied
        case .notAsked: .notAsked
        }
        calendars = Self.state(EKEventStore.authorizationStatus(for: .event))
        reminders = Self.state(EKEventStore.authorizationStatus(for: .reminder))
        camera = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        default: .notAsked
        }
        location = switch locations.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        case .restricted: .restricted
        default: .allowed
        }
        bluetooth = switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        default: .notAsked
        }
        Task {
            let found = await Self.automationStates()
            if found.map(\.name) != automation.map(\.name) || found.map(\.allowed) != automation.map(\.allowed) { automation = found }
        }
    }

    private static func state(_ status: EKAuthorizationStatus) -> State {
        switch status {
        case .fullAccess: .allowed
        case .writeOnly: .partly(String(localized: "Add only"))
        case .denied: .denied
        case .restricted: .restricted
        default: .notAsked
        }
    }

    // MARK: Asking

    func askAccessibility() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
        SystemSettings.open(.accessibility)
    }

    func askAudio() { SoundMixer.shared.requestAccess() }

    func askCalendars() {
        Task {
            await CalendarManager.shared.checkCalendarAuthorization()
            refresh()
        }
    }

    func askReminders() {
        Task {
            _ = try? await EKEventStore().requestFullAccessToReminders()
            RemindersModel.shared.refresh()
            refresh()
        }
    }

    func askCamera() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            refresh()
        }
    }

    func askLocation() { locations.requestWhenInUseAuthorization() }

    func askBluetooth() {
        bluetoothCheck = CBCentralManager(delegate: nil, queue: nil)
        Task {
            for _ in 0..<60 where CBManager.authorization == .notDetermined { try? await Task.sleep(for: .seconds(1)) }
            bluetoothCheck = nil
            refresh()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in refresh() }
    }

    // MARK: Automation

    /// Apps Underbrim scripts: the music apps it controls, and the terminals whose tab it selects.
    private static let scripted = [MediaAppBundleID.appleMusic, MediaAppBundleID.spotify] + AgentHostApps.scriptableTerminals.sorted()

    /// Only what macOS knows without asking; an app that isn't open can't be checked.
    private static func automationStates() async -> [(name: String, allowed: Bool)] {
        let running = scripted.filter { id in NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id } }
        let names = Dictionary(uniqueKeysWithValues: running.map { id in
            (id, AppInfo.name(bundleID: id) ?? id)
        })
        return await Task.detached(priority: .utility) {
            running.compactMap { id -> (name: String, allowed: Bool)? in
                var target = AEAddressDesc()
                let bytes = Array(id.utf8)
                guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr else { return nil }
                defer { AEDisposeDesc(&target) }
                let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
                switch Int(status) {
                case Int(noErr): return (names[id] ?? id, true)
                case errAEEventNotPermitted: return (names[id] ?? id, false)
                default: return nil  // not asked yet, or not open
                }
            }
        }.value
    }
}

struct PermissionsSettingsView: View {
    private let states = PermissionStates.shared

    var body: some View {
        Form {
            Section {
                row(AccessibilityPermission.displayName, symbol: AccessibilityPermission.systemImageName,
                    unlocks: String(localized: "Volume, brightness and keyboard light in the notch, Focus, Caps Lock, notification banners, iPhone Live Activities, and Quick Launch hiding an app's windows."),
                    state: states.accessibility, pane: .accessibility, ask: states.askAccessibility)
                    .settingsItem("Accessibility")
                row(String(localized: "System Audio Recording"), symbol: "waveform",
                    unlocks: String(localized: "The Sound page's volume for each app, and the music waveform. Nothing is recorded or saved."),
                    state: states.audio, pane: .audioCapture, ask: states.askAudio)
                    .settingsItem("System Audio Recording")
                row(String(localized: "Calendars"), symbol: "calendar",
                    unlocks: String(localized: "Meeting countdowns, and today's events on Home."),
                    state: states.calendars, pane: .calendars, ask: states.askCalendars)
                    .settingsItem("Calendars")
                row(String(localized: "Reminders"), symbol: "checklist",
                    unlocks: String(localized: "The Reminders widget."),
                    state: states.reminders, pane: .reminders, ask: states.askReminders)
                    .settingsItem("Reminders")
                row(String(localized: "Camera"), symbol: "web.camera",
                    unlocks: String(localized: "The Mirror, while you have it open. Nothing is recorded."),
                    state: states.camera, pane: .camera, ask: states.askCamera)
                    .settingsItem("Camera")
                row(String(localized: "Location"), symbol: "location",
                    unlocks: String(localized: "Prayer times where you are. You can choose a town instead."),
                    state: states.location, pane: .location, ask: states.askLocation)
                    .settingsItem("Location")
                row(String(localized: "Bluetooth"), symbol: "headphones",
                    unlocks: String(localized: "Your headphones' battery levels."),
                    state: states.bluetooth, pane: .bluetooth, ask: states.askBluetooth)
                    .settingsItem("Bluetooth")
            } header: {
                SettingsPageHeader(tab: .permissions, section: "On this Mac")
            } footer: {
                Text("Underbrim asks for each one only when you use what needs it, or press Allow here. Change any of them in System Settings › Privacy & Security.")
            }
            Section {
                LabeledContent {
                    Button("Open System Settings") { SystemSettings.open(.automation) }
                } label: {
                    Label {
                        Text("Automation")
                        Text("Controls for Music and Spotify, and a coding session's own tab in Terminal or iTerm2. macOS asks once for each app.")
                    } icon: {
                        Image(systemName: "gearshape.2")
                    }
                }
                .settingsItem("Automation")
                ForEach(states.automation, id: \.name) { app in
                    LabeledContent(app.name) { stateLabel(app.allowed ? .allowed : .denied) }
                }
            } header: {
                Text("Other apps")
            }
        }
        .navigationTitle("Permissions")
        .onAppear { states.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in states.refresh() }
        // The answer to a question macOS asked while Settings stayed in front.
        .onReceive(XPCHelperClient.shared.$accessibilityGranted) { _ in states.refresh() }
    }

    private func row(_ title: String, symbol: String, unlocks: String, state: PermissionStates.State, pane: SystemSettings.Privacy,
                     ask: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                stateLabel(state)
                if state == .notAsked {
                    Button("Allow…", action: ask)
                } else {
                    Button("Open System Settings") { SystemSettings.open(pane) }
                }
            }
        } label: {
            Label {
                Text(title)
                Text(unlocks)
            } icon: {
                Image(systemName: symbol)
            }
        }
    }

    /// The state in words, with a symbol: never colour alone.
    @ViewBuilder private func stateLabel(_ state: PermissionStates.State) -> some View {
        switch state {
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
        case .notAsked:
            Label("Not asked yet", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .partly(let words):
            Label(words, systemImage: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .restricted:
            Label("Blocked by a profile", systemImage: "lock.fill").foregroundStyle(.secondary)
        }
    }
}

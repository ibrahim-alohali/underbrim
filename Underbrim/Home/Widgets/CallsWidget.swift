//
//  CallsWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Calls in any app: which app is using the microphone, and a mute switch for the input itself,
//  both from Core Audio's own state (no audio captured, no permission needed). Muting the input
//  silences the microphone for every app, though the meeting app's own mute button won't show it.
//

import CoreAudio
import SwiftUI

enum Microphone {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Bundle IDs of the apps recording from an input now, each once: a browser's or Electron
    /// app's helper process counts as its app.
    static func appsUsingInput() -> [String] {
        var apps: [String] = []
        for process in processes() {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var input = Self.address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(process, &input, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  let app = appBundleID(pid: pid), app != Bundle.main.bundleIdentifier, !apps.contains(app) else { continue }
            apps.append(app)
        }
        return apps
    }

    static func processes() -> [AudioObjectID] {
        guard #available(macOS 14.4, *) else { return [] }
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes
    }

    /// The outermost app bundle in its path (helpers live inside their app), else the app macOS
    /// holds responsible for it (WebKit's media process, for Safari).
    static func appBundleID(pid: pid_t) -> String? {
        for candidate in [pid, responsibleFor.map { $0(pid) }].compactMap({ $0 }) where candidate > 0 {
            if let path = ProcessLineage.info(candidate)?.path, let bundle = ProcessLineage.bundlePath(in: path),
               let id = Bundle(path: bundle)?.bundleIdentifier { return id }
        }
        return nil
    }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    /// A private libsystem call (what Activity Monitor uses); without it, only paths are used.
    private static let responsibleFor: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    static var defaultInput: AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    static var inputName: String? {
        defaultInput.flatMap { AudioRouteManager.stringProperty($0, kAudioObjectPropertyName) }
    }

    static func isMuted() -> Bool? {
        guard let device = defaultInput else { return nil }
        var address = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    /// Some inputs report a mute switch but won't take a change.
    static func canMute() -> Bool {
        guard let device = defaultInput else { return false }
        var address = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard canMute(), let device = defaultInput else { return false }
        var address = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

struct CallsWidget: View {
    @State private var apps: [String] = []
    @State private var muted: Bool?
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                aloneLayout
            } else {
                home
            }
        }
        .task {
            while !Task.isCancelled {
                apps = Microphone.appsUsingInput()
                muted = Microphone.canMute() ? Microphone.isMuted() : nil
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var aloneLayout: some View {
        AloneFrame(widget: .calls) {
            if let app = apps.first {
                let name = AppInfo.name(bundleID: app) ?? app
                Button { AppInfo.activate(app) } label: {
                    HStack(spacing: 6) {
                        AppIconView(bundleID: app, size: 18)
                        Text(name).font(.notchTitle).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open \(name)"))
                .accessibilityLabel(String(localized: "Open \(name)"))
            } else {
                AloneTitle(symbol: "mic.slash", title: String(localized: "Microphone"))
            }
        } trailing: {
            if let muted {
                MicMuteButton(muted: muted, side: 22) {
                    if Microphone.setMuted(!muted) { self.muted = Microphone.isMuted() }
                }
            }
        } row: {
            Text(apps.isEmpty ? String(localized: "No app is using the microphone")
                 : apps.count > 1 ? String(localized: "and \(apps.count - 1) more using the microphone")
                 : String(localized: "Using the microphone"))
                .font(.notchCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var home: some View {
        HStack(spacing: 10) {
            if let app = apps.first {
                Button { AppInfo.activate(app) } label: {
                    AppIconView(bundleID: app, size: 36)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open \(AppInfo.name(bundleID: app) ?? app)"))
                .accessibilityLabel(String(localized: "Open \(AppInfo.name(bundleID: app) ?? app)"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name(bundleID: app) ?? app).font(.notchBody.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(apps.count > 1 ? String(localized: "and \(apps.count - 1) more using the microphone") : String(localized: "Using the microphone"))
                        .font(.notchCaption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Image(systemName: "mic.slash").font(.notchSymbol(size: 16)).foregroundStyle(.secondary).frame(width: 36)
                    .accessibilityHidden(true)
                Text(String(localized: "No app is using the microphone")).font(.notchCaption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let muted {
                MicMuteButton(muted: muted, side: 32) {
                    if Microphone.setMuted(!muted) { self.muted = Microphone.isMuted() }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct MicMuteButton: View {
    let muted: Bool
    let side: CGFloat
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                .font(.notchSymbol(size: side * 0.44))
                .foregroundStyle(muted ? .red : .white)
                .frame(width: side, height: side)
                .background(.white.opacity(muted ? 0.16 : 0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(muted ? String(localized: "Unmute the microphone") : String(localized: "Mute the microphone for every app"))
        .accessibilityLabel(String(localized: "Microphone"))
        .accessibilityValue(muted ? String(localized: "Muted") : String(localized: "On"))
        .accessibilityHint(String(localized: "Mutes or unmutes the microphone for every app"))
    }
}

struct CallRow: View {
    static let height: CGFloat = 48
    let call: CallActivity.Call
    private var activity: CallActivity { .shared }
    @State private var iconHovered = false

    var body: some View {
        let name = AppInfo.name(bundleID: call.app) ?? call.app
        HStack(spacing: 10) {
            Button { AppInfo.activate(call.app) } label: {
                AppIconView(bundleID: call.app, size: 30)
                    .padding(3)
                    .background(.white.opacity(iconHovered ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { iconHovered = $0 }
            .help(String(localized: "Open \(name)"))
            .accessibilityLabel(String(localized: "Open \(name)"))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.notchTitle).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(activity.muted ? Color.red : call.tint).frame(width: 6, height: 6)
                    Text(call.since, style: .timer).monospacedDigit()
                    if let detail {
                        Text(verbatim: "·")
                        Text(detail).lineLimit(1)
                    }
                }
                .font(.notchCaption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("Hide Until the Call Ends")) { activity.hide() }
            Spacer(minLength: 8)
            if activity.canMute {
                MicMuteButton(muted: activity.muted, side: 30) {
                    Microphone.setMuted(!activity.muted)
                    activity.refresh()
                }
            }
            if CallActivity.canLeave(call.app) {
                Button { activity.leave() } label: {
                    Label(String(localized: "Leave"), systemImage: "phone.down.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(Color(red: 0.92, green: 0.23, blue: 0.2), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Leave the call"))
            }
        }
        .padding(.horizontal, 10)
        // Its own height on its own; beside a card, that card's.
        .frame(minHeight: Self.height, maxHeight: .infinity)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
        .contextMenu {
            Button(String(localized: "Hide Until the Call Ends")) { activity.hide() }
        }
    }

    private var detail: String? {
        if activity.muted { return String(localized: "Muted") }
        if activity.others > 0 { return String(localized: "and \(activity.others) more") }
        return activity.input
    }
}

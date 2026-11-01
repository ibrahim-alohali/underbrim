//
//  LiveActivitySettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings › Live Activities. A switch that needs Accessibility asks for it when it's turned on.
//

import AppKit
import Defaults
import SwiftUI

struct LiveActivitySettingsView: View {
    @Default(.showPhoneActivities) private var showPhoneActivities
    @Default(.showDeliveryUpdates) private var showDeliveryUpdates
    @Default(.deliveryApps) private var deliveryApps
    @Default(.showCapsLock) private var showCapsLock
    @Default(.showFocusChanges) private var showFocusChanges
    @Default(.showBatteryIndicator) private var batteryOn
    @Default(.showPowerStatusNotifications) private var powerNotes
    @Default(.showDownloadActivity) private var downloadsOn
    @ObservedObject private var xpc = XPCHelperClient.shared
    @State private var newApp = ""

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showPhoneActivities) {
                    Text("Show your iPhone's Live Activities")
                }
                .settingsItem("Show your iPhone's Live Activities")
                .disabled(!PhoneActivityStore.isSupported)
                if showPhoneActivities, MenuBarActivityReader.iPhoneActivitiesEnabled == false {
                    Label {
                        Text("macOS isn't showing your iPhone's Live Activities. Turn on Allow Live Activities from iPhone in System Settings › Notifications.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Open Notifications Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            } header: {
                SettingsPageHeader(tab: .activities, section: "From your iPhone", info: PhoneActivityStore.isSupported
                                   ? ["A delivery, a ride, a game or a flight your iPhone shows as a Live Activity appears in the notch; click it for the details. macOS shows them in the menu bar once iPhone Mirroring is set up, and Underbrim reads them from there with \(AccessibilityPermission.displayName). Only text is shared, and it stays on this Mac."]
                                   : [])
            } footer: {
                if !PhoneActivityStore.isSupported {
                    HelpText("Needs macOS 26 or later.")
                }
            }

            Section {
                Defaults.Toggle(key: .showDeliveryUpdates) {
                    Text("Follow deliveries from their notifications")
                }
                .settingsItem("Follow deliveries from their notifications")
                if showDeliveryUpdates {
                    ForEach(deliveryApps, id: \.self) { app in
                        HStack {
                            Text(app)
                            Spacer()
                            Button("Remove", role: .destructive) { deliveryApps.removeAll { $0 == app } }
                                .accessibilityLabel(String(localized: "Remove \(app)"))
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("App name", text: $newApp, prompt: Text("App name, as its notifications show it"))
                            .onSubmit(addApp)
                        Button("Add", action: addApp)
                            .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                SettingsLabel("Deliveries", info: "For delivery apps without Live Activities, such as HungerStation, Jahez and Ninja. Their notifications reach this Mac from your iPhone with iPhone Mirroring; each order's newest status stays in the notch until it's delivered, or for two quiet hours. Their banners show in the notch, and this uses \(AccessibilityPermission.displayName) too.")
            }

            Section {
                Defaults.Toggle(key: .showFocusChanges) {
                    Text("Show Focus turning on and off")
                }
                .disabled(!FocusWatcher.isSupported)
                .settingsItem("Show Focus turning on and off")
            } header: {
                SettingsLabel("Focus", info: FocusWatcher.isSupported
                              ? ["Like the iPhone: the Focus's symbol in its colour with On, in grey with Off. Underbrim reads macOS's Focus banner with \(AccessibilityPermission.displayName)."]
                              : [])
            } footer: {
                if !FocusWatcher.isSupported {
                    HelpText("Needs macOS 27 or later.")
                }
            }

            Section {
                Defaults.Toggle(key: .showCallActivity) {
                    Text("Show calls")
                }
                .settingsItem("Show calls")
            } header: {
                SettingsLabel("Calls", info: "While an app uses the microphone, the closed notch shows how long: a green phone for calls (FaceTime, Zoom, Teams, WhatsApp, a meeting in your browser…), an orange microphone for anything else that records. Click it for the mute switch. No permission needed.")
            }

            Section {
                Defaults.Toggle(key: .showUnlockAnimation) {
                    Text("Padlock opening when you unlock")
                }
                .settingsItem("Padlock opening when you unlock")
                Defaults.Toggle(key: .showCapsLock) {
                    Text("Caps Lock on and off")
                }
                .settingsItem("Caps Lock on and off")
            } header: {
                Text("Smaller touches")
            } footer: {
                HelpText("Caps Lock uses \(AccessibilityPermission.displayName) to notice the key.")
            }

            BatterySettingsSection()
            DownloadSettingsSection()

            if !xpc.accessibilityGranted && wantsAccess {
                Section { AccessibilityRequiredRow() }
            }

            if batteryOn || powerNotes {
                MoreInAdvanced(.battery)
            } else if downloadsOn {
                MoreInAdvanced(.downloads)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Live Activities")
        .onChange(of: wantsAccess) { _, wants in
            if wants, !xpc.accessibilityGranted {
                Task { _ = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true) }
            }
        }
    }

    private var wantsAccess: Bool { showPhoneActivities || showDeliveryUpdates || (showFocusChanges && FocusWatcher.isSupported) || showCapsLock }

    private func addApp() {
        let name = newApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !deliveryApps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        deliveryApps.append(name)
        newApp = ""
    }
}

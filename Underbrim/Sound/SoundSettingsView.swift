//
//  SoundSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings › Sound: the Sound page, its range and tiles, and the permission it needs.
//

import Defaults
import SwiftUI

struct SoundSettingsView: View {
    private let mixer = SoundMixer.shared
    @Default(.soundPageEnabled) private var pageOn
    @Default(.soundLevels) private var levels
    @Default(.soundMuted) private var muted

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .soundPageEnabled) {
                    SettingsLabel("Show the Sound page", info: "A page in the open notch with a volume for each app that plays sound.")
                }
                .settingsItem("Show the Sound page")
                if pageOn {
                    Defaults.Toggle(key: .soundBoost) {
                        SettingsLabel("Allow levels above 100 %", info: "Up to 200 %, with a limiter so loud parts don't distort.")
                    }
                    .settingsItem("Allow levels above 100 %")
                    Defaults.Toggle(key: .soundKeepPaused) {
                        SettingsLabel("Keep paused apps", info: "An app that played keeps its tile after it pauses, until it quits.")
                    }
                    .settingsItem("Keep paused apps")
                    Defaults.Toggle(key: .soundShowSystem) {
                        SettingsLabel("Show system sounds", info: "Alerts and sound effects get a tile of their own.")
                    }
                    .settingsItem("Show system sounds")
                    if !levels.isEmpty || !muted.isEmpty {
                        LabeledContent {
                            Button("Reset") {
                                levels = [:]
                                muted = []
                            }
                        } label: {
                            SettingsLabel("Every app at 100 %", info: "Forgets the levels and mutes you set.")
                        }
                    }
                }
            } header: {
                Text("Sound page")
            }
            if pageOn {
                Section {
                    LabeledContent {
                        switch mixer.access {
                        case .allowed:
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .denied:
                            Button("Open System Settings") { NSWorkspace.shared.open(SoundMixer.privacyPane) }
                        case .notAsked:
                            Button("Allow…") { mixer.requestAccess() }
                        }
                    } label: {
                        Text("System Audio Recording")
                        Text(mixer.access == .denied
                             ? String(localized: "Off: turn on Underbrim under System Audio Recording Only. Until then, every app plays as it is.")
                             : String(localized: "Lets Underbrim change an app's sound. Nothing is recorded or saved."))
                    }
                    .settingsItem("System Audio Recording")
                } header: {
                    SettingsLabel("Permission", info: "An app you change plays through a private tap at its level, until it's back at 100 %. Apps in a call are left alone unless you move their slider, as a change can upset the call's echo cancellation.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { mixer.refreshAccess() }
        .navigationTitle("Sound")
    }
}

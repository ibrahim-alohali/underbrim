//
//  OSDSettingsView.swift
//  Underbrim
//
//  Created by Alexander on 2026-02-07.
//

import SwiftUI
import Defaults
import CoreGraphics

struct OSDSettings: View {
    // Defaults-backed storage
    @Default(.osdReplacement) private var osdReplacementDefault
    @ObservedObject private var xpcClient = XPCHelperClient.shared

    var body: some View {
        Form {
            if osdReplacementDefault {
                Section {
                    Defaults.Toggle(key: .systemEventIndicatorUseAccent) {
                        Text("Use accent color")
                    }
                    .settingsItem("Use accent color")
                    Defaults.Toggle(key: .showOpenNotchOSD) {
                        Text("Show OSD in open notch")
                    }
                    .settingsItem("Show OSD in open notch")
                } header: {
                    SettingsPageHeader(tab: .osd, isOn: $osdReplacementDefault, section: "Appearance")
                }

                if !xpcClient.helperAvailable || !xpcClient.accessibilityGranted {
                    Section {
                        if !xpcClient.helperAvailable {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title)
                                    .foregroundStyle(.yellow)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "Helper Service Unavailable"))
                                        .font(.headline)
                                    Text(String(localized: "The background helper crashed or was closed by macOS. It restarts automatically on the next OSD event."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        if !xpcClient.accessibilityGranted {
                            AccessibilityRequiredRow()
                                .padding(.vertical, 4)
                        }
                    }
                }

                MoreInAdvanced(.osd)
            } else {
                Section {
                } header: {
                    SettingsPageHeader(tab: .osd, isOn: $osdReplacementDefault)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Volume & Brightness")
    }
}

/// Advanced › Volume & Brightness: which app controls each, and the Option key.
struct OSDAdvancedSettings: View {
    @Default(.optionKeyAction) private var optionKeyActionDefault
    @Default(.osdBrightnessSource) private var osdBrightnessSourceDefault
    @Default(.osdVolumeSource) private var osdVolumeSourceDefault

    var body: some View {
        Section {
            Picker(selection: $osdBrightnessSourceDefault) {
                ForEach(OSDControlSource.allCases) { source in
                    Text(source.localizedString).tag(source)
                }
            } label: {
                if osdBrightnessSourceDefault == .builtin {
                    SettingsLabel("Brightness Source", info: "Only Apple displays are supported. In multi-display setups, the brightness OSD appears on the active display if supported, or on another supported display otherwise.")
                } else {
                    Text("Brightness Source")
                }
            }
            .settingsItem("Brightness Source")
            if osdBrightnessSourceDefault == .betterDisplay && !BetterDisplayManager.shared.isBetterDisplayAvailable {
                HelpText("BetterDisplay is not installed or not running")
            }
            if osdBrightnessSourceDefault == .lunar && !LunarManager.shared.isLunarAvailable {
                HelpText("Lunar is not installed or not reachable")
            }

            Picker("Volume Source", selection: $osdVolumeSourceDefault) {
                // Lunar does not support volume control so hide it from the picker
                ForEach(OSDControlSource.allCases.filter { $0 != .lunar }) { source in
                    Text(source.localizedString).tag(source)
                }
            }
            .settingsItem("Volume Source")
            if osdVolumeSourceDefault == .betterDisplay && !BetterDisplayManager.shared.isBetterDisplayAvailable {
                HelpText("BetterDisplay is not installed or not running")
            }

            LabeledContent {
                Text(OSDControlSource.builtin.localizedString)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsLabel("Keyboard Source", info: "Keyboard brightness currently supports the built-in source only.")
            }
            .settingsItem("Keyboard Source")

            Picker(selection: $optionKeyActionDefault) {
                ForEach(OptionKeyAction.allCases) { action in
                    Text(action.localizedString).tag(action)
                }
            } label: {
                SettingsLabel("Option (⌥) Key Behavior", info: "Define what happens when you hold the Option key while pressing media keys.")
            }
            .settingsItem("Option (⌥) Key Behavior")
        } header: {
            AdvancedHeader(area: .osd, info: ["Select which provider to use for system controls. BetterDisplay and Lunar require their respective apps to be installed and running."])
        }
    }
}

#Preview {
    OSDSettings()
        .frame(width: 500, height: 600)
}

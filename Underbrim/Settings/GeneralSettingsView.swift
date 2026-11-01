//
//  GeneralSettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import LaunchAtLogin
import SwiftUI

struct GeneralSettings: View {
    @State private var showLanguageRestartAlert = false
    @ObservedObject private var xpc = XPCHelperClient.shared

    @Default(.appLanguage) var appLanguage

    var body: some View {
        Form {
            Section {
                // Observed, so it reads back (a plain Binding's switch can show one thing and say another).
                Defaults.Toggle(key: .menubarIcon) {
                    Text("Show menu bar icon")
                }
                .settingsItem("Show menu bar icon")
                LaunchAtLogin.Toggle {
                    Text("Open Underbrim when you log in")
                }
                .settingsItem("Open Underbrim when you log in")
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .settingsItem("Language")
                .onChange(of: appLanguage) {
                    appLanguage.applyAppleLanguagesOverride()
                    showLanguageRestartAlert = true
                }
            } header: {
                SettingsPageHeader(tab: .general, section: "App")
            }

            if !xpc.accessibilityGranted && AccessibilityPermission.needed {
                Section { AccessibilityRequiredRow() }
            }

            NotchSettingsSection()
            ShortcutsSettingsSection()
            MoreInAdvanced(.notch)
        }
        .navigationTitle("General")
        .alert("Restart to apply language", isPresented: $showLanguageRestartAlert) {
            Button("Later", role: .cancel) {}
            Button("Restart Now") {
                ApplicationRelauncher.restart()
            }
        } message: {
            Text("Changing the app language requires restarting Underbrim.")
        }
    }
}

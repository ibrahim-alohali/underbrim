//
//  NotificationSettingsView.swift
//  Underbrim
//
import AppKit
import Defaults
import SwiftUI

private struct NotificationApp: Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

struct NotificationSettingsView: View {
    @Default(.notificationLiveActivity) private var notificationLiveActivity
    @Default(.notificationsFromAllApps) private var notificationsFromAllApps
    @Default(.notificationAllowedApps) private var allowedApps
    @ObservedObject private var xpc = XPCHelperClient.shared

    private var selectedApps: [NotificationApp] {
        allowedApps
            .map { NotificationApp(bundleID: $0, name: AppInfo.name(bundleID: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .notificationLiveActivity) {
                    Text("Show notifications in the notch")
                }
                .settingsItem("Show notifications in the notch")
            } header: {
                SettingsPageHeader(tab: .notifications)
            } footer: {
                Text("Requires \(AccessibilityPermission.displayName). Only visible banners are mirrored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !xpc.accessibilityGranted {
                Section { AccessibilityRequiredRow() }
            }

            Section {
                Defaults.Toggle(key: .notificationsFromAllApps) {
                    Text("From all apps")
                }
                .settingsItem("From all apps")
                .disabled(!notificationLiveActivity)

                if !notificationsFromAllApps {
                    if selectedApps.isEmpty {
                        Text("No apps selected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedApps) { app in
                            HStack {
                                appIcon(for: app.bundleID)
                                    .resizable().scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))

                                Text(app.name)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    allowedApps.remove(app.bundleID)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    Button {
                        Self.chooseApplications()
                    } label: {
                        Label("Add Application…", systemImage: "plus")
                    }
                    .settingsItem("Add Application…")
                }
            } header: {
                SettingsLabel("Apps", info: notificationsFromAllApps ? []
                              : ["Only selected apps are mirrored. Add applications from your Mac; no preset app list is used."])
            }
            .disabled(!notificationLiveActivity)
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }

    /// Apps picked in an open panel join those whose banners show (also from the page's island).
    static func chooseApplications() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard !bundleIDs.isEmpty else { return }
            DispatchQueue.main.async {
                Defaults[.notificationAllowedApps].formUnion(bundleIDs)
            }
        }
    }
}

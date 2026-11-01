//
//  NotificationsIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Notifications: banners on or off, and the apps they come from.
//

import Defaults
import SwiftUI

struct NotificationsIsland: View {
    @Default(.notificationAllowedApps) private var apps
    @Default(.notificationsFromAllApps) private var allApps
    @Default(.notificationLiveActivity) private var banners

    var body: some View {
        let name = String(localized: "From all apps")
        Group {
            if allApps {
                IslandSwitch(name: name, isOn: $allApps) {
                    IslandRow(symbol: "bell.badge.fill", title: name, dim: !banners)
                }
            } else {
                HStack(spacing: 7) {
                    IslandSwitch(name: name, isOn: $allApps, whole: false) {
                        HStack(spacing: 7) {
                            IslandGlyph(symbol: "bell.badge.fill", dim: !banners)
                            if apps.isEmpty {
                                Text("No apps selected").islandText(dim: !banners)
                                    .islandShown(String(localized: "No apps selected"))
                            }
                        }
                    }
                    ForEach(apps.sorted().prefix(5), id: \.self) { app in
                        NotificationAppButton(bundleID: app)
                    }
                    Button { NotificationSettingsView.chooseApplications() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(IslandButtonStyle())
                    .help(String(localized: "Add Application…"))
                    .accessibilityLabel(String(localized: "Add Application…"))
                    Spacer(minLength: 0)
                }
            }
        }
        .disabled(!banners)
    }
}

private struct NotificationAppButton: View {
    let bundleID: String
    @State private var frame = CGRect.zero
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        let name = (AppInfo.name(bundleID: bundleID) ?? bundleID)
        Button {
            let menu = IslandMenu()
            menu.add(String(localized: "Remove")) { Defaults[.notificationAllowedApps].remove(bundleID) }
            menu.show(under: frame, rightToLeft: direction == .rightToLeft)
        } label: {
            AppIconView(bundleID: bundleID, size: 22).contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .settingsIslandFrame($frame)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAction(named: Text("Remove")) { Defaults[.notificationAllowedApps].remove(bundleID) }
    }
}

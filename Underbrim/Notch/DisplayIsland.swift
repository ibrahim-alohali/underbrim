//
//  DisplayIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on General: the display the notch is on.
//

import AppKit
import Defaults
import SwiftUI

struct DisplayIsland: View {
    /// Only the chosen screen, not the whole coordinator, which changes with every tab and tour step.
    @State private var screen = NotchViewCoordinator.shared.selectedScreenUUID
    @State private var frame = CGRect.zero
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 7) {
                Image("notch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .accessibilityHidden(true)
                Text(NSScreen.screen(withUUID: screen)?.localizedName ?? SettingsTab.general.title)
                    .islandText()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .settingsIslandFrame($frame)
        .help(islandHelp(String(localized: "Preferred display"), String(localized: "Click to choose")))
        .accessibilityLabel(String(localized: "Preferred display"))
        .accessibilityValue(NSScreen.screen(withUUID: screen)?.localizedName ?? "")
        .onReceive(NotchViewCoordinator.shared.$selectedScreenUUID) { screen = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(LinearGradient(colors: [.clear, .notchAccent, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
                .shadow(color: .notchAccent.opacity(0.7), radius: 4)
                .padding(.horizontal, 34)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The notch follows each change on its own: the app watches these settings.
    private func showMenu() {
        let coordinator = NotchViewCoordinator.shared
        let all = Defaults[.showOnAllDisplays]
        let menu = IslandMenu()
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID else { continue }
            menu.add(screen.localizedName, checked: coordinator.preferredScreenUUID == uuid, enabled: !all) {
                coordinator.preferredScreenUUID = uuid
            }
        }
        menu.separator()
        menu.add(String(localized: "Show on all displays"), checked: all) { Defaults[.showOnAllDisplays].toggle() }
        menu.add(String(localized: "Automatically switch displays"), checked: Defaults[.automaticallySwitchDisplay], enabled: !all) {
            Defaults[.automaticallySwitchDisplay].toggle()
        }
        menu.show(under: frame, rightToLeft: direction == .rightToLeft)
    }
}

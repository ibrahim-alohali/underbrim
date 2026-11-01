//
//  SettingsHelpers.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI

func customBadge(text: LocalizedStringKey) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

/// A settings page's row while a feature waits for Accessibility, with the way out when macOS lists
/// Underbrim as allowed but still refuses (a differently signed copy got the permission).
struct AccessibilityRequiredRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: AccessibilityPermission.systemImageName)
                .font(.title)
                .foregroundStyle(Color.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(AccessibilityPermission.displayName) Required")
                    .font(.headline)
                HelpText("Volume, brightness and keyboard light in the notch, Focus, Caps Lock, notification banners and iPhone Live Activities need it.")
                HelpText("Already on for Underbrim? Remove it from the list with − and add it again.")
            }
            Spacer()
            // macOS's prompt if it gives one, and the list at once; every page hears via accessibilityGranted.
            Button("Grant Access") {
                XPCHelperClient.shared.requestAccessibilityAuthorization()
                SystemSettings.open(.accessibility)
            }
        }
    }
}

func HelpText(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

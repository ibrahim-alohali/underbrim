//
//  ActivityIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Live Activities: the iPhone's, on or off.
//

import Defaults
import SwiftUI

struct ActivityIsland: View {
    private let store = PhoneActivityStore.shared
    @Default(.showPhoneActivities) private var on

    var body: some View {
        IslandSwitch(name: String(localized: "Show your iPhone's Live Activities"), isOn: $on) {
            if !on {
                IslandRow(symbol: "iphone.radiowaves.left.and.right", title: SettingsTab.activities.title, dim: true)
            } else if let activity = store.featured {
                IslandRow(symbol: activity.symbol, title: activity.textWithoutValue ?? activity.app ?? "", value: activity.value)
            } else {
                IslandRow(symbol: "iphone.radiowaves.left.and.right", title: String(localized: "No Live Activities right now"))
            }
        }
        .disabled(!PhoneActivityStore.isSupported)
    }
}

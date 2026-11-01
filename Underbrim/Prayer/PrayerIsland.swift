//
//  PrayerIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Prayer Times: the next prayer, and whether each shows in the notch when
//  its time comes.
//

import Defaults
import SwiftUI

struct PrayerIsland: View {
    private let store = PrayerTimesStore.shared
    @Default(.prayerAtTime) private var atTime

    var body: some View {
        IslandSwitch(name: String(localized: "Show each prayer in the notch when its time comes"), isOn: $atTime) {
            // Each minute: past midnight, "Tomorrow" is today.
            TimelineView(.everyMinute) { context in
                if !atTime {
                    IslandRow(symbol: "moon.stars.fill", title: SettingsTab.prayer.title, dim: true)
                } else if store.status == .ready, let next = store.next {
                    IslandRow(symbol: next.name.symbol, lit: true, title: next.title,
                              value: PrayerFormat.when(next.at, zone: PrayerFormat.zone(store.place), now: context.date))
                } else {
                    IslandRow(symbol: "moon.stars.fill", title: SettingsTab.prayer.title)
                }
            }
        }
    }
}

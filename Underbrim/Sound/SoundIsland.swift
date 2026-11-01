//
//  SoundIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Sound: the Sound page's switch.
//

import Defaults
import SwiftUI

struct SoundIsland: View {
    @Default(.soundPageEnabled) private var on

    var body: some View {
        IslandSwitch(name: String(localized: "Show the Sound page"), isOn: $on) {
            IslandRow(symbol: "slider.horizontal.3", title: SettingsTab.sound.title, dim: !on)
        }
    }
}

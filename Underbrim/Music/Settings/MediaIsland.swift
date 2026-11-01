//
//  MediaIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Media: what's playing, shown in the closed notch or not.
//

import Defaults
import SwiftUI

struct MediaIsland: View {
    @ObservedObject private var music = MusicManager.shared
    /// The coordinator's own setting, read here alone rather than through the whole coordinator.
    @Default(.musicLiveActivityEnabled) private var shows

    var body: some View {
        IslandSwitch(name: String(localized: "Show what's playing when the notch is closed"),
                     isOn: Binding(get: { shows }, set: { on in withAnimation { NotchViewCoordinator.shared.musicLiveActivityEnabled = on } })) {
            if !shows {
                IslandRow(symbol: "play.fill", title: SettingsTab.media.title, dim: true)
            } else if music.hasTrack {
                HStack {
                    Image(nsImage: music.albumArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach([7.0, 14, 10, 16, 8], id: \.self) { height in
                            Capsule()
                                .fill(music.isPlaying ? Color.notchAccent : .white.opacity(0.35))
                                .frame(width: 2.5, height: music.isPlaying ? height : 2.5)
                        }
                    }
                }
                .islandShown(music.isPlaying ? String(localized: "Now Playing") : String(localized: "Paused"))
            } else {
                Text("Not Playing").islandText(dim: true)
                    .islandShown(String(localized: "Not Playing"))
            }
        }
    }
}

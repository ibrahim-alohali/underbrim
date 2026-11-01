//
//  VolumeIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Volume & Brightness: the volume, set by a click, a drag or a scroll on it.
//

import Defaults
import SwiftUI

struct VolumeIsland: View {
    @Default(.osdReplacement) private var on
    @Default(.osdVolumeSource) private var source

    var body: some View {
        // Only the built-in source has a level the app keeps (and a manager already running).
        if on, source == .builtin {
            VolumeLevel()
        } else {
            IslandRow(symbol: "speaker.wave.2.fill", title: SettingsTab.osd.title)
        }
    }
}

private struct VolumeLevel: View {
    @ObservedObject private var volume = VolumeManager.shared

    var body: some View {
        let action = volume.isMuted ? String(localized: "Unmute") : String(localized: "Mute")
        Button { volume.toggleMuteAction() } label: {
            IslandGlyph(symbol: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .disabled(!volume.canMute)
        .help(action)
        .accessibilityLabel(action)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct VolumeDrag: View {
    @Default(.osdReplacement) private var on
    @Default(.osdVolumeSource) private var source
    @ObservedObject private var volume = VolumeManager.shared

    private let shape = IslandShape(topRadius: SettingsIsland.flare, bottomRadius: 18)

    var body: some View {
        if on, source == .builtin, volume.canSetVolume {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(shape)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                set(HUDBrimLight.level(at: drag.location, in: proxy.size, shape: shape))
                            }
                    )
                    .holdsSettingsWindow()
                    .islandScroll { amount, precise in
                        set(level + (precise ? amount / max(proxy.size.width, 1) : amount / 16))
                    }
            }
            .help(islandHelp(String(localized: "Volume"), String(localized: "Drag or scroll to change")))
            .accessibilityRepresentation {
                Slider(value: Binding(get: { Double(level) }, set: { set(CGFloat($0)) }), in: 0...1, step: 0.05)
            }
            .accessibilityLabel(String(localized: "Volume"))
            .accessibilityValue(volume.isMuted ? Text("Muted") : Text(level, format: .percent.precision(.fractionLength(0))))
        }
    }

    /// Read when used: a scroll's closure outlives the redraw it was made in.
    private var level: CGFloat { volume.isMuted ? 0 : CGFloat(min(max(volume.rawVolume, 0), 1)) }

    private func set(_ level: CGFloat) {
        let level = Float(min(max(level, 0), 1))
        guard abs(CGFloat(level) - self.level) > 0.004 else { return }
        volume.setAbsolute(level)
    }
}

struct VolumeBrim: View {
    @Default(.osdReplacement) private var on
    @Default(.osdVolumeSource) private var source
    // On this same page: passed in as the colour, so the light follows the switch at once.
    @Default(.systemEventIndicatorUseAccent) private var useAccent
    @ObservedObject private var volume = VolumeManager.shared

    var body: some View {
        if on, source == .builtin {
            HUDBrimLight(level: volume.isMuted ? 0 : CGFloat(volume.rawVolume), type: .volume,
                         accent: useAccent ? .notchAccent : .white,
                         updated: .distantPast, lit: .constant(.distantPast),
                         shape: IslandShape(topRadius: SettingsIsland.flare, bottomRadius: 18))
                .accessibilityHidden(true)
        }
    }
}

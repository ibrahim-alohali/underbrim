//
//  NotchSurface.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Background of the notch shell: black, continuous with the camera housing,
//  with a hairline of light around the open notch.
//

import Defaults
import SwiftUI

struct NotchSurface: View {
    let shape: IslandShape
    let isOpen: Bool
    let bandHeight: CGFloat
    @Default(.enableShadow) private var edgeLight
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if isOpen, edgeLight {
                // Open: a hairline of light inside the sides and bottom, below the band, so the edge reads on a dark
                // wallpaper. Twice the hairline, centred on the outline: the island's clip keeps the inner half.
                shape.stroke(Color.white.opacity(contrast == .increased ? 0.35 : 0.14),
                             lineWidth: contrast == .increased ? 2 : 2 / displayScale)
                    .mask { Rectangle().padding(.top, bandHeight) }
                    .transition(.opacity)
            }
        }
    }
}

//
//  ShelfIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Shelf: its switch, how many items it holds, and a place to drop files.
//

import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct ShelfIsland: View {
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    @Default(.shelfEnabled) private var on
    @State private var targeted = false

    var body: some View {
        let count = shelf.items.count
        IslandSwitch(name: SettingsTab.shelf.title, isOn: $on, note: on ? String(localized: "Drop files here") : nil) {
            if on {
                let words = count == 0 ? String(localized: "Drop files here") : String(localized: "\(count) items")
                HStack(spacing: 10) {
                    HStack(spacing: -9) {
                        Image(systemName: "doc.fill").foregroundStyle(.white.opacity(0.9))
                        Image(systemName: "doc.fill").foregroundStyle(.white.opacity(0.55))
                    }
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                    Text(words).islandText()
                }
                .islandShown(words)
            } else {
                IslandRow(symbol: "tray.full.fill", title: SettingsTab.shelf.title, dim: true)
            }
        }
        .modifier(IslandHighlight(pressed: targeted, pad: EdgeInsets(top: 5, leading: -8, bottom: 5, trailing: -8), hovers: false))
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { targeted }, set: { targeted = $0 && on })) { providers in
            guard on else { return false }
            shelf.load(providers)
            return true
        }
    }
}

//
//  AppIconView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI

/// An app's icon by bundle id, cached: Launch Services lookups on every notch redraw add up.
struct AppIconView: View {
    let bundleID: String
    let size: CGFloat
    /// nil: no installed or running app has this id.
    private static var icons: [String: Image?] = [:]

    static func icon(for bundleID: String) -> Image? {
        if let cached = icons[bundleID] { return cached }
        let image = appIconAsNSImage(for: bundleID).map { Image(nsImage: $0) }
        icons[bundleID] = image
        return image
    }

    var body: some View {
        (Self.icon(for: bundleID) ?? Image(nsImage: NSWorkspace.shared.icon(for: .applicationBundle)))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The playing app's icon on the artwork, only for a loaded track from an identifiable app (else
/// macOS's blank generic icon or a guessed default would appear).
struct MediaSourceBadge: View {
    @ObservedObject private var music = MusicManager.shared
    let size: CGFloat

    var body: some View {
        if !music.usingAppIconForArtwork, music.hasTrack,
           let bundleID = music.bundleIdentifier, AppIconView.icon(for: bundleID) != nil {
            AppIconView(bundleID: bundleID, size: size)
        }
    }
}

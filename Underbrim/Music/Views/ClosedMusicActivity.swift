//
//  ClosedMusicActivity.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The playing song on the closed island: album art, the song-change peek's title and artist
//  either side of the camera, and the visualizer.
//

import Defaults
import SwiftUI

struct ClosedMusicActivity: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var hud = HUDPresenter.shared
    /// The closed island's height.
    let height: CGFloat
    /// The closed notch's width.
    let notchWidth: CGFloat
    /// The corner radius scale, when corner radius scaling is on.
    let scale: CGFloat?
    let albumArtNamespace: Namespace.ID
    /// On the floating island (a display without a notch): no camera in the way, so the title takes the middle.
    var floating = false

    /// Space reserved for the title (left of the cutout) and artist (right).
    static let labelWidth: CGFloat = 110

    /// True while the song-change peek is expanding the closed pill inline.
    @MainActor static var peeksInline: Bool {
        let hud = HUDPresenter.shared
        return hud.expandingView.show && hud.expandingView.type == .music
            && Defaults[.sneakPeekStyles] == .inline
    }

    /// Width of the black centre section of the closed music pill.
    ///
    /// Derived from the real notch width rather than the previous hard-coded
    /// 380. That constant assumed a particular notch size: the title sits
    /// left of the cutout and the artist right of it, separated by a spacer
    /// as wide as the notch itself, so on a wider notch there was no room
    /// left for the artist and the labels collided. Sizing from
    /// closedNotchSize keeps a fixed label budget either side whatever the
    /// hardware is, and keeps liveActivityEdgeMargin in play so content
    /// clears the bezel — the inline path had dropped it entirely.
    private var centerWidth: CGFloat {
        let margin = notchWidth - 4 + (2 * liveActivityEdgeMargin)
        guard Self.peeksInline else { return margin }
        return margin + (2 * Self.labelWidth)
    }

    var body: some View {
        Group {
            if floating { floatingBody } else { notchBody }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveActivityItem.music.spokenText)
    }

    private var floatingBody: some View {
        let size = max(0, height - 6)
        return HStack(spacing: 8) {
            Image(nsImage: musicManager.albumArt)
                .resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(width: size, height: size)
            Text(musicManager.songTitle)
                .font(.notchCaption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: FloatingIsland.titleWidth, alignment: .leading)
            MusicVisualizer(
                isPlaying: musicManager.isPlaying,
                tintColor: Defaults[.coloredSpectrogram]
                ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.5)
                : Color.gray
            )
            .frame(width: 18, height: 12)
            .frame(width: size, height: size)
        }
        .frame(height: height)
    }

    private var notchBody: some View {
        HStack(spacing: 0) {
            // Closed-mode album art: scale padding and corner radius according to the scale
            let baseArtSize = height - 12
            let scaledArtSize: CGFloat = {
                if let scale {
                    return height - 12 * scale
                }
                return baseArtSize
            }()
            // The art's top/bottom gap to the pill; the leading offset below
            // trims the row's edge slack down to this same inset.
            let artVerticalInset = (height - scaledArtSize) / 2

            let closedCornerRadius: CGFloat = {
                let base = MusicPlayerImageSizes.cornerRadiusInset.closed
                if let scale {
                    return max(0, base * scale)
                }
                return base
            }()

            Image(nsImage: musicManager.albumArt)
                .resizable().scaledToFit()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: closedCornerRadius)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: scaledArtSize,
                    height: scaledArtSize
                )
                .offset(x: artVerticalInset - liveActivityEdgeMargin)

            Rectangle()
                .fill(.black)
                .overlay(
                    // .center, not .top: the album art beside this is
                    // vertically centered, so top-aligned labels sat visibly
                    // high against it.
                    HStack(alignment: .center) {
                        if hud.expandingView.show
                            && hud.expandingView.type == .music {
                            MarqueeText(
                                musicManager.songTitle,
                                color: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                delayDuration: 0.4,
                                frameWidth: Self.labelWidth
                            )
                            .opacity(
                                (hud.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: notchWidth)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: Self.labelWidth, alignment: .trailing)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (hud.expandingView.show
                                        && hud.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                    .padding(.horizontal, 8)
                )
                .frame(width: centerWidth)

            HStack {
                MusicVisualizer(
                    isPlaying: musicManager.isPlaying,
                    tintColor: Defaults[.coloredSpectrogram]
                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.5)
                    : Color.gray
                )
                .frame(width: 18, height: 12)
            }
            .frame(
                width: max(
                    0,
                    height - 12
                ),
                height: max(
                    0,
                    height - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: height,
            alignment: .center
        )
    }
}

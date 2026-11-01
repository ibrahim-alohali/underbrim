//
//  CompactHomeView.swift
//  Underbrim
//
//  Now Playing on its own (HomeWidgetAlone), pinned or in compact mode.
//
//  Transport and slider are shared with the standard layout
//  (MusicControlSlotButton / MusicSliderView) rather than ported separately,
//  so seeking and the buttons behave identically in both.
//

import Defaults
import SwiftUI

struct CompactHomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject var musicManager = MusicManager.shared
    let albumArtNamespace: Namespace.ID

    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    @Default(.coloredSpectrogram) private var coloredSpectrogram
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.showRemainingTime) private var showRemainingTime

    private static let art: CGFloat = 20
    private static let vizBarWidth: CGFloat = 24
    /// The progress bar's width before the island widens it: with the full set of buttons (nothing
    /// playing, or a player with shuffle) the island grows for it instead of squeezing it to a dot.
    private static let progressWidth: CGFloat = 40

    // No idle branch, deliberately. The standard layout has none either —
    // it renders whatever MusicManager last cached, so a paused or stopped
    // track keeps its art, title and scrub position.
    var body: some View {
        AloneFrame(widget: .nowPlaying) {
            Button { musicManager.openMusicApp() } label: {
                Image(nsImage: musicManager.albumArt)
                    .resizable().scaledToFill()
                    .frame(width: Self.art, height: Self.art)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .disabled(musicManager.appToOpen == nil)
            .accessibilityLabel(musicManager.appToOpen.map { String(localized: "Open \(AppInfo.name(bundleID: $0) ?? $0)") } ?? "")
            .accessibilityHidden(musicManager.appToOpen == nil)
            BandTitle(text: musicManager.hasTrack ? musicManager.songTitle : String(localized: "Not Playing"),
                      color: musicManager.hasTrack ? .white : .secondary)
        } trailing: {
            MusicVisualizer(
                isPlaying: musicManager.isPlaying,
                tintColor: coloredSpectrogram
                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                    : .gray
            )
            .frame(width: Self.vizBarWidth, height: 14)
        } row: {
            HStack(spacing: 10) {
                transport
                timeline
            }
            .environment(\.layoutDirection, .leftToRight)  // playback, as in MusicSliderView
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var timeline: some View {
        MusicPlaybackTimeline(isPlaying: musicManager.isPlaying) { date in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                onValueChange: { MusicManager.shared.seek(to: $0) },
                trailingLabel: showRemainingTime ? .remaining : .duration,
                barWidth: Self.progressWidth
            )
            .frame(height: 22)
            // Nothing loaded: there's no position to show or seek (as Home's).
            .notchDisabled(!musicManager.hasTrack)
            .allowsHitTesting(musicManager.hasTrack)
            .accessibilityHidden(!musicManager.hasTrack)
        }
    }

    /// The user's configured control slots, clamped like the standard
    /// layout's activeSlots, rendered through the same MusicControlSlotButton
    /// — so sizing and glyphs match exactly.
    private var displayedSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        return musicManager.available(Array(slotConfig
            .padded(to: sanitizedLimit, filler: .none)
            .prefix(sanitizedLimit)))
    }

    private var transport: some View {
        HStack(spacing: 6) {
            ForEach(Array(displayedSlots.enumerated()), id: \.offset) { _, slot in
                MusicControlSlotButton(slot: slot)
            }
        }
    }
}

/// The song beside the camera, in the room its side of the band leaves (the island doesn't widen for
/// it): one line cut at the end. Where not even a couple of letters would show, only the art and the
/// visualizer flank the camera, and VoiceOver still reads the title.
private struct BandTitle: View {
    let text: String
    let color: Color

    /// About two letters and the ellipsis.
    private static let shortest: CGFloat = 28

    var body: some View {
        // A geometry reader asks for next to no width of its own, so the band, and the island, keep their size.
        GeometryReader { geo in
            Text(text)
                .font(.notchTitle)
                .foregroundStyle(geo.size.width >= Self.shortest ? color : .clear)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: 17)
    }
}

/// Output device list shared by both layouts' media-output buttons.
/// Row treatment follows macOS's AirPlay output menu: rounded highlight on
/// hover, circular icon badge marking the active output, no checkmark.
struct AudioOutputPicker: View {
    @ObservedObject var routeManager: AudioRouteManager
    let onSelect: () -> Void

    /// Apple's rows use a softly rounded rectangle, not a full pill.
    private let rowCornerRadius: CGFloat = 8
    private let listInset: CGFloat = 8
    private let badgeSize: CGFloat = 24
    private let hoverFill: CGFloat = 0.1
    private let pressedFill: CGFloat = 0.18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Output")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if routeManager.devices.isEmpty {
                // Enumeration is async, so an empty list on first open is
                // normal rather than an error worth alarming anyone about.
                Text("Looking for devices…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ForEach(routeManager.devices) { device in
                    deviceRow(device)
                }
                .padding(.horizontal, listInset)
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 220)
    }

    private func deviceRow(_ device: AudioOutputDevice) -> some View {
        let isSelected = device.id == routeManager.activeDeviceID

        return Button {
            routeManager.select(device)
            onSelect()
        } label: {
            HStack(spacing: 10) {
                deviceIcon(device, isSelected: isSelected)

                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 10)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: rowCornerRadius))
        }
        .buttonStyle(AudioOutputRowButtonStyle(
            cornerRadius: rowCornerRadius,
            hoverFill: hoverFill,
            pressedFill: pressedFill
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// White badge + accent glyph for the active output, dim badge + white
    /// glyph for the rest.
    @ViewBuilder
    private func deviceIcon(_ device: AudioOutputDevice, isSelected: Bool) -> some View {
        Image(systemName: device.iconName)
            .font(.system(size: badgeSize * 0.55, weight: .regular))
            .foregroundStyle(isSelected ? Color.notchAccent : Color.white)
            .frame(width: badgeSize, height: badgeSize)
            .background(isSelected ? Color.white : Color.white.opacity(0.22), in: Circle())
    }
}

private struct AudioOutputRowButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let hoverFill: CGFloat
    let pressedFill: CGFloat

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: CGFloat
        if configuration.isPressed {
            fill = pressedFill
        } else {
            fill = isHovering ? hoverFill : 0
        }

        return configuration.label
            .background(Color.white.opacity(fill), in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
    }
}

//
//  MusicPlayerView.swift
//  Underbrim
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

struct MusicPlayerView: View {
    @EnvironmentObject var vm: NotchViewModel
    let albumArtNamespace: Namespace.ID

    nonisolated static var height: CGFloat { NotchMetrics.tabHeight }

    var body: some View {
        HStack(spacing: NotchMetrics.margin) {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                .frame(width: Self.height, height: Self.height)
            MusicControlsView()
                .compositingGroup()
        }
        .frame(height: Self.height)
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: NotchViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        let app = musicManager.appToOpen
        return ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(app == nil)
            .accessibilityLabel(app.map { String(localized: "Open \(AppInfo.name(bundleID: $0) ?? $0)") } ?? "")
            .accessibilityHidden(app == nil)

            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .foregroundColor(Color.black)
            // Dims paused artwork; the "nothing playing" tile is already muted.
            .opacity(musicManager.isPlaying || !musicManager.hasTrack ? 0 : 0.8)
            .blur(radius: 50)
            .allowsHitTesting(false)
    }

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .interpolation(.high)
            .resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        // Inside the artwork's corner, so the margin around it stays clear.
        if vm.notchState == .open {
            MediaSourceBadge(size: 22)
                .padding(5)
                .transition(.opacity)
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.showRemainingTime) private var showRemainingTime
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            songInfo(width: width)
            Spacer(minLength: 4)
            musicSlider
            Spacer(minLength: 2)
            slotToolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .buttonStyle(PlainButtonStyle())
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(musicManager.hasTrack ? musicManager.songTitle : String(localized: "Not Playing"),
                        font: .notchTitle, color: musicManager.hasTrack ? .white : .secondary, frameWidth: width)
            MarqueeText(
                musicManager.artistName,
                font: .notchBody,
                nsFont: .callout,
                color: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .secondary,
                frameWidth: width
            )
        }
    }

    private var musicSlider: some View {
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
                onValueChange: { newValue in
                    MusicManager.shared.seek(to: newValue)
                },
                trailingLabel: showRemainingTime ? .remaining : .duration
            )
            .notchDisabled(!musicManager.hasTrack)
            .allowsHitTesting(musicManager.hasTrack)
            .accessibilityHidden(!musicManager.hasTrack)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                slotView(for: slot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .environment(\.layoutDirection, .leftToRight)  // like the timeline
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        // All of them, mirror or not, so the player keeps its width.
        return musicManager.available(Array(padded.prefix(sanitizedLimit)))
    }

    private func slotView(for slot: MusicControlButton) -> some View {
        MusicControlSlotButton(slot: slot)
    }
}

/// A single transport button, shared by the standard and compact layouts so
/// both render the exact same controls — sizing, glyphs — and can't drift apart.
struct MusicControlSlotButton: View {
    @ObservedObject var musicManager = MusicManager.shared
    let slot: MusicControlButton

    var body: some View {
        Group {
            switch slot {
            case .shuffle:
                HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .notchAccent : .primary, scale: .medium) {
                    MusicManager.shared.toggleShuffle()
                }
            case .previous:
                HoverButton(icon: "backward.fill", scale: .medium) {
                    MusicManager.shared.previousTrack()
                }
            case .playPause:
                HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                    MusicManager.shared.togglePlay()
                }
            case .next:
                HoverButton(icon: "forward.fill", scale: .medium) {
                    MusicManager.shared.nextTrack()
                }
            case .repeatMode:
                HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                    MusicManager.shared.toggleRepeat()
                }
            case .mediaOutput:
                MediaOutputSlotButton()
            case .volume:
                VolumeControlView()
            case .favorite:
                FavoriteControlButton()
            case .goBackward:
                HoverButton(icon: "gobackward.15", scale: .medium) {
                    MusicManager.shared.skip(seconds: -15)
                }
            case .goForward:
                HoverButton(icon: "goforward.15", scale: .medium) {
                    MusicManager.shared.skip(seconds: 15)
                }
            case .none:
                Color.clear.frame(height: 1)
            }
        }
        .help(slot.actionLabel(isPlaying: musicManager.isPlaying, isFavorite: musicManager.isFavoriteTrack))
        .accessibilityLabel(slot.actionLabel(isPlaying: musicManager.isPlaying, isFavorite: musicManager.isFavoriteTrack))
        .accessibilityValue(stateValue)
        .accessibilityHidden(slot == .none)
        // Sent to the playing app: with no track there's none to send to (Play can wake the last player).
        .notchDisabled([.previous, .next, .goBackward, .goForward].contains(slot) && !musicManager.hasTrack)
    }

    /// Shuffle and Repeat say their state: the tint alone doesn't reach VoiceOver.
    private var stateValue: String {
        switch slot {
        case .shuffle: musicManager.isShuffled ? String(localized: "On") : String(localized: "Off")
        case .repeatMode:
            switch musicManager.repeatMode {
            case .off: String(localized: "Off")
            case .all: String(localized: "All Songs")
            case .one: String(localized: "One Song")
            }
        default: ""
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .notchAccent
        }
    }
}

struct MusicPlaybackTimeline<Content: View>: View {
    let isPlaying: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        // Still while paused: with no interval it redraws the bar every frame.
        TimelineView(.animation(minimumInterval: musicPlaybackTickInterval, paused: !isPlaying)) { context in
            content(context.date)
        }
    }
}

private let musicPlaybackTickInterval: TimeInterval = 0.2

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .notchDisabled(!musicManager.canFavoriteTrack)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

/// Audio-output slot for a control row. Shows where audio is going and
/// switches it, via a popover device picker. Both layouts use this through
/// MusicControlSlotButton.
struct MediaOutputSlotButton: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var routeManager = AudioRouteManager.shared
    @State private var showingPicker = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HoverButton(icon: routeSymbol, scale: .medium) {
            // Enumerate on open rather than polling: devices come and go
            // (AirPods connecting, a display waking) and a list built at
            // launch would be stale by the time anyone opened it.
            if routeManager.devices.isEmpty {
                // A popover sizes its window once, at presentation. Opening
                // on the empty placeholder would size it to that and
                // truncate names that arrive a moment later.
                routeManager.refreshDevices { showingPicker = true }
            } else {
                routeManager.refreshDevices()
                showingPicker.toggle()
            }
        }
        .onHover { hovering in
            isHoveringButton = hovering
            if hovering {
                hideTask?.cancel()
                hideTask = nil
            } else {
                scheduleHideIfNeeded()
            }
        }
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            AudioOutputPicker(routeManager: routeManager) {
                showingPicker = false
            }
            // The button sits in the left-to-right transport row; its list is text.
            .environment(\.layoutDirection, NSApp.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight)
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    hideTask?.cancel()
                    hideTask = nil
                } else {
                    scheduleHideIfNeeded()
                }
            }
        }
        .onChange(of: showingPicker) { _, isShowing in
            vm.isPopoverActive = isShowing
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeIslandPopovers)) { _ in showingPicker = false }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
            vm.isPopoverActive = false
        }
    }

    /// Prefer the live device's own icon; fall back to the resolver's
    /// classification before the first enumeration has run.
    private var routeSymbol: String {
        routeManager.activeDevice?.iconName ?? AudioOutputRouteResolver.shared.outputRouteSymbol()
    }

    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showingPicker = false } }
        }
    }
}

// Internal so the compact layout's slot row can share the padding rule.
extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

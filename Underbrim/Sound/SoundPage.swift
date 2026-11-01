//
//  SoundPage.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The island's Sound page: the output and overall volume, then a tile for each app with sound,
//  its icon muting it and a slider from 0 to 200 %. Until System Audio Recording is allowed, it asks.
//

import Defaults
import SwiftUI

struct SoundPage: View {
    private let mixer = SoundMixer.shared
    @Default(.soundKeepPaused) private var keepPaused

    static let outputWidth: CGFloat = 178
    static let tileHeight: CGFloat = 40

    /// Two columns while they fit, else three (scrolling past six).
    static func tileWidth(count: Int) -> CGFloat {
        let room = NotchMetrics.openContentWidth - outputWidth - NotchMetrics.margin
        let columns = CGFloat(min(max(2, (count + 1) / 2), 3))
        return (room - (columns - 1) * NotchMetrics.cardSpacing) / columns
    }

    private var shown: [SoundMixer.App] {
        mixer.apps
            .filter { $0.playing || keepPaused || $0.id == SoundMixer.systemSounds }
            .sorted { first, second in
                let order = { (app: SoundMixer.App) in app.id == SoundMixer.systemSounds ? 2 : app.playing ? 0 : 1 }
                if order(first) != order(second) { return order(first) < order(second) }
                return SoundAppTile.name(of: first.id).localizedStandardCompare(SoundAppTile.name(of: second.id)) == .orderedAscending
            }
    }

    var body: some View {
        Group {
            switch mixer.access {
            case .allowed:
                HStack(alignment: .top, spacing: NotchMetrics.margin) {
                    SoundOutputCard()
                        .frame(width: Self.outputWidth)
                    if shown.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nothing is playing").font(.notchTitle).foregroundStyle(.white)
                            Text("Apps show here once they play sound.").font(.notchCaption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else {
                        let width = Self.tileWidth(count: shown.count)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: Array(repeating: GridItem(.fixed(Self.tileHeight), spacing: NotchMetrics.cardSpacing), count: 2),
                                      spacing: NotchMetrics.cardSpacing) {
                                ForEach(shown) { app in
                                    SoundAppTile(app: app, touchedInCall: mixer.touchedInCall.contains(app.id))
                                        .frame(width: width, height: Self.tileHeight)
                                }
                            }
                        }
                        .scrollClipDisabled(false)
                        .scrollsBeforePages()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(String(localized: "Apps with sound"))
                    }
                }
            case .notAsked, .denied:
                SoundAccessCard(denied: mixer.access == .denied)
            }
        }
        .frame(width: NotchMetrics.openContentWidth, height: NotchMetrics.tabHeight)
        .onAppear { mixer.refreshAccess() }
    }
}

private struct SoundAccessCard: View {
    let denied: Bool
    @ObservedObject private var coordinator = NotchViewCoordinator.shared

    var body: some View {
        HStack(spacing: NotchMetrics.margin) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sound").font(.notchCaption).foregroundStyle(.secondary)
                Text(denied ? String(localized: "System Audio Recording is off") : String(localized: "Set each app's volume"))
                    .font(.notchTitle).foregroundStyle(.white)
                Text(denied
                     ? String(localized: "Turn on Underbrim under System Audio Recording Only to set each app's volume. Until then, every app plays as it is.")
                     : String(localized: "Underbrim needs System Audio Recording to change an app's sound. Nothing is recorded or saved, and the sound stays on this Mac."))
                    .font(.notchCaption).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if denied {
                Button(String(localized: "Open System Settings")) { NSWorkspace.shared.open(SoundMixer.privacyPane) }
                    .buttonStyle(NotchProminentStyle())
            } else {
                Button(String(localized: "Allow…")) { SoundMixer.shared.requestAccess() }
                    .buttonStyle(NotchProminentStyle())
                NotchTextButton(title: String(localized: "Not Now")) {
                    withAnimation(StandardAnimations.open) { coordinator.selectTab(.home) }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
    }
}

private struct SoundOutputCard: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var routes = AudioRouteManager.shared
    @ObservedObject private var volume = VolumeManager.shared
    @State private var picking = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output").font(.notchCaption).foregroundStyle(.secondary)
            Button {
                routes.refreshDevices { picking = true }
            } label: {
                HStack(spacing: 4) {
                    Text(routes.activeDevice?.name ?? String(localized: "Output"))
                        .font(.notchBody.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.notchSymbol(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Choose where sound plays"))
            .accessibilityHint(String(localized: "Choose where sound plays"))
            .onHover { hovering in
                isHoveringButton = hovering
                if hovering { cancelHide() } else { scheduleHideIfNeeded() }
            }
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                AudioOutputPicker(routeManager: routes) { picking = false }
                    .onHover { hovering in
                        isHoveringPopover = hovering
                        if hovering { cancelHide() } else { scheduleHideIfNeeded() }
                    }
            }
            .onChange(of: picking) { _, shown in vm.isPopoverActive = shown }
            HStack(spacing: 8) {
                Text("All sound").font(.notchCaption).foregroundStyle(.secondary)
                LevelSlider(value: Double(volume.rawVolume), upper: 1, name: String(localized: "All sound"),
                            current: { Double(volume.rawVolume) }) { value, _ in
                    volume.setAbsolute(Float32(value))
                }
                Text(Double(volume.isMuted ? 0 : volume.rawVolume).formatted(.percent.precision(.fractionLength(0))))
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
        .onAppear { routes.refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: .closeIslandPopovers)) { _ in picking = false }
        .onDisappear {
            cancelHide()
            if picking { vm.isPopoverActive = false }
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// Hides it a moment after the pointer has left both the button and the list, like the player's output picker.
    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { picking = false } }
        }
    }
}

struct SoundAppTile: View {
    let app: SoundMixer.App
    /// Its slider moved during its call: a note that echo cancellation may suffer.
    var touchedInCall = false
    private let mixer = SoundMixer.shared
    // Observed so a saved level, a mute or the range redraws the tile.
    @Default(.soundLevels) private var levels
    @Default(.soundMuted) private var muted
    @Default(.soundBoost) private var boost

    static func name(of app: String) -> String {
        app == SoundMixer.systemSounds ? String(localized: "System sounds") : AppInfo.name(bundleID: app) ?? app
    }

    private var name: String { Self.name(of: app.id) }
    private var isMuted: Bool { muted.contains(app.id) }
    private var level: Double { mixer.level(of: app.id) }
    private var leftAlone: Bool { app.inCall && !touchedInCall }

    private var status: String {
        if isMuted { return String(localized: "Muted") }
        if leftAlone { return String(localized: "In a call") }
        if !app.playing && app.id != SoundMixer.systemSounds { return String(localized: "Paused") }
        return level.formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button { mixer.toggleMute(app.id) } label: {
                    icon
                        .overlay(alignment: .bottomTrailing) {
                            if isMuted {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(2)
                                    .background(.black.opacity(0.75), in: Circle())
                                    .offset(x: 3, y: 3)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .opacity(isMuted ? 0.5 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? String(localized: "Unmute \(name)") : String(localized: "Mute \(name)"))
                .accessibilityLabel(isMuted ? String(localized: "Unmute \(name)") : String(localized: "Mute \(name)"))
                Text(name)
                    .font(.notchBody.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if touchedInCall {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.notchSymbol(size: 9))
                        .foregroundStyle(.orange)
                        .help(String(localized: "Changing a call's sound can upset its echo cancellation."))
                        .accessibilityLabel(String(localized: "Changing a call's sound can upset its echo cancellation."))
                }
                Spacer(minLength: 4)
                Text(status)
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(!isMuted && !leftAlone && level > 1 ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            LevelSlider(value: isMuted ? 0 : level, upper: boost ? 2 : 1, name: String(localized: "\(name) volume"),
                        dimmed: isMuted || leftAlone, spoken: status,
                        current: { mixer.isMuted(app.id) ? 0 : mixer.level(of: app.id) }) { value, done in
                mixer.setLevel(value, for: app.id, done: done)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
        .opacity(app.playing || app.id == SoundMixer.systemSounds ? 1 : 0.6)
        .help(name)
        .animation(.smooth(duration: 0.2), value: isMuted)
    }

    @ViewBuilder private var icon: some View {
        if app.id == SoundMixer.systemSounds {
            Image(systemName: "bell.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.gray, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        } else {
            AppIconView(bundleID: app.id, size: 18)
        }
    }
}

/// A level from 0 to `upper` (1 is 100 %), amber past 100 %. Drawn left to right and mirrored
/// as a whole in Arabic, like the island's other sliders.
struct LevelSlider: View {
    let value: Double
    let upper: Double
    let name: String
    var dimmed = false
    var spoken: String?
    /// Its value as it is now, for two fingers sliding over it (it moves as far as a drag would).
    var current: (() -> Double)?
    let change: (Double, Bool) -> Void
    @State private var dragging = false
    @State private var width: CGFloat = 1
    @State private var swipeStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let unit = upper > 0 ? width / upper : 0
            let height: CGFloat = dragging ? 7 : 4
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle().fill(.white.opacity(dimmed ? 0.45 : 1))
                    .frame(width: min(max(value, 0), 1) * unit)
                if value > 1 {
                    Rectangle().fill(Color.orange.opacity(dimmed ? 0.45 : 1))
                        .frame(width: (min(value, upper) - 1) * unit)
                        .offset(x: unit)
                }
            }
            .frame(height: height)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if upper > 1 {
                    Capsule().fill(.white.opacity(0.6))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: unit - 0.75)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        change(min(max(gesture.location.x / max(unit, 1), 0), upper), false)
                    }
                    .onEnded { gesture in
                        change(min(max(gesture.location.x / max(unit, 1), 0), upper), true)
                        dragging = false
                    }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragging)
        }
        .frame(height: 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .keepsSwipes(current.map { current in
            { travel, lifted in
                let start = swipeStart ?? current()
                swipeStart = lifted ? nil : start
                let toward = NSApp.userInterfaceLayoutDirection == .rightToLeft ? -travel : travel
                change(min(max(start + Double(toward / width) * upper, 0), upper), lifted)
            }
        })
        .environment(\.layoutDirection, .leftToRight)
        .flipsForRightToLeftLayoutDirection(true)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { change($0, true) }), in: 0...max(upper, 0.01), step: 0.05) {
                Text(name)
            }
        }
        .accessibilityValue(spoken ?? value.formatted(.percent.precision(.fractionLength(0))))
    }
}

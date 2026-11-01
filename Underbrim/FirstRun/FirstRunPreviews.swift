//
//  FirstRunPreviews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The tour's two moving pictures on a small screen drawn in shapes: a widget held until it's
//  pinned, and the Sound page's sliders. Frames come only while something moves, and what changes
//  is drawn, not laid out, so the notch around them is left alone. Hidden from VoiceOver: the
//  step's text says what they show.
//

import AppKit
import Defaults
import SwiftUI

private enum TourPreview {
    static let size = CGSize(width: 300, height: 128)
    static let band: CGFloat = 12
    static let camera: CGFloat = 56
    static let loop: TimeInterval = 6.4
    static let fading: ClosedRange<TimeInterval> = 5.6...loop
    /// Where the pointer comes in from (left to right; mirrored in Arabic), all of it on the screen.
    static let pointerStart = CGPoint(x: 250, y: 104)

    static func run(_ elapsed: TimeInterval) -> (t: TimeInterval, opacity: Double) {
        let t = elapsed.truncatingRemainder(dividingBy: loop)
        if t > 6 { return (0, part(t, 6, loop)) }
        return (t, 1 - part(t, 5.6, 6))
    }

    static func part(_ t: Double, _ start: Double, _ end: Double) -> Double {
        min(1, max(0, (t - start) / (end - start)))
    }

    static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, x), y: mix(a.y, b.y, x)) }
}

/// Repeats `scene` while shown; with Reduce Motion, shows `stills` in turn every 3.5 s. Frames come
/// in step with the display during `moving` (seconds into each run), 15 a second in `ticking`, else none.
private struct TourPlayer<Scene: View>: View {
    let stills: [TimeInterval]
    let moving: [ClosedRange<TimeInterval>]
    var ticking: ClosedRange<TimeInterval>?
    @ViewBuilder let scene: (_ t: TimeInterval, _ clock: TimeInterval?) -> Scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var coordinator = NotchViewCoordinator.shared
    @State private var start = Date()
    @State private var pace = Pace.moving

    private enum Pace { case moving, ticking, still }

    var body: some View {
        // The picture as an overlay on a fixed space: what moves in it is laid out on its own.
        Color.clear
            .frame(width: TourPreview.size.width, height: TourPreview.size.height)
            .overlay {
                if reduceMotion, stills.count == 1 {
                    scene(stills[0], nil)
                } else if reduceMotion {
                    TimelineView(.periodic(from: start, by: 3.5)) { context in
                        let shown = Int((context.date.timeIntervalSince(start) + 0.01) / 3.5) % stills.count
                        ZStack {
                            ForEach(stills.indices, id: \.self) { index in
                                scene(stills[index], nil).opacity(index == shown ? 1 : 0)
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: shown)
                    }
                } else {
                    TimelineView(.animation(minimumInterval: pace == .ticking ? 1 / 15 : 1 / 60,
                                            paused: pace == .still || coordinator.screenLocked)) { context in
                        let elapsed = context.date.timeIntervalSince(start)
                        let run = TourPreview.run(elapsed)
                        scene(run.t, elapsed).opacity(run.opacity)
                    }
                    .task { await keepPace() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func keepPace() async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            let t = elapsed.truncatingRemainder(dividingBy: TourPreview.loop)
            var now = Pace.still
            var until = (moving.map(\.lowerBound) + [ticking?.lowerBound].compactMap { $0 }).filter { $0 > t }.min() ?? TourPreview.loop
            if let range = moving.first(where: { $0.contains(t) }) {
                now = .moving
                until = range.upperBound
            } else if let ticking, ticking.contains(t) {
                now = .ticking
                until = ticking.upperBound
            }
            if pace != now { pace = now }
            try? await Task.sleep(for: .seconds(max(0.01, until - t + 0.001)))
        }
    }
}

private struct TourScreen<Island: View>: View {
    @ViewBuilder let island: Island

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackdrop()
            island
        }
        .frame(width: TourPreview.size.width, height: TourPreview.size.height)
    }
}

private struct ScreenBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.28, blue: 0.42), Color(red: 0.29, green: 0.23, blue: 0.38),
                                    Color(red: 0.42, green: 0.29, blue: 0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { canvas, size in
                canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: TourPreview.band)), with: .color(.white.opacity(0.14)))
                for (x, width) in [(8, 5), (18, 14), (37, 10), (52, 12), (236, 6), (247, 6), (258, 8), (271, 20)] as [(CGFloat, CGFloat)] {
                    canvas.fill(Path(roundedRect: CGRect(x: x, y: 4, width: width, height: 4), cornerRadius: 2), with: .color(.white.opacity(0.6)))
                }
            }
            .flipsForRightToLeftLayoutDirection(true)
        }
    }
}

/// The island's outline, hanging from the middle of the top: it changes size without a new layout.
private struct HangingIsland: Shape {
    var size: CGSize
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        IslandShape(topRadius: 3, bottomRadius: radius)
            .path(in: CGRect(x: rect.midX - size.width / 2, y: rect.minY, width: size.width, height: size.height))
    }
}

private struct TourTabs: View {
    let chosen: NotchViews

    var body: some View {
        HStack(spacing: 7) {
            ForEach([NotchViews.home, .shelf, .agents, .sound], id: \.self) { tab in
                Image(systemName: tab.symbol)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(tab == chosen ? Color.notchAccent : .white.opacity(0.35))
            }
        }
        .padding(.leading, 10)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private enum Arrow {
    static let cursor = NSCursor.arrow
    static let image = Image(nsImage: cursor.image)
    static let scale: CGFloat = 0.6
    static let size = CGSize(width: cursor.image.size.width * scale, height: cursor.image.size.height * scale)
    static let tip = CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
}

private struct TourPointer: View {
    let at: CGPoint
    let pressed: Double
    let opacity: Double
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        let x = direction == .rightToLeft ? TourPreview.size.width - at.x : at.x
        Arrow.image
            .resizable()
            .frame(width: Arrow.size.width, height: Arrow.size.height)
            .scaleEffect(1 - 0.12 * pressed, anchor: UnitPoint(x: Arrow.tip.x / Arrow.size.width, y: Arrow.tip.y / Arrow.size.height))
            .offset(x: x - Arrow.tip.x, y: at.y - Arrow.tip.y)
            .opacity(opacity)
            .frame(width: TourPreview.size.width, height: TourPreview.size.height, alignment: .topLeading)
            .environment(\.layoutDirection, .leftToRight)
    }
}

private func textLine(_ width: CGFloat, _ opacity: Double = 0.55, height: CGFloat = 3) -> some View {
    Capsule().fill(.white.opacity(opacity)).frame(width: width, height: height)
}

private let artwork = LinearGradient(colors: [Color(red: 1, green: 0.48, blue: 0.35), Color(red: 0.76, green: 0.21, blue: 0.54),
                                              Color(red: 0.36, green: 0.25, blue: 0.82)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

/// Playback stays left to right in every language, as Apple has it.
private func transport(_ size: CGFloat) -> some View {
    HStack(spacing: size * 0.8) {
        Image(systemName: "backward.fill").opacity(0.7)
        Image(systemName: "play.fill")
        Image(systemName: "forward.fill").opacity(0.7)
    }
    .font(.system(size: size))
    .foregroundStyle(.white)
    .environment(\.layoutDirection, .leftToRight)
}

private func playhead(_ width: CGFloat, played: CGFloat) -> some View {
    textLine(width, 0.28, height: 2)
        .overlay(alignment: .leading) { textLine(played, height: 2) }
        .environment(\.layoutDirection, .leftToRight)
}

private extension View {
    func homeTile() -> some View {
        frame(width: 70, height: 62, alignment: .topLeading)
            .background(Color.notchRowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Hold to pin

struct FirstRunPinPreview: View {
    // When each part starts, in seconds: the pointer arrives and presses; PinHold does the rest.
    private static let pressed: TimeInterval = 0.7
    private static let armed = pressed + PinHold.quiet
    private static let committed = armed + PinHold.fill
    private static let closing = committed + PinHold.settle
    private static let closed = closing + 0.5
    private static let target = CGPoint(x: 73, y: 49)

    var body: some View {
        TourPlayer(stills: [Self.committed - 0.01, 3], moving: [0...Self.closed + 0.05, TourPreview.fading],
                   ticking: (Self.closed + 0.05)...TourPreview.fading.lowerBound) { t, clock in
            scene(at: t, clock: clock)
        }
    }

    private func scene(at t: TimeInterval, clock: TimeInterval?) -> some View {
        let part = TourPreview.part
        let closing = TourPreview.easeInOut(part(t, Self.closing, Self.closed))
        let move = TourPreview.easeInOut(part(t, 0, Self.pressed))
        // The others step back as the ring starts, and out once it closes (PinHoldTarget).
        let others = (1 - 0.58 * TourPreview.easeOut(part(t, Self.armed, Self.armed + 0.3))) * (1 - part(t, Self.committed, Self.committed + 0.14))
        let levels: [Double] = (0..<4).map { (bar: Int) -> Double in
            let n = Double(bar)
            guard let clock else { return 0.55 + 0.2 * sin(n * 1.7) }
            return 0.5 + 0.5 * abs(sin(clock * (3.1 + n * 0.9) + n))
        }
        return TourScreen {
            ZStack(alignment: .top) {
                PinHome(look: HeldLook(at: t, armed: Self.armed, committed: Self.committed), others: others)
                    .opacity(1 - part(t, Self.closing, Self.closing + 0.25))
                // In before Home is quite gone, so the island is never empty.
                NowPlayingAlone(levels: levels)
                    .opacity(part(t, Self.closing + 0.1, Self.closing + 0.4))
            }
            .frame(width: 240, height: 96, alignment: .top)
            .background(.black)
            .clipShape(HangingIsland(size: CGSize(width: TourPreview.mix(240, 196, closing), height: TourPreview.mix(96, 34, closing)),
                                     radius: TourPreview.mix(16, 11, closing)))
        }
        .overlay {
            TourPointer(at: TourPreview.mix(TourPreview.pointerStart, Self.target, move),
                        pressed: part(t, Self.pressed, Self.pressed + 0.1),
                        opacity: 1 - part(t, Self.closing, Self.closing + 0.2))
        }
    }
}

private struct PinHome: View {
    let look: HeldLook
    let others: Double

    var body: some View {
        VStack(spacing: 0) {
            TourTabs(chosen: .home).frame(height: 18, alignment: .top)
            HStack(spacing: 7) {
                HeldTile(look: look) { NowPlayingTile() }
                CalendarTile().opacity(others)
                QuickLaunchTile().opacity(others)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 240, height: 96)
    }
}

private struct NowPlayingTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(artwork).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) { textLine(28); textLine(20, 0.28) }
            }
            playhead(56, played: 22)
            transport(6).frame(maxWidth: .infinity)
        }
        .padding(7)
        .homeTile()
    }
}

private struct CalendarTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Color.red.opacity(0.85)).frame(width: 16, height: 3)
            textLine(40)
            ForEach([Color.cyan, .purple], id: \.self) { color in
                HStack(spacing: 3) {
                    Capsule().fill(color).frame(width: 2, height: 12)
                    VStack(alignment: .leading, spacing: 4) { textLine(40); textLine(24, 0.28) }
                }
            }
        }
        .padding(7)
        .homeTile()
    }
}

private struct QuickLaunchTile: View {
    var body: some View {
        let colors: [[Color]] = [[.cyan, .blue], [.yellow, .orange], [.green, .mint], [.white, .gray]]
        VStack(spacing: 8) {
            ForEach(0..<2) { row in
                HStack(spacing: 8) {
                    ForEach(0..<2) { column in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: colors[row * 2 + column], startPoint: .top, endPoint: .bottom))
                            .frame(width: 18, height: 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .homeTile()
    }
}

private struct NowPlayingAlone: View {
    let levels: [Double]

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(artwork).frame(width: 8, height: 8)
                    textLine(18, height: 2.5)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
                Color.clear.frame(width: TourPreview.camera)
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Color.notchAccent)
                    HStack(spacing: 1.5) {
                        ForEach(levels.indices, id: \.self) { bar in
                            Capsule().fill(Color.notchAccent).frame(width: 2, height: 8)
                                .scaleEffect(y: (2 + 6 * levels[bar]) / 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            }
            .frame(height: TourPreview.band)
            transport(5)
            playhead(148, played: 60)
            Spacer(minLength: 0)
        }
        .frame(width: 196, height: 34)
    }
}

private struct HeldLook: Equatable {
    var u = 0.0
    var flash = 0.0
    var tap: CGFloat = 1
    var ripple = -1.0

    init(at t: TimeInterval, armed: TimeInterval, committed: TimeInterval) {
        u = TourPreview.part(t, armed, committed)
        let since = t - committed
        guard since >= 0 else { return }
        flash = 0.6 * max(0, 1 - since / 0.26)
        tap = 1 + 0.22 * CGFloat(max(0, 1 - since / 0.2))
        ripple = min(1, since / 0.45)
    }
}

private struct HeldTile<Content: View>: View {
    let look: HeldLook
    @ViewBuilder let content: Content

    var body: some View {
        let u = look.u
        let eased = 1 - pow(1 - u, 2)
        // Like the real pin: grows in tilted, a little past full, upright as the ring closes.
        let grown = CGFloat(1 - exp(-6 * u) * cos(7.5 * u))
        content
            .scaleEffect(1 - 0.03 * eased)
            .overlay {
                if u > 0 {
                    ZStack {
                        HoldRing(radius: 11).stroke(Color.notchAccent.opacity(0.16 * eased), lineWidth: 1.2)
                        HoldRing(radius: 11).trim(from: 0, to: u).stroke(Color.notchAccent, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                            .brightness(look.flash)
                        HoldRing(radius: 11).stroke(Color.notchAccent.opacity(0.32 * eased), lineWidth: 4).blur(radius: 5)
                    }
                    .padding(-2.5)
                }
            }
            .overlay(alignment: .top) {
                if u > 0 {
                    ZStack {
                        if look.ripple >= 0, look.ripple < 1 {
                            Circle().stroke(Color.notchAccent, lineWidth: 1.2).scaleEffect(1 + 1.1 * look.ripple).opacity(0.9 * (1 - look.ripple))
                        }
                        Circle().fill(Color.notchAccent)
                            .overlay {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.85))
                                    .rotationEffect(.degrees(-40 * (1 - Double(grown))))
                            }
                            .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    }
                    .frame(width: 13, height: 13)
                    .scaleEffect((0.2 + 0.8 * grown) * look.tap)
                    .opacity(min(1, u * 4))
                    .offset(y: -3.5)
                }
            }
    }
}

// MARK: - A volume for each app

struct FirstRunMixerPreview: View {
    @Default(.soundBoost) private var boost
    // Music's slider (from its start, and how long) and Safari's icon, left to right: two tiles of
    // 120 by 48, 8 apart, under the tabs of an island 264 wide (MixerIsland).
    private static let left = (TourPreview.size.width - MixerIsland.width) / 2 + 8
    private static let bar = (x: left + 7, width: MixerTile.size.width - 14, y: MixerIsland.tabs + 33)
    private static let safariIcon = CGPoint(x: left + MixerTile.size.width + 8 + 7 + 6.5, y: MixerIsland.tabs + 15.5)

    var body: some View {
        TourPlayer(stills: [3.6], moving: [0...3.45, 4...4.45, TourPreview.fading]) { t, clock in
            scene(at: t, showsPointer: clock != nil)
        }
    }

    private func scene(at t: TimeInterval, showsPointer: Bool) -> some View {
        let part = TourPreview.part, ease = TourPreview.easeInOut
        let upper: Double = boost ? 2 : 1
        let from: Double = boost ? 0.5 : 0.3, to: Double = boost ? 1.5 : 0.8
        let level = from + (to - from) * ease(part(t, 0.7, 2))
        let onBar = { (level: Double) in CGPoint(x: Self.bar.x + Self.bar.width * CGFloat(level / upper), y: Self.bar.y) }
        let pointer = t < 0.7 ? TourPreview.mix(TourPreview.pointerStart, onBar(from), ease(part(t, 0, 0.6)))
            : t < 2.3 ? onBar(level)
            : TourPreview.mix(onBar(to), Self.safariIcon, ease(part(t, 2.3, 3)))
        let pressed = t < 2.2 ? part(t, 0.6, 0.7) - part(t, 2, 2.1) : part(t, 3.1, 3.18) - part(t, 3.2, 3.3)
        return TourScreen {
            MixerIsland(music: level, safariMuting: part(t, 3.2, 3.4), upper: upper)
        }
        .overlay {
            if showsPointer {
                TourPointer(at: pointer, pressed: pressed, opacity: 1 - part(t, 4, 4.4))
            }
        }
    }
}

private struct MixerIsland: View {
    static let width: CGFloat = 264
    static let tabs: CGFloat = 20
    let music: Double
    let safariMuting: Double
    let upper: Double

    var body: some View {
        VStack(spacing: 0) {
            TourTabs(chosen: .sound).frame(height: Self.tabs, alignment: .top)
            HStack(spacing: 8) {
                MixerTile(app: "com.apple.Music", level: music, upper: upper, muting: 0)
                MixerTile(app: "com.apple.Safari", level: 1, upper: upper, muting: safariMuting)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: 78)
        .background(.black)
        .clipShape(IslandShape(topRadius: 3, bottomRadius: 16))
    }
}

/// An app's tile as the Sound page has it, smaller; `muting` from 0 to 1 as its mute eases in.
private struct MixerTile: View {
    static let size = CGSize(width: 120, height: 48)
    let app: String
    let level: Double
    let upper: Double
    let muting: Double

    var body: some View {
        let muted = muting > 0
        let status = muted ? String(localized: "Muted") : level.formatted(.percent.precision(.fractionLength(0)))
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                AppIconView(bundleID: app, size: 13)
                    .overlay(alignment: .bottomTrailing) {
                        if muted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(1.5)
                                .background(.black.opacity(0.75), in: Circle())
                                .offset(x: 2, y: 2)
                                .scaleEffect(muting)
                        }
                    }
                    .opacity(1 - 0.5 * muting)
                Text(verbatim: AppInfo.name(bundleID: app) ?? (app == "com.apple.Music" ? "Music" : "Safari"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(status)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(!muted && level > 1 ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            .frame(height: 13)
            LevelSlider(value: level * (1 - muting), upper: upper, name: "", dimmed: muted) { _, _ in }
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 7)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.notchRowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

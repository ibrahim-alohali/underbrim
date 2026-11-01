//
//  RimLight.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A light that runs once along the island's rim (the glint, charging, unplugging, low battery); it
//  never loops or lasts over 2 s. Reduce Motion: the rim glows and fades in place. Increase Contrast:
//  no blur. The camera housing has no pixels, so closed, only the pill's sides and the glow show.
//

import SwiftUI

extension IslandShape {
    /// The outline's lower edge as an open path: trim 0.5 is the bottom centre, 0 and 1 the corners' tops.
    func rim(in size: CGSize) -> Path {
        let flare = floating ? 0 : min(max(0, topRadius), size.width / 2, size.height)
        let left = flare, right = size.width - flare
        let extent = floating ? Self.floatingExtent(size) : max(0, min(size.height - flare, (right - left) / 2))
        let r = max(0, min(bottomRadius, extent))
        let start = r > 0.01 ? (1 + min(0.6, extent / r - 1)) * r : 0
        var path = Path()
        path.move(to: CGPoint(x: left, y: size.height - start))
        Self.addCorner(to: &path, at: CGPoint(x: left, y: size.height), from: CGVector(dx: 0, dy: 1),
                       to: CGVector(dx: 1, dy: 0), radius: bottomRadius, extent: extent)
        Self.addCorner(to: &path, at: CGPoint(x: right, y: size.height), from: CGVector(dx: 1, dy: 0),
                       to: CGVector(dx: 0, dy: -1), radius: bottomRadius, extent: extent)
        return path
    }

    /// The outline but its top (the screen's edge): from `top` points down the left side (never above
    /// the flare), round the bottom and up the right. Trim 0.5 is the bottom centre. Floating, there's
    /// no screen edge to leave out: all of it, from the top centre.
    func edge(in size: CGSize, from top: CGFloat) -> Path {
        if floating { return Self.floatingPath(in: CGRect(origin: .zero, size: size), radius: bottomRadius) }
        let flare = min(max(0, topRadius), size.width / 2, size.height)
        let left = flare, right = size.width - flare
        let extent = max(0, min(size.height - flare, (right - left) / 2))
        let start = min(max(top, flare), size.height)
        var path = Path()
        path.move(to: CGPoint(x: left, y: start))
        Self.addCorner(to: &path, at: CGPoint(x: left, y: size.height), from: CGVector(dx: 0, dy: 1),
                       to: CGVector(dx: 1, dy: 0), radius: bottomRadius, extent: extent)
        Self.addCorner(to: &path, at: CGPoint(x: right, y: size.height), from: CGVector(dx: 1, dy: 0),
                       to: CGVector(dx: 0, dy: -1), radius: bottomRadius, extent: extent)
        path.addLine(to: CGPoint(x: right, y: start))
        return path
    }
}

struct RimLight: View {
    enum Kind: Equatable {
        /// The first run's and the adhan's: white streaks in the accent's glow, out from under the camera.
        case glint
        /// Plugged in: green fills the rim from under the camera up both sides, then fades.
        case charge
        /// Unplugged: the whole rim lights white and drains back under the camera as it fades.
        case drain
        /// Low battery: the rim glows red as two rings go out from it, radar-like.
        case alarm
    }

    let kind: Kind
    let shape: IslandShape
    let start: Date
    /// Where the rim starts down the sides: the menu-bar band's foot when open.
    var top: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// Done: no more frames (the notch can stay as it is for hours).
    @State private var done = false

    /// Room beyond the island for the glow, which the canvas would cut off; the alarm's rings go further.
    static func room(_ kind: Kind) -> CGFloat { kind == .alarm ? 30 : 12 }

    static func duration(_ kind: Kind, reduceMotion: Bool) -> TimeInterval {
        if reduceMotion { return Still.duration }
        switch kind {
        case .glint: return Glint.duration
        case .charge: return Charge.duration
        case .drain: return Drain.duration
        case .alarm: return Alarm.duration
        }
    }

    var body: some View {
        let accent = Color.notchAccent
        TimelineView(.animation(minimumInterval: nil, paused: done)) { context in
            RimLightFrame(kind: kind, shape: shape, t: context.date.timeIntervalSince(start), top: top, accent: accent,
                          reduceMotion: reduceMotion, crisp: contrast == .increased)
        }
        .opacity(done ? 0 : 1)
        .task(id: start) {
            done = false
            let end = start.addingTimeInterval(Self.duration(kind, reduceMotion: reduceMotion))
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            done = true
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    enum Glint {
        static let duration: TimeInterval = 1.2
    }

    /// Charging: how far the green has climbed (0 to 0.5 each way from the bottom centre), how bright, the breath.
    enum Charge {
        static let fill = 0.9, hold = 0.35, fade = 0.6
        static var duration: TimeInterval { fill + hold + fade }

        static func frame(at t: Double) -> (reach: Double, alpha: Double, breath: Double) {
            guard t > 0, t < duration else { return (0, 0, 0) }
            let u = min(t / fill, 1)
            let reach = 0.5 * (1 - pow(1 - u, 3))
            let alpha = t <= fill + hold ? 1 : max(0, 1 - (t - fill - hold) / fade)
            let breath = t > fill ? sin(min(1, (t - fill) / (hold + fade)) * .pi) : 0
            return (reach, alpha, breath)
        }
    }

    /// Unplugged: charging's fill run backwards; how much of the rim is still lit, and how bright.
    enum Drain {
        static let duration: TimeInterval = 0.85

        static func frame(at t: Double) -> (reach: Double, alpha: Double) {
            let u = t / duration
            guard u > 0, u < 1 else { return (0, 0) }
            return (0.5 * (1 - u * u * u), smoothstep(u / 0.14) * (1 - smoothstep((u - 0.4) / 0.6)))
        }
    }

    enum Alarm {
        static let ring = 1.1, gap = 0.45, reach: CGFloat = 20
        static var duration: TimeInterval { gap + ring }
        static let red = Color(red: 1, green: 0.27, blue: 0.23)

        static func rim(at t: Double) -> Double {
            guard t > 0, t < duration else { return 0 }
            return smoothstep(t / 0.2) * (1 - smoothstep((t - 0.5) / (duration - 0.5)))
        }

        static func rings(at t: Double) -> [(distance: CGFloat, alpha: Double)] {
            [0, gap].compactMap { start in
                let p = (t - start) / ring
                guard p > 0, p < 1 else { return nil }
                return (reach * CGFloat(1 - pow(1 - p, 2.2)), 0.8 * pow(1 - p, 1.4))
            }
        }
    }

    enum Still {
        static let duration: TimeInterval = 1.2

        static func alpha(at t: Double) -> Double {
            guard t > 0, t < duration else { return 0 }
            return smoothstep(t / 0.25) * (1 - smoothstep((t - 0.7) / 0.5))
        }
    }

    static func smoothstep(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// One frame of a rim light, `t` seconds in.
struct RimLightFrame: View {
    let kind: RimLight.Kind
    let shape: IslandShape
    let t: Double
    var top: CGFloat = 0
    let accent: Color
    var reduceMotion = false
    var crisp = false

    /// The light core of the green (the battery glyph's own, system green).
    static let greenCore = Color(red: 0.608, green: 0.902, blue: 0.667)

    var body: some View {
        let room = RimLight.room(kind)
        Canvas { canvas, size in
            canvas.translateBy(x: room, y: 0)
            let island = CGSize(width: max(0, size.width - 2 * room), height: max(0, size.height - room))
            switch kind {
            case .glint: glint(&canvas, island)
            case .charge: charge(&canvas, island)
            case .drain: drain(&canvas, island)
            case .alarm: alarm(&canvas, island)
            }
        }
        .padding(EdgeInsets(top: 0, leading: -room, bottom: -room, trailing: -room))
    }

    private func glow(_ canvas: inout GraphicsContext, _ path: Path, _ color: Color, width: CGFloat, blur: CGFloat, alpha: Double) {
        var layer = canvas
        if !crisp { layer.addFilter(.blur(radius: blur)) }
        layer.opacity = alpha
        layer.stroke(path, with: .color(color), lineWidth: crisp ? 2 : width)
    }

    private func glint(_ canvas: inout GraphicsContext, _ size: CGSize) {
        if reduceMotion {
            glow(&canvas, shape.edge(in: size, from: 0), accent, width: 3, blur: 4, alpha: 0.5 * RimLight.Still.alpha(at: t))
            return
        }
        let u = min(max(t / RimLight.Glint.duration, 0), 1)
        guard u > 0, u < 1 else { return }
        let rim = shape.rim(in: size)
        let travel = 0.5 * (0.5 - 0.5 * cos(.pi * u))
        let alpha = 0.55 * RimLight.smoothstep(u / 0.2) * (1 - RimLight.smoothstep((u - 0.55) / 0.45))
        // Both streaks in one path, so they don't add up where they meet.
        func streak(_ fraction: Double) -> Path {
            let half = 0.16 * fraction / 2
            var path = Path()
            for centre in [0.5 - travel, 0.5 + travel] {
                path.addPath(rim.trimmedPath(from: max(0, centre - half), to: min(1, centre + half)))
            }
            return path
        }
        glow(&canvas, streak(1), accent, width: 3, blur: 6, alpha: alpha)
        for i in 1...4 {
            var line = canvas
            line.opacity = alpha / 3
            line.stroke(streak(Double(i) / 4), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private func charge(_ canvas: inout GraphicsContext, _ size: CGSize) {
        let edge = shape.edge(in: size, from: top)
        if reduceMotion {
            glow(&canvas, edge, .green, width: 3, blur: 4, alpha: 0.6 * RimLight.Still.alpha(at: t))
            return
        }
        let frame = RimLight.Charge.frame(at: t)
        guard frame.alpha > 0, frame.reach > 0 else { return }
        let lit = edge.trimmedPath(from: 0.5 - frame.reach, to: 0.5 + frame.reach)
        glow(&canvas, lit, .green, width: 3, blur: 4, alpha: 0.85 * frame.alpha)
        var line = canvas
        line.opacity = frame.alpha
        line.stroke(lit, with: .color(.green), style: StrokeStyle(lineWidth: crisp ? 2 : 1.5, lineCap: .round))
        if t < RimLight.Charge.fill, !crisp {
            for front in [0.5 - frame.reach, 0.5 + frame.reach] {
                var head = canvas
                head.addFilter(.blur(radius: 1.5))
                head.stroke(edge.trimmedPath(from: max(0, front - 0.025), to: min(1, front + 0.025)),
                            with: .color(Self.greenCore), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        if frame.breath > 0, !crisp {
            glow(&canvas, edge, .green, width: 5, blur: 8, alpha: 0.5 * frame.breath * frame.alpha)
        }
    }

    private func drain(_ canvas: inout GraphicsContext, _ size: CGSize) {
        let edge = shape.edge(in: size, from: top)
        if reduceMotion {
            glow(&canvas, edge, .white, width: 3, blur: 4, alpha: 0.55 * RimLight.Still.alpha(at: t))
            return
        }
        let frame = RimLight.Drain.frame(at: t)
        guard frame.alpha > 0, frame.reach > 0 else { return }
        let lit = edge.trimmedPath(from: 0.5 - frame.reach, to: 0.5 + frame.reach)
        glow(&canvas, lit, .white, width: 3, blur: 4, alpha: 0.6 * frame.alpha)
        var line = canvas
        line.opacity = 0.85 * frame.alpha
        line.stroke(lit, with: .color(.white), style: StrokeStyle(lineWidth: crisp ? 2 : 1.3, lineCap: .round))
        guard !crisp, frame.reach > 0.02 else { return }
        for end in [0.5 - frame.reach, 0.5 + frame.reach] {
            var head = canvas
            head.addFilter(.blur(radius: 1.5))
            head.opacity = frame.alpha
            head.stroke(edge.trimmedPath(from: max(0, end - 0.02), to: min(1, end + 0.02)),
                        with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func alarm(_ canvas: inout GraphicsContext, _ size: CGSize) {
        let edge = shape.edge(in: size, from: top)
        let red = RimLight.Alarm.red
        if reduceMotion {
            glow(&canvas, edge, red, width: 3, blur: 4, alpha: 0.7 * RimLight.Still.alpha(at: t))
            return
        }
        let rim = RimLight.Alarm.rim(at: t)
        if rim > 0 {
            glow(&canvas, edge, red, width: 3, blur: 4, alpha: 0.75 * rim)
            var line = canvas
            line.opacity = 0.9 * rim
            line.stroke(edge, with: .color(red), style: StrokeStyle(lineWidth: crisp ? 2 : 1.3, lineCap: .round))
        }
        // The rings: the rim's own line grown out from the screen's edge.
        for ring in RimLight.Alarm.rings(at: t) {
            let w = size.width, h = size.height
            let out = CGAffineTransform(translationX: w / 2, y: 0)
                .scaledBy(x: (w + 2 * ring.distance) / max(w, 1), y: (h + ring.distance) / max(h, 1))
                .translatedBy(x: -w / 2, y: 0)
            glow(&canvas, edge.applying(out), red, width: 2.5, blur: crisp ? 0 : 2.5, alpha: ring.alpha)
        }
    }
}

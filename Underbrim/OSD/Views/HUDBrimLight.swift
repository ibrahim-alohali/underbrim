//
//  HUDBrimLight.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The closed HUD's level as light just inside the brim below the camera (NotchHUD.brim), on black so
//  it reads over any window and under the housing, which has no pixels; left to right in Arabic too.
//  Each update glows briefly, then nothing moves. Reduce Motion: it glows in place; Increase
//  Contrast: crisp lines, no glow.
//

import AppKit
import SwiftUI

struct HUDBrimLight: View {
    let level: CGFloat
    let type: SneakContentType
    let accent: Color?
    let updated: Date
    /// The last press it glowed for, kept by the notch as the light comes and goes.
    @Binding var lit: Date
    let shape: IslandShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// The kind and level the light last showed, to tell what an update changed.
    @State private var shown: (type: SneakContentType, level: CGFloat)?
    @State private var pulses: [Pulse] = []
    /// No pulse left to draw: no more frames.
    @State private var still = true

    static let inset: CGFloat = 1.8
    /// A pulse's whole life: the longest, a step's glow, is over by then.
    static let life: TimeInterval = 0.5

    private var tint: Color { DraggableProgressBar.tint(accent) }

    private var value: CGFloat { level.isFinite ? min(max(level, 0), 1) : 0 }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: still)) { context in
            lights(Glow(pulses: pulses, at: context.date, reduceMotion: reduceMotion))
        }
        .allowsHitTesting(false)
        // The level for VoiceOver, adjustable as the slider it opens into (a twentieth a step).
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(value) }, set: { NotchHUD.setLevel(CGFloat($0), for: type) }), in: 0...1, step: 0.05)
        }
        .accessibilityLabel(type.levelName)
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        // The press that brought the HUD up glows too (`onChange` doesn't see the value the light appears
        // with), once: not again when the light comes back.
        .onAppear {
            if updated > lit, Date.now.timeIntervalSince(updated) < Self.life { changed(at: updated) } else { shown = (type, value) }
        }
        .onChange(of: updated) { _, at in changed(at: at) }
        .task(id: pulses.last?.start) {
            guard let last = pulses.last?.start else { return }
            guard (try? await Task.sleep(for: .seconds(max(0, last.timeIntervalSinceNow + Self.life)))) != nil else { return }
            still = true
        }
    }

    private func changed(at: Date) {
        lit = at
        var new = [Pulse(kind: .press, start: at)]
        if let shown, shown.type == type {
            if value > shown.level + 0.001 {
                new.append(Pulse(kind: .add, from: shown.level, to: value, start: at))
            } else if value < shown.level - 0.001 {
                new.append(Pulse(kind: .remove, from: value, to: shown.level, start: at))
            } else if value < 0.001 || value > 0.999 {
                new.append(Pulse(kind: .edge, from: value, to: value, start: at))
            }
        } else {
            new.append(Pulse(kind: .add, from: 0, to: value, start: at))
        }
        shown = (type, value)
        pulses = pulses.filter { at.timeIntervalSince($0.start) < Self.life } + new
        still = false
    }

    @ViewBuilder
    private func lights(_ glow: Glow) -> some View {
        let crisp = contrast == .increased
        let tone = NSColor(tint)
        // The glow that falls on the window a little deeper; the step's core and the bloom lighter.
        let deep = Color(nsColor: tone.blended(withFraction: 0.12, of: .black) ?? tone)
        let core = Color(nsColor: tone.blended(withFraction: 0.45, of: .white) ?? tone)
        let hot = Color(nsColor: tone.blended(withFraction: 0.85, of: .white) ?? tone)
        let lift = reduceMotion ? glow.press : max(glow.step, glow.head)
        ZStack {
            Brim(island: shape).stroke(.white.opacity(0.16), lineWidth: 1.4)
            if !crisp {
                Brim(island: shape, to: value).stroke(deep, lineWidth: 5).blur(radius: 2.3).opacity(0.42 + 0.3 * lift)
            }
            Brim(island: shape, to: value).stroke(tint, lineWidth: crisp ? 2 : 2.2)
            if glow.ghost > 0 {
                Brim(island: shape, from: glow.ghostFrom, to: glow.ghostTo).stroke(tint, lineWidth: 2.2).opacity(0.85 * glow.ghost)
            }
            if glow.step > 0 {
                Brim(island: shape, from: glow.stepFrom, to: glow.stepTo).stroke(core, lineWidth: 3)
                    .blur(radius: crisp ? 0 : 0.9).opacity(glow.step)
            }
            if glow.head > 0, !crisp {
                let from = max(0, glow.headAt - 0.016), to = min(1, glow.headAt + 0.004)
                Brim(island: shape, from: from, to: to).stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .blur(radius: 4.2).opacity(0.75 * glow.head)
                Brim(island: shape, from: from, to: to).stroke(hot, style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                    .blur(radius: 0.9).opacity(glow.head)
            }
        }
    }

    private struct Pulse {
        enum Kind { case press, add, remove, edge }
        let kind: Kind
        var from: CGFloat = 0
        var to: CGFloat = 0
        let start: Date
    }

    private struct Glow {
        var press = 0.0, step = 0.0, head = 0.0, ghost = 0.0
        var stepFrom: CGFloat = 0, stepTo: CGFloat = 0, ghostFrom: CGFloat = 0, ghostTo: CGFloat = 0, headAt: CGFloat = 0

        init(pulses: [Pulse], at date: Date, reduceMotion: Bool) {
            for pulse in pulses {
                let u = date.timeIntervalSince(pulse.start)
                guard u >= 0, u < HUDBrimLight.life else { continue }
                if pulse.kind == .press {
                    press = max(press, reduceMotion ? Self.envelope(u, rise: 0.14, fall: 0.36) : Self.envelope(u))
                    continue
                }
                guard !reduceMotion else { continue }
                let s = Self.envelope(u)
                switch pulse.kind {
                case .add:
                    if s >= step { (step, stepFrom, stepTo) = (s, pulse.from, pulse.to) }
                    if s >= head { (head, headAt) = (s, pulse.to) }
                case .remove:
                    let g = pow(max(0, 1 - u / 0.3), 2)
                    if g >= ghost { (ghost, ghostFrom, ghostTo) = (g, pulse.from, pulse.to) }
                    if pulse.from > 0, 0.55 * s >= head { (head, headAt) = (0.55 * s, pulse.from) }
                case .edge:
                    if min(1, 1.35 * s) >= head { (head, headAt) = (min(1, 1.35 * s), pulse.from) }
                case .press:
                    break
                }
            }
        }

        static func envelope(_ u: Double, rise: Double = 0.05, fall: Double = 0.42) -> Double {
            u < rise ? 1 - pow(1 - u / rise, 2) : pow(max(0, 1 - (u - rise) / fall), 2)
        }
    }
}

/// The island's lower edge, `inset` inside, from `from` to `to` (0 left top, 1 right top); follows the frame as it resizes.
private struct Brim: Shape {
    let island: IslandShape
    var from: CGFloat = 0
    var to: CGFloat = 1

    /// Left to right in Arabic too (shapes mirror there by default).
    var layoutDirectionBehavior: LayoutDirectionBehavior { .fixed }

    func path(in rect: CGRect) -> Path {
        let d = HUDBrimLight.inset
        let inner = IslandShape(topRadius: island.topRadius, bottomRadius: max(0, island.bottomRadius - d), floating: island.floating)
        let rim = inner.rim(in: CGSize(width: max(0, rect.width - 2 * d), height: max(0, rect.height - d)))
            .offsetBy(dx: rect.minX + d, dy: rect.minY)
        return from <= 0 && to >= 1 ? rim : rim.trimmedPath(from: max(0, from), to: min(1, to))
    }
}

extension HUDBrimLight {
    /// The level whose end of the light is nearest `point`, in a frame of `size`: where a click or
    /// drag along the light puts it (Settings' Volume island). Measured at every percent, once per size.
    static func level(at point: CGPoint, in size: CGSize, shape: IslandShape) -> CGFloat {
        let ends: [CGPoint]
        if let measured, measured.size == size, measured.radii == [shape.topRadius, shape.bottomRadius] {
            ends = measured.ends
        } else {
            let brim = Brim(island: shape).path(in: CGRect(origin: .zero, size: size))
            ends = (0...100).compactMap { brim.trimmedPath(from: 0, to: max(0.0001, CGFloat($0) / 100)).currentPoint }
            measured = (size, [shape.topRadius, shape.bottomRadius], ends)
        }
        let nearest = ends.indices.min { hypot(ends[$0].x - point.x, ends[$0].y - point.y) < hypot(ends[$1].x - point.x, ends[$1].y - point.y) }
        return CGFloat(nearest ?? 0) / CGFloat(max(ends.count - 1, 1))
    }

    private static var measured: (size: CGSize, radii: [CGFloat], ends: [CGPoint])?
}

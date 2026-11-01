//
//  SlabCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Cursor's creature: the grey cube from the Cursor app's icon, seen from a little above
//  with its arrow folded over the front corner. Its sounds are key-click ticks and sine tones.
//

import SwiftUI

struct SlabCreature: AgentCreature {
    var box: CGSize { CGSize(width: 20, height: 20) }
    var overflow: CGFloat { 3 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(SlabArt.doneAct.count)
        case .failed: CreatureClock.seconds(SlabArt.failedFrames)
        case .stopped: CreatureClock.seconds(SlabArt.stopped.count)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        SlabArt.render(SlabArt.pose(for: frame), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        var graph = SynthGraph()
        var voices: [SynthGraph.Node] = []
        func envelope(_ start: Double, _ amp: Double, _ attack: Double, _ length: Double) -> SynthGraph.Param {
            SynthGraph.Param(0.0001).set(0.0001, at: start)
                .exponential(to: amp, at: start + attack).exponential(to: 0.0008, at: start + length)
        }
        /// A key click: a short burst of the seeded noise through a filter.
        func tick(_ kind: SynthGraph.FilterKind, _ hz: Double, q: Double, at start: Double, length: Double, amp: Double) {
            let noise = graph.noise(seed: 7, start: start, length: length + 0.01)
            let shaped = graph.filter(kind, hz: hz, q: q, noise)
            voices.append(graph.gain(envelope(start, amp, 0.001, length), shaped))
        }
        /// A tone: a sine and a faint octave above it, optionally dropping to a lower pitch.
        func tone(_ hz: Double, drop: (to: Double, seconds: Double)? = nil, at start: Double, length: Double,
                  amp: Double, attack: Double, octave: Double) {
            func sine(_ multiple: Double) -> SynthGraph.Node {
                var pitch = SynthGraph.Param(hz * multiple).set(hz * multiple, at: start)
                if let drop { pitch = pitch.exponential(to: drop.to * multiple, at: start + drop.seconds) }
                return graph.oscillator(.sine, frequency: pitch, start: start, stop: start + length + 0.02)
            }
            let main = sine(1)
            let level = envelope(start, amp, attack / 1000, length)
            if octave > 0 {
                let upper = graph.gain(octave, sine(2))
                voices.append(graph.gain(level, main, upper))
            } else {
                voices.append(graph.gain(level, main))
            }
        }
        let lowpass: Double, master: Double, seconds: Double
        switch cue {
        case .attention:
            tick(.bandpass, 3200, q: 1.2, at: 0, length: 0.012, amp: 0.5)
            tick(.bandpass, 3800, q: 1.2, at: 0.13, length: 0.012, amp: 0.5)
            tone(880, at: 0, length: 0.15, amp: 0.8, attack: 3, octave: 0.15)
            tone(1318.51, at: 0.13, length: 0.2, amp: 1, attack: 3, octave: 0.15)
            (lowpass, master, seconds) = (3600, 0.105, 0.38)
        case .done:
            tick(.bandpass, 3000, q: 1, at: 0, length: 0.012, amp: 0.45)
            tick(.bandpass, 3600, q: 1, at: 0.09, length: 0.012, amp: 0.35)
            tone(783.99, at: 0, length: 0.13, amp: 0.7, attack: 3, octave: 0.15)
            tone(1046.5, at: 0.09, length: 0.24, amp: 1, attack: 3, octave: 0.15)
            tone(1318.51, at: 0.115, length: 0.2, amp: 0.5, attack: 3, octave: 0.1)
            (lowpass, master, seconds) = (3800, 0.113, 0.38)
        case .failed:
            tick(.bandpass, 2200, q: 0.8, at: 0, length: 0.01, amp: 0.4)
            tick(.lowpass, 700, q: 0.7, at: 0.075, length: 0.02, amp: 0.6)
            tick(.lowpass, 600, q: 0.7, at: 0.18, length: 0.02, amp: 0.45)
            tone(246.94, drop: (190, 0.05), at: 0.075, length: 0.14, amp: 0.9, attack: 4, octave: 0.1)
            tone(196, drop: (146.83, 0.06), at: 0.18, length: 0.16, amp: 0.8, attack: 4, octave: 0.1)
            // The clicks and the low notes overlap, so the peak sits lower: a louder master
            // brings it to -18 dBFS like the others.
            (lowpass, master, seconds) = (1500, 0.1383, 0.39)
        }
        let mix = graph.gain(1)
        for voice in voices { graph.connect(voice, to: mix) }
        let soft = graph.filter(.lowpass, hz: lowpass, q: 0.5, mix)
        let output = graph.gain(master, soft)
        return (graph, output, seconds)
    }
}

// MARK: - Poses

private enum SlabArt {
    enum Glyph {
        case question, exclamation, stop, tick

        /// Its pixels on the eight by eight face, from the top: "#" white.
        var rows: [String] {
            switch self {
            case .question: ["........", "..###...", ".#...#..", ".....#..", "....#...", "...#....", "........", "...#...."]
            case .exclamation: ["........", "...##...", "...##...", "...##...", "...##...", "........", "...##...", "........"]
            case .stop: ["........", "........", "..####..", "..####..", "..####..", "..####..", "........", "........"]
            case .tick: ["........", ".......#", "......##", ".#...##.", ".##.##..", "..###...", "...#....", "........"]
            }
        }
    }

    struct Pose {
        /// Degrees round from the icon's view, and down from above (the icon's is 35).
        var turn = 0.0, pitch = 35.0
        var lift = 0
        /// The arrow lit as it clicks; the ripple off it (frames since the click).
        var glow = false
        var ripple: Int?
        /// 0: the icon's greys and white arrow; 1: darker, the arrow gone grey.
        var dim = 0.0
        var bits: Int?
        var glyph: Glyph?
    }

    static let doneFrames = 14, failedFrames = 8

    /// A hop of a quarter turn: a click and its ripple, then up, round and down.
    static func hop(_ f: Int) -> Pose {
        var p = Pose()
        if f == 1 { p.glow = true }
        if f >= 1, f < 4 { p.ripple = f - 1 }
        let lifts = [0, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0]
        p.lift = lifts[f]
        p.turn = 90 * Double(min(4, max(0, f - 4))) / 4
        return p
    }

    /// Four hops, each turning it a quarter round: a whole turn, so it ends as it began.
    static func working(_ f: Int) -> Pose {
        var p = hop(f % 12)
        p.turn += 90 * Double(f / 12)
        return p
    }

    static func attention(_ f: Int) -> Pose {
        var p = Pose()
        let lifts = [0, 2, 3, 3, 2, 0, 0, 1, 2, 2, 1, 0]
        if f < 12 { p.lift = lifts[f] }
        for click in [0, 6, 16] where f >= click && f < click + 3 {
            p.ripple = f - click
            p.glow = f == click
        }
        return p
    }

    static func done(_ f: Int) -> Pose {
        var p = Pose(glow: f < 10)
        let lifts = [0, 1, 2, 3, 3, 3, 3, 2, 1, 0]
        if f < lifts.count {
            p.lift = lifts[f]
            p.turn = 45 * Double(min(8, max(0, f - 1)))
        }
        if f >= 2, f < 11 { p.bits = f - 2 }
        return p
    }

    static func failed(_ f: Int) -> Pose {
        Pose(turn: f >= 2 ? -12 : 0, lift: f >= 2 ? -1 : 0, dim: min(1, Double(f) / 5))
    }

    /// Turned to face you square on, looking at it less from above, by `step` of 4. Its clicks light
    /// the mark on its front; a ripple off the top would run off the canvas.
    static func facing(_ step: Int, glyph: Glyph? = nil, lift: Int = 0, glow: Bool = false) -> Pose {
        Pose(turn: -45 * Double(step) / 4, pitch: 35 - 20 * Double(step) / 4, lift: lift, glow: glow, glyph: glyph)
    }

    static let questionStart: [Pose] = [facing(1, lift: 1), facing(2, lift: 2), facing(3, glyph: .question, lift: 2), facing(4, glyph: .question, lift: 1)]
    static let questionLoop: [Pose] = {
        func ask(_ turn: Double = 0, lift: Int = 0, glow: Bool = false) -> Pose {
            var p = facing(4, glyph: .question, lift: lift, glow: glow)
            p.turn += turn
            return p
        }
        func peer(_ side: Double) -> [Pose] {
            [ask(10 * side)] + [0, 0, 1, 1, 0, 0, 1, 1].map { ask(22 * side, lift: $0) } + [ask(10 * side)]
        }
        return Array(repeating: ask(), count: 8) + peer(-1) + [ask(), ask()] + peer(1) + [ask(), ask()]
            + [ask(lift: 1, glow: true), ask(lift: 2, glow: true), ask(lift: 1), ask()]
            + Array(repeating: ask(), count: 12)
    }()

    static let permissionStart: [Pose] = [facing(1, lift: 1), facing(2, lift: 2), facing(3, glyph: .exclamation, lift: 1), facing(4, glyph: .exclamation)]
    static let permissionLoop: [Pose] = (0..<24).map { f in
        let a = attention(f)
        return facing(4, glyph: .exclamation, lift: a.lift, glow: a.ripple != nil)
    }

    static let doneAct: [Pose] = (0..<doneFrames).map(done)
        + [facing(1), facing(2), facing(3, glyph: .tick, lift: 1), facing(4, glyph: .tick, lift: 1, glow: true), facing(4, glyph: .tick, glow: true)]
        + [facing(4, glyph: .tick)]

    static let stopped: [Pose] = [Pose(), Pose(lift: -1), Pose(), facing(1), facing(2), facing(3), facing(4, glyph: .stop, lift: 1)]
        + Array(repeating: facing(4, glyph: .stop), count: 5)

    static func pose(for frame: CreatureFrame) -> Pose {
        let f = frame.still ? nil : CreatureClock.frame(frame.elapsed)
        return switch frame.state {
        case .idle: Pose()
        case .working: f.map { working($0 % 48) } ?? Pose()
        case .question: CreatureClock.act(questionStart, questionLoop, f)
        case .permission: CreatureClock.act(permissionStart, permissionLoop, f)
        case .done: CreatureClock.once(doneAct, f)
        case .failed: failed(min(f ?? failedFrames, failedFrames))
        case .stopped: CreatureClock.once(stopped, f)
        }
    }

    // MARK: - Model

    static let palette: [PixelColor] = [PixelColor(124, 123, 120), PixelColor(250, 250, 250), PixelColor(206, 206, 204), PixelColor(255, 255, 255)]
    static let size = 8
    /// Lit from above and to the left, as the icon's facets are: the top lightest, the right darkest.
    static let light = VoxelLight(from: SIMD3(-0.45, -1, -0.5), ambient: 0.42)

    /// The cube, with the arrow over its front corner: the near half of the top white, the near half
    /// of the right face pale.
    static func model(_ pose: Pose) -> VoxelModel {
        var m = VoxelModel(width: size, height: size, depth: size)
        m.fill(0, 0, 0, size, size, size, 1)
        let white: UInt8 = pose.glow ? 4 : 2
        for x in 0..<size {
            for z in 0..<size where x + z < size { m[x, 0, z] = white }
            for y in 0..<size where x + y < size { m[x, y, 0] = 3 }
        }
        if let glyph = pose.glyph {
            for (y, row) in glyph.rows.enumerated() {
                for (x, character) in row.enumerated() { m[x, y, 0] = character == "#" ? white : 1 }
            }
        }
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        let half = Double(size) / 2
        let yaw = (45 + pose.turn).truncatingRemainder(dividingBy: 360)
        var view = VoxelView(yaw: yaw, pitch: pose.pitch, pivot: (half, half, half), at: (Double(canvas.columns) / 2, 0))
        // Standing on the floor: its lowest corner, as it is turned now, on the floor.
        let lowest = [0.0, Double(size)].flatMap { x in [0.0, Double(size)].flatMap { y in [0.0, Double(size)].map { z in view.project(x, y, z).y } } }.max()!
        view.at.y = Double(canvas.floor - pose.lift) - lowest
        let dim = pose.dim
        Voxels.draw(model(pose), palette: palette, view: view, into: &image, light: light,
                    tone: dim > 0 ? { $0.mixed(with: $0.greyed.scaled(0.7), dim) } : nil)
        let top = view.project(half, 0, half)
        if let ripple = pose.ripple {
            image.ring(around: (top.x, top.y - 1), radius: 2 + 1.5 * Double(ripple), PixelColor(255, 255, 255), alpha: 0.8 - 0.25 * Double(ripple))
        }
        if let bits = pose.bits {
            let middle = view.project(half, half, half), distance = 6 + 1.1 * Double(bits)
            for k in 0..<5 {
                let angle = (-90 + 72 * Double(k) + 20) * .pi / 180
                image.set(Int((middle.x + distance * cos(angle)).rounded(.down)),
                          Int((middle.y + distance * sin(angle) + 0.15 * Double(bits * bits)).rounded(.down)),
                          k % 2 == 0 ? palette[1] : palette[2], alpha: 1 - Double(bits) / 9)
            }
        }
        return image
    }
}

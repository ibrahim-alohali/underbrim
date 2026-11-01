//
//  MoteCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Codex's creature: the cloud from the Codex app's icon, lilac to deep blue, with its
//  white ">_" prompt on the front. Its sounds are soft FM bells.
//

import SwiftUI

struct MoteCreature: AgentCreature {
    var box: CGSize { CGSize(width: 22, height: 20) }
    var overflow: CGFloat { 3 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(MoteArt.doneFrames)
        case .failed: CreatureClock.seconds(MoteArt.failedFrames)
        case .stopped: CreatureClock.seconds(MoteArt.stopped.count)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        MoteArt.render(MoteArt.pose(for: frame), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        var graph = SynthGraph()
        var voices: [SynthGraph.Node] = []
        /// One bell: a sine carrier with an FM partner that fades out over 60 percent of the note.
        func note(_ hz: Double, glide: (to: Double, seconds: Double)? = nil, at start: Double, length: Double,
                  amp: Double, attack: Double = 0.008, ratio: Double, index: Double) {
            let stop = start + length + 0.02
            let modulator = graph.oscillator(.sine, hz: hz * ratio, start: start, stop: stop)
            let depth = SynthGraph.Param(index * hz).set(index * hz, at: start)
                .exponential(to: 0.001 * index * hz, at: start + length * 0.6)
            let swing = graph.gain(depth, modulator)
            var pitch = SynthGraph.Param(hz).set(hz, at: start)
            if let glide { pitch = pitch.exponential(to: glide.to, at: start + glide.seconds) }
            let carrier = graph.oscillator(.sine, frequency: pitch, start: start, stop: stop)
            graph.modulate(frequencyOf: carrier, by: swing)
            let level = SynthGraph.Param(0.0001).set(0.0001, at: start)
                .exponential(to: amp, at: start + attack).exponential(to: 0.0008, at: start + length)
            voices.append(graph.gain(level, carrier))
        }
        let lowpass: Double, master: Double, seconds: Double
        switch cue {
        case .attention:
            note(659.25, at: 0, length: 0.23, amp: 0.8, ratio: 2, index: 1.2)
            note(880, at: 0.15, length: 0.23, amp: 1, ratio: 2, index: 1.2)
            (lowpass, master, seconds) = (5000, 0.12, 0.43)
        case .done:
            note(523.25, at: 0, length: 0.2, amp: 0.7, ratio: 1, index: 0.6)
            note(659.25, at: 0.085, length: 0.2, amp: 0.8, ratio: 1, index: 0.6)
            note(783.99, at: 0.17, length: 0.22, amp: 1, ratio: 1, index: 0.6)
            (lowpass, master, seconds) = (4500, 0.12, 0.44)
        case .failed:
            note(311.13, glide: (233.08, 0.26), at: 0, length: 0.24, amp: 1, attack: 0.02, ratio: 1, index: 0.4)
            note(246.94, glide: (196, 0.2), at: 0.14, length: 0.24, amp: 0.7, attack: 0.02, ratio: 1, index: 0.4)
            (lowpass, master, seconds) = (1800, 0.12, 0.43)
        }
        let mix = graph.gain(1)
        for voice in voices { graph.connect(voice, to: mix) }
        let soft = graph.filter(.lowpass, hz: lowpass, q: 0.5, mix)
        let output = graph.gain(master, soft)
        return (graph, output, seconds)
    }
}

// MARK: - Poses

private enum MoteArt {
    enum Glyph { case prompt, tick, cross, question, exclamation, stop }

    struct Pose {
        var glyph = Glyph.prompt
        var cursor = true
        /// The chevron pushed a pixel right as a line goes in.
        var nudge = false
        var yaw = 0.0
        var lift = 0, dx = 0
        /// 0: its own blues; 1: rain-cloud grey.
        var grey = 0.0
        var ring: (radius: Double, alpha: Double)?
        /// Sparks flying out (frames since the leap), and rain falling (frames since it greyed).
        var sparks: Int?, rain: Int?

    }

    static let loop = 48, doneFrames = 14, failedFrames = 12

    /// Working: looks side to side, bobs, blinks its cursor and enters two lines; each repeats
    /// a whole number of times in the loop.
    static func working(_ f: Int) -> Pose {
        var p = Pose()
        let turn = 22 * sin(2 * .pi * Double(f) / Double(loop))
        p.yaw = [-22.0, -12, 0, 12, 22].min { abs($0 - turn) < abs($1 - turn) }!
        p.lift = f % 24 < 12 ? 0 : 1
        p.cursor = f % 12 < 6
        if f % 24 == 10 || f % 24 == 11 {
            p.nudge = true
            p.cursor = false
            p.lift += 1
        }
        return p
    }

    static func attention(_ f: Int) -> Pose {
        var p = Pose()
        let hops = [0, 2, 3, 3, 2, 0, 0, 1, 2, 2, 1, 0]
        p.lift = f < hops.count ? hops[f] : 0
        p.cursor = f % 4 < 2
        if f >= 14, f < 18 { p.yaw = f < 16 ? -12 : 12 }
        // The ring goes out as it hops and comes back in, faint, as it rests.
        p.ring = f < 12 ? (7 + 0.14 * Double(f), 0.85 * (1 - Double(f) / 12)) : f >= 18 ? (7.5, 0.4) : nil
        return p
    }

    static let questionStart: [Pose] = [Pose(cursor: false)] + [1, 2, 1].map { Pose(glyph: .question, lift: $0) }
    static let questionLoop: [Pose] = {
        func ask(yaw: Double = 0, lift: Int = 0, dx: Int = 0) -> Pose { Pose(glyph: .question, yaw: yaw, lift: lift, dx: dx) }
        func peer(_ side: Double) -> [Pose] {
            let lean = Int(side)
            return [ask(yaw: 12 * side), ask(yaw: 22 * side, dx: lean)] + [0, 1, 1, 0, 0, 1, 1, 0].map { ask(yaw: 22 * side, lift: $0, dx: lean) }
                + [ask(yaw: 12 * side)]
        }
        return Array(repeating: ask(), count: 8) + peer(-1) + [ask(), ask(), ask()] + peer(1) + [ask(), ask(), ask()]
            + [1, 2, 1, 0].map { ask(lift: $0) } + Array(repeating: ask(), count: 8)
    }()

    static let permissionStart: [Pose] = [Pose(cursor: false), Pose(glyph: .exclamation)]
    static let permissionLoop: [Pose] = (0..<24).map { f in
        var p = attention(f)
        p.glyph = .exclamation
        return p
    }

    static let stopped: [Pose] = [Pose(cursor: false), Pose(cursor: false, lift: 1), Pose(cursor: false, dx: 1), Pose(cursor: false, dx: -1)]
        + [Pose(glyph: .stop, dx: 1), Pose(glyph: .stop), Pose(glyph: .stop), Pose(glyph: .stop, lift: -1), Pose(glyph: .stop, lift: -1)]
        + Array(repeating: Pose(glyph: .stop), count: 3)

    static func done(_ f: Int) -> Pose {
        var p = Pose(glyph: f >= 2 ? .tick : .prompt)
        let lifts = [0, 1, 2, 3, 3, 3, 3, 2, 1, 0]
        if f < lifts.count {
            p.lift = lifts[f]
            p.yaw = 45 * Double(min(8, max(0, f - 1)))
        }
        if f >= 3, f < 11 { p.sparks = f - 3 }
        return p
    }

    static func failed(_ f: Int) -> Pose {
        var p = Pose(glyph: f >= 1 ? .cross : .prompt)
        p.grey = min(1, Double(f) / 4)
        p.lift = f >= 2 ? -1 : 0
        p.dx = f < 4 ? [1, -1, 1, 0][f] : 0
        if f >= 2, f < failedFrames { p.rain = f - 2 }
        return p
    }

    static func pose(for frame: CreatureFrame) -> Pose {
        let f = frame.still ? nil : CreatureClock.frame(frame.elapsed)
        return switch frame.state {
        case .idle: Pose()
        case .working: f.map { working($0 % loop) } ?? Pose(yaw: 12)
        case .question: CreatureClock.act(questionStart, questionLoop, f)
        case .permission: CreatureClock.act(permissionStart, permissionLoop, f)
        case .done: done(min(f ?? doneFrames, doneFrames))
        case .failed: failed(min(f ?? failedFrames, failedFrames))
        case .stopped: CreatureClock.once(stopped, f)
        }
    }

    // MARK: - Model

    /// Its shading top to bottom, measured down the middle of the icon's cloud, in bands; then the prompt's white.
    static let palette: [PixelColor] = [
        PixelColor(192, 190, 250), PixelColor(190, 173, 249), PixelColor(160, 148, 248), PixelColor(120, 132, 247),
        PixelColor(119, 146, 249), PixelColor(122, 150, 248), PixelColor(88, 102, 246), PixelColor(54, 48, 245),
        PixelColor(48, 40, 245), PixelColor(242, 245, 255),
    ]
    static let white: UInt8 = 10
    static let lilac = PixelColor(190, 173, 249), rainBlue = PixelColor(150, 165, 200)

    static let width = 14, height = 13, depth = 6
    /// The cloud's middle and radius, from the icon: six lobes half its radius, half its radius out.
    static let center = SIMD3(7.0, 6.5, 3.0), radius = 6.4

    /// The icon's outline pushed back into a cushion: flat on the front, its rim set back a cell
    /// so it rounds off as it turns, shaded in bands from top to bottom.
    static let cloud: VoxelModel = {
        var m = VoxelModel(width: width, height: height, depth: depth)
        func inside(_ x: Int, _ y: Int) -> Bool {
            let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            return (0..<6).contains { k in
                let angle = (15 + 60 * Double(k)) * .pi / 180
                let lobe = SIMD2(center.x + 0.5 * radius * cos(angle), center.y + 0.5 * radius * sin(angle))
                return ((p - lobe) * (p - lobe)).sum() <= 0.25 * radius * radius + 0.4
            }
        }
        m.extrude({ x, y in
            guard inside(x, y) else { return 0 }
            let rim = !(inside(x - 1, y) && inside(x + 1, y) && inside(x, y - 1) && inside(x, y + 1))
            return rim ? depth - 2 : depth
        }, color: { _, y in
            let band = (Double(y) + 0.5 - (center.y - radius)) / (2 * radius)
            return UInt8(min(9, max(1, Int(band * 9) + 1)))
        })
        return m
    }()

    static func model(_ pose: Pose) -> VoxelModel {
        var m = cloud
        let marks: [(Int, Int)] = switch pose.glyph {
        case .prompt:
            [(4, 5), (5, 6), (4, 7)].map { ($0.0 + (pose.nudge ? 1 : 0), $0.1) } + (pose.cursor ? [(7, 8), (8, 8), (9, 8)] : [])
        case .tick: [(4, 6), (5, 7), (6, 8), (7, 7), (8, 6), (9, 5), (10, 4)]
        case .cross: [(5, 4), (6, 5), (7, 6), (8, 7), (9, 8), (9, 4), (8, 5), (6, 7), (5, 8)]
        case .question: [(6, 4), (7, 4), (5, 5), (8, 5), (7, 6), (7, 8)]
        case .exclamation: [(6, 4), (7, 4), (6, 5), (7, 5), (6, 6), (7, 6), (6, 8), (7, 8)]
        case .stop: (5...8).flatMap { x in (5...8).map { (x, $0) } }
        }
        for (x, y) in marks { m.paintFront(x, y, white) }
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        let x = Double(canvas.middle + pose.dx)
        let view = VoxelView(yaw: pose.yaw, pivot: (7, Double(height), center.z), at: (x, Double(canvas.floor - pose.lift)))
        let middle = view.project(center.x, center.y, center.z)
        if let ring = pose.ring {
            // Round where it stands, not where it hops to, so the ring stays on the canvas.
            image.ring(around: (middle.x, middle.y + Double(pose.lift)), radius: ring.radius, lilac, alpha: ring.alpha)
        }
        let grey = pose.grey
        Voxels.draw(model(pose), palette: palette, view: view, into: &image,
                    tone: grey > 0 ? { $0.mixed(with: $0.greyed, grey) } : nil)
        if let spark = pose.sparks {
            let distance = 7 + 1.2 * Double(spark), fade = 1 - Double(spark) / 8
            for k in 0..<8 {
                let angle = (-90 + 45 * Double(k)) * .pi / 180
                image.set(Int((middle.x + distance * cos(angle)).rounded(.down)), Int((middle.y + distance * sin(angle)).rounded(.down)),
                          k % 2 == 0 ? palette[9] : lilac, alpha: fade)
            }
        }
        if let rain = pose.rain {
            let bottom = Int(view.project(center.x, center.y + radius, center.z).y.rounded(.down))
            for (k, offset) in [-3, 0, 3].enumerated() {
                let fall = rain - 2 * k
                guard fall >= 0, fall < 5 else { continue }
                let column = Int(middle.x.rounded(.down)) + offset
                image.set(column, bottom + fall, rainBlue, alpha: 1 - Double(fall) / 5)
                image.set(column, bottom + fall - 1, rainBlue, alpha: 0.5 * (1 - Double(fall) / 5))
            }
        }
        return image
    }
}

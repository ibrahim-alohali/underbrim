//
//  QoderCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Qoder's creature: the green block-pixel "Q" from the Qoder CLI's welcome banner, its
//  dot the eye, three blocks deep over a line of code. Its sounds are soft wooden plucks.
//

import SwiftUI

struct QoderCreature: AgentCreature {
    /// 20 x 20 pt: the Q is 15 pt square, over a line of code along the bottom.
    var box: CGSize { CGSize(width: 20, height: 20) }
    var overflow: CGFloat { 3 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(QoderArt.doneAct.count)
        case .failed: CreatureClock.seconds(QoderArt.failedFrames)
        case .stopped: CreatureClock.seconds(QoderArt.stopped.count)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        QoderArt.render(QoderArt.pose(for: frame), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        var graph = SynthGraph()
        var voices: [SynthGraph.Node] = []
        /// A sine voice that starts 3 percent sharp and settles in 14 ms; `fall` drops it a little over its length.
        func voice(_ hz: Double, at start: Double, length: Double, level: Double, fall: Double) {
            var pitch = SynthGraph.Param(hz * 1.03).set(hz * 1.03, at: start).exponential(to: hz, at: start + 0.014)
            if fall > 0 { pitch = pitch.exponential(to: hz * (1 - fall), at: start + length) }
            let oscillator = graph.oscillator(.sine, frequency: pitch, start: start, stop: start + length + 0.02)
            let envelope = SynthGraph.Param(0.0001).set(0.0001, at: start)
                .exponential(to: level, at: start + 0.004).exponential(to: 0.0008, at: start + length)
            voices.append(graph.gain(envelope, oscillator))
        }
        /// A pluck: the note, a fast-dying overtone two octaves up, and a very quiet band-passed tick at the start.
        func pluck(_ hz: Double, at start: Double, length: Double, amp: Double, overtone: Double, tick: Double, fall: Double = 0) {
            voice(hz, at: start, length: length, level: amp, fall: fall)
            voice(hz * 4, at: start, length: length * 0.3, level: amp * overtone, fall: fall)
            let noise = graph.noise(seed: 7, start: start, length: 0.03)
            let band = graph.filter(.bandpass, hz: 2200, q: 1.2, noise)
            let envelope = SynthGraph.Param(0.0001).set(0.0001, at: start)
                .exponential(to: amp * tick, at: start + 0.002).exponential(to: 0.0008, at: start + 0.014)
            voices.append(graph.gain(envelope, band))
        }
        let lowpass: Double, master: Double, seconds: Double
        switch cue {
        case .attention:
            pluck(466.16, at: 0, length: 0.24, amp: 0.9, overtone: 0.22, tick: 0.14)
            pluck(698.46, at: 0.135, length: 0.27, amp: 1, overtone: 0.22, tick: 0.14)
            (lowpass, master, seconds) = (3200, 0.104, 0.46)
        case .done:
            pluck(587.33, at: 0, length: 0.2, amp: 0.75, overtone: 0.20, tick: 0.12)
            pluck(739.99, at: 0.07, length: 0.2, amp: 0.8, overtone: 0.20, tick: 0.12)
            pluck(880, at: 0.14, length: 0.2, amp: 0.9, overtone: 0.18, tick: 0.12)
            pluck(1174.66, at: 0.215, length: 0.17, amp: 0.55, overtone: 0.08, tick: 0.08)
            // A little quieter than its notes alone suggest, so it peaks at -18 dBFS like the others.
            (lowpass, master, seconds) = (3600, 0.1167, 0.45)
        case .failed:
            pluck(329.63, at: 0, length: 0.19, amp: 0.9, overtone: 0.10, tick: 0.10, fall: 0.015)
            pluck(261.63, at: 0.12, length: 0.22, amp: 1, overtone: 0.08, tick: 0.10, fall: 0.03)
            (lowpass, master, seconds) = (1500, 0.123, 0.40)
        }
        let mix = graph.gain(1)
        for voice in voices { graph.connect(voice, to: mix) }
        let soft = graph.filter(.lowpass, hz: lowpass, q: 0.5, mix)
        let output = graph.gain(master, soft)
        return (graph, output, seconds)
    }
}

// MARK: - Poses

private enum QoderArt {
    struct Pose {
        var lift = 0
        var yaw = 0.0
        /// 0: its green; 1: the bright flash; -1: dimmed.
        var light = 0.0
        var dotOn = true
        /// How far the code has scrolled, in pixels; nil: no line.
        var scroll: Int?
        /// Dust either side as it lands; sparks flying out (frames since).
        var dust = false
        var sparks: Int?
        /// Where its dot looks, in the banner's pixels from the middle: (1, -1) up and to the right.
        var look = (0, 0)
        /// A mark by its top right corner, pixels it bobs up; and one over it.
        var mark: CreatureMark?, bob = 0, thought: CreatureMark?
    }

    static let loop = 48, doneFrames = 14, failedFrames = 8
    static let hops = [0, 0, 1, 2, 2, 1, 0, 0, 0, 0, 0, 0]
    static let facing = [16.0, 0, -16, 0]

    static func working(_ f: Int) -> Pose {
        var p = Pose()
        let hop = f / 12, step = f % 12
        p.lift = hops[step]
        // It turns while it's up: halfway on the way up, all the way at the top.
        let from = facing[(hop + 3) % 4], to = facing[hop]
        p.yaw = step < 2 ? from : step == 2 ? (from + to) / 2 : to
        p.dust = step == 6
        p.dotOn = f % 12 < 9
        p.scroll = f
        return p
    }

    static func attention(_ f: Int) -> Pose {
        var p = Pose(scroll: 0)
        let lifts = [0, 2, 3, 3, 2, 0, 0, 1, 2, 2, 1, 0]
        if f < 12 { p.lift = lifts[f] }
        p.light = f < 12 && p.lift >= 2 ? 1 : 0
        p.dust = f == 5 || f == 11
        if f >= 1, f < 8 { p.sparks = f - 1 }
        p.dotOn = f % 4 < 2 || f >= 20
        return p
    }

    static func done(_ f: Int) -> Pose {
        var p = Pose(scroll: 0)
        let lifts = [0, 1, 2, 3, 3, 3, 3, 2, 1, 0]
        if f < lifts.count {
            p.lift = lifts[f]
            p.yaw = 45 * Double(min(8, max(0, f - 1)))
        }
        p.light = f >= 2 && f < 10 ? 1 : 0
        p.dust = f == 10
        if f >= 4, f < 12 { p.sparks = f - 4 }
        return p
    }

    static func failed(_ f: Int) -> Pose {
        Pose(lift: f >= 2 ? -1 : 0, light: -min(1, Double(f) / 5), dotOn: false, scroll: 0)
    }

    static let questionStart: [Pose] = [Pose(scroll: 0, mark: .twinkle(1)), Pose(scroll: 0, mark: .question, bob: 1), Pose(scroll: 0, mark: .question)]
    static let questionLoop: [Pose] = {
        func ask(look: (Int, Int) = (0, 0), yaw: Double = 0, lift: Int = 0, dotOn: Bool = true) -> Pose {
            Pose(lift: lift, yaw: yaw, dotOn: dotOn, scroll: 0, look: look, mark: .question)
        }
        let up = [0, 0, 1, 1, 0, 0, 1, 1, 0, 0].map { ask(look: (1, -1), yaw: 14, lift: $0) }
        return Array(repeating: ask(), count: 6) + [ask(look: (1, 0)), ask(look: (1, 0), yaw: 7)] + up
            + [ask(look: (1, 0), yaw: 7)] + Array(repeating: ask(), count: 7) + [ask(dotOn: false), ask(dotOn: false)]
            + [1, 2, 1, 0].map { ask(lift: $0) } + Array(repeating: ask(), count: 16)
    }()

    static let permissionStart: [Pose] = [Pose(scroll: 0, mark: .twinkle(1)), Pose(scroll: 0, mark: .exclamation, bob: 1)]
    static let permissionLoop: [Pose] = (0..<24).map { f in
        var p = attention(f)
        p.mark = .exclamation
        return p
    }

    static let doneAct: [Pose] = (0..<doneFrames).map(done)
        + [Pose(scroll: 0, mark: .twinkle(1)), Pose(scroll: 0, mark: .tick, bob: 1), Pose(scroll: 0, mark: .tick)]
        + [1, 2, 1, 0].map { Pose(lift: $0, scroll: 0, mark: .tick) } + [Pose(scroll: 0, mark: .tick)]

    static let stopped: [Pose] = [Pose(lift: 2, scroll: 4), Pose(lift: 2, scroll: 4), Pose(lift: 1, scroll: 4), Pose(scroll: 4, dust: true),
                                  Pose(scroll: 4), Pose(dotOn: false, scroll: 4), Pose(scroll: 4)]
        + [1, 1, 2, 2, 3, 3].map { Pose(scroll: 4, thought: .dots($0)) }

    static func pose(for frame: CreatureFrame) -> Pose {
        let f = frame.still ? nil : CreatureClock.frame(frame.elapsed)
        return switch frame.state {
        case .idle: Pose()
        case .working: f.map { working($0 % loop) } ?? Pose(scroll: 0)
        case .question: CreatureClock.act(questionStart, questionLoop, f)
        case .permission: CreatureClock.act(permissionStart, permissionLoop, f)
        case .done: CreatureClock.once(doneAct, f)
        case .failed: failed(min(f ?? failedFrames, failedFrames))
        case .stopped: CreatureClock.once(stopped, f)
        }
    }

    // MARK: - Model

    /// The banner's Q, a row of five pixels per string, each two of ours; its dot in the middle.
    static let rows = [".###.", "#...#", "#.#.#", "#..#.", ".##.#"]
    static let dot = (x: 2, y: 2)
    static let palette = [PixelColor(39, 189, 81), PixelColor(140, 240, 160), PixelColor(64, 96, 74)]
    static let green = palette[0], bright = palette[1], dim = palette[2]
    /// The line of code: dash lengths in pixels, alternately code and gap; the pattern is 12 long,
    /// so it repeats four times a loop.
    static let dashes = [2, 1, 3, 1, 1, 1, 2, 1]
    static let size = 10, depth = 3

    static func model(_ pose: Pose) -> VoxelModel {
        var m = VoxelModel(width: size, height: size, depth: depth)
        let eye = (x: dot.x + pose.look.0, y: dot.y + pose.look.1)
        for (y, row) in rows.enumerated() {
            for (x, cell) in row.enumerated() where cell == "#" && (x, y) != dot {
                m.fill(2 * x, 2 * y, 0, 2, 2, depth, 1)
            }
        }
        m.fill(2 * eye.x, 2 * eye.y, 0, 2, 2, depth, pose.dotOn ? 2 : 3)
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        let line = canvas.floor - 1
        if let scroll = pose.scroll {
            let period = dashes.reduce(0, +)
            for x in 0..<canvas.columns {
                var u = ((x + scroll) % period + period) % period, k = 0
                while u >= dashes[k] { u -= dashes[k]; k += 1 }
                if k % 2 == 0 { image.set(x, line, green, alpha: 0.45) }
            }
        }
        let half = Double(size) / 2
        let view = VoxelView(yaw: pose.yaw, pivot: (half, Double(size), Double(depth) / 2),
                             at: (Double(canvas.columns) / 2, Double(line - pose.lift)))
        let light = pose.light
        Voxels.draw(model(pose), palette: palette, view: view, into: &image,
                    tone: light > 0 ? { $0.mixed(with: PixelColor(220, 255, 225), 0.35 * light) }
                        : light < 0 ? { $0.mixed(with: $0.greyed.scaled(0.55), -light) } : nil)
        if pose.dust {
            let left = Int(view.project(0, Double(size), half).x.rounded(.down)), right = Int(view.project(Double(size), Double(size), half).x.rounded(.down))
            for x in [left - 2, left - 1, right, right + 1] { image.set(x, line - 1, PixelColor(150, 150, 150), alpha: 0.7) }
        }
        if let spark = pose.sparks {
            let center = view.project(half, half, half), distance = 7 + Double(spark)
            for k in 0..<4 {
                let angle = (-135 + 90 * Double(k)) * .pi / 180
                image.set(Int((center.x + distance * cos(angle)).rounded(.down)), Int((center.y + distance * sin(angle)).rounded(.down)),
                          bright, alpha: 1 - Double(spark) / 8)
            }
        }
        // Marks keep their place as it hops: by its top right corner, and over it.
        if let mark = pose.mark {
            image.draw(mark, bottomCenter: (Double(canvas.columns) - 3.5, 5 - Double(pose.bob)))
        }
        if let mark = pose.thought {
            image.draw(mark, bottomCenter: (Double(canvas.columns) / 2, 2))
        }
        return image
    }
}

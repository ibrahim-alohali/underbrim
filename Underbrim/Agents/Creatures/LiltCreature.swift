//
//  LiltCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Antigravity's creature: the arch from the Antigravity app's icon, warm across the top
//  turning blue down its legs, four cells deep. Its sounds are soft sine scoops and glides.
//

import SwiftUI

struct LiltCreature: AgentCreature {
    var box: CGSize { CGSize(width: 22, height: 20) }
    var overflow: CGFloat { 3 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(LiltArt.doneAct.count)
        case .failed: CreatureClock.seconds(LiltArt.failedFrames)
        case .stopped: CreatureClock.seconds(LiltArt.stopped.count)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        LiltArt.render(LiltArt.pose(for: frame), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        var graph = SynthGraph()
        var voices: [SynthGraph.Node] = []
        /// One sine voice: starts at `from`, glides to `hz` over `glide` seconds, rises over `attack`, then dies away.
        func voice(from: Double, to hz: Double, glide: Double, at start: Double, length: Double, level: Double, attack: Double) {
            let pitch = SynthGraph.Param(from).set(from, at: start).exponential(to: hz, at: start + glide)
            let oscillator = graph.oscillator(.sine, frequency: pitch, start: start, stop: start + length + 0.02)
            let envelope = SynthGraph.Param(0.0001).set(0.0001, at: start)
                .exponential(to: level, at: start + attack).exponential(to: 0.0008, at: start + length)
            voices.append(graph.gain(envelope, oscillator))
        }
        /// A note and its glassy overtone an octave up, which dies first.
        func note(_ hz: Double, from: Double, glide: Double, at start: Double, length: Double,
                  amp: Double, attack: Double, overtone: Double) {
            voice(from: from, to: hz, glide: glide, at: start, length: length, level: amp, attack: attack)
            if overtone > 0 {
                voice(from: from * 2, to: hz * 2, glide: glide, at: start, length: length * 0.6, level: amp * overtone, attack: attack)
            }
        }
        let cutoff: SynthGraph.Param, master: Double, seconds: Double
        switch cue {
        case .attention:
            note(783.99, from: 659.26, glide: 0.06, at: 0, length: 0.21, amp: 0.9, attack: 0.006, overtone: 0.12)
            note(1174.66, from: 987.77, glide: 0.07, at: 0.115, length: 0.24, amp: 1, attack: 0.006, overtone: 0.10)
            (cutoff, master, seconds) = (SynthGraph.Param(3600), 0.123, 0.42)
        case .done:
            note(783.99, from: 721.3, glide: 0.035, at: 0, length: 0.16, amp: 0.8, attack: 0.005, overtone: 0.12)
            note(987.77, from: 908.7, glide: 0.035, at: 0.07, length: 0.16, amp: 0.85, attack: 0.005, overtone: 0.12)
            note(1174.66, from: 1080.7, glide: 0.035, at: 0.14, length: 0.17, amp: 0.9, attack: 0.005, overtone: 0.12)
            note(1567.98, from: 1442.5, glide: 0.035, at: 0.21, length: 0.15, amp: 0.5, attack: 0.005, overtone: 0.06)
            (cutoff, master, seconds) = (SynthGraph.Param(5200), 0.129, 0.42)
        case .failed:
            note(349.23, from: 587.33, glide: 0.30, at: 0, length: 0.34, amp: 1, attack: 0.015, overtone: 0.08)
            // The filter closes while the note sinks.
            (cutoff, master, seconds) = (SynthGraph.Param(2600).set(2600, at: 0).exponential(to: 700, at: 0.32), 0.121, 0.42)
        }
        let mix = graph.gain(1)
        for voice in voices { graph.connect(voice, to: mix) }
        let soft = graph.filter(.lowpass, frequency: cutoff, q: 0.5, mix)
        let output = graph.gain(master, soft)
        return (graph, output, seconds)
    }
}

// MARK: - Poses

private enum LiltArt {
    struct Pose {
        /// Pixels each foot is lifted (left, right); how far the legs splay out.
        var feet = (0, 0), splay = 0
        var yaw = 0.0
        var lift = 0
        var grey = 0.0
        var ring: (radius: Double, alpha: Double)?
        var sparks: Int?
        /// A mark beside its top on the right, pixels it bobs up; and one over its top.
        var mark: CreatureMark?, bob = 0, thought: CreatureMark?
    }

    static let loop = 48, doneFrames = 14, failedFrames = 10
    static let steps = [0, 1, 2, 2, 1, 0]

    /// A step with each foot every second while it turns slowly one way and back.
    static func working(_ f: Int) -> Pose {
        var p = Pose()
        let step = f % 12
        p.feet = step < 6 ? (steps[step], 0) : (0, steps[step - 6])
        let turn = 18 * sin(2 * .pi * Double(f) / Double(loop))
        p.yaw = [-18.0, -9, 0, 9, 18].min { abs($0 - turn) < abs($1 - turn) }!
        return p
    }

    static func attention(_ f: Int) -> Pose {
        var p = Pose()
        let lifts = [0, 2, 3, 3, 2, 0, 0, 1, 2, 2, 1, 0]
        if f < 12 {
            p.lift = lifts[f]
            if p.lift >= 2 { p.feet = (1, 1) }
        }
        p.ring = f < 12 ? (7 + 0.13 * Double(f), 0.8 * (1 - Double(f) / 12)) : f >= 18 ? (7.5, 0.35) : nil
        return p
    }

    static func done(_ f: Int) -> Pose {
        var p = Pose()
        let lifts = [0, 1, 2, 3, 3, 3, 3, 2, 1, 0]
        if f < lifts.count {
            p.lift = lifts[f]
            p.yaw = 45 * Double(min(8, max(0, f - 1)))
            if p.lift >= 2 { p.feet = (1, 1) }
        }
        if f >= 3, f < 12 { p.sparks = f - 3 }
        return p
    }

    static func failed(_ f: Int) -> Pose {
        Pose(splay: f >= 2 ? 1 : 0, lift: f >= 3 ? -1 : 0, grey: min(1, Double(f) / 6))
    }

    static let questionStart: [Pose] = [Pose(mark: .twinkle(0)), Pose(mark: .twinkle(1)), Pose(mark: .question, bob: 1), Pose(mark: .question)]
    static let questionLoop: [Pose] = {
        func ask(yaw: Double = 0, lift: Int = 0, feet: (Int, Int) = (0, 0)) -> Pose {
            Pose(feet: feet, yaw: yaw, lift: lift, mark: .question)
        }
        let look = [ask(yaw: 9)] + [0, 0, 1, 1, 0, 0, 1, 1, 0, 0].map { ask(yaw: 18, lift: $0) } + [ask(yaw: 9)]
        let shuffle = [(1, 0), (2, 0), (1, 0), (0, 0), (0, 1), (0, 2), (0, 1), (0, 0)].map { ask(feet: $0) }
        return Array(repeating: ask(), count: 6) + look + Array(repeating: ask(), count: 4) + shuffle
            + [ask(lift: 1, feet: (1, 1)), ask(lift: 1, feet: (1, 1)), ask()] + Array(repeating: ask(), count: 15)
    }()

    static let permissionStart: [Pose] = [Pose(mark: .twinkle(1)), Pose(mark: .exclamation, bob: 1)]
    static let permissionLoop: [Pose] = (0..<24).map { f in
        var p = attention(f)
        p.mark = .exclamation
        // Lower bounces than its call when it needed you, so the mark stays on the canvas.
        p.lift = min(p.lift, 2)
        if f >= 12, f < 20 { p.feet = [(1, 0), (0, 0), (0, 1), (0, 0)][(f - 12) / 2] }
        return p
    }

    static let doneAct: [Pose] = (0..<doneFrames).map(done)
        + [Pose(feet: (1, 0), mark: .twinkle(1)), Pose(feet: (0, 0), mark: .tick, bob: 1), Pose(feet: (0, 1), mark: .tick), Pose(mark: .tick)]
        + [Pose(lift: 1, mark: .tick), Pose(mark: .tick)]

    static let stopped: [Pose] = [Pose(feet: (2, 0)), Pose(feet: (2, 0)), Pose(feet: (2, 0), yaw: -9), Pose(feet: (2, 0), yaw: 9),
                                  Pose(feet: (1, 0)), Pose()]
        + [1, 1, 2, 2, 3, 3].map { Pose(thought: .dots($0)) }

    static func pose(for frame: CreatureFrame) -> Pose {
        let f = frame.still ? nil : CreatureClock.frame(frame.elapsed)
        return switch frame.state {
        case .idle: Pose()
        case .working: f.map { working($0 % loop) } ?? Pose()
        case .question: CreatureClock.act(questionStart, questionLoop, f)
        case .permission: CreatureClock.act(permissionStart, permissionLoop, f)
        case .done: CreatureClock.once(doneAct, f)
        case .failed: failed(min(f ?? failedFrames, failedFrames))
        case .stopped: CreatureClock.once(stopped, f)
        }
    }

    // MARK: - Model

    /// Its outline from the icon, going round from the bottom of the left foot: up the outside,
    /// over the top, down to the right foot, then up the inside and down again. x and y in
    /// heights, x from the middle, y from the top.
    static let outline: [CGPoint] = {
        let outside: [(Double, Double)] = [
            (0.546, 0.972), (0.528, 0.933), (0.493, 0.894), (0.461, 0.855), (0.436, 0.816), (0.415, 0.777),
            (0.396, 0.739), (0.38, 0.7), (0.366, 0.661), (0.352, 0.622), (0.337, 0.583), (0.327, 0.544),
            (0.316, 0.505), (0.306, 0.466), (0.295, 0.428), (0.284, 0.389), (0.274, 0.35), (0.26, 0.311),
            (0.249, 0.272), (0.235, 0.233), (0.221, 0.194), (0.203, 0.155), (0.182, 0.117), (0.154, 0.078),
            (0.115, 0.039),
        ]
        let inside: [(Double, Double)] = [
            (0.044, 0.544), (0.08, 0.555), (0.125, 0.583), (0.164, 0.622), (0.191, 0.661), (0.214, 0.7),
            (0.239, 0.739), (0.26, 0.777), (0.284, 0.816), (0.313, 0.855), (0.345, 0.894), (0.38, 0.933), (0.433, 0.975),
        ]
        let foot: [(Double, Double)] = [(0.46, 0.99), (0.5, 1.0), (0.535, 0.99)]
        var points: [(Double, Double)] = []
        points += foot.map { (-$0.0, $0.1) }                                  // the left foot, outward
        points += outside.map { (-$0.0, $0.1) }                               // up the left side
        points += [(0, 0)] + outside.reversed()                              // over the top, down the right
        points += foot.reversed()                                            // round the right foot
        points += inside.reversed() + [(0, 0.535)]                           // up the inside
        points += inside.map { (-$0.0, $0.1) }                               // down to the left foot
        return points.map { CGPoint(x: $0.0, y: $0.1) }
    }()
    static let blue = PixelColor(53, 137, 253), violet = PixelColor(176, 104, 214)
    /// Across the top, left to right: yellow-green, orange, red.
    static let warm: [(at: Double, color: PixelColor)] = [(0, PixelColor(160, 200, 78)), (0.5, PixelColor(232, 140, 55)), (1, PixelColor(243, 82, 75))]
    static let sparkColors = [PixelColor(250, 190, 40), PixelColor(70, 180, 100), PixelColor(240, 80, 70), PixelColor(53, 137, 253)]
    static let ringBlue = PixelColor(120, 175, 255)

    static let width = 15, height = 12, depth = 4, middle = 7.5

    /// The pixels in the arch, by row: each its own colour's index (warm across the top, blue from
    /// halfway down), or 0.
    static let cells: [[UInt8]] = {
        let shape = CGMutablePath()
        shape.addLines(between: outline.map { CGPoint(x: middle + $0.x * Double(height), y: $0.y * Double(height)) })
        shape.closeSubpath()
        return (0..<height).map { y in
            (0..<width).map { x in shape.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) ? UInt8(1 + y * width + x) : 0 }
        }
    }()
    static let palette: [PixelColor] = (0..<(height * width)).map { i in
        let (x, y) = (i % width, i / width)
        let u = (Double(x) + 0.5) / Double(width)
        let warmth = u < 0.5 ? warm[0].color.mixed(with: warm[1].color, u * 2) : warm[1].color.mixed(with: warm[2].color, (u - 0.5) * 2)
        // Down to blue through a pinkish purple, not through grey.
        let down = min(1, max(0, ((Double(y) + 0.5) / Double(height) - 0.3) / 0.45))
        return down < 0.5 ? warmth.mixed(with: violet, down * 2) : violet.mixed(with: blue, (down - 0.5) * 2)
    }

    static func model(_ pose: Pose) -> VoxelModel {
        var m = VoxelModel(width: width, height: height, depth: depth)
        for y in 0..<height {
            for x in 0..<width {
                let left = Double(x) + 0.5 < middle
                // The legs below the inside's top: a lifted foot comes up, splayed legs spread.
                var (sx, sy) = (x, y)
                if y >= 7 {
                    sy += left ? pose.feet.0 : pose.feet.1
                    sx += (left ? 1 : -1) * pose.splay
                }
                guard sy < height, sx >= 0, sx < width, cells[sy][sx] != 0 else { continue }
                m.fill(x, y, 0, 1, 1, depth, cells[sy][sx])
            }
        }
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        let view = VoxelView(yaw: pose.yaw, pivot: (middle, Double(height), Double(depth) / 2),
                             at: (Double(canvas.columns) / 2, Double(canvas.floor - pose.lift)))
        let center = view.project(middle, Double(height) / 2, Double(depth) / 2)
        // Round where it stands, not where it hops to, so the ring stays on the canvas.
        if let ring = pose.ring { image.ring(around: (center.x, center.y + Double(pose.lift)), radius: ring.radius, ringBlue, alpha: ring.alpha) }
        let grey = pose.grey
        Voxels.draw(model(pose), palette: palette, view: view, into: &image,
                    tone: grey > 0 ? { $0.mixed(with: $0.greyed.scaled(0.8), grey) } : nil)
        if let spark = pose.sparks {
            let distance = 6 + 1.1 * Double(spark)
            for k in 0..<8 {
                let angle = (-90 + 45 * Double(k) + 22.5) * .pi / 180
                image.set(Int((center.x + distance * cos(angle)).rounded(.down)), Int((center.y + distance * sin(angle)).rounded(.down)),
                          sparkColors[k % 4], alpha: 1 - Double(spark) / 9)
            }
        }
        if let mark = pose.mark {
            let side = view.project(Double(width) - 1, 3, 0)
            image.draw(mark, bottomCenter: (side.x, side.y - Double(pose.bob)))
        }
        if let mark = pose.thought {
            let top = view.project(middle, 0, 0)
            image.draw(mark, bottomCenter: (top.x, top.y - 2))
        }
        return image
    }
}

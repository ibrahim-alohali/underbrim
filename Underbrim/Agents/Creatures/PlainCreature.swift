//
//  PlainCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The neutral creature for agents without their own: a white capsule with a small face
//  on a pad of light in one tint. Its sounds are plain sine chimes.
//

import SwiftUI

struct PlainCreature: AgentCreature {
    /// The one colour: the pad, the mark, the key line. Very light tints darken on the white body.
    var tint: Color = .accentColor

    /// 26 x 20 pt; the capsule is 8 pixels wide and 11 tall.
    var box: CGSize { CGSize(width: 26, height: 20) }
    var overflow: CGFloat { 2 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(PipArt.doneFrames)
        case .failed: CreatureClock.seconds(PipArt.failedFrames)
        case .stopped: CreatureClock.seconds(PipArt.stopped.count)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        PipArt.render(PipArt.pose(for: frame), tint: PipArt.rgb(tint), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        var graph = SynthGraph()
        var voices: [SynthGraph.Node] = []
        func voice(_ hz: Double, at start: Double, length: Double, level: Double, attack: Double,
                   glide: (to: Double, seconds: Double)? = nil) {
            var pitch = SynthGraph.Param(hz).set(hz, at: start)
            if let glide { pitch = pitch.exponential(to: glide.to, at: start + glide.seconds) }
            let oscillator = graph.oscillator(.sine, frequency: pitch, start: start, stop: start + length + 0.02)
            let envelope = SynthGraph.Param(0.0001).set(0.0001, at: start)
                .exponential(to: level, at: start + attack).exponential(to: 0.0008, at: start + length)
            voices.append(graph.gain(envelope, oscillator))
        }
        let lowpass: Double, master: Double, seconds: Double
        switch cue {
        case .attention:
            // A rising fifth; each note carries a faint octave that dies in half the time.
            voice(783.99, at: 0, length: 0.2, level: 0.85, attack: 0.006)
            voice(783.99 * 2, at: 0, length: 0.1, level: 0.85 * 0.12, attack: 0.006)
            voice(1174.66, at: 0.13, length: 0.22, level: 1, attack: 0.006)
            voice(1174.66 * 2, at: 0.13, length: 0.11, level: 0.12, attack: 0.006)
            // A little louder than its notes alone suggest, so it peaks at -18 dBFS like the others.
            (lowpass, master, seconds) = (4500, 0.1186, 0.42)
        case .done:
            voice(587.33, at: 0, length: 0.11, level: 0.75, attack: 0.004)
            voice(739.99, at: 0.08, length: 0.11, level: 0.85, attack: 0.004)
            voice(880, at: 0.16, length: 0.17, level: 1, attack: 0.004)
            (lowpass, master, seconds) = (4500, 0.1264, 0.40)
        case .failed:
            voice(392, at: 0, length: 0.3, level: 1, attack: 0.012, glide: (261.63, 0.24))
            voice(130.81, at: 0, length: 0.07, level: 0.5, attack: 0.004)
            (lowpass, master, seconds) = (1500, 0.1067, 0.38)
        }
        let mix = graph.gain(1)
        for voice in voices { graph.connect(voice, to: mix) }
        let soft = graph.filter(.lowpass, hz: lowpass, q: 0.5, mix)
        let output = graph.gain(master, soft)
        return (graph, output, seconds)
    }
}

// MARK: - Poses

private enum PipArt {
    enum Eyes { case open, shut, wide, low, aside, up }
    enum Mark { case dot, dots(Int), bang, tick, frown, slant, flat }

    struct Pose {
        var eyes = Eyes.open
        var mark = Mark.dot
        var yaw = 0.0
        var lift = 0
        /// How bright the pad is (0...1); how far it has dimmed.
        var pad = 0.45, dim = 0.0
        /// A mark by its head, pixels it bobs up; and one over it.
        var side: CreatureMark?, bob = 0, thought: CreatureMark?
    }

    static let doneFrames = 12, failedFrames = 8
    static let rock = [0.0, 8, 16, 16, 8, 0, 0, -8, -16, -16, -8, 0]
    static let step = [0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0]

    /// Two waddles, a dot lighting in turn every third of a second, and a blink in the second.
    static func working(_ f: Int) -> Pose {
        var p = Pose(mark: .dots(f / 4 % 3))
        p.yaw = rock[f % 12]
        p.lift = step[f % 12]
        if f == 20 || f == 21 { p.eyes = .shut }
        return p
    }

    static func attention(_ f: Int) -> Pose {
        var p = Pose(eyes: .wide, mark: .bang, pad: 0.8)
        let lifts = [0, 2, 3, 3, 2, 0, 0, 1, 2, 2, 1, 0]
        if f < 12 { p.lift = lifts[f] }
        if f >= 14, f < 18 { p.yaw = f < 16 ? -12 : 12 }
        return p
    }

    static func done(_ f: Int) -> Pose {
        var p = Pose(mark: f >= 2 ? .tick : .dot, pad: 0.6)
        let lifts = [0, 1, 2, 3, 3, 2, 1, 0]
        if f < lifts.count { p.lift = lifts[f] }
        if f >= 1, f < 6 { p.pad = 0.9 }
        return p
    }

    static func failed(_ f: Int) -> Pose {
        Pose(eyes: f >= 1 ? .low : .open, mark: f >= 1 ? .frown : .dot, yaw: f >= 2 ? 20 : 0,
             pad: 0.12, dim: min(1, Double(f) / 5))
    }

    static let questionStart: [Pose] = [Pose(mark: .slant, side: .twinkle(1)), Pose(mark: .slant, side: .question, bob: 1), Pose(mark: .slant, side: .question)]
    static let questionLoop: [Pose] = {
        func ask(_ eyes: Eyes = .open, yaw: Double = 0, lift: Int = 0) -> Pose {
            Pose(eyes: eyes, mark: .slant, yaw: yaw, lift: lift, side: .question)
        }
        let up = [0, 0, 1, 1, 0, 0, 1, 1, 0, 0].map { ask(.up, yaw: 12, lift: $0) }
        return Array(repeating: ask(), count: 6) + [ask(.aside), ask(.aside, yaw: 6)] + up + [ask(.aside, yaw: 6)]
            + Array(repeating: ask(), count: 7) + [ask(.shut), ask(.shut)] + [1, 2, 1, 0].map { ask(lift: $0) }
            + Array(repeating: ask(), count: 16)
    }()

    static let stopped: [Pose] = [Pose(eyes: .wide, mark: .dots(1), yaw: 16, lift: 1), Pose(eyes: .wide, mark: .dots(1), yaw: 16, lift: 1),
                                  Pose(eyes: .wide, mark: .dots(1), yaw: 8), Pose(mark: .flat), Pose(eyes: .shut, mark: .flat), Pose(mark: .flat)]
        + [1, 1, 2, 2, 3, 3].map { Pose(mark: .flat, thought: .dots($0)) }

    static func pose(for frame: CreatureFrame) -> Pose {
        let f = frame.still ? nil : CreatureClock.frame(frame.elapsed)
        return switch frame.state {
        case .idle: Pose()
        case .working: f.map { working($0 % 24) } ?? Pose(mark: .dots(1))
        case .question: CreatureClock.act(questionStart, questionLoop, f)
        case .permission: f.map { attention($0 % 24) } ?? attention(23)
        case .done: done(min(f ?? doneFrames, doneFrames))
        case .failed: failed(min(f ?? failedFrames, failedFrames))
        case .stopped: CreatureClock.once(stopped, f)
        }
    }

    // MARK: - Model

    static let ink = PixelColor(0x15, 0x16, 0x1B)
    /// White at the top shading to a cool grey at the bottom, a gloss, the ink, and the mark (set per tint).
    static let body = [PixelColor(255, 255, 255), PixelColor(0xE3, 0xE5, 0xE9), PixelColor(0xBD, 0xC1, 0xC8)]
    static let width = 8, height = 11, depth = 6

    static func inside(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let dx = Double(x) + 0.5 - 4, dy = Double(y) + 0.5 - min(7, max(4, Double(y) + 0.5))
        return dx * dx + dy * dy <= 16.2
    }

    /// The capsule: flat on the front, its rim set back so it rounds off as it turns; its face on the front.
    static func model(_ pose: Pose) -> VoxelModel {
        var m = VoxelModel(width: width, height: height, depth: depth)
        m.extrude({ x, y in
            guard inside(x, y) else { return 0 }
            return inside(x - 1, y) && inside(x + 1, y) && inside(x, y - 1) && inside(x, y + 1) ? depth : depth - 2
        }, color: { _, y in UInt8(1 + min(2, y * 3 / height)) })
        m.paintFront(1, 3, 4)
        m.paintFront(1, 4, 4)
        let eyes: [(Int, Int)] = switch pose.eyes {
        case .open: [(2, 4), (2, 5), (5, 4), (5, 5)]
        case .shut: [(2, 5), (5, 5)]
        case .wide: [(2, 3), (2, 4), (2, 5), (5, 3), (5, 4), (5, 5)]
        case .low: [(2, 5), (5, 5), (2, 6), (5, 6)]
        case .aside: [(3, 4), (3, 5), (6, 4), (6, 5)]
        case .up: [(3, 3), (3, 4), (6, 3), (6, 4)]
        }
        for (x, y) in eyes { m.paintFront(x, y, 5) }
        let mark: [(Int, Int)] = switch pose.mark {
        case .dot: [(3, 8), (4, 8)]
        case .dots(let lit): [(1 + 2 * lit, 8), (2 + 2 * lit, 8)]
        case .bang: [(3, 6), (4, 6), (3, 7), (4, 7), (3, 9), (4, 9)]
        case .tick: [(2, 7), (3, 8), (4, 7), (5, 6)]
        case .frown: [(2, 9), (3, 8), (4, 8), (5, 9)]
        case .slant: [(2, 8), (3, 8), (4, 7), (5, 7)]
        case .flat: [(2, 8), (3, 8), (4, 8), (5, 8)]
        }
        if case .dots(let lit) = pose.mark {
            for k in 0..<3 where k != lit { m.paintFront(1 + 2 * k, 8, 7); m.paintFront(2 + 2 * k, 8, 7) }
        }
        for (x, y) in mark { m.paintFront(x, y, 6) }
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, tint: [Double], on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        let color = PixelColor(tint[0], tint[1], tint[2])
        let markColor = { let c = markTint(tint); return PixelColor(c[0], c[1], c[2]) }()
        let grey = PixelColor(128, 132, 140)
        let palette = body + [PixelColor(255, 255, 255), ink, markColor, markColor.mixed(with: body[1], 0.7)]
        let view = VoxelView(yaw: pose.yaw, pivot: (4, Double(height), Double(depth) / 2),
                             at: (Double(canvas.middle), Double(canvas.floor - pose.lift)))
        let pad = color.mixed(with: grey, pose.dim * 0.8)
        let reach = pose.lift > 1 ? 3 : 5
        for dx in -reach..<reach {
            let edge = 1 - abs(Double(dx) + 0.5) / Double(reach)
            image.set(canvas.middle + dx, canvas.floor, pad, alpha: pose.pad * (0.25 + 0.75 * edge))
        }
        let dim = pose.dim
        Voxels.draw(model(pose), palette: palette, view: view, into: &image,
                    tone: dim > 0 ? { $0.mixed(with: $0.greyed.scaled(0.6), dim) } : nil)
        if let mark = pose.side {
            let side = view.project(Double(width) + 2.5, 2, 0)
            image.draw(mark, bottomCenter: (side.x, side.y - Double(pose.bob)))
        }
        if let mark = pose.thought {
            let top = view.project(4, 0, 0)
            image.draw(mark, bottomCenter: (top.x, top.y - 2))
        }
        return image
    }

    /// Red, green and blue out of 255, as the app draws the colour in a dark appearance.
    static func rgb(_ color: Color) -> [Double] {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        let c = color.resolve(in: environment)
        return [c.red, c.green, c.blue].map { (min(1, max(0, Double($0))) * 255).rounded() }
    }

    /// A light tint would vanish on the white body, so the mark takes it darker (to a luma of one half).
    static func markTint(_ c: [Double]) -> [Double] {
        let luma = (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255
        return luma > 0.5 ? c.map { ($0 * 0.5 / luma).rounded() } : c
    }
}

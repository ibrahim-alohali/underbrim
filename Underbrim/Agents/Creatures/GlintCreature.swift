//
//  GlintCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Qwen Code's creature: its mark, three rounded blue blades like a pinwheel, three
//  cells deep. Its sounds are bell chimes.
//

import SwiftUI

struct GlintCreature: AgentCreature {
    var box: CGSize { CGSize(width: 20, height: 20) }
    var overflow: CGFloat { 3 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(GlintMark.doneAct.count)
        case .stopped: CreatureClock.seconds(GlintMark.stopped.count)
        case .failed: CreatureClock.seconds(GlintMark.failedFrames)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        GlintMark.render(GlintMark.pose(for: frame), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        GlintArt.chime(for: cue).render()
    }
}

// MARK: - Poses

private enum GlintMark {
    struct Pose {
        /// Degrees the blades have turned; how far apart they are, in pixels; how far each has fallen.
        var spin = 0.0, apart = 0.0, droop = 0.0
        var yaw = 0.0
        var lift = 0
        var grey = 0.0
        var sparkles: Int?
        /// A mark in its middle, shown as the blades open out round it.
        var glyph: CreatureMark?
    }

    static let loop = 36, doneFrames = 14, failedFrames = 10
    /// A third of a turn, eased to a stop.
    static let spinSteps = [0.0, 40, 80, 105, 117, 120]

    /// Three spins, each a third of a turn with a pulse as it stops, while it tilts one way and back.
    static func working(_ f: Int) -> Pose {
        var p = Pose()
        let step = f % 12
        p.spin = 120 * Double(f / 12) + (step < spinSteps.count ? spinSteps[step] : 120)
        if step == 6 || step == 7 { p.apart = 1 }
        let tilt = 18 * sin(2 * .pi * Double(f) / Double(loop))
        p.yaw = [-18.0, -9, 0, 9, 18].min { abs($0 - tilt) < abs($1 - tilt) }!
        return p
    }

    static func done(_ f: Int) -> Pose {
        var p = Pose()
        let lifts = [0, 1, 2, 2, 2, 2, 2, 2, 1, 0]
        if f < lifts.count {
            p.lift = lifts[f]
            p.spin = 360 * Double(min(f, 9)) / 9
        }
        if f == 10 { p.apart = 0.5 }
        if f >= 6, f < 13 { p.sparkles = f - 6 }
        return p
    }

    static func failed(_ f: Int) -> Pose {
        Pose(apart: f >= 1 ? 1 : 0, droop: f >= 3 ? 0.5 : 0, lift: f >= 3 ? -1 : 0, grey: min(1, Double(f) / 6))
    }

    /// Opened out round a mark: two pixels apart, enough to show it.
    static func open(_ glyph: CreatureMark?, apart: Double = 2, spin: Double = 0, yaw: Double = 0) -> Pose {
        Pose(spin: spin, apart: apart, yaw: yaw, glyph: glyph)
    }
    static func opening(_ glyph: CreatureMark) -> [Pose] {
        [open(nil, apart: 0.5, spin: 10), open(.twinkle(1), apart: 1, spin: 20), open(glyph, apart: 1.5, spin: 10), open(glyph, apart: 2.5), open(glyph)]
    }

    static let questionStart = opening(.question)
    static let questionLoop: [Pose] = {
        let rock = [0.0, -8, -14, -8, 0, 8, 14, 8, 0].map { open(.question, spin: $0) }
        func look(_ side: Double) -> [Pose] {
            [open(.question, yaw: 9 * side)] + Array(repeating: open(.question, yaw: 18 * side), count: 7) + [open(.question, yaw: 9 * side)]
        }
        return [open(.question), open(.question)] + rock + [open(.question)] + look(-1) + [open(.question)] + look(1)
            + rock + Array(repeating: open(.question), count: 8)
    }()

    static let permissionStart = opening(.exclamation)
    static let permissionLoop: [Pose] = {
        let rattle = [(16.0, 2.5), (-16, 2), (16, 2.5), (-16, 2), (0, 2.5), (0, 2)].map { open(.exclamation, apart: $0.1, spin: $0.0) }
        return rattle + rattle + Array(repeating: open(.exclamation), count: 12)
    }()

    static let doneAct: [Pose] = (0..<doneFrames).map(done) + opening(.tick) + [open(.tick, apart: 2.5), open(.tick)]

    static let stopped: [Pose] = [Pose(spin: 40), Pose(spin: 52), Pose(spin: 46), Pose(spin: 40), Pose(spin: 40)]
        + [open(nil, apart: 0.5, spin: 40), open(nil, apart: 1, spin: 20), open(.stop, apart: 1.5, spin: 10), open(.stop, apart: 2.5), open(.stop)]
        + Array(repeating: open(.stop), count: 2)

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

    enum Segment {
        case move(Double, Double), line(Double, Double)
        case curve(Double, Double, Double, Double, Double, Double)
    }

    /// One blade (the top one), from the mark's own outline, in radii from its middle; the other
    /// two are it turned a third and two thirds of the way round.
    static let outline: [Segment] = [
        .move(0.6196, -0.7366), .line(0.1455, -0.7366),
        .curve(0.1455, -0.7567, 0.1402, -0.7769, 0.1299, -0.795), .line(0.0664, -0.9049),
        .curve(0.0455, -0.941, 0.007, -0.9633, -0.0348, -0.9633), .line(-0.1617, -0.9633),
        .curve(-0.2034, -0.9633, -0.2419, -0.941, -0.2628, -0.9049), .line(-0.4572, -0.5683),
        .curve(-0.4781, -0.5323, -0.4781, -0.4878, -0.4572, -0.4516), .line(-0.3937, -0.3416),
        .curve(-0.3728, -0.3055, -0.3343, -0.2832, -0.2925, -0.2832), .line(0.6195, -0.2832),
        .curve(0.6612, -0.2832, 0.6997, -0.3055, 0.7206, -0.3416), .line(0.7841, -0.4516),
        .curve(0.805, -0.4876, 0.805, -0.5321, 0.7841, -0.5683), .line(0.7206, -0.6783),
        .curve(0.6997, -0.7144, 0.6612, -0.7367, 0.6195, -0.7367),
    ]
    /// Where the top blade sits, roughly, so it can move out from the middle along it, in radii.
    static let bladeMiddle = (0.16, -0.62)
    static let palette = [PixelColor(8, 45, 255)]
    static let sparkle = PixelColor(200, 215, 255)

    /// Room for the blades to spread, three deep; the mark's radius in pixels.
    static let size = 19, depth = 3, radius = 6.4

    static func blade() -> CGPath {
        let path = CGMutablePath()
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * radius, y: y * radius) }
        for segment in outline {
            switch segment {
            case let .move(x, y): path.move(to: point(x, y))
            case let .line(x, y): path.addLine(to: point(x, y))
            case let .curve(x1, y1, x2, y2, x, y): path.addCurve(to: point(x, y), control1: point(x1, y1), control2: point(x2, y2))
            }
        }
        path.closeSubpath()
        return path
    }

    /// The three blades turned and spread as the pose has them, sampled at each pixel's middle.
    static func model(_ pose: Pose) -> VoxelModel {
        var m = VoxelModel(width: size, height: size, depth: depth)
        let middle = Double(size) / 2, blade = blade(), bounds = blade.boundingBoxOfPath
        // The three blades look the same a third of a turn on.
        let spin = pose.spin.truncatingRemainder(dividingBy: 120)
        for k in 0..<3 {
            let turn = (spin + 120 * Double(k)) * .pi / 180
            let out = (bladeMiddle.0 * cos(turn) - bladeMiddle.1 * sin(turn), bladeMiddle.0 * sin(turn) + bladeMiddle.1 * cos(turn))
            let length = (out.0 * out.0 + out.1 * out.1).squareRoot()
            let shift = (out.0 / length * pose.apart, out.1 / length * pose.apart + pose.droop * Double(k + 1))
            for y in 0..<size {
                for x in 0..<size {
                    // Back from the picture to the top blade: undo the spread, then the turn.
                    let px = Double(x) + 0.5 - middle - shift.0, py = Double(y) + 0.5 - middle - shift.1
                    let point = CGPoint(x: px * cos(turn) + py * sin(turn), y: -px * sin(turn) + py * cos(turn))
                    // Its box first: most pixels are nowhere near the blade, and the curve test is slow.
                    if bounds.contains(point), blade.contains(point) { m.fill(x, y, 0, 1, 1, depth, 1) }
                }
            }
        }
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        let half = Double(size) / 2
        // Its middle seven pixels above the floor puts its lowest blade on it.
        let view = VoxelView(yaw: pose.yaw, pivot: (half, half, Double(depth) / 2),
                             at: (Double(canvas.columns) / 2, Double(canvas.floor - pose.lift - 7)))
        let grey = pose.grey
        Voxels.draw(model(pose), palette: palette, view: view, into: &image,
                    // Its deep blue greys dark, so the grey is lifted to stay visible on black.
                    tone: grey > 0 ? { $0.mixed(with: $0.greyed.scaled(1.7), grey) } : nil)
        if let glyph = pose.glyph {
            let center = view.project(half, half, 0)
            image.draw(glyph, bottomCenter: (center.x, center.y + Double(glyph.height) / 2))
        }
        if let sparkle = pose.sparkles {
            let center = view.project(half, half, Double(depth) / 2), distance = 8 + 0.6 * Double(sparkle)
            for k in 0..<6 {
                let angle = (-60 + 60 * Double(k)) * .pi / 180
                let (x, y) = (Int((center.x + distance * cos(angle)).rounded(.down)), Int((center.y + distance * sin(angle)).rounded(.down)))
                let alpha = 1 - Double(sparkle) / 7
                image.set(x, y, sparkle == 0 ? palette[0] : self.sparkle, alpha: alpha)
                if sparkle < 4 { for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { image.set(x + dx, y + dy, self.sparkle, alpha: alpha * 0.5) } }
            }
        }
        return image
    }
}

// MARK: - Sounds

private enum GlintArt {
    /// A bell's partials: pitch ratio, loudness, and how much of the note's length it rings.
    typealias Partial = (ratio: Double, gain: Double, ring: Double)
    static let bell: [Partial] = [(1, 1, 1), (2, 0.32, 0.55), (2.76, 0.12, 0.3)]
    /// Darker, with no glassy overtone.
    static let soft: [Partial] = [(1, 1, 1), (2, 0.18, 0.5)]

    struct Note {
        let start: Double, length: Double, hz: Double, amplitude: Double
    }

    /// One sound: sine partials through a shared low-pass and a master gain, maybe with an echo.
    struct Chime {
        let partials: [Partial]
        let notes: [Note]
        let lowpass: Double, master: Double
        /// Each partial slides to this share of its pitch over the note's length (1: no slide).
        var slide = 1.0
        var echo: (delay: Double, gain: Double, lowpass: Double)?
        let seconds: Double

        func render() -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
            var graph = SynthGraph()
            var voices: [SynthGraph.Node] = []
            for note in notes {
                for partial in partials {
                    let hz = note.hz * partial.ratio
                    let end = note.start + note.length * partial.ring
                    var pitch = SynthGraph.Param(hz).set(hz, at: note.start)
                    if slide != 1 { pitch = pitch.exponential(to: hz * slide, at: note.start + note.length) }
                    let level = SynthGraph.Param(0.0001)
                        .set(0.0001, at: note.start)
                        .linear(to: partial.gain * note.amplitude, at: note.start + 0.004)
                        .exponential(to: 0.0001, at: end)
                    let oscillator = graph.oscillator(.sine, frequency: pitch, start: note.start, stop: end + 0.02)
                    voices.append(graph.gain(level, oscillator))
                }
            }
            let low = graph.filter(.lowpass, hz: lowpass, q: 0.5)
            for voice in voices { graph.connect(voice, to: low) }
            var master = graph.gain(self.master, low)
            if let echo {
                let delayed = graph.delay(echo.delay, low)
                let quiet = graph.gain(echo.gain, delayed)
                let soft = graph.filter(.lowpass, hz: echo.lowpass, q: 0.5, quiet)
                master = graph.gain(self.master, low, soft)
            }
            return (graph, master, seconds)
        }
    }

    static func chime(for cue: CreatureCue) -> Chime {
        switch cue {
        // Two bells rising a fifth, "ting, ting", with a soft echo.
        case .attention:
            Chime(partials: bell,
                  notes: [Note(start: 0, length: 0.26, hz: 783.99, amplitude: 1), Note(start: 0.11, length: 0.24, hz: 1174.66, amplitude: 0.9)],
                  lowpass: 6500, master: 0.1023, echo: (delay: 0.09, gain: 0.22, lowpass: 2800), seconds: 0.45)
        // A quick run up to a ringing D, with a faint high sparkle.
        case .done:
            Chime(partials: bell,
                  notes: [Note(start: 0, length: 0.16, hz: 659.26, amplitude: 0.8), Note(start: 0.06, length: 0.16, hz: 783.99, amplitude: 0.85),
                          Note(start: 0.12, length: 0.16, hz: 880, amplitude: 0.9), Note(start: 0.18, length: 0.3, hz: 1174.66, amplitude: 1),
                          Note(start: 0.195, length: 0.12, hz: 2349.32, amplitude: 0.2)],
                  lowpass: 7000, master: 0.095, seconds: 0.5)
        // A falling fifth in a darker, softer bell, each partial sinking a little.
        case .failed:
            Chime(partials: soft,
                  notes: [Note(start: 0, length: 0.24, hz: 440, amplitude: 1), Note(start: 0.13, length: 0.28, hz: 329.63, amplitude: 0.9)],
                  lowpass: 2400, master: 0.112, slide: 0.98, seconds: 0.45)
        }
    }
}

//
//  TerraCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Claude Code's creature: the clay-coloured critter from its welcome screen, twelve
//  pixels by eight, four deep. At work it wears a yellow hard hat and hammers a block;
//  the hat is for work only.
//

import SwiftUI

struct TerraCreature: AgentCreature {
    /// 17 pixels across; at work the hammer and its block take the right side.
    var box: CGSize { CGSize(width: 25.5, height: 20) }
    var overflow: CGFloat { 3 }

    func motionLength(_ state: AgentCreatureState) -> TimeInterval? {
        switch state {
        case .idle: 0
        case .working: nil
        case .question, .permission: CreatureClock.askSeconds
        case .done: CreatureClock.seconds(TerraArt.done.count)
        case .failed: CreatureClock.seconds(TerraArt.failed.count)
        case .stopped: CreatureClock.seconds(TerraArt.stopped.count)
        }
    }

    func render(_ frame: CreatureFrame) -> CreatureImage {
        TerraArt.render(TerraArt.pose(for: frame), on: canvas)
    }

    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
        TerraArt.voice(for: cue).render()
    }
}

// MARK: - Poses

private enum TerraArt {
    enum Eyes { case open, closed, wink, glance, wide, happy, dizzy }
    enum Arms { case down, up, leftUp, rightUp }
    enum Legs { case both, leftUp, rightUp }
    enum Hammer { case up, raised, level, down, broken }
    enum Hat: Equatable { case on, lifted, askew }

    struct Pose: Equatable {
        var eyes = Eyes.open, arms = Arms.down, legs = Legs.both
        var hat: Hat?
        var hammer: Hammer?
        /// Degrees it has turned to your right (its left side shows); turned left when negative.
        var yaw = 0.0
        /// Pixels it is up in the air; rows it has crouched by (its legs fold under it).
        var lift = 0, crouch = 0
        /// The spark burst off the block, and the dust by its feet: which frame of each.
        var sparks: Int?, dust: Int?
        var fade = 0.0
        /// A mark above its raised right hand, or its raised left one, and pixels it bobs up.
        var held: CreatureMark?, overHand: CreatureMark?, bob = 0
        /// The hammer's head flying off (which frame of its flight; 6 has landed), a bead of sweat,
        /// dizzy stars going round (where they are), twinkles of joy (which frame), and a mark over
        /// its head.
        var flying: Int?, sweat = false, dizzy: Int?, twinkle: Int?, thought: CreatureMark?
        /// Its hat, flung away: which frame of its flight (6 has landed, 7 bounced, 8 settled).
        var tossed: Int?
    }

    static let rest = Pose()
    static func work(_ hammer: Hammer, yaw: Double = 22, eyes: Eyes = .open, legs: Legs = .both,
                     crouch: Int = 0, sparks: Int? = nil) -> Pose {
        Pose(eyes: eyes, arms: hammer == .up || hammer == .raised ? .rightUp : .down, legs: legs, hat: .on, hammer: hammer,
             yaw: yaw, crouch: crouch, sparks: sparks)
    }

    static let strike: [Pose] = [
        work(.down), work(.level), work(.raised), work(.up), work(.up, yaw: 18), work(.up, yaw: 14),
        work(.raised, yaw: 20), work(.down, yaw: 26, crouch: 1, sparks: 0), work(.down, yaw: 24, sparks: 1),
        work(.down, sparks: 2), work(.down), work(.down),
    ]
    /// Three strikes, then a look at you; the last frame is the first's pose, so the loop has no seam.
    static let working: [Pose] = strike + strike + strike + [
        work(.down, yaw: 12), work(.down, yaw: 0), work(.down, yaw: 0, legs: .leftUp), work(.down, yaw: 0),
        work(.down, yaw: 0, eyes: .closed), work(.down, yaw: 0, eyes: .closed), work(.down, yaw: 0),
        work(.down, yaw: 0, legs: .rightUp), work(.down, yaw: 0), work(.down, yaw: 12), work(.down), work(.down),
    ]

    static let questionStart: [Pose] = [
        Pose(arms: .rightUp), Pose(arms: .rightUp, held: .twinkle(1)), Pose(arms: .rightUp, held: .question, bob: 1),
        Pose(arms: .rightUp, held: .question),
    ]
    static let questionLoop: [Pose] = {
        func ask(_ eyes: Eyes = .open, yaw: Double = 0, lift: Int = 0, bob: Int = 0) -> Pose {
            Pose(eyes: eyes, arms: .rightUp, yaw: yaw, lift: lift, held: .question, bob: bob)
        }
        let look = [ask(.glance, yaw: 6), ask(.glance, yaw: 10)] + [0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0].map { ask(.glance, yaw: 14, bob: $0) }
            + [ask(.closed, yaw: 14), ask(.glance, yaw: 14), ask(.glance, yaw: 14), ask(.glance, yaw: 14)]
        let back = [ask(yaw: 10), ask(yaw: 6), ask(), ask()]
        let show = [0, 1, 1, 1, 0, 0].map { ask(lift: $0) } + [ask(bob: 1), ask(bob: 1), ask(), ask()]
        let wait = Array(repeating: ask(), count: 2) + [ask(.closed)] + Array(repeating: ask(), count: 13)
        return look + back + show + wait
    }()

    static let permissionStart: [Pose] = [
        rest, Pose(arms: .leftUp, overHand: .twinkle(1)), Pose(arms: .leftUp, overHand: .exclamation, bob: 1),
    ]
    static let permissionLoop: [Pose] = {
        func ask(_ legs: Legs = .both, lift: Int = 0, bob: Int = 0, eyes: Eyes = .open) -> Pose {
            Pose(eyes: eyes, arms: .leftUp, legs: legs, lift: lift, overHand: .exclamation, bob: bob)
        }
        return [ask(), ask(), ask(.rightUp, bob: 1), ask(.rightUp), ask(), ask(), ask(.rightUp, bob: 1), ask(.rightUp), ask(), ask(),
                ask(lift: 1, bob: 1), ask(lift: 2), ask(lift: 1), ask(),
                ask(.rightUp, bob: 1), ask(.rightUp), ask(), ask(), ask(eyes: .closed), ask(), ask(), ask(), ask(), ask()]
    }()

    static let done: [Pose] = {
        func joy(arms: Arms = .down, lift: Int = 0, crouch: Int = 0, dust: Int? = nil, twinkle: Int? = nil, tossed: Int = 8) -> Pose {
            Pose(eyes: .happy, arms: arms, lift: lift, crouch: crouch, dust: dust, twinkle: twinkle, tossed: tossed)
        }
        return [Pose(hat: .on), Pose(arms: .rightUp, hat: .on), Pose(arms: .rightUp, hat: .lifted)]
            + [Pose(arms: .rightUp, tossed: 0), Pose(arms: .rightUp, tossed: 1)] + (2...5).map { joy(tossed: $0) }
            + [joy(crouch: 1, dust: 0, tossed: 6), joy(crouch: 1, tossed: 7)]
            + [1, 2, 3, 3, 2, 1].enumerated().map { k, lift in joy(arms: .up, lift: lift, twinkle: k) }
            + [joy(crouch: 1, dust: 0), joy(dust: 1), joy()]
            + [Arms.up, .up, .down, .down, .up, .up, .down, .down].map { joy(arms: $0) } + [joy()]
    }()

    static let failed: [Pose] = {
        func broke(_ eyes: Eyes, yaw: Double = 0, hat: Hat = .on, crouch: Int = 0, sweat: Bool = false,
                   dizzy: Int? = nil, fade: Double = 0, flying: Int = 6) -> Pose {
            Pose(eyes: eyes, hat: hat, hammer: .broken, yaw: yaw, crouch: crouch, fade: fade, flying: flying, sweat: sweat, dizzy: dizzy)
        }
        return [work(.raised), work(.up), work(.up, yaw: 18), work(.raised, yaw: 20), work(.down, yaw: 26, crouch: 1, sparks: 0)]
            + (0..<6).map { broke(.wide, yaw: 24, flying: $0) }
            + [broke(.glance, yaw: 22), broke(.glance, yaw: 22), broke(.glance, yaw: 22), broke(.wide, yaw: 12), broke(.wide), broke(.wide)]
            + [broke(.wide, hat: .askew), broke(.wide, hat: .askew, sweat: true), broke(.closed, hat: .askew, sweat: true),
               broke(.wide, hat: .askew, sweat: true)]
            + (0..<8).map { broke(.dizzy, hat: .askew, crouch: 1, sweat: true, dizzy: $0, fade: min(0.3, 0.05 * Double($0 + 1))) }
    }()

    static let stopped: [Pose] = [
        work(.up, eyes: .wide), work(.up, eyes: .wide), work(.up, eyes: .wide), work(.raised, eyes: .wide), work(.level), work(.down),
        work(.down, yaw: 12), work(.down, yaw: 0), work(.down, yaw: 0, eyes: .closed), work(.down, yaw: 0),
    ] + [1, 1, 2, 2, 3, 3].map { dots in
        var pose = work(.down, yaw: 0)
        pose.thought = .dots(dots)
        return pose
    }

    static func pose(for frame: CreatureFrame) -> Pose {
        let f = frame.still ? nil : CreatureClock.frame(frame.elapsed)
        return switch frame.state {
        case .idle: rest
        case .working: f.map { working[$0 % working.count] } ?? work(.down)
        case .question: CreatureClock.act(questionStart, questionLoop, f)
        case .permission: CreatureClock.act(permissionStart, permissionLoop, f)
        case .done: CreatureClock.once(done, f)
        case .failed: CreatureClock.once(failed, f)
        case .stopped: CreatureClock.once(stopped, f)
        }
    }

    // MARK: - Model

    enum Ink: UInt8 { case body = 1, eye, lid, hat, ridge, handle, steel, wood, grain }
    static let palette: [PixelColor] = [
        PixelColor(215, 119, 87), PixelColor(0, 0, 0), PixelColor(120, 62, 44), PixelColor(247, 194, 44),
        PixelColor(255, 226, 122), PixelColor(150, 98, 56), PixelColor(186, 192, 202), PixelColor(184, 132, 78),
        PixelColor(150, 104, 60),
    ]
    static let spark = PixelColor(255, 236, 150), dustGrey = PixelColor(150, 150, 150)

    /// The model: the critter's twelve columns, then the hammer and block; the hat's rows above its
    /// head; four cells deep, with the hat's brim one more all round.
    static let width = 18, height = 12, depth = 6
    static let head = 4

    static func model(_ pose: Pose) -> VoxelModel {
        var m = VoxelModel(width: width, height: height, depth: depth)
        func put(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ink: Ink, z: Int = 1, d: Int = 4) {
            m.fill(x, y + pose.crouch, z, w, h, d, ink.rawValue)
        }
        let top = head
        // Head, shoulders and body; the arms are stubs two deep, on the shoulder rows or raised by the head.
        put(2, top, 8, 2, .body)
        put(2, top + 2, 8, 4, .body)
        let leftUp = pose.arms == .up || pose.arms == .leftUp, rightUp = pose.arms == .up || pose.arms == .rightUp
        put(0, top + (leftUp ? 0 : 2), 2, 2, .body, z: 2, d: 2)
        put(10, top + (rightUp ? 0 : 2), 2, 2, .body, z: 2, d: 2)
        func eye(_ x: Int, _ y: Int, _ ink: Ink = .eye) { put(x, y, 1, 1, ink, d: 1) }
        switch pose.eyes {
        case .open: eye(3, top + 1); eye(8, top + 1)
        case .closed: eye(3, top + 1, .lid); eye(8, top + 1, .lid)
        case .wink: eye(3, top + 1); eye(8, top + 1, .lid)
        case .glance: eye(4, top + 1); eye(9, top + 1)
        case .wide: for x in [3, 8] { eye(x, top + 1); eye(x, top + 2) }
        case .happy: for x in [3, 8] { eye(x - 1, top + 2); eye(x, top + 1); eye(x + 1, top + 2) }
        case .dizzy: for x in [3, 8] { eye(x - 1, top + 1); eye(x + 1, top + 1); eye(x, top + 2); eye(x - 1, top + 3); eye(x + 1, top + 3) }
        }
        // Four legs; a lifted pair keeps only its top row. Crouched, they fold out of sight.
        for (x, side) in [(2, Legs.leftUp), (4, .leftUp), (7, .rightUp), (9, .rightUp)] {
            put(x, top + 6, 1, pose.legs == side ? 1 : 2, .body, z: 2, d: 2)
        }
        switch pose.hat {
        case .on, .lifted:
            let brim = top - (pose.hat == .lifted ? 2 : 1)
            put(1, brim, 10, 1, .hat, z: 0, d: 6)
            put(2, brim - 1, 8, 1, .hat)
            put(3, brim - 2, 6, 1, .hat)
            put(5, brim - 2, 2, 2, .ridge, d: 1)
        case .askew:
            put(2, top - 1, 10, 1, .hat, z: 0, d: 6)
            put(4, top - 2, 8, 1, .hat)
            put(6, top - 3, 6, 1, .hat)
            put(8, top - 3, 2, 2, .ridge, d: 1)
        case nil: break
        }
        guard let hammer = pose.hammer else { return m }
        m.fill(14, 10, 1, 3, 2, 4, Ink.wood.rawValue)
        m.fill(14, 11, 1, 3, 1, 1, Ink.grain.rawValue)
        let (handle, steel): ([(Int, Int)], [(Int, Int)]) = switch hammer {
        case .up: ([(12, top + 1), (12, top), (12, top - 1)], [(11, top - 3), (12, top - 3), (13, top - 3), (11, top - 2), (12, top - 2), (13, top - 2)])
        case .raised: ([(12, top), (13, top - 1)], [(14, top - 3), (15, top - 3), (14, top - 2), (15, top - 2)])
        case .level: ([(12, top + 2), (13, top + 2), (14, top + 2)], [(15, top + 1), (16, top + 1), (15, top + 2), (16, top + 2), (15, top + 3), (16, top + 3)])
        case .down: ([(12, top + 3), (13, top + 4)], [(14, top + 4), (15, top + 4), (16, top + 4), (14, top + 5), (15, top + 5), (16, top + 5)])
        case .broken: ([(12, top + 3), (13, top + 4)], [])
        }
        for (x, y) in handle { put(x, y, 1, 1, .handle, z: 2, d: 2) }
        for (x, y) in steel { put(x, y, 1, 1, .steel, z: 2, d: 2) }
        return m
    }

    // MARK: - Drawing

    static func render(_ pose: Pose, on canvas: CreatureCanvas) -> CreatureImage {
        var image = CreatureImage(canvas)
        // At work it stands left of the middle to leave room for the block.
        let x = Double(canvas.middle - (pose.hammer == nil ? 0 : 2))
        let view = VoxelView(yaw: pose.yaw, pivot: (6, Double(height), 3), at: (x, Double(canvas.floor - pose.lift)))
        let dim = pose.fade
        Voxels.draw(model(pose), palette: palette, view: view, into: &image,
                    tone: dim > 0 ? { $0.scaled(1 - 0.5 * dim) } : nil)
        let top = Double(head + pose.crouch)
        if let burst = pose.sparks {
            let hit = view.project(15.5, 10, 2)
            let (cx, cy) = (Int(hit.x.rounded(.down)), Int(hit.y.rounded(.down)))
            let flecks: [[(Int, Int, Double)]] = [
                [(-2, -1, 1), (2, -1, 1), (0, -2, 1)],
                [(-3, -2, 1), (3, -2, 1), (-1, -3, 0.8), (1, -4, 0.8)],
                [(-4, -2, 0.5), (4, -1, 0.5), (0, -5, 0.4)],
            ]
            for (dx, dy, alpha) in flecks[burst] { image.set(cx + dx, cy + dy, spark, alpha: alpha) }
        }
        if let flight = pose.flying {
            let start = view.project(15, Double(head + 4), 2)
            let arc = [(0, -2), (1, -4), (1, -5), (2, -5), (2, -3), (3, -1)]
            let (px, py) = flight < arc.count
                ? (Int(start.x.rounded(.down)) + arc[flight].0, Int(start.y.rounded(.down)) + arc[flight].1)
                : (min(Int(start.x.rounded(.down)) + 3, canvas.columns - 2), canvas.floor - 2)
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                image.set(px + dx, py + dy, palette[Int(Ink.steel.rawValue) - 1].scaled(dy == 1 ? 0.75 : 1))
            }
        }
        if let puff = pose.dust {
            let row = canvas.floor - 1
            let left = Int(view.project(0, Double(height), 3).x.rounded(.down)), right = Int(view.project(12, Double(height), 3).x.rounded(.down))
            for (x, outward) in [(left - 1, -1), (right, 1)] {
                image.set(x + outward * puff, row - puff, dustGrey, alpha: puff == 0 ? 0.9 : 0.5)
                if puff == 1 { image.set(x + outward * 2, row, dustGrey, alpha: 0.35) }
            }
        }
        if let mark = pose.held {
            let hand = view.project(11, top, 1)
            image.draw(mark, bottomCenter: (hand.x, hand.y - 1 - Double(pose.bob)))
        }
        if let mark = pose.overHand {
            let hand = view.project(0, top, 1)
            image.draw(mark, bottomCenter: (hand.x, hand.y - 1 - Double(pose.bob)))
        }
        if let mark = pose.thought {
            let crown = view.project(6, top - (pose.hat == nil ? 0 : 3), 1)
            image.draw(mark, bottomCenter: (crown.x, crown.y - 2))
        }
        if pose.sweat {
            let brow = view.project(1, top, 1)
            image.draw(.sweat, bottomCenter: (brow.x - 1, brow.y + 1))
        }
        if let turn = pose.dizzy {
            let crown = view.project(6, top - 3, 2)
            for star in 0..<2 {
                let angle = Double(turn) * .pi / 4 + Double(star) * .pi
                // Where they cross, the one going round the back is hidden.
                if sin(angle) < -0.9 { continue }
                image.draw(.star, bottomCenter: (crown.x + 5 * cos(angle), crown.y - 2 + sin(angle)))
            }
        }
        if let flight = pose.tossed {
            // Up and out over its right hand, end over end, then down beside it with a bounce.
            let lifted = view.project(6, top - 2, 1)
            let land = (x: Double(canvas.columns - 3), y: Double(canvas.floor - 1))
            let path = [(lifted.x + 1, lifted.y - 1), (lifted.x + 3, lifted.y - 2), (lifted.x + 5, lifted.y - 2),
                        (land.x, lifted.y), (land.x, lifted.y + 4), (land.x, land.y - 2), land, (land.x, land.y - 1), land]
            let (x, y) = path[min(flight, path.count - 1)]
            // Over on its back every other frame while it flies.
            let flipped = flight < 6 && flight % 2 == 1
            let hat = palette[Int(Ink.hat.rawValue) - 1], ridge = palette[Int(Ink.ridge.rawValue) - 1]
            let left = Int((x - 2.5).rounded()), brim = Int(y.rounded(.down))
            let crown = flipped ? brim : brim - 1, rim = flipped ? brim - 1 : brim
            for dx in 0..<5 { image.set(left + dx, rim, hat) }
            for dx in 1..<4 { image.set(left + dx, crown, dx == 2 ? ridge : hat) }
        }
        if let k = pose.twinkle {
            let sizes = [0, 1, 2, 2, 1, 0]
            let side = view.project(-1, top, 1), above = view.project(3, top - 3, 1)
            image.draw(.twinkle(sizes[k]), bottomCenter: (side.x - 1, side.y))
            image.draw(.twinkle(min(1, sizes[(k + 3) % sizes.count])), bottomCenter: (above.x, above.y + 1))
        }
        return image
    }

    // MARK: - Sounds

    /// A note of a sound: start and length in seconds, pitch, and an optional pitch to slide to by its end.
    struct Note {
        let start: Double, length: Double, hz: Double
        var slideTo: Double?
    }

    /// One sound: pulse-wave notes through a shared low-pass and a master gain, maybe with an echo.
    struct Voice {
        let duty: Double
        let attack: Double, decay: Double, sustain: Double, release: Double
        let lowpass: Double, master: Double
        let notes: [Note]
        var echo: (delay: Double, gain: Double, lowpass: Double)?
        let seconds: Double

        func render() -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double) {
            var graph = SynthGraph()
            // A pulse wave of this duty, as a periodic wave of 48 terms.
            // Typed one step at a time: Xcode 26 gives up on these as one expression.
            let terms = (1...48).map { Double($0) }
            let real: [Double] = [0] + terms.map { (n: Double) -> Double in sin(2 * .pi * n * duty) / (n * .pi) }
            let imag: [Double] = [0] + terms.map { (n: Double) -> Double in (1 - cos(2 * .pi * n * duty)) / (n * .pi) }
            let wave = SynthGraph.Wave.custom(real: real, imag: imag)
            let voices = notes.map { note -> SynthGraph.Node in
                let end = note.start + note.length
                var pitch = SynthGraph.Param(note.hz).set(note.hz, at: note.start)
                if let target = note.slideTo { pitch = pitch.exponential(to: target, at: end) }
                // The release starts at the note's end, or after the decay if the note is shorter.
                let held = max(end, note.start + attack + decay)
                let level = SynthGraph.Param(0.0001)
                    .set(0.0001, at: note.start)
                    .linear(to: 1, at: note.start + attack)
                    .linear(to: sustain, at: note.start + attack + decay)
                    .set(sustain, at: held)
                    .exponential(to: 0.0001, at: held + release)
                let oscillator = graph.oscillator(wave, frequency: pitch, start: note.start, stop: held + release + 0.02)
                return graph.gain(level, oscillator)
            }
            let low = graph.filter(.lowpass, hz: lowpass, q: 0.5)
            for voice in voices { graph.connect(voice, to: low) }
            var master = graph.gain(self.master, low)
            if let echo {
                let delayed = graph.delay(echo.delay, low)
                let quiet = graph.gain(echo.gain, delayed)
                let soft = graph.filter(.lowpass, hz: echo.lowpass, quiet)
                master = graph.gain(self.master, low, soft)
            }
            return (graph, master, seconds)
        }
    }

    static func voice(for cue: CreatureCue) -> Voice {
        switch cue {
        // A rising fourth, "hello?", with a soft echo.
        case .attention:
            Voice(duty: 0.25, attack: 0.004, decay: 0.05, sustain: 0.55, release: 0.06, lowpass: 3000, master: 0.091,
                  notes: [Note(start: 0, length: 0.085, hz: 659.26), Note(start: 0.1, length: 0.12, hz: 880)],
                  echo: (delay: 0.09, gain: 0.28, lowpass: 2200), seconds: 0.45)
        // A major arpeggio up an octave.
        case .done:
            Voice(duty: 0.5, attack: 0.004, decay: 0.04, sustain: 0.6, release: 0.06, lowpass: 3200, master: 0.097,
                  notes: [Note(start: 0, length: 0.065, hz: 523.25), Note(start: 0.07, length: 0.065, hz: 659.26),
                          Note(start: 0.14, length: 0.065, hz: 783.99), Note(start: 0.21, length: 0.1, hz: 1046.5)],
                  seconds: 0.42)
        // Three falling notes, the last sliding down.
        case .failed:
            Voice(duty: 0.5, attack: 0.006, decay: 0.05, sustain: 0.6, release: 0.07, lowpass: 1500, master: 0.098,
                  notes: [Note(start: 0, length: 0.085, hz: 493.88), Note(start: 0.09, length: 0.085, hz: 392),
                          Note(start: 0.18, length: 0.1, hz: 311.13, slideTo: 293.66)],
                  seconds: 0.4)
        }
    }
}

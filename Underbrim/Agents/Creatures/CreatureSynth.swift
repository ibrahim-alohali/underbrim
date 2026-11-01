//
//  CreatureSynth.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The creatures' sounds, made in code: a small graph of oscillators, noise, gains,
//  filters and delays with Web Audio's rules (ramps, band-limited waves, biquads),
//  rendered once into samples. No recordings.
//

import Foundation

struct SynthGraph: Sendable {
    struct Node: Hashable, Sendable {
        fileprivate let index: Int
    }

    enum Wave: Sendable {
        case sine, square, sawtooth, triangle
        /// Fourier terms, as Web Audio's PeriodicWave takes them (index 0 unused), scaled to a peak of 1.
        case custom(real: [Double], imag: [Double])
    }

    enum FilterKind: Sendable {
        /// Q in decibels, as Web Audio's lowpass and highpass read it.
        case lowpass, highpass
        /// Q as a plain ratio.
        case bandpass
    }

    /// A value over time: Web Audio's AudioParam, with its ramps.
    struct Param: Sendable {
        enum Ramp: Sendable { case jump, linear, exponential, target(constant: Double) }
        private struct Event: Sendable { var time: Double; var value: Double; var ramp: Ramp }
        private let initial: Double
        private var events: [Event] = []

        init(_ value: Double) { initial = value }

        /// setValueAtTime
        func set(_ value: Double, at time: Double) -> Param { adding(.init(time: time, value: value, ramp: .jump)) }
        /// linearRampToValueAtTime
        func linear(to value: Double, at time: Double) -> Param { adding(.init(time: time, value: value, ramp: .linear)) }
        /// exponentialRampToValueAtTime
        func exponential(to value: Double, at time: Double) -> Param { adding(.init(time: time, value: value, ramp: .exponential)) }
        /// setTargetAtTime
        func target(_ value: Double, at time: Double, constant: Double) -> Param {
            adding(.init(time: time, value: value, ramp: .target(constant: constant)))
        }

        private func adding(_ event: Event) -> Param {
            var copy = self
            let index = copy.events.firstIndex { $0.time > event.time } ?? copy.events.count
            copy.events.insert(event, at: index)
            return copy
        }

        func value(at time: Double) -> Double {
            var value = initial, from = 0.0
            for (index, event) in events.enumerated() {
                switch event.ramp {
                case .target(let constant):
                    guard time >= event.time else { return value }
                    // Approaches the value from what it was when it started, until the next event.
                    let next = events.indices.contains(index + 1) ? events[index + 1] : nil
                    let until = next.map { min(time, $0.time) } ?? time
                    value = event.value + (value - event.value) * exp(-(until - event.time) / max(constant, 1e-9))
                    from = until
                    if let next, time >= next.time, case .jump = next.ramp {} else if next == nil || time < next!.time { return value }
                case .jump:
                    guard time >= event.time else { return value }
                    value = event.value
                    from = event.time
                case .linear, .exponential:
                    if time >= event.time { value = event.value; from = event.time; continue }
                    let progress = (time - from) / max(event.time - from, 1e-9)
                    if case .exponential = event.ramp {
                        // Web Audio holds the old value when the two differ in sign or one is zero.
                        guard value * event.value > 0 else { return value }
                        return value * pow(event.value / value, progress)
                    }
                    return value + (event.value - value) * progress
                }
            }
            return value
        }
    }

    private enum Unit: Sendable {
        case oscillator(Wave, frequency: Param, start: Double, stop: Double)
        case noise(seed: UInt32, start: Double, length: Double)
        case gain(Param)
        case filter(FilterKind, frequency: Param, q: Double)
        case delay(Double)
    }

    private var units: [Unit] = []
    private var inputs: [[Int]] = []
    private var modulators: [Int: [Int]] = [:]

    init() {}

    mutating func oscillator(_ wave: Wave, frequency: Param, start: Double, stop: Double) -> Node {
        add(.oscillator(wave, frequency: frequency, start: start, stop: stop), [])
    }

    mutating func oscillator(_ wave: Wave, hz: Double, start: Double, stop: Double) -> Node {
        oscillator(wave, frequency: Param(hz), start: start, stop: stop)
    }

    /// White noise from a seeded generator (mulberry32), `length` seconds long, played once.
    mutating func noise(seed: UInt32, start: Double, length: Double) -> Node {
        add(.noise(seed: seed, start: start, length: length), [])
    }

    mutating func gain(_ gain: Param, _ sources: Node...) -> Node { add(.gain(gain), sources) }
    mutating func gain(_ value: Double, _ sources: Node...) -> Node { add(.gain(Param(value)), sources) }

    mutating func filter(_ kind: FilterKind, frequency: Param, q: Double = 1, _ sources: Node...) -> Node {
        add(.filter(kind, frequency: frequency, q: q), sources)
    }

    mutating func filter(_ kind: FilterKind, hz: Double, q: Double = 1, _ sources: Node...) -> Node {
        add(.filter(kind, frequency: Param(hz), q: q), sources)
    }

    mutating func delay(_ seconds: Double, _ sources: Node...) -> Node { add(.delay(seconds), sources) }

    /// One more input for `node`, which may come later in the graph: a delay's feedback, say.
    /// Anything but a delay hears a later node one sample late.
    mutating func connect(_ source: Node, to node: Node) { inputs[node.index].append(source.index) }

    /// Adds `source` to an oscillator's frequency, in hertz (frequency modulation).
    mutating func modulate(frequencyOf oscillator: Node, by source: Node) {
        modulators[oscillator.index, default: []].append(source.index)
    }

    private mutating func add(_ unit: Unit, _ sources: [Node]) -> Node {
        units.append(unit)
        inputs.append(sources.map(\.index))
        return Node(index: units.count - 1)
    }

    func render(_ output: Node, seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        let count = Int(seconds * sampleRate)
        var values = [Double](repeating: 0, count: units.count)
        var phases = [Double](repeating: 0, count: units.count)
        var tables: [Int: [Int: [Double]]] = [:]
        var scales: [Int: Double] = [:]
        var filters = [Biquad](repeating: Biquad(), count: units.count)
        var histories: [Int: [Double]] = [:]
        var noises: [Int: [Double]] = [:]
        for (index, unit) in units.enumerated() {
            switch unit {
            case .delay(let seconds):
                histories[index] = [Double](repeating: 0, count: max(1, Int((seconds * sampleRate).rounded())))
            case .noise(let seed, _, let length):
                var generator = Mulberry32(seed: seed)
                noises[index] = (0..<Int(length * sampleRate)).map { _ in generator.next() * 2 - 1 }
            case .oscillator(let wave, _, _, _):
                scales[index] = Self.scale(of: wave)
            default: break
            }
        }
        var samples = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            let time = Double(frame) / sampleRate
            for (index, unit) in units.enumerated() {
                func input() -> Double { inputs[index].reduce(0) { $0 + values[$1] } }
                switch unit {
                case .oscillator(let wave, let frequency, let start, let stop):
                    guard time >= start, time < stop else { values[index] = 0; continue }
                    let hz = frequency.value(at: time) + (modulators[index] ?? []).reduce(0) { $0 + values[$1] }
                    let harmonics = max(1, Int(sampleRate / 2 / max(abs(hz), 1)))
                    let table = tables[index, default: [:]][harmonics] ?? {
                        let made = Self.table(wave, harmonics: harmonics, scale: scales[index] ?? 1)
                        tables[index, default: [:]][harmonics] = made
                        return made
                    }()
                    let position = phases[index] * Double(table.count)
                    let lower = Int(position) % table.count
                    let fraction = position - Double(Int(position))
                    values[index] = table[lower] + (table[(lower + 1) % table.count] - table[lower]) * fraction
                    phases[index] = (phases[index] + hz / sampleRate).truncatingRemainder(dividingBy: 1)
                    if phases[index] < 0 { phases[index] += 1 }
                case .noise(_, let start, _):
                    let buffer = noises[index] ?? []
                    let offset = Int(((time - start) * sampleRate).rounded(.down))
                    values[index] = time >= start && offset < buffer.count ? buffer[offset] : 0
                case .gain(let gain):
                    values[index] = input() * gain.value(at: time)
                case .filter(let kind, let frequency, let q):
                    filters[index].tune(kind, hz: frequency.value(at: time), q: q, sampleRate: sampleRate)
                    values[index] = filters[index].process(input())
                case .delay:
                    let history = histories[index] ?? [0]
                    values[index] = history[frame % history.count]
                }
            }
            // The delays take in what reaches them now, for later.
            for index in histories.keys {
                histories[index]![frame % histories[index]!.count] = inputs[index].reduce(0) { $0 + values[$1] }
            }
            samples[frame] = Float(values[output.index])
        }
        return samples
    }

    /// A wave's Fourier terms (sine terms in `imag`), as Web Audio defines its built-in waves.
    private static func terms(_ wave: Wave) -> (real: [Double], imag: [Double]) {
        let count = 4096
        func series(_ term: (Double) -> Double) -> [Double] { [0] + (1..<count).map { term(Double($0)) } }
        switch wave {
        case .sine: return ([0, 0], [0, 1])
        case .square: return ([Double](repeating: 0, count: count), series { 2 / ($0 * .pi) * (1 - pow(-1, $0)) })
        case .sawtooth: return ([Double](repeating: 0, count: count), series { pow(-1, $0 + 1) * 2 / ($0 * .pi) })
        case .triangle: return ([Double](repeating: 0, count: count), series { 8 * sin($0 * .pi / 2) / pow($0 * .pi, 2) })
        case .custom(let real, let imag): return (real, imag)
        }
    }

    private static let tableSize = 2048

    private static func table(_ wave: Wave, harmonics: Int, scale: Double) -> [Double] {
        let (real, imag) = terms(wave)
        let last = min(harmonics, max(real.count, imag.count) - 1)
        return (0..<tableSize).map { step in
            let x = 2 * Double.pi * Double(step) / Double(tableSize)
            var sum = 0.0
            if last >= 1 {
                for n in 1...last {
                    let a = n < real.count ? real[n] : 0, b = n < imag.count ? imag[n] : 0
                    if a != 0 { sum += a * cos(Double(n) * x) }
                    if b != 0 { sum += b * sin(Double(n) * x) }
                }
            }
            return sum * scale
        }
    }

    /// What scales the full wave to a peak of 1 (Web Audio normalizes every periodic wave).
    private static func scale(of wave: Wave) -> Double {
        if case .sine = wave { return 1 }
        let peak = table(wave, harmonics: 512, scale: 1).map(abs).max() ?? 1
        return peak > 0 ? 1 / peak : 1
    }
}

/// A biquad filter, with the coefficients of Web Audio's BiquadFilterNode.
private struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var tuned: (Double, Double)?

    mutating func tune(_ kind: SynthGraph.FilterKind, hz: Double, q: Double, sampleRate: Double) {
        guard tuned.map({ $0 != (hz, q) }) ?? true else { return }
        tuned = (hz, q)
        let w0 = 2 * Double.pi * min(max(hz, 1), sampleRate / 2 - 1) / sampleRate
        let cosine = cos(w0)
        let a0: Double
        switch kind {
        case .lowpass, .highpass:
            let alpha = sin(w0) / (2 * pow(10, q / 20))
            a0 = 1 + alpha
            if case .lowpass = kind {
                b0 = (1 - cosine) / 2; b1 = 1 - cosine
            } else {
                b0 = (1 + cosine) / 2; b1 = -(1 + cosine)
            }
            b2 = b0
            a1 = -2 * cosine; a2 = 1 - alpha
        case .bandpass:
            let alpha = sin(w0) / (2 * max(q, 1e-4))
            a0 = 1 + alpha
            b0 = alpha; b1 = 0; b2 = -alpha
            a1 = -2 * cosine; a2 = 1 - alpha
        }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// The small seeded generator the sound designs were made with, values in 0..<1.
private struct Mulberry32 {
    private var state: UInt32
    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

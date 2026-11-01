//
//  SpectrumAnalyzer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The waveform's bands from captured audio: a Hann-windowed FFT (Accelerate),
//  the power in log-spaced bands with a pink-noise tilt, mapped to 0…1 and
//  smoothed so the bars rise quickly and fall slowly.
//

import Accelerate
import Foundation

/// Not thread-safe: one queue at a time uses it (AudioCaptureManager's FFT queue,
/// or its lifecycle queue while no FFT runs).
final class SpectrumAnalyzer {
    /// Samples per analysis.
    static let fftSize = 1024
    private static let log2n: vDSP_Length = 10
    private static let floorDB: Float = -58
    private static let ceilDB: Float = -14
    private static let referenceHz: Double = 1000
    private static let pinkCompensationSlopePerOctave: Double = 3.0

    let bandCount: Int

    /// If setup fails (essentially impossible on real hardware) the FFT path
    /// degrades to flat bars instead of taking down the whole app.
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let hannWindow: [Float]
    private let windowPowerScalar: Float
    private var samplesBuf: [Float]
    private var windowedBuf: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var powBuf: [Float]
    private var smoothed: [Float]
    private var barsBuf: [Float]
    private var lastPublishedBuf: [Float]
    private var bandRanges: [Range<Int>] = []
    private var pinkCompensationDB: [Float] = []

    init(bandCount: Int, sampleRate: Double) {
        self.bandCount = bandCount
        fft = vDSP.FFT(log2n: Self.log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.fftSize,
            isHalfWindow: false
        )
        hannWindow = window
        // Parseval-style normalization so full-scale input lands near 0 dBFS.
        // Factor of 2 folds the one-sided real FFT back to total power.
        let windowPowerGain = vDSP.sum(vDSP.multiply(window, window))
        windowPowerScalar = 2.0 / (Float(Self.fftSize) * windowPowerGain)
        samplesBuf = [Float](repeating: 0, count: Self.fftSize)
        windowedBuf = [Float](repeating: 0, count: Self.fftSize)
        realBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        imagBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        powBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        smoothed = [Float](repeating: 0, count: bandCount)
        barsBuf = [Float](repeating: 0, count: bandCount)
        // Seed with a sentinel so the first real frame always publishes.
        lastPublishedBuf = [Float](repeating: -1, count: bandCount)
        setSampleRate(sampleRate)
    }

    /// Back to silence, so the next frame publishes.
    func reset() {
        for i in 0..<bandCount {
            smoothed[i] = 0
            barsBuf[i] = 0
            lastPublishedBuf[i] = -1
        }
    }

    /// The bands for the newest `fftSize` samples, which `fill` writes; nil when nothing perceptible
    /// changed since the last bands returned (or there's no FFT).
    func analyze(fill: (UnsafeMutableBufferPointer<Float>) -> Void) -> [Float]? {
        guard let fft else { return nil }
        let n = Self.fftSize
        samplesBuf.withUnsafeMutableBufferPointer { fill($0) }

        vDSP.multiply(samplesBuf, hannWindow, result: &windowedBuf)

        let halfN = n / 2
        realBuf.withUnsafeMutableBufferPointer { rPtr in
            imagBuf.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                windowedBuf.withUnsafeBufferPointer { wPtr in
                    wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                fft.forward(input: split, output: &split)
                // vDSP packs DC in realp[0] and Nyquist in imagp[0]; zero both
                // so they can't pollute the sub-bass band.
                rPtr[0] = 0
                iPtr[0] = 0
                vDSP.squareMagnitudes(split, result: &powBuf)
            }
        }
        vDSP.multiply(windowPowerScalar, powBuf, result: &powBuf)

        let floorDB = Self.floorDB
        let ceilDB = Self.ceilDB
        let dbRange = ceilDB - floorDB
        powBuf.withUnsafeBufferPointer { pPtr in
            guard let base = pPtr.baseAddress else { return }
            for i in 0..<bandCount {
                let range = bandRanges[i]
                guard !range.isEmpty else { barsBuf[i] = 0; continue }
                var sum: Float = 0
                vDSP_sve(base.advanced(by: range.lowerBound), 1, &sum, vDSP_Length(range.count))
                let meanPow = sum / Float(range.count)
                let db = 10 * log10f(max(meanPow, 1e-12)) + pinkCompensationDB[i]
                let clamped = max(floorDB, min(ceilDB, db))
                barsBuf[i] = (clamped - floorDB) / dbRange
            }
        }

        var maxDelta: Float = 0
        for i in 0..<bandCount {
            let target = barsBuf[i]
            let decayed = smoothed[i] * 0.86
            let next = target > decayed ? (decayed + (target - decayed) * 0.58) : decayed
            smoothed[i] = next
            let clipped = max(0, min(1, next))
            barsBuf[i] = clipped
            let delta = abs(clipped - lastPublishedBuf[i])
            if delta > maxDelta { maxDelta = delta }
        }

        // Skip main-thread delivery when nothing perceptible changed.
        guard maxDelta > 1e-4 else { return nil }
        for i in 0..<bandCount {
            lastPublishedBuf[i] = barsBuf[i]
        }
        return barsBuf
    }

    /// The bands' FFT bins for a sample rate: log-spaced from 60 Hz to 16 kHz (or just under Nyquist).
    func setSampleRate(_ sampleRate: Double) {
        let halfN = Self.fftSize / 2
        let nyquist = sampleRate / 2
        let minHz: Double = 60
        let maxHz: Double = min(16_000, nyquist - 1)
        guard maxHz > minHz else {
            bandRanges = Array(repeating: 0..<0, count: bandCount)
            pinkCompensationDB = Array(repeating: 0, count: bandCount)
            return
        }
        let logMin = log(minHz)
        let logMax = log(maxHz)
        var ranges: [Range<Int>] = []
        var pinks: [Float] = []
        for i in 0..<bandCount {
            let startHz = exp(logMin + (logMax - logMin) * Double(i) / Double(bandCount))
            let endHz = exp(logMin + (logMax - logMin) * Double(i + 1) / Double(bandCount))
            let startBin = max(1, Int((startHz / nyquist) * Double(halfN)))
            let endBin = max(startBin + 1, min(halfN, Int((endHz / nyquist) * Double(halfN))))
            ranges.append(startBin..<endBin)
            let centerHz = sqrt(startHz * endHz)
            pinks.append(Float(Self.pinkCompensationSlopePerOctave * log2(centerHz / Self.referenceHz)))
        }
        bandRanges = ranges
        pinkCompensationDB = pinks
    }
}

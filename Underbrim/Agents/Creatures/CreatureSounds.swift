//
//  CreatureSounds.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Plays a creature's sound like any alert: on the alert device and volume, times the
//  app's own volume. Each sound is rendered once, off the main thread, into Caches. At
//  most one sound a second, so sessions finishing together don't pile up.
//

import AudioToolbox
import Foundation
import os

@MainActor
final class CreatureSounds {
    static let shared = CreatureSounds()

    private var sounds: [String: SystemSoundID] = [:]
    private var rendering: Set<String> = []
    private var lastPlayed = Date.distantPast
    private let log = Logger(subsystem: bundleIdentifier, category: "agents")
    private static let version = 1

    func play(_ cue: CreatureCue, for kind: AgentCreatureKind, volume: Double) {
        guard volume > 0, Date().timeIntervalSince(lastPlayed) >= 1 else { return }
        lastPlayed = Date()
        // In steps of 10 %, so a slider leaves a few files per sound, not dozens.
        let level = Int((min(volume, 1) * 10).rounded()) * 10
        guard level > 0 else { return }
        let key = "\(kind.soundName)-\(cue)-\(level)"
        log.info("sound \(key, privacy: .public)")
        if let sound = sounds[key] {
            AudioServicesPlaySystemSoundWithCompletion(sound, nil)
            return
        }
        guard !rendering.contains(key) else { return }
        rendering.insert(key)
        let creature = kind.creature
        Task.detached(priority: .userInitiated) {
            let url = Self.file(for: key)
            if !FileManager.default.fileExists(atPath: url.path) {
                let (graph, output, seconds) = creature.sound(cue)
                let samples = graph.render(output, seconds: seconds).map { $0 * Float(level) / 100 }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Self.wave(samples).write(to: url, options: .atomic)
            }
            await MainActor.run {
                self.rendering.remove(key)
                var sound: SystemSoundID = 0
                guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return }
                self.sounds[key] = sound
                AudioServicesPlaySystemSoundWithCompletion(sound, nil)
            }
        }
    }

    nonisolated private static func file(for key: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Underbrim")
            .appendingPathComponent("Sounds/v\(version)/\(key).wav")
    }

    /// 16-bit mono PCM at 44.1 kHz in a WAVE file.
    nonisolated static func wave(_ samples: [Float], rate: Int = 44_100) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16).littleEndian); put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian); put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2).littleEndian)
        for sample in samples { put(Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian) }
        return data
    }
}

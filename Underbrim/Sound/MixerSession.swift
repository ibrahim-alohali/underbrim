//
//  MixerSession.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  One app's sound at its own level: a private tap that mutes its processes while read, and a
//  private aggregate of the output device and that tap, whose IO proc (MixerRender.c) plays the
//  sound at the level. Private objects go when Underbrim does and an unread tap no longer mutes,
//  so a crash leaves the app as loud as it was. Method adapted from FineTune (GPL-3.0).
//

import CoreAudio
import Foundation
import os

/// Built, changed and torn down on the mixer's queue only.
@available(macOS 14.4, *)
final class MixerSession {
    let app: String
    let processes: [AudioObjectID]
    let deviceUID: String
    let sampleRate: Double

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var voice: OpaquePointer?
    private(set) var resting: Bool
    private static let log = Logger(subsystem: bundleIdentifier, category: "sound")

    /// Plays `app` at `gain` on `deviceUID`; nil (with nothing left behind) when any step fails.
    init?(app: String, processes: [AudioObjectID], deviceUID: String, gain: Float, playing: Bool) {
        self.app = app
        resting = !playing
        self.processes = processes
        self.deviceUID = deviceUID
        guard let tap = Self.makeTap(processes: processes, deviceUID: deviceUID) else { return nil }
        self.tap = tap
        guard let tapUID = MixerAudio.string(tap, kAudioTapPropertyUID) else {
            Self.log.error("no tap UID for \(app, privacy: .public)")
            sampleRate = 0
            teardown()
            return nil
        }
        var format = AudioStreamBasicDescription()
        guard MixerAudio.get(tap, kAudioTapPropertyFormat, into: &format),
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            Self.log.error("unexpected tap format for \(app, privacy: .public)")
            sampleRate = 0
            teardown()
            return nil
        }
        sampleRate = format.mSampleRate
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Underbrim-mixer-\(app)",
            kAudioAggregateDeviceUIDKey: "\(bundleIdentifier).mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            // The tap reads the device's own stream, on the device's clock: nothing drifts.
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let made = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard made == noErr, aggregate != kAudioObjectUnknown else {
            Self.log.error("aggregate for \(app, privacy: .public) failed: \(made)")
            teardown()
            return nil
        }
        self.aggregate = aggregate
        guard let voice = mixer_voice_create(sampleRate, gain) else {
            teardown()
            return nil
        }
        self.voice = voice
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcID(aggregate, mixer_render, UnsafeMutableRawPointer(voice), &proc)
        guard created == noErr, let proc else {
            Self.log.error("IO proc for \(app, privacy: .public) failed: \(created)")
            teardown()
            return nil
        }
        self.proc = proc
        useTapStreamOnly(proc)
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else {
            Self.log.error("start for \(app, privacy: .public) failed: \(started)")
            teardown()
            return nil
        }
        Self.log.info("tapped \(app, privacy: .public): \(processes.count) processes, \(Int(self.sampleRate)) Hz")
    }

    deinit { teardown() }

    func set(gain: Float) {
        if let voice { mixer_voice_set_gain(voice, gain) }
    }

    var cycles: (all: UInt64, silent: UInt64) {
        guard let voice else { return (0, 0) }
        return (mixer_voice_cycles(voice), mixer_voice_silent_cycles(voice))
    }

    /// The app went quiet: stops the IO, so nothing wakes while it's silent, and starts it again,
    /// which returns at once and waits for the app's next sound (the tap starts the aggregate).
    func rest() {
        guard !resting, let proc, aggregate != kAudioObjectUnknown else { return }
        resting = true
        AudioDeviceStop(aggregate, proc)
        let status = AudioDeviceStart(aggregate, proc)
        if status != noErr { Self.log.error("waiting start for \(self.app, privacy: .public) failed: \(status)") }
    }

    func wake() { resting = false }

    func takePeaks() -> (input: Float, output: Float) {
        guard let voice else { return (0, 0) }
        var input: Float = 0, output: Float = 0
        mixer_voice_take_peaks(voice, &input, &output)
        return (input, output)
    }

    /// Stops the IO, then the aggregate, then the tap (the app is heard directly again), then the voice.
    func teardown() {
        if let proc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        if let voice { mixer_voice_destroy(voice) }
        voice = nil
    }

    /// A tap on the device's first output stream, in its format; else a stereo mix of the app's sound.
    private static func makeTap(processes: [AudioObjectID], deviceUID: String) -> AudioObjectID? {
        let onStream = CATapDescription(processes: processes, deviceUID: deviceUID, stream: 0)
        let mixed = CATapDescription(stereoMixdownOfProcesses: processes)
        for description in [onStream, mixed] {
            description.uuid = UUID()
            description.muteBehavior = .mutedWhenTapped
            description.isPrivate = true
            var tap = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &tap)
            if status == noErr, tap != kAudioObjectUnknown { return tap }
            log.error("tap failed: \(status)")
        }
        return nil
    }

    /// An output device with inputs of its own (AirPods, a USB headset) adds them to the aggregate
    /// first; left on, macOS would count the microphone as in use. Only the last stream, the tap's, stays.
    private func useTapStreamOnly(_ proc: AudioDeviceIOProcID) {
        let streams = MixerAudio.count(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput,
                                       of: AudioStreamID.self)
        guard streams > 1 else { return }
        let header = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 16
        let size = header + streams * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streams)
        let flags = (raw + header).bindMemory(to: UInt32.self, capacity: streams)
        for index in 0..<streams { flags[index] = index == streams - 1 ? 1 : 0 }
        var address = MixerAudio.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), raw)
        if status != noErr { Self.log.error("stream usage for \(self.app, privacy: .public) failed: \(status)") }
    }
}

enum MixerAudio {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    @discardableResult
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) -> Bool {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var value: UInt32 = 0
        return get(object, selector, into: &value) ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func count<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) -> Int {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<T>.stride
    }

    static var defaultOutput: AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device),
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}

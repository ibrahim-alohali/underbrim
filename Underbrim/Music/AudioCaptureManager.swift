//
//  AudioCaptureManager.swift
//  Underbrim
//
//  Captures audio from the currently-playing music app via Core Audio
//  Process Tap (macOS 14.2+) and publishes 6 log-spaced magnitude bands
//  (SpectrumAnalyzer) for the visualizer.
//

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Darwin
import Defaults
import Foundation
import os

protocol AudioCaptureLevelsConsumer: AnyObject {
    func audioCaptureManager(_ manager: AudioCaptureManager, didProduceLevels values: [Float])
    /// On screen: the waveform's audio is captured only while one is.
    @MainActor var isShown: Bool { get }
}

final class AudioCaptureManager: ObservableObject {
    static let shared = AudioCaptureManager()

    /// Asks for the audio permission now (the first-run tour's tile) rather than at the first song, by
    /// creating a tap; off the main thread, as the call can wait for the answer.
    static func requestPermission() {
        guard #available(macOS 14.2, *) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            tap.isPrivate = true
            var id = AudioObjectID(kAudioObjectUnknown)
            if AudioHardwareCreateProcessTap(tap, &id) == noErr { AudioHardwareDestroyProcessTap(id) }
        }
    }

    static let barCount = 6
    private static let ringCapacity = 4096
    private static let fftIntervalMilliseconds = 33
    private static let fftLeewayMilliseconds = 0
    private static let fftQueueKey = DispatchSpecificKey<Void>()
    private static let lifecycleQueueKey = DispatchSpecificKey<Void>()
    private static let allowedAlreadyDestroyedStatuses: Set<OSStatus> = [
        kAudioHardwareBadObjectError,
        kAudioHardwareUnknownPropertyError
    ]

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var waveformShown = false

    private var cancellables = Set<AnyCancellable>()

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var currentPIDs: [pid_t] = []
    /// While macOS asks for System Audio Recording: the processes to tap if it's allowed.
    private var pidsAwaitingAccess: [pid_t]?
    private var askingAccess = false
    /// macOS said yes when asked, though its check may still be unsure.
    private var accessAnswered = false
    private var sampleRate: Double = 48_000

    private let ringBuffer: UnsafeMutablePointer<Float>
    private var ringWrite: Int = 0
    private let ringLock = OSAllocatedUnfairLock()
    private let levelsConsumerLock = OSAllocatedUnfairLock()
    private let levelsConsumers = NSHashTable<AnyObject>.weakObjects()
    private var latestLevels: [Float]?

    /// Used on the FFT queue, and on the lifecycle queue while no FFT runs.
    private let analyzer: SpectrumAnalyzer

    private let fftQueue = DispatchQueue(label: "\(bundleIdentifier).audiocapture.fft", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "\(bundleIdentifier).audiocapture.io", qos: .userInteractive)
    private let lifecycleQueue = DispatchQueue(label: "\(bundleIdentifier).audiocapture.lifecycle", qos: .userInitiated)
    private var fftTimer: DispatchSourceTimer?

    private init() {
        ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.ringCapacity)
        ringBuffer.initialize(repeating: 0, count: Self.ringCapacity)

        analyzer = SpectrumAnalyzer(bandCount: Self.barCount, sampleRate: sampleRate)

        fftQueue.setSpecific(key: Self.fftQueueKey, value: ())
        lifecycleQueue.setSpecific(key: Self.lifecycleQueueKey, value: ())
        Task { @MainActor [weak self] in
            self?.observeState()
        }
    }

    deinit {
        syncOnLifecycleQueue {
            stopCaptureOnLifecycleQueue()
        }
        ringBuffer.deinitialize(count: Self.ringCapacity)
        ringBuffer.deallocate()
    }

    func setLevelsConsumer(_ consumer: AudioCaptureLevelsConsumer) {
        levelsConsumerLock.lock()
        defer { levelsConsumerLock.unlock() }
        levelsConsumers.add(consumer)
    }

    func clearLevelsConsumer(_ consumer: AudioCaptureLevelsConsumer) {
        levelsConsumerLock.lock()
        defer { levelsConsumerLock.unlock() }
        levelsConsumers.remove(consumer)
    }

    @MainActor func waveformsChanged() {
        levelsConsumerLock.lock()
        let shown = levelsConsumers.allObjects.contains { ($0 as? AudioCaptureLevelsConsumer)?.isShown == true }
        levelsConsumerLock.unlock()
        if shown != waveformShown { waveformShown = shown }
    }

    func latestLevelsSnapshot() -> [Float]? {
        levelsConsumerLock.lock()
        defer { levelsConsumerLock.unlock() }
        return latestLevels
    }

    // MARK: - State observation

    @MainActor
    private func observeState() {
        // MusicManager is @MainActor — wire the publishers on the main
        // actor; delivery then continues via receive(on:) as before.
        Task { @MainActor in
            let music = MusicManager.shared
            // For a waveform on screen (gone for a moment, as the island opens and closes, isn't worth stopping for).
            let waveformShown = self.$waveformShown.removeDuplicates()
                .map { shown in
                    shown ? Just(true).eraseToAnyPublisher()
                        : Just(false).delay(for: .seconds(3), scheduler: DispatchQueue.main).eraseToAnyPublisher()
                }
                .switchToLatest()
            let enabledPublisher = Defaults.publisher(.realtimeAudioWaveform)
                .map(\.newValue)
                .prepend(Defaults[.realtimeAudioWaveform])
                .combineLatest(waveformShown) { $0 && $1 }
                .removeDuplicates()

            Publishers.CombineLatest4(
                music.$isPlaying.removeDuplicates(),
                music.$bundleIdentifier.removeDuplicates(),
                music.$audioCaptureBundleIdentifiers.removeDuplicates(),
                enabledPublisher
            )
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isPlaying, bundleID, captureBundleIDs, enabled in
                    self?.evaluate(
                        isPlaying: isPlaying,
                        displayBundleID: bundleID,
                        captureBundleIDs: captureBundleIDs,
                        enabled: enabled
                    )
                }
                .store(in: &cancellables)
        }
    }

    private func evaluate(
        isPlaying: Bool,
        displayBundleID: String?,
        captureBundleIDs: [String],
        enabled: Bool
    ) {
        guard #available(macOS 14.2, *),
              enabled, isPlaying,
              let resolvedDisplayBundleID = displayBundleID,
              !resolvedDisplayBundleID.isEmpty else {
            stopCaptureAsync()
            return
        }
        let resolvedPIDs = AudioCaptureTargets.pids(
            displayBundleID: resolvedDisplayBundleID,
            captureBundleIDs: captureBundleIDs
        )
        guard !resolvedPIDs.isEmpty else {
            stopCaptureAsync()
            return
        }
        lifecycleQueue.async { [weak self] in
            self?.startCaptureOnLifecycleQueue(pids: resolvedPIDs)
        }
    }

    private func stopCaptureAsync() {
        lifecycleQueue.async { [weak self] in
            self?.pidsAwaitingAccess = nil
            self?.stopCaptureOnLifecycleQueue()
        }
    }

    // MARK: - Capture lifecycle

    @available(macOS 14.2, *)
    private func startCaptureOnLifecycleQueue(pids: [pid_t]) {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        if ioProcID != nil, pids == currentPIDs { return }
        if captureIsConfigured {
            stopCaptureOnLifecycleQueue()
        }
        // A tap without the permission reads silence: none while it's denied, and none before macOS
        // answers, so the bars keep their own motion meanwhile.
        switch SoundMixer.currentAccess() {
        case .allowed:
            break
        case .denied:
            currentPIDs.removeAll(keepingCapacity: true)
            return
        case .notAsked:
            if accessAnswered { break }
            currentPIDs.removeAll(keepingCapacity: true)
            pidsAwaitingAccess = pids
            if askingAccess { return }
            askingAccess = SoundMixer.ask { [weak self] allowed in
                self?.lifecycleQueue.async {
                    guard let self else { return }
                    self.askingAccess = false
                    self.accessAnswered = allowed
                    guard allowed, let pids = self.pidsAwaitingAccess else { return }
                    self.pidsAwaitingAccess = nil
                    self.startCaptureOnLifecycleQueue(pids: pids)
                }
            }
            // Underbrim can't ask macOS this way: the tap asks, as before.
            if askingAccess { return }
            pidsAwaitingAccess = nil
        }

        let attachedProcesses = pids.compactMap { pid -> (pid: pid_t, objectID: AudioObjectID)? in
            guard let objectID = translatePIDToAudioObject(pid: pid) else {
                NSLog("[AudioCaptureManager] Failed to translate PID \(pid) to AudioObjectID")
                return nil
            }
            return (pid: pid, objectID: objectID)
        }
        guard !attachedProcesses.isEmpty else {
            currentPIDs.removeAll(keepingCapacity: true)
            return
        }
        let resolvedProcessObjectIDs = attachedProcesses.map(\.objectID)
        currentPIDs = attachedProcesses.map(\.pid)

        let tapDescription = CATapDescription(monoMixdownOfProcesses: resolvedProcessObjectIDs)
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            NSLog("[AudioCaptureManager] AudioHardwareCreateProcessTap failed: \(tapStatus)")
            currentPIDs.removeAll(keepingCapacity: true)
            return
        }
        tapObjectID = newTapID

        guard let tapUID = getAudioObjectStringProperty(
            objectID: tapObjectID,
            selector: kAudioTapPropertyUID
        ) else {
            NSLog("[AudioCaptureManager] Failed to read tap UID")
            currentPIDs.removeAll(keepingCapacity: true)
            cleanupTap()
            return
        }

        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let fmtStatus = AudioObjectGetPropertyData(
            tapObjectID, &formatAddr, 0, nil, &formatSize, &streamFormat
        )
        guard fmtStatus == noErr else {
            NSLog("[AudioCaptureManager] Failed to read tap format: \(fmtStatus)")
            currentPIDs.removeAll(keepingCapacity: true)
            cleanupTap()
            return
        }
        guard validateTapFormat(streamFormat) else {
            NSLog("[AudioCaptureManager] Unsupported tap format: \(streamFormat)")
            currentPIDs.removeAll(keepingCapacity: true)
            cleanupTap()
            return
        }
        if streamFormat.mSampleRate > 0 {
            sampleRate = streamFormat.mSampleRate
        }
        analyzer.setSampleRate(sampleRate)

        let aggregateUID = "\(bundleIdentifier).audiotap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "UnderbrimTapAggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: "",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 0
                ]
            ]
        ]

        var newAggID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggID
        )
        guard aggStatus == noErr, newAggID != 0 else {
            NSLog("[AudioCaptureManager] AudioHardwareCreateAggregateDevice failed: \(aggStatus)")
            currentPIDs.removeAll(keepingCapacity: true)
            cleanupTap()
            return
        }
        aggregateDeviceID = newAggID

        var newIOProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProc, aggregateDeviceID, ioQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleInputBuffer(inInputData)
        }
        guard ioStatus == noErr, let ioProc = newIOProc else {
            NSLog("[AudioCaptureManager] AudioDeviceCreateIOProcIDWithBlock failed: \(ioStatus)")
            currentPIDs.removeAll(keepingCapacity: true)
            cleanupAggregate()
            cleanupTap()
            return
        }
        ioProcID = ioProc

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProc)
        guard startStatus == noErr else {
            NSLog("[AudioCaptureManager] AudioDeviceStart failed: \(startStatus)")
            destroyIOProc(ioProc)
            ioProcID = nil
            currentPIDs.removeAll(keepingCapacity: true)
            cleanupAggregate()
            cleanupTap()
            return
        }

        startFFTTimer()
        setCapturing(true)
    }

    private var captureIsConfigured: Bool {
        ioProcID != nil || aggregateDeviceID != 0 || tapObjectID != kAudioObjectUnknown
    }

    private func syncOnLifecycleQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.lifecycleQueueKey) != nil {
            work()
        } else {
            lifecycleQueue.sync(execute: work)
        }
    }

    private func stopCaptureOnLifecycleQueue() {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        guard captureIsConfigured else { return }
        stopFFTTimer()
        teardownCapture()
        currentPIDs.removeAll(keepingCapacity: true)
        syncOnFFTQueue {
            resetProcessingState()
        }
        let zeros = [Float](repeating: 0, count: Self.barCount)
        setCapturing(false)
        publishLevels(zeros)
    }

    private func resetProcessingState() {
        ringLock.lock()
        ringBuffer.update(repeating: 0, count: Self.ringCapacity)
        ringWrite = 0
        ringLock.unlock()

        analyzer.reset()
    }

    private func teardownCapture() {
        if aggregateDeviceID != 0, let proc = ioProcID {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, proc)
            if stopStatus != noErr {
                NSLog("[AudioCaptureManager] AudioDeviceStop failed during teardown: \(stopStatus)")
            }
            destroyIOProc(proc)
        }
        ioProcID = nil
        cleanupAggregate()
        cleanupTap()
    }

    private func destroyIOProc(_ proc: AudioDeviceIOProcID) {
        guard aggregateDeviceID != 0 else { return }
        let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
        if status != noErr {
            NSLog("[AudioCaptureManager] AudioDeviceDestroyIOProcID failed: \(status)")
        }
    }

    private func cleanupAggregate() {
        if aggregateDeviceID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status == noErr || Self.allowedAlreadyDestroyedStatuses.contains(status) {
                aggregateDeviceID = 0
            } else {
                NSLog("[AudioCaptureManager] AudioHardwareDestroyAggregateDevice failed: \(status)")
            }
        }
    }

    private func cleanupTap() {
        guard tapObjectID != kAudioObjectUnknown else { return }
        if #available(macOS 14.2, *) {
            let status = AudioHardwareDestroyProcessTap(tapObjectID)
            if status == noErr || Self.allowedAlreadyDestroyedStatuses.contains(status) {
                tapObjectID = kAudioObjectUnknown
            } else {
                NSLog("[AudioCaptureManager] AudioHardwareDestroyProcessTap failed: \(status)")
            }
        } else {
            tapObjectID = kAudioObjectUnknown
        }
    }

    private func setCapturing(_ capturing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing != capturing else { return }
            self.isCapturing = capturing
        }
    }

    // MARK: - IO proc

    private func handleInputBuffer(_ bufferList: UnsafePointer<AudioBufferList>) {
        let mutableBL = UnsafeMutablePointer(mutating: bufferList)
        let abl = UnsafeMutableAudioBufferListPointer(mutableBL)
        guard let first = abl.first, let rawData = first.mData else { return }
        let expectedBytesPerFrame = UInt32(MemoryLayout<Float>.size)
        guard first.mNumberChannels == 1,
              first.mDataByteSize % expectedBytesPerFrame == 0 else { return }
        let frameCount = Int(first.mDataByteSize / expectedBytesPerFrame)
        guard frameCount > 0 else { return }
        let src = rawData.assumingMemoryBound(to: Float.self)

        ringLock.lock()
        defer { ringLock.unlock() }

        let cap = Self.ringCapacity
        if frameCount >= cap {
            let newestFrames = src.advanced(by: frameCount - cap)
            memcpy(ringBuffer, newestFrames, cap * MemoryLayout<Float>.size)
            ringWrite = 0
            return
        }
        let write = ringWrite
        let firstCount = min(frameCount, cap - write)
        memcpy(ringBuffer.advanced(by: write), src, firstCount * MemoryLayout<Float>.size)
        if firstCount < frameCount {
            memcpy(
                ringBuffer,
                src.advanced(by: firstCount),
                (frameCount - firstCount) * MemoryLayout<Float>.size
            )
        }
        ringWrite = (write + frameCount) % cap
    }

    // MARK: - FFT loop

    private func startFFTTimer() {
        let timer = DispatchSource.makeTimerSource(queue: fftQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(Self.fftIntervalMilliseconds),
            leeway: .milliseconds(Self.fftLeewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in self?.processFFT() }
        fftTimer = timer
        timer.resume()
    }

    private func stopFFTTimer() {
        fftTimer?.cancel()
        fftTimer = nil
    }

    private func syncOnFFTQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.fftQueueKey) != nil {
            work()
        } else {
            fftQueue.sync(execute: work)
        }
    }

    private func processFFT() {
        guard let levels = analyzer.analyze(fill: copyLatestSamples(into:)) else { return }
        publishLevels(levels)
    }

    /// The newest samples from the ring, as many as `dst` holds.
    private func copyLatestSamples(into dst: UnsafeMutableBufferPointer<Float>) {
        ringLock.lock()
        defer { ringLock.unlock() }

        let count = dst.count
        let cap = Self.ringCapacity
        let end = ringWrite
        let start = (end - count + cap) % cap
        guard let base = dst.baseAddress else { return }
        if start + count <= cap {
            memcpy(base, ringBuffer.advanced(by: start), count * MemoryLayout<Float>.size)
        } else {
            let firstCount = cap - start
            memcpy(base, ringBuffer.advanced(by: start), firstCount * MemoryLayout<Float>.size)
            memcpy(
                base.advanced(by: firstCount),
                ringBuffer,
                (count - firstCount) * MemoryLayout<Float>.size
            )
        }
    }

    private func publishLevels(_ values: [Float]) {
        levelsConsumerLock.lock()
        latestLevels = values
        let consumers = levelsConsumers.allObjects.compactMap { $0 as? AudioCaptureLevelsConsumer }
        levelsConsumerLock.unlock()
        guard !consumers.isEmpty else { return }

        let deliverLevels = { [weak self] in
            guard let self else { return }
            for consumer in consumers {
                consumer.audioCaptureManager(self, didProduceLevels: values)
            }
        }

        if Thread.isMainThread {
            deliverLevels()
        } else {
            DispatchQueue.main.async(execute: deliverLevels)
        }
    }

    private func validateTapFormat(_ format: AudioStreamBasicDescription) -> Bool {
        let floatPCMFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        return format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & floatPCMFlags) == floatPCMFlags
            && (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            && format.mChannelsPerFrame == 1
            && format.mBytesPerFrame == UInt32(MemoryLayout<Float>.size)
            && format.mBitsPerChannel == UInt32(MemoryLayout<Float>.size * 8)
    }

    // MARK: - Core Audio helpers

    private func translatePIDToAudioObject(pid: pid_t) -> AudioObjectID? {
        var pidVal = pid
        var processObject: AudioObjectID = kAudioObjectUnknown
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVal,
            &size,
            &processObject
        )
        guard status == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }

    private func getAudioObjectStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = cfStr else { return nil }
        return cfStr as String
    }
}

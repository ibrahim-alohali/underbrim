//
//  NowPlayingController.swift
//  Underbrim
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class NowPlayingController: NowPlayingRuntimeControlling {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: MediaAppBundleID.appleMusic
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == MediaAppBundleID.appleMusic || bundleID == MediaAppBundleID.spotify
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == MediaAppBundleID.appleMusic
    }

    /// Only Music and Spotify, through their own scripting: MediaRemote's shuffle and repeat do nothing
    /// from here, and a website's player takes play, pause, skip and seek only.
    var supportsShuffleAndRepeat: Bool {
        [MediaAppBundleID.appleMusic, MediaAppBundleID.spotify].contains(playbackState.bundleIdentifier)
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier

        if bundleID == MediaAppBundleID.appleMusic {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                _ = try? await AppleScriptHelper.execute(script)
            }
        }

        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let adapterScriptURL: URL
    private let adapterFrameworkPath: String

    let runtimeFailures: AsyncStream<Void>
    private let runtimeFailureContinuation: AsyncStream<Void>.Continuation

    private var streamSession: NowPlayingStreamSession?

    // MARK: - Initialization
    init() throws {
        let resources = try NowPlayingResources.load()

        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString)
        else {
            throw NowPlayingError.unavailable
        }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        adapterScriptURL = resources.adapterScriptURL
        adapterFrameworkPath = resources.adapterFrameworkPath

        let runtimeFailureChannel = AsyncStream.makeStream(of: Void.self)
        runtimeFailures = runtimeFailureChannel.stream
        runtimeFailureContinuation = runtimeFailureChannel.continuation
    }

    deinit {
        if let streamSession {
            Task { @MainActor in
                streamSession.stop()
            }
        }
        runtimeFailureContinuation.finish()
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }

    func toggleShuffle() async {
        switch playbackState.bundleIdentifier {
        case MediaAppBundleID.appleMusic: await script("Music", "set shuffle enabled to not shuffle enabled")
        case MediaAppBundleID.spotify: await script("Spotify", "set shuffling to not shuffling")
        default: return
        }
    }

    /// Music goes off, all, one, as its own button does; Spotify on and off.
    func toggleRepeat() async {
        switch playbackState.bundleIdentifier {
        case MediaAppBundleID.appleMusic:
            await script("Music", """
                if song repeat is off then
                    set song repeat to all
                else if song repeat is all then
                    set song repeat to one
                else
                    set song repeat to off
                end if
                """)
        case MediaAppBundleID.spotify: await script("Spotify", "set repeating to not repeating")
        default: return
        }
    }

    /// Changes shuffle or repeat in Music or Spotify, then reads both back so the buttons show the result.
    private func script(_ app: String, _ command: String) async {
        await AppleScriptHelper.run("tell application \"\(app)\"\n\(command)\nend tell")
        let read = app == "Music"
            ? "tell application \"Music\" to return {shuffle enabled, song repeat is one, song repeat is all}"
            : "tell application \"Spotify\" to return {shuffling, false, repeating}"
        guard let result = try? await AppleScriptHelper.execute(read), result.numberOfItems == 3 else { return }
        var updated = playbackState
        updated.isShuffled = result.atIndex(1)?.booleanValue ?? false
        updated.repeatMode = result.atIndex(2)?.booleanValue == true ? .one : result.atIndex(3)?.booleanValue == true ? .all : .off
        playbackState = updated
    }

    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)

        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == MediaAppBundleID.appleMusic {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
                if !runningApps.isEmpty {
                    await AppleScriptHelper.run("tell application \"Music\" to set sound volume to \(volumePercentage)")
                }
            } else if bundleID == MediaAppBundleID.spotify {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.spotify)
                if !runningApps.isEmpty {
                    await AppleScriptHelper.run("tell application \"Spotify\" to set sound volume to \(volumePercentage)")
                }
            }
        }

        playbackState.volume = clampedLevel
    }

    // MARK: - Runtime Stream Lifecycle
    func startRuntimeStream() {
        guard streamSession == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapterScriptURL.path, adapterFrameworkPath, "stream"]
        process.environment = Process.cleanEnvironment()  // perl reads PERL5OPT and PERL5LIB

        let session = NowPlayingStreamSession(
            process: process,
            onUpdate: { [weak self] update in
                await self?.handleAdapterUpdate(update)
            },
            onFailure: { [weak self] in
                guard let self else { return }
                self.streamSession = nil
                self.runtimeFailureContinuation.yield()
            }
        )
        streamSession = session
        session.start()
    }

    func stopRuntimeStream() {
        let session = streamSession
        streamSession = nil
        session?.stop()
    }

    // MARK: - Update Methods
    func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        let resolvedBundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? self.playbackState.bundleIdentifier : "")
        )
        let captureBundleFallbackIdentifiers: [String]
        if diff {
            captureBundleFallbackIdentifiers =
                resolvedBundleIdentifier != self.playbackState.bundleIdentifier
                ? [resolvedBundleIdentifier]
                : self.playbackState.effectiveAudioCaptureBundleIdentifiers
        } else {
            captureBundleFallbackIdentifiers = [resolvedBundleIdentifier]
        }
        let captureBundleIdentifiers = Self.audioCaptureBundleIdentifiers(
            sourceBundleIdentifier: payload.bundleIdentifier,
            fallbackBundleIdentifiers: captureBundleFallbackIdentifiers
        )

        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)

        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            newPlaybackState.artwork = nil
        } else {
            newPlaybackState.artwork = self.playbackState.artwork
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        // Sometimes a pause or play comes only as the new rate (YouTube Music in Safari).
        newPlaybackState.isPlaying = payload.playing ?? payload.playbackRate.map { $0 > 0 } ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = resolvedBundleIdentifier
        newPlaybackState.audioCaptureBundleIdentifiers = captureBundleIdentifiers

        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)

        self.playbackState = newPlaybackState
    }

    private func fetchFavoriteStateIfSupported() async {
        // Only for a Favorite button (off by default): asking Music otherwise prompts a new Mac at launch.
        guard playbackState.bundleIdentifier == MediaAppBundleID.appleMusic,
              Defaults[.musicControlSlots].contains(.favorite) else { return }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application "Music"
            try
                return favorited of current track
            on error
                return false
            end try
        end tell
        """
        if let result = try? await AppleScriptHelper.execute(script) {
            var updated = playbackState
            updated.isFavorite = result.booleanValue
            playbackState = updated
        }
    }
}

private extension NowPlayingController {
    static func audioCaptureBundleIdentifiers(
        sourceBundleIdentifier: String?,
        fallbackBundleIdentifiers: [String]
    ) -> [String] {
        let preferred = sourceBundleIdentifier.map { [$0] } ?? fallbackBundleIdentifiers
        return preferred.normalizedBundleIdentifiers
    }
}

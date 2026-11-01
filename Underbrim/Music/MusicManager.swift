//
//  MusicManager.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

/// Artwork placeholder: a dark tile with a music note, the usual "nothing playing" look.
let defaultImage: NSImage = {
    let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
        NSGradient(starting: NSColor(white: 0.24, alpha: 1), ending: NSColor(white: 0.15, alpha: 1))?
            .draw(in: rect, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: 100, weight: .medium)
            .applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.45)]))
        if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = note.size
            note.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                 width: size.width, height: size.height))
        }
        return true
    }
    image.accessibilityDescription = String(localized: "No artwork")
    return image
}()

@MainActor
final class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private static let noticeDuration: Duration = .seconds(6)
    private static let runtimeRecoveryDelay: Duration = .seconds(1)
    private static let maxRuntimeRecoveryDelay: Duration = .seconds(60)

    private var controllerCancellables = Set<AnyCancellable>()
    private var averageColorTask: Task<Void, Never>?
    private var debounceIdleTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var runtimeFailureTask: Task<Void, Never>?
    private var runtimeRecoveryTask: Task<Void, Never>?
    private var runtimeRecoveryAttempts = 0
    /// When the current stream started: one that ran 30 s or more restarts at 1 s when it drops.
    private var runtimeStartedAt = Date.distantPast
    private var noticeDismissalTask: Task<Void, Never>?
    private var isDestroyed = false
    private var lastNoticedFailure: NowPlayingFailure?

    // Helper to check if macOS can use NowPlayingController
    @Published private(set) var preferredMediaController: MediaControllerType
    @Published private(set) var nowPlayingAvailability: NowPlayingAvailability = .unchecked
    @Published private(set) var effectiveMediaController: MediaControllerType?
    @Published private(set) var nowPlayingNotice: NowPlayingFallbackNotice?

    // Active controller
    private(set) var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = ""
    @Published var isPlayerIdle: Bool = true
    var hasTrack: Bool { !songTitle.isEmpty }
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String?
    @Published var audioCaptureBundleIdentifiers: [String] = []
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @Published var usingAppIconForArtwork: Bool = false
    @Published var canFavoriteTrack: Bool = false
    @Published var canShuffleAndRepeat: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data?

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = ""
    private var lastArtworkArtist: String = ""
    private var lastArtworkAlbum: String = ""
    private var lastArtworkBundleIdentifier: String?

    // MARK: - Initialization
    init() {
        Self.migrateMediaControllerPreferenceIfNeeded()
        preferredMediaController = Defaults[.mediaController]

        if preferredMediaController == .nowPlaying {
            // No stand-in while it's checked: Apple Music's would ask a new Mac to let Underbrim control
            // Music before the check finished. A failed check still falls back (startAvailabilityCheck).
            ensureNowPlayingAvailabilityChecked()
        } else {
            activateControllerIfNeeded(preferredMediaController)
        }
    }

    private static func migrateMediaControllerPreferenceIfNeeded() {
        guard !Defaults[.didMigrateMediaControllerChoice] else { return }

        let firstLaunch = Defaults[.firstLaunch]
        // What's stored, not the default Defaults registers once the key is first used.
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let hasStoredController = stored[Defaults.Keys.mediaController.name] != nil
        Defaults[.didChooseMediaController] = Defaults[.didChooseMediaController]
            || hasStoredController
            || !firstLaunch
        Defaults[.didMigrateMediaControllerChoice] = true
    }

    deinit {
        debounceIdleTask?.cancel()
        availabilityTask?.cancel()
        runtimeFailureTask?.cancel()
        runtimeRecoveryTask?.cancel()
        noticeDismissalTask?.cancel()
        controllerCancellables.removeAll()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true

        debounceIdleTask?.cancel()
        availabilityTask?.cancel()
        runtimeFailureTask?.cancel()
        runtimeRecoveryTask?.cancel()
        noticeDismissalTask?.cancel()
        availabilityTask = nil
        runtimeFailureTask = nil
        runtimeRecoveryTask = nil
        runtimeRecoveryAttempts = 0
        noticeDismissalTask = nil
        controllerCancellables.removeAll()
        (activeController as? any NowPlayingRuntimeControlling)?.stopRuntimeStream()

        activeController = nil
        effectiveMediaController = nil
        nowPlayingNotice = nil
    }

    func selectMediaController(_ type: MediaControllerType) {
        guard !isDestroyed else { return }

        Defaults[.mediaController] = type
        Defaults[.didChooseMediaController] = true
        preferredMediaController = type
        cancelRuntimeRecovery()
        clearNotice()

        if type == .nowPlaying {
            if nowPlayingAvailability == .available {
                activateControllerIfNeeded(.nowPlaying)
            } else {
                activateFallback()
                refreshNowPlayingAvailability()
            }
        } else {
            activateControllerIfNeeded(type)
        }
    }

    /// What stands in while Now Playing is down: the app last played through it when Underbrim has its
    /// own controller for it; otherwise nothing (an Apple Music remote would only open Music for someone
    /// watching videos), except for missing components, when Now Playing won't come back.
    private func resolvedNowPlayingFallback(after failure: NowPlayingFailure?) -> MediaControllerType? {
        if let bundleIdentifier = Defaults[.lastSupportedNowPlayingBundleIdentifier],
           let controller = MediaControllerType(nowPlayingBundleIdentifier: bundleIdentifier) {
            return controller
        }
        return failure == .setup ? .appleMusic : nil
    }

    func ensureNowPlayingAvailabilityChecked() {
        guard nowPlayingAvailability == .unchecked else { return }
        startAvailabilityCheck()
    }

    func refreshNowPlayingAvailability() {
        cancelRuntimeRecovery()
        startAvailabilityCheck()
    }

    private func startAvailabilityCheck() {
        guard !isDestroyed, availabilityTask == nil else { return }

        nowPlayingAvailability = .checking
        availabilityTask = Task { @MainActor [weak self] in
            let availability: NowPlayingAvailability
            do {
                availability = try await MediaChecker().checkAvailability(maxAttempts: 3)
            } catch is CancellationError {
                return
            } catch {
                availability = .unavailable(.probe)
            }

            guard let self, !self.isDestroyed else { return }
            self.availabilityTask = nil
            self.nowPlayingAvailability = availability

            if availability == .available {
                self.clearNotice()
                if self.preferredMediaController == .nowPlaying {
                    self.activateControllerIfNeeded(.nowPlaying)
                }
            } else if self.preferredMediaController == .nowPlaying,
                      let failure = availability.failure {
                self.activateFallback(after: failure)
                if failure == .probe { self.scheduleRecovery() }
            }
        }
    }

    private func activateFallback(after failure: NowPlayingFailure? = nil) {
        guard let fallbackController = resolvedNowPlayingFallback(after: failure) else {
            deactivateController()
            return
        }

        if let failure, Defaults[.didChooseMediaController] {
            requestNotice(fallbackController: fallbackController, failure: failure)
        }

        activateControllerIfNeeded(fallbackController)
    }

    private func requestNotice(
        fallbackController: MediaControllerType,
        failure: NowPlayingFailure
    ) {
        guard lastNoticedFailure != failure else { return }
        lastNoticedFailure = failure

        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        nowPlayingNotice = NowPlayingFallbackNotice(
            fallbackSource: fallbackController,
            failure: failure
        )
    }

    @discardableResult
    func markNowPlayingNoticePresented(_ noticeID: UUID) -> Bool {
        guard nowPlayingNotice?.id == noticeID,
              noticeDismissalTask == nil
        else {
            return false
        }

        noticeDismissalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: Self.noticeDuration)
            } catch {
                return
            }
            guard self.nowPlayingNotice?.id == noticeID else { return }
            self.nowPlayingNotice = nil
            self.noticeDismissalTask = nil
        }
        return true
    }

    private func clearNotice() {
        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        nowPlayingNotice = nil
        lastNoticedFailure = nil
    }

    private func activateControllerIfNeeded(_ type: MediaControllerType) {
        guard !isDestroyed,
              activeController == nil || effectiveMediaController != type
        else {
            return
        }

        do {
            let controller = try makeController(for: type)
            activateController(controller, type: type)
        } catch {
            if type == .nowPlaying {
                let failure = NowPlayingFailure.setup
                nowPlayingAvailability = .unavailable(failure)
                activateFallback(after: failure)
                return
            }

            guard type != .appleMusic else { return }
            activateController(AppleMusicController(), type: .appleMusic)
        }
    }

    private func makeController(
        for type: MediaControllerType
    ) throws -> any MediaControllerProtocol {
        switch type {
        case .nowPlaying:
            try NowPlayingController()
        case .appleMusic:
            AppleMusicController()
        case .spotify:
            SpotifyController()
        case .youtubeMusic:
            YouTubeMusicController()
        }
    }

    private func deactivateController() {
        runtimeFailureTask?.cancel()
        runtimeFailureTask = nil
        (activeController as? any NowPlayingRuntimeControlling)?.stopRuntimeStream()
        controllerCancellables.removeAll()

        if activeController != nil {
            resetPublishedPlaybackState()
        }
        activeController = nil
        effectiveMediaController = nil
    }

    private func activateController(
        _ controller: any MediaControllerProtocol,
        type: MediaControllerType
    ) {
        deactivateController()
        activeController = controller
        effectiveMediaController = type
        canFavoriteTrack = controller.supportsFavorite
        canShuffleAndRepeat = controller.supportsShuffleAndRepeat
        volumeControlSupported = controller.supportsVolumeControl

        controller.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, controller] state in
                guard let self,
                      self.activeController === controller,
                      state.lastUpdated != .distantPast
                else {
                    return
                }
                self.updateFromPlaybackState(state)
            }
            .store(in: &controllerCancellables)

        if let runtimeController = controller as? any NowPlayingRuntimeControlling {
            runtimeFailureTask = Task { @MainActor [weak self, runtimeController] in
                for await _ in runtimeController.runtimeFailures {
                    guard let self else { return }
                    self.handleRuntimeFailure(from: runtimeController)
                }
            }
        }

        forceUpdate()
        if let runtimeController = controller as? any NowPlayingRuntimeControlling {
            runtimeStartedAt = .now
            runtimeController.startRuntimeStream()
        }
    }

    private func resetPublishedPlaybackState() {
        debounceIdleTask?.cancel()
        debounceIdleTask = nil

        songTitle = ""
        artistName = ""
        album = ""
        albumArt = defaultImage
        isPlaying = false
        isPlayerIdle = true
        avgColor = .white
        bundleIdentifier = nil
        audioCaptureBundleIdentifiers = []
        songDuration = 0
        elapsedTime = 0
        timestampDate = Date()
        playbackRate = 1
        isShuffled = false
        repeatMode = .off
        volume = 0.5
        usingAppIconForArtwork = false
        isFavoriteTrack = false

        artworkData = nil
        lastArtworkTitle = ""
        lastArtworkArtist = ""
        lastArtworkAlbum = ""
        lastArtworkBundleIdentifier = nil
    }

    private func handleRuntimeFailure(from controller: any NowPlayingRuntimeControlling) {
        guard activeController === controller,
              effectiveMediaController == .nowPlaying,
              preferredMediaController == .nowPlaying
        else {
            return
        }

        NSLog("Now Playing runtime stream failed; reconnecting")
        let failure = NowPlayingFailure.runtime
        nowPlayingAvailability = .unavailable(failure)
        if Date.now.timeIntervalSince(runtimeStartedAt) >= 30 { runtimeRecoveryAttempts = 0 }
        activateFallback(after: failure)
        scheduleRecovery()
    }

    /// Checks Now Playing again after 1 s, 2, 4… up to a minute, so a dying stream can't spawn a process a second.
    private func scheduleRecovery() {
        cancelRuntimeRecovery()
        let delay = min(Self.runtimeRecoveryDelay * (1 << min(runtimeRecoveryAttempts, 6)), Self.maxRuntimeRecoveryDelay)
        runtimeRecoveryAttempts += 1
        runtimeRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self,
                  !self.isDestroyed,
                  self.preferredMediaController == .nowPlaying
            else {
                return
            }

            self.runtimeRecoveryTask = nil
            self.startAvailabilityCheck()
        }
    }

    private func cancelRuntimeRecovery() {
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = nil
    }

    // MARK: - Update Methods
    private func updateFromPlaybackState(_ state: PlaybackState) {
        guard state.lastUpdated != .distantPast else { return }

        if effectiveMediaController == .nowPlaying,
           MediaControllerType(nowPlayingBundleIdentifier: state.bundleIdentifier) != nil,
           Defaults[.lastSupportedNowPlayingBundleIdentifier] != state.bundleIdentifier {
            Defaults[.lastSupportedNowPlayingBundleIdentifier] = state.bundleIdentifier
        }

        // Check for playback state changes (playing/paused)
        let playingStateChanged = state.isPlaying != self.isPlaying
        if playingStateChanged {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = appIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                } else {
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: defaultImage)
                }
            }
            self.artworkData = state.artwork

            // On every change, not only with new artwork: a track with the same artwork bytes (same album)
            // re-peeked on each later event. Later artwork is still caught by artworkChanged.
            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume

        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }

        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        // Nothing playing comes as "", which is no source.
        let source = state.bundleIdentifier.isEmpty ? nil : state.bundleIdentifier
        if let source { lastPlayedBundleIdentifier = source }
        if source != self.bundleIdentifier {
            self.bundleIdentifier = source
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
            self.canFavoriteTrack = activeController?.supportsFavorite ?? false
            self.canShuffleAndRepeat = activeController?.supportsShuffleAndRepeat ?? false
        }

        let captureBundleIDs = state.effectiveAudioCaptureBundleIdentifiers
        if captureBundleIDs != self.audioCaptureBundleIdentifiers {
            self.audioCaptureBundleIdentifiers = captureBundleIDs
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }

        if volumeChanged {
            self.volume = state.volume
        }

        // The slider extrapolates from (elapsedTime, timestampDate); only
        // republish when an extrapolation input actually changed — otherwise
        // every no-op stream event invalidates the whole view tree. A pause/
        // resume must rebase it too, or the estimate overshoots by the pause
        // duration.
        if timeChanged || playbackRateChanged || playingStateChanged {
            self.timestampDate = state.lastUpdated
        }
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.artworkData == artworkData else { return }
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    func updateAlbumArt(newAlbumArt: NSImage) {
        averageColorTask?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        min(position(at: date), songDuration)
    }

    /// Where playback has got to, with no end to stop at: a live stream (no length) is past 0:00.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsedTime }
        return max(0, elapsedTime + date.timeIntervalSince(timestampDate) * playbackRate)
    }

    func calculateAverageColor() {
        let artwork = albumArt
        averageColorTask = Task { [weak self, artwork] in
            let color = await artwork.averageColor()
            guard !Task.isCancelled,
                  let self,
                  self.albumArt === artwork else {
                return
            }

            withAnimation(.smooth) {
                self.avgColor = color ?? .white
            }
        }
    }

    private func updateSneakPeek() {
        guard isPlaying && Defaults[.enableSneakPeek] else { return }
        if Defaults[.sneakPeekStyles] == .standard {
            NotchUIEventBus.events.send(.sneakPeek(type: .music, value: 0))
        } else {
            NotchUIEventBus.events.send(.expandingView(type: .music))
        }
    }

    /// The last app that played since launch, browsers too (Now Playing).
    private var lastPlayedBundleIdentifier: String?

    /// The app the artwork opens: the one playing, else the source chosen in Settings › Media or the
    /// last one played; nil when none is installed, so the artwork doesn't react.
    var appToOpen: String? {
        if let bundleIdentifier { return bundleIdentifier }
        let source: String? = switch effectiveMediaController {
        case .appleMusic: MediaAppBundleID.appleMusic
        case .spotify: MediaAppBundleID.spotify
        case .youtubeMusic: MediaAppBundleID.youTubeMusic
        case .nowPlaying: lastPlayedBundleIdentifier ?? Defaults[.lastSupportedNowPlayingBundleIdentifier]
        case .none: nil
        }
        return source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil ? nil : $0 }
    }

    func openMusicApp() {
        guard let bundleID = appToOpen else { return }
        AppInfo.activate(bundleID)
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
}

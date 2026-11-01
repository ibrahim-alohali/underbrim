//
//  MediaControllerProtocol.swift
//  Underbrim
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine

@MainActor
protocol MediaControllerProtocol: AnyObject {
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var supportsVolumeControl: Bool { get }
    var supportsFavorite: Bool { get }
    /// Whether shuffle and repeat reach the playing app; where they don't, the player doesn't show them.
    var supportsShuffleAndRepeat: Bool { get }

    func setFavorite(_ favorite: Bool) async
    func play() async
    func pause() async
    func seek(to time: Double) async
    func nextTrack() async
    func previousTrack() async
    func togglePlay() async
    func toggleShuffle() async
    func toggleRepeat() async
    func setVolume(_ level: Double) async
    func isActive() -> Bool
    func updatePlaybackInfo() async
}

@MainActor
protocol NowPlayingRuntimeControlling: MediaControllerProtocol {
    var runtimeFailures: AsyncStream<Void> { get }

    func startRuntimeStream()
    func stopRuntimeStream()
}

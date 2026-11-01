//
//  MusicManager+Transport.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//

import AppKit

/// Playback controls, sent to the active controller.
extension MusicManager {
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }

    /// Pause while playing, Play while paused: a toggle flips twice when a page pauses late (YouTube, up
    /// to 1.7 s) and the button is pressed again; some players take no toggle at all.
    func togglePlay() {
        let playing = isPlaying
        Task {
            if playing { await activeController?.pause() } else { await activeController?.play() }
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    /// From where the song is now (the last report could be minutes old); a live stream has no end at 0:00.
    func skip(seconds: TimeInterval) {
        let newPos = max(0, position(at: Date()) + seconds)
        seek(to: songDuration > 0 ? min(newPos, songDuration) : newPos)
    }

    /// The player's buttons less those the playing app can't take. A video in a browser (no album) rarely
    /// has next or previous, so it gets −15 s / +15 s, as Control Center shows, unless the layout has them.
    func available(_ slots: [MusicControlButton]) -> [MusicControlButton] {
        let webVideo = album.isEmpty && bundleIdentifier.map(Self.browsers.contains) == true
        return slots.compactMap { slot in
            switch slot {
            case .shuffle, .repeatMode: canShuffleAndRepeat ? slot : nil
            case .favorite: canFavoriteTrack ? slot : nil
            case .previous where webVideo: slots.contains(.goBackward) ? nil : .goBackward
            case .next where webVideo: slots.contains(.goForward) ? nil : .goForward
            default: slot
            }
        }
    }

    private static let browsers = Set(
        NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!).compactMap { Bundle(url: $0)?.bundleIdentifier }
    )

    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }
}

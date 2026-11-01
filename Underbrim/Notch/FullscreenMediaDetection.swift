//
//  FullscreenMediaDetection.swift
//  Underbrim
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]
    /// Displays showing any full-screen Space, whatever the hide setting (a pinned island lets go there).
    @Published var anyFullscreen: Set<String> = []

    private var monitorTask: Task<Void, Never>?
    /// The last full-screen Spaces seen: the decision is made again when the
    /// playing app or the setting changes, not only on a Space change.
    private var lastSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        startMonitoring()
        // Underbrim: playback that starts after entering full screen counts too.
        // The app is the one sent: $bundleIdentifier sends before the property
        // changes, so reading it here would give the previous app.
        MusicManager.shared.$bundleIdentifier.removeDuplicates()
            .merge(with: Defaults.publisher(.hideNotchOption).map { _ in MusicManager.shared.bundleIdentifier })
            .dropFirst()
            .sink { [weak self] playing in
                guard let self else { return }
                self.updateStatus(with: self.lastSpaces, playing: playing)
            }
            .store(in: &cancellables)
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                updateStatus(with: spaces)
            }
        }
    }

    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo],
                              playing: String? = MusicManager.shared.bundleIdentifier) {
        lastSpaces = spaces
        var newStatus: [String: Bool] = [:]

        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if Defaults[.hideNotchOption] == .nowPlayingOnly {
                    // Underbrim: only for the media app's own space; with nothing playing, for none.
                    shouldDetect = playing.map { space.runningApps.contains($0) } ?? false
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }

        if fullscreenStatus != newStatus { fullscreenStatus = newStatus }
        let screens = Set(spaces.compactMap(\.screenUUID))
        if anyFullscreen != screens { anyFullscreen = screens }
    }
}

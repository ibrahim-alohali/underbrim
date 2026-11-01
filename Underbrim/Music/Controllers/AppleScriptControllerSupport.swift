//
//  AppleScriptControllerSupport.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Shared scaffolding for AppleScript-driven media controllers.
//

import Foundation

/// The "tell application X to command" shape and distributed player-info
/// observation that AppleMusicController and SpotifyController previously
/// copy-pasted between each other.
enum AppleScriptControllerSupport {
    static func executeCommand(_ command: String, appName: String) async {
        await AppleScriptHelper.run("tell application \"\(appName)\" to \(command)")
    }

    /// Streams player-info notifications from DistributedNotificationCenter
    /// and cancels the underlying observer when the stream terminates.
    static func playerInfoNotifications(named name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observerTask = Task {
                let notifications = DistributedNotificationCenter.default().notifications(
                    named: NSNotification.Name(name)
                )
                for await _ in notifications {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in observerTask.cancel() }
        }
    }
}

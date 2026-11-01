//
//  AppleScriptHelper.swift
//  Underbrim
//
//  Created by Alexander on 2025-03-29.
//

import AppKit

final class AppleScriptHelper {
    @discardableResult
    class func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: scriptText)
                var error: NSDictionary?
                if let descriptor = script?.executeAndReturnError(&error) {
                    continuation.resume(returning: descriptor)
                } else if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }

    /// A command the user gave: a refusal (Automation off for Underbrim) beeps rather than nothing, at most
    /// once a second, as a dragged slider sends many.
    class func run(_ scriptText: String) async {
        do { try await execute(scriptText) } catch { await refused() }
    }

    @MainActor private static var lastRefusal = Date.distantPast
    @MainActor private static func refused() {
        guard Date().timeIntervalSince(lastRefusal) > 1 else { return }
        lastRefusal = Date()
        NSSound.beep()
    }
}

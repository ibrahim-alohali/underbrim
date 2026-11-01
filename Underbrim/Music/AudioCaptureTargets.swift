//
//  AudioCaptureTargets.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Darwin

/// Which running processes the waveform's audio is captured from.
enum AudioCaptureTargets {
    /// The processes to capture: the shown app's and those of the apps named as its audio's source
    /// (tied to the shown app when several of one run); the shown app's own when none qualify.
    static func pids(displayBundleID: String, captureBundleIDs: [String]) -> [pid_t] {
        let displayApps = NSRunningApplication.runningApplications(withBundleIdentifier: displayBundleID)
        let displayNames = Set(displayApps.compactMap(\.localizedName))
        let displayBundlePaths = Set(displayApps.compactMap(displayBundlePath(for:)))

        let bundleIDs = Array(
            Set(captureBundleIDs + [displayBundleID])
        ).sorted()

        var pids = Set<pid_t>()
        for bundleID in bundleIDs {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let requireDisplayAppTie = bundleID != displayBundleID && runningApps.count > 1
            for app in runningApps {
                guard shouldInclude(
                    app: app,
                    requireDisplayAppTie: requireDisplayAppTie,
                    displayNames: displayNames,
                    displayBundlePaths: displayBundlePaths
                ) else { continue }
                pids.insert(app.processIdentifier)
            }
        }

        if pids.isEmpty {
            return NSRunningApplication
                .runningApplications(withBundleIdentifier: displayBundleID)
                .map(\.processIdentifier)
                .sorted()
        }

        return pids.sorted()
    }

    private static func shouldInclude(
        app: NSRunningApplication,
        requireDisplayAppTie: Bool,
        displayNames: Set<String>,
        displayBundlePaths: Set<String>
    ) -> Bool {
        guard requireDisplayAppTie else { return true }
        if belongsToDisplayApplication(app, displayBundlePaths: displayBundlePaths) {
            return true
        }
        guard let localizedName = app.localizedName, !displayNames.isEmpty else { return false }
        return displayNames.contains { localizedName.localizedCaseInsensitiveContains($0) }
    }

    private static func belongsToDisplayApplication(
        _ app: NSRunningApplication,
        displayBundlePaths: Set<String>
    ) -> Bool {
        guard !displayBundlePaths.isEmpty else { return false }

        if let bundlePath = displayBundlePath(for: app),
           displayBundlePaths.contains(where: { pathContainsApp($0, candidatePath: bundlePath) }) {
            return true
        }

        guard let executablePath = executablePath(forPID: app.processIdentifier) else { return false }
        return displayBundlePaths.contains { pathContainsApp($0, candidatePath: executablePath) }
    }

    private static func displayBundlePath(for app: NSRunningApplication) -> String? {
        if let bundlePath = app.bundleURL?.standardizedFileURL.path {
            return bundlePath
        }
        guard let executablePath = executablePath(forPID: app.processIdentifier) else { return nil }
        return outermostAppBundlePath(containing: executablePath)
    }

    private static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private static func outermostAppBundlePath(containing executablePath: String) -> String? {
        let normalizedPath = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        let components = normalizedPath.split(separator: "/")
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...appIndex].joined(separator: "/")
    }

    private static func pathContainsApp(_ appPath: String, candidatePath: String) -> Bool {
        let normalizedAppPath = URL(fileURLWithPath: appPath).standardizedFileURL.path
        let normalizedCandidatePath = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        return normalizedCandidatePath == normalizedAppPath
            || normalizedCandidatePath.hasPrefix(normalizedAppPath + "/")
    }
}

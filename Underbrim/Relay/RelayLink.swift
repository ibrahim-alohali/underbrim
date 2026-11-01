//
//  RelayLink.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The helper the agents' hooks and Chrome run, at a path that never changes when the app moves
//  or updates: a symlink into an installed copy's bundle, refreshed at launch.
//

import Foundation

enum RelayLink {
    /// The helper's name: hook entries that run it are Underbrim's, so installing replaces old ones
    /// and removing removes them.
    static let helperName = "underbrim-relay"

    /// The symlink, so the hook command (which Codex pins its approval to) stays byte-identical.
    static var stablePath: String {
        Relay.supportDirectory.appendingPathComponent("bin/\(helperName)").path
    }

    /// Points the stable path at this bundle's helper, only from an installed copy: the agents and
    /// Chrome run its target, so it must never point into a disk image or Downloads. Throws when the
    /// agents and Chrome have no helper to run.
    static func refresh() throws(RelayLinkError) {
        let fm = FileManager.default
        let link = URL(fileURLWithPath: stablePath)
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard isInstalledLocation(app) else {
            let target = try? fm.destinationOfSymbolicLink(atPath: link.path)
            // One an older version pointed into a disk image or a download goes.
            if let target, !isInstalledLocation(target) {
                try? fm.removeItem(at: link)
            }
            // An installed copy's helper reaches this copy's listener just as well.
            guard let target, isInstalledLocation(target), fm.isExecutableFile(atPath: target) else {
                throw .notInstalledLocation
            }
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)")
        guard fm.isExecutableFile(atPath: helper.path) else { throw .helperMissing }
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == helper.path { return }
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: helper)
        } catch {
            throw .linkFailed(error.localizedDescription)
        }
    }

    /// /Applications or ~/Applications. A translocated copy runs from a
    /// temporary folder, so it never matches.
    static func isInstalledLocation(_ appPath: String) -> Bool {
        appPath.hasPrefix("/Applications/") || appPath.hasPrefix(Relay.homeDirectory + "/Applications/")
    }
}

/// Why the stable relay path has no helper behind it.
enum RelayLinkError: Error, Equatable {
    /// This copy runs from outside the Applications folders and no installed copy's helper is linked.
    case notInstalledLocation
    /// The bundle has no relay helper.
    case helperMissing
    case linkFailed(String)
}

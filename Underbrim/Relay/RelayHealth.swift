//
//  RelayHealth.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Whether the agents' hooks and the Chrome extension can reach this app: the helper
//  they run is linked, and the app is listening. Found where both are set up
//  (RelayListener.check), shown in Settings, and checked before anything that relies on
//  the relay is installed.
//

import Darwin
import Foundation

enum RelayHealth: Equatable {
    case ready
    case link(RelayLinkError)
    case listener(RelayServer.StartError)

    /// What to tell the user; nil when the relay works.
    var problem: String? {
        switch self {
        case .ready:
            return nil
        case .link(.notInstalledLocation):
            return String(localized: "Agents and Chrome can't reach this copy of Underbrim. Move it to the Applications folder and open it from there.")
        case .link(.helperMissing):
            return String(localized: "This copy of Underbrim is missing the helper that agents and Chrome run. Install it again from the disk image.")
        case .link(.linkFailed(let reason)):
            return String(localized: "Underbrim couldn't set up the helper that agents and Chrome run (\(reason)).")
        case .listener(.alreadyRunning):
            return String(localized: "Another copy of Underbrim is receiving the agents' and Chrome's updates. Quit it to use this one.")
        case .listener(let error):
            return String(localized: "Underbrim couldn't start receiving the agents' and Chrome's updates (\(Self.detail(error))).")
        }
    }

    private static func detail(_ error: RelayServer.StartError) -> String {
        switch error {
        case .directory(let reason): reason
        case .pathOccupied, .alreadyRunning: Relay.socketPath
        case .socket(let code): String(cString: strerror(code))
        }
    }
}

//
//  ChromeIntegration.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Registers (and removes) the Chrome native-messaging host, and copies the bundled extension
//  somewhere stable for "Load unpacked". Only our own manifest file is ever written or deleted.
//

import AppKit
import Foundation

enum ChromeIntegration {
    /// Chrome allows lowercase letters, digits, dots and underscores only.
    static let hostName = "io.github.ibrahim_alohali.underbrim"

    static var manifestURL: URL {
        URL(fileURLWithPath: Relay.homeDirectory)
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(hostName).json")
    }

    /// Stable copy of the extension (Chrome remembers the folder it was loaded from).
    static var extensionCopyURL: URL {
        Relay.supportDirectory.appendingPathComponent("chrome-extension", isDirectory: true)
    }

    static var chromeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
    }

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Our manifest points somewhere else, or the extension copy differs from this build's.
        case outdated
    }

    static func manifestData() -> Data {
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Underbrim download status",
            "path": RelayLink.stablePath,
            "type": "stdio",
            "allowed_origins": Array(Relay.allowedChromeOrigins).sorted(),
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func status() -> Status {
        guard let data = try? Data(contentsOf: manifestURL) else { return .notInstalled }
        guard data == manifestData() else { return .outdated }
        guard let source = Bundle.main.url(forResource: "chrome-extension", withExtension: nil) else { return .installed }
        return FileManager.default.contentsEqual(atPath: source.path, andPath: extensionCopyURL.path) ? .installed : .outdated
    }

    static func install() throws {
        if Relay.isPreviewCopy { throw HookInstaller.InstallError.previewCopy }
        let fm = FileManager.default
        try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifestData().write(to: manifestURL, options: .atomic)
        if let source = Bundle.main.url(forResource: "chrome-extension", withExtension: nil) {
            Relay.removeOwnItem(at: extensionCopyURL)
            try fm.copyItem(at: source, to: extensionCopyURL)
        }
    }

    static func uninstall() {
        guard !Relay.isPreviewCopy else { return }
        try? FileManager.default.removeItem(at: manifestURL)
        Relay.removeOwnItem(at: extensionCopyURL)
    }

    /// Opens the extensions page and shows the folder to choose in "Load unpacked".
    static func revealExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([extensionCopyURL])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
           let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

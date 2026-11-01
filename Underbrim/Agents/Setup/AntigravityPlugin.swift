//
//  AntigravityPlugin.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Antigravity reads hooks from plugin folders under ~/.gemini/config/plugins. Ours
//  is a folder of its own, written whole and removed only while it holds just our
//  two files. Its hooks report progress and print nothing; approvals stay there.
//

import Foundation

struct AntigravityPlugin: HookAgentSetup {
    static let name = "underbrim"
    static let events = ["PreInvocation", "PostToolUse", "Stop"]

    let folder: URL
    let relayPath: String

    init() {
        folder = URL(fileURLWithPath: Relay.homeDirectory).appendingPathComponent(".gemini/config/plugins/\(Self.name)", isDirectory: true)
        relayPath = RelayLink.stablePath
    }

    private var manifestURL: URL { folder.appendingPathComponent("plugin.json") }
    private var hooksURL: URL { folder.appendingPathComponent("hooks.json") }

    func command(for event: String) -> String {
        HookInstaller.hookCommand(relayPath: relayPath, verb: "hook", agent: .antigravity, arguments: [event])
    }

    var manifest: OrderedJSON {
        .object([
            .init(key: "name", value: .string(Self.name)),
            .init(key: "displayName", value: .string("Underbrim")),
            .init(key: "description", value: .string("Shows Antigravity's sessions in Underbrim's notch.")),
            .init(key: "version", value: .string("1.0.0")),
        ])
    }

    var hooks: OrderedJSON {
        var members: [OrderedJSON.Member] = [.init(key: "enabled", value: .bool(true))]
        for event in Self.events {
            let handler: OrderedJSON = .object([
                .init(key: "command", value: .string(command(for: event))),
                .init(key: "timeout", value: .number("5")),
                .init(key: "type", value: .string("command")),
            ])
            // Tool events take a matcher and a list of handlers; the others, handlers.
            let entry: OrderedJSON = event.hasSuffix("ToolUse")
                ? .object([.init(key: "matcher", value: .string("*")), .init(key: "hooks", value: .array([handler]))])
                : handler
            members.append(.init(key: event, value: .array([entry])))
        }
        return .object([.init(key: Self.name, value: .object(members))])
    }

    func status() -> HookInstaller.Status {
        guard FileManager.default.fileExists(atPath: folder.path) else { return .notInstalled }
        guard let manifestData = try? Data(contentsOf: manifestURL), let hooksData = try? Data(contentsOf: hooksURL),
              let manifest = try? OrderedJSON.parse(manifestData), let hooks = try? OrderedJSON.parse(hooksData)
        else { return .unreadable(String(localized: "not readable")) }
        return manifest == self.manifest && hooks == self.hooks ? .installed : .outdated
    }

    /// Its hooks report progress only: Antigravity asks for approvals in its own window.
    func answersInNotch() -> Bool { false }

    /// The folder is ours alone, so nothing is backed up.
    @discardableResult
    func install() throws -> URL? {
        if Relay.isPreviewCopy { throw HookInstaller.InstallError.previewCopy }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.serialized().write(to: manifestURL, options: .atomic)
        try hooks.serialized().write(to: hooksURL, options: .atomic)
        guard status() == .installed else { throw HookInstaller.InstallError.verificationFailed }
        return nil
    }

    @discardableResult
    func uninstall() throws -> URL? {
        if Relay.isPreviewCopy { throw HookInstaller.InstallError.previewCopy }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return nil }
        // Only a folder of ours: anything else in it is someone else's.
        let names = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        guard names.isSubset(of: ["plugin.json", "hooks.json", ".DS_Store"]) else {
            throw HookInstaller.InstallError.unreadable(String(localized: "other files in its folder"))
        }
        try fm.removeItem(at: folder)
        return nil
    }
}

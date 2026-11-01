//
//  RelayWire.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Shared by the app and `underbrim-relay`. The helper reduces provider JSON to
//  this allowlisted summary: no prompts, file contents or transcripts reach the
//  socket, except the bounded call a RelayRequest asks about.
//

import Darwin
import Foundation

/// One status event, as written to the app's socket (one JSON object per line).
struct RelayEvent: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v = RelayEvent.currentVersion
    /// "claude", "codex", "qwen", "qoder", "cursor", "antigravity" or "chrome".
    var provider: String
    var kind: String
    /// Session / thread id, or the browser download id.
    var session: String?
    /// Working directory, or a download's target path.
    var cwd: String?
    /// Tool name (e.g. "Bash") — never its input.
    var tool: String?
    /// One allowlisted token: a notification type, an end reason, a download state…
    var detail: String?
    /// Seconds since 1970 at the time the helper saw the event.
    var ts: Double
    /// Agent process id and start time (µs since 1970), for exit detection.
    var pid: Int32?
    var pidStart: UInt64?
    var host: String?
    /// A session title the user set (Claude `session_title`), sanitized.
    var title: String?
    /// How the agent was started, e.g. "claude-desktop", "cli", "sdk-ts".
    var entry: String?
    /// Claude Desktop's own session id ("local_…"), for its session deep link.
    var hostSession: String?
    var attended: Bool?
    /// Plan-usage windows (Claude status-line `rate_limits`).
    var windows: [RelayWindow]?
    /// kind "Request": something to answer; the helper waits on the connection.
    var request: RelayRequest?
    // Downloads only.
    var name: String?
    var received: Int64?
    /// Absent while Chrome doesn't know the size (a helper a version behind sends -1).
    var total: Int64?
}

/// A Chrome download's state, as `RelayEvent.detail`.
enum ChromeDownloadState: String, Sendable {
    case inProgress = "in_progress"
    case paused
    case complete
    case cancelled
    case failed
    /// Flagged by Chrome, waiting for the user's decision there.
    case dangerous
}

/// One plan-usage window: percent used (0–100) and when it resets.
struct RelayWindow: Codable, Equatable, Sendable {
    /// "five_hour", "seven_day", …
    var id: String
    var used: Double
    /// Unix seconds; nil when not reported.
    var resets: Double?
}

enum Relay {
    /// A first-run preview build (bundle id + `.preview`): keeps to its own folder.
    static let isPreviewCopy = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true
    /// Folder name under ~/Library/Application Support, shared with the app
    /// (short, so the socket path stays well inside its 104-byte limit).
    static let supportFolderName = isPreviewCopy ? "Underbrim Preview" : "Underbrim"
    static let socketName = "relay.sock"
    /// The bundled Chrome extension's id (from the public `key` in its manifest).
    static let chromeExtensionID = "fjfblodgeijoighojdggcokapljkjdof"
    static let allowedChromeOrigins: Set<String> = ["chrome-extension://\(chromeExtensionID)/"]
    /// Upper bound for one line: events are tiny, a request with a plan can take tens of KB.
    static let maxLineBytes = 128 * 1024

    /// The real home directory — not `$HOME`, which a hook's environment can change.
    static var homeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static var supportDirectory: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportFolderName, isDirectory: true)
    }

    /// Opens a folder of ours without following a link at any step from the support folder
    /// down (outside it, at the last step), so another program running as the user can't
    /// redirect our deletes to a protected folder.
    static func openOwnFolder(_ url: URL) -> Int32? {
        let top = supportDirectory.path
        let path = url.standardizedFileURL.path
        let steps = path.hasPrefix(top + "/") ? path.dropFirst(top.count + 1).split(separator: "/").map(String.init) : []
        var fd = open(steps.isEmpty ? path : top, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        for step in steps where fd >= 0 {
            let next = openat(fd, step, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            fd = next
        }
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid() else { close(fd); return nil }
        return fd
    }

    /// Removes the entries `pick` chooses from a folder of ours, relative to one open
    /// descriptor: a link swapped in for its path changes nothing, and links inside go
    /// themselves. A folder goes with its contents only when `recursive`.
    static func removeEntries(in folder: URL, recursive: Bool = false,
                              pick: ([(name: String, created: Date)]) -> Set<String>) {
        guard let fd = openOwnFolder(folder) else { return }
        defer { close(fd) }
        let found = entries(of: fd)
        let chosen = pick(found.map { ($0.name, $0.created) })
        for entry in found where chosen.contains(entry.name) {
            if entry.isFolder && recursive {
                removeTree(entry.name, in: fd)
            } else {
                _ = unlinkat(fd, entry.name, entry.isFolder ? AT_REMOVEDIR : 0)
            }
        }
    }

    static func removeOwnItem(at url: URL) {
        removeEntries(in: url.deletingLastPathComponent(), recursive: true) { _ in [url.lastPathComponent] }
    }

    private static func entries(of fd: Int32) -> [(name: String, created: Date, isFolder: Bool)] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let listing = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(listing) }
        rewinddir(listing)
        var entries: [(name: String, created: Date, isFolder: Bool)] = []
        while let entry = readdir(listing) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            var st = stat()
            guard name != ".", name != "..", fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            entries.append((name, Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)),
                            (st.st_mode & S_IFMT) == S_IFDIR))
        }
        return entries
    }

    /// Removes `name` in `parent` recursively, opening each level from the one above
    /// without following links (removefile walks by path, so a swapped link redirects it).
    private static func removeTree(_ name: String, in parent: Int32) {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { _ = unlinkat(parent, name, 0); return }  // now a link or a file: that goes itself
        for entry in entries(of: fd) {
            if entry.isFolder { removeTree(entry.name, in: fd) } else { _ = unlinkat(fd, entry.name, 0) }
        }
        close(fd)
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    static var socketPath: String {
        supportDirectory.appendingPathComponent(socketName).path
    }

    static func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    // MARK: Field hygiene

    /// A conservative charset, so nothing odd can ride along in an id field.
    static func identifier(_ value: Any?, maxLength: Int = 128) -> String? {
        guard let raw = value as? String, !raw.isEmpty, raw.count <= maxLength else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return raw
    }

    /// C0/C1 controls. (`CharacterSet.controlCharacters` also holds format characters such as
    /// the zero-width joiner, which emoji sequences and Persian text need.)
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    /// Characters that reorder the text around them (embeddings, overrides, isolates).
    static let bidiControls = CharacterSet(charactersIn: "\u{202A}"..."\u{202E}")
        .union(CharacterSet(charactersIn: "\u{2066}"..."\u{2069}"))
    /// The two of them that show letters in reverse ("fdp.exe" for "exe.pdf"); embeddings and
    /// isolates only set the direction of the text they group.
    static let directionOverrides = CharacterSet(charactersIn: "\u{202D}\u{202E}")

    static func path(_ value: Any?) -> String? {
        guard let raw = value as? String, raw.hasPrefix("/"), raw.utf8.count <= 1024,
              !raw.unicodeScalars.contains(where: isControl)
        else { return nil }
        return raw
    }

    /// Display file name: the last path component only, bounded, without the
    /// characters that reorder text (they can disguise a file's extension).
    static func fileName(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let last = (raw as NSString).lastPathComponent
        let name = String(String.UnicodeScalarView(last.unicodeScalars.filter { !bidiControls.contains($0) }))
        guard !name.isEmpty, name.utf8.count <= 255, !name.unicodeScalars.contains(where: isControl)
        else { return nil }
        return name
    }

    /// User-visible text in any script, without control characters or those in `reordering`, bounded.
    static func label(_ value: Any?, maxLength: Int = 120, removing reordering: CharacterSet = bidiControls) -> String? {
        guard let raw = value as? String else { return nil }
        var cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isControl($0) && !reordering.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength)) + "…" }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func token(_ value: Any?, allowed: Set<String>) -> String? {
        guard let raw = value as? String, allowed.contains(raw) else { return nil }
        return raw
    }

    static func desktopSessionID(_ value: String?) -> String? {
        guard let value, value.hasPrefix("local_"), let id = identifier(value, maxLength: 70),
              !id.contains("."), !id.contains(":") else { return nil }
        return id
    }

    static func encodeLine(_ event: RelayEvent) -> Data? {
        guard var data = try? JSONEncoder().encode(event), data.count < maxLineBytes else { return nil }
        data.append(0x0A)
        return data
    }
}

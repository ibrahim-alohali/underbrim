//
//  JSONLTail.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reading the agents' JSONL logs: the first line, and the lines added since the last read.
//

import Foundation

enum JSONLines {
    /// A file's first line (a Codex log's session record), read only as far as its end. A file not
    /// yet ending its first line gives what's there, so a record being written still counts once
    /// complete; past `limit` without a newline, nothing.
    static func firstLine(of url: URL, limit: Int = 1 << 20) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < limit, let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let end = chunk.firstIndex(of: 0x0A) { return line + chunk[..<end] }
            line += chunk
        }
        return line.isEmpty || line.count >= limit ? nil : line
    }
}

/// The lines appended to a JSONL file since the last read: starts near the end, keeps a
/// partial last line, and starts over when the file is replaced or truncated.
struct JSONLTail {
    /// How far back the first read reaches, and the most read in one go.
    static let window: UInt64 = 256 * 1024
    static let maxAppend: UInt64 = 8 << 20
    /// Longer lines (a pasted image, a huge tool result) are skipped.
    static let maxLine = 4 << 20

    private var offset: UInt64?
    private var inode: UInt64 = 0
    private var partial = Data()
    private var skippingToNewline = false

    mutating func read(_ url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return [] }
        let size = UInt64(info.st_size)
        if offset == nil || UInt64(info.st_ino) != inode || size < offset! || size - offset! > Self.maxAppend {
            // First read, replaced, truncated, or far behind: begin a window before the end.
            inode = UInt64(info.st_ino)
            partial = Data()
            offset = size > Self.window ? size - Self.window : 0
            skippingToNewline = offset! > 0
        }
        guard let start = offset, size > start else { return [] }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else { return [] }
        offset = start + UInt64(data.count)

        var lines: [Data] = []
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if skippingToNewline {
                skippingToNewline = false
            } else {
                let line = partial + data[lineStart..<newline]
                if !line.isEmpty, line.count <= Self.maxLine { lines.append(line) }
            }
            partial = Data()
            lineStart = data.index(after: newline)
        }
        if !skippingToNewline {
            partial.append(data[lineStart...])
            if partial.count > Self.maxLine { partial = Data(); skippingToNewline = true }
        }
        return lines
    }
}

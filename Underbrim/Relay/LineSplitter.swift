//
//  LineSplitter.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Splits a byte stream from another process into lines as chunks arrive. A sender
//  that never ends a line is caught at `maxLine` instead of filling memory.
//

import Foundation

struct LineSplitter {
    let maxLine: Int
    private var rest = Data()

    init(maxLine: Int) {
        self.maxLine = maxLine
    }

    /// The lines `chunk` completes, without their newlines.
    mutating func append(_ chunk: Data) -> [Data] {
        rest.append(chunk)
        var lines: [Data] = []
        while let newline = rest.firstIndex(of: 0x0A) {
            lines.append(Data(rest[rest.startIndex..<newline]))
            rest.removeSubrange(rest.startIndex...newline)
        }
        return lines
    }

    /// An unfinished line has grown past `maxLine`: the sender should be dropped.
    var overflowed: Bool { rest.count > maxLine }

    /// What's left once the stream ends: a last line sent without a newline.
    mutating func finish() -> Data? {
        defer { rest = Data() }
        return rest.isEmpty ? nil : rest
    }
}

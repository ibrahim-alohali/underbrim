//
//  OrderedJSON.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Order-preserving JSON for editing the user's agent config files: JSONSerialization
//  reorders keys, so a rewrite would reshuffle settings we don't own. Keeps key order
//  and number spelling, in the agents' own 2-space style.
//

import Foundation

indirect enum OrderedJSON: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// Kept as written, so `1.0` stays `1.0`.
    case number(String)
    case bool(Bool)
    case null

    struct ParseError: Error, Equatable {
        let offset: Int
    }

    // MARK: Access

    subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
            self = .object(members)
        }
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    // MARK: Parse

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            guard index < bytes.count else { throw ParseError(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                // Real settings nest a few levels. The limit keeps a damaged
                // file from using up the stack and crashing the app.
                guard depth < 512 else { throw ParseError(offset: index) }
                depth += 1
                defer { depth -= 1 }
                return bytes[index] == UInt8(ascii: "{") ? try object() : try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else {
                throw ParseError(offset: index)
            }
            index += w.count
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  Double(text) != nil else { throw ParseError(offset: start) }
            return .number(text)
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError(offset: index) }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError(offset: index) }
                index += 1
                skipWhitespace()
                members.append(Member(key: key, value: try value()))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw ParseError(offset: index)
            }
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array([]) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError(offset: index)
            }
        }

        mutating func string() throws -> String {
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw ParseError(offset: index) }
            index += 1
            // The slice is one complete string literal; Foundation decodes its escapes.
            guard let text = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String
            else { throw ParseError(offset: start) }
            return text
        }
    }

    // MARK: Serialize

    /// `JSON.stringify(value, null, 2)` style, plus a trailing newline.
    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        out += "\n"
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .string(let value): out += Self.quoted(value)
        case .number(let text): out += text
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

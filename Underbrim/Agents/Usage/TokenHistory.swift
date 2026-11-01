//
//  TokenHistory.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Tokens per day for two weeks, summed from logs the agents keep anyway: Claude Code's
//  transcripts (`message.usage`, once per message) and Codex's (`token_count.last_token_usage`).
//  Only counts, model and time are read from usage lines; a cache in Application Support
//  remembers how far each file was read. Tokens only: no prices.
//

import Foundation
import Observation

struct TokenDay: Codable, Equatable, Sendable {
    /// Read fresh (cache writes included).
    var input = 0
    var output = 0
    /// Read from the agent's prompt cache.
    var cached = 0
    var models: [String: Int] = [:]

    var total: Int { Self.sum(input, output, cached) }

    mutating func add(_ usage: TokenUsage) {
        input = Self.sum(input, usage.input)
        output = Self.sum(output, usage.output)
        cached = Self.sum(cached, usage.cached)
        if let model = usage.model { models[model] = Self.sum(models[model] ?? 0, usage.input, usage.output, usage.cached) }
    }

    mutating func add(_ day: TokenDay) {
        input = Self.sum(input, day.input)
        output = Self.sum(output, day.output)
        cached = Self.sum(cached, day.cached)
        for (model, count) in day.models { models[model] = Self.sum(models[model] ?? 0, count) }
    }

    /// Counts come from files on disk: a sum that would overflow stops at the largest count instead.
    private static func sum(_ counts: Int...) -> Int {
        counts.reduce(0) { total, count in
            let (result, overflow) = total.addingReportingOverflow(count)
            return overflow ? .max : result
        }
    }
}

struct TokenUsage: Equatable, Sendable {
    var id: String?
    var date: Date
    var model: String?
    var input: Int
    var output: Int
    var cached: Int
}

enum TokenLogs {
    /// Text every line with usage has, to pass over the rest without parsing them.
    static let claudeMarker = "\"output_tokens\""
    static let codexMarker = "\"token_count\""

    /// A Claude transcript line with a reply's usage. The same reply is written
    /// once per content block, with the same id: callers count an id once.
    static func claudeUsage(in line: Data) -> TokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: skim(line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let date = isoDate(object["timestamp"])
        else { return nil }
        func count(_ key: String) -> Int { tokens(usage[key]) }
        let model = Relay.identifier(message["model"], maxLength: 64).flatMap { $0 == "<synthetic>" ? nil : $0 }
        return TokenUsage(id: Relay.identifier(message["id"], maxLength: 96), date: date, model: model,
                          input: count("input_tokens") + count("cache_creation_input_tokens"),
                          output: count("output_tokens"), cached: count("cache_read_input_tokens"))
    }

    /// A Codex log line with a request's usage (its input includes the cached part).
    static func codexUsage(in line: Data) -> TokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any], let usage = info["last_token_usage"] as? [String: Any],
              let date = isoDate(object["timestamp"])
        else { return nil }
        func count(_ key: String) -> Int { tokens(usage[key]) }
        let cached = count("cached_input_tokens")
        return TokenUsage(id: nil, date: date, model: nil, input: max(0, count("input_tokens") - cached),
                          output: count("output_tokens"), cached: cached)
    }

    /// A count as written, or 0 when it can't be one: negative, or more than any reply could use.
    static func tokens(_ value: Any?) -> Int {
        guard let count = (value as? NSNumber)?.int64Value, (0...maxTokens).contains(count) else { return 0 }
        return Int(count)
    }

    static let maxTokens: Int64 = 100_000_000

    /// The line with every string longer than 256 bytes emptied: counts, ids, model and
    /// time are short, so they parse the same at a fraction of the work.
    static func skim(_ line: Data) -> Data {
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return line }
            let count = raw.count
            var out = Data(capacity: min(count, 8192))
            var copied = 0, index = 0
            while index < count, let quote = memchr(base + index, 0x22, count - index) {
                let open = base.distance(to: quote.assumingMemoryBound(to: UInt8.self))
                // The closing quote: the next one not escaped by an odd run of backslashes.
                var close = open + 1
                while true {
                    guard close < count, let next = memchr(base + close, 0x22, count - close) else { close = count; break }
                    close = base.distance(to: next.assumingMemoryBound(to: UInt8.self))
                    var slashes = 0
                    while base[close - 1 - slashes] == 0x5C { slashes += 1 }
                    if slashes % 2 == 0 { break }
                    close += 1
                }
                guard close < count else { break }
                if close - open - 1 > 256 {
                    out.append(base + copied, count: open + 1 - copied)
                    copied = close
                }
                index = close + 1
            }
            out.append(base + copied, count: count - copied)
            return out
        }
    }
}

/// Finds a byte string by Horspool's method: on a miss it skips ahead by up to
/// the string's length instead of comparing at every byte, as memmem does.
struct ByteFinder: Sendable {
    private let needle: [UInt8]
    private let shift: [Int]

    init(_ text: String) {
        needle = Array(text.utf8)
        var shift = [Int](repeating: needle.count, count: 256)
        for (index, byte) in needle.dropLast().enumerated() { shift[Int(byte)] = needle.count - 1 - index }
        self.shift = shift
    }

    func first(in base: UnsafePointer<UInt8>, count: Int) -> Int? {
        let length = needle.count
        guard length > 0, count >= length else { return nil }
        return needle.withUnsafeBufferPointer { needle in
            shift.withUnsafeBufferPointer { shift in
                let lastByte = needle[length - 1]
                var index = 0
                while index <= count - length {
                    let byte = base[index + length - 1]
                    if byte == lastByte, memcmp(base + index, needle.baseAddress!, length - 1) == 0 { return index }
                    index += shift[Int(byte)]
                }
                return nil
            }
        }
    }
}

struct TokenTally: Codable, Sendable {
    struct FileState: Codable, Sendable {
        var offset: UInt64
        var inode: UInt64
        /// The last reply counted (a reply's lines can straddle two reads).
        var lastID: String?
        var days: [String: TokenDay]
    }

    var files: [String: FileState] = [:]

    func days() -> [String: TokenDay] {
        var sum: [String: TokenDay] = [:]
        for file in files.values {
            for (day, tokens) in file.days { sum[day, default: TokenDay()].add(tokens) }
        }
        return sum
    }

    /// Reads what was added to `url` since last time (all of it if replaced or truncated).
    mutating func read(_ url: URL, marker: String, parse: (Data) -> TokenUsage?, dayKey: (Date) -> String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return }
        let size = UInt64(info.st_size), inode = UInt64(info.st_ino)
        var state = files[url.path] ?? FileState(offset: 0, inode: inode, days: [:])
        if state.inode != inode || size < state.offset { state = FileState(offset: 0, inode: inode, days: [:]) }
        guard size > state.offset, (try? handle.seek(toOffset: state.offset)) != nil else { files[url.path] = state; return }
        // In pieces, so a big file never sits in memory whole; a line cut by a piece's end waits for the next.
        let finder = ByteFinder(marker)
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            var data = carry
            data.append(chunk)
            // The marker is searched in the whole piece; only the lines it's in are looked at.
            let complete = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let last = Self.lastNewline(base, from: 0, to: raw.count) else { return 0 }
                let end = last + 1
                var from = 0
                while let found = finder.first(in: base + from, count: end - from) {
                    let hit = from + found
                    let start = Self.lastNewline(base, from: from, to: hit).map { $0 + 1 } ?? from
                    let stop = memchr(base + hit, 0x0A, end - hit).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? end
                    if stop - start <= JSONLTail.maxLine, let usage = parse(Data(bytes: base + start, count: stop - start)) {
                        if let id = usage.id, id == state.lastID {
                            // The same reply again.
                        } else {
                            if let id = usage.id { state.lastID = id }
                            state.days[dayKey(usage.date), default: TokenDay()].add(usage)
                        }
                    }
                    from = stop + 1
                    if from >= end { break }
                }
                return end
            }
            if complete == 0 {
                // A line too long to keep is skipped, and counted as read.
                if data.count > JSONLTail.maxLine { state.offset += UInt64(data.count); carry = Data() } else { carry = data }
                continue
            }
            carry = data.subdata(in: complete..<data.count)
            state.offset += UInt64(complete)
        }
        files[url.path] = state
    }

    private static func lastNewline(_ base: UnsafePointer<UInt8>, from: Int, to: Int) -> Int? {
        var index = to - 1
        while index >= from {
            if base[index] == 0x0A { return index }
            index -= 1
        }
        return nil
    }

    mutating func prune(oldest: String) {
        for (path, state) in files {
            guard FileManager.default.fileExists(atPath: path) else { files[path] = nil; continue }
            files[path]?.days = state.days.filter { $0.key >= oldest }
        }
    }
}

@MainActor
@Observable
final class TokenHistoryStore {
    static let shared = TokenHistoryStore()

    static let dayCount = 14

    struct History: Equatable {
        /// Oldest first, `dayCount` of them, today last.
        var days: [(date: Date, tokens: TokenDay)]
        var readAt: Date

        static func == (a: History, b: History) -> Bool {
            a.readAt == b.readAt && a.days.map(\.tokens) == b.days.map(\.tokens)
        }
    }

    private(set) var claude: History?
    private(set) var codex: History?
    private(set) var reading = false

    /// The tokens counted from an agent's own logs; only Claude Code's and Codex's are read.
    func history(for provider: AgentProvider) -> History? {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .qwen, .qoder, .cursor, .antigravity: nil
        }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let (claude, codex) = Self.read()
            await MainActor.run {
                self.claude = claude
                self.codex = codex
                self.reading = false
            }
        }
    }

    nonisolated static var cacheURL: URL {
        Relay.supportDirectory.appendingPathComponent("token-history.json")
    }

    nonisolated private static func read() -> (History, History) {
        let home = AgentFiles.home
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let key = { (date: Date) in formatter.string(from: date) }
        let oldest = dates.first ?? today

        struct Cache: Codable { var claude = TokenTally(); var codex = TokenTally() }
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()

        // Saved now and then too: a first read of large logs can take a while, and what
        // was read by a quit is kept.
        var savedAt = Date()
        func save() {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            savedAt = Date()
        }
        for file in recentFiles(under: AgentFiles.codexSessions(home: home), since: oldest) {
            cache.codex.read(file, marker: TokenLogs.codexMarker, parse: TokenLogs.codexUsage, dayKey: key)
        }
        for file in recentFiles(under: AgentFiles.claudeProjects(home: home), since: oldest) {
            cache.claude.read(file, marker: TokenLogs.claudeMarker, parse: TokenLogs.claudeUsage, dayKey: key)
            if Date().timeIntervalSince(savedAt) > 5 { save() }
        }
        cache.claude.prune(oldest: key(oldest))
        cache.codex.prune(oldest: key(oldest))
        save()
        func history(_ tally: TokenTally) -> History {
            let days = tally.days()
            return History(days: dates.map { ($0, days[key($0)] ?? TokenDay()) }, readAt: Date())
        }
        return (history(cache.claude), history(cache.codex))
    }

    nonisolated private static func recentFiles(under folder: URL, since date: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= date { files.append(url) }
        }
        return files
    }
}

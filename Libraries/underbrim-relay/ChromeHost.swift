//
//  ChromeHost.swift
//  underbrim-relay
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Chrome native-messaging host: Chrome writes 32-bit native-endian
//  length-prefixed JSON to stdin. Download summaries are forwarded to the
//  app's socket; nothing else is, and nothing is sent back.
//

import Darwin
import Foundation

enum ChromeHost {
    /// Our messages are tiny; anything larger is not from our extension.
    static let maxMessageBytes = 64 * 1024

    static func run(origin: String) -> Never {
        guard Relay.allowedChromeOrigins.contains(origin) else { exit(1) }
        var socketFD: Int32 = -1

        func forward(_ line: Data) -> Bool {
            if socketFD < 0 { socketFD = RelayClient.connect() }
            guard socketFD >= 0 else { return false }
            if RelayClient.write(socketFD, line) { return true }
            close(socketFD)
            socketFD = RelayClient.connect()
            return socketFD >= 0 && RelayClient.write(socketFD, line)
        }

        while let message = readMessage() {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "hello":
                let hello = RelayEvent(provider: "chrome", kind: "hello", ts: Date().timeIntervalSince1970)
                _ = Relay.encodeLine(hello).map(forward)
            case "download":
                if let event = RelaySanitizer.chromeDownload(object), let line = Relay.encodeLine(event) {
                    _ = forward(line)
                }
            default:
                continue
            }
        }
        exit(0)
    }

    private static func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress! + offset, count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            return nil
        }
        return data
    }

    static func readMessage() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0, length <= maxMessageBytes else { return nil }
        return readExactly(length)
    }
}

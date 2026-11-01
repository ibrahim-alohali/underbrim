//
//  RelayClient.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Unix-socket client. Hooks run synchronously inside the agent, so every call
//  is bounded and gives up when the app isn't running.
//

import Darwin
import Foundation

enum RelayClient {
    /// A connected socket, or -1; writes to a stalled app time out after 250 ms.
    static func connect(path: String = Relay.socketPath) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard Relay.withSocketAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Sends a request line and waits for one line back; nil when the app is absent, closes
    /// without an answer, or the asking agent goes away (its own prompt decides then).
    static func ask(_ line: Data, agent: ProcessLineage.Info?) -> Data? {
        let fd = connect()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard write(fd, line) else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 {
                // Once a second: the agent must still be the process that asked.
                if let agent, ProcessLineage.info(agent.pid)?.start != agent.start { return nil }
                if getppid() == 1 { return nil }
                continue
            }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                reply.append(contentsOf: chunk[0..<n])
                if let newline = reply.firstIndex(of: 0x0A) { return Data(reply[..<newline]) }
                if reply.count > Relay.maxLineBytes { return nil }
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    @discardableResult
    static func send(_ line: Data) -> Bool {
        let fd = connect()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return write(fd, line)
    }
}

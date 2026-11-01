//
//  RelayMessage.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A relay line as what it means, made once where the line is read (RelayServer.decode):
//  the rest of the app never sees the wire's strings and side-by-side optionals.
//

import Foundation

enum RelayMessage: Equatable, Sendable {
    /// Another agent's hook: its session's progress.
    case agent(AgentEvent)
    /// A request the agent waits on; the server holds its connection for the answer.
    case request(AgentRequestArrival)
    /// Claude Code's status line: plan usage.
    case usage(windows: [RelayWindow], at: Date)
    case download(ChromeDownload)
    /// The Chrome extension connected.
    case chromeHello
}

struct AgentRequestArrival: Equatable, Sendable {
    let provider: AgentProvider
    let session: String?
    let cwd: String?
    let host: String?
    let process: ProcessStamp?
    /// false for a scripted run nobody watches; nil when the agent doesn't say.
    let attended: Bool?
    let date: Date
    let request: RelayRequest
}

struct ChromeDownload: Equatable, Sendable {
    /// Chrome's download id.
    let id: Int
    var state: ChromeDownloadState
    var name: String?
    var path: String?
    var received: Int64?
    /// nil while Chrome doesn't know the size.
    var total: Int64?
}

extension RelayMessage {
    /// A checked wire event as a message; nil for a kind or an agent this build doesn't know.
    init?(_ event: RelayEvent) {
        let date = Date(timeIntervalSince1970: event.ts)
        if event.provider == "chrome" {
            switch event.kind {
            case "hello":
                self = .chromeHello
            case "download":
                guard let id = event.session.flatMap({ Int($0) }), id >= 0,
                      let state = event.detail.flatMap(ChromeDownloadState.init(rawValue:))
                else { return nil }
                // A total of -1 meant unknown before the helper left it out.
                self = .download(ChromeDownload(id: id, state: state, name: event.name, path: event.cwd,
                                                received: event.received, total: event.total.flatMap { $0 > 0 ? $0 : nil }))
            default:
                return nil
            }
            return
        }
        guard let provider = AgentProvider(rawValue: event.provider) else { return nil }
        let process = event.pid.flatMap { pid in event.pidStart.map { ProcessStamp(pid: pid, start: $0) } }
        if let request = event.request {
            self = .request(AgentRequestArrival(provider: provider, session: event.session, cwd: event.cwd, host: event.host,
                                                process: process, attended: event.attended, date: date, request: request))
            return
        }
        if event.kind == "usage" {
            guard provider == .claude, let windows = event.windows else { return nil }
            self = .usage(windows: windows, at: date)
            return
        }
        guard let session = event.session,
              let kind = AgentEvent.Kind(hookEvent: event.kind, tool: event.tool, detail: event.detail)
        else { return nil }
        self = .agent(AgentEvent(provider: provider, session: session, kind: kind, date: date, cwd: event.cwd,
                                 title: event.title, entry: event.entry, hostSession: event.hostSession,
                                 attended: event.attended, host: event.host, process: process))
    }
}

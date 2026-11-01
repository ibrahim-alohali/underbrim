//
//  main.swift
//  underbrim-relay
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Status relay bundled with Underbrim.
//
//    underbrim-relay ask claude|codex|qwen|qoder
//                                          the agent's PermissionRequest hook: the
//                                          request is answered in the notch
//    underbrim-relay hook qwen|qoder|cursor|antigravity <event>
//                                          a session's progress → app socket
//    underbrim-relay hook codex            the approval hook of earlier versions → app
//                                          socket (their status hooks send nothing)
//    underbrim-relay statusline            Claude Code status line (plan usage)
//    underbrim-relay <chrome-extension://…> Chrome native-messaging host (Chrome
//                                            passes the caller's origin as argv[1])
//
//  Hook mode prints nothing and always exits 0, so it can never approve,
//  deny, block or add context to an agent turn. It gives up within a fraction
//  of a second when the app isn't running. Ask mode prints the agent's reply
//  only for an answer the user gave in the notch; otherwise nothing, and the
//  agent's own prompt decides.
//

import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

/// Reads stdin up to `limit` bytes, then drains (and discards) the rest so
/// the writer never sees a broken pipe.
func readStandardInput(limit: Int) -> Data {
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(STDIN_FILENO, &chunk, chunk.count)
        if n > 0 {
            if data.count < limit { data.append(contentsOf: chunk[0..<min(n, limit - data.count)]) }
            continue
        }
        if n < 0, errno == EINTR { continue }
        return data
    }
}

func runHook(provider name: String, event: String?) -> Never {
    // Hard stop: hooks are synchronous for the agent, so never linger.
    signal(SIGALRM) { _ in _exit(0) }
    alarm(2)
    let input = readStandardInput(limit: 8 << 20)
    // The agent is the first ancestor past the launching shell.
    let lineage = ProcessLineage.agentAndHost(chain: ProcessLineage.ancestors(of: getppid()))
    if let provider = AgentProvider(rawValue: name),
       let event = RelaySanitizer.hookEvent(provider: provider, event: event, input: input, lineage: lineage),
       let line = Relay.encodeLine(event) {
        RelayClient.send(line)
    }
    exit(0)
}

/// The agent's PermissionRequest hook: waits for the user's answer in the notch (Claude
/// asks in its own window too; the first answer counts).
func runAsk(provider name: String) -> Never {
    signal(SIGALRM) { _ in _exit(0) }
    alarm(10)
    let input = readStandardInput(limit: 8 << 20)
    alarm(0)
    let id = UUID().uuidString
    guard let provider = AgentProvider(rawValue: name), let format = provider.spec.answers else { exit(0) }
    guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
    let built: RelayRequest? = switch format {
    case .claude: RelayRequestBuilder.claudeRequest(id: id, input: object)
    case .allowOrDeny: RelayRequestBuilder.codexRequest(id: id, input: object)
    }
    guard let request = built else { exit(0) }
    let lineage = ProcessLineage.agentAndHost(chain: ProcessLineage.ancestors(of: getppid()))
    let environment = ProcessInfo.processInfo.environment
    // Other agents read Claude Code's hook settings too (TRAE, Cursor, Devin…), so only a request
    // the agent's own hook made is answered: Claude Code gives its hooks its own pid, Qwen Code and
    // Qoder set a variable of theirs.
    switch provider.spec.askCheck {
    case .none:
        break
    case .processID(let variable):
        guard let agent = lineage.agent, environment[variable] == String(agent.pid) else { exit(0) }
    case .variable(let variable):
        if environment[variable]?.isEmpty != false { exit(0) }
    }
    var event = RelayEvent(
        provider: provider.rawValue,
        kind: "Request",
        session: Relay.identifier(object["session_id"] ?? object["thread_id"]),
        cwd: Relay.path(object["cwd"]),
        tool: request.tool,
        ts: Date().timeIntervalSince1970,
        pid: lineage.agent?.pid,
        pidStart: lineage.agent?.start,
        host: Relay.identifier(lineage.hostBundleID)
    )
    event.request = request
    // Scripted and background runs (`claude -p`, SDK apps) say so.
    if environment["CLAUDE_CODE_SESSION_ATTENDED"] == "0" { event.attended = false }
    guard let line = Relay.encodeLine(event),
          let reply = RelayClient.ask(line, agent: lineage.agent),
          let answer = try? JSONDecoder().decode(RelayAnswer.self, from: reply)
    else { exit(0) }
    let output: Data? = switch format {
    case .claude: RelayRequestBuilder.claudeOutput(for: answer, request: request, input: object)
    case .allowOrDeny: RelayRequestBuilder.codexOutput(for: answer, request: request)
    }
    guard let output else { exit(0) }
    FileHandle.standardOutput.write(output)
    exit(0)
}

/// Claude Code status line: forwards plan usage to the app and prints a
/// short line (an empty one would leave a blank row in the terminal).
func runStatusLine() -> Never {
    signal(SIGALRM) { _ in _exit(0) }
    alarm(2)
    let result = RelaySanitizer.statusLine(readStandardInput(limit: 1 << 20))
    if let event = result.event, let line = Relay.encodeLine(event) {
        RelayClient.send(line)
    }
    print(result.text)
    exit(0)
}

switch arguments.first {
case "hook":
    runHook(provider: arguments.count > 1 ? arguments[1] : "", event: arguments.count > 2 ? arguments[2] : nil)
case "ask":
    runAsk(provider: arguments.count > 1 ? arguments[1] : "")
case "statusline":
    runStatusLine()
case let origin? where origin.hasPrefix("chrome-extension://"):
    ChromeHost.run(origin: origin)
default:
    // `hook claude` still runs (earlier versions' hooks call it) but sends nothing.
    FileHandle.standardError.write(Data("usage: underbrim-relay ask claude|codex|qwen|qoder\n       underbrim-relay hook qwen|qoder|cursor|antigravity <event>\n       underbrim-relay statusline\n".utf8))
    exit(0)
}

//
//  DebugCommands.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Debug builds only: the real handlers, driven by name from outside the app.
//

#if DEBUG
import AppKit

extension AppDelegate {
    func listenForDebugCommands() {
        // Debug builds: drive the real handlers by name, e.g. "lock", "unlock", "adhan", "plug",
        // "settings:prayer", "shelf:/path", "meeting:3", "notification:Hi" (Messages), "title:A long name", "volume:0.4",
        // "agent:Stop@com.apple.Terminal#1234" (a Claude Code event, in an app and with a process if given),
        // "agent-question:Ship it?" (that session's turn ending with the Claude app's question), "keyboard" (the
        // shortcut that opens the notch), "key:125" or "key:36+cmd" (a key pressed in the island while it has the keyboard).
        // `swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: .init("io.github.ibrahim-alohali.underbrim.debug"), object: "unlock")'`
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "io.github.ibrahim-alohali.underbrim.debug"),
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    switch notification.object as? String {
                    case "lock": self?.onScreenLocked(notification)
                    case "unlock": self?.onScreenUnlocked(notification)
                    case "adhan": PrayerTimesStore.shared.arriveSoon()
                    case "plug": BatteryStatusViewModel.shared.debugPlugIn()
                    case "unplug": BatteryStatusViewModel.shared.debugUnplug()
                    case "lowbattery": BatteryStatusViewModel.shared.debugLowBattery()
                    case "sound-report": SoundMixer.shared.report()
                    case "keyboard": self?.toggleNotchFromKeyboard()
                    case let command? where command.hasPrefix("key:"):
                        let parts = command.dropFirst(4).split(separator: "+")
                        guard let window = NSApp.keyWindow, let code = parts.first.flatMap({ UInt16($0) }),
                              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: parts.contains("cmd") ? .command : [],
                                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                           context: nil, characters: code == 49 ? " " : "", charactersIgnoringModifiers: code == 49 ? " " : "",
                                                           isARepeat: false, keyCode: code)
                        else { break }
                        NSApp.postEvent(event, atStart: false)
                    case let command? where command.hasPrefix("settings:"):
                        SettingsWindowController.shared.showWindow(tab: SettingsTab(rawValue: String(command.dropFirst(9))) ?? .general)
                    case let command? where command.hasPrefix("call:"):
                        let app = String(command.dropFirst(5))
                        CallActivity.shared.debugApp = app.isEmpty ? nil : app
                        CallActivity.shared.refresh()
                    case let command? where command.hasPrefix("meeting:"):
                        MeetingStore.shared.debugMeeting(inMinutes: Double(command.dropFirst(8)) ?? 3)
                    case let command? where command.hasPrefix("notification:"):
                        // "#chat Hi" reuses the token "chat", as banners from one conversation can.
                        var body = String(command.dropFirst(13)), token = UUID().uuidString
                        if body.hasPrefix("#"), let space = body.firstIndex(of: " ") {
                            token = String(body[body.index(after: body.startIndex)..<space])
                            body = String(body[body.index(after: space)...])
                        }
                        SystemNotificationManager.shared.receive(UnderbrimBanner(
                            token: token, appName: "Messages", bundleID: "com.apple.MobileSMS",
                            title: "Underbrim", subtitle: nil, body: body.isEmpty ? nil : body))
                    case let command? where command.hasPrefix("agent:"):
                        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sample Project").path
                        let parts = command.dropFirst(6).split(separator: "#", maxSplits: 1)
                        let kindAndHost = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
                        let process = parts.count > 1 ? Int32(parts[1]).flatMap { ProcessLineage.info($0) } : nil
                        if case .agent(let event)? = RelayMessage(RelayEvent(provider: "claude", kind: kindAndHost[0], session: "debug",
                                                                             cwd: folder, tool: "Bash", ts: Date().timeIntervalSince1970,
                                                                             pid: process?.pid, pidStart: process?.start,
                                                                             host: kindAndHost.count > 1 ? kindAndHost[1] : nil)) {
                            AgentSessionStore.shared.apply(event, live: true)
                        }
                    case let command? where command.hasPrefix("agent-question:"):
                        // The debug session's turn ends with the Claude app's question under its reply.
                        // The same question each time it's sent, as a transcript read again gives it.
                        let text = String(command.dropFirst(15))
                        let step = AgentNextStep(ask: text, choices: [.init(label: "Yes"), .init(label: "Not now")], at: Date(), id: "debug:\(text)")
                        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sample Project").path
                        if case .agent(let event)? = RelayMessage(RelayEvent(provider: "claude", kind: "Stop", session: "debug", cwd: folder,
                                                                             ts: Date().timeIntervalSince1970)) {
                            AgentSessionStore.shared.apply(event, live: true, details: AgentDetails(nextStep: step))
                        }
                    case let command? where command.hasPrefix("volume:"):
                        HUDPresenter.shared.toggleSneakPeek(status: true, type: .volume, duration: 4,
                                                            value: CGFloat(Double(command.dropFirst(7)) ?? 0.5))
                    case let command? where command.hasPrefix("title:"):
                        MusicManager.shared.songTitle = String(command.dropFirst(6))
                    case let command? where command.hasPrefix("shelf:"):
                        ShelfStateViewModel.shared.addFile(URL(fileURLWithPath: String(command.dropFirst(6))))
                    default: break
                    }
                }
        })
    }
}
#endif

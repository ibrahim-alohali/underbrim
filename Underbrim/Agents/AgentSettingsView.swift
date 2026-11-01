//
//  AgentSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Coding-agent settings. Claude Code's and Codex's sessions need no setup (only the
//  optional answering hooks and Claude status line); Qwen Code, Qoder, Cursor and
//  Antigravity are followed through hooks switched on here.
//

import Defaults
import SwiftUI

@MainActor
@Observable
final class AgentSetupModel {
    var claudeHooks = 0
    var claudeAnswering: HookInstaller.Status = .notInstalled
    var claudeOtherAnswerers: [String] = []
    private var claudeCurrent = 0
    var claudeStatusLine: HookInstaller.StatusLineState = .notInstalled
    var codex: HookInstaller.Status = .notInstalled
    var codexHooks = 0
    var codexTrust: [CodexAppServer.HookTrust]?
    var checkingCodexTrust = false
    var message: String?

    // Both keep their hooks in a settings file of their own.
    private let claudeInstaller = HookInstaller(agent: .claude)!
    private let codexInstaller = HookInstaller(agent: .codex)!

    var codexConfigPath: String { codexInstaller.configURL.path }
    var approvalHook: Bool { codex == .installed }
    /// Other apps' hooks that also answer Codex's requests (Codex waits for all of them).
    var codexOtherAnswerers: [String] = []
    /// Hooks an earlier version added: any in Claude Code, and Codex's beyond the approval hook.
    var leftovers: (claude: Int, codex: Int) {
        (claudeHooks - claudeCurrent, codex == .outdated ? codexHooks - codexApprovalKept : 0)
    }
    var answersClaude: Bool { claudeCurrent > 0 }
    /// 1 when Codex's file holds an approval hook (kept when the rest go).
    private var codexApprovalKept: Int {
        codexInstaller.events.contains { codexInstaller.ownedCount(in: $0.name) > 0 } ? 1 : 0
    }

    func refresh() {
        claudeHooks = claudeInstaller.ownedCount()
        claudeCurrent = claudeInstaller.currentCount()
        claudeAnswering = claudeInstaller.status()
        claudeOtherAnswerers = Array(Set(claudeInstaller.foreignAnswerers())).sorted()
        claudeStatusLine = claudeInstaller.statusLineState()
        codex = codexInstaller.status()
        codexHooks = codexInstaller.ownedCount()
        codexOtherAnswerers = Array(Set(codexInstaller.foreignAnswerers())).sorted()
        if approvalHook { checkCodexTrust() } else { codexTrust = nil }
        refreshHookAgents()
    }

    /// Switched on, Codex is also told to trust the hook (as its own /hooks review would), so it runs at once.
    func setApprovalHook(_ on: Bool) {
        perform { [on ? try codexInstaller.install() : try codexInstaller.uninstall()] }
        guard on, approvalHook else { return }
        checkingCodexTrust = true
        Task {
            defer { checkingCodexTrust = false }
            do {
                codexTrust = try await CodexAppServer.trustOwnHooks().hooks
            } catch {
                codexTrust = (try? await CodexAppServer.fetch(hooksOnly: true))?.hooks
                message = String(localized: "Codex couldn't be asked to trust the hook (\(error.localizedDescription)). Review it in Codex instead.")
            }
        }
    }

    func setAnswersClaude(_ on: Bool) {
        perform { [on ? try claudeInstaller.install() : try claudeInstaller.uninstall()] }
    }

    func removeLeftovers() {
        let keep = (codex: codexApprovalKept > 0, claude: answersClaude)
        let installers = [(claudeInstaller, keep.claude)] + (codex == .outdated ? [(codexInstaller, keep.codex)] : [])
        perform {
            // install() keeps (and refreshes) the hook in use and removes the rest.
            try installers.map { installer, kept in kept ? try installer.install() : try installer.uninstall() }
        }
    }

    func setStatusLine(_ enabled: Bool) {
        perform { [enabled ? try claudeInstaller.installStatusLine() : try claudeInstaller.uninstallStatusLine()] }
        Defaults[.claudeStatusLineFeed] = enabled && claudeStatusLine == .installed
        AgentUsageStore.shared.applySettings()
    }

    /// Runs `change`, which gives the backups of the files it changed, and says how it went. The island
    /// reads the agents' hooks again at once: a wait it shows offers answering here only while it's off.
    private func perform(_ change: () throws -> [URL?]) {
        defer { AgentRoster.shared.refresh() }
        do {
            let backups = try change().compactMap { $0?.lastPathComponent }
            message = backups.isEmpty
                ? String(localized: "Done.")
                : backups.count == 1
                ? String(localized: "Done. The previous file was backed up to \(backups[0]).")
                : String(localized: "Done. The previous files were backed up to \(backups.formatted(.list(type: .and))).")
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    /// Codex runs a new hook only after the user approves it in Codex.
    func checkCodexTrust() {
        guard !checkingCodexTrust else { return }
        checkingCodexTrust = true
        Task {
            defer { checkingCodexTrust = false }
            codexTrust = (try? await CodexAppServer.fetch(hooksOnly: true))?.hooks
        }
    }

    var codexApproved: Bool? {
        guard let codexTrust, !codexTrust.isEmpty else { return nil }
        return codexTrust.allSatisfy { $0.trustStatus == "trusted" && $0.enabled }
    }

    // MARK: Agents followed through their hooks

    static let hookAgents = AgentProvider.allCases.filter { !$0.readsFiles }

    struct HookAgentState: Equatable {
        var follows = false
        var answers = false
        var problem: String?
    }

    var hookAgentStates: [AgentProvider: HookAgentState] = [:]

    func refreshHookAgents() {
        for provider in Self.hookAgents {
            var state = HookAgentState()
            if let setup = provider.hookSetup(answers: true) {
                let status = setup.status()
                if case .unreadable(let reason) = status { state.problem = reason }
                state.follows = status.follows
                state.answers = status.follows && setup.answersInNotch()
            }
            hookAgentStates[provider] = state
        }
    }

    func setFollows(_ provider: AgentProvider, _ on: Bool) {
        let answers = hookAgentStates[provider]?.answers ?? false
        guard let setup = provider.hookSetup(answers: answers) else { return }
        perform { [on ? try setup.install() : try setup.uninstall()] }
    }

    func setAnswers(_ provider: AgentProvider, _ on: Bool) {
        guard let setup = provider.hookSetup(answers: on) else { return }
        perform { [try setup.install()] }
    }

    /// On this Mac: the app, or the command-line tool where npm, Homebrew and others put it, or its settings folder.
    static func isAvailable(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .claude, .codex:
            // Read from their files: they need no setup here.
            return false
        case .cursor, .antigravity:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.defaultHostBundleID) != nil
        case .qwen:
            return hasCommandLineTool("qwen", folder: ".qwen")
        case .qoder:
            return hasCommandLineTool("qodercli", folder: ".qoder")
        }
    }

    private static func hasCommandLineTool(_ tool: String, folder: String) -> Bool {
        let home = Relay.homeDirectory, fm = FileManager.default
        if fm.fileExists(atPath: "\(home)/\(folder)") { return true }
        let nvm = "\(home)/.nvm/versions/node"
        let places = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
            + ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).map { "\(nvm)/\($0)/bin" }
        return places.contains { fm.isExecutableFile(atPath: "\($0)/\(tool)") }
    }
}

struct AgentSettingsView: View {
    @State private var model = AgentSetupModel()
    @Default(.showAgentActivity) private var agentsOn
    private let sessions = AgentSessionStore.shared
    private let relay = RelayListener.shared
    private let usage = AgentUsageStore.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showAgentActivity) { Text("Show coding sessions in the notch") }
                    .settingsItem("Show coding sessions in the notch")
                Defaults.Toggle(key: .showSessionDetails) {
                    SettingsLabel("Show details on session cards", info: "The file or command at work, the task list, and for a while after a turn ends, the start of the reply and of your message.")
                }
                .settingsItem("Show details on session cards")
                Defaults.Toggle(key: .agentSounds) {
                    SettingsLabel("Play sounds",
                                  info: "A short sound in each agent's own voice when a session needs you, finishes or fails. Quiet while the screen is locked, during a Focus, while that session's app is in front, and while your screen is shared or recorded.",
                                  "Made in the app, at the alert volume set in Sound settings, through the device chosen for alerts.")
                }
                .settingsItem("Play sounds")
                if sessions.hasOutdatedClaude {
                    Label("A Claude Code running in a terminal is too old to report approvals, questions or idle; it shows only working and done. Update it to 2.1.162 or later.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                SettingsPageHeader(tab: .agents, section: "Live sessions",
                                   info: ["Underbrim follows the files Claude Code and Codex keep about their sessions on this Mac: the Claude app's Code tab, the terminal `claude` and `codex`, and the Codex app. It reads their status, folder, title and tool names, and for the cards' details, what a tool works on, the task list and the start of the last message and reply. Nothing is saved or sent anywhere, and nothing changes in either app. Regular Claude and ChatGPT chats, cloud tasks and remote machines aren't included."])
            }

            if let problem = relayProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            answerSection
            codexSection
            hookAgentsSection
            usageSection

            if let message = model.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }

            if agentsOn {
                MoreInAdvanced(.agents)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            relay.check()
            model.refresh()
        }
        .navigationTitle("Coding Agents")
    }

    /// Why hooks can't reach the app: nothing that relies on them is turned on until it's fixed.
    private var relayProblem: String? { relay.health?.problem }

    // MARK: Answering in the notch

    private var answerSection: some View {
        Section {
            if case .unreadable(let reason) = model.claudeAnswering {
                Label("~/.claude/settings.json can't be read safely (\(reason)), so it won't be changed.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .settingsItem("Answer Claude Code in the notch")
            } else {
                Toggle(isOn: Binding(get: { model.answersClaude }, set: { model.setAnswersClaude($0) })) {
                    SettingsLabel("Answer Claude Code in the notch", info: "Approvals, questions and plans show in the notch, with the command or change they ask about. Claude still asks in its own window too, and the first answer counts. Adds one hook to ~/.claude/settings.json; switching this off removes it. Without it, the Claude app's questions can still be answered in the notch through Accessibility.")
                }
                .disabled(!model.answersClaude && relayProblem != nil)
                .settingsItem("Answer Claude Code in the notch")
                if model.answersClaude, let others = model.claudeOtherAnswerers.first {
                    Label(model.claudeOtherAnswerers.count == 1
                          ? "\(others) also answers Claude's requests, so each one shows there too. The first answer counts."
                          : "\(model.claudeOtherAnswerers.formatted(.list(type: .and))) also answer Claude's requests, so each one shows there too. The first answer counts.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Defaults.Toggle(key: .openIslandForAgentRequests) {
                SettingsLabel("Show agent questions in the notch", info: "An approval, a question, a plan or the Claude app's question under a reply opens the island on its own, without taking the keyboard, and stays until you answer it, close it, or answer in the agent's window. With Accessibility allowed, you answer the Claude app's questions in the island too: Underbrim fills in Claude's own box or presses its button for you. When off, the closed notch shows that an agent is waiting.")
            }
            .settingsItem("Show agent questions in the notch")
        } header: {
            SettingsLabel("Answer in the notch", info: "Nothing is ever approved without your click. Answer in Claude hands a request back to Claude's own prompt, as does quitting Underbrim.")
        }
    }

    // MARK: Agents followed through their hooks

    @ViewBuilder private var hookAgentsSection: some View {
        let installed = AgentSetupModel.hookAgents.filter(AgentSetupModel.isAvailable)
        if !installed.isEmpty {
            Section {
                ForEach(installed, id: \.self) { provider in
                    hookAgentRows(provider, state: model.hookAgentStates[provider] ?? .init())
                }
            } header: {
                SettingsLabel("More agents", info: "These agents keep no session files Underbrim can follow, so it adds hooks to their settings that report a session's progress and print nothing. Switching one off removes only Underbrim's hooks.")
            }
        }
    }

    @ViewBuilder private func hookAgentRows(_ provider: AgentProvider, state: AgentSetupModel.HookAgentState) -> some View {
        if let rows = provider.hookAgentRows {
            if let problem = state.problem {
                Label("\(provider.displayName)'s settings can't be read safely (\(problem)), so they won't be changed.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .settingsItem(rows.follow)
            } else {
                Toggle(isOn: Binding(get: { state.follows }, set: { model.setFollows(provider, $0) })) {
                    SettingsLabel(LocalizedStringKey(rows.follow), info: rows.followNote)
                }
                .disabled(!state.follows && relayProblem != nil)
                .settingsItem(rows.follow)
                if state.follows, let answer = rows.answer {
                    Toggle(isOn: Binding(get: { state.answers }, set: { model.setAnswers(provider, $0) })) {
                        SettingsLabel(LocalizedStringKey(answer), info: rows.answerNote.map { [$0] } ?? [])
                    }
                    .disabled(!state.answers && relayProblem != nil)
                    .settingsItem(answer)
                }
            }
        }
    }

    // MARK: Codex

    private static let handBackMinutes = Int(HookInstaller.handBackAfter / 60)

    private var codexSection: some View {
        Section {
            if case .unreadable(let reason) = model.codex {
                Label("\(model.codexConfigPath) can't be read safely (\(reason)), so it won't be changed.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .settingsItem("Answer Codex in the notch")
            } else {
                Toggle(isOn: Binding(get: { model.approvalHook }, set: { model.setApprovalHook($0) })) {
                    SettingsLabel("Answer Codex in the notch", info: "Approvals show in the notch while Codex isn't the app in front. Codex waits for your answer there, and asks in its own window again when you switch to it or after \(Self.handBackMinutes) minutes. Adds one hook to \(model.codexConfigPath) and marks it as trusted in Codex; switching this off removes it.")
                }
                .disabled(!model.approvalHook && relayProblem != nil)
                .settingsItem("Answer Codex in the notch")
                if model.approvalHook {
                    codexApprovalRow
                    if let others = model.codexOtherAnswerers.first {
                        Label(model.codexOtherAnswerers.count == 1
                              ? "\(others) also answers Codex's approvals, and Codex waits for every app that does. Remove one of them."
                              : "\(model.codexOtherAnswerers.formatted(.list(type: .and))) also answer Codex's approvals, and Codex waits for every app that does. Keep only one of them.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Codex")
        }
    }

    @ViewBuilder private var codexApprovalRow: some View {
        if model.checkingCodexTrust {
            HStack { ProgressView().controlSize(.small); Text("Checking approval in Codex…").foregroundStyle(.secondary) }
        } else if model.codexApproved == true {
            Label("Trusted in Codex", systemImage: "checkmark.seal").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.codexApproved == false ? "Waiting for your approval in Codex" : "Approval state unknown",
                      systemImage: "hand.raised")
                    .foregroundStyle(model.codexApproved == false ? .orange : .secondary)
                Text("In Codex's main window, click Review hooks next to the message box.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Codex") { AppInfo.activate(AgentProvider.codex.defaultHostBundleID) }
                    Button("Check Again") { model.checkCodexTrust() }
                }
            }
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        Section {
            Defaults.Toggle(key: .codexUsageEnabled) {
                SettingsLabel("Codex plan usage", info: "Read-only, through the Codex app on this Mac. Refreshes every 5 minutes while you're using the Mac.")
            }
            .settingsItem("Codex plan usage")
            if let account = usage.codex.snapshot?.account {
                LabeledContent("Codex account", value: [account, usage.codex.snapshot?.plan].compactMap { $0 }.joined(separator: " · "))
            }

            Toggle(isOn: Binding(
                get: { model.claudeStatusLine == .installed },
                set: { model.setStatusLine($0) }
            )) {
                if model.claudeStatusLine == .foreign {
                    Text("Claude plan usage from terminal sessions")
                    Text("You already have a status line, so this is unavailable.")
                } else {
                    SettingsLabel("Claude plan usage from terminal sessions", info: "Adds a status line to terminal sessions, Claude Code's documented source for plan limits. It replaces the default footer hints there.")
                }
            }
            .disabled(model.claudeStatusLine == .foreign || (model.claudeStatusLine != .installed && relayProblem != nil))
            .settingsItem("Claude plan usage from terminal sessions")

            Defaults.Toggle(key: .readClaudeDesktopUsage) {
                SettingsLabel("Claude plan usage from the Claude app (unofficial)", info: "Reads the 5-hour and weekly percentages the Claude app saves on this Mac each time it checks your usage. Undocumented, so it may stop working. It has no reset times, and your Claude login is never read.")
            }
            .settingsItem("Claude plan usage from the Claude app (unofficial)")
        } header: {
            SettingsLabel("Plan usage", info: "Your Claude login is never read: Anthropic's terms don't allow other apps to use Claude.ai credentials.")
        }
    }
}

struct AgentAdvancedSettings: View {
    @State private var model = AgentSetupModel()
    @Default(.usageWarningPercent) private var warningPercent
    @Default(.hiddenAgentFolders) private var hiddenFolders
    @Default(.agentSounds) private var soundsOn
    @Default(.agentSoundVolume) private var soundVolume
    @Default(.agentReminderMinutes) private var reminderMinutes
    @State private var previewKind = AgentCreatureKind.agent(.claude)

    var body: some View {
        Section {
            Defaults.Toggle(key: .showBackgroundAgents) {
                SettingsLabel("Include scripted and background runs", info: "Sessions started by scripts or other apps, such as `claude -p`.")
            }
            .settingsItem("Include scripted and background runs")
            Defaults.Toggle(key: .keepAwakeWhileAgentsWork) {
                SettingsLabel("Keep the Mac awake while a session works", info: "It doesn't go to sleep on its own in the middle of a task. The display can still sleep, and closing the lid still sleeps the Mac.")
            }
            .settingsItem("Keep the Mac awake while a session works")
            Defaults.Toggle(key: .useClaudeDesktopSessionLinks) {
                SettingsLabel("Open Claude app sessions directly", info: "Uses the link the Claude app builds for its own Spotlight results; it isn't documented. When off, clicking just brings the Claude app forward.")
            }
            .settingsItem("Open Claude app sessions directly")
            Picker(selection: $warningPercent) {
                ForEach(UsageWarnings.choices, id: \.self) { percent in
                    Text(percent == 0 ? String(localized: "Never") : (Double(percent) / 100).formatted(.percent)).tag(percent)
                }
            } label: {
                SettingsLabel("Warn when a limit reaches", info: "The closed notch says so once, and again when that limit has reset.")
            }
            .settingsItem("Warn when a limit reaches")
            ForEach(hiddenFolders, id: \.self) { folder in
                LabeledContent {
                    Button {
                        hiddenFolders.removeAll { $0 == folder }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Show Its Sessions Again")
                    .accessibilityLabel(Text("Show Its Sessions Again"))
                } label: {
                    Label {
                        Text((folder as NSString).lastPathComponent)
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                }
            }
        } header: {
            AdvancedHeader(area: .agents)
        }

        if soundsOn {
            soundsSection
        }

        if model.leftovers.claude + model.leftovers.codex > 0 {
            leftoversSection
        }

        if let message = model.message {
            Section { Text(message).foregroundStyle(.secondary) }
        }

        Section {
            HStack {
                Button("Show Backups in Finder") {
                    let url = HookInstaller.backupDirectory
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                SettingsInfo("Each change backs up the original file first. Removing something deletes only Underbrim's own entries and keeps everything else you've changed since.")
            }
            .settingsItem("Show Backups in Finder")
        }
        .onAppear { model.refresh() }
    }

    private var soundsSection: some View {
        Section {
            Slider(value: $soundVolume, in: 0.1...1) {
                Text("Volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill").accessibilityLabel("Quieter")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill").accessibilityLabel("Louder")
            }
            Picker(selection: $previewKind) {
                ForEach(AgentCreatureKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                Text("Voice to preview")
            }
            cueToggle(.agentSoundForAttention, cue: .attention, title: "Needs you")
            cueToggle(.agentSoundForDone, cue: .done, title: "Done")
            cueToggle(.agentSoundForFailed, cue: .failed, title: "Failed")
            Picker(selection: $reminderMinutes) {
                ForEach(AgentCues.reminderChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? String(localized: "Never") : String(localized: "After \(minutes) min")).tag(minutes)
                }
            } label: {
                SettingsLabel("Remind me of a waiting request", info: "Once: the needs-you sound again, and its creature asks again.")
            }
            .settingsItem("Remind me of a waiting request")
        } header: {
            Text("Sounds")
        }
    }

    private func cueToggle(_ key: Defaults.Key<Bool>, cue: CreatureCue, title: LocalizedStringKey) -> some View {
        HStack {
            Defaults.Toggle(key: key) { Text(title) }
            Button {
                AgentCues.shared.preview(cue, for: previewKind)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Preview")
            .accessibilityLabel(Text("Preview"))
        }
    }

    private var leftoversSection: some View {
        Section {
            let (claude, codex) = model.leftovers
            Text(claude > 0 && codex > 0
                 ? "An earlier version of Underbrim added hooks that are no longer needed: \(claude) to Claude Code and \(codex) to Codex."
                 : claude > 0
                 ? "An earlier version of Underbrim added \(claude) hooks to Claude Code. They're no longer needed."
                 : "An earlier version of Underbrim added \(codex) hooks to Codex. They're no longer needed.")
            Button("Remove Them") { model.removeLeftovers() }
        } header: {
            Text("Hooks from an earlier version")
        } footer: {
            Text("Removes only Underbrim's entries. Nothing changes until you click.")
        }
    }
}

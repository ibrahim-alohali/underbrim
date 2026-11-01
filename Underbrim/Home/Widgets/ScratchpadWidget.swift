//
//  ScratchpadWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A note typed straight into the notch, kept in a private file on this Mac. It can go on to an
//  installed notes or task app through that app's documented link (no sign-in or permission).
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class Scratchpad {
    static let shared = Scratchpad()

    var text: String {
        didSet { if text != oldValue { scheduleSave() } }
    }
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored weak var editingIsland: NotchViewModel?
    /// The note on disk couldn't be read or set aside, so nothing is saved over it.
    @ObservationIgnored private var readOnly = false

    struct Jump: Equatable {
        let island: ObjectIdentifier
        /// The shortcut opened the island for it, so finishing the note closes it again.
        let closesWhenDone: Bool
        let id = UUID()
    }
    private(set) var jump: Jump?

    /// The shortcut sends the keyboard straight into the note in `island`'s Home. Not taken within a
    /// second (Home isn't showing), it's dropped, so it can't take the keyboard later.
    func jump(to island: NotchViewModel, closesWhenDone: Bool) {
        let jump = Jump(island: ObjectIdentifier(island), closesWhenDone: closesWhenDone)
        self.jump = jump
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.took(jump) }
    }

    /// The note has the keyboard (or the second is up): `jump` is done with.
    func took(_ jump: Jump) {
        if self.jump == jump { self.jump = nil }
    }

    private init() {
        let fileURL = Relay.supportDirectory.appendingPathComponent("Scratchpad.txt")
        self.fileURL = fileURL
        switch Self.read(fileURL) {
        case .text(let saved): text = saved
        case .unreadable:
            text = ""
            readOnly = true
        }
        // The note is about to take the keyboard: no widget takes its keys meanwhile.
        HomeWidgetKeys.register(.scratchpad, typing: { [weak self] in self?.jump != nil })
    }

    private enum Saved { case text(String), unreadable }

    /// The note as saved. One another editor saved in another encoding is read in that one; a file
    /// that can't be read as text is set aside beside it rather than written over.
    private static func read(_ url: URL) -> Saved {
        guard FileManager.default.fileExists(atPath: url.path) else { return .text("") }
        if let text = try? String(contentsOf: url, encoding: .utf8) { return .text(text) }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return .text(text) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let aside = url.deletingLastPathComponent().appendingPathComponent("Scratchpad (unreadable \(stamp)).txt")
        return (try? FileManager.default.moveItem(at: url, to: aside)) != nil ? .text("") : .unreadable
    }

    private func scheduleSave() {
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saving?.cancel()
        saving = nil
        guard !readOnly else { return }
        let files = FileManager.default
        try? files.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        guard (try? Data(text.utf8).write(to: fileURL, options: .atomic)) != nil else { return }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func flush() { if saving != nil { saveNow() } }

    // MARK: Sending on

    struct Target: Identifiable, Sendable {
        let name: String
        let scheme: String
        /// Whether its window comes forward (Todoist's Quick Add asks to confirm).
        let activates: Bool
        let link: @Sendable (_ title: String, _ body: String, _ full: String) -> URL?
        var id: String { scheme }
    }

    nonisolated static let targets: [Target] = [
        Target(name: "Things", scheme: "things", activates: false) { title, body, _ in
            url("things:///add", ["title": title, "notes": body])
        },
        Target(name: "Todoist", scheme: "todoist", activates: true) { _, _, full in
            url("todoist://openquickadd", ["content": full])
        },
        Target(name: "Bear", scheme: "bear", activates: false) { _, _, full in
            url("bear://x-callback-url/create", ["text": full, "open_note": "no", "show_window": "no"])
        },
        Target(name: "Obsidian", scheme: "obsidian", activates: false) { _, _, full in
            url("obsidian://new", ["content": full, "silent": "true"])
        },
        Target(name: "Drafts", scheme: "drafts", activates: false) { _, _, full in
            url("drafts://create", ["text": full])
        },
    ]

    /// `base` with these query items, "+" encoded too (apps decode it as a space).
    nonisolated static func url(_ base: String, _ items: [String: String]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    nonisolated static func split(_ text: String) -> (title: String, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, "") }
        return (String(trimmed[..<newline]).trimmingCharacters(in: .whitespaces),
                String(trimmed[trimmed.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var installedTargets: [Target] {
        Self.targets.filter { target in
            URL(string: "\(target.scheme):").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        }
    }

    func send(to target: Target) {
        let (title, body) = Self.split(text)
        guard !title.isEmpty, let url = target.link(title, body, text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = target.activates
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ScratchpadWidget: View {
    @EnvironmentObject private var vm: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var note = ScratchpadText()
    /// After Clear, Undo in the ⋯'s place; each Clear its own, for its 5 seconds.
    @State private var undoClear: UUID?
    @State private var copied = false
    /// Counts copies, so an earlier one's timer doesn't cut a later "Copied" short.
    @State private var copies = 0
    @State private var closeWhenDone = false
    @State private var overflow = NoteOverflow()
    @Bindable private var pad = Scratchpad.shared
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                AloneFrame(widget: .scratchpad) {
                    AloneTitle(symbol: HomeWidget.scratchpad.symbol, title: HomeWidget.scratchpad.title)
                    if editing {
                        NotchTextButton(title: String(localized: "Done")) { finish() }
                    }
                } trailing: {
                    actions
                } row: {
                    editor
                        .frame(minWidth: 0, idealWidth: HomeWidget.scratchpad.width(HomeWidget.scratchpad.size, height: 0),
                               maxWidth: .infinity)
                        .frame(height: Self.aloneHeight)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    editor
                    footer
                }
            }
        }
        .foregroundStyle(.white)
        .background(NotchTextInputFocus(active: editing))
        .preference(key: ScratchpadEditingKey.self, value: editing)
        // Closing the notch ends editing and saves before its animation ends, so no keystroke lands in it.
        .onChange(of: vm.notchState) { _, state in if state == .closed { stopEditing() } }
        .onChange(of: pad.text) { _, text in if !text.isEmpty { undoClear = nil } }
        .onChange(of: pad.jump, initial: true) { _, jump in
            guard let jump, jump.island == ObjectIdentifier(vm) else { return }
            closeWhenDone = jump.closesWhenDone
            // Once the text view is in the island's window; until then the keyboard session leaves keys alone.
            DispatchQueue.main.async {
                note.focusAtEnd()
                pad.took(jump)
            }
        }
        .onDisappear { stopEditing() }
    }

    private static let aloneHeight: CGFloat = 42

    private var editor: some View {
        ScratchpadEditor(text: $pad.text, note: note, editing: editing, overflow: $overflow,
                         focused: { $0 ? startEditing() : stopEditing() }, escape: finish)
            // Not while typing: the line being typed can sit at an edge.
            .mask { NoteFade(overflow: editing ? NoteOverflow() : overflow) }
            .overlay(alignment: .topLeading) {
                if pad.text.isEmpty {
                    Text(String(localized: "Type a note…"))
                        .font(.notchBody)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(6)
            .background(.white.opacity(editing ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if editing {
                NotchTextButton(title: String(localized: "Done")) { finish() }
            }
            Spacer(minLength: 0)
            actions
        }
        .frame(height: 18)
    }

    @ViewBuilder private var actions: some View {
        if copied {
            Label(String(localized: "Copied"), systemImage: "checkmark")
                .font(.notchCaption)
                .foregroundStyle(.green)
        }
        if undoClear != nil {
            NotchTextButton(title: String(localized: "Undo")) { note.undo() }
                .accessibilityLabel(String(localized: "Undo Clear"))
        } else {
            menu
                .opacity(pad.text.isEmpty ? 0 : 1)
                .allowsHitTesting(!pad.text.isEmpty)
                .accessibilityHidden(pad.text.isEmpty)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pad.text.isEmpty)
        }
    }

    private var menu: some View {
        Menu {
            ForEach(pad.installedTargets) { target in
                Button(String(localized: "Send to \(target.name)")) { pad.send(to: target) }
                    .disabled(Scratchpad.split(pad.text).title.isEmpty)
            }
            if !pad.installedTargets.isEmpty { Divider() }
            Button(String(localized: "Copy")) { copy() }
            Button(String(localized: "Clear"), role: .destructive) { clear() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.notchSymbol(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Send, copy or clear the note"))
        .accessibilityLabel(String(localized: "Note actions"))
    }

    private func copy() {
        pad.copy()
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        withAnimation(reduceMotion ? nil : .snappy) { copied = true }
        copies += 1
        let copy = copies
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copies == copy { withAnimation(reduceMotion ? nil : .snappy) { copied = false } }
        }
    }

    /// Clears at once, with Undo for 5 seconds (and ⌘Z while typing). With VoiceOver on, Undo
    /// stays until there's text again.
    private func clear() {
        note.replaceAll(with: "")
        let clear = UUID()
        undoClear = clear
        AccessibilityNotification.Announcement(String(localized: "Note cleared")).post()
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if undoClear == clear { undoClear = nil }
        }
    }

    private func startEditing() {
        editing = true
        pad.editingIsland = vm
    }

    /// Typing's over (Done, Escape, a click elsewhere, the island closing). Only Done and Escape close the island.
    private func stopEditing() {
        closeWhenDone = false
        guard editing else { return }
        editing = false
        if pad.editingIsland === vm { pad.editingIsland = nil }
        note.resign()
        pad.flush()
    }

    private func finish() {
        let close = closeWhenDone && !vm.isPinned
        stopEditing()
        if close { vm.closeDeliberately() }
    }
}

struct ScratchpadEditingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

@MainActor
final class ScratchpadText {
    weak var view: NSTextView?

    func replaceAll(with string: String) {
        guard let view, view.string != string else { return }
        let all = NSRange(location: 0, length: (view.string as NSString).length)
        guard view.shouldChangeText(in: all, replacementString: string) else { return }
        view.replaceCharacters(in: all, with: string)
        view.didChangeText()
    }

    func undo() { view?.undoManager?.undo() }

    func focusAtEnd() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
        let end = NSRange(location: (view.string as NSString).length, length: 0)
        view.setSelectedRange(end)
        view.scrollRangeToVisible(end)
    }

    func resign() {
        guard let view, view.window?.firstResponder === view else { return }
        view.window?.makeFirstResponder(nil)
    }
}

/// Which edges of the note have more of it beyond them.
private struct NoteOverflow: Equatable {
    var above = false
    var below = false
}

/// Shows the note, fading out at an edge with more beyond it, so a line cut there reads as "more".
private struct NoteFade: View {
    let overflow: NoteOverflow

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [overflow.above ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
            Color.black
            LinearGradient(colors: [.black, overflow.below ? .clear : .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
        }
        .animation(.easeOut(duration: 0.2), value: overflow)
    }
}

/// AppKit's text view: a click puts the cursor where it lands even before the island has the
/// keyboard, each paragraph keeps its own direction, and the note has its own undo.
private struct ScratchpadEditor: NSViewRepresentable {
    @Binding var text: String
    let note: ScratchpadText
    let editing: Bool
    @Binding var overflow: NoteOverflow
    /// True on a click (before it's handled) or on focus; false when the note or the island lets go of the keyboard.
    let focused: (Bool) -> Void
    let escape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, overflow: $overflow) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        guard let view = scroll.documentView as? NoteTextView else { return scroll }
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 12)
        view.textColor = .white
        view.insertionPointColor = NSColor(Color.notchAccent)
        // No Writing Tools: their inline button (a Siri orb on macOS 27, even with .limited) covers the note.
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        view.string = text
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.setAccessibilityLabel(String(localized: "Scratchpad"))
        view.setAccessibilityPlaceholderValue(String(localized: "Type a note…"))
        context.coordinator.watch(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NoteTextView else { return }
        context.coordinator.text = $text
        context.coordinator.overflow = $overflow
        note.view = view
        view.focused = focused
        view.escape = escape
        view.acceptsDrops = editing
        view.toolTip = editing ? nil : String(localized: "Click to write")
        if view.string != text {
            // Changed in the island on another display: not undoable here.
            view.string = text
            context.coordinator.undo.removeAllActions()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        var overflow: Binding<NoteOverflow>
        /// Its own: the island's other text fields don't share it.
        let undo = UndoManager()
        private weak var scroll: NSScrollView?

        init(text: Binding<String>, overflow: Binding<NoteOverflow>) {
            self.text = text
            self.overflow = overflow
        }

        /// Scrolling, the text growing or shrinking, and the note resizing all change what's hidden.
        func watch(_ scroll: NSScrollView) {
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.postsFrameChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            center.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification, object: scroll)
            center.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification, object: scroll.documentView)
        }

        @objc private func changed() {
            guard let scroll, let document = scroll.documentView else { return }
            // The clip view is flipped like the text view: its bounds' top is how far the note is scrolled.
            let visible = scroll.contentView.bounds
            let now = NoteOverflow(above: visible.minY > 1, below: document.frame.height - visible.maxY > 1)
            guard now != overflow.wrappedValue else { return }
            // These can come during a layout pass, which mustn't change the view's state.
            DispatchQueue.main.async { [overflow] in overflow.wrappedValue = now }
        }

        /// Every change to the text, undo and redo too: AppKit's text-did-change
        /// doesn't come for those, and the note would keep (and save) what they undid.
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                if text.wrappedValue != textStorage.string { text.wrappedValue = textStorage.string }
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}

private final class NoteTextView: NSTextView {
    var focused: ((Bool) -> Void)?
    var escape: (() -> Void)?
    /// Drops only while typing: Home is where apps are dragged to Quick Launch.
    var acceptsDrops = false {
        didSet { if acceptsDrops != oldValue { updateDragTypeRegistration() } }
    }
    private var resignObserver: NSObjectProtocol?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateDragTypeRegistration() {
        if acceptsDrops { super.updateDragTypeRegistration() } else { unregisterDraggedTypes() }
    }

    /// The island lost the keyboard (a click in another app): typing's over, so a click back starts it again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focused?(false) }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        focused?(true)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focused?(true)
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focused?(false)
        return true
    }

    override func cancelOperation(_ sender: Any?) { escape?() }
}

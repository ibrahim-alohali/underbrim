//
//  ClipboardViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Clipboard tab: one row of cards, the search field in the header band beside the camera.
//

import Defaults
import SwiftUI

@MainActor @Observable
final class ClipboardBrowse {
    /// A new search starts from the first result (the field writes it again on Return).
    var query = "" { didSet { if query != oldValue { selectedID = nil } } }
    var searching = false
    /// Arrow keys move it, Return copies it. When it's gone (deleted, filtered out), the first
    /// result stands in.
    var selectedID: ClipboardEntry.ID?
    /// The card Return just copied, to show its "Copied" as a click does.
    var copiedByKey: ClipboardEntry.ID?
    /// The card a click or Return copied as it ended a search: the cards held under the pointer show it
    /// first, as they would a copy made elsewhere, also while an image's copy is still loading.
    var copiedAsSearchEnded: ClipboardEntry.ID?

    func selected(in items: [ClipboardEntry]) -> ClipboardEntry? {
        items.first { $0.id == selectedID } ?? items.first
    }

    func move(_ step: Int, in items: [ClipboardEntry]) -> ClipboardEntry? {
        guard let current = selected(in: items), let index = items.firstIndex(of: current) else { return nil }
        let next = items[min(max(index + step, 0), items.count - 1)]
        selectedID = next.id
        return next
    }

    func endSearch(copying id: ClipboardEntry.ID? = nil) {
        // Only a search with words changes the cards under the pointer; ending none (the island closing, say)
        // leaves a card copied as an earlier one ended where it is.
        if !query.isEmpty, let id { copiedAsSearchEnded = id }
        query = ""
        searching = false
        selectedID = nil
    }

    /// Not copied after all (an image's bytes were missing): it goes back among the held cards.
    func copyFailed(_ id: ClipboardEntry.ID) {
        if copiedAsSearchEnded == id { copiedAsSearchEnded = nil }
        NSSound.beep()
    }
}

/// Looks like a search field and starts a search (the notch takes keyboard focus only then).
struct ClipboardSearchField: View {
    /// Leaves room for the red Clear Unpinned Items button beside it without widening the header.
    static let width: CGFloat = 152
    @Environment(ClipboardBrowse.self) private var browse
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focused: Bool
    private let history = ClipboardHistory.shared

    var body: some View {
        @Bindable var browse = browse
        Group {
            if browse.searching {
                field {
                    TextField(String(localized: "Search clipboard"), text: $browse.query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(String(localized: "Search clipboard"))
                        .focused($focused)
                        // The way the arrow points on screen: the cards run right to left in Arabic.
                        .onKeyPress(.leftArrow) { move(layoutDirection == .rightToLeft ? 1 : -1) }
                        .onKeyPress(.rightArrow) { move(layoutDirection == .rightToLeft ? -1 : 1) }
                        // Return copies the highlighted card and hands the keyboard back, ready to paste.
                        .onSubmit {
                            let entry = browse.selected(in: history.filtered(browse.query))
                            browse.endSearch(copying: entry?.id)
                            if let entry {
                                history.copy(entry) { if $0 { browse.copiedByKey = entry.id } else { browse.copyFailed(entry.id) } }
                            }
                        }
                        .onExitCommand { browse.endSearch() }
                }
            } else {
                Button(action: start) {
                    field {
                        // Shrinks a little beside the paused or full badge.
                        Text(String(localized: "Search clipboard")).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        stateBadge
                    }
                }
                .buttonStyle(.plain)
                .notchDisabled(!history.browsable || history.entries.isEmpty)
            }
        }
        .background(NotchTextInputFocus(active: browse.searching))
        // The field lives exactly as long as the open header: closing ends any search.
        .onDisappear { browse.endSearch() }
    }

    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.notchSymbol(size: 11)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
        }
        .font(.notchBody)
        .padding(.horizontal, 8)
        .frame(width: Self.width, height: 24)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var stateBadge: some View {
        switch history.state {
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
                .help(String(localized: "Clipboard history is paused"))
                .accessibilityLabel(String(localized: "Paused"))
        case .storageFull:
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                .help(String(localized: "Storage full: pinned items fill the space, so nothing new is saved"))
                .accessibilityLabel(String(localized: "Storage full"))
        default:
            EmptyView()
        }
    }

    private func start() {
        browse.searching = true
        // Left set when the copied card was out of view, so it never showed.
        browse.copiedByKey = nil
        DispatchQueue.main.async { focused = true }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard let entry = browse.move(step, in: history.filtered(browse.query)) else { return .ignored }
        AccessibilityNotification.Announcement(entry.spokenDescription).post()
        return .handled
    }
}

struct NotchTextInputFocus: NSViewRepresentable {
    let active: Bool

    final class Coordinator {
        weak var window: NotchSkyLightWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard active else { return Self.release(coordinator) }
            // (Already true: a keyboard-opened notch, whose session owns focus.)
            guard let window = nsView.window as? NotchSkyLightWindow, !window.wantsKeyForTextInput else { return }
            coordinator.window = window
            window.wantsKeyForTextInput = true
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        release(coordinator)
    }

    /// Gives typing back to the app the user was in, also when the notch closes mid-search, so it
    /// never lands in the closed notch (taking key made this app active).
    private static func release(_ coordinator: Coordinator) {
        guard let window = coordinator.window else { return }
        coordinator.window = nil
        let hadFocus = window.isKeyWindow
        window.wantsKeyForTextInput = false
        if hadFocus { NSApp.deactivate() }
    }
}

struct ClipboardPanel: View {
    @EnvironmentObject private var vm: NotchViewModel
    @Environment(ClipboardBrowse.self) private var browse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let history = ClipboardHistory.shared
    /// Every card's place when the pointer came onto them, searched for or not. A pinned or copied card
    /// moves to the front once the pointer leaves, so the next click never lands on a different card.
    @State private var heldOrder: [ClipboardEntry.ID: Int]?
    /// The pointer has just left the cards: they're let go in a moment if the island is still open.
    @State private var lettingGo: Task<Void, Never>?

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: NotchMetrics.tabHeight)
            // The panel outlives the close for its transition; the keyboard and a query must not. The cards
            // keep their places as it folds away, and each opening starts in the history's own order.
            .onChange(of: vm.notchState) { _, state in
                switch state {
                case .closed:
                    browse.endSearch()
                    stopLettingGo()
                case .open:
                    heldOrder = nil
                    browse.copiedAsSearchEnded = nil
                }
            }
            .onChange(of: history.previewsHidden) { _, hidden in
                if hidden { browse.endSearch() }
            }
            .onDisappear {
                browse.endSearch()
                stopLettingGo()
                browse.copiedAsSearchEnded = nil
            }
            .onAppear { history.pruneExpired() }
    }

    @ViewBuilder private var content: some View {
        switch history.state {
        case .off:
            message(String(localized: "Clipboard history is off"), detail: String(localized: "Turn it on in Settings › Clipboard."),
                    symbol: "doc.on.clipboard", action: (String(localized: "Open Settings…"), { SettingsWindowController.shared.showWindow(tab: .clipboard) }))
        case .opening:
            message(String(localized: "Opening clipboard history"),
                    detail: String(localized: "If macOS asks about Underbrim's clipboard key, answer that dialog."),
                    symbol: "key", action: nil)
        case .keyUnavailable:
            message(String(localized: "History is locked"),
                    detail: String(localized: "Its encryption key couldn't be read, so nothing is shown or recorded."),
                    symbol: "lock.trianglebadge.exclamationmark",
                    action: (String(localized: "Open Settings…"), { SettingsWindowController.shared.showWindow(tab: .clipboard) }))
        case .storageFailed:
            message(String(localized: "History couldn't be read or saved"),
                    detail: String(localized: "It has stopped, and nothing was deleted. Turn it off and on in Settings to try again."),
                    symbol: "externaldrive.badge.exclamationmark",
                    action: (String(localized: "Open Settings…"), { SettingsWindowController.shared.showWindow(tab: .clipboard) }))
        case .accessDenied:
            message(String(localized: "macOS blocks clipboard access"),
                    detail: String(localized: "Allow it in System Settings › Privacy & Security › Paste from Other Apps."),
                    symbol: "hand.raised", action: nil)
        default:
            if history.previewsHidden {
                message(String(localized: "Unlock to see clipboard history"), detail: nil, symbol: "lock", action: nil)
            } else {
                let items = held(history.filtered(browse.query))
                if items.isEmpty {
                    message(browse.query.isEmpty ? String(localized: "Copied text, links and images appear here") : String(localized: "No matches"),
                            detail: nil, symbol: browse.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass", action: nil)
                } else {
                    let selected = browse.searching ? browse.selected(in: items)?.id : nil
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: NotchMetrics.cardSpacing) {
                                ForEach(items) { entry in
                                    ClipboardCard(entry: entry, selected: entry.id == selected)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .scrollsBeforePages()
                        .onChange(of: selected) { _, id in
                            if let id { withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(id) } }
                        }
                        .onHover { inside in
                            if inside { hold() } else { letGoSoon() }
                        }
                    }
                }
            }
        }
    }

    private func hold() {
        // Back on the cards before they were let go: they stay where they are.
        if lettingGo != nil { return stopLettingGo() }
        browse.copiedAsSearchEnded = nil
        heldOrder = Dictionary(uniqueKeysWithValues: history.entries.enumerated().map { ($1.id, $0) })
    }

    /// Lets the cards go once it's clear the island stays open: leaving it closes it at once, and cards
    /// sliding past each other as it folds away would only blur. The copied card goes with the others, in
    /// the same move, rather than first dropping back to its old place.
    private func letGoSoon() {
        stopLettingGo()
        lettingGo = Task {
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            lettingGo = nil
            guard vm.notchState == .open else { return }
            withAnimation(reduceMotion ? nil : .snappy) {
                browse.copiedAsSearchEnded = nil
                heldOrder = nil
            }
        }
    }

    private func stopLettingGo() {
        lettingGo?.cancel()
        lettingGo = nil
    }

    /// In the held order, with anything copied meanwhile first, where it would be anyway (a card copied as
    /// the search ended too: the cards around it change all the same).
    private func held(_ items: [ClipboardEntry]) -> [ClipboardEntry] {
        guard let heldOrder else { return items }
        let copied = browse.copiedAsSearchEnded
        func kept(_ entry: ClipboardEntry) -> Bool { heldOrder[entry.id] != nil && entry.id != copied }
        return items.filter { !kept($0) } + items.filter(kept).sorted { heldOrder[$0.id, default: 0] < heldOrder[$1.id, default: 0] }
    }

    private func message(_ title: String, detail: String?, symbol: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.notchBody)
                .foregroundStyle(.white)
            if let detail {
                Text(detail).font(.notchCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let action {
                NotchTextButton(title: action.0, action: action.1)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ClipboardCard: View {
    static let width: CGFloat = 112
    let entry: ClipboardEntry
    var selected = false
    @State private var thumbnail: NSImage?
    @State private var copied = false
    @State private var copies = 0
    @State private var hovering = false
    @Environment(ClipboardBrowse.self) private var browse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous) }

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
            .frame(width: Self.width, height: NotchMetrics.tabHeight)
            .background(hovering ? .notchRowHoverFill : .notchRowFill, in: shape)
            // The island's own black under the fill: the same at rest, and a card passing another as the row
            // reorders covers it instead of showing both texts.
            .background(.black, in: shape)
            .overlay { if selected { shape.strokeBorder(Color.notchAccent, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrag { ClipboardHistory.shared.itemProvider(for: entry) }
        .contextMenu {
            Button(String(localized: "Copy"), action: copy)
            Button(entry.pinned ? String(localized: "Unpin") : String(localized: "Pin")) { ClipboardHistory.shared.togglePin(entry) }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) { ClipboardHistory.shared.delete(entry) }
        }
        .task(id: entry.id) {
            if entry.kind == .image { thumbnail = await ClipboardHistory.shared.thumbnail(for: entry) }
        }
        .onChange(of: browse.copiedByKey) { _, id in
            guard id == entry.id else { return }
            browse.copiedByKey = nil
            showCopied()
        }
        .help(tooltip)
        // One element for VoiceOver; ignoring the children also drops the button's
        // own role and press, so both are restored here.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { copy() }
        .accessibilityLabel(entry.spokenDescription)
        .accessibilityHint(String(localized: "Copies it to the clipboard"))
        .accessibilityAction(named: entry.pinned ? String(localized: "Unpin") : String(localized: "Pin")) {
            ClipboardHistory.shared.togglePin(entry)
        }
        .accessibilityAction(named: String(localized: "Delete")) { ClipboardHistory.shared.delete(entry) }
    }

    /// The whole text, which the card cuts after four lines, then what a click does.
    private var tooltip: String {
        let hint = String(localized: "Click to copy · drag to drop it somewhere")
        guard entry.kind != .image, let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return hint }
        return (text.count > 500 ? text.prefix(500) + "…" : text) + "\n\n" + hint
    }

    private func copy() {
        // Mid-search, the keyboard goes back too, ready to paste.
        browse.endSearch(copying: entry.id)
        // "Copied" once it's there: an image's bytes can be missing.
        ClipboardHistory.shared.copy(entry) { worked in
            guard worked else { return browse.copyFailed(entry.id) }
            showCopied()
        }
    }

    private func showCopied() {
        // The buttons (or the time) go at once and the word fades in on its own (its transition):
        // fading out together, the word would sit over the buttons.
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        copies += 1
        let copy = copies
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            // Under the pointer the buttons come back at once, as on any hover, so the word goes at once too.
            if copies == copy { withAnimation(reduceMotion || hovering ? nil : .snappy) { copied = false } }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if entry.sourceBundleID == ClipboardHistory.anotherDevice {
                Image(systemName: "ipad.and.iphone").font(.system(size: 10)).frame(width: 13, height: 13)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            } else if let source = entry.sourceBundleID {
                AppIconView(bundleID: source, size: 13)
            }
            if copied {
                // About 38 pt beside a pinned card's pin mark: its own short word, shrinking a little.
                Label(String(localized: "Copied (clipboard card)", defaultValue: "Copied",
                             comment: "Flash on a clipboard card after a click: a short word, at most about 7 letters."),
                      systemImage: "checkmark")
                    .labelStyle(.titleAndIcon).foregroundStyle(.green).lineLimit(1).minimumScaleFactor(0.8)
                    .transition(.asymmetric(insertion: .opacity.animation(reduceMotion ? nil : .snappy), removal: .opacity))
            } else if !hovering {
                // Shrinks a little for the longest ("59 мин. назад") beside the pin mark.
                RelativeTimeText(date: entry.copiedAt).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if hovering && !copied {
                // What a click on the card does, as a button of its own beside the others.
                NotchSymbolButton(symbol: "doc.on.doc", label: String(localized: "Copy"), size: 11, box: 22,
                                  nameEdge: .trailing, nameAbove: true, action: copy)
                NotchSymbolButton(symbol: entry.pinned ? "pin.slash" : "pin",
                                  label: entry.pinned ? String(localized: "Unpin") : String(localized: "Pin"), size: 11, box: 22,
                                  nameEdge: .trailing, nameAbove: true) {
                    guard !NSEvent.isSecondClick else { return }
                    ClipboardHistory.shared.togglePin(entry)
                }
                NotchSymbolButton(symbol: "trash", label: String(localized: "Delete"), size: 11, box: 22,
                                  nameEdge: .trailing, nameAbove: true) {
                    // A double-click's second click would delete the card that slides in.
                    guard !NSEvent.isSecondClick else { return }
                    ClipboardHistory.shared.delete(entry)
                }
            } else if entry.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .font(.notchCaption)
        .frame(height: 22)
    }

    @ViewBuilder private var preview: some View {
        switch entry.content {
        case .image:
            // A clear frame takes exactly the room; the picture fills it and is cut to it.
            Color.clear
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: NotchMetrics.innerRadius,
                                              topTrailingRadius: NotchMetrics.innerRadius, style: .continuous))
        case .link(let text):
            let url = ClipboardPolicy.link(in: text)
            VStack(alignment: .leading, spacing: 2) {
                Label(url?.host(percentEncoded: false) ?? String(localized: "Link"), systemImage: "link")
                    .font(.notchCaption).foregroundStyle(.white).lineLimit(1)
                Text(url?.path(percentEncoded: false) ?? text).font(.notchCaption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding([.horizontal, .top], 8)
        case .text(let text):
            // Enough for its four lines, without laying out a long copy in full.
            Text(String(ClipboardPolicy.visibleStart(of: text).prefix(600)))
                .font(.notchCaption)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding([.horizontal, .top], 8)
        }
    }

}

extension ClipboardEntry {
    @MainActor var spokenDescription: String {
        let what: String = switch content {
        case .image(let size): size.map { String(localized: "Image, \(Int($0.width)) by \(Int($0.height)) pixels") }
            ?? String(localized: "Image")
        case .link(let text): String(localized: "Link \(text)")
        case .text(let text): String(localized: "Text \(String(ClipboardPolicy.visibleStart(of: text).prefix(80)))")
        }
        let source = sourceBundleID.flatMap(ClipboardHistory.appName).map { String(localized: "from \($0)") }
        let age = RelativeTimeText.string(for: copiedAt, now: .now)
        return [what, source, age, pinned ? String(localized: "pinned") : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

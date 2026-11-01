//
//  QuickLaunchWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Quick Launch in the notch: Home's grid, the pinned row and Settings' preview, with dragging,
//  adding and removing apps.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct QuickLaunchWidget: View {
    enum Style { case home, pinned, settings }

    nonisolated static let icon: CGFloat = 36
    nonisolated static let spacing: CGFloat = 8
    nonisolated static let corner: CGFloat = 26
    /// Pinned: one row of smaller icons just below the band, the dot under
    /// them and 1 pt to spare.
    nonisolated static let pinnedIcon: CGFloat = 27
    nonisolated static let pinnedHeight: CGFloat = pinnedIcon + 8
    nonisolated static let space = "quickLaunch"

    let columns: Int
    var style: Style = .home
    var apps: [String]?
    /// Shared by Home's and the pinned Quick Launch, so the apps fly to their places as it's pinned or unpinned.
    var namespace: Namespace.ID?

    private let model = QuickLaunch.shared
    @Default(.enableHaptics) private var haptics
    @Default(.quickLaunchBadges) private var showsBadges
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @State private var hovered: String?
    @State private var drag: Drag?
    @State private var settle: Settle?
    /// The app last let go of, drawn over the other apps: landing on the one it
    /// changes places with, it isn't hidden while that one moves off.
    @State private var landed: String?
    @State private var poof: Poof?
    @State private var dropSpot: Int?
    @State private var hold: Task<Void, Never>?
    @State private var dwell: Task<Void, Never>?
    @State private var holds = 0
    /// Home's apps lead the pinned row's flight once in sight a moment, and only if the pin hasn't
    /// changed since: Home lingers until the island's spring settles and would hold the row there.
    @State private var flies = false

    nonisolated static func width(columns: Int) -> CGFloat {
        CGFloat(columns) * icon + CGFloat(columns - 1) * spacing
    }

    private struct Item: Identifiable {
        let spot: Int
        let app: String
        var id: String { app }
    }

    private struct Drag {
        let app: String
        let from: Int
        let start: CGPoint
        let grab: CGSize
        var location: CGPoint
        var moved = false
        var held = false
        var target: Int?
        /// The target, its app shown in `from` while the pointer rests on it.
        var preview: Int?
        var removing = false
        var center: CGPoint { CGPoint(x: location.x - grab.width, y: location.y - grab.height) }
    }

    private struct Settle { let app: String; let offset: CGSize }
    private struct Poof { let app: String; let center: CGPoint; let size: CGFloat }

    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.3) }

    private var pressed: String? { drag.flatMap { $0.moved || $0.held ? nil : $0.app } }

    var body: some View {
        let shown = apps.map { Dictionary(uniqueKeysWithValues: zip(QuickLaunch.order(columns: columns), $0)) } ?? model.shown(columns: columns)
        let editing = apps == nil && (style == .settings || (style == .home && model.editing))
        let layout = QuickLaunchLayout(style: style, columns: columns, shown: shown, editing: editing, rightToLeft: direction == .rightToLeft)
        let items = shown.sorted { $0.key < $1.key }.map { Item(spot: $0.key, app: $0.value) }
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    guard style == .home else { return }
                    setEditing(!model.editing)
                    holds += 1
                }
                .contextMenu { if style != .settings { widgetMenu } }
                .environment(\.layoutDirection, direction)
            if items.isEmpty && !editing && style == .home && (0..<columns).contains(where: { model.spots[$0] == nil }) {
                Text(String(localized: "The apps you use most will show here"))
                    .font(.notchCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(width: layout.gridWidth, height: layout.height)
            }
            if editing {
                let open = model.openApps(besides: Set(shown.values))
                ForEach(layout.spots.filter { shown[$0] == nil || (drag?.moved == true && drag?.from == $0 && drag?.preview == nil) }, id: \.self) { spot in
                    well(spot, layout: layout, open: open)
                }
            }
            if let spot = ringSpot(shown: shown) {
                RoundedRectangle(cornerRadius: (layout.icon + 6) * 0.27, style: .continuous)
                    .strokeBorder(Color.notchAccent.opacity(0.85), lineWidth: 1.5)
                    .frame(width: layout.icon + 6, height: layout.icon + 6)
                    .allowsHitTesting(false)
                    .position(layout.center(spot))
                    .animation(.snappy(duration: 0.16), value: spot)
            }
            ForEach(items.filter { $0.app != landed } + items.filter { $0.app == landed }) { item in
                tile(item, layout: layout, shown: shown, editing: editing)
            }
            if editing {
                ForEach(items.filter { !(drag?.moved == true && drag?.app == $0.app) }) { item in minus(item, layout: layout) }
            }
            if style != .settings && apps == nil { buttons(layout) }
        }
        .frame(width: layout.width, height: layout.height)
        .environment(\.layoutDirection, .leftToRight)  // positions are worked out here, mirrored for right-to-left
        .coordinateSpace(name: Self.space)
        .anchorPreference(key: QuickLaunchFloatKey.self, value: .bounds) { anchor in
            floats(layout, shown: shown, editing: editing).map { QuickLaunchFloats(anchor: anchor, float: $0) }
        }
        .onDrop(of: [.fileURL], delegate: QuickLaunchDrop(spotAt: { layout.spot(at: $0) }, spot: $dropSpot) { providers, spot in
            model.drop(providers, at: spot)
        })
        .sensoryFeedback(trigger: drag?.target) { _, target in haptics && target != nil ? .alignment : nil }
        .sensoryFeedback(trigger: holds) { _, _ in haptics ? .levelChange : nil }
        .animation(motion, value: layout.rows)
        .onAppear {
            guard apps == nil else { return }
            // Settings doesn't reorder: a pinned row may be on screen.
            model.refreshSuggestions(reorder: style != .settings)
            if style != .settings { model.onScreen += 1 }
            if style == .home { model.gridOnScreen += 1 }
        }
        .onChange(of: columns) { model.refreshSuggestions(reorder: false) }
        .onDisappear {
            if apps == nil, style != .settings { model.onScreen -= 1 }
            if apps == nil, style == .home { model.gridOnScreen -= 1 }
            if style == .home { model.editing = false }
            model.focus = nil
            hovered = nil
            // Gone mid-drag (the island closed): the drag can't end, so it ends here.
            if drag != nil {
                drag = nil
                model.dragging = false
            }
        }
        .onHover { inside in if !inside, style == .pinned, drag == nil { model.refreshSuggestionsIfStale() } }
        .task(id: items.map(\.app)) { if apps == nil { await model.watch(items.map(\.app)) } }
        .task {
            let pins = model.pinChanges
            if style == .home, (try? await Task.sleep(for: .milliseconds(600))) != nil, model.pinChanges == pins { flies = true }
        }
        .frame(maxWidth: style == .pinned ? .infinity : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Quick Launch"))
    }

    private func setEditing(_ on: Bool) {
        withAnimation(motion) { model.editing = on }
    }

    private func ringSpot(shown: [Int: String]) -> Int? {
        if let drag, drag.moved { return drag.target == drag.from ? nil : drag.target }
        if let dropSpot { return dropSpot }
        if let focus = model.focus, shown[focus] != nil, style != .settings { return focus }
        return nil
    }

    // MARK: Apps

    private func tile(_ item: Item, layout: QuickLaunchLayout, shown: [Int: String], editing: Bool) -> some View {
        let suggested = apps == nil && model.spots[item.spot] == nil
        let lifted = drag?.moved == true && drag?.app == item.app
        let center = layout.center(drag?.preview == item.spot ? drag?.from ?? item.spot : item.spot)
        let name = AppInfo.name(bundleID: item.app) ?? item.app
        return QuickLaunchAppTile(app: item.app, size: layout.icon, pinned: style == .pinned, indicator: indicator(item.app),
                               badge: showsBadges ? model.badges[item.app] : nil, faded: editing && suggested,
                               hovered: hovered == item.app && drag == nil, pressed: pressed == item.app,
                               launching: model.launching.contains(item.app), pops: model.pops[item.app] ?? 0, dips: model.dips[item.app] ?? 0)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = item.app } else if hovered == item.app { hovered = nil }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { dragChanged(item, $0, layout: layout, shown: shown) }
                .onEnded { _ in dragEnded(item, layout: layout, editing: editing) })
            .contextMenu { tileMenu(item, suggested: suggested) }
            .environment(\.layoutDirection, direction)  // its menu reads in the user's language
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(state(item.app, suggested: suggested))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap(item, editing: editing) }
            .accessibilityActions {
                if suggested {
                    Button(String(localized: "Keep Here")) { withAnimation(motion) { model.keep(at: item.spot) } }
                }
                Button(String(localized: "Remove from Quick Launch")) { withAnimation(motion) { model.remove(at: item.spot) } }
                if style != .pinned {
                    ForEach(moves(item.spot), id: \.target) { move in
                        Button(move.title) { withAnimation(motion) { model.move(from: item.spot, to: move.target) } }
                    }
                }
            }
            .quickLaunchMatched(item.app, in: namespace, source: style != .pinned, active: style == .pinned || flies)
            .opacity(lifted ? 0 : 1)
            .scaleEffect(settle?.app == item.app && !reduceMotion ? QuickLaunchGhost.lift : 1)
            .offset(settle?.app == item.app ? settle?.offset ?? .zero : .zero)
            .position(center)
            .transition(appear(at: center, layout: layout))
    }

    private func appear(at center: CGPoint, layout: QuickLaunchLayout) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let anchor = UnitPoint(x: center.x / max(layout.width, 1), y: center.y / max(layout.height, 1))
        return .asymmetric(insertion: .scale(scale: 0.6, anchor: anchor).combined(with: .opacity),
                           removal: .scale(scale: 0.4, anchor: anchor).combined(with: .opacity))
    }

    private func indicator(_ app: String) -> QuickLaunchAppTile.Indicator {
        guard model.running.contains(app), !model.launching.contains(app) else { return .none }
        if model.hidden.contains(app) || model.minimized.contains(app) { return .away }
        return model.front == app ? .front : .open
    }

    private func state(_ app: String, suggested: Bool) -> String {
        var parts: [String] = []
        if model.launching.contains(app) {
            parts.append(String(localized: "Opening"))
        } else if model.running.contains(app) {
            parts.append(model.hidden.contains(app) ? String(localized: "Hidden")
                         : model.minimized.contains(app) ? String(localized: "Minimized")
                         : model.front == app ? String(localized: "In front") : String(localized: "Running"))
        }
        if showsBadges, let badge = model.badges[app] { parts.append(String(localized: "\(badge) unread")) }
        if suggested { parts.append(String(localized: "Suggested")) }
        return parts.joined(separator: ", ")
    }

    private struct Move { let title: String; let target: Int }

    private func moves(_ spot: Int) -> [Move] {
        let row = spot / QuickLaunch.rowLength, column = spot % QuickLaunch.rowLength
        let candidates = [
            (String(localized: "Move Left"), column > 0 ? spot - 1 : nil),
            (String(localized: "Move Right"), column + 1 < columns ? spot + 1 : nil),
            (String(localized: "Move Up"), row == 1 ? spot - QuickLaunch.rowLength : nil),
            (String(localized: "Move Down"), row == 0 ? spot + QuickLaunch.rowLength : nil),
        ]
        return candidates.compactMap { title, target in target.map { Move(title: title, target: $0) } }
    }

    private func tap(_ item: Item, editing: Bool) {
        if editing {
            if model.spots[item.spot] == nil { withAnimation(motion) { model.keep(at: item.spot) } }
            return
        }
        model.click(item.app)
    }

    private func dragChanged(_ item: Item, _ value: DragGesture.Value, layout: QuickLaunchLayout, shown: [Int: String]) {
        if drag?.start != value.startLocation {
            // A new press; one whose gesture was cancelled (its app went) is let go.
            if drag?.moved == true { model.dragging = false }
            dwell?.cancel()
            let center = layout.center(item.spot)
            drag = Drag(app: item.app, from: item.spot, start: value.startLocation,
                        grab: CGSize(width: value.startLocation.x - center.x, height: value.startLocation.y - center.y),
                        location: value.location)
            hold?.cancel()
            hold = Task {
                try? await Task.sleep(for: .milliseconds(500))
                // Held only where holding does something (Home's grid starts editing):
                // elsewhere a slow click is still a click.
                guard !Task.isCancelled, drag?.moved == false, style == .home, !model.editing else { return }
                drag?.held = true
                setEditing(true)
                holds += 1
            }
        }
        guard var current = drag else { return }
        current.location = value.location
        if !current.moved, hypot(value.translation.width, value.translation.height) > 4 {
            current.moved = true
            hold?.cancel()
            model.dragging = true
        }
        var previewEnds = false
        if current.moved {
            current.removing = !layout.area.insetBy(dx: -26, dy: -26).contains(value.location)
            let target = current.removing ? nil : layout.spot(at: value.location)
            if target != current.target {
                current.target = target
                previewEnds = current.preview != nil
                dwell?.cancel()
                if let target, target != current.from, shown[target] != nil {
                    dwell = Task {
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        withAnimation(motion) { drag?.preview = target }
                    }
                }
            }
        }
        drag = current
        if previewEnds { withAnimation(motion) { drag?.preview = nil } }
    }

    private func dragEnded(_ item: Item, layout: QuickLaunchLayout, editing: Bool) {
        hold?.cancel()
        dwell?.cancel()
        guard let ended = drag, ended.app == item.app else {
            drag = nil
            model.dragging = false
            return
        }
        model.dragging = false
        guard ended.moved else {
            drag = nil
            if !ended.held { tap(item, editing: editing) }
            return
        }
        if ended.removing {
            poof = Poof(app: ended.app, center: ended.center, size: layout.icon)
            drag = nil
            withAnimation(motion) { model.remove(at: ended.from) }
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                if poof?.app == ended.app { poof = nil }  // not another removal's, begun meanwhile
            }
            return
        }
        // Let go: the icon springs from where it is into its spot. Its place
        // moves from `from` to there on the same spring, so the offset is from `from`.
        let destination = ended.target ?? ended.from
        let start = layout.center(ended.from)
        settle = Settle(app: ended.app, offset: CGSize(width: ended.center.x - start.x, height: ended.center.y - start.y))
        landed = ended.app
        drag = nil
        if destination != ended.from { withAnimation(motion) { model.move(from: ended.from, to: destination) } }
        Task { withAnimation(.snappy(duration: 0.23)) { settle = nil } }  // once it has drawn there
    }

    // MARK: Menus

    @ViewBuilder private func tileMenu(_ item: Item, suggested: Bool) -> some View {
        Button(String(localized: "Show in Finder")) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.app) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        if let app = QuickLaunch.runningApp(item.app) {
            Button(String(localized: "Hide")) { app.hide() }
                .disabled(app.isHidden)
            if #available(macOS 15.0, *) {
                Button(String(localized: "Quit")) { app.terminate() }
                    .modifierKeyAlternate(.option) { Button(String(localized: "Force Quit")) { app.forceTerminate() } }
            } else {
                Button(String(localized: "Quit")) { app.terminate() }
            }
        }
        Divider()
        if suggested {
            Button(String(localized: "Keep Here")) { withAnimation(motion) { model.keep(at: item.spot) } }
        }
        Button(String(localized: "Remove from Quick Launch")) { withAnimation(motion) { model.remove(at: item.spot) } }
        if style != .settings {
            Divider()
            widgetMenu
        }
    }

    @ViewBuilder private var widgetMenu: some View {
        Button(model.pinned ? String(localized: "Unpin \(HomeWidget.quickLaunch.title)") : String(localized: "Pin Alone")) {
            model.setPinned(!model.pinned)
        }
        if style == .home {
            Button(model.editing ? String(localized: "Done Editing") : String(localized: "Edit Quick Launch")) { setEditing(!model.editing) }
        }
        Button(String(localized: "Quick Launch Settings…")) { SettingsWindowController.shared.showWindow(tab: .widgets) }
        if style == .home {
            EditWidgetsButton()
        }
    }

    private func well(_ spot: Int, layout: QuickLaunchLayout, open: [String]) -> some View {
        let row = spot / QuickLaunch.rowLength + 1, column = spot % QuickLaunch.rowLength + 1
        return Menu {
            Section(String(localized: "Add to Row \(row), Spot \(column)")) {
                if open.isEmpty { Text(String(localized: "No other apps are open")) }
                ForEach(open, id: \.self) { id in
                    Button { withAnimation(motion) { model.place(id, at: spot) } } label: {
                        Label { Text(AppInfo.name(bundleID: id) ?? id) } icon: { menuIcon(id) }
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            Divider()
            Button(String(localized: "Choose Another App…")) { model.pickApp(for: spot) }
            if spot < QuickLaunch.rowLength, model.spots[spot] != nil {
                Button(String(localized: "Let Quick Launch Suggest")) { withAnimation(motion) { model.suggest(at: spot) } }
            }
        } label: {
            QuickLaunchWell(size: layout.icon)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .environment(\.layoutDirection, direction)
        .frame(width: layout.icon, height: layout.icon)
        .accessibilityLabel(String(localized: "Empty spot, row \(row), spot \(column)"))
        .position(layout.center(spot))
        .transition(.opacity)
    }

    /// Kept: the add menus are rebuilt on every redraw while editing (a drag redraws per frame).
    private static var menuIcons: [String: Image] = [:]

    private func menuIcon(_ id: String) -> Image {
        if let icon = Self.menuIcons[id] { return icon }
        guard let image = appIconAsNSImage(for: id)?.copy() as? NSImage else { return Image(systemName: "app") }
        image.size = NSSize(width: 16, height: 16)
        let icon = Image(nsImage: image)
        Self.menuIcons[id] = icon
        return icon
    }

    private func minus(_ item: Item, layout: QuickLaunchLayout) -> some View {
        let center = layout.minusCenter(item.spot)
        return Button { withAnimation(motion) { model.remove(at: item.spot) } } label: {
            Circle().fill(Color(white: 0.37))
                .overlay(Capsule().fill(.white).frame(width: 8, height: 2))
                .frame(width: 16, height: 16)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Remove from Quick Launch"))
        .accessibilityLabel(String(localized: "Remove \(AppInfo.name(bundleID: item.app) ?? item.app)"))
        .position(center)
        .transition(appear(at: center, layout: layout))
    }

    @ViewBuilder private func buttons(_ layout: QuickLaunchLayout) -> some View {
        if style == .home {
            NotchSymbolButton(symbol: model.editing ? "checkmark" : "pencil",
                              label: model.editing ? String(localized: "Done Editing") : String(localized: "Edit Quick Launch"),
                              size: 12, box: 22, tint: model.editing ? .notchAccent : nil) {
                setEditing(!model.editing)
            }
            .position(layout.editCenter)
        }
    }

    // MARK: Over the island

    private func floats(_ layout: QuickLaunchLayout, shown: [Int: String], editing: Bool) -> QuickLaunchFloat? {
        if let poof { return .poof(poof.app, center: poof.center, size: poof.size) }
        if let drag, drag.moved { return .ghost(drag.app, center: drag.center, size: layout.icon, removing: drag.removing) }
        // Let go, the name waits for the icon to have its place, rather than sliding over from where it was.
        guard let hovered, pressed == nil, settle == nil, let spot = shown.first(where: { $0.value == hovered })?.key else { return nil }
        let name = AppInfo.name(bundleID: hovered) ?? hovered
        let origin = layout.origin(spot)
        return .name(editing && model.spots[spot] == nil ? String(localized: "Keep \(name) Here") : name,
                     at: CGPoint(x: origin.x + layout.icon / 2, y: origin.y + layout.icon + 2), belowIsland: style == .pinned)
    }
}

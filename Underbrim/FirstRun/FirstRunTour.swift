//
//  FirstRunTour.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The first run, inside the notch: a light runs once along the rim, the notch opens on a welcome
//  card and a short tour follows. Skippable at every step, silent, still under Reduce Motion. Text
//  is laid out at its final size from the start, so nothing reflows while the notch opens.
//

import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

// MARK: - The mark

struct UnderbrimMark: View {
    var body: some View {
        let accent = Color.notchAccent
        Canvas { canvas, size in
            let line: CGFloat = 1.6
            let top = line / 2, flare: CGFloat = 3, corner: CGFloat = 5
            let left = size.width * 0.27, right = size.width * 0.73, bottom = size.height * 0.62
            var edge = Path()
            edge.move(to: CGPoint(x: line, y: top))
            edge.addLine(to: CGPoint(x: left - flare, y: top))
            edge.addQuadCurve(to: CGPoint(x: left, y: top + flare), control: CGPoint(x: left, y: top))
            edge.addLine(to: CGPoint(x: left, y: bottom - corner))
            edge.addQuadCurve(to: CGPoint(x: left + corner, y: bottom), control: CGPoint(x: left, y: bottom))
            edge.addLine(to: CGPoint(x: right - corner, y: bottom))
            edge.addQuadCurve(to: CGPoint(x: right, y: bottom - corner), control: CGPoint(x: right, y: bottom))
            edge.addLine(to: CGPoint(x: right, y: top + flare))
            edge.addQuadCurve(to: CGPoint(x: right + flare, y: top), control: CGPoint(x: right, y: top))
            edge.addLine(to: CGPoint(x: size.width - line, y: top))
            canvas.stroke(edge, with: .color(.white), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))

            var brim = Path()
            brim.move(to: CGPoint(x: left + corner, y: bottom + 3.5))
            brim.addLine(to: CGPoint(x: right - corner, y: bottom + 3.5))
            var glow = canvas
            glow.addFilter(.blur(radius: 3.5))
            glow.stroke(brim, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            canvas.stroke(brim, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .frame(width: 46, height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: - The tour

struct FirstRunTour: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var coordinator = NotchViewCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var arrived = false
    /// The last step's "Open Underbrim when you log in", applied when done: ticked on a first run.
    @State private var openAtLogin = NotchViewCoordinator.shared.firstLaunch || LaunchAtLogin.isEnabled
    @Default(.prayerPlace) private var place
    @Default(.prayerTimesEnabled) private var prayer
    @Default(.soundBoost) private var boost

    private enum Page { case welcome, opening, home, pin, shelf, sound, prayer, picks, settings }
    /// In order; the Sound page's only where its tab can show. Kept for the tour's length, so a
    /// setting changed meanwhile can't move the steps under it.
    @State private var pages: [Page]
    /// Skipped from the welcome card to the setup steps, which then have no Skip of their own: it would
    /// sit where the first one was, and a second press would leave everything off.
    @State private var tourSkipped = false
    private var last: Int { pages.count - 1 }
    static let width: CGFloat = 460

    init() {
        _pages = State(initialValue: [.welcome, .opening, .home, .pin, .shelf] + (NotchViews.sound.isOn ? [.sound] : [])
                       + [.prayer, .picks, .settings])
    }

    var body: some View {
        VStack(spacing: 0) {
            corners
            Group {
                switch pages[step] {
                case .welcome: welcome
                case .opening: opening
                case .home: card(symbol: "house", title: String(localized: "Home"),
                             text: String(localized: "What's playing, your calendar and your widgets. Choose them with the widgets button at the top."))
                case .pin:
                    VStack(spacing: 12) {
                        card(symbol: "pin", title: String(localized: "Press and hold a widget to pin it"),
                             text: vm.floating == nil
                                 ? String(localized: "Press and hold any Home widget and the notch keeps just that one, slim, beside the camera. Press and hold it again to unpin it.")
                                 : String(localized: "Press and hold any Home widget and the island keeps just that one, slim. Press and hold it again to unpin it."))
                        FirstRunPinPreview()
                    }
                case .shelf: card(symbol: "tray", title: String(localized: "Shelf"),
                                  text: vm.floating == nil
                                      ? String(localized: "Drop files on the notch to keep them for later, or to AirDrop and share them.")
                                      : String(localized: "Drop files on the island to keep them for later, or to AirDrop and share them."))
                case .sound:
                    VStack(spacing: 12) {
                        card(symbol: "slider.horizontal.3", title: String(localized: "A volume for each app"),
                             text: boost ? String(localized: "In the Sound tab, every app playing sound gets its own slider, up to \(2.0.formatted(.percent)). Click an app's icon to mute it. The first time, macOS asks for System Audio Recording permission.")
                                 : String(localized: "In the Sound tab, every app playing sound gets its own slider. Click an app's icon to mute it. The first time, macOS asks for System Audio Recording permission."))
                        FirstRunMixerPreview()
                    }
                case .prayer: FirstRunPrayer()
                case .picks: FirstRunPicks()
                case .settings:
                    VStack(spacing: 10) {
                        card(symbol: "gearshape", title: String(localized: "Everything else is in Settings"),
                             text: vm.floating == nil
                                 ? String(localized: "Open it from Underbrim's menu bar icon, or by right-clicking the notch.")
                                 : String(localized: "Open it from Underbrim's menu bar icon, or by right-clicking the island."))
                        FirstRunCheckbox(title: String(localized: "Open Underbrim when you log in"), isOn: $openAtLogin)
                    }
                }
            }
            .id(step)
            .transition(StandardAnimations.pageChange(entering: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))))
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .top)

            if step > 0 { controls.padding(.top, 12) }
        }
        .frame(width: Self.width)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        // On the lock screen it keeps its step for after unlocking, dimmed: no one may answer it there.
        .disabled(coordinator.screenLocked)
        .opacity(coordinator.screenLocked ? 0.5 : 1)
    }

    /// How it opens: pointing at the notch, at the top centre where nothing shows while idle (a floating
    /// island), or, beside Apple's island, from the menu bar icon or the shortcut.
    private var opening: some View {
        // The shortcut as set now (the tour also runs from About, after it may have changed). Left to
        // right inside Arabic too, or the keys come out backwards ("I⌘⇧").
        let keys = KeyboardShortcuts.getShortcut(for: .toggleNotchOpen).map { "\u{2066}\($0.description)\u{2069}" }
        if vm.floating?.besideAppleIsland == true {
            return card(symbol: "menubar.arrow.up.rectangle", title: String(localized: "Open it from the menu bar icon"),
                        text: keys.map { String(localized: "Apple's island keeps the top of the screen, so Underbrim opens from its menu bar icon, or with \($0).") }
                            ?? String(localized: "Apple's island keeps the top of the screen, so Underbrim opens from its menu bar icon."))
        }
        if vm.floating != nil {
            return card(symbol: "cursorarrow.rays", title: String(localized: "It opens when you point at the top centre"),
                        text: keys.map { String(localized: "Nothing shows there until something happens. It closes when you move away. A click, or \($0), opens it too.") }
                            ?? String(localized: "Nothing shows there until something happens. It closes when you move away. A click opens it too."))
        }
        return card(symbol: "cursorarrow.rays", title: String(localized: "The notch opens when you point at it"),
                    text: keys.map { String(localized: "It closes when you move away. A click, or \($0), opens it too.") }
                        ?? String(localized: "It closes when you move away. A click opens it too."))
    }

    private func arrival(_ index: Int) -> some ViewModifier {
        Arrival(shown: arrived, delay: 0.08 * Double(index), reduceMotion: reduceMotion)
    }

    private var corners: some View {
        HStack {
            if step > 0 {
                HStack(spacing: 5) {
                    ForEach(1..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(.white.opacity(index == step ? 0.9 : 0.25))
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Step \(step) of \(pages.count - 1)"))
            }
            Spacer()
            if step < last && !tourSkipped {
                Button(String(localized: "Skip")) { skip() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(FirstRunSecondaryStyle(height: 22))
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            UnderbrimMark().modifier(arrival(0))
            Text("Welcome to Underbrim")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 10)
                .modifier(arrival(1))
            Text("Everything you need, right at the top of your screen.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 4)
                .modifier(arrival(2))
            Button(String(localized: "Start")) { go(1) }
                .buttonStyle(NotchProminentStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 16)
                .modifier(arrival(3))
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { arrived = true }
    }

    private func card(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.notchAccent)
                .frame(height: 26)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if step > 1 {
                Button(String(localized: "Back")) { go(step - 1) }
                    .buttonStyle(FirstRunSecondaryStyle())
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                if pages[step] == .prayer, !(prayer && place != nil) {
                    // No place yet: prayer times stay off, and Home has no tile asking for one.
                    Button(String(localized: "Not Now")) {
                        prayer = false
                        go(step + 1)
                    }
                    .buttonStyle(FirstRunSecondaryStyle())
                } else if step < last {
                    Button(String(localized: "Next")) { go(step + 1) }
                        .buttonStyle(NotchProminentStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: "Open Settings")) {
                        finish()
                        SettingsWindowController.shared.showWindow()
                    }
                    .buttonStyle(FirstRunSecondaryStyle())
                    Button(String(localized: "Done")) { finish() }
                        .buttonStyle(NotchProminentStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func go(_ next: Int) {
        // The next step's button can sit where this one was.
        guard !NSEvent.isSecondClick else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) { step = next }
    }

    /// On a first run, Skip on the welcome card skips the tour but not the setup: what to turn on,
    /// and the login item.
    private func skip() {
        // A quick double-click can reach this button again before the setup step replaces it.
        guard !NSEvent.isSecondClick else { return }
        guard step == 0, coordinator.firstLaunch else { return finish() }
        pages = [.welcome, .picks, .settings]
        tourSkipped = true
        go(1)
    }

    /// Closing ends the tour (NotchViewModel.close). The login item from the last step, or the first
    /// run's default when it ends earlier.
    private func finish() {
        if step == last || coordinator.firstLaunch { LaunchAtLogin.isEnabled = openAtLogin }
        vm.close()
    }
}

private struct Arrival: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 8)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .animation(.easeOut(duration: reduceMotion ? 0.25 : 0.62).delay(0.55 + delay), value: shown)
    }
}

private struct FirstRunSecondaryStyle: ButtonStyle {
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height < 28 ? 11 : 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, height < 28 ? 10 : 16)
            .frame(height: height)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

private struct FirstRunCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.notchAccent : .white.opacity(0.5))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
        // A switch, as the Settings islands' are.
        .accessibilityAddTraits(.isToggle)
        // A new element, so the button's own press is gone: VoiceOver's needs this.
        .accessibilityAction { isOn.toggle() }
    }
}

// MARK: - Prayer times

private struct FirstRunPrayer: View {
    @Default(.prayerPlace) private var place
    @Default(.prayerTimesEnabled) private var enabled
    @State private var search = TownSearch(animation: StandardAnimations.open)
    @State private var choosing = false
    /// A town being looked up; left behind (Not Now, Back), it mustn't turn prayer times on.
    @State private var picking: Task<Void, Never>?
    @FocusState private var typing: Bool
    private var store: PrayerTimesStore { .shared }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.stars")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.notchAccent)
                .frame(height: 26)
            Text("Prayer times").font(.system(size: 16, weight: .semibold))
            Text("For where you are, with each adhan in the notch.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Group {
                if let place, enabled, !choosing {
                    chosen(place)
                } else if store.locating {
                    Label(String(localized: "Finding your location…"), systemImage: "location.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(height: 30)
                } else if choosing || store.locationError != nil {
                    townSearch
                } else {
                    HStack(spacing: 8) {
                        // Through the store, which also puts back the Home widget an earlier Not Now took off.
                        // Not orange: it isn't the way on, and it asks for the location.
                        Button { store.turnOn(); store.locate() } label: {
                            Label(String(localized: "Use My Location"), systemImage: "location.fill")
                        }
                        .buttonStyle(FirstRunSecondaryStyle())
                        Button(String(localized: "Choose a Town…")) { withAnimation(StandardAnimations.open) { choosing = true } }
                            .buttonStyle(FirstRunSecondaryStyle())
                    }
                }
            }
            .padding(.top, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { picking?.cancel() }
    }

    private func chosen(_ place: PrayerPlace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.notchAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                // Two lines if need be: the method's name can leave no room for the time.
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(String(localized: "Change")) { withAnimation(StandardAnimations.open) { choosing = true } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.notchAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 360)
        .frame(minHeight: 44)
        .background(Color.notchRowFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var detail: String {
        guard let next = store.next else { return store.method.name }
        return String(localized: "\(store.method.name) · Next: \(next.title) at \(PrayerFormat.time(next.at, PrayerFormat.zone(store.place)))")
    }

    private var townSearch: some View {
        VStack(spacing: 4) {
            if let error = store.locationError, !choosing {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.4))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.bottom, 2)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField(String(localized: "Search for a town"), text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .accessibilityLabel(String(localized: "Search for a town"))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(width: 320, height: 28)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.notchAccent.opacity(typing ? 0.8 : 0), lineWidth: 1))
            if search.nothingFound {
                Text("No towns found").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(height: 26)
            }
            ForEach(search.results.prefix(4), id: \.self) { result in
                Button {
                    picking = Task {
                        let picked = await search.place(for: result)
                        guard !Task.isCancelled else { return }
                        guard let picked else { return NSSound.beep() }
                        store.turnOn()
                        place = picked
                        search.query = ""
                        choosing = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.white.opacity(0.6))
                        Text(result.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 320, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // A turn later: on the step's own appearance the field can't take focus yet.
        .task { typing = true }
    }
}

// MARK: - What to turn on

private struct FirstRunPicks: View {
    @Default(.realtimeAudioWaveform) private var waveform
    @Default(.clipboardHistoryEnabled) private var clipboard
    @Default(.osdReplacement) private var hud
    @Default(.showPhoneActivities) private var phone
    @Default(.showAgentActivity) private var agents
    @Default(.showFocusChanges) private var focus
    @Default(.showCapsLock) private var capsLock

    var body: some View {
        VStack(spacing: 8) {
            Text("Turn on what you want")
                .font(.system(size: 16, weight: .semibold))
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                // First: what many come for, and off until turned on.
                GridRow {
                    tile("terminal", String(localized: "Coding agents"),
                         String(localized: "Claude Code, Codex, Cursor and more, while they work."), isOn: $agents)
                        .gridCellColumns(2)
                }
                GridRow {
                    // Asks as the step goes (below), so ticked from the start it asks too.
                    tile("waveform", String(localized: "Real-time audio waveform"),
                         String(localized: "Moves with what's playing. Asks to capture audio."), isOn: $waveform)
                    tile("doc.on.clipboard", String(localized: "Clipboard history"),
                         String(localized: "What you copy, encrypted on this Mac."), recommended: true, isOn: $clipboard)
                }
                GridRow {
                    // Focus and Caps Lock need the same permission, so they come and go with it.
                    tile("speaker.wave.2", String(localized: "Volume and brightness"),
                         FocusWatcher.isSupported
                             ? String(localized: "Replaces macOS's own, plus Focus and Caps Lock. Asks for \(AccessibilityPermission.displayName).")
                             : String(localized: "Replaces macOS's own, plus Caps Lock. Asks for \(AccessibilityPermission.displayName)."),
                         recommended: true, isOn: Binding(get: { hud }, set: { on in
                             hud = on
                             capsLock = on
                             if FocusWatcher.isSupported { focus = on }
                             if on { Task { await MediaKeyInterceptor.shared.start(promptIfNeeded: true) } }
                         }))
                    tile("iphone", String(localized: "iPhone Live Activities"),
                         String(localized: "Deliveries, rides and scores. Asks for \(AccessibilityPermission.displayName)."), isOn: Binding(get: { phone }, set: { on in
                             phone = on
                             if on { Task { _ = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true) } }
                         }))
                }
            }
        }
        // Gone with the waveform ticked, by a button or the island closing: macOS asks now rather than at
        // the first song. Its check goes off the main thread.
        .onDisappear {
            guard waveform, #available(macOS 14.2, *) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard SoundMixer.currentAccess() == .notAsked else { return }
                Task { @MainActor in SoundMixer.shared.requestAccess() }
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ detail: String, recommended: Bool = false,
                      isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue || recommended ? Color.notchAccent : .white.opacity(0.6))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn.wrappedValue ? Color.notchAccent : .white.opacity(0.35))
            }
            .padding(8)
            .padding(.top, recommended ? 10 : 0)
            .frame(width: 222)
            .frame(minHeight: 46)
            .background(Color.notchRowFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .top) { if recommended { RecommendedTag() } }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recommended ? "\(title), \(String(localized: "Recommended"))" : title)
        .accessibilityHint(detail)
        .accessibilityValue(isOn.wrappedValue ? String(localized: "On") : String(localized: "Off"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { isOn.wrappedValue.toggle() }
    }
}

private struct RecommendedTag: View {
    var body: some View {
        let island = IslandShape(topRadius: 4, bottomRadius: 7)
        Text("Recommended")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 15)
            .background(.black, in: island)
            .overlay {
                island.stroke(Color.notchAccent.opacity(0.9), lineWidth: 1)
                    .mask(Rectangle().padding(.top, 2))
                    .shadow(color: Color.notchAccent.opacity(0.8), radius: 3)
            }
            .accessibilityHidden(true)
    }
}

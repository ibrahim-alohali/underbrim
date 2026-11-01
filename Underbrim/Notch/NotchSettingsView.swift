//
//  NotchSettingsView.swift
//  Underbrim
//
//  Created by Alexander on 2026-09-21.
//

//  The notch's settings: how it opens and where it shows on General, the rest
//  (its size, delays, animation, window, and which display it's on) on Advanced.
//

import Defaults
import SwiftUI

struct NotchSettingsSection: View {
    @Default(.compactMode) private var compactMode
    @Default(.compactWidget) private var compactWidget
    @Default(.hideFromScreenRecording) private var hideFromScreenRecording
    @Default(.hideWhileScreenShared) private var hideWhileScreenShared
    @Default(.seenDisplayWithoutNotch) private var seenDisplayWithoutNotch

    private enum CaptureHiding: Hashable { case never, whileShared, always }

    /// Always is the original switch; while sharing is a second one, used when that's off.
    private var captureHiding: Binding<CaptureHiding> {
        Binding {
            hideFromScreenRecording ? .always : hideWhileScreenShared ? .whileShared : .never
        } set: { choice in
            hideFromScreenRecording = choice == .always
            hideWhileScreenShared = choice == .whileShared
        }
    }

    var body: some View {
        Section {
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            .settingsItem("Open notch on hover")
            Defaults.Toggle(key: .compactMode) {
                SettingsLabel("Compact mode", info: "Shows a smaller opened notch with one widget and no tabs. Two fingers sideways on it move through the widgets that are on.")
            }
            .settingsItem("Compact mode")
            if compactMode {
                // The widgets that are on (and Now Playing): one that's turned off shows Now Playing.
                Picker("Compact island shows", selection: Binding(
                    get: { HomeWidget.compactChoices.contains(compactWidget) ? compactWidget : .nowPlaying },
                    set: { compactWidget = $0 }
                )) {
                    ForEach(HomeWidget.compactChoices) { widget in
                        Label(widget.title, systemImage: widget.symbol).tag(widget)
                    }
                }
                .settingsItem("Compact island shows")
            }
            Defaults.Toggle(key: .showOnAllDisplays) {
                Text("Show on all displays")
            }
            .settingsItem("Show on all displays")
            // Once there's been one: on a Mac that's only ever had its notch, the choice means nothing.
            if seenDisplayWithoutNotch {
                NonNotchStylePicker()
                    .settingsItem("Displays without a notch")
            }
            Defaults.Toggle(key: .showOnLockScreen) {
                Text("Show notch on lock screen")
            }
            .settingsItem("Show notch on lock screen")
            Picker(selection: captureHiding) {
                Text("Never").tag(CaptureHiding.never)
                Text("While sharing or recording").tag(CaptureHiding.whileShared)
                Text("Always").tag(CaptureHiding.always)
            } label: {
                SettingsLabel("Hide from screen sharing and recording",
                              info: "While sharing or recording, screenshots still show the notch. Always keeps it out of screenshots too.")
            }
            .settingsItem("Hide from screen sharing and recording")
        } header: {
            Text("Notch")
        }
    }
}

/// Displays without a notch: the floating island or the tab, each with a picture of the top of the screen.
private struct NonNotchStylePicker: View {
    @Default(.nonNotchStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsLabel("Displays without a notch",
                          info: "External displays, iMacs, Mac minis and Macs without a camera notch. The island floats just below the top edge while something's happening, and pointing at the top centre opens it. The notch stays at the top all the time; its height is in Advanced.")
            HStack(spacing: 10) {
                ForEach(NonNotchStyle.allCases) { choice in
                    tile(choice)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Displays without a notch"))
    }

    private func tile(_ choice: NonNotchStyle) -> some View {
        let chosen = style == choice
        return Button {
            style = choice
        } label: {
            VStack(spacing: 7) {
                SettingsStage(height: 40) { picture(choice) }
                HStack(spacing: 5) {
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(chosen ? Color.effectiveAccent : .secondary)
                        .accessibilityHidden(true)
                    Text(title(choice))
                }
                .font(.system(size: 12, weight: .medium))
            }
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(chosen ? Color.effectiveAccent : Color.primary.opacity(0.09), lineWidth: chosen ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title(choice)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func title(_ choice: NonNotchStyle) -> LocalizedStringKey {
        switch choice {
        case .island: "Island"
        case .notch: "Notch"
        }
    }

    /// The menu bar's band (22 pt) with what sits in its middle: a capsule playing a song, or the tab.
    @ViewBuilder private func picture(_ choice: NonNotchStyle) -> some View {
        switch choice {
        case .island:
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(red: 0.35, green: 0.47, blue: 0.6))
                    .frame(width: 9, height: 9)
                Capsule().fill(.white.opacity(0.8)).frame(width: 34, height: 3)
                Spacer(minLength: 0)
                HStack(spacing: 1.5) {
                    ForEach([5.0, 8, 4], id: \.self) { height in
                        Capsule().fill(Color(red: 0.62, green: 0.71, blue: 0.83)).frame(width: 1.6, height: height)
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(width: 84, height: 15)
            .background(.black, in: Capsule())
            .padding(.top, 3.5)
        case .notch:
            IslandShape(topRadius: 4, bottomRadius: 8)
                .fill(.black)
                .frame(width: 64, height: 22)
        }
    }
}

struct NotchAdvancedSettings: View {
    @ObservedObject var coordinator = NotchViewCoordinator.shared

    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.closeDelay) private var closeDelay
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.nonNotchStyle) private var nonNotchStyle
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.enableOpeningAnimation) var enableOpeningAnimation
    @Default(.animationSpeedMultiplier) var animationSpeedMultiplier
    @Default(.shelfEnabled) private var shelfOn
    @Default(.clipboardHistoryEnabled) private var clipboardOn
    @Default(.showAgentActivity) private var agentsOn

    var body: some View {
        Section {
            Picker(
                selection: $notchHeightMode,
                label:
                    Text("Notch height on notch displays")
            ) {
                Text("Match real notch height")
                    .tag(WindowHeightMode.matchRealNotchSize)
                Text("Match menu bar height")
                    .tag(WindowHeightMode.matchMenuBar)
                Text("Custom height")
                    .tag(WindowHeightMode.custom)
            }
            .onChange(of: notchHeightMode) {
                switch notchHeightMode {
                case .matchRealNotchSize:
                    // Get the actual notch height from the built-in display
                    notchHeight = getRealNotchHeight()
                case .matchMenuBar:
                    notchHeight = getMenuBarHeight(hasNotch: true)
                case .custom:
                    notchHeight = 38
                }
            }
            .settingsItem("Notch height on notch displays")
            if notchHeightMode == .custom {
                Slider(value: $notchHeight, in: 15...45, step: 1) {
                    Text(
                        "Custom notch size - \(notchHeight, format: .number.precision(.fractionLength(0)))",
                        comment: "Slider label showing the custom notch height."
                    )
                }
                .tint(.effectiveAccent)
            }
            // The island's height comes from each display's menu bar.
            if nonNotchStyle == .notch {
                Picker("Notch height on non-notch displays", selection: $nonNotchHeightMode) {
                    Text("Match menu bar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar:
                        nonNotchHeight = getMenuBarHeight(hasNotch: false)
                    case .matchRealNotchSize, .custom:
                        nonNotchHeight = 23
                    }
                }
                .settingsItem("Notch height on non-notch displays")
                if nonNotchHeightMode == .custom {
                    // Custom binding to skip values 1-14 (jump from 0 to 10)
                    let sliderValue = Binding<Double>(
                        get: {
                            nonNotchHeight == 0 ? 0 : nonNotchHeight - 14
                        },
                        set: { newValue in
                            nonNotchHeight = newValue == 0 ? 0 : newValue + 14
                        }
                    )

                    Slider(value: sliderValue, in: 0...26, step: 1) {
                        Text(
                            "Custom notch size - \(nonNotchHeight, format: .number.precision(.fractionLength(0)))",
                            comment: "Slider label showing the custom notch height."
                        )
                    }
                    .tint(.effectiveAccent)
                }
            }
            if openNotchOnHover {
                delaySlider("Hover delay", value: $minimumHoverDuration)
                    .settingsItem("Hover delay")
            }
            delaySlider("Close delay", value: $closeDelay)
                .settingsItem("Close delay")
            Toggle("Remember last tab", isOn: $coordinator.openLastTabByDefault)
                .settingsItem("Remember last tab")
            Toggle("Notch animation", isOn: $enableOpeningAnimation)
                .settingsItem("Notch animation")
            if enableOpeningAnimation {
                Slider(value: $animationSpeedMultiplier, in: 0.1...2.01, step: 0.1) {
                    HStack {
                        Text("Animation speed")
                        Spacer()
                        Text(
                            "\(animationSpeedMultiplier, format: .number.precision(.fractionLength(1)))x",
                            comment: "Animation speed multiplier."
                        )
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.effectiveAccent)
                .settingsItem("Animation speed")
            }
            Defaults.Toggle(key: .enableHaptics) {
                Text("Enable haptic feedback")
            }
            .settingsItem("Enable haptic feedback")
        } header: {
            AdvancedHeader(area: .notch)
        }

        Section {
            Defaults.Toggle(key: .cornerRadiusScaling) {
                Text("Scale corner radius for closed notch")
            }
            .settingsItem("Scale corner radius for closed notch")
            Defaults.Toggle(key: .hideTitleBar) {
                Text("Hide title bar")
            }
            .settingsItem("Hide title bar")
            Defaults.Toggle(key: .hideNonNotchedFromMissionControl) {
                Text("Hide windows on non-notch displays from Mission Control")
            }
            .settingsItem("Hide windows on non-notch displays from Mission Control")
            // It only decides whether an empty Shelf still shows the tab bar; say when it can't.
            Toggle(isOn: $coordinator.alwaysShowTabs) {
                Text("Always show tabs")
                if !shelfOn {
                    Text("Only matters with the Shelf on (Widgets › Tabs).")
                } else if clipboardOn || agentsOn {
                    Text("The tabs show anyway while Clipboard history or Coding Agents is on.")
                }
            }
            .disabled(!shelfOn || clipboardOn || agentsOn)
            .settingsItem("Always show tabs")
            Defaults.Toggle(key: .settingsIconInNotch) {
                Text("Settings button in the notch")
            }
            .settingsItem("Settings button in the notch")
        }
    }

    private func delaySlider(_ title: LocalizedStringKey, value: Binding<TimeInterval>) -> some View {
        Slider(value: value, in: 0...1, step: 0.1) {
            HStack {
                Text(title)
                Spacer()
                Text(Measurement(value: value.wrappedValue, unit: UnitDuration.seconds),
                     format: .measurement(width: .narrow, usage: .asProvided,
                                          numberFormatStyle: .number.precision(.fractionLength(1))))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.effectiveAccent)
    }
}

/// Advanced › Displays: which one the notch is on, while it isn't on all of them.
struct DisplayAdvancedSettings: View {
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @Default(.showOnAllDisplays) var showOnAllDisplays

    var body: some View {
        Section {
            Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
                ForEach(screens, id: \.uuid) { screen in
                    Text(screen.name).tag(screen.uuid as String?)
                }
            }
            .onChange(of: NSScreen.screens) {
                screens = NSScreen.screens.compactMap { screen in
                    guard let uuid = screen.displayUUID else { return nil }
                    return (uuid, screen.localizedName)
                }
            }
            .disabled(showOnAllDisplays)
            .settingsItem("Preferred display")

            Defaults.Toggle(key: .automaticallySwitchDisplay) {
                Text("Automatically switch displays")
            }
            .disabled(showOnAllDisplays)
            .settingsItem("Automatically switch displays")
        } header: {
            AdvancedHeader(area: .displays)
        }
    }
}

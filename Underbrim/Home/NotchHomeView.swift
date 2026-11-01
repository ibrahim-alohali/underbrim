//
//  NotchHomeView.swift
//  Underbrim
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import SwiftUI

struct NotchHomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let albumArtNamespace: Namespace.ID
    /// The note is being typed in: the others step aside so it has the row.
    @State private var noteWide = false
    /// The widgets' own widths, kept while they step aside so nothing in them reflows.
    @State private var widths: [HomeWidget: CGFloat] = [:]

    var body: some View {
        mainContent
    }

    static func shown(cameraRunning: Bool, locked: Bool) -> [HomeWidget] {
        HomeWidget.enabled.filter { ($0 != .mirror || cameraRunning) && (!locked || $0.showsWhileLocked) }
    }

    /// The row's width with room for whatever its widgets show, for fitting them.
    static func contentWidth(_ widgets: [HomeWidget], size: (HomeWidget) -> WidgetSize = \.size) -> CGFloat {
        rowWidth(widgets.map { $0.width(size($0), height: MusicPlayerView.height) })
    }

    /// The row's width as its widgets are now.
    static func liveContentWidth(_ widgets: [HomeWidget]) -> CGFloat {
        rowWidth(widgets.map { $0.liveWidth(height: MusicPlayerView.height) })
    }

    private static func rowWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(widths.count - 1, 0)) * NotchMetrics.margin
    }

    /// Open, the notch is at least 560 pt wide and grows sideways with Home's widgets, up to `limit`.
    static func minimumWidth(_ widgets: [HomeWidget], limit: CGFloat) -> CGFloat {
        min(max(liveContentWidth(widgets), 560 - side), limit)
    }

    static let side = 2 * (NotchMetrics.openTopRadius + NotchMetrics.margin)
    static let widest: CGFloat = 1200

    /// Room for Home's row on a screen this wide: up to `widest`, keeping 60 pt of menu bar either side.
    static func maxContentWidth(screenWidth: CGFloat?) -> CGFloat {
        min(widest, (screenWidth ?? .infinity) - 120) - side
    }

    @MainActor static func maxContentWidth(screen uuid: String?) -> CGFloat {
        maxContentWidth(screenWidth: NSScreen.screen(withUUID: uuid ?? "")?.frame.width)
    }

    private var cameraRunning: Bool { vm.camera.cameraAvailable && vm.camera.isSessionRunning }

    private var mainContent: some View {
        let widgets = Self.shown(cameraRunning: cameraRunning, locked: coordinator.screenLocked)
        let width = Self.liveContentWidth(widgets)
        // Typing, the note takes the notch's width, not the whole row's (nothing to scroll).
        let overflows = !noteWide && width > Self.maxContentWidth(screen: vm.screenUUID)
        return Group {
            if coordinator.editingWidgets {
                WidgetEditor(camera: vm.camera.cameraAvailable)
                    .transition(StandardAnimations.pageChange)
            } else if widgets.isEmpty, coordinator.screenLocked {
                Text("Unlock to see your widgets").font(.notchBody).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if widgets.isEmpty {
                VStack(spacing: 4) {
                    Text("Home is empty").font(.notchBody).foregroundStyle(.white)
                    NotchTextButton(title: String(localized: "Choose Widgets…")) {
                        coordinator.setEditingWidgets(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(StandardAnimations.pageChange)
            } else {
                // One scroll view either way, so crossing the limit doesn't rebuild the row; no scroller (a legacy
                // one squeezes the row). It clips only while scrolling, 6 pt out for the player's controls.
                let reach: CGFloat = overflows ? 6 : 0
                ScrollView(.horizontal) {
                    row(widgets)
                        .containerRelativeFrame(.horizontal) { length, _ in noteWide ? length : max(length, width) }
                        .padding(.vertical, reach)
                }
                .scrollDisabled(!overflows)
                .scrollClipDisabled(!overflows)
                .scrollIndicators(.never)
                .scrollsBeforePages()
                .mask {
                    if overflows {
                        LinearGradient(stops: [.init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                            .flipsForRightToLeftLayoutDirection(true)
                    } else {
                        // Not a clip: the controls, and a held widget's ring, show past the row.
                        Rectangle().padding(-16)
                    }
                }
                .padding(.vertical, -reach)
                .transition(StandardAnimations.pageChange)
            }
        }
        .frame(height: MusicPlayerView.height)
    }

    private func row(_ widgets: [HomeWidget]) -> some View {
        HStack(alignment: .top, spacing: noteWide ? 0 : NotchMetrics.margin) {
            ForEach(widgets) { widget in
                Group {
                switch widget {
                case .nowPlaying:
                    MusicPlayerView(albumArtNamespace: albumArtNamespace)
                case .calendar:
                    CalendarWidget()
                case .mirror:
                    CameraPreviewView(camera: vm.camera, island: vm, side: MusicPlayerView.height)
                        .opacity(vm.notchState == .closed ? 0 : 1)
                case .quickLaunch:
                    QuickLaunchWidget(columns: widget.size.quickLaunchColumns, namespace: albumArtNamespace)
                case .timer:
                    TimerWidget()
                case .shortcuts:
                    ShortcutsWidget()
                case .scratchpad:
                    ScratchpadWidget()
                case .system:
                    SystemWidget()
                case .reminders:
                    RemindersWidget()
                case .unread:
                    UnreadWidget()
                case .calls:
                    CallsWidget()
                case .prayer:
                    PrayerWidget(locked: coordinator.screenLocked)
                }
                }
                // Its own menu: pin it as the island alone (a widget's own menus, inside it, come first).
                .contextMenu { PinMenu(widget: widget) }
                .pinHoldTarget(widget)
                .modifier(StepAside(active: noteWide && widget != .scratchpad, width: widths[widget]))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if !noteWide { widths[widget] = width }
                }
                .transition(StandardAnimations.aroundPlayer)
            }
        }
        .onPreferenceChange(ScratchpadEditingKey.self) { editing in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { noteWide = editing }
        }
        // Gone mid-note (Edit Widgets): the others are back when the row is.
        .onDisappear { noteWide = false }
        .contextMenu {
            if !coordinator.screenLocked {
                EditWidgetsButton()
            }
        }
        .transition(.opacity)
    }
}

/// A widget making room for the typed note slides under it at its own width and fades, without reflowing.
private struct StepAside: ViewModifier {
    let active: Bool
    let width: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(width: active ? width : nil)
            .frame(width: active ? 0 : nil, alignment: .leading)
            .clipShape(TrailingCut(settled: width))
            .opacity(active ? 0 : 1)
            .allowsHitTesting(!active)
            .accessibilityHidden(active)
            .transformPreference(QuickLaunchFloatKey.self) { if active { $0 = nil } }
    }
}

/// Cuts off what runs past the trailing edge while a widget slides under the note, so it doesn't
/// spill onto its neighbour; settled, 40 pt out (the player's controls run past the row). Nothing
/// above, below or before it is cut (the album art flying in from the closed notch).
struct TrailingCut: Shape {
    /// The widget's own width (not known yet: settled).
    let settled: CGFloat?
    var layoutDirectionBehavior: LayoutDirectionBehavior { .mirrors }

    func path(in rect: CGRect) -> Path {
        let far: CGFloat = 10_000
        let spare: CGFloat = rect.width >= (settled ?? 0) - 0.5 ? 40 : 0
        return Path(CGRect(x: rect.minX - far, y: rect.minY - far, width: far + rect.width + spare, height: rect.height + 2 * far))
    }
}

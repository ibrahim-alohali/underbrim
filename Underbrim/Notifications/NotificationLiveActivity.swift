//
//  NotificationLiveActivity.swift
//  Underbrim
//

import SwiftUI

struct NotificationSourceIcon: View {
    let bundleID: String?
    let size: CGFloat

    var body: some View {
        if let bundleID {
            appIcon(for: bundleID)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "bell")
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
        }
    }
}

struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let notification: SystemNotification

    @State private var pulses = 0
    /// The notifications that have rung: this view is made anew whenever the closed island comes back
    /// over one, and each rings once. Keyed by arrival, as a later banner can reuse an id.
    private static var rung: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var itemSize: CGFloat {
        vm.closedItemSize
    }

    var body: some View {
        HStack {
            NotificationSourceIcon(bundleID: notification.bundleID, size: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)

            ZStack {
                Circle()
                    .stroke(Color.notchAccent, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: Ring(), trigger: pulses) { ring, value in
                        ring.scaleEffect(value.scale).opacity(value.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) { MoveKeyframe(1); CubicKeyframe(1.8, duration: 0.6) }
                        KeyframeTrack(\.opacity) { MoveKeyframe(0.8); CubicKeyframe(0, duration: 0.6) }
                    }
                Circle()
                    .fill(Color.notchAccent)
                    .frame(width: 7, height: 7)
            }
            .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveActivityItem.notification(notification).spokenText)
        // Something new: one pulse from the dot, once the activity has come in (none with Reduce Motion).
        .task(id: notification.receivedAt) {
            guard !reduceMotion, (try? await Task.sleep(for: .seconds(0.25))) != nil,
                  Self.rung.insert("\(vm.screenUUID ?? "")/\(notification.receivedAt.timeIntervalSinceReferenceDate)").inserted
            else { return }
            pulses += 1
        }
    }

    private struct Ring { var scale = 1.0; var opacity = 0.0 }
}

struct NotificationExpandedView: View {
    @ObservedObject private var manager = SystemNotificationManager.shared
    let notification: SystemNotification
    /// Its dismiss countdown waits while it shows (false: it keeps running).
    var holdsWhileShown = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openSourceApp) {
                HStack(alignment: .center, spacing: 12) {
                    NotificationSourceIcon(bundleID: notification.bundleID, size: 46)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            (notification.appName.map { Text($0) } ?? Text("Notification"))
                                .font(.notchTitle)
                                .lineLimit(1)

                            Text(notification.receivedAt, style: .relative)
                                .font(.notchCaption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }

                        if let title = notification.title, title != notification.appName {
                            Text(title)
                                .font(.notchBody)
                                .lineLimit(1)
                        }

                        if let subtitle = notification.subtitle {
                            Text(subtitle)
                                .font(.notchBody)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let body = notification.body {
                            Text(body)
                                .font(.notchBody)
                                .foregroundStyle(.secondary.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text([notification.appName, notification.title, notification.subtitle, notification.body]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
            .accessibilityHint("Opens \(notification.appName ?? String(localized: "the app"))")

            HStack(spacing: 4) {
                if !manager.queuedNotifications.isEmpty {
                    NotchTextButton(title: "+\(manager.queuedNotifications.count)",
                                    help: String(localized: "Show next queued notification")) {
                        manager.showNextQueued()
                    }
                    .monospacedDigit()
                    .accessibilityLabel("Show next queued notification")
                }

                NotchSymbolButton(symbol: "xmark", label: String(localized: "Dismiss notification"), size: 10) {
                    manager.dismissActive(token: notification.id)
                }
            }
        }
        // Ages out again when the pointer leaves or the notch closes (ContentView), not when the next card shows.
        .onAppear { if holdsWhileShown { manager.holdActive() } }
    }

    private func openSourceApp() {
        Task {
            // No app to bring forward: refused like other actions, and the card stays.
            guard await manager.open(notification) else { return NSSound.beep() }
            manager.dismissActive(token: notification.id)
        }
    }
}

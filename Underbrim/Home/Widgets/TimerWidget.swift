//
//  TimerWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A countdown with presets, or a stopwatch. While it runs it counts on the closed notch too.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
@Observable
final class TimerModel {
    static let shared = TimerModel()
    nonisolated static let doneFeedback: TimeInterval = 6
    nonisolated static let presets = [5, 15, 25, 45]

    enum Mode: Equatable { case idle, countdown, stopwatch }

    private(set) var mode: Mode = .idle
    /// A running countdown's end, or a running stopwatch's (shifted) start.
    private(set) var anchor: Date?
    /// While paused: the time left (countdown) or counted (stopwatch).
    private(set) var pausedValue: TimeInterval?
    private(set) var finishedAt: Date?
    private(set) var showingDone = false
    @ObservationIgnored private var alarm: Task<Void, Never>?

    var isRunning: Bool { anchor != nil }
    var isFinished: Bool { finishedAt != nil }

    var showsOnClosedNotch: Bool { isRunning || showingDone }
    var spokenState: String {
        isFinished ? String(localized: "Timer done")
            : mode == .stopwatch ? String(localized: "Stopwatch running") : String(localized: "Timer running")
    }

    func value(at now: Date) -> TimeInterval {
        if let pausedValue { return pausedValue }
        guard let anchor else { return 0 }
        return mode == .countdown ? max(0, anchor.timeIntervalSince(now)) : now.timeIntervalSince(anchor)
    }

    func start(minutes: Int) {
        reset()
        mode = .countdown
        anchor = Date().addingTimeInterval(TimeInterval(minutes * 60))
        scheduleAlarm()
    }

    func startStopwatch() {
        reset()
        mode = .stopwatch
        anchor = Date()
    }

    func pause() {
        guard isRunning else { return }
        pausedValue = value(at: Date())
        anchor = nil
        alarm?.cancel()
    }

    func resume() {
        guard let pausedValue else { return }
        let now = Date()
        anchor = mode == .countdown ? now.addingTimeInterval(pausedValue) : now.addingTimeInterval(-pausedValue)
        self.pausedValue = nil
        if mode == .countdown { scheduleAlarm() }
    }

    func addMinute() {
        guard mode == .countdown, !isFinished else { return }
        if let anchor { self.anchor = anchor.addingTimeInterval(60); scheduleAlarm() }
        if let pausedValue { self.pausedValue = pausedValue + 60 }
    }

    func reset() {
        alarm?.cancel()
        alarm = nil
        mode = .idle
        anchor = nil
        pausedValue = nil
        finishedAt = nil
        showingDone = false
    }

    private func scheduleAlarm() {
        alarm?.cancel()
        guard let anchor else { return }
        alarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, anchor.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func finish() {
        let now = Date()
        anchor = nil
        pausedValue = 0
        finishedAt = now
        showingDone = true
        NSSound(named: "Glass")?.play()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.doneFeedback))
            if self?.finishedAt == now { self?.showingDone = false }
        }
    }

    /// The whole seconds a clock shows: a countdown rounds up (0:00 only at its end), a stopwatch down
    /// (0:01 once a second has gone).
    func shownSeconds(at now: Date) -> Int {
        let value = value(at: now)
        return Int(mode == .stopwatch ? value.rounded(.down) : value.rounded(.up))
    }

    /// Where a running clock's once-a-second schedule starts: just after its shown second turns (whole
    /// seconds from the anchor), so every clock on screen turns with it, and not later than now.
    func ticksStart(now: Date = .now) -> Date? {
        guard let anchor else { return nil }
        let turn = anchor.addingTimeInterval(0.01)
        return turn.addingTimeInterval(-max(0, turn.timeIntervalSince(now).rounded(.up)))
    }

    nonisolated static func format(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    nonisolated static func spoken(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Draws a timer's clock once a second while it runs, in step with the timer; paused or done, once.
struct TimerTicks<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if let start = TimerModel.shared.ticksStart() {
            TimelineView(.periodic(from: start, by: 1)) { context in content(context.date) }
        } else {
            content(.now)
        }
    }
}

struct TimerWidget: View {
    private let timer = TimerModel.shared
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        if alone {
            aloneLayout
        } else {
            Group {
                if timer.mode == .idle {
                    idle
                } else {
                    active
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var aloneLayout: some View {
        AloneFrame(widget: .timer) {
            AloneTitle(symbol: timer.isFinished ? "checkmark.circle.fill" : timer.mode == .stopwatch ? "stopwatch" : "timer",
                       title: timer.mode == .stopwatch ? String(localized: "Stopwatch") : String(localized: "Timer"),
                       tint: timer.mode == .idle || timer.isFinished ? .secondary : .notchAccent)
        } trailing: {
            if timer.mode != .idle {
                clock(.notchTitle.monospacedDigit())
            }
        } row: {
            HStack(spacing: 5) {
                if timer.mode == .idle {
                    ForEach(TimerModel.presets, id: \.self) { minutes in
                        chip(Duration.minutesShort(minutes), help: String(localized: "Start a \(minutes)-minute timer")) { timer.start(minutes: minutes) }
                    }
                    chip(String(localized: "Stopwatch"), help: String(localized: "Start a stopwatch")) { timer.startStopwatch() }
                } else {
                    if !timer.isFinished {
                        chip(timer.isRunning ? String(localized: "Pause") : String(localized: "Resume"),
                             symbol: timer.isRunning ? "pause.fill" : "play.fill",
                             help: timer.isRunning ? String(localized: "Pause") : String(localized: "Resume")) {
                            timer.isRunning ? timer.pause() : timer.resume()
                        }
                    }
                    if timer.mode == .countdown && !timer.isFinished {
                        chip(Duration.minutesShort(1), symbol: "plus", help: String(localized: "Add a minute")) { timer.addMinute() }
                    }
                    chip(String(localized: "Reset"), symbol: "arrow.counterclockwise", help: String(localized: "Reset")) { timer.reset() }
                }
            }
        }
    }

    private var idle: some View {
        VStack(spacing: 6) {
            Label(String(localized: "Timer"), systemImage: "timer")
                .font(.notchCaption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(TimerModel.presets.prefix(3), id: \.self) { minutes in
                    chip(Duration.minutesShort(minutes), help: String(localized: "Start a \(minutes)-minute timer")) { timer.start(minutes: minutes) }
                }
            }
            HStack(spacing: 5) {
                chip(Duration.minutesShort(TimerModel.presets[3]), help: String(localized: "Start a \(TimerModel.presets[3])-minute timer")) {
                    timer.start(minutes: TimerModel.presets[3])
                }
                chip(String(localized: "Stopwatch"), help: String(localized: "Start a stopwatch")) { timer.startStopwatch() }
            }
        }
    }

    private var active: some View {
        VStack(spacing: 4) {
            clock(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
            HStack(spacing: 6) {
                if !timer.isFinished {
                    NotchSymbolButton(symbol: timer.isRunning ? "pause.fill" : "play.fill",
                                      label: timer.isRunning ? String(localized: "Pause") : String(localized: "Resume")) {
                        timer.isRunning ? timer.pause() : timer.resume()
                    }
                }
                NotchSymbolButton(symbol: "arrow.counterclockwise", label: String(localized: "Reset")) { timer.reset() }
                if timer.mode == .countdown && !timer.isFinished {
                    NotchSymbolButton(symbol: "plus", label: String(localized: "Add a minute")) { timer.addMinute() }
                }
            }
        }
    }

    /// The time left or counted, or Done. Ticks once a second, and only while running.
    private func clock(_ font: Font) -> some View {
        TimerTicks { date in
            let value = timer.shownSeconds(at: date)
            Text(timer.isFinished ? String(localized: "Done") : TimerModel.format(value))
                .font(font)
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: timer.mode == .countdown))
                .accessibilityLabel(timer.isFinished ? String(localized: "Timer done")
                                    : timer.mode == .countdown ? String(localized: "\(TimerModel.spoken(value)) left")
                                    : String(localized: "Stopwatch, \(TimerModel.spoken(value))"))
        }
    }

    private func chip(_ title: String, symbol: String? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(.notchCaption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct TimerLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    private let timer = TimerModel.shared

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            Image(systemName: timer.isFinished ? "checkmark.circle.fill" : timer.mode == .stopwatch ? "stopwatch" : "timer")
                .font(.notchSymbol(size: 12))
                .foregroundStyle(timer.isFinished ? Color.white : Color.notchAccent)
                .frame(width: itemSize, height: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            TimerTicks { date in
                Text(timer.isFinished ? String(localized: "Done") : TimerModel.format(timer.shownSeconds(at: date)))
                    .font(.notchCaption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: itemSize + TimerLiveActivity.extraWidth, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timer.spokenState)
    }

    /// The time needs a little more room than a symbol.
    static let extraWidth: CGFloat = 14
}

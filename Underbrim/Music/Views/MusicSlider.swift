//
//  MusicSlider.swift
//  Underbrim
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Defaults
import SwiftUI

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    var onValueChange: (Double) -> Void

    // Ported from Atoll (GPL-3.0) so the
    // trailing timestamp can count down instead of showing the duration.
    var trailingLabel: TrailingLabel = .duration
    /// The bar's own width, which a row sized to its content keeps it at; nil, next to none.
    var barWidth: CGFloat?

    enum TrailingLabel {
        case duration
        /// Counts down: "-2:56".
        case remaining
    }

    var body: some View {
        // The times either side of the bar, as on the iPhone: on their own line the player would be too tall.
        HStack(spacing: 8) {
            Text(timeString(from: sliderValue))
                .frame(minWidth: 30, alignment: .leading)
            sliderCore
                .frame(idealWidth: barWidth)
                .frame(height: sliderFrameHeight, alignment: .center)
            Text(trailingTimeText)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .foregroundColor(timeLabelColor)
        .font(.notchCaption.monospacedDigit())
        // Playback runs left to right in every language (Apple doesn't mirror scrubbers or transport buttons).
        .environment(\.layoutDirection, .leftToRight)
        .onChange(of: currentDate) { followPlayback() }
        // Paused, the timeline doesn't tick: follow when the bar appears and when the song moves.
        .onAppear { followPlayback() }
        .onChange(of: elapsedTime) { followPlayback() }
    }

    private func followPlayback() {
        guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
        sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
    }

    private var sliderCore: some View {
        CustomSlider(
            value: $sliderValue,
            range: 0...duration,
            color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                : Defaults[.sliderColor] == SliderColorEnum.accent ? .notchAccent : .white,
            dragging: $dragging,
            lastDragged: $lastDragged,
            onValueChange: onValueChange,
            spokenValue: timeString(from: sliderValue)
        )
        .accessibilityLabel(String(localized: "Playback position"))
    }

    private var timeLabelColor: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
    }

    private var trailingTimeText: String {
        switch trailingLabel {
        case .duration:
            return timeString(from: duration)
        case .remaining:
            return "-" + timeString(from: max(duration - sliderValue, 0))
        }
    }

    private var sliderFrameHeight: CGFloat {
        10
    }

    func timeString(from seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        return Duration.seconds(Int(seconds)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    /// What VoiceOver says the value is; unless given, a percentage of 0...1 (the volume).
    var spokenValue: String?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
        // A click's location doesn't mirror in Arabic: drawn and measured from the left, then mirrored whole.
        .environment(\.layoutDirection, .leftToRight)
        .flipsForRightToLeftLayoutDirection(true)
        // A drag on shapes is nothing to VoiceOver (its role read "unknown"): a slider stands in for
        // it, stepping by a twentieth. A live stream has no length to step through.
        .accessibilityRepresentation {
            let span = range.upperBound - range.lowerBound
            Slider(value: Binding(get: { value }, set: { newValue in
                value = newValue
                onValueChange?(newValue)
                lastDragged = Date()
            }), in: span > 0 ? range : 0...1, step: span > 0 ? span / 20 : 1)
            .disabled(span <= 0)
        }
        .accessibilityValue(spokenValue ?? value.formatted(.percent.precision(.fractionLength(0))))
        .keepsSwipes()
    }
}

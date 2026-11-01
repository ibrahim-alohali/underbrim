//
//  ProgressRing.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Download ring for the closed notch, drawn by Core Animation: a SwiftUI trim animated per progress
//  tick re-laid out the whole hosting view every frame (~25% CPU while downloading).
//

import AppKit
import SwiftUI

struct ProgressRing: NSViewRepresentable {
    var fraction: Double
    var animated: Bool
    var color: NSColor

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.set(fraction: fraction, animated: animated)
        view.progress.strokeColor = color.cgColor
    }

    final class RingView: NSView {
        private let track = CAShapeLayer()
        let progress = CAShapeLayer()
        private let lineWidth: CGFloat = 2.5

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for shape in [track, progress] {
                shape.fillColor = nil
                shape.lineWidth = lineWidth
                shape.lineCap = .round
                layer?.addSublayer(shape)
            }
            track.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
            progress.strokeEnd = 0
        }

        required init?(coder: NSCoder) { nil }

        /// Decorative: clicks belong to the notch underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let radius = max(0, min(bounds.width, bounds.height) / 2 - lineWidth / 2)
            // From 12 o'clock, clockwise (y points up in this view).
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for shape in [track, progress] {
                shape.frame = bounds
                shape.path = path
            }
            CATransaction.commit()
        }

        func set(fraction: Double, animated: Bool) {
            let end = CGFloat(min(1, max(0, fraction)))
            guard end != progress.strokeEnd else { return }
            let from = progress.presentation()?.strokeEnd ?? progress.strokeEnd
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progress.strokeEnd = end
            CATransaction.commit()
            guard animated else { return }
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = from
            animation.toValue = end
            animation.duration = 0.25
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            progress.add(animation, forKey: "progress")
        }
    }
}

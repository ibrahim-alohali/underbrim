//
//  ActivityDots.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  "Working" dots for the closed notch as Core Animation layers: a SwiftUI symbol effect re-rendered
//  the notch's whole layer every frame (~32% CPU). Static under Reduce Motion.
//

import AppKit
import SwiftUI

struct ActivityDots: NSViewRepresentable {
    var animated: Bool

    func makeNSView(context: Context) -> DotsView { DotsView() }

    func updateNSView(_ view: DotsView, context: Context) {
        view.setAnimated(animated)
    }

    final class DotsView: NSView {
        private let dots = (0..<3).map { _ in CALayer() }
        private var animated = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for dot in dots {
                dot.backgroundColor = NSColor.white.cgColor
                dot.opacity = 0.75
                layer?.addSublayer(dot)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 6) }

        override func layout() {
            super.layout()
            let size: CGFloat = 3.5
            let gap = (bounds.width - size * 3) / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * (size + gap), y: (bounds.height - size) / 2, width: size, height: size)
                dot.cornerRadius = size / 2
            }
            CATransaction.commit()
        }

        func setAnimated(_ value: Bool) {
            guard value != animated else { return }
            animated = value
            for (index, dot) in dots.enumerated() {
                dot.removeAnimation(forKey: "pulse")
                guard value else { dot.opacity = 0.75; continue }
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.3, 1.0, 0.3]
                pulse.keyTimes = [0, 0.5, 1]
                pulse.duration = 1.2
                pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
                pulse.repeatCount = .infinity
                pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
                dot.add(pulse, forKey: "pulse")
            }
        }
    }
}

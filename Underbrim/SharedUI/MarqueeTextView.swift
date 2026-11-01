//
//  MarqueeTextView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

extension String {
    /// Its first letter is in a right-to-left script (Unicode's first strong character, near enough).
    var readsRightToLeft: Bool {
        guard let letter = unicodeScalars.first(where: { $0.properties.isAlphabetic }) else { return false }
        return (0x0590...0x08FF).contains(letter.value) || (0xFB1D...0xFDFF).contains(letter.value)
            || (0xFE70...0xFEFF).contains(letter.value)
    }
}

/// Text that fits sits at the leading edge; text that scrolls at its own beginning (the right, for Arabic).
private func marqueeAlignment(scrolls: Bool, rightToLeftText: Bool, in direction: LayoutDirection) -> Alignment {
    (scrolls ? rightToLeftText : direction == .rightToLeft) ? .trailing : .leading
}

struct MarqueeText: View {
    let text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let color: Color
    let delayDuration: Double
    let frameWidth: CGFloat

    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0
    /// Counts the starts, so an earlier run's end can't mark a later one as done.
    @State private var runs = 0
    /// Scrolled through: resting at its beginning until the pointer comes over it or the text changes.
    @State private var resting = false
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let gap: CGFloat = 20

    init(_ text: String, font: Font = .body, nsFont: NSFont.TextStyle = .body, color: Color = .primary, delayDuration: Double = 3.0, frameWidth: CGFloat) {
        self.text = text
        self.font = font
        self.nsFont = nsFont
        self.color = color
        self.delayDuration = delayDuration
        self.frameWidth = frameWidth
    }

    /// Not before there's a width (at 0 everything looks too long), nor with Reduce Motion (it truncates).
    private var needsScrolling: Bool {
        frameWidth > 0 && textSize.width > frameWidth && !reduceMotion
    }

    /// Scrolls too-long text through twice, then rests at its beginning: scrolling while the island
    /// stays open redraws the notch every frame (~33% CPU).
    private func restart(rightToLeft: Bool, after delay: Double? = nil) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        resting = false
        runs += 1
        let run = runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            guard run == runs, needsScrolling else { return }
            withAnimation(.linear(duration: Double(textSize.width / 30)).delay(delay ?? delayDuration)
                .repeatCount(2, autoreverses: false)) {
                offset = (textSize.width + gap) * (rightToLeft ? 1 : -1)
            } completion: {
                if run == runs { resting = true }
            }
        }
    }

    var body: some View {
        // Laid out left to right in any language, so it scrolls the way the text reads, its copy following.
        let rightToLeft = text.readsRightToLeft
        let label = Text(text).lineLimit(1).environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        GeometryReader { _ in
            HStack(spacing: gap) {
                if rightToLeft && needsScrolling { label }
                label.modifier(MeasureSizeModifier())
                if !rightToLeft && needsScrolling { label }
            }
            .id(text)
            .font(font)
            .foregroundColor(color)
            .fixedSize(horizontal: !reduceMotion, vertical: false)
            .offset(x: offset)
            .onPreferenceChange(SizePreferenceKey.self) { size in
                self.textSize = CGSize(width: size.width, height: NSFont.preferredFont(forTextStyle: nsFont).pointSize)
                restart(rightToLeft: rightToLeft)
            }
            // The row's width can arrive after the text's: decide again.
            .onChange(of: frameWidth) { _, _ in restart(rightToLeft: rightToLeft) }
            .onChange(of: reduceMotion) { _, _ in restart(rightToLeft: rightToLeft) }
            .frame(width: frameWidth, alignment: marqueeAlignment(scrolls: needsScrolling, rightToLeftText: rightToLeft,
                                                                  in: layoutDirection))
            .clipped()
        }
        .frame(height: textSize.height * 1.3)
        .environment(\.layoutDirection, .leftToRight)
        .onHover { hovering in if hovering && resting { restart(rightToLeft: rightToLeft, after: 0) } }
    }
}

//
//  StandardAnimations.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import AppKit
import Defaults
import Foundation
import SwiftUI

// MARK: - Standardized Animations
/// Centralized animation definitions for consistent UI behavior across the app.
enum StandardAnimations {
    /// Interactive spring for responsive UI (used for notch interactions)
    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    /// Reduce Motion: the shell still changes size (that's the content), but
    /// quickly and without overshoot, and its content cross-fades.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Spring animation for opening the notch. It drives the outline's width,
    /// height and corners together, and resizes it between tabs.
    static var open: Animation { open(reduceMotion: reduceMotion) }

    static func open(reduceMotion: Bool) -> Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        if reduceMotion { return .easeOut(duration: 0.18) }
        return Animation.spring(response: 0.42 / Defaults[.animationSpeedMultiplier], dampingFraction: 0.8, blendDuration: 0)
    }

    /// Spring animation for closing the notch. It waits a moment so the
    /// content's fade-out (`openContent`) leads, and is done in about 0.4 s:
    /// quicker than the open, as the island is answering the pointer leaving.
    static var close: Animation { close(reduceMotion: reduceMotion) }

    static func close(reduceMotion: Bool) -> Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        if reduceMotion { return .easeOut(duration: 0.18) }
        return Animation.spring(response: 0.34 / Defaults[.animationSpeedMultiplier], dampingFraction: 1.0, blendDuration: 0)
            .delay(0.04)
    }

    /// The open notch's content: it fades in once the outline is mostly open
    /// (about three quarters, 0.14 s into the opening spring) and fades out
    /// first when closing. No scaling — the outline does the moving.
    static var openContent: AnyTransition {
        if reduceMotion || !Defaults[.enableOpeningAnimation] { return .opacity.animation(.easeOut(duration: 0.12)) }
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.14 / Defaults[.animationSpeedMultiplier])),
                           removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    /// The closed notch's content (activities on its sides) mirrors that:
    /// out quickly as the notch opens, back once it has nearly closed.
    static var closedContent: AnyTransition {
        if reduceMotion || !Defaults[.enableOpeningAnimation] { return .opacity.animation(.easeOut(duration: 0.12)) }
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.22 / Defaults[.animationSpeedMultiplier])),
                           removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    /// One page of the open island giving way to another (a tab, the widget
    /// editor, a step of the tour): the old one out first, the new one in once
    /// it's gone and the outline has made most of the room (a wider page isn't
    /// cut by it once half there), so the two never show at once. Opacity only,
    /// so it stands with Reduce Motion too.
    static var pageChange: AnyTransition { pageChange(entering: .opacity) }

    /// `pageChange`, with what the new page does as it comes in (the tour's steps rise a little).
    static func pageChange(entering: AnyTransition) -> AnyTransition {
        .asymmetric(insertion: entering.animation(.easeOut(duration: 0.18).delay(0.12 / Defaults[.animationSpeedMultiplier])),
                    removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    /// A page brought by a swipe: in from the side of the screen the fingers moved away from
    /// (`entering` 1 the right, -1 the left), the old page out the other way. A fade with Reduce Motion.
    static func pageSwipe(entering: CGFloat) -> AnyTransition {
        guard !reduceMotion else { return pageChange }
        // Offsets mirror in Arabic; these are on screen.
        let side = NSApp.userInterfaceLayoutDirection == .rightToLeft ? -entering : entering
        return .asymmetric(insertion: .offset(x: 44 * side).combined(with: .opacity).animation(.smooth(duration: 0.32)),
                           removal: .offset(x: -44 * side).combined(with: .opacity).animation(.easeOut(duration: 0.16)))
    }

    /// Home's other widgets and the header, leaving or coming back around the
    /// player alone: a fade with a slight blur, in once the outline has made
    /// room (a plain fade with Reduce Motion).
    static var aroundPlayer: AnyTransition {
        if reduceMotion || !Defaults[.enableOpeningAnimation] { return .opacity.animation(.easeOut(duration: 0.15)) }
        let blurFade = AnyTransition.modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
        return .asymmetric(insertion: blurFade.animation(.easeOut(duration: 0.22).delay(0.12 / Defaults[.animationSpeedMultiplier])),
                           removal: blurFade.animation(.easeOut(duration: 0.14)))
    }

    /// Smooth animation for general transitions
    static let smooth = Animation.smooth
}

/// Fades and blurs together (StandardAnimations.aroundPlayer).
struct BlurFade: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: 6 * amount).opacity(1 - amount)
    }
}

//
//  NotificationBannerTests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
@testable import Underbrim

struct NotificationBannerTests {
    /// A banner's text comes from another app: characters that reorder the text around them go, so a
    /// message can't show its words in another order than it holds them.
    @Test func directionOverridesAreRemoved() {
        #expect(UnderbrimBanner.cleaned("Invoice \u{202E}fdp.exe", maxLength: 100) == "Invoice fdp.exe")
    }

    /// A message of several lines keeps them: the body shows two.
    @Test func lineBreaksStay() {
        #expect(UnderbrimBanner.cleaned("On my way\nSee you soon", maxLength: 100) == "On my way\nSee you soon")
    }

    @Test func longTextIsBounded() throws {
        let cleaned = try #require(UnderbrimBanner.cleaned(String(repeating: "a", count: 5000), maxLength: 2000))
        #expect(cleaned.count == 2001)
        #expect(cleaned.hasSuffix("…"))
    }

    /// Isolates and embeddings stay: apps (macOS's own strings among them) wrap names and quotes in them,
    /// and without them right-to-left text around a name shows in the wrong order.
    @Test func isolatesAndEmbeddingsStay() {
        let text = "\u{2067}رد من \u{2068}Sam 2\u{2069}\u{2069} \u{202B}مرحبا\u{202C}"
        #expect(UnderbrimBanner.cleaned(text, maxLength: 100) == text)
    }
}

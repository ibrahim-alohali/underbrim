//
//  NowPlayingFallbackNoticeView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The closed island's notice when Now Playing has to fall back, read out once by VoiceOver.
//

import SwiftUI

struct NowPlayingFallbackNoticeView: View {
    let notice: NowPlayingFallbackNotice

    static let width: CGFloat = 330

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(notice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(2)

            Spacer(minLength: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: Self.width)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .onAppear {
            if MusicManager.shared.markNowPlayingNoticePresented(notice.id) {
                announce()
            }
        }
    }

    private func announce() {
        let announcement = "\(String(localized: notice.title)). \(String(localized: notice.subtitle))."
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

//
//  NowPlayingFallbackNotice.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

/// The passive notice shown when Now Playing can't be used and another source stands in.
struct NowPlayingFallbackNotice: Identifiable, Equatable {
    let id = UUID()
    let fallbackSource: MediaControllerType
    let failure: NowPlayingFailure

    var title: LocalizedStringResource {
        switch failure {
        case .setup:
            LocalizedStringResource(
                "Now Playing components unavailable",
                comment: "Title of the passive notice shown when required Now Playing components cannot be used."
            )
        case .probe:
            LocalizedStringResource(
                "Could not verify Now Playing",
                comment: "Title of the passive notice shown when the Now Playing availability probe fails."
            )
        case .runtime:
            LocalizedStringResource(
                "Now Playing connection lost",
                comment: "Title of the passive notice shown when an active Now Playing stream fails."
            )
        }
    }

    var subtitle: LocalizedStringResource {
        if failure == .setup {
            LocalizedStringResource(
                "Using \(fallbackSource.localizedString) instead",
                comment: "Now Playing setup failure notice. The placeholder is the fallback music source name."
            )
        } else {
            LocalizedStringResource(
                "Using \(fallbackSource.localizedString) temporarily",
                comment: "Temporary Now Playing fallback notice. The placeholder is the fallback music source name."
            )
        }
    }
}

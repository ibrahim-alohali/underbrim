//
//  ActivityFeed.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The closed notch's activities, in the order they claim the island, and what brings each one
//  forward as it starts. Read while the notch draws: ContentView observes the stores they come from.
//

import Defaults
import Foundation

@MainActor
enum ActivityFeed {
    /// Closed-notch activities, newest first. A notification sits in front of
    /// music, so an incoming message takes over the display; when it expires
    /// it drops out of this list on its own and music comes back — no
    /// explicit "restore previous activity" bookkeeping needed.
    static var items: [LiveActivityItem] {
        var items: [LiveActivityItem] = []
        let requests = AgentRequestStore.shared.requests
        // A request to answer shows even with sessions off.
        let agent = Defaults[.showAgentActivity] || !requests.isEmpty ? AgentSessionStore.shared.closedSummary : nil

        // An agent waiting on the user stays in front; a notification or an OSD only covers it for a moment.
        if let agent, agent.waitsOnUser {
            items.append(.agent(agent))
        }

        if let notification = SystemNotificationManager.shared.activeNotification {
            items.append(.notification(notification))
        }

        if let device = HeadphoneBatteryStore.shared.justConnected {
            items.append(.headphones(device))
        }

        // A call goes in front of anything ongoing, as on the iPhone.
        if let call = CallActivity.shared.call {
            items.append(.call(call))
        }

        if Defaults[.prayerAtTime], let prayer = PrayerTimesStore.shared.arrived {
            items.append(.prayer(prayer))
        }

        if let meeting = MeetingStore.shared.featured {
            items.append(.meeting(meeting))
        }

        // A transfer goes ahead of a working agent (often hours long), or its progress would rarely show.
        if Defaults[.showDownloadActivity], let download = DownloadsStore.shared.closedSummary {
            items.append(.download(download))
        }

        // A timer the user started, ahead of a working agent and music (a finished one comes forward below).
        if TimerModel.shared.showsOnClosedNotch {
            items.append(.timer)
        }

        // An iPhone Live Activity: ongoing like a working agent, but the user is usually waiting on it.
        let phones = PhoneActivityStore.shared
        if let phone = phones.featured {
            items.append(.phone(phone))
        } else if let order = DeliveryTracker.shared.orders(besides: phones.activities).first {
            items.append(.delivery(order))
        }

        if let agent, !agent.waitsOnUser {
            items.append(.agent(agent))
        }

        // Not hidden during a battery notice, which shows over the activities: hiding would end the user's pick.
        let music = MusicManager.shared
        if (music.isPlaying || !music.isPlayerIdle) && NotchViewCoordinator.shared.musicLiveActivityEnabled {
            items.append(.music)
        }

        return items
    }

    /// What has just started, by kind: a new key brings that activity to the front, and one gone lets it
    /// go back to its place. A notification comes forward on its own (ContentView), with more to do.
    static var starts: [LiveActivityItem.Kind: String] {
        var keys: [LiveActivityItem.Kind: String] = [:]
        // An agent comes forward as it starts to need the user, not when a question is set aside.
        if let summary = AgentSessionStore.shared.closedSummary, summary.waitsOnUser, !summary.setAside { keys[.agent] = summary.sessionID }
        keys[.headphones] = HeadphoneBatteryStore.shared.justConnected?.id
        keys[.timer] = TimerModel.shared.finishedAt.map { "\($0.timeIntervalSince1970)" }
        keys[.call] = CallActivity.shared.call.map { "\($0.since.timeIntervalSince1970)" }
        keys[.phone] = PhoneActivityStore.shared.featured?.id
        keys[.prayer] = PrayerTimesStore.shared.arrived.map { "\($0.name.rawValue) \($0.at.timeIntervalSince1970)" }
        keys[.meeting] = MeetingStore.shared.featured?.id
        return keys
    }

    /// The order they come forward in when several start at once: the last one ends up in front.
    static let startOrder: [LiveActivityItem.Kind] = [.agent, .headphones, .timer, .call, .phone, .prayer, .meeting]
}

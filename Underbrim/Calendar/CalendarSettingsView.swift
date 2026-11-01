//
//  CalendarSettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import EventKit
import SwiftUI

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.meetingCountdown) private var meetingCountdown

    @Default(.meetingLeadMinutes) private var meetingLead
    private let meetings = MeetingStore.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .meetingCountdown) {
                    SettingsLabel("Count down to meetings in the closed notch", info: "Timed events only — not all-day events, reminders or meetings you declined.")
                }
                .settingsItem("Count down to meetings in the closed notch")
                Picker("Start the countdown", selection: $meetingLead) {
                    ForEach([5, 10, 15], id: \.self) { Text("\($0) minutes before").tag($0) }
                }
                .settingsItem("Start the countdown")
                switch meetings.access {
                case .granted:
                    EmptyView()
                case .unknown:
                    Button("Allow Calendar Access…") {
                        Task {
                            await meetings.requestAccess()
                            await calendarManager.refreshCalendarStatus()
                        }
                    }
                    .settingsItem("Allow Calendar Access…")
                case .denied:
                    Label("Calendar access is off. Turn it on in System Settings › Privacy & Security › Calendars.",
                          systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            } header: {
                SettingsPageHeader(tab: .calendar, section: "Upcoming meetings",
                                   info: ["Join opens only video links from known meeting services (Zoom, Google Meet, Teams, Webex, Whereby, Jitsi)."])
            }

            // Underbrim: Home's compact calendar; its size and place are in Settings → Widgets.
            Section {
                Defaults.Toggle(key: .showCalendar) {
                    Text("Show calendar on Home")
                }
                .settingsItem("Show calendar on Home")
                .homeRoom(for: .calendar)
                Defaults.Toggle(key: .joinMeetingOnEventTap) {
                    Text("Join meeting when clicking an event")
                }
                .settingsItem("Join meeting when clicking an event")
            } header: {
                SettingsLabel("Home", info: "Today's next three timed events. Clicking one opens it in Calendar, or joins it when it has a meeting link and this is on.")
            }

            // Underbrim: not before access was asked for (the button above asks).
            if calendarManager.calendarAuthorizationStatus != .notDetermined {
                Section(header: Text("Calendars")) {
                    if calendarManager.calendarAuthorizationStatus != .fullAccess {
                        PermissionDeniedNotice(
                            message: "Calendar access is denied. Please enable it in System Settings.",
                            buttonTitle: "Open Calendar Settings",
                            privacyPane: .calendars
                        )
                        .settingsItem("Calendars")
                    } else {
                        CalendarList(
                            calendars: calendarManager.eventCalendars,
                            calendarManager: calendarManager,
                            isEnabled: showCalendar || meetingCountdown  // they pick the countdown's meetings too
                        )
                        .settingsItem("Calendars")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
        // Underbrim: reads the current access only; asking is the "Allow Calendar Access…" button's job.
        .onAppear {
            Task { await calendarManager.refreshCalendarStatus() }
        }
    }
}

/// An access-denied explanation with a shortcut to the relevant pane of
/// System Settings → Privacy & Security.
private struct PermissionDeniedNotice: View {
    let message: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    let privacyPane: SystemSettings.Privacy

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding()
            Button(buttonTitle) {
                SystemSettings.open(privacyPane)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A selectable list of calendars with their accent-colored toggles.
private struct CalendarList: View {
    let calendars: [CalendarModel]
    @ObservedObject var calendarManager: CalendarManager
    let isEnabled: Bool

    var body: some View {
        List {
            ForEach(calendars, id: \.id) { calendar in
                Toggle(
                    isOn: Binding(
                        get: { calendarManager.getCalendarSelected(calendar) },
                        set: { isSelected in
                            Task {
                                await calendarManager.setCalendarSelected(
                                    calendar, isSelected: isSelected)
                            }
                        }
                    )
                ) {
                    Text(calendar.title)
                }
                .toggleStyle(.automatic)  // not Settings' switch style, which would tint it amber
                .accentColor(lighterColor(from: calendar.color))
                .disabled(!isEnabled)
            }
        }
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    let nr = lighten(r)
    let ng = lighten(g)
    let nb = lighten(b)

    return Color(red: Double(nr), green: Double(ng), blue: Double(nb), opacity: Double(a))
}

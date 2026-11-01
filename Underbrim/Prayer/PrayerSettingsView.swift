//
//  PrayerSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings › Prayer Times: the place (your location, once, on this Mac; or a town from Apple
//  Maps), the method, Asr and what the notch shows.
//

import Defaults
import MapKit
import SwiftUI

struct PrayerSettingsView: View {
    @Default(.prayerTimesEnabled) private var enabled
    @Default(.prayerPlace) private var place
    @Default(.prayerMethod) private var methodID
    @Default(.prayerAsrHanafi) private var hanafi
    @State private var search = TownSearch()
    private var store: PrayerTimesStore { .shared }

    var body: some View {
        Form {
            if enabled {
                placeSection
                methodSection
                Section(header: Text("Notch")) {
                    Defaults.Toggle(key: .prayerAtTime) { Text("Show each prayer in the notch when its time comes") }
                        .settingsItem("Show each prayer in the notch when its time comes")
                    Defaults.Toggle(key: .prayerSound) {
                        SettingsLabel("Play a soft sound at prayer time", info: "Never during a call or a meeting.")
                    }
                    .settingsItem("Play a soft sound at prayer time")
                    Defaults.Toggle(key: .showPrayerWidget) { Text("Prayer widget on Home") }
                        .homeRoom(for: .prayer)
                        .settingsItem("Prayer widget on Home")
                }
                MoreInAdvanced(.prayer)
            } else {
                Section {
                } header: {
                    SettingsPageHeader(tab: .prayer, isOn: $enabled)
                } footer: {
                    HelpText("The notch shows a prayer only when its time comes. Open the Prayer widget on Home for the next adhan and the time since the last.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Prayer Times")
        .onChange(of: enabled) { _, on in if on { store.turnOn() } }
    }

    private var placeSection: some View {
        Section(header: SettingsPageHeader(tab: .prayer, isOn: $enabled, section: "Place",
                                           info: ["Your location is found once by this Mac and stays on it, and again when you travel to another time zone. A town you search for is looked up with Apple Maps."])) {
            if let place {
                LabeledContent(place.title) {
                    // A format, for Arabic's comma.
                    Text("\(String(format: "%.4f", place.latitude)), \(String(format: "%.4f", place.longitude))")
                        .monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Text("Choose where the times are for.").foregroundStyle(.secondary)
            }
            HStack {
                Button(String(localized: "Use My Location")) { store.locate() }
                    .disabled(store.locating)
                if store.locating { ProgressView().controlSize(.small) }
            }
            .settingsItem("Use My Location")
            if let error = store.locationError { Text(error).font(.caption).foregroundStyle(.secondary) }
            TextField(String(localized: "Search for a town"), text: $search.query)
                .textFieldStyle(.roundedBorder)
                .settingsItem("Search for a town")
            if search.nothingFound { Text("No towns found").foregroundStyle(.secondary) }
            ForEach(search.results, id: \.self) { result in
                Button {
                    Task { if let picked = await search.place(for: result) { place = picked; search.query = "" } else { NSSound.beep() } }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.title)
                        if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var methodSection: some View {
        let automatic = PrayerMethod.forCountry(place?.country)
        return Section {
            Picker(String(localized: "Method"), selection: $methodID) {
                Text("Automatic (\(automatic.name))").tag(String?.none)
                Divider()
                ForEach(PrayerMethod.all) { method in Text(method.name).tag(String?.some(method.id)) }
            }
            .settingsItem("Method")
            Picker(String(localized: "Asr"), selection: $hanafi) {
                Text("Standard (Shafi'i, Maliki, Hanbali)").tag(false)
                Text("Hanafi").tag(true)
            }
            .settingsItem("Asr")
        } header: {
            Text("Method")
        } footer: {
            HelpText("Calculated on your Mac with \(store.method.name). Check once against your local mosque.")
        }
    }
}

struct PrayerAdvancedSettings: View {
    @Default(.prayerAdjustments) private var adjustments
    @Default(.hijriAdjustment) private var hijriAdjustment
    @State private var adjusting = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $adjusting) {
                ForEach(PrayerName.allCases, id: \.self) { name in
                    Stepper(value: $adjustments[name], in: -15...15) {
                        LabeledContent(name.title()) {
                            Text(adjustments[name] == 0 ? String(localized: "As calculated")
                                 : String(localized: "\(adjustments[name]) min"))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                // The words open it too, and VoiceOver can: the triangle alone has no press.
                Button(String(localized: "Adjust Times")) { withAnimation { adjusting.toggle() } }
                    .buttonStyle(.plain)
            }
            .settingsItem("Adjust Times")
            Stepper(value: $hijriAdjustment, in: -2...2) {
                LabeledContent(String(localized: "Hijri date")) {
                    Text(hijriAdjustment == 0 ? String(localized: "Umm al-Qura calendar")
                         : String(localized: "\(hijriAdjustment) days"))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .settingsItem("Hijri date")
        } header: {
            AdvancedHeader(area: .prayer)
        }
    }
}

@MainActor
@Observable
final class TownSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            answered = false
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                withAnimation(animation) { results = [] }
            } else {
                completer.queryFragment = query
            }
        }
    }
    private(set) var results: [MKLocalSearchCompletion] = []
    /// Maps has answered what's typed now: empty results then mean no town, not "still looking".
    private var answered = false
    var nothingFound: Bool { answered && results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty }
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// How the rows come in: in the tour the island grows on its spring; in Settings they just change.
    @ObservationIgnored private let animation: Animation?

    init(animation: Animation? = nil) {
        self.animation = animation
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = Array(completer.results.prefix(5))
        MainActor.assumeIsolated { withAnimation(animation) { results = query.isEmpty ? [] : found; answered = true } }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { withAnimation(animation) { results = []; answered = true } }
    }

    func place(for completion: MKLocalSearchCompletion) async -> PrayerPlace? {
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
        else { return nil }
        let coordinate = item.placemark.coordinate
        let zone = item.timeZone ?? .current
        return PrayerPlace(name: completion.title, latitude: coordinate.latitude, longitude: coordinate.longitude,
                           timeZone: zone.identifier,
                           country: item.placemark.isoCountryCode ?? PrayerCalculation.country(forTimeZone: zone.identifier))
    }
}

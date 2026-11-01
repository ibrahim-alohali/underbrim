//
//  AppLanguage.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI
import Defaults

struct AppLanguage: RawRepresentable, Hashable, Identifiable, Defaults.Serializable {
    static let system = AppLanguage(rawValue: "system")

    var id: String { rawValue }
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Built once: reading every string table on each Settings redraw cost
    /// ~8 ms of main-thread I/O, and the bundle's languages can't change.
    static let allCases: [AppLanguage] = {
        let languages = Bundle.main.localizations
            .filter(isSelectableLocalization)
            .map(AppLanguage.init(rawValue:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return [.system] + languages
    }()

    var displayName: String {
        if self == .system {
            return NSLocalizedString(
                "System default",
                comment: "Language picker option: follow the system app language"
            )
        }

        let displayName = nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
        return displayName.capitalized(with: nativeLocale)
    }

    private var nativeLocale: Locale {
        Locale(identifier: rawValue)
    }

    private static func isSelectableLocalization(_ identifier: String) -> Bool {
        guard identifier != "Base" else { return false }
        guard let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: identifier
        ) else {
            return false
        }

        guard
            let data = try? Data(contentsOf: url),
            let strings = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: String]
        else {
            return false
        }

        return strings.values.contains { !$0.isEmpty }
    }

    func applyAppleLanguagesOverride() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            UserDefaults.standard.removeObject(forKey: "AppleTextDirection")
            UserDefaults.standard.removeObject(forKey: "AppleLocale")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
            // AppKit takes its layout direction from this, not from the language, so a chosen language lays
            // out in its own direction whatever the Mac's.
            UserDefaults.standard.set(Locale.Language(identifier: rawValue).characterDirection == .rightToLeft,
                                      forKey: "AppleTextDirection")
            // Formatters follow the locale, not the language: this language, in the Mac's region.
            let macLocale = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLocale"] as? String
            let region = macLocale.flatMap { Locale(identifier: $0).region?.identifier }
            // The Mac's calendar and number choices ("@calendar=gregorian;numbers=latn") stay.
            let keywords = macLocale?.split(separator: "@", maxSplits: 1).dropFirst().first.map { "@\($0)" } ?? ""
            // The language and its script, without a region of its own: "pt-BR" in the
            // US is "pt_US" (ICU reads "pt-BR_US" as Brazil); "zh-Hans" is "zh_Hans_US".
            let language = Locale.Language.Components(identifier: rawValue)  // as written: no script it doesn't name
            let base = [language.languageCode?.identifier, language.script?.identifier].compactMap { $0 }.joined(separator: "_")
            UserDefaults.standard.set((region.map { "\(base.isEmpty ? rawValue : base)_\($0)" } ?? rawValue) + keywords,
                                      forKey: "AppleLocale")
        }
        UserDefaults.standard.synchronize()
    }
}

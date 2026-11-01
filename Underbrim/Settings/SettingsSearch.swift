//
//  SettingsSearch.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings' search finds single settings: each is listed here with its page and more words
//  people look for it by, in English and Arabic. Picking one opens its page at the setting, lit.
//

import SwiftUI

/// A setting the search finds. `key` is its English name: the catalog key its row shows, and
/// the row's mark (`settingsItem(_:)`) unless it has its own `anchor`.
struct SettingsItem: Hashable {
    let page: SettingsTab
    let key: String
    var words = ""
    var anchor: String?
    /// Lit instead while this row is hidden: the switch it shows with.
    var parent: String?
    var parentPage: SettingsTab?
    var area: AdvancedArea?

    init(area: AdvancedArea, key: String, words: String = "", anchor: String? = nil, parent: String? = nil, parentPage: SettingsTab? = nil) {
        self.init(page: .advanced, key: key, words: words, anchor: anchor, parent: parent, parentPage: parentPage, area: area)
    }

    init(page: SettingsTab, key: String, words: String = "", anchor: String? = nil, parent: String? = nil,
         parentPage: SettingsTab? = nil, area: AdvancedArea? = nil) {
        self.page = page
        self.key = key
        self.words = words
        self.anchor = anchor
        self.parent = parent
        self.parentPage = parentPage
        self.area = area
    }

    /// A page's own switch, lit when a setting hides while its feature is off.
    static let pageSwitch = "page"

    var title: String { Self.name(key) }

    /// Where to look, best first, and the row's name there (it's lit, and VoiceOver says so): the
    /// row; its parent; on Advanced, the switch its area shows with; the page's own switch.
    @MainActor var places: [(page: SettingsTab, mark: String, name: String)] {
        var places: [(page: SettingsTab, mark: String, name: String)] = []
        if area?.inUse != false { places.append((page, anchor ?? key, title)) }
        if let parent { places.append((parentPage ?? page, parent, Self.name(parent))) }
        if let feature = area?.feature { places.append((feature.page, feature.mark, feature.mark == Self.pageSwitch ? feature.page.title : Self.name(feature.mark))) }
        if area == nil { places.append((parentPage ?? page, Self.pageSwitch, (parentPage ?? page).title)) }
        return places
    }

    private static func name(_ key: String) -> String {
        String(localized: String.LocalizationValue(key)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }
}

@MainActor
@Observable
final class SettingsSearch {
    static let shared = SettingsSearch()

    /// The search field writes its text back on Return too: only a change starts the results over.
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    var target: SettingsItem?
    private(set) var lit: String?
    /// Marks on screen, counted: a Form's rows come and go as it scrolls, and
    /// the page going away can still hold a mark the new one has.
    @ObservationIgnored private var shown: [String: Int] = [:]

    struct Result: Hashable {
        let page: SettingsTab
        var item: SettingsItem?

        var title: String { item?.title ?? page.title }
        var place: String {
            guard let item else { return String(localized: "Page") }
            guard let area = item.area else { return page.title }
            return String(localized: "\(page.title) › \(area.title)", comment: "Where a setting is in Settings: a page, then a section of it, as in Advanced › Media.")
        }
        var glyph: Image { item?.area?.glyph ?? page.info.glyph }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var results: [Result] { Self.results(for: query) }

    func move(by step: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + step + count) % count
        let result = results[selection]
        AccessibilityNotification.Announcement("\(result.title), \(result.place)").post()
    }

    func open(_ result: Result) {
        SettingsNavigation.shared.selectedTab = result.item?.places.first?.page ?? result.page
        target = result.item
        query = ""
    }

    func openSelection() {
        let results = results
        if results.indices.contains(selection) { open(results[selection]) }
    }

    func isShown(_ mark: String) -> Bool { shown[mark, default: 0] > 0 }
    func mark(_ mark: String, shows: Bool) { shown[mark] = max(0, shown[mark, default: 0] + (shows ? 1 : -1)) }

    func light(_ mark: String) {
        withAnimation(.easeOut(duration: 0.15)) { lit = mark }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if lit == mark { withAnimation(.easeOut(duration: 0.5)) { lit = nil } }
        }
    }

    /// Pages whose name (or keywords) has every word and settings, together, best first: name
    /// starts with it, a word of the name does, name contains it, a keyword does, the more words.
    /// On a tie a page goes first, then by name. Last, pages whose summary has every word.
    /// One ranking for both, so a page found only by a keyword never hides a setting named so.
    static func results(for query: String) -> [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        // Pages in sidebar order, then settings (all Int.max) by name.
        let pages = SettingsTab.allCases.enumerated().map { (result: Result(page: $1), score: score($1, words), order: $0) }
            .filter { $0.score > 0 }
        let items = index.map { (result: Result(page: $0.page, item: $0), score: score($0, words), order: Int.max) }
            .filter { $0.score > 0 }
        let ranked = (pages + items).sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.order != b.order { return a.order < b.order }
            return a.result.title.localizedStandardCompare(b.result.title) == .orderedAscending
        }
        let described = SettingsTab.allCases.filter { tab in
            let text = fold(tab.info.summary)
            return !pages.contains { $0.result.page == tab } && words.allSatisfy { has(text, $0) }
        }
        return ranked.map(\.result) + described.map { Result(page: $0) }
    }

    /// A page's name counts as a setting's does; its keywords as a setting's other words.
    static func score(_ page: SettingsTab, _ words: [String]) -> Int {
        let name = fold(page.title), more = fold(page.info.keywords + " " + page.info.localWords)
        var total = 0
        for word in words {
            if starts(name, with: word) {
                total += 6
            } else if name.split(separator: " ").contains(where: { starts($0, with: word) }) {
                total += 4
            } else if has(name, word) {
                total += 3
            } else if has(more, word) {
                total += 2
            } else {
                return 0
            }
        }
        return total
    }

    static func score(_ item: SettingsItem, _ words: [String]) -> Int {
        let names = [fold(item.title), fold(item.key)], more = fold(item.words)
        let page = fold([item.page.title, item.area?.title].compactMap { $0 }.joined(separator: " "))
        var total = 0
        for word in words {
            if names.contains(where: { starts($0, with: word) }) {
                total += 6
            } else if names.contains(where: { $0.split(separator: " ").contains { starts($0, with: word) } }) {
                total += 4
            } else if names.contains(where: { has($0, word) }) {
                total += 3
            } else if more.split(separator: " ").contains(where: { starts($0, with: word) }) {
                total += 2
            } else if has(page, word) {
                total += 1
            } else {
                return 0
            }
        }
        return total
    }

    static func starts(_ text: some StringProtocol, with word: String) -> Bool {
        text.hasPrefix(word) || text.hasPrefix("ال" + word) || (word.count > 2 && word.hasPrefix("ال") && text.hasPrefix(word.dropFirst(2)))
    }

    static func has(_ text: some StringProtocol, _ word: String) -> Bool {
        text.contains(word) || (word.count > 2 && word.hasPrefix("ال") && text.contains(word.dropFirst(2)))
    }

    /// Case and accents don't matter, nor Arabic's marks (harakat, tatweel;
    /// Foundation's folding leaves Arabic alone) or the letters people type
    /// either way: a hamza's seat for the bare letter, ة for ه, ى for ي.
    static func fold(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue
            case 0x0622, 0x0623, 0x0625, 0x0671: folded.append("ا")
            case 0x0624: folded.append("و")
            case 0x0626, 0x0649: folded.append("ي")
            case 0x0629: folded.append("ه")
            default: folded.append(scalar)
            }
        }
        return String(folded)
    }
}

extension View {
    func settingsItem(_ mark: String) -> some View { modifier(SettingsItemMark(mark: mark)) }
}

private struct SettingsItemMark: ViewModifier {
    let mark: String
    private let search = SettingsSearch.shared

    func body(content: Content) -> some View {
        content
            .id(mark)
            .background {
                if search.lit == mark {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.effectiveAccent.opacity(0.22))
                        .padding(-5)
                        .transition(.opacity)
                }
            }
            .onAppear { search.mark(mark, shows: true) }
            .onDisappear { search.mark(mark, shows: false) }
    }
}

struct SettingsResultsView: View {
    private let search = SettingsSearch.shared
    @State private var arrows: Any?

    var body: some View {
        let results = search.results
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if results.isEmpty {
                        Text("No settings match “\(search.query)”.")
                            .lineLimit(2).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    } else {
                        // The count is in the island above.
                        ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                            row(result, selected: index == search.selection)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: search.selection) { _, selection in proxy.scrollTo(selection) }
        }
        // The search field's editor takes ↓ ↑ before SwiftUI sees them (onKeyPress never fires):
        // while results show, bare ↓ ↑ in this window move through them, unless an input method
        // is composing.
        .onAppear {
            arrows = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 125 || event.keyCode == 126,
                      event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]),
                      let window = event.window else { return event }
                let step = event.keyCode == 125 ? 1 : -1
                let moved = MainActor.assumeIsolated {
                    guard window.identifier?.rawValue == SettingsWindowController.identifier,
                          (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                    SettingsSearch.shared.move(by: step)
                    return true
                }
                return moved ? nil : event
            }
        }
        .onDisappear {
            if let arrows { NSEvent.removeMonitor(arrows) }
            arrows = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Search results"))
    }

    private func row(_ result: SettingsSearch.Result, selected: Bool) -> some View {
        return Button { search.open(result) } label: {
            HStack(spacing: 12) {
                result.glyph
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.glyph)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    Text(result.place).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.title), \(result.place)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SettingsSearch {
    static let index: [SettingsItem] = [
        SettingsItem(page: .general, key: "Show menu bar icon", words: "status item menubar شريط القائمة أيقونة"),
        SettingsItem(page: .general, key: "Open Underbrim when you log in", words: "startup launch login بدء التشغيل الدخول"),
        SettingsItem(page: .general, key: "Language", words: "arabic english لغة عربي إنجليزي"),
        SettingsItem(page: .general, key: "Open notch on hover", words: "pointer mouse cursor مؤشر تمرير"),
        SettingsItem(page: .general, key: "Compact mode", words: "small smaller minimal مضغوط صغير"),
        SettingsItem(page: .general, key: "Compact island shows", words: "widget swipe compact أداة مضغوط", parent: "Compact mode"),
        SettingsItem(page: .general, key: "Show on all displays", words: "monitors screens external شاشات خارجية"),
        SettingsItem(page: .general, key: "Displays without a notch", words: "island floating capsule dynamic external monitor imac mac mini جزيرة عائمة شاشة خارجية",
                     parent: "Show on all displays"),
        SettingsItem(page: .general, key: "Show notch on lock screen", words: "locked قفل"),
        SettingsItem(page: .general, key: "Hide from screen sharing and recording", words: "screenshot capture sharing call meeting مشاركة الشاشة تسجيل لقطة مكالمة"),
        SettingsItem(page: .general, key: "Toggle Notch Open", words: "keyboard shortcut hotkey open close اختصار لوحة المفاتيح فتح"),
        SettingsItem(page: .general, key: "Open Scratchpad", words: "keyboard shortcut hotkey note notes scratchpad اختصار لوحة المفاتيح ملاحظة ملاحظات"),
        SettingsItem(page: .appearance, key: "Accent color", words: "colour custom system preset tint لون مخصص"),
        SettingsItem(page: .appearance, key: "Shadow and edge light", words: "glow ظل حافة توهج"),
        SettingsItem(page: .appearance, key: "A face when idle", words: "face idle وجه"),
        SettingsItem(page: .widgets, key: "Quick Launch apps", words: "dock launcher favorites spots pin تطبيقات تشغيل سريع تثبيت"),
        SettingsItem(page: .widgets, key: "Unread badges", words: "badge count شارة غير مقروء"),
        SettingsItem(page: .widgets, key: "Open the apps with ⌃⌥1 to ⌃⌥9 from any app", words: "keyboard shortcut hotkey control option number اختصار لوحة المفاتيح"),
        SettingsItem(page: .widgets, key: "Tabs", words: "order reorder tab bar ترتيب"),
        SettingsItem(page: .widgets, key: "Flip video", words: "mirror flip horizontal قلب عكس", parent: HomeWidget.mirror.settingsMark),
        SettingsItem(page: .widgets, key: "Camera", words: "webcam device mirror كاميرا مرآة", parent: HomeWidget.mirror.settingsMark),
        SettingsItem(page: .widgets, key: "Frame shape", words: "circle square mirror شكل دائرة مربع مرآة", parent: HomeWidget.mirror.settingsMark),
        SettingsItem(page: .media, key: "Show what's playing when the notch is closed", words: "live activity now playing يعمل الآن مغلق"),
        SettingsItem(page: .media, key: "Show sneak peek on playback changes", words: "peek song track لمحة أغنية"),
        SettingsItem(page: .media, key: "Sneak Peek Style", words: "peek style نمط لمحة"),
        SettingsItem(page: .media, key: "Media controls", words: "buttons shuffle repeat skip previous next volume أزرار تحكم تكرار خلط"),
        SettingsItem(page: .prayer, key: "Use My Location", words: "location gps place city موقعي مكان"),
        SettingsItem(page: .prayer, key: "Search for a town", words: "city town place مدينة بحث"),
        SettingsItem(page: .prayer, key: "Method", words: "calculation umm al-qura طريقة حساب أم القرى"),
        SettingsItem(page: .prayer, key: "Asr", words: "hanafi shafii madhab عصر حنفي"),
        SettingsItem(page: .prayer, key: "Show each prayer in the notch when its time comes", words: "adhan athan alert أذان تنبيه"),
        SettingsItem(page: .prayer, key: "Play a soft sound at prayer time", words: "adhan sound audio صوت أذان"),
        SettingsItem(page: .prayer, key: "Prayer widget on Home", words: "widget home أداة الرئيسية"),
        SettingsItem(page: .calendar, key: "Count down to meetings in the closed notch", words: "meeting countdown event اجتماع عد تنازلي"),
        SettingsItem(page: .calendar, key: "Start the countdown", words: "minutes before lead دقائق قبل"),
        SettingsItem(page: .calendar, key: "Show calendar on Home", words: "events widget أحداث أداة"),
        SettingsItem(page: .calendar, key: "Join meeting when clicking an event", words: "zoom meet teams link انضمام رابط"),
        SettingsItem(page: .calendar, key: "Calendars", words: "which accounts list تقاويم", parent: "Allow Calendar Access…"),
        SettingsItem(page: .shelf, key: "Quick Share Service", words: "airdrop share sharing مشاركة"),
        SettingsItem(page: .clipboard, key: "Keep clipboard history", words: "copy paste history نسخ لصق سجل"),
        SettingsItem(page: .clipboard, key: "Pause history", words: "pause stop privacy recording إيقاف مؤقت"),
        SettingsItem(page: .clipboard, key: "Never keep copies from", words: "exclude apps ignore passwords record استثناء تطبيقات"),
        SettingsItem(page: .clipboard, key: "Clear Unpinned Items", words: "clear delete مسح حذف"),
        SettingsItem(page: .clipboard, key: "Add new screenshots to the Shelf", words: "screenshot capture لقطة شاشة"),
        SettingsItem(page: .clipboard, key: "Folder", words: "screenshots screenshot location لقطات الشاشة مجلد"),
        SettingsItem(page: .agents, key: "Show coding sessions in the notch", words: "claude code codex sessions جلسات"),
        SettingsItem(page: .agents, key: "Show details on session cards", words: "tasks progress reply file command مهام تقدم رد ملف أمر"),
        SettingsItem(page: .agents, key: "Answer Claude Code in the notch", words: "approve allow deny question plan permission hook موافقة سؤال خطة إذن"),
        SettingsItem(page: .agents, key: "Show agent questions in the notch", words: "open automatically request approval question next step فتح تلقائي طلب سؤال"),
        SettingsItem(page: .agents, key: "Answer Codex in the notch", words: "approval hook codex allow deny موافقة خطاف"),
        SettingsItem(page: .agents, key: "Follow Qwen Code", words: "qwen alibaba hooks sessions جلسات"),
        SettingsItem(page: .agents, key: "Answer Qwen Code in the notch", words: "qwen approval allow deny موافقة"),
        SettingsItem(page: .agents, key: "Follow Qoder", words: "qoder alibaba hooks sessions جلسات"),
        SettingsItem(page: .agents, key: "Answer Qoder in the notch", words: "qoder approval allow deny موافقة"),
        SettingsItem(page: .agents, key: "Follow Cursor", words: "cursor hooks sessions جلسات"),
        SettingsItem(page: .agents, key: "Follow Antigravity", words: "antigravity google gemini plugin sessions جلسات"),
        SettingsItem(page: .agents, key: "Codex plan usage", words: "usage limits plan استخدام حدود"),
        SettingsItem(page: .agents, key: "Play sounds", words: "sound audio chime volume creature صوت أصوات نغمة مستوى"),
        SettingsItem(page: .agents, key: "Claude plan usage from terminal sessions", words: "status line usage limits terminal استخدام الطرفية"),
        SettingsItem(page: .agents, key: "Claude plan usage from the Claude app (unofficial)", words: "usage limits app استخدام"),
        SettingsItem(page: .sound, key: "Show the Sound page", words: "mixer app volume page مازج مستوى صفحة"),
        SettingsItem(page: .sound, key: "Allow levels above 100 %", words: "boost louder 200 limiter تضخيم أعلى"),
        SettingsItem(page: .sound, key: "Keep paused apps", words: "paused tiles متوقف"),
        SettingsItem(page: .sound, key: "Show system sounds", words: "alerts effects تنبيهات مؤثرات"),
        SettingsItem(page: .sound, key: "System Audio Recording", words: "permission privacy tap إذن خصوصية تسجيل"),
        SettingsItem(page: .activities, key: "Show your iPhone's Live Activities", words: "iphone mirroring live activity آيفون"),
        SettingsItem(page: .activities, key: "Follow deliveries from their notifications", words: "delivery orders hungerstation jahez ninja توصيل طلبات"),
        SettingsItem(page: .activities, key: "Show Focus turning on and off", words: "focus do not disturb dnd عدم الإزعاج تركيز"),
        SettingsItem(page: .activities, key: "Show calls", words: "call phone facetime zoom microphone mute مكالمة ميكروفون"),
        SettingsItem(page: .activities, key: "Padlock opening when you unlock", words: "unlock lock padlock قفل فتح"),
        SettingsItem(page: .activities, key: "Caps Lock on and off", words: "capital letters أحرف كبيرة"),
        SettingsItem(page: .activities, key: "Show battery indicator", words: "charge بطارية"),
        SettingsItem(page: .activities, key: "Show battery percentage", words: "percent نسبة"),
        SettingsItem(page: .activities, key: "Show power status notifications", words: "charger plugged unplugged power شاحن"),
        SettingsItem(page: .activities, key: "Show headphone battery", words: "airpods headphones bluetooth سماعات"),
        SettingsItem(page: .activities, key: "Show downloads in the closed notch", words: "download progress تنزيل"),
        SettingsItem(page: .activities, key: "Add finished downloads to the Shelf", words: "shelf finished file رف"),
        SettingsItem(page: .activities, key: "Chrome", words: "google chrome extension كروم إضافة"),
        SettingsItem(page: .notifications, key: "Show notifications in the notch", words: "banners messages إشعارات"),
        SettingsItem(page: .notifications, key: "From all apps", words: "every app تطبيقات"),
        SettingsItem(page: .notifications, key: "Add Application…", words: "allowed apps choose select إضافة تطبيق", parent: "From all apps"),
        SettingsItem(page: .osd, key: "Use accent color", words: "accent colour لون"),
        SettingsItem(page: .osd, key: "Show OSD in open notch", words: "hud indicator open مؤشر"),
        SettingsItem(page: .permissions, key: "Accessibility", words: "device control data access ax trusted وصول التحكم بالجهاز"),
        SettingsItem(page: .permissions, key: "System Audio Recording", words: "audio capture tap sound تسجيل صوت النظام"),
        SettingsItem(page: .permissions, key: "Calendars", words: "events calendar تقويم أحداث"),
        SettingsItem(page: .permissions, key: "Reminders", words: "tasks todo تذكيرات مهام"),
        SettingsItem(page: .permissions, key: "Camera", words: "webcam mirror كاميرا مرآة"),
        SettingsItem(page: .permissions, key: "Location", words: "location services gps موقع"),
        SettingsItem(page: .permissions, key: "Bluetooth", words: "headphones airpods بلوتوث سماعات"),
        SettingsItem(page: .permissions, key: "Automation", words: "apple events applescript terminal music spotify أتمتة"),
        SettingsItem(area: .notch, key: "Notch height on notch displays", words: "size custom real menu bar ارتفاع حجم"),
        SettingsItem(area: .notch, key: "Notch height on non-notch displays", words: "size custom external monitor ارتفاع حجم شاشة خارجية",
                     parent: "Displays without a notch", parentPage: .general),
        SettingsItem(area: .notch, key: "Hover delay", words: "wait pointer time تأخير مؤشر", parent: "Open notch on hover", parentPage: .general),
        SettingsItem(area: .notch, key: "Close delay", words: "wait time closing تأخير إغلاق"),
        SettingsItem(area: .notch, key: "Remember last tab", words: "reopen tab علامة تبويب آخر"),
        SettingsItem(area: .notch, key: "Notch animation", words: "motion spring حركة"),
        SettingsItem(area: .notch, key: "Animation speed", words: "motion faster slower سرعة حركة", parent: "Notch animation"),
        SettingsItem(area: .notch, key: "Enable haptic feedback", words: "haptics vibration trackpad اهتزاز لمس"),
        SettingsItem(area: .notch, key: "Scale corner radius for closed notch", words: "rounded corners زوايا"),
        SettingsItem(area: .notch, key: "Hide title bar", words: "titlebar شريط العنوان"),
        SettingsItem(area: .notch, key: "Hide windows on non-notch displays from Mission Control", words: "spaces exposé"),
        SettingsItem(area: .notch, key: "Always show tabs", words: "tab bar علامات التبويب"),
        SettingsItem(area: .notch, key: "Settings button in the notch", words: "gear cog ترس زر"),
        SettingsItem(area: .displays, key: "Preferred display", words: "monitor screen main شاشة"),
        SettingsItem(area: .displays, key: "Automatically switch displays", words: "monitor main screen شاشة"),
        SettingsItem(area: .media, key: "Media Source", words: "now playing music spotify youtube مصدر وسائط موسيقى"),
        SettingsItem(area: .media, key: "Media inactivity timeout", words: "wait seconds hide paused مهلة"),
        SettingsItem(area: .media, key: "Full screen behavior", words: "fullscreen hide ملء الشاشة إخفاء"),
        SettingsItem(area: .media, key: "Toggle Sneak Peek", words: "keyboard shortcut hotkey peek media اختصار لمحة"),
        SettingsItem(area: .media, key: "Show remaining time instead of duration", words: "time duration الوقت المتبقي مدة"),
        SettingsItem(area: .media, key: "Colored spectrogram", words: "visualizer bars colour مخطط ألوان"),
        SettingsItem(area: .media, key: "Real-time audio waveform", words: "waveform visualizer audio موجة صوت"),
        SettingsItem(area: .media, key: "Player tinting", words: "tint colour album art تلوين"),
        SettingsItem(area: .media, key: "Enable blur effect behind album art", words: "blur glow artwork ضبابية غلاف"),
        SettingsItem(area: .media, key: "Slider color", words: "progress bar seek شريط التقدم لون"),
        SettingsItem(area: .prayer, key: "Adjust Times", words: "minutes offset correct تعديل دقائق"),
        SettingsItem(area: .prayer, key: "Hijri date", words: "islamic calendar umm al-qura هجري تقويم"),
        SettingsItem(area: .shelf, key: "Open the Shelf by default if items are present", words: "files open default ملفات"),
        SettingsItem(area: .shelf, key: "Expanded drag detection area", words: "drag drop area سحب إفلات"),
        SettingsItem(area: .shelf, key: "Copy items on drag", words: "copy move drag نسخ سحب"),
        SettingsItem(area: .shelf, key: "Remove from the Shelf after dragging", words: "remove drag إزالة"),
        SettingsItem(area: .shelf, key: "Keep newer Shelf items in front", words: "order newest first ترتيب أحدث"),
        SettingsItem(area: .clipboard, key: "Keep unpinned items for", words: "days retention delete أيام حذف"),
        SettingsItem(area: .clipboard, key: "Keep at most", words: "items limit maximum عناصر حد"),
        SettingsItem(area: .clipboard, key: "Storage used", words: "size space مساحة تخزين"),
        SettingsItem(area: .clipboard, key: "Delete All History and Its Key…", words: "erase delete key مسح حذف مفتاح"),
        SettingsItem(area: .agents, key: "Include scripted and background runs", words: "background scripts خلفية"),
        SettingsItem(area: .agents, key: "Keep the Mac awake while a session works", words: "sleep awake caffeine power نوم مستيقظ طاقة"),
        SettingsItem(area: .agents, key: "Open Claude app sessions directly", words: "claude app link فتح"),
        SettingsItem(area: .agents, key: "Warn when a limit reaches", words: "usage warning limit alert تنبيه حد استخدام"),
        SettingsItem(area: .agents, key: "Remind me of a waiting request", words: "reminder waiting request sound تذكير طلب انتظار", parent: "Play sounds", parentPage: .agents),
        SettingsItem(area: .agents, key: "Show Backups in Finder", words: "backup files hooks نسخ احتياطية"),
        SettingsItem(area: .battery, key: "Show power status icons", words: "charging icon bolt شحن أيقونة"),
        SettingsItem(area: .battery, key: "Show charging wattage", words: "watts power واط"),
        SettingsItem(area: .downloads, key: "Show progress that browsers report", words: "safari browser progress سفاري متصفح"),
        SettingsItem(area: .downloads, key: "Downloads folder", words: "folder location مجلد التنزيلات"),
        SettingsItem(area: .osd, key: "Brightness Source", words: "display betterdisplay lunar سطوع"),
        SettingsItem(area: .osd, key: "Volume Source", words: "sound صوت"),
        SettingsItem(area: .osd, key: "Keyboard Source", words: "keyboard backlight light إضاءة لوحة المفاتيح"),
        SettingsItem(area: .osd, key: "Option (⌥) Key Behavior", words: "option alt key مفتاح"),
        SettingsItem(page: .about, key: "Version", words: "release about إصدار"),
        SettingsItem(page: .about, key: "Show Welcome Tour", words: "tour welcome intro first run جولة ترحيب"),
        SettingsItem(page: .about, key: "Underbrim on GitHub", words: "github source code repository مصدر"),
        SettingsItem(page: .about, key: "Open-Source Notices", words: "licenses credits copyright notice ترخيص حقوق إشعارات"),
        SettingsItem(page: .about, key: "GNU General Public License, version 3", words: "license gpl رخصة ترخيص"),
        SettingsItem(page: .about, key: "Restart Underbrim", words: "relaunch restart إعادة تشغيل"),
    ] + HomeWidget.allCases.map { SettingsItem(page: .widgets, key: $0.titleKey, words: $0.searchWords, anchor: $0.settingsMark) }
}

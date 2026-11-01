# Architecture

A quick map of the code, so you can find things without searching. The app's
code is grouped by feature: each folder in `Underbrim/` holds a feature's
model, views and Settings page together, and code that several features use
sits in `Core/` and `SharedUI/`.

## Targets

| Folder | What it is |
|---|---|
| `Underbrim/` | The app (SwiftUI and AppKit, macOS 14+) |
| `UnderbrimHelper/` | The helper inside the app: Accessibility checks, notification banners, brightness |
| `Libraries/Shared/` | Code both use: the XPC protocol and the banner it carries, `AXElement` helpers, notification-panel parsing, finding an app from its name |
| `Libraries/RelayKit/`, `Libraries/underbrim-relay/` | The local relay that the agent hooks, Claude Code's status line and the Chrome extension report through, and that the answer hooks wait on. The helper also uses RelayKit's text rules for banners |
| `Libraries/mediaremote-adapter/` | The Now Playing adapter (a vendored copy; see its README) |
| `UnderbrimTests/` | Unit tests for what you can't see in the running app (Swift Testing, plus XCTest where needed) |
| `scripts/` | `release.sh` (build, sign, package), `sign-app.sh`, `make-signing-keychain.sh`, `check-translations.py`, `check-settings-search.py` |

`Underbrim/` is one synchronized folder in the Xcode project: a file you add,
move or rename there needs no project edit. `Info.plist`, the entitlements,
the bridging header and the string catalogs stay at its top.

## The notch, top to bottom (`Underbrim/`)

| Piece | File |
|---|---|
| App start, lock and unlock, shortcuts | `App/UnderbrimApp.swift` (`AppDelegate`); the services that run from launch start in `App/Startup.swift` |
| A window per screen, lock-screen windows, keyboard sessions | `Notch/Window/NotchWindowManager.swift` |
| State for one notch (open, closed, size) | `Notch/NotchViewModel.swift`; what the open island shows and what keeps it open, `Notch/NotchViewModel+Shown.swift` |
| App-wide state (tab, last tab, reopening, the lock screen) | `Notch/NotchViewCoordinator.swift` |
| The volume and brightness display and the closed island's brief notices, and where the levels come from | `OSD/HUDPresenter.swift` |
| The notch's view: its state, shell and layout | `Notch/ContentView.swift`, with the closed island, the HUD, the open page and hover in `ContentView+Closed.swift`, `+HUD`, `+OpenContent` and `+Hover` |
| Which activity has the island, and the bubble | `LiveActivities/LiveActivityStack.swift` (`ActivitySelection`) |
| Open layout (header halves beside the camera, tab below) | `Notch/Shell/OpenNotchLayout.swift` |
| Hover tracking against the island's real outline | `Notch/Shell/IslandPointerWatch.swift` |
| Sizes, margins, corner radii, text styles | `Notch/Shell/NotchMetrics.swift`, `Notch/NotchGeometry.swift` |
| Header (tabs on the left, status and settings on the right) | `Notch/NotchHeader.swift`, `Notch/Tabs/` |
| Home and its widgets | `Home/NotchHomeView.swift`, `Home/Widgets/` (`HomeWidgets.swift` has sizes and order) |
| Accent colour, for Settings and the notch | `Appearance/Color+AccentColor.swift` |
| Volume and brightness display | `OSD/` |
| Shelf (files, AirDrop, Quick Look, context menu) | `Shelf/` |
| Music | `Music/MusicManager.swift`, `Music/Controllers/`, the player's views in `Music/Views/` |
| Settings window | `Settings/`; each feature's page and the island over it sit in the feature's folder, for example `Prayer/PrayerSettingsView.swift` and `Prayer/PrayerIsland.swift`; the island's shell and parts are `Settings/SettingsIsland.swift` and `Settings/SettingsIslandKit.swift` |

## Features

| Folder | Feature |
|---|---|
| `Agents/` | Coding agents: Claude Code and Codex from their own session files, the others through hooks; requests answered in the notch, plan usage and token history (`Usage/`), each agent's creature and sounds (`Creatures/`), and the optional hooks, Antigravity's plugin folder and Claude Code's status line (`Setup/`) |
| `Appearance/` | The island's surface, rim light and accent colour |
| `AudioOutput/` | The output device picker and route |
| `Battery/`, `Devices/` | Battery details, headphone batteries |
| `Calendar/` | Calendar and reminders, and the meeting countdown with Join (`Meetings/`) |
| `Clipboard/` | Clipboard history (an encrypted vault) and screenshots on the Shelf |
| `Downloads/` | Chrome and Safari downloads, and the Chrome extension (`Resources/`) |
| `FirstRun/` | The welcome tour inside the notch |
| `Home/` | Home, its widgets and the widget editor (`Widgets/`) |
| `LiveActivities/` | Calls, iPhone Live Activities (through the menu bar), deliveries, Focus, Caps Lock and unlock flashes, the bubble |
| `Mirror/` | The camera mirror |
| `Music/` | Now Playing, the players' controllers, the visualizer |
| `Notifications/` | Notification banners in the notch |
| `OSD/` | The volume and brightness display and where its levels come from |
| `Prayer/` | Prayer times with adhan-swift: the calculation, a store with one timer, the views |
| `Relay/` | The relay server; `RelayListener`, which links the helper, listens and sends answers back; and `AgentRouter`, which hands each event to the store that owns it |
| `Shelf/` | The Shelf |
| `Sound/` | The Sound page: a volume for each app, through Core Audio process taps |
| `Core/` | Logging, settings keys, screens, app names and icons, the helper's XPC client. `PersonalDefaults.swift` has every setting Underbrim added, with keys starting `personal_`; older settings are in `Constants.swift`, a few of them under new names |
| `SharedUI/` | Views and styles several features use: animations, controls, the progress ring, app icons, scrolling text |

## Conventions

English is the key for every string. All user-visible text is in
`Underbrim/Localizable.xcstrings`, translated into every language the app
ships: Arabic, Chinese (Simplified), French, German, Italian, Japanese,
Korean, Portuguese (Brazil), Russian, Spanish and Turkish.
`scripts/check-translations.py` makes sure each string has all of them, with
the same placeholders as the English, and CI runs it. Arabic is right to
left, except the playback timeline and controls, which stay left to right.

In the notch the accent colour is `Color.notchAccent`; Settings uses
`Color.effectiveAccent`, and text on an accent fill uses `Color.onNotchAccent`.
Colours that carry a meaning, like the green and red of a call, the battery
and warnings, don't follow the accent.

Automatic closes (the pointer leaving, a drag ending, a drop) don't close an
island that something is keeping open. Esc and the shortcut always close it. Locking the Mac closes an island that something is holding open, and
every island unless "Show on lock screen" is on. The camera stops either way.

There are three text styles (`Font.notchTitle`, `.notchBody`,
`.notchCaption`), one symbol weight, and monospaced digits for numbers that
change.

Nothing about you leaves the Mac. The only requests out are album artwork
and the town search for prayer times (Apple Maps). Prayer times look up your
location when you ask, and again if the Mac's time zone changes while
they're on. The location stays on the Mac.

## Build and test

```sh
xcodebuild -project Underbrim.xcodeproj -scheme Underbrim -configuration Debug build
xcodebuild -project Underbrim.xcodeproj -scheme Underbrim -configuration Release build  # as CI and the README do
xcodebuild -project Underbrim.xcodeproj -scheme Underbrim build-for-testing  # compiles the tests, runs nothing
xcodebuild -project Underbrim.xcodeproj -scheme Underbrim -destination 'platform=macOS,arch=arm64' test  # arch=x86_64 on an Intel Mac
xcodebuild ... test -testLanguage ar    # the same tests in Arabic, or any of the app's languages
python3 scripts/check-translations.py   # every string in every language; CI runs this first
python3 scripts/check-settings-search.py  # every Settings search entry has a row marked for it; CI runs this next
```

The tests run inside the app, with the release's bundle id, so they use an
installed Underbrim's settings and its folder,
`~/Library/Application Support/Underbrim`, where the Shelf and the Scratchpad
note live. Before you run them:

1. Quit Underbrim.
2. Back up its settings with
   `defaults export io.github.ibrahim-alohali.underbrim <file>`, and restore
   them afterwards with `defaults import`.
3. Copy the folder's `Shelf` and `Scratchpad.txt`.
4. Turn clipboard history off while they run, so the build under test doesn't
   keep what you copy meanwhile.

A Debug build keeps its own clipboard history in `Clipboard-Debug`, with its
key next to it.

The agent hooks, Claude Code's status line and the Chrome extension reach the
app through a link that only a copy in `/Applications` or `~/Applications`
sets up. A build that runs from Xcode's build folder leaves the link alone, so
copy it to one of those folders to try those features with your changes.

To run a single Swift Testing test, add `()` to its name:
`-only-testing:UnderbrimTests/HookInstallerTests/invalidFilesAreNeverTouched()`.
Without the parentheses nothing runs, and xcodebuild still reports success.

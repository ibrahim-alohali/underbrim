# Security

## Supported versions

Only the latest release and the `main` branch get security fixes.

## Reporting a vulnerability

Please report security problems privately with the repository's
["Report a vulnerability"](https://github.com/ibrahim-alohali/underbrim/security/advisories/new)
form, not in a public issue. I'll reply with the next steps and keep you
posted until a fix ships.

Problems in third-party dependencies are best reported to the people who
maintain them.

## Notes for auditors

### Private macOS APIs

Some features aren't possible with the public SDK, so Underbrim uses private
macOS frameworks and functions:

- the notch window lives in a private SkyLight space (`Underbrim/private/`);
- Now Playing comes from the private `MediaRemote.framework`, through the
  vendored [MediaRemoteAdapter](../Libraries/mediaremote-adapter/README.md);
- the volume and brightness display uses private DisplayServices and
  brightness functions;
- the Unread widget reads Dock badges with LaunchServices'
  `_LSCopyApplicationInformationItem`;
- the Calls widget uses the kernel's
  `responsibility_get_pid_responsible_for_pid` to name the app behind a helper
  that's using the microphone;
- the coding agent sounds stay quiet while the screen is shared or recorded,
  which SkyLight's `SLSIsScreenWatcherPresent` reports;
- the Sound page checks and asks for the System Audio Recording permission
  with TCC's `TCCAccessPreflight` and `TCCAccessRequest`, since macOS has no
  public call that tells whether it's allowed;
- Security's `SecTranslocateCreateOriginalPathForURL` lets the app restart
  from where it really is when macOS has moved it to a translocated path.

These aren't documented, can change with any macOS update, and a feature may
stop working without warning when they do. They're also why Underbrim isn't
in the App Store.

### The helper

Neither the app (`Underbrim/Underbrim.entitlements`) nor the XPC helper inside
it (`UnderbrimHelper/UnderbrimHelper.entitlements`) is sandboxed. The app reads
the status files coding agents keep and runs the `codex` tool, and the helper
uses the Accessibility API and private frameworks for the notification and
brightness features. The helper is deliberately small: it has a narrow, typed
protocol (`Libraries/Shared/UnderbrimHelperProtocol.swift`) and is only reachable
from the app it ships in. If you're auditing, treat it as the most trusted
part of the project. Its attack surface is the XPC protocol and what it reads
through the Accessibility API. For the brightness display it can also start
Lunar's command-line tool, but only when `/Applications/Lunar.app` carries
the signature of Lunar's developer, checked right before it starts.

Every program the app or the helper starts gets a minimal environment, so
variables another program sets for your session (such as `PERL5OPT` or
`ZIPOPT`) can't change what it runs.

At signing, releases give the app (not the helper) one more entitlement,
which isn't in the entitlements file:
`com.apple.security.cs.disable-library-validation`.
Underbrim is self-signed, so its code has no Team ID for library validation to
match, and without it the app couldn't load its own embedded frameworks (see
`scripts/sign-app.sh`). The cost is that macOS no longer checks who signed a
library the app loads. The app loads frameworks only from its own bundle and
from macOS, and the hardened runtime still ignores `DYLD_` environment
variables. One way in remains: the system color panel, which the color
pickers in Settings open, loads color picker plug-ins from
`~/Library/ColorPickers`, so a program running as you could put code there
that then runs inside Underbrim.

### The MediaRemote adapter

`Libraries/mediaremote-adapter/` holds binaries built from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter).
Its [README](../Libraries/mediaremote-adapter/README.md) has the pinned upstream version
and how to rebuild it. The binaries are ad hoc signed, so they can't be checked
bit for bit against upstream's.

### Coding agents, the local relay and stored data

- Claude Code and Codex sessions are read from the files those tools keep
  anyway. Only a fixed set of fields is parsed: status, folder, title, record
  types, times, tool names and token counts, and while session details are on
  (the default), the tool's target, the task list and the start of the last
  prompt and reply, each cut to a set length. Those stay in memory and are
  never logged. Only token counts per day are written to disk
  (`token-history.json` in Application Support). Claude Code's session key
  files are never opened.
- The agent hooks, Claude Code's status line and the Chrome extension send
  events to the app over a Unix socket in a private folder (0700) in
  Application Support. The socket
  is 0600, the app only accepts connections from the same user (checked with
  `getpeereid`), and malformed or oversized messages are dropped. The hooks and
  the status line run the relay through a link in the same folder, and the app
  only points that link at a copy of itself installed in `/Applications` or
  `~/Applications`, never at one running from a disk image or a download.
- The answer hooks (Claude Code, Codex, and Qwen Code and Qoder when answering
  is on) wait on that socket for an answer given in the notch and print it as
  the hook's reply. Nothing is approved without a click: Allow All, marked as
  a warning, approves only the requests waiting at that moment. When the app
  isn't running or gives no answer, the hook prints nothing and exits
  successfully, so the agent asks in its own window as usual. Codex and Qwen
  Code get their request back after 10 minutes. Other agents also read Claude
  Code's hook settings, so the Claude hook answers only requests from the
  Claude Code process that started it. Turning on the Codex hook also marks it
  as trusted in Codex through `codex app-server`.
- The progress hooks (Qwen Code, Qoder, Cursor) and Antigravity's plugin print
  nothing and always exit successfully. Adding or removing any hook backs up
  the agent's settings file first and only touches Underbrim's own entries.
  Antigravity's hooks are a plugin folder of Underbrim's own, removed only
  while it holds nothing but Underbrim's files. Turning on the status line
  writes `~/.claude/settings.json` the same way, with a backup first, and never
  replaces an existing status line.
- To answer the question the Claude app shows under a reply, the app presses
  the matching button in Claude's window through Accessibility, only when the
  question and its buttons match the ones shown in the notch. If the button
  only reacts to a real pointer, the app brings Claude to the front, posts a
  click on it and puts the pointer back.
- Session cards list the TCP ports that the agent's child processes, or other
  processes working in its folder (not apps), listen on, read with libproc
  while the Agents page is open. Stop sends SIGTERM to that process, and only
  if it still serves the port.
- Codex plan usage, when it's turned on, runs the local `codex app-server`,
  which asks OpenAI with your existing Codex login. Underbrim checks that
  `codex` is signed by OpenAI right before starting it.
- Clipboard history is sealed with AES-GCM. Its key is sealed in turn by a
  key in this Mac's Secure Enclave and kept next to the history, so neither
  opens on another Mac. A program already running as you on this Mac can use
  that file to open the history, as it could read the clipboard while you
  copy, and it could plant a key file of its own before the first one exists
  (on first use, or right after Delete All History and Its Key) and know the
  key. The history folder, key included, is kept out of Time Machine backups,
  though the local snapshots macOS keeps for up to a day can still hold it,
  and other backup tools may copy it.
- History that an earlier version sealed with a Keychain key this version
  can't read without macOS asking is set aside, and read only when you click
  Bring It Back, which asks macOS for that key. Deleting that Keychain item
  would ask too, so the app leaves it; delete it in Keychain Access.
- On a Mac without a Secure Enclave the key is kept in the login Keychain,
  where only code signed as Underbrim can read it, and a program running as
  you could plant that item in the same way.
- With Accessibility allowed, the app reads the Live Activities in the menu
  bar: only the items from MenuBarAgent and the Live Activity renderer, never
  other apps' status items. Their text stays in memory and is never logged.
  Clicking an activity in the notch presses that item through Accessibility,
  after first pressing the menu bar's button for hidden items when the item is
  tucked behind the notch. The Caps Lock flash listens for modifier-key changes
  and nothing else.
- Deliveries use the helper's notification reader. Banners from the apps you
  list get through its filter by name, and their text stays in memory until the
  order ends.
- The Sound page lists the apps playing sound from Core Audio. An app set
  away from its normal level, or muted, plays through a Core Audio process tap
  and an aggregate device of its own, which needs System Audio Recording. The
  sound passes through in memory and is never recorded or saved, and the tap
  goes away when the app is back at its normal level.
- The app makes these network requests on its own: album artwork from the
  address the music app reports, and, for prayer times, the town name you type
  into the search, which goes to Apple Maps (MapKit). It has no updater. The
  YouTube Music bridge only talks to `localhost`. Nothing else about you is sent
  anywhere, and your location for prayer times never leaves the Mac.

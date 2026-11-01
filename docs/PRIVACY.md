# Privacy

Underbrim has no account and doesn't send anything about you anywhere. The
only requests it makes on its own are album artwork from the address your
music app gives it, and the town search for prayer times, which sends what you
type to Apple Maps.

Several features need Accessibility, which macOS 27 calls "Device Control and
Data Access". Underbrim asks for it only when you turn one of them on.

Some features read things on your Mac, and most of them are off until you
turn them on:

- Coding Agents (off until you turn it on in the first-run tour or Settings >
  Coding Agents) reads the files Claude Code and Codex already keep about
  their sessions: Claude Code's status files (`~/.claude/sessions/*.json`, with
  the state, folder and title) and transcripts (`~/.claude/projects`), and
  Codex's logs (`~/.codex/sessions`) and thread names
  (`~/.codex/session_index.jsonl`). From transcripts and logs it reads record
  types, times, tool names and token counts. With "Show details on session
  cards" (on by default) it also reads the file or command a tool is working
  on, the task list, and the start of your last message and of the reply.
  These stay in memory and are never saved or sent; only the token counts per
  day are kept, in `~/Library/Application Support/Underbrim`. It never opens
  the `.key` files next to the status files, and reading them changes nothing
  in either app.
- "Answer Claude Code in the notch" and "Answer Codex in the notch" (off until
  you turn them on) each add one hook, to `~/.claude/settings.json` and
  `~/.codex/hooks.json`. The hook passes an approval request (and Claude's
  questions and plans) to the notch, waits for your answer there and hands it
  to the agent. Nothing is approved without your click. Claude asks in its own
  window at the same time, and the first answer counts. Codex waits, and asks
  in its own window again when you switch to it, after 10 minutes, or straight
  away if Underbrim isn't running. Turning on the Codex hook also marks it as
  trusted in Codex, as Codex's own hook review would. Turning either off
  removes only Underbrim's entry.
- Under More agents, following Qwen Code, Qoder or Cursor adds hooks to
  `~/.qwen/settings.json`, `~/.qoder/settings.json` or `~/.cursor/hooks.json`
  that report a session's progress, and following Antigravity adds a plugin
  folder of Underbrim's own, `~/.gemini/config/plugins/underbrim`. Qwen Code
  and Qoder can also be answered in the notch. Cursor and Antigravity ask for
  approvals in their own windows. Turning one off removes only Underbrim's
  hooks.
- When an agent asks something, the island opens on its own without taking
  the keyboard ("Show agent questions in the notch", on by default). For the
  question the Claude app shows under a reply, your click in the notch presses
  the matching button in Claude's window, through Accessibility. If that
  button only reacts to a real pointer, Underbrim brings Claude to the front,
  clicks it and puts the pointer back.
- Session cards list the local ports a session's commands serve, such as a
  dev server, read from the process list while the Agents page is open. Its
  Stop button ends that process. "Keep the Mac awake while a session works"
  (on by default) stops the Mac from going to sleep on its own in the middle
  of a task.
- Claude plan usage comes from the readings the Claude app saves on disk
  (unofficial, and labelled that way), which is on from the start and can be
  turned off in Settings > Coding Agents. You can also turn on "Claude plan
  usage from terminal sessions", which adds Claude Code's status line to
  `~/.claude/settings.json`. Underbrim backs that file up first and never
  replaces a status line of your own. Your Claude login is never read.
- Codex plan usage (off until you turn it on) asks the `codex` command-line
  tool already on your Mac, which asks OpenAI with your existing login, as
  Codex itself does. Underbrim only runs a copy signed by OpenAI, like the one
  inside the ChatGPT app.
- Clipboard history keeps what you copy, encrypted with a key sealed by this
  Mac's Secure Enclave (in your Keychain on a Mac without one), and notes
  where it came from: the app, another of your devices or the Screenshot tool. Nothing is recorded while the screen is locked. It's
  on for new installs, and the first-run tour lets you turn it off.
- Screenshots on the Shelf (off by default) picks up new files in your
  screenshot folder, the Desktop unless you pick another, that macOS marks as
  screenshots. The Shelf points to the files and doesn't copy them.
- Notifications in the notch (off by default) reads the banners macOS shows,
  from the apps you choose or from all of them, through Accessibility. Their
  text stays in memory.
- Live Activities (off by default) reads the Live Activities macOS shows in
  the menu bar, through Accessibility. Other apps' menu bar items aren't read,
  and what it reads stays in memory.
- Deliveries (off by default) reads the banners of the delivery apps you list,
  through the same notification reader as notifications in the notch, and
  keeps their text in memory until the order ends.
- Focus (off by default) reads the banner macOS shows when a Focus turns on or
  off, through Accessibility, and shows it in the notch instead. The first-run
  tour turns it on with the volume and brightness display.
- Calls (on by default) checks which app is using the microphone. No audio is
  captured. Only the Leave button needs Accessibility: it presses Zoom's or
  Teams' own shortcut, or Discord's Disconnect button. So that Leave works at
  once, Underbrim asks Discord during a call to describe its window through
  Accessibility, as a screen reader would, and lets that go when the call
  ends. It looks there only for the Disconnect button, and for the Close
  button of a Discord settings screen covering it.
- The volume and brightness display (off by default) watches the volume and
  brightness keys, which needs Accessibility.
- The mirror uses your camera only while it's on screen, and the camera stops
  as soon as the mirror can't be seen.
- Headphone battery (off by default) shows the levels your Bluetooth
  headphones report.
- Caps Lock (off by default) looks only at whether Caps Lock is on, through
  Accessibility. The first-run tour turns it on with the volume and brightness
  display.
- Downloads uses the progress browsers report to macOS for your Downloads
  folder and, if you install it, a small Chrome extension that can only see
  downloads.
- Calendar and meetings use your calendars, through the access you allow.
- Prayer times use either your location, which you allow and which never
  leaves your Mac (it's saved to about a kilometre), or a town you pick. They're on for new installs, and the
  first-run tour asks where you are.
- Lunar or BetterDisplay report brightness changes to Underbrim, but only if
  you pick one of them as the brightness source.
- The waveform listens to the sound your Mac is playing, with macOS's "System
  Audio Recording Only" permission, just to draw the bars while they're on
  screen. Nothing is recorded or saved. It's on for new installs, and the
  first-run tour asks for the permission. Without it, nothing is captured.
- The Sound page (on by default) lists the apps playing sound. Changing an
  app's volume needs the same "System Audio Recording Only" permission, which
  it asks for only from its Allow button: an app you set away from its normal
  level plays through a private tap at that level. Nothing is recorded or
  saved. Apps in a call are left alone unless you move their slider. Per-app
  volume needs macOS 14.4 or later.
- Quick Launch (on by default) ranks apps by how often you switch to them,
  counted on your Mac and starting from Spotlight's record of how often you
  open each one. Older use counts for less, and turning Quick Launch off stops
  the counting.
- The Scratchpad widget saves what you type in a private file on your Mac.
  Sending it to Things, Todoist, Bear, Obsidian or Drafts goes through that
  app's own link, and only when you choose to.
- The other widgets:
  - Reminders shows your open reminders and asks for access only from its own
    button.
  - Shortcuts lists your shortcuts with macOS's `shortcuts` command, which also
    runs the one you click.
  - Unread counts the badges chat and mail apps put on their Dock icons.
  - Calls shows which app is using the microphone, with a switch that mutes
    the microphone for every app.
  - System shows CPU, memory and network use while it's on screen.

  These, like the Scratchpad, are off until you add them to Home.

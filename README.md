# NotchPad

A macOS notch panel. Hover the notch (or press ⌥⌘N) to open it.

| Tab | What it does |
|---|---|
| Home | Ask bar (quick `claude -p` answers, Fast = Haiku / Smart = your default model), clock, next events, open tasks, quick note, Now Playing |
| Calendar | Month grid of your macOS Calendar events; add an event to the selected day |
| Notes | Write, save (⌘S) and delete notes (stored in `~/Library/Application Support/NotchPad/notes.json`) |
| Tasks | Add tasks; each open task with 🔔 gets an hourly notification and a peek from the notch |
| Claude | A real terminal running `claude` in a folder you pick; "Continue last" runs `claude --continue` |
| Clipboard | Last 40 copied strings, in memory only; password-manager copies are skipped |
| Focus | Pomodoro-style timer; the countdown shows beside the notch while it runs |

Now Playing reads macOS's system Now Playing (YouTube Music in a browser, Spotify, …) through a JXA helper run by `/usr/bin/osascript`, since Apple only lets its own binaries read MediaRemote. Cover art comes from the iTunes catalog. The equalizer follows the real audio through a private Core Audio tap on system output (levels only, nothing recorded; status in `visualizer-status.txt`), falling back to an animation if the tap isn't allowed.

Claude chats launched from the notch get `--settings` with hooks that call `NotchPad --hook <event>`; the notch shows when a chat is working (orange), needs you (yellow) or finished while you weren't looking (cyan), and drops a peek you can hover to jump to that chat.

Closed notch "ears" show album art and the equalizer while music plays, the open-task count, a green dot while Claude is running, and the timer.
📌 pins the panel open (useful while coding). Esc closes it (except in the Claude tab, where Esc goes to the terminal).

URL scheme: `notchpad://open/<home|calendar|notes|tasks|code|clipboard|timer>`, `notchpad://claude/start`, `notchpad://ask?q=…`, `notchpad://close`.

Google Calendar: add the Google account in System Settings → Internet Accounts; NotchPad reads everything macOS Calendar has.

Chats are saved to `chats.json` and come back after a relaunch: each tab keeps its folder and name, and Claude chats `--resume` their conversation (Claude's session id is captured by a SessionStart hook) the first time you open them.

Drag files onto the notch to start a Claude chat with them (a folder opens the chat there) or paste their paths into the current chat. ⌘1–⌘7 switch tabs; notes can be pinned and searched.

## Build

```sh
./scripts/setup-signing.sh   # once: self-signed identity in its own keychain, so permissions survive rebuilds
./build.sh   # builds, ad-hoc signs, installs ~/Applications/NotchPad.app
```

Needs only the Xcode Command Line Tools. Two workarounds make that possible:
- `Vendor/SwiftTerm` is SwiftTerm 1.20.0 with `Shaders.metal` copied instead of compiled (the Metal compiler ships only with full Xcode; SwiftTerm's default renderer doesn't need it).
- Views use `@ViewState` (a typealias for `State`) because `@State` is a macro in the macOS 27 SDK whose plugin isn't in the CLT.

Launch at login and Quit live in the menu bar icon.

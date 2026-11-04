import AppKit

// `NotchPad --hook <event>`: invoked by Claude Code hooks in notch chats; forwards and exits.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--hook" {
    ClaudeHooks.relay(event: CommandLine.arguments[2])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AppKit
import Foundation

/// What a Claude chat is doing, as reported by Claude Code hooks.
enum ChatActivity: Equatable {
    case idle
    case working
    case needsYou(String)
    /// Finished a turn while you weren't looking at it.
    case finished
}

/// Wires Claude Code hooks back into NotchPad.
///
/// Chats launched from the notch get `--settings <hooks file>`; each hook runs this same binary as
/// `NotchPad --hook <event>`, which forwards the event over a distributed notification and exits.
enum ClaudeHooks {
    static let notificationName = Notification.Name("com.naman.notchpad.hook")
    static let sessionEnvKey = "NOTCHPAD_SESSION"

    /// Writes the hooks settings file (once per launch, so it always points at the current binary).
    static let settingsPath: String = {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        func hook(_ event: String) -> [String: Any] {
            ["hooks": [["type": "command", "command": "'\(exe)' --hook \(event)", "timeout": 5]]]
        }
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [hook("start")],
                "UserPromptSubmit": [hook("working")],
                "PostToolUse": [hook("working").merging(["matcher": "*"]) { a, _ in a }],
                "Notification": [hook("notify")],
                "Stop": [hook("stop")],
            ],
        ]
        let url = Storage.dir.appendingPathComponent("claude-hooks.json")
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
        return url.path
    }()

    /// Hook-helper mode: read the hook's JSON from stdin, forward it to the running app, exit fast.
    static func relay(event: String) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let info: [String: String] = [
            "session": ProcessInfo.processInfo.environment[sessionEnvKey] ?? "",
            "event": event,
            "message": json["message"] as? String ?? "",
            "type": json["notification_type"] as? String ?? "",
            // Claude's own conversation id, so the chat can be resumed after NotchPad relaunches.
            "claudeSession": json["session_id"] as? String ?? "",
        ]
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil, userInfo: info, deliverImmediately: true)
        exit(0)
    }
}

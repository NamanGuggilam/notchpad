import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        TerminalHost.shared.restore()
        NotchController.shared.start()
        TasksStore.shared.startReminderLoop()
        ClipboardStore.shared.start()
        NowPlaying.shared.start()
        AudioLevels.shared.follow(NowPlaying.shared)
        setUpStatusItem()
        registerHotKey()
    }

    /// notchpad://open/<tab>, notchpad://close (handy from Raycast/Shortcuts).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "notchpad" {
            if url.host == "close" {
                NotchController.shared.close()
            } else if url.host == "ask" { // notchpad://ask?q=...
                NotchController.shared.open(tab: .home, focus: true)
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
                if let q { AskStore.shared.ask(q) }
            } else if url.host == "claude", url.lastPathComponent == "toggle-size" { // notchpad://claude/toggle-size
                NotchController.shared.open(tab: .code, focus: true)
                let state = NotchController.shared.state
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { state.codeExpanded.toggle() }
            } else if url.host == "claude" { // notchpad://claude/start
                NotchController.shared.open(tab: .code, focus: true)
                TerminalHost.shared.add()
            } else {
                NotchController.shared.open(tab: NotchTab(rawValue: url.lastPathComponent), focus: true)
            }
        }
    }

    // Show banners even though we're the "active" app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { NotchController.shared.open(tab: .tasks, focus: true) }
        completionHandler()
    }

    // MARK: Menu bar item (quit, launch at login)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchPad")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open NotchPad  (⌥⌘N)", action: #selector(openPad), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openPad() { NotchController.shared.open(tab: .home, focus: true) }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Global hotkey ⌥⌘N (Carbon hotkeys need no Accessibility permission)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { NotchController.shared.toggleFromHotKey() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E504144), id: 1) // 'NPAD'
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

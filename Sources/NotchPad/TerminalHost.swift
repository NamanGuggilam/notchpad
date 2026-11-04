import AppKit
import Combine
import SwiftTerm
import SwiftUI

/// One tab in the Claude panel: a live terminal running `claude` (or a plain shell) in a folder. Stays alive across tab switches and open/close.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let directory: String
    let number: Int
    /// Plain shell tab, no claude.
    let isShell: Bool
    @Published var running = false
    @Published var title = ""
    @Published var activity: ChatActivity = .idle
    /// Set by renaming the tab; nil = folder-based name.
    @Published var customName: String?
    /// Claude's conversation id (reported by hooks); used to `--resume` after a relaunch.
    var claudeSessionID: String?
    /// Restored from a previous launch but not started yet (started when you first look at it).
    var needsStart = false
    /// Text to type into claude's prompt once it's up (e.g. paths of files dropped on the notch).
    var pendingInput: String?

    /// Types text into the terminal as a paste (bracketed when the app asked for it), without pressing Enter.
    func paste(_ text: String) {
        if view.getTerminal().bracketedPasteMode {
            view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            view.send(txt: text)
        }
        focus()
    }

    /// Hand over pending input once claude has started (or after a fallback delay).
    func deliverPendingInput(after delay: Double) {
        guard pendingInput != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let text = self.pendingInput else { return }
            self.pendingInput = nil
            self.paste(text)
        }
    }
    var cancellables = Set<AnyCancellable>()

    let view: LocalProcessTerminalView = {
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        v.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        v.nativeBackgroundColor = NSColor(white: 0.06, alpha: 1)
        v.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        v.caretColor = .systemOrange
        return v
    }()

    init(directory: String, number: Int, isShell: Bool) {
        self.directory = directory
        self.number = number
        self.isShell = isShell
        super.init()
        view.processDelegate = self
    }

    var name: String {
        if let customName { return customName }
        let base = (directory as NSString).lastPathComponent
        let folder = directory == NSHomeDirectory() ? "~" : base
        let label = isShell ? "$ \(folder)" : folder
        return number > 1 ? "\(label) \(number)" : label
    }

    /// Launches `claude` through an interactive login zsh (so PATH from .zshrc/.zprofile applies),
    /// then falls back to a shell in the same folder when claude exits. Shell tabs just get the shell.
    func start(extraArgs: String = "") {
        if running { view.terminate() }
        var env = ProcessInfo.processInfo.environment
        // If NotchPad itself was launched from inside a Claude Code session, don't let its markers leak in:
        // they make each chat think it's a child session (transcripts off, so --continue/--resume can't find it).
        // The login shell re-exports anything the user's own rc files set (e.g. ANTHROPIC_API_KEY).
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_")
            || ["CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_API_KEY"].contains(key) {
            env.removeValue(forKey: key)
        }
        env[ClaudeHooks.sessionEnvKey] = id.uuidString
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let shell = env["SHELL"] ?? "/bin/zsh"
        let cmd = isShell ? "exec \(shell) -il" : "claude --settings '\(ClaudeHooks.settingsPath)' \(extraArgs); echo; echo '[claude exited — you are in a shell; type claude to restart]'; exec \(shell) -il"
        view.startProcess(executable: shell, args: ["-ilc", cmd],
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: directory)
        running = true
        activity = .idle
        focus()
    }

    /// Starts a restored chat, resuming its conversation when we know which one it was.
    func startIfNeeded() {
        guard needsStart else { return }
        needsStart = false
        if !isShell, let sid = claudeSessionID, sid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
           Self.transcriptExists(sid) {
            start(extraArgs: "--resume \(sid)")
        } else {
            start() // never had a message (nothing saved to resume), or a shell tab
        }
    }

    /// Claude saves each conversation as ~/.claude/projects/<project>/<session-id>.jsonl once it has a message.
    private static func transcriptExists(_ sid: String) -> Bool {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(sid).jsonl").path) }
    }

    func stop() {
        guard running else { return }
        view.terminate()
        running = false
    }

    func focus() {
        DispatchQueue.main.async { self.view.window?.makeFirstResponder(self.view) }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.running = false
            self.activity = .idle
        }
    }
}

/// All open Claude chats, plus the folder new chats start in.
final class TerminalHost: ObservableObject {
    static let shared = TerminalHost()

    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published private(set) var summary = Summary()

    /// Rolled-up chat state for the closed notch.
    struct Summary: Equatable {
        var running = 0
        var working = 0
        var needsYou = 0
        var finished = 0
    }

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: ClaudeHooks.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo as? [String: String] else { return }
            self?.handleHook(info)
        }
    }
    /// New chats always start in ~/projects (never ~, which makes Claude scan Music/Photos and trigger privacy prompts).
    /// Other folders are still available from the + menu.
    let directory = NSHomeDirectory() + "/projects"
    @Published var recents: [String] = (UserDefaults.standard.stringArray(forKey: "codeRecents") ?? [])
        .filter { $0 != NSHomeDirectory() } {
        didSet { UserDefaults.standard.set(recents, forKey: "codeRecents") }
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    /// Opens a new chat (defaults to the current folder) and switches to it.
    @discardableResult
    func add(in dir: String? = nil, extraArgs: String = "", shell: Bool = false) -> TerminalSession {
        let dir = dir ?? directory
        if dir != directory { rememberRecent(dir) }
        let number = (sessions.filter { $0.directory == dir && $0.isShell == shell }.map(\.number).max() ?? 0) + 1
        let session = TerminalSession(directory: dir, number: number, isShell: shell)
        track(session)
        sessions.append(session)
        selectedID = session.id
        session.start(extraArgs: extraArgs)
        save()
        return session
    }

    /// Keep the closed-notch indicator and the saved chat list in sync with a chat.
    private func track(_ session: TerminalSession) {
        session.$running.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshSummary() } }
            .store(in: &session.cancellables)
        session.$activity.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshSummary() } }
            .store(in: &session.cancellables)
        session.$customName.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.save() } }
            .store(in: &session.cancellables)
    }

    // MARK: Persistence (chats come back after NotchPad relaunches)

    private struct Saved: Codable {
        struct Chat: Codable {
            var directory: String
            var isShell: Bool
            var number: Int
            var customName: String?
            var claudeSessionID: String?
        }
        var chats: [Chat]
        var selected: Int?
    }

    private func save() {
        let chats = sessions.map {
            Saved.Chat(directory: $0.directory, isShell: $0.isShell, number: $0.number,
                       customName: $0.customName, claudeSessionID: $0.claudeSessionID)
        }
        Storage.save(Saved(chats: chats, selected: sessions.firstIndex { $0.id == selectedID }), to: "chats.json")
    }

    /// Recreates last launch's tabs without starting them; each resumes the first time you view it.
    func restore() {
        guard sessions.isEmpty, let saved = Storage.load("chats.json", as: Saved.self) else { return }
        for c in saved.chats where FileManager.default.fileExists(atPath: c.directory) {
            let s = TerminalSession(directory: c.directory, number: c.number, isShell: c.isShell)
            s.customName = c.customName
            s.claudeSessionID = c.claudeSessionID
            s.needsStart = true
            track(s)
            sessions.append(s)
        }
        if let i = saved.selected, sessions.indices.contains(i) { selectedID = sessions[i].id }
        else { selectedID = sessions.first?.id }
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].stop()
        sessions.remove(at: i)
        if selectedID == id {
            selectedID = sessions.isEmpty ? nil : sessions[min(i, sessions.count - 1)].id
        }
        refreshSummary()
        save()
        selected?.startIfNeeded()
        selected?.focus()
    }

    func select(_ id: UUID) {
        selectedID = id
        if selected?.activity == .finished { selected?.activity = .idle }
        selected?.startIfNeeded()
        selected?.focus()
        save()
    }

    /// Opens the notch on a specific chat (used when you act on a status peek).
    func reveal(_ id: UUID) {
        NotchController.shared.open(tab: .code, focus: true)
        select(id)
    }

    private func refreshSummary() {
        var s = Summary()
        for c in sessions {
            if c.running { s.running += 1 }
            switch c.activity {
            case .working: s.working += 1
            case .needsYou: s.needsYou += 1
            case .finished: s.finished += 1
            case .idle: break
            }
        }
        summary = s
    }

    private func isVisible(_ session: TerminalSession) -> Bool {
        let st = NotchController.shared.state
        return st.isOpen && st.tab == .code && selectedID == session.id
    }

    private func handleHook(_ info: [String: String]) {
        guard let session = sessions.first(where: { $0.id.uuidString == info["session"] }) else { return }
        if let cs = info["claudeSession"], !cs.isEmpty, cs != session.claudeSessionID {
            session.claudeSessionID = cs
            save()
        }
        let visible = isVisible(session)
        switch info["event"] {
        case "start":
            session.deliverPendingInput(after: 0.9) // give the prompt a moment to draw
        case "working":
            session.activity = .working
        case "stop":
            session.activity = visible ? .idle : .finished
            if !visible {
                NotchController.shared.peek(Peek(text: "Claude finished in \(session.name)", symbol: "checkmark.circle.fill",
                                                 tint: .green, sound: "Pop") { [weak self] in self?.reveal(session.id) })
            }
        case "notify":
            // The 60s "waiting for your input" nudge after a finished turn is noise; we already said it finished.
            if info["type"] == "idle_prompt" { return }
            let message = info["message"].flatMap { $0.isEmpty ? nil : $0 } ?? "Claude needs your input"
            session.activity = .needsYou(message)
            if !visible {
                NotchController.shared.peek(Peek(text: "\(session.name) · \(message)", symbol: "exclamationmark.bubble.fill",
                                                 tint: .yellow, sound: "Glass", seconds: 8) { [weak self] in self?.reveal(session.id) })
            }
        default:
            break
        }
    }

    // MARK: Files dropped on the notch

    /// Paths escaped the way Terminal does when you drag files in; Claude reads them (images become attachments).
    static func pathsText(_ urls: [URL]) -> String {
        let special = Set(" ()'\"&;$`!*?[]{}<>|#~")
        return urls.map { url in
            String(url.path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
        }.joined(separator: " ") + " "
    }

    /// One folder → a chat in that folder. Files → a chat in the default folder with their paths typed in.
    func newChat(with urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotchController.shared.state.tab = .code
        var isDir: ObjCBool = false
        if urls.count == 1, FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir), isDir.boolValue {
            add(in: urls[0].path)
            return
        }
        let session = add()
        session.pendingInput = Self.pathsText(urls)
        session.deliverPendingInput(after: 6) // fallback if the start hook never arrives
    }

    /// Paste the paths into the chat you're looking at.
    func addToCurrent(_ urls: [URL]) {
        guard let s = selected, !urls.isEmpty else { return newChat(with: urls) }
        NotchController.shared.state.tab = .code
        s.startIfNeeded()
        if s.needsStart || !s.running {
            s.pendingInput = Self.pathsText(urls)
            s.deliverPendingInput(after: 6)
        } else {
            s.paste(Self.pathsText(urls))
        }
    }

    /// Cycle through chats (⌘⇧] / ⌘⇧[).
    func selectNeighbor(_ offset: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == selectedID }), !sessions.isEmpty else { return }
        select(sessions[(i + offset + sessions.count) % sessions.count].id)
    }

    func rememberRecent(_ dir: String) {
        recents.removeAll { $0 == dir }
        recents.insert(dir, at: 0)
        if recents.count > 6 { recents.removeLast(recents.count - 6) }
    }
}

struct TerminalRepresentable: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

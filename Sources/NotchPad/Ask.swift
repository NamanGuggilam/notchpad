import AppKit
import SwiftUI

/// Quick questions answered by `claude -p` (your Claude subscription), streamed into the notch.
/// No tools, run from a private scratch folder; follow-ups resume the same conversation.
final class AskStore: ObservableObject {
    static let shared = AskStore()

    struct Turn: Identifiable {
        let id = UUID()
        var question: String
        var answer = ""
        var error: String?
        var done = false
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var busy = false
    /// Fast = Haiku; Smart = your default Claude Code model.
    @Published var smart = UserDefaults.standard.bool(forKey: "askSmart") {
        didSet { UserDefaults.standard.set(smart, forKey: "askSmart") }
    }

    private var process: Process?
    private var sessionID: String?
    private var buffer = Data()

    private static let workDir: URL = {
        let url = Storage.dir.appendingPathComponent("ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Locate the claude binary without running the user's (chatty) interactive shell config.
    private static let claudePath: String? = {
        let candidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { NSString(string: $0).expandingTildeInPath }
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).last { $0.hasPrefix("/") }
    }()

    func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        guard let claude = Self.claudePath else {
            turns.append(Turn(question: q, error: "Couldn't find the claude command.", done: true))
            return
        }
        turns.append(Turn(question: q))
        busy = true
        buffer = Data()

        var args = ["-p", q, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "",
                    "--append-system-prompt",
                    "You are answering inside a tiny macOS notch panel. Be brief and direct: a few sentences or a short list, no preamble. Light markdown only (bold, inline code)."]
        if !smart { args += ["--model", "haiku"] }
        if let sessionID { args += ["--resume", sessionID] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = Self.workDir
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_")
            || ["CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_API_KEY", ClaudeHooks.sessionEnvKey].contains(key) {
            env.removeValue(forKey: key)
        }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.finish(status: proc.terminationStatus, stderr: errText) }
        }
        do {
            try p.run()
            process = p
        } catch {
            finish(status: -1, stderr: error.localizedDescription)
        }
    }

    func cancel() {
        process?.terminate()
    }

    func clear() {
        cancel()
        turns = []
        sessionID = nil
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let sid = obj["session_id"] as? String { sessionID = sid }
            switch obj["type"] as? String {
            case "stream_event":
                if let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                   let delta = ev["delta"] as? [String: Any], let text = delta["text"] as? String {
                    mutateLast { $0.answer += text }
                }
            case "result":
                if obj["is_error"] as? Bool == true {
                    mutateLast { $0.error = obj["result"] as? String ?? "Claude returned an error." }
                } else if let result = obj["result"] as? String {
                    mutateLast { if $0.answer.isEmpty { $0.answer = result } }
                }
            default:
                break
            }
        }
    }

    private func finish(status: Int32, stderr: String) {
        process = nil
        busy = false
        mutateLast { t in
            t.done = true
            if t.answer.isEmpty && t.error == nil {
                let tail = stderr.split(separator: "\n").suffix(2).joined(separator: " ")
                t.error = status == 15 ? "Stopped." : (tail.isEmpty ? "No answer (exit \(status))." : tail)
            }
        }
    }

    private func mutateLast(_ f: (inout Turn) -> Void) {
        guard !turns.isEmpty else { return }
        f(&turns[turns.count - 1])
    }
}

// MARK: - Views

struct AskBar: View {
    @ObservedObject var store = AskStore.shared
    @EnvironmentObject var state: NotchState
    @FocusState private var focused: Bool
    @ViewState private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .symbolEffect(.pulse, isActive: store.busy)
            TextField(store.turns.isEmpty ? "Ask Claude anything…" : "Ask a follow-up…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    store.ask(text)
                    text = ""
                }
            if store.busy {
                Button { store.cancel() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            ModeToggle(smart: $store.smart)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(accent.opacity(focused ? 0.6 : 0), lineWidth: 1))
        )
        .animation(.easeOut(duration: 0.15), value: focused)
        .onChange(of: state.askFocusRequest) { _, _ in focused = true }
    }
}

private struct ModeToggle: View {
    @Binding var smart: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Fast", on: !smart) { smart = false }
            segment("Smart", on: smart) { smart = true }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .help("Fast uses Haiku; Smart uses your default Claude Code model")
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { action() } }) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(on ? accent : Color.clear))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }
}

struct AskAnswers: View {
    @ObservedObject var store = AskStore.shared
    @ViewState private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.turns) { turn in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(turn.question)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if let error = turn.error, turn.answer.isEmpty {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 12)).foregroundStyle(.orange)
                                } else if turn.answer.isEmpty {
                                    TypingDots()
                                } else {
                                    Text(markdown(turn.answer))
                                        .font(.system(size: 13))
                                        .lineSpacing(2)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: store.turns.last?.answer) { _, _ in
                    if let id = store.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                if let last = store.turns.last, !last.answer.isEmpty {
                    PillButton(title: copiedID == last.id ? "Copied" : "Copy answer",
                               icon: copiedID == last.id ? "checkmark" : "doc.on.doc") {
                        ClipboardStore.shared.copy(last.answer)
                        copiedID = last.id
                    }
                    PillButton(title: "Save as note", icon: "note.text") {
                        _ = NotesStore.shared.save(id: nil, text: "\(last.question)\n\n\(last.answer)")
                    }
                }
                Spacer()
                PillButton(title: "Done", icon: "xmark") {
                    withAnimation(.easeInOut(duration: 0.2)) { store.clear() }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.white.opacity(0.35 + 0.5 * max(0, sin(t * 6 - Double(i) * 0.8))))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

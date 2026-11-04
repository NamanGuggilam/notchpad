import AppKit
import EventKit
import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var state: NotchState
    @ObservedObject var cal = CalendarStore.shared
    @ObservedObject var tasks = TasksStore.shared
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var notes = NotesStore.shared
    @ObservedObject var ask = AskStore.shared
    @ObservedObject var music = NowPlaying.shared
    @ViewState private var quickNote = ""
    @ViewState private var quickTask = ""

    var body: some View {
        VStack(spacing: 10) {
            AskBar()
            if ask.turns.isEmpty {
                dashboard.transition(.opacity)
            } else {
                AskAnswers().transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: ask.turns.isEmpty)
        .onAppear { if cal.access == nil && EKEventStore.authorizationStatus(for: .event) == .fullAccess { cal.requestAccess() } }
    }

    private var dashboard: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                Card {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ctx.date.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 76)
                Card(title: "Up next") {
                    if cal.access != true {
                        PillButton(title: "Allow calendar access", icon: "calendar") { cal.requestAccess() }
                    } else if cal.upcoming.isEmpty {
                        Text("Nothing in the next 48h").font(.system(size: 12)).foregroundStyle(.secondary)
                        if !cal.hasGoogle {
                            PillButton(title: "Add Google account", icon: "plus") { CalendarStore.openInternetAccounts() }
                        }
                    } else {
                        ForEach(cal.upcoming.prefix(3), id: \.eventIdentifier) { e in
                            EventRow(event: e, showDay: true)
                        }
                    }
                }
            }
            .frame(width: 196)

            Card(title: "Tasks · \(tasks.pending.count) open") {
                TextField("Add a task…", text: $quickTask)
                    .fieldStyle()
                    .onSubmit { tasks.add(quickTask, remind: true); quickTask = "" }
                ForEach(tasks.pending.prefix(5)) { t in
                    HStack(spacing: 8) {
                        Button { tasks.toggleDone(t.id) } label: { Image(systemName: "circle") }
                            .buttonStyle(.plain)
                        Text(t.title).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        if t.remind { Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(accent) }
                    }
                }
                if tasks.pending.count > 5 {
                    Button("View all") { state.tab = .tasks }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                }
            }

            VStack(spacing: 10) {
                Card(title: "Quick note") {
                    TextField("Jot something, ⏎ to save", text: $quickNote, axis: .vertical)
                        .lineLimit(2...3)
                        .fieldStyle()
                        .onSubmit {
                            guard !quickNote.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            _ = notes.save(id: nil, text: quickNote)
                            quickNote = ""
                        }
                    Text("\(notes.notes.count) saved notes").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if music.hasTrack {
                    NowPlayingCard()
                        .frame(height: 146)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    Card(title: timer.label) {
                        HStack {
                            Text(timer.display).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                            Spacer()
                            Button { timer.running ? timer.pause() : timer.start() } label: {
                                Image(systemName: timer.running ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Play something (YouTube Music, Spotify…) to see it here.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .frame(height: 146)
                }
            }
            .frame(width: 196)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: music.hasTrack)
        }
    }
}

struct EventRow: View {
    let event: EKEvent
    var showDay = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(timeText).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var timeText: String {
        if event.isAllDay { return showDay ? event.startDate.formatted(.dateTime.weekday().day()) + " · all day" : "All day" }
        let t = event.startDate.formatted(date: .omitted, time: .shortened) + " – " + event.endDate.formatted(date: .omitted, time: .shortened)
        if showDay && !Calendar.current.isDateInToday(event.startDate) {
            return event.startDate.formatted(.dateTime.weekday()) + " " + t
        }
        return t
    }
}

// MARK: - Calendar

struct CalendarTab: View {
    @ObservedObject var cal = CalendarStore.shared
    @ViewState private var month = Date()
    @ViewState private var selected = Date()
    @ViewState private var newTitle = ""
    @ViewState private var newTime = Date()
    @ViewState private var newMinutes = 30
    @ViewState private var addError = false

    private let calendar = Calendar.current

    var body: some View {
        if cal.access != true {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(cal.access == false
                     ? "Calendar access was denied. Enable NotchPad in System Settings → Privacy & Security → Calendars."
                     : "NotchPad shows the calendars on this Mac. macOS's permission prompt mentions Calendar, but it covers every account added to this Mac, including Google.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 400)
                Text("To see Google Calendar: System Settings → Internet Accounts → Add Account → Google, with Calendars on.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 400)
                HStack {
                    if cal.access == false {
                        PillButton(title: "Open Settings", icon: "gear") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    } else {
                        PillButton(title: "Allow calendar access", icon: "calendar", prominent: true) { cal.requestAccess() }
                    }
                    PillButton(title: "Add Google account", icon: "plus") { CalendarStore.openInternetAccounts() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 10) {
                Card {
                    monthGrid
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Text(cal.accounts.isEmpty ? "No calendar accounts" : cal.accounts.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if !cal.hasGoogle {
                            Button("Add Google") { CalendarStore.openInternetAccounts() }
                                .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(accent)
                        }
                    }
                }
                .frame(width: 300)
                Card(title: selected.formatted(.dateTime.weekday(.wide).month().day())) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            let events = cal.events(on: selected)
                            if events.isEmpty {
                                Text("No events").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(events, id: \.eventIdentifier) { EventRow(event: $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().opacity(0.3)
                    TextField("New event on this day…", text: $newTitle).fieldStyle().onSubmit(addEvent)
                    HStack(spacing: 8) {
                        DatePicker("", selection: $newTime, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.stepperField).frame(width: 100)
                        Picker("", selection: $newMinutes) {
                            Text("15m").tag(15); Text("30m").tag(30); Text("1h").tag(60); Text("2h").tag(120)
                        }
                        .labelsHidden().frame(width: 70)
                        Spacer()
                        PillButton(title: "Add", icon: "plus", prominent: true, action: addEvent)
                    }
                    if addError { Text("Couldn't save the event.").font(.system(size: 10.5)).foregroundStyle(.red) }
                }
            }
            .onAppear { cal.refreshAccounts(); cal.loadMonth(containing: month) }
            .onChange(of: month) { _, m in cal.loadMonth(containing: m) }
        }
    }

    private func addEvent() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let tc = calendar.dateComponents([.hour, .minute], from: newTime)
        let start = calendar.date(bySettingHour: tc.hour ?? 9, minute: tc.minute ?? 0, second: 0, of: selected) ?? selected
        addError = !cal.addEvent(title: title, start: start, minutes: newMinutes)
        if !addError { newTitle = "" }
    }

    private var monthGrid: some View {
        let days = gridDays()
        let symbols = calendar.veryShortWeekdaySymbols
        let shifted = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Button("Today") { month = Date(); selected = Date() }.buttonStyle(.plain).font(.system(size: 11))
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(Array(shifted.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 30) }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSel = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let hasEvents = !cal.events(on: day).isEmpty
        return Button { selected = day } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 11.5, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? accent : .white)
                Circle().fill(hasEvents ? Color.white.opacity(0.6) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? Color.white.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ by: Int) {
        month = calendar.date(byAdding: .month, value: by, to: month) ?? month
    }

    private func gridDays() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}

// MARK: - Notes

struct NotesView: View {
    @ObservedObject var store = NotesStore.shared
    @ViewState private var selected: UUID?
    @ViewState private var draft = ""
    @ViewState private var confirmDelete = false
    @ViewState private var savedFlash = false
    @ViewState private var query = ""

    private var dirty: Bool {
        if let selected, let n = store.notes.first(where: { $0.id == selected }) { return n.text != draft }
        return !draft.isEmpty
    }

    private var selectedNote: Note? { store.notes.first { $0.id == selected } }

    private var visible: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.ordered : store.ordered.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                PillButton(title: "New note", icon: "square.and.pencil", prominent: true) { newNote() }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    TextField("Search notes", text: $query).textFieldStyle(.plain).font(.system(size: 11.5))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(visible) { n in
                            Button { select(n) } label: {
                                HStack(alignment: .top, spacing: 5) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(n.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(n.updated.formatted(.relative(presentation: .named)))
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if n.pinned {
                                        Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(accent).padding(.top, 3)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selected == n.id ? Color.white.opacity(0.14) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(n.pinned ? "Unpin" : "Pin to top") { store.togglePin(n.id) }
                            }
                        }
                        if store.notes.isEmpty {
                            Text("No notes yet").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                        } else if visible.isEmpty {
                            Text("No notes match “\(query)”").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                }
            }
            .frame(width: 170)

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                HStack(spacing: 8) {
                    PillButton(title: savedFlash ? "Saved" : "Save", icon: savedFlash ? "checkmark" : "square.and.arrow.down",
                               prominent: dirty) { save() }
                        .keyboardShortcut("s", modifiers: .command)
                    if let note = selectedNote {
                        PillButton(title: note.pinned ? "Unpin" : "Pin", icon: note.pinned ? "pin.slash" : "pin") {
                            store.togglePin(note.id)
                        }
                        if confirmDelete {
                            PillButton(title: "Really delete?", icon: "trash") { deleteSelected() }
                            Button("Cancel") { confirmDelete = false }.buttonStyle(.plain).font(.system(size: 11))
                        } else {
                            PillButton(title: "Delete", icon: "trash") { confirmDelete = true }
                        }
                    }
                    Spacer()
                    if dirty { Text("Unsaved").font(.system(size: 10.5)).foregroundStyle(accent) }
                    PillButton(title: "Copy", icon: "doc.on.doc") { ClipboardStore.shared.copy(draft) }
                }
            }
        }
        .onAppear {
            if selected == nil, let first = store.ordered.first { select(first) }
        }
    }

    private func select(_ n: Note) {
        selected = n.id
        draft = n.text
        confirmDelete = false
    }

    private func newNote() {
        if dirty { save() }
        selected = nil
        draft = ""
        confirmDelete = false
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selected = store.save(id: selected, text: draft)
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { savedFlash = false }
    }

    private func deleteSelected() {
        guard let selected else { return }
        store.delete(selected)
        confirmDelete = false
        if let first = store.ordered.first { select(first) } else { self.selected = nil; draft = "" }
    }
}

// MARK: - Tasks

struct TasksView: View {
    @ObservedObject var store = TasksStore.shared
    @ViewState private var newTitle = ""
    @ViewState private var remind = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("What needs doing?", text: $newTitle).fieldStyle().onSubmit(add)
                Toggle(isOn: $remind) { Label("Hourly", systemImage: "bell") }
                    .toggleStyle(.button)
                    .font(.system(size: 11.5))
                    .help("Remind me every hour until it's done")
                PillButton(title: "Add", icon: "plus", prominent: true, action: add)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.tasks) { t in row(t) }
                    if store.tasks.isEmpty {
                        Text("No tasks. Add one above — open tasks with 🔔 nudge you every hour.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }
            }
            HStack {
                Text("\(store.pending.count) open · \(store.tasks.count - store.pending.count) done")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                if store.tasks.contains(where: \.done) {
                    Button("Clear completed") { store.clearDone() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                }
            }
        }
    }

    private func add() {
        store.add(newTitle, remind: remind)
        newTitle = ""
    }

    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: 10) {
            Button { store.toggleDone(t.id) } label: {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(t.done ? accent : .white.opacity(0.7))
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: 12.5)).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                if let next = t.nextReminder {
                    Text("next reminder \(next.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !t.done {
                Button { store.toggleRemind(t.id) } label: {
                    Image(systemName: t.remind ? "bell.fill" : "bell.slash").foregroundStyle(t.remind ? accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(t.remind ? "Stop hourly reminders" : "Remind hourly")
            }
            Button { store.delete(t.id) } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Claude Code

/// Multiple Claude chats shown as tabs; + opens another one.
struct CodeView: View {
    @ObservedObject var term = TerminalHost.shared
    @EnvironmentObject var state: NotchState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(term.sessions) { s in
                            ChatTab(session: s, selected: s.id == term.selectedID)
                        }
                    }
                }
                newChatMenu
                if let s = term.selected {
                    SessionControls(session: s)
                }
                Divider().frame(height: 14).opacity(0.4)
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { state.codeExpanded.toggle() }
                } label: {
                    Image(systemName: state.codeExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.codeExpanded ? "Shrink the Claude panel" : "Expand the Claude panel")
                Button { state.pinned.toggle() } label: {
                    Label(state.pinned ? "Kept open" : "Keep open", systemImage: state.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(state.pinned ? accent : Color.white.opacity(0.1)))
                        .foregroundStyle(state.pinned ? Color.white : Color.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(state.pinned ? "Click to let the notch close when the pointer leaves" : "Stay open even when the pointer leaves")
            }
            .frame(height: 28)

            if let s = term.selected {
                TerminalRepresentable(session: s)
                    .id(s.id)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onAppear { s.startIfNeeded() }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(accent)
                    Text("Run Claude Code right here in the notch.").font(.system(size: 13, weight: .medium))
                    Text("Chats start in \(abbreviate(term.directory))").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        PillButton(title: "Other folder…", icon: "folder") { chooseFolder() }
                        PillButton(title: "Start claude", icon: "play.fill", prominent: true) { term.add() }
                    }
                    Text("+ (or ⌘T) opens more chats; ⌘⇧[ ⌘⇧] switch between them. Pin the notch (📌) while you work.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            }
        }
    }

    /// Click: new chat in the current folder. Arrow: pick a recent folder or browse.
    private var newChatMenu: some View {
        Menu {
            Button("New chat in \(abbreviate(term.directory))") { term.add() }
            Button("Continue last chat in \(abbreviate(term.directory))") { term.add(extraArgs: "--continue") }
            Button("New shell in \(abbreviate(term.directory))") { term.add(shell: true) }
            if !term.recents.filter({ $0 != term.directory }).isEmpty {
                Divider()
                ForEach(term.recents.filter { $0 != term.directory }, id: \.self) { dir in
                    Button("New chat in \(abbreviate(dir))") { term.add(in: dir) }
                }
            }
            Divider()
            Button("New chat in folder…") { chooseFolder() }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            term.add()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("New Claude chat (⌘T) — click the arrow for other folders")
    }

    private func chooseFolder() {
        NotchController.shared.withAutoCloseSuppressed { done in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: term.directory)
            panel.prompt = "Start chat here"
            panel.level = .mainMenu + 4
            NSApp.activate()
            panel.begin { resp in
                if resp == .OK, let url = panel.url {
                    term.add(in: url.path)
                }
                done()
            }
        }
    }
}

private func abbreviate(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

struct ChatTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    @ViewState private var hovering = false
    @ViewState private var editing = false
    @ViewState private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            ActivityDot(session: session)
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .frame(width: min(160, max(50, CGFloat(draft.count) * 7 + 10)))
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: fieldFocused) { _, focused in if !focused && editing { commit() } }
            } else {
                Text(session.name).lineLimit(1)
            }
            Button { TerminalHost.shared.close(session.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity((hovering || selected) && !editing ? 0.8 : 0)
            .help("Close chat (⌘W) — resume later with claude --resume")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(editing ? 0.7 : 0), lineWidth: 1))
        )
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.65))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { TerminalHost.shared.select(session.id) } }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
        .contextMenu {
            Button("Rename…") { startEditing() }
            if session.customName != nil {
                Button("Reset name") { session.customName = nil }
            }
            Divider()
            Button("Close chat") { TerminalHost.shared.close(session.id) }
        }
        .onHover { hovering = $0 }
        .help("\(abbreviate(session.directory))\(session.title.isEmpty ? "" : " — \(session.title)") · double-click to rename")
    }

    private func startEditing() {
        draft = session.name
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    /// Empty name goes back to the folder-based default.
    private func commit() {
        guard editing else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = name.isEmpty ? nil : String(name.prefix(40))
        editing = false
        session.focus()
    }

    private func cancel() {
        editing = false
        session.focus()
    }
}

/// Per-chat state from Claude Code hooks: working (pulsing orange), needs you (yellow), finished unseen (cyan).
private struct ActivityDot: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        let (color, pulse): (Color, Bool) = {
            guard session.running else { return (.gray, false) }
            switch session.activity {
            case .working: return (accent, true)
            case .needsYou: return (.yellow, true)
            case .finished: return (.cyan, false)
            case .idle: return (.green, false)
            }
        }()
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulse)) { ctx in
            let k = pulse ? 0.55 + 0.45 * sin(ctx.date.timeIntervalSinceReferenceDate * 4) : 1
            Circle().fill(color).frame(width: 6, height: 6).opacity(k)
        }
        .frame(width: 6, height: 6)
        .help({
            if case .needsYou(let m) = session.activity { return m }
            return session.activity == .working ? "Claude is working" : ""
        }())
    }
}

/// Restart / continue / stop for the selected chat.
struct SessionControls: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Button { session.start() } label: { Image(systemName: "arrow.clockwise") }
                .help(session.isShell ? "Restart this shell" : "Restart claude in this chat")
            if !session.isShell {
                Button { session.start(extraArgs: "--continue") } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("claude --continue: resume the most recent conversation in this folder")
            }
            if session.running {
                Button { session.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Stop this chat's process")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

// MARK: - Clipboard

struct ClipboardView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ViewState private var query = ""
    @ViewState private var copied: String?

    private var filtered: [String] {
        query.isEmpty ? store.items : store.items.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search clipboard history…", text: $query).fieldStyle()
                if !store.items.isEmpty { PillButton(title: "Clear", icon: "xmark") { store.clear() } }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(filtered, id: \.self) { s in
                        HStack {
                            Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 12, design: .monospaced)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if copied == s {
                                Text("Copied").font(.system(size: 10.5)).foregroundStyle(accent)
                            }
                            Button { store.remove(s) } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.copy(s)
                            copied = s
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if copied == s { copied = nil } }
                        }
                    }
                    if store.items.isEmpty {
                        Text("Copied text shows up here (kept in memory only; password-manager copies are skipped).")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }
            }
        }
    }
}

// MARK: - Focus timer

struct TimerView: View {
    @ObservedObject var timer = FocusTimer.shared
    @ViewState private var custom = 45

    var body: some View {
        HStack(spacing: 30) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: timer.total > 0 ? timer.remaining / timer.total : 0)
                    .stroke(accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: timer.remaining)
                VStack(spacing: 2) {
                    Text(timer.display).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(timer.label).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    PillButton(title: timer.running ? "Pause" : "Start", icon: timer.running ? "pause.fill" : "play.fill", prominent: true) {
                        timer.running ? timer.pause() : timer.start()
                    }
                    PillButton(title: "Reset", icon: "arrow.counterclockwise") { timer.stop() }
                }
                Text("PRESETS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    PillButton(title: "Focus 25") { timer.set(minutes: 25, label: "Focus") }
                    PillButton(title: "Deep 50") { timer.set(minutes: 50, label: "Deep work") }
                    PillButton(title: "Break 5") { timer.set(minutes: 5, label: "Break") }
                    PillButton(title: "Break 15") { timer.set(minutes: 15, label: "Long break") }
                }
                HStack(spacing: 8) {
                    Stepper("\(custom) min", value: $custom, in: 1...180, step: 5).font(.system(size: 12))
                    PillButton(title: "Set") { timer.set(minutes: custom, label: "Timer") }
                }
                Text("The countdown shows beside the notch while it runs.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

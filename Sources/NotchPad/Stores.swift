import AppKit
import EventKit
import Foundation
import UserNotifications

// MARK: - Persistence

enum Storage {
    static let dir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

// MARK: - Notes

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var updated = Date()
    var pinned = false

    init(text: String) {
        self.text = text
    }

    /// `pinned` is optional so notes saved before pinning existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        updated = try c.decode(Date.self, forKey: .updated)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled" : t
    }
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published private(set) var notes: [Note] = Storage.load("notes.json", as: [Note].self) ?? []

    /// Pinned first, then most recently edited.
    var ordered: [Note] {
        notes.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.updated > b.updated }
    }

    func togglePin(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned.toggle()
        persist()
    }

    func save(id: UUID?, text: String) -> UUID {
        if let id, let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].text = text
            notes[i].updated = Date()
        } else {
            let note = Note(text: text)
            notes.insert(note, at: 0)
            persist()
            return note.id
        }
        notes.sort { $0.updated > $1.updated }
        persist()
        return id!
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        persist()
    }

    private func persist() { Storage.save(notes, to: "notes.json") }
}

// MARK: - Tasks (with hourly reminders)

struct TaskItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var remind = true
    var created = Date()
    /// Reminders fire every hour on the hour-mark measured from this date.
    var remindFrom = Date()

    var nextReminder: Date? {
        guard remind, !done else { return nil }
        let elapsed = Date().timeIntervalSince(remindFrom)
        let n = max(1, Int(elapsed / 3600) + 1)
        return remindFrom.addingTimeInterval(Double(n) * 3600)
    }
}

final class TasksStore: ObservableObject {
    static let shared = TasksStore()
    @Published private(set) var tasks: [TaskItem] = Storage.load("tasks.json", as: [TaskItem].self) ?? []
    private var timer: Timer?
    private var lastNudge = Date()

    var pending: [TaskItem] { tasks.filter { !$0.done } }

    func add(_ title: String, remind: Bool) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let item = TaskItem(title: t, remind: remind)
        tasks.insert(item, at: 0)
        schedule(item)
        persist()
    }

    func toggleDone(_ id: UUID) {
        mutate(id) { $0.done.toggle(); $0.remindFrom = Date() }
    }

    func toggleRemind(_ id: UUID) {
        mutate(id) { $0.remind.toggle(); $0.remindFrom = Date() }
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        persist()
    }

    func clearDone() {
        let done = tasks.filter(\.done).map(\.id.uuidString)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: done)
        tasks.removeAll(where: \.done)
        persist()
    }

    private func mutate(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        schedule(tasks[i])
        persist()
    }

    /// One repeating hourly system notification per open task with reminders on.
    private func schedule(_ item: TaskItem) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
        guard item.remind, !item.done else { return }
        let content = UNMutableNotificationContent()
        content.title = "Task reminder"
        content.body = item.title
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: true)
        center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger))
    }

    /// Re-arm notifications on launch, and drop a notch "peek" every hour while tasks are open
    /// (works even if notification permission was denied).
    func startReminderLoop() {
        tasks.forEach(schedule)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let reminding = self.tasks.filter { $0.remind && !$0.done }
            guard !reminding.isEmpty, Date().timeIntervalSince(self.lastNudge) >= 3600 else { return }
            self.lastNudge = Date()
            let first = reminding[0].title
            let more = reminding.count > 1 ? "  +\(reminding.count - 1) more" : ""
            NotchController.shared.peek("⏰ \(first)\(more)", seconds: 6)
        }
    }

    private func persist() { Storage.save(tasks, to: "tasks.json") }
}

// MARK: - Calendar

final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    let store = EKEventStore()
    @Published var access: Bool? = nil
    @Published var monthEvents: [EKEvent] = []
    @Published var upcoming: [EKEvent] = []
    /// Calendar accounts macOS has (iCloud, Google address, …), for showing what's connected.
    @Published var accounts: [String] = []

    /// Google calendars reach NotchPad through macOS: add the account in System Settings → Internet Accounts.
    var hasGoogle: Bool { accounts.contains { $0.lowercased().contains("google") || $0.lowercased().contains("gmail") } }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.store.refreshSourcesIfNecessary()
            self?.refreshAccounts()
            self?.refreshUpcoming()
        }
    }

    func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { access = true; refreshAccounts(); refreshUpcoming(); return }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.access = granted
                if granted { self.refreshAccounts(); self.refreshUpcoming() }
            }
        }
    }

    func refreshAccounts() {
        guard access == true else { return }
        let sources = store.calendars(for: .event).map(\.source)
            .filter { $0.sourceType != .birthdays && $0.sourceType != .subscribed }
        var seen = Set<String>()
        accounts = sources.map(\.title).filter { seen.insert($0).inserted }
    }

    static func openInternetAccounts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }

    func loadMonth(containing date: Date) {
        guard access == true else { return }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: date) else { return }
        let pred = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        monthEvents = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    }

    func refreshUpcoming() {
        guard access == true else { return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(86400 * 2), calendars: nil)
        upcoming = store.events(matching: pred).filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
    }

    func events(on day: Date) -> [EKEvent] {
        monthEvents.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    func addEvent(title: String, start: Date, minutes: Int) -> Bool {
        guard access == true, let cal = store.defaultCalendarForNewEvents else { return false }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = start.addingTimeInterval(Double(minutes) * 60)
        e.calendar = cal
        do {
            try store.save(e, span: .thisEvent)
            loadMonth(containing: start)
            refreshUpcoming()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Clipboard history (in memory only; skips password-manager items)

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published private(set) var items: [String] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = pb.types ?? []
        if types.contains(concealed) || types.contains(transient) { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > 40 { items.removeLast(items.count - 40) }
    }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        lastChange = pb.changeCount
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
    }

    func remove(_ s: String) { items.removeAll { $0 == s } }
    func clear() { items.removeAll() }
}

// MARK: - Focus timer

final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    @Published var total: TimeInterval = 25 * 60
    @Published var remaining: TimeInterval = 25 * 60
    @Published var running = false
    @Published var label = "Focus"
    private var endDate: Date?
    private var timer: Timer?

    func set(minutes: Int, label: String) {
        stop()
        total = Double(minutes) * 60
        remaining = total
        self.label = label
    }

    func start() {
        guard !running, remaining > 0 else { return }
        running = true
        endDate = Date().addingTimeInterval(remaining)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pause() {
        running = false
        timer?.invalidate()
        if let endDate { remaining = max(0, endDate.timeIntervalSinceNow) }
    }

    func stop() {
        pause()
        remaining = total
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining == 0 {
            running = false
            timer?.invalidate()
            let content = UNMutableNotificationContent()
            content.title = "\(label) done"
            content.body = "\(Int(total / 60)) minutes are up."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            NotchController.shared.peek("✅ \(label) done — \(Int(total / 60)) min", seconds: 6)
            remaining = total
        }
    }

    var display: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

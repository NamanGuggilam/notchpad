import AppKit
import Combine
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home, calendar, notes, tasks, code, clipboard, timer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .calendar: "Calendar"
        case .notes: "Notes"
        case .tasks: "Tasks"
        case .code: "Claude"
        case .clipboard: "Clipboard"
        case .timer: "Focus"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .calendar: "calendar"
        case .notes: "note.text"
        case .tasks: "checklist"
        case .code: "terminal"
        case .clipboard: "doc.on.clipboard"
        case .timer: "timer"
        }
    }
}

/// UI state shared between the panel controller and SwiftUI.
final class NotchState: ObservableObject {
    @Published var isOpen = false
    @Published var tab: NotchTab = .home
    @Published var pinned = false
    @Published var peek: Peek?
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// Current size of the closed shape (grows with the "ears"); drives the hover hit-area.
    @Published var closedSize = CGSize(width: 200, height: 32)
    /// A file drag (from Finder etc.) is in progress; the open panel shows drop zones.
    @Published var fileDragActive = false
    /// Bumped to ask Home to focus the Ask bar (⌥⌘N).
    @Published var askFocusRequest = 0

    /// Claude tab uses a big panel (toggle in its toolbar).
    @Published var codeExpanded = UserDefaults.standard.object(forKey: "codeExpanded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(codeExpanded, forKey: "codeExpanded") }
    }
    @Published var screenSize = CGSize(width: 1440, height: 900)

    static let normalSize = CGSize(width: 680, height: 420)

    /// Size of the open panel for the current tab; it grows evenly around the notch.
    var openSize: CGSize { size(for: tab, expanded: codeExpanded) }

    func size(for tab: NotchTab, expanded: Bool) -> CGSize {
        guard tab == .code, expanded else { return Self.normalSize }
        return CGSize(width: min(1100, screenSize.width - 60), height: min(700, screenSize.height - 40))
    }
}

/// A short message that drops out of the closed notch. Hovering it opens the notch and runs `action`.
struct Peek: Equatable {
    let id = UUID()
    var text: String
    var symbol: String? = nil
    var image: NSImage? = nil
    var tint: Color = .white
    var sound: String? = nil
    var seconds: Double = 5
    var action: (() -> Void)? = nil

    static func == (a: Peek, b: Peek) -> Bool { a.id == b.id }
}

/// Owns the borderless panel that sits over the notch and decides when it opens/closes.
final class NotchKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NotchController {
    static let shared = NotchController()

    let state = NotchState()
    private var panel: NotchKeyPanel!
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    /// Hover-close only applies once the pointer has actually been inside the open panel
    /// (so ⌥⌘N or a notification can open it without it snapping shut).
    private var hoverArmed = false
    /// After closing, hover-open waits until the pointer has left the notch once (no close→reopen flicker).
    private var reopenArmed = true
    private var closedAt = Date.distantPast
    private var pointerTimer: Timer?
    private var lastPointer = NSPoint(x: -1, y: -1)
    private let dragPasteboard = NSPasteboard(name: .drag)
    private lazy var lastDragCount = dragPasteboard.changeCount
    private var dragging = false

    /// A new drag writes the drag pasteboard while the mouse is held; that's our cue that files are in
    /// flight, so hovering the notch opens it with drop zones (the hover-close already waits for mouse-up).
    private func trackFileDrag() {
        let held = NSEvent.pressedMouseButtons & 1 != 0
        if held {
            if !dragging, dragPasteboard.changeCount != lastDragCount {
                lastDragCount = dragPasteboard.changeCount
                dragging = true
            }
        } else {
            dragging = false
            lastDragCount = dragPasteboard.changeCount
        }
        let fileDrag = dragging && (dragPasteboard.types?.contains(.fileURL) ?? false)
        if fileDrag != state.fileDragActive {
            withAnimation(.easeOut(duration: 0.15)) { state.fileDragActive = fileDrag }
        }
    }
    /// Set while a system sheet (folder picker) is up so hover-out doesn't close us.
    var suppressAutoClose = false

    private var cancellables = Set<AnyCancellable>()

    /// The window hugs the open panel (plus room for its shadow) so it never blocks clicks elsewhere.
    private func windowSize(for open: CGSize) -> CGSize {
        CGSize(width: max(760, open.width + 80), height: max(460, open.height + 40))
    }

    func start() {
        panel = NotchKeyPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: RootView().environmentObject(state))
        host.frame = NSRect(origin: .zero, size: windowSize(for: state.openSize))
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        // Switching to/from the big Claude panel: grow the window first, shrink it after the animation,
        // and don't hover-close just because the panel moved out from under the pointer.
        // @Published emits in willSet, so resize on the next turn of the run loop: resizing synchronously
        // makes SwiftUI redraw with the old value and then miss the change until the panel reopens.
        state.$tab.combineLatest(state.$codeExpanded).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.hoverArmed = false
                let target = self.windowSize(for: self.state.openSize)
                if target.width >= self.panel.frame.width && target.height >= self.panel.frame.height {
                    self.layout(windowSize: target)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.layout() }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }

        // Poll the pointer instead of relying on mouse-moved events, which don't reliably arrive over the
        // menu bar / notch area. Only does work when the pointer actually moved.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.trackFileDrag()
            let p = NSEvent.mouseLocation
            if p != self.lastPointer {
                self.lastPointer = p
                self.mouseMoved()
            }
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if let self, self.handleShortcut(e) { return nil }
            return e
        }) {
            monitors.append(l)
        }
    }

    /// Panel-level shortcuts, handled before the terminal or text fields can swallow them.
    private func handleShortcut(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased()
        if e.keyCode == 53, mods.isEmpty, state.tab != .code { // Esc closes (except in the terminal)
            close()
            return true
        }
        guard state.isOpen else { return false }
        // ⌘← / ⌘→: previous / next chat (arrow keys have no useful characters, so match key codes).
        if mods == [.command], state.tab == .code, e.keyCode == 123 || e.keyCode == 124 {
            TerminalHost.shared.selectNeighbor(e.keyCode == 123 ? -1 : 1)
            return true
        }
        // ⌘1…⌘7: jump to a tab.
        if mods == [.command], let k = key, let n = Int(k), (1...NotchTab.allCases.count).contains(n) {
            state.tab = NotchTab.allCases[n - 1]
            return true
        }
        switch (mods, key) {
        case ([.command], "t"): // ⌘T: new Claude chat (from any tab)
            state.tab = .code
            TerminalHost.shared.add()
            return true
        case ([.command], "w"): // ⌘W: close the current chat
            guard state.tab == .code, let id = TerminalHost.shared.selectedID else { return false }
            TerminalHost.shared.close(id)
            return true
        case ([.command, .shift], "]"), ([.command, .shift], "}"): // ⌘⇧]: next chat
            guard state.tab == .code else { return false }
            TerminalHost.shared.selectNeighbor(1)
            return true
        case ([.command, .shift], "["), ([.command, .shift], "{"): // ⌘⇧[: previous chat
            guard state.tab == .code else { return false }
            TerminalHost.shared.selectNeighbor(-1)
            return true
        default:
            return false
        }
    }

    /// The screen with a notch, else the main screen (then we draw a fake pill).
    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout(windowSize forced: CGSize? = nil) {
        let s = screen
        let f = s.frame
        state.screenSize = f.size
        if s.safeAreaInsets.top > 0,
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: f.width - left.width - right.width, height: s.safeAreaInsets.top)
        } else {
            state.notchSize = CGSize(width: 190, height: 26)
        }
        let windowSize = forced ?? self.windowSize(for: state.openSize)
        panel.setFrame(NSRect(x: f.midX - windowSize.width / 2, y: f.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: true)
    }

    /// Screen-space rect of the visible black shape.
    private func shapeRect(open: Bool) -> NSRect {
        let f = screen.frame
        let size: CGSize
        if open {
            size = state.openSize
        } else {
            // A little bigger than what's drawn so it's easy to hit.
            size = CGSize(width: max(state.closedSize.width, state.notchSize.width) + 30,
                          height: max(state.closedSize.height, state.notchSize.height) + 6)
        }
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    /// Hover target for the closed notch. NSRect.contains excludes the top edge, but a fast flick parks the
    /// pointer exactly on the screen's top row, so reach a few points past it; along that top row the
    /// target is also wider, so a slightly off-centre flick still lands.
    private func closedHotRect(for p: NSPoint) -> NSRect {
        let f = screen.frame
        var r = shapeRect(open: false)
        r.size.height += 4
        if p.y >= f.maxY - 3 { r = r.insetBy(dx: -40, dy: 0) }
        return r
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if state.isOpen {
            if shapeRect(open: true).insetBy(dx: -12, dy: -12).contains(p) {
                hoverArmed = true
                closeWork?.cancel()
                closeWork = nil
            } else if hoverArmed && !state.pinned && !suppressAutoClose && closeWork == nil
                        && NSEvent.pressedMouseButtons == 0 {
                let work = DispatchWorkItem { [weak self] in self?.close() }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
        } else if !closedHotRect(for: p).contains(p) {
            reopenArmed = true
        } else if reopenArmed || Date().timeIntervalSince(closedAt) > 0.6 {
            // Re-arms once the pointer leaves the notch, or if you keep moving on it a moment after it closed.
            open(tab: nil, focus: false)
            hoverArmed = true
        }
    }

    func open(tab: NotchTab?, focus: Bool) {
        if let tab { state.tab = tab }
        peekWork?.cancel()
        let action = state.peek?.action
        state.peek = nil
        hoverArmed = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { state.isOpen = true }
        panel.ignoresMouseEvents = false
        if focus { panel.makeKey() }
        action?()
    }

    func close() {
        closeWork?.cancel()
        closeWork = nil
        guard state.isOpen else { return }
        reopenArmed = false
        closedAt = Date()
        withAnimation(.spring(response: 0.32, dampingFraction: 1)) { state.isOpen = false }
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow {
            panel.resignKey()
            // Hand keyboard focus back to whatever app was in front.
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }

    func toggleFromHotKey() {
        if state.isOpen {
            close()
        } else {
            open(tab: nil, focus: true)
            if state.tab == .home { state.askFocusRequest += 1 }
        }
    }

    /// Briefly drop a message out of the closed notch (reminders, timer done, Claude status, track changes).
    func peek(_ message: String, seconds: Double = 5) {
        peek(Peek(text: message, sound: "Glass", seconds: seconds))
    }

    func peek(_ p: Peek) {
        guard !state.isOpen else { return }
        peekWork?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { state.peek = p }
        if let sound = p.sound { NSSound(named: sound)?.play() }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self?.state.peek = nil }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + p.seconds, execute: work)
    }

    /// Used by views that pop a system panel (NSOpenPanel) so we stay open while it's up.
    func withAutoCloseSuppressed(_ body: (@escaping () -> Void) -> Void) {
        suppressAutoClose = true
        body { [weak self] in
            self?.suppressAutoClose = false
            self?.panel.makeKey()
        }
    }
}

import SwiftUI

let accent = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude-ish clay orange

/// Black shape hugging the top edge: small outward flare at the top, rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let flare = min(8, radius)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + flare, y: r.minY + flare), control: CGPoint(x: r.minX + flare, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + flare, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + flare + radius, y: r.maxY), control: CGPoint(x: r.minX + flare, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - flare - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - flare, y: r.maxY - radius), control: CGPoint(x: r.maxX - flare, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - flare, y: r.minY + flare))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - flare, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct RootView: View {
    @EnvironmentObject var state: NotchState
    @ObservedObject var tasks = TasksStore.shared
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var term = TerminalHost.shared
    @ObservedObject var music = NowPlaying.shared

    private var showMusic: Bool { music.hasTrack && music.isPlaying }
    /// Open content stays mounted until the close animation finishes, so it never pops or re-lays out mid-animation.
    @ViewState private var contentMounted = false

    private var radius: CGFloat { state.isOpen ? 22 : (state.peek != nil ? 16 : 10) }

    /// Both ears get the same width so the shape stays centred on the camera.
    private var earWidth: CGFloat {
        func width(_ items: [CGFloat]) -> CGFloat { items.isEmpty ? 0 : items.reduce(0, +) + CGFloat(items.count - 1) * 7 }
        var left: [CGFloat] = []
        if showMusic { left.append(20) }
        if term.summary.running > 0 { left.append(term.summary.running > 1 ? 26 : 12) }
        if !tasks.pending.isEmpty { left.append(tasks.pending.count > 9 ? 36 : 30) }
        var right: [CGFloat] = []
        if timer.running { right.append(40) }
        if showMusic { right.append(18) }
        let w = max(width(left), width(right))
        return w == 0 ? 0 : w + 22
    }

    private var size: CGSize {
        let n = state.notchSize
        if state.isOpen { return state.openSize }
        if let peek = state.peek {
            // Fit the message: rough text width + icon + padding, never narrower than the ears.
            let textW = CGFloat(peek.text.count) * 6.6 + (peek.image != nil || peek.symbol != nil ? 32 : 0) + 48
            let w = min(max(textW, n.width + 90, n.width + earWidth * 2 + 8), n.width + 380)
            return CGSize(width: w, height: n.height + 38)
        }
        return CGSize(width: n.width + earWidth * 2 + 8, height: n.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: radius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(state.isOpen ? 0.5 : 0), radius: 16, y: 6)

                ZStack(alignment: .top) {
                    if contentMounted || state.isOpen {
                        // Laid out once at full size and revealed by the growing shape.
                        OpenContent()
                            .frame(width: state.openSize.width, height: state.openSize.height, alignment: .top)
                            .opacity(state.isOpen ? 1 : 0)
                            .animation(state.isOpen ? .easeOut(duration: 0.2).delay(0.07) : .easeIn(duration: 0.08),
                                       value: state.isOpen)
                            .allowsHitTesting(state.isOpen)
                    }
                    ClosedContent(earWidth: earWidth, showMusic: showMusic)
                        .opacity(state.isOpen ? 0 : 1)
                        .animation(state.isOpen ? .easeIn(duration: 0.08) : .easeOut(duration: 0.2).delay(0.12),
                                   value: state.isOpen)
                        .allowsHitTesting(!state.isOpen)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(radius: radius))
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(accent)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: earWidth)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: state.openSize)
        .onAppear { state.closedSize = size }
        .onChange(of: state.isOpen) { _, open in
            if open {
                contentMounted = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if !state.isOpen { contentMounted = false } }
            }
        }
        .onChange(of: size) { _, new in if !state.isOpen { state.closedSize = new } }
    }
}

/// What sits in the "ears" beside the camera when closed, plus peeks.
struct ClosedContent: View {
    @EnvironmentObject var state: NotchState
    let earWidth: CGFloat
    let showMusic: Bool
    @ObservedObject var tasks = TasksStore.shared
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var term = TerminalHost.shared
    @ObservedObject var music = NowPlaying.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    if showMusic {
                        ArtworkView(image: music.artwork, size: 20, radius: 5)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if term.summary.running > 0 {
                        ChatStatusDot(summary: term.summary)
                    }
                    if !tasks.pending.isEmpty {
                        Label("\(tasks.pending.count)", systemImage: "checklist")
                            .labelStyle(TightLabel())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .frame(width: earWidth)

                Spacer(minLength: state.notchSize.width)

                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    if timer.running {
                        Text(timer.display).monospacedDigit().foregroundStyle(accent)
                    }
                    if showMusic {
                        AudioBars(playing: music.isPlaying, color: music.tint, bars: 4, height: 13, barWidth: 2.5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.trailing, 14)
                .frame(width: earWidth)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: state.notchSize.height)
            .opacity(earWidth > 0 ? 1 : 0)

            if let peek = state.peek {
                HStack(spacing: 9) {
                    if let image = peek.image {
                        ArtworkView(image: image, size: 22, radius: 5)
                    } else if let symbol = peek.symbol {
                        Image(systemName: symbol).foregroundStyle(peek.tint).font(.system(size: 14, weight: .semibold))
                    }
                    Text(peek.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 22)
                .frame(height: 34)
                .transition(.opacity.combined(with: .offset(y: -6)))
                .id(peek.id)
            }
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

/// Green = chats running, pulsing orange = Claude working, pulsing yellow = needs you, blue ring = finished (unseen).
struct ChatStatusDot: View {
    let summary: TerminalHost.Summary

    private var color: Color {
        if summary.needsYou > 0 { return .yellow }
        if summary.working > 0 { return accent }
        if summary.finished > 0 { return .cyan }
        return .green
    }

    private var pulsing: Bool { summary.needsYou > 0 || summary.working > 0 }

    var body: some View {
        HStack(spacing: 3) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulsing)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let k = pulsing ? 0.5 + 0.5 * sin(t * (summary.needsYou > 0 ? 6 : 3.5)) : 1
                ZStack {
                    Circle().fill(color.opacity(0.35)).frame(width: 7 + 5 * k, height: 7 + 5 * k).opacity(pulsing ? 1 - k * 0.6 : 0)
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                .frame(width: 12, height: 12)
            }
            if summary.running > 1 { Text("\(summary.running)") }
        }
        .animation(.easeInOut(duration: 0.3), value: color)
    }
}

struct OpenContent: View {
    @EnvironmentObject var state: NotchState

    var body: some View {
        VStack(spacing: 0) {
            // Top strip: the camera lives in the middle, so only use the sides.
            HStack {
                TimelineView(.everyMinute) { ctx in
                    Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.pinned.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.pinned ? "pin.fill" : "pin")
                        if state.pinned { Text("Pinned").font(.system(size: 11, weight: .semibold)) }
                    }
                    .foregroundStyle(state.pinned ? accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(state.pinned ? "Unpin (close when the pointer leaves)" : "Pin open")
                Button { NotchController.shared.close() } label: {
                    Image(systemName: "chevron.up").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 30)
            .frame(height: max(state.notchSize.height, 28))

            TabBar()
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

            Group {
                switch state.tab {
                case .home: HomeView()
                case .calendar: CalendarTab()
                case .notes: NotesView()
                case .tasks: TasksView()
                case .code: CodeView()
                case .clipboard: ClipboardView()
                case .timer: TimerView()
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .overlay {
            if state.fileDragActive {
                DropZones().padding(14).transition(.opacity)
            }
        }
    }
}

/// Shown over the open panel while files are being dragged.
struct DropZones: View {
    @ObservedObject var term = TerminalHost.shared

    var body: some View {
        HStack(spacing: 12) {
            DropZone(title: "New Claude chat", subtitle: "A folder opens the chat there; files are added to the prompt",
                     icon: "plus.bubble") { term.newChat(with: $0) }
            if let s = term.selected, !s.isShell {
                DropZone(title: "Add to \(s.name)", subtitle: "Pastes the files into this chat's prompt",
                         icon: "text.badge.plus") { term.addToCurrent($0) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.88)))
    }
}

private struct DropZone: View {
    let title: String
    let subtitle: String
    let icon: String
    let onDrop: ([URL]) -> Void
    @ViewState private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26, weight: .medium))
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(targeted ? accent : .white)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(accent.opacity(targeted ? 0.16 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(targeted ? accent : Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            var urls = [URL]()
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { onDrop(urls) }
            return true
        }
    }
}

struct TabBar: View {
    @EnvironmentObject var state: NotchState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { state.tab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                        Text(tab.title).lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(state.tab == tab ? Color.white.opacity(0.14) : Color.clear)
                    )
                    .foregroundStyle(state.tab == tab ? Color.white : Color.white.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared bits

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? accent : Color.white.opacity(0.12)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}

/// `@State` is a SwiftUI macro in the macOS 27 SDK whose plugin only ships with full Xcode.
/// Spelling the property wrapper through a typealias bypasses the macro so this builds with Command Line Tools alone.
typealias ViewState = State

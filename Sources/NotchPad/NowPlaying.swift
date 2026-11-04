import AppKit
import SwiftUI

/// Tracks whatever macOS's system "Now Playing" shows: YouTube Music in a browser, Spotify, Music, podcasts…
///
/// Apple only lets its own binaries read Now Playing, so a small JavaScript-for-Automation helper runs under
/// `/usr/bin/osascript`, polls MediaRemote once a second, and prints a JSON line whenever something changes.
/// Controls go through MediaRemote the same way, so no per-app Automation permission is needed.
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    /// Bundle id of the app that's playing (e.g. com.vivaldi.Vivaldi).
    @Published private(set) var sourceApp: String?
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = accent
    @Published private(set) var duration: Double?
    /// Position at `baseDate`; nil when unknown.
    private(set) var basePosition: Double?
    private(set) var baseDate = Date()
    private var trackKey = ""
    private var sawFirstUpdate = false
    private var helper: Process?
    /// Long-running command helper; commands are written to its stdin (no per-press launch cost).
    private var commander: Process?
    private var commanderInput: FileHandle?
    /// Play state we just asked for; stale helper reports that disagree are ignored until it lands.
    private var optimistic: (playing: Bool, until: Date)?
    private var buffer = Data()
    private let artQueue = DispatchQueue(label: "notchpad.nowplaying.art")

    var hasTrack: Bool { !title.isEmpty }

    var sourceIcon: NSImage? {
        guard let id = sourceApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func elapsed(at date: Date = Date()) -> Double? {
        guard let basePosition else { return nil }
        let e = basePosition + (isPlaying ? date.timeIntervalSince(baseDate) : 0)
        return min(e, duration ?? e)
    }

    func start() {
        launchHelper()
        launchCommander()
    }

    // MARK: Controls (MediaRemote commands: 0 play, 1 pause, 4 next, 5 previous)

    /// Flips the UI immediately; the helper confirms within ~half a second.
    func playPause() {
        let playing = !isPlaying
        if let e = elapsed() {
            basePosition = e
            baseDate = Date()
        }
        withAnimation(.easeOut(duration: 0.15)) { isPlaying = playing }
        optimistic = (playing, Date().addingTimeInterval(2.5))
        send(playing ? 0 : 1)
    }

    func next() { send(4) }
    func previous() { send(5) }

    private func send(_ command: Int) {
        if commander?.isRunning != true { launchCommander() }
        commanderInput?.write(Data("\(command)\n".utf8))
    }

    private func launchCommander() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", Self.commandScript]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            commander = p
            commanderInput = input.fileHandleForWriting
        } catch {
            NSLog("NotchPad: now-playing command helper failed: \(error)")
        }
    }

    // MARK: Helper process

    private func launchHelper() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", Self.watchScript]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            // Keep it alive (e.g. after sleep); back off a little.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.launchHelper() }
        }
        do {
            try p.run()
            helper = p
        } catch {
            NSLog("NotchPad: now-playing helper failed: \(error)")
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(obj) }
        }
    }

    private func apply(_ o: [String: Any]) {
        let first = !sawFirstUpdate
        sawFirstUpdate = true
        let title = o["title"] as? String ?? ""
        guard !title.isEmpty else {
            clear()
            return
        }
        let artist = o["artist"] as? String ?? ""
        let app = o["app"] as? String
        var playing = o["playing"] as? Bool ?? false
        if let opt = optimistic {
            if playing == opt.playing || Date() > opt.until {
                optimistic = nil
            } else {
                playing = opt.playing // stale report from before the command landed
            }
        }
        let key = "\(app ?? "")|\(title)|\(artist)"
        let newTrack = key != trackKey

        withAnimation(.easeInOut(duration: 0.25)) {
            sourceApp = app
            self.title = title
            self.artist = artist
            album = o["album"] as? String ?? ""
            isPlaying = playing
            let d = o["duration"] as? Double ?? 0
            duration = d > 0 ? d : nil
        }

        // Snapshot elapsed + how long ago it was taken → current position.
        if let e = o["elapsed"] as? Double {
            let age = o["age"] as? Double ?? 0
            basePosition = e + (playing ? max(0, age) : 0)
            baseDate = Date()
        } else if newTrack {
            basePosition = nil
        }

        if newTrack {
            trackKey = key
            artwork = nil
            // Announce song changes, but not whatever was already on when NotchPad launched.
            let announce = playing && !first
            loadArtwork(title: title, artist: artist, key: key) { image in
                guard announce else { return }
                NotchController.shared.peek(Peek(text: artist.isEmpty ? title : "\(title) · \(artist)",
                                                 symbol: image == nil ? "music.note" : nil,
                                                 image: image, tint: self.tint, seconds: 3.5) {
                    NotchController.shared.state.tab = .home
                })
            }
        }
    }

    private func clear() {
        guard hasTrack else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            sourceApp = nil
            title = ""
            artist = ""
            isPlaying = false
            artwork = nil
        }
        trackKey = ""
    }

    // MARK: Artwork

    private func loadArtwork(title: String, artist: String, key: String, then done: @escaping (NSImage?) -> Void) {
        artQueue.async { [weak self] in
            let image = Self.catalogArtwork(title: title, artist: artist)
            let tint = image.map(Self.vividAverage) ?? accent
            DispatchQueue.main.async {
                guard self?.trackKey == key else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.artwork = image
                    self?.tint = tint
                }
                done(image)
            }
        }
    }

    /// The search is picky about query shape, so try "title artist" then title alone (matching the artist).
    private static func catalogArtwork(title: String, artist: String) -> NSImage? {
        func search(_ term: String) -> [[String: Any]] {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [.init(name: "term", value: term), .init(name: "media", value: "music"),
                            .init(name: "entity", value: "song"), .init(name: "limit", value: "5")]
            guard let url = c.url, let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return json["results"] as? [[String: Any]] ?? []
        }
        let wanted = artist.lowercased()
        let byArtist = { (r: [String: Any]) in
            let a = (r["artistName"] as? String ?? "").lowercased()
            return !wanted.isEmpty && (a.contains(wanted) || wanted.contains(a))
        }
        var results = search("\(title) \(artist)")
        if results.isEmpty { results = search(title).filter(byArtist) }
        guard let hit = results.first(where: byArtist) ?? results.first,
              let art = hit["artworkUrl100"] as? String,
              let big = URL(string: art.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
              let imgData = try? Data(contentsOf: big) else { return nil }
        return NSImage(data: imgData)
    }

    /// Average colour of the cover, pushed bright enough to read on black.
    private static func vividAverage(of image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return accent }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return accent }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return Color(white: 0.85) } // greyscale covers → soft white
        return Color(hue: h, saturation: min(1, max(0.45, s * 1.25)), brightness: max(0.82, b))
    }

    // MARK: Helper scripts (JavaScript for Automation, run by Apple's osascript)

    private static let watchScript: String = writeScript("nowplaying-watch.js", """
    ObjC.import('Foundation');
    function run() {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
      var R = $.NSClassFromString('MRNowPlayingRequest');
      var out = $.NSFileHandle.fileHandleWithStandardOutput;
      ObjC.bindFunction('getppid', ['int', []]);
      var last = '';
      while (Number($.getppid()) !== 1) { // stop if NotchPad goes away
        var o = {};
        try {
          var item = R.localNowPlayingItem;
          var info = (item && !item.isNil()) ? item.nowPlayingInfo : null;
          if (info && !info.isNil()) {
            var g = function (k) { var v = info.objectForKey('kMRMediaRemoteNowPlayingInfo' + k); return (v && !v.isNil()) ? ObjC.unwrap(v) : null; };
            o.title = g('Title'); o.artist = g('Artist'); o.album = g('Album');
            o.duration = g('Duration'); o.elapsed = g('ElapsedTime');
            var ts = info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
            o.age = (ts && !ts.isNil()) ? -ts.timeIntervalSinceNow : 0;
          }
          o.playing = R.localIsPlaying === true;
          var path = R.localNowPlayingPlayerPath;
          if (path && !path.isNil() && !path.client.isNil()) o.app = ObjC.unwrap(path.client.bundleIdentifier);
        } catch (e) { o = { error: String(e) }; }
        var key = JSON.stringify([o.title, o.artist, o.playing, o.app, o.duration, o.elapsed]);
        if (key !== last) {
          last = key;
          out.writeData($(JSON.stringify(o) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
        }
        delay(0.5);
      }
    }
    """)

    /// Reads one command number per line from stdin and sends it. Browsers ignore MediaRemote's
    /// toggle (2), so callers send explicit play (0) / pause (1); 2 is still mapped for safety.
    private static let commandScript: String = writeScript("nowplaying-command.js", """
    ObjC.import('Foundation');
    function run() {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      var R = $.NSClassFromString('MRNowPlayingRequest');
      var input = $.NSFileHandle.fileHandleWithStandardInput;
      ObjC.bindFunction('getppid', ['int', []]);
      while (Number($.getppid()) !== 1) { // stop if NotchPad goes away
        var d = input.availableData;
        if (Number(d.length) === 0) break; // EOF (JXA reports lengths as strings)
        var s = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding));
        s.split('\\n').forEach(function (line) {
          var cmd = parseInt(line);
          if (isNaN(cmd)) return;
          if (cmd === 2) cmd = R.localIsPlaying === true ? 1 : 0;
          $.MRMediaRemoteSendCommand(cmd, $({}));
        });
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
      }
    }
    """)

    private static func writeScript(_ name: String, _ source: String) -> String {
        let url = Storage.dir.appendingPathComponent(name)
        try? source.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}

// MARK: - Views

/// Equalizer bars: driven by live system-audio levels when available (AudioLevels), otherwise a
/// stylised animation.
struct AudioBars: View {
    var playing: Bool
    var color: Color
    var bars = 4
    var height: CGFloat = 14
    var barWidth: CGFloat = 2.5
    @ObservedObject private var levels = AudioLevels.shared

    var body: some View {
        Group {
            if playing, let bands = levels.bands {
                HStack(alignment: .center, spacing: barWidth * 0.8) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(color)
                            .frame(width: barWidth, height: max(barWidth, height * CGFloat(0.12 + 0.88 * sample(bands, i))))
                    }
                }
                .animation(.linear(duration: 0.06), value: bands)
            } else {
                animated
            }
        }
        .frame(height: height)
    }

    /// Spread the 5 frequency bands across however many bars this instance draws.
    private func sample(_ bands: [Float], _ i: Int) -> Float {
        guard bands.count > 1, bars > 1 else { return bands.first ?? 0 }
        let x = Float(i) * Float(bands.count - 1) / Float(bars - 1)
        let lo = Int(x), hi = min(bands.count - 1, lo + 1)
        return bands[lo] + (bands[hi] - bands[lo]) * (x - Float(lo))
    }

    private var animated: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.8) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(barWidth, height * level(i, t)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: playing)
        }
    }

    private func level(_ i: Int, _ t: Double) -> CGFloat {
        guard playing else { return 0.18 }
        let p = Double(i) * 1.7
        let v = 0.55 * abs(sin(t * (5.1 + Double(i) * 0.9) + p)) + 0.45 * abs(sin(t * (2.3 + Double(i) * 1.3) + p * 2.1))
        return CGFloat(0.22 + 0.78 * v)
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.1))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Home card: cover, title, controls, progress, visualizer — tinted with the cover's colour.
struct NowPlayingCard: View {
    @ObservedObject var np = NowPlaying.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                ArtworkView(image: np.artwork, size: 50, radius: 9)
                    .shadow(color: np.tint.opacity(0.35), radius: 8, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if let icon = np.sourceIcon {
                            Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                                .help("Playing in \(np.sourceApp ?? "")")
                        }
                        Text(np.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    AudioBars(playing: np.isPlaying, color: np.tint, bars: 5, height: 12, barWidth: 2.5)
                }
                .frame(height: 50)
                Spacer(minLength: 0)
            }
            ProgressLine()
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                control("backward.fill", 12) { np.previous() }
                control(np.isPlaying ? "pause.fill" : "play.fill", 17) { np.playPause() }
                control("forward.fill", 12) { np.next() }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [np.tint.opacity(0.22), Color.white.opacity(0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .animation(.easeInOut(duration: 0.4), value: np.tint)
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProgressLine: View {
    @ObservedObject var np = NowPlaying.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            if let e = np.elapsed(at: ctx.date), let d = np.duration, d > 0 {
                VStack(spacing: 3) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(np.tint).frame(width: g.size.width * CGFloat(min(1, e / d)))
                        }
                    }
                    .frame(height: 3)
                    HStack {
                        Text(fmt(e)); Spacer(); Text("-" + fmt(max(0, d - e)))
                    }
                    .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 3)
            }
        }
    }

    private func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

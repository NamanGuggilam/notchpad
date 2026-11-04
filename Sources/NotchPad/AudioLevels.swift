import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Live loudness per frequency band from a private Core Audio tap on system output (macOS 14.2+).
///
/// Only levels are computed; no audio is stored. The tap runs only while something is playing, and
/// `bands` stays nil (so the visualizer falls back to its animation) if the tap can't start, permission
/// was denied, or it only ever hears silence.
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()

    /// 0…1 per band, low → high frequency. nil = no live data.
    @Published private(set) var bands: [Float]?

    private static let bandEdges: [Float] = [40, 150, 400, 1000, 2500, 8000]
    private let fftSize = 1024
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "notchpad.audiolevels", qos: .userInteractive)
    private var sampleRate: Float = 48_000
    private var channels = 2
    private var ring = [Float]()
    private var smoothed = [Float](repeating: 0, count: 5)
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private var window = [Float]()
    private var heardSound = false
    private var startedAt = Date()
    private var lastPublish = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    /// Follow playback: tap while playing, release it when paused.
    func follow(_ nowPlaying: NowPlaying) {
        nowPlaying.$isPlaying.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in playing ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    func start() {
        guard procID == nil else { return }
        guard #available(macOS 14.2, *) else { return }
        do {
            try startTap()
        } catch {
            report("tap unavailable: \(error) — using animated bars")
            stop()
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        DispatchQueue.main.async { self.bands = nil }
    }

    struct TapError: Error { let step: String; let status: OSStatus }

    /// Last visualizer status, in ~/Library/Application Support/NotchPad/visualizer-status.txt (for troubleshooting).
    private func report(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        try? line.write(to: Storage.dir.appendingPathComponent("visualizer-status.txt"), atomically: true, encoding: .utf8)
    }

    @available(macOS 14.2, *)
    private func startTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw TapError(step: "create tap", status: status) }
        tapID = tap

        // Tap format (sample rate / channels).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 {
            sampleRate = Float(asbd.mSampleRate)
            channels = max(1, Int(asbd.mChannelsPerFrame))
        }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchPad Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { throw TapError(step: "create aggregate", status: status) }
        aggregateID = agg

        let log2n = vDSP_Length(log2(Float(fftSize)))
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        ring.removeAll(keepingCapacity: true)
        heardSound = false
        startedAt = Date()

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else { throw TapError(step: "create IO proc", status: status) }
        procID = proc
        status = AudioDeviceStart(agg, proc)
        guard status == noErr else { throw TapError(step: "start", status: status) }
        report("tap started (\(Int(sampleRate)) Hz, \(channels) ch); waiting for sound")
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw TapError(step: "default output", status: status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError(step: "output UID", status: status) }
        return uid.takeRetainedValue() as String
    }

    // MARK: Analysis (runs on the audio queue)

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let data = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: count)
        let ch = max(1, Int(buffer.mNumberChannels))
        // Downmix to mono.
        var i = 0
        while i + ch - 1 < count {
            var s: Float = 0
            for c in 0..<ch { s += samples[i + c] }
            ring.append(s / Float(ch))
            i += ch
        }
        while ring.count >= fftSize {
            analyze(Array(ring.prefix(fftSize)))
            ring.removeFirst(fftSize / 2) // 50% overlap
        }
    }

    private func analyze(_ frame: [Float]) {
        guard let fft else { return }
        let n = fftSize
        let windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }

        let binHz = sampleRate / Float(n)
        var levels = [Float]()
        for b in 0..<(Self.bandEdges.count - 1) {
            let lo = max(1, Int(Self.bandEdges[b] / binHz))
            let hi = min(n / 2 - 1, max(lo + 1, Int(Self.bandEdges[b + 1] / binHz)))
            let rms = sqrt(vDSP.meanSquare(mags[lo..<hi])) / Float(n)
            let db = 20 * log10(max(rms, 1e-9))
            // Map roughly -70 dB…-20 dB onto 0…1, with a little extra lift for the quieter highs.
            let lift = Float(b) * 3
            levels.append(min(1, max(0, (db + 70 + lift) / 50)))
        }
        // Fast attack, slow release.
        for k in levels.indices {
            let a: Float = levels[k] > smoothed[k] ? 0.6 : 0.18
            smoothed[k] += (levels[k] - smoothed[k]) * a
        }
        if !heardSound, smoothed.contains(where: { $0 > 0.05 }) {
            heardSound = true
            report("hearing live audio")
        }

        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 1 / 40 else { return }
        lastPublish = now
        let out = smoothed
        // Pure silence for a few seconds while "playing" usually means capture permission was denied.
        let live = heardSound || now.timeIntervalSince(startedAt) < 3
        DispatchQueue.main.async { self.bands = live ? out : nil }
    }
}

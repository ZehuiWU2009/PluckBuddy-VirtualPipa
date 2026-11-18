import AVFoundation
import Foundation
import Combine

/// Offline stand-in for the microphone path that PluckBuddy's tuner and
/// technique classifier rely on.
///
/// Instead of listening to a real Pipa through the mic, this engine drives
/// the measured four-open-string model fitted from recordings of a real Pipa
/// and feeds the rendered buffers into the same `onBufferReceived` closure the
/// microphone tap would have used. The classifier and coach therefore "hear" a
/// virtual Pipa with no real instrument, no microphone and no network. The
/// waveguide remains as a fallback if the fitted resources cannot be loaded.
///
/// Wiring follows ElectricPipa's proven `AudioEngine`: the `AVAudioSourceNode`
/// format is matched to the engine's real output format, the node connects
/// straight to `outputNode` (bypassing the iOS 26 spatial mixer), and the
/// render block is built in a `nonisolated` factory so the real-time IO thread
/// can call it without tripping Swift 6's `MainActor.assumeIsolated`.
@MainActor
final class VirtualPipaEngine: ObservableObject {
    static let shared = VirtualPipaEngine()

    private var core: PipaAudioCore?
    private var sourceNode: AVAudioSourceNode?
    private let engine = AVAudioEngine()
    private let preferredSampleRate: Double = 48000

    /// One-shot, background-driven start state. Keeps the blocking
    /// `AVAudioSession` activation off the main thread so the UI never stalls
    /// (and the "audio session hang risk" analyzer warning stays away).
    private enum StartState { case idle, starting, started, failed }
    private var startState: StartState = .idle

    /// Surfaced in the UI when the audio session refuses to start, so a silent
    /// instrument is never mistaken for a broken view.
    @Published var startupError: String?
    @Published var isRunning = false
    @Published var masterGain: Float = 0.5 {
        didSet { core?.setMasterGain(masterGain) }
    }
    /// Neutral for the measured model: 0.5 leaves the fitted spectrum alone.
    @Published var brightness: Double = 0.5 {
        didSet { core?.setBrightness(brightness) }
    }
    /// Set only if the measured resources fail to load, so a silent instrument
    /// is never mistaken for a broken view and the waveguide takes over.
    @Published var modelNote: String?

    private init() {}

    @discardableResult
    func ensureStarted() -> Bool {
        switch startState {
        case .started:
            return core != nil
        case .starting:
            return false
        case .idle, .failed:
            // Capture main-actor state, then run the blocking audio-session and
            // AVAudioEngine setup on a background thread. This is what keeps the
            // "audio session hang risk" warning away — `setActive` is never
            // called on the main thread.
            let gain = masterGain
            let bright = brightness
            startState = .starting
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.startOffMain(masterGain: gain, brightness: bright)
                } catch {
                    self.reportStartError(error)
                    self.startState = .failed
                }
            }
            return false
        }
    }

    /// Blocking setup (audio session + AVAudioEngine graph) — runs entirely off
    /// the main actor. It reads nothing from `self` except the captured `engine`,
    /// and hands the live kernel/source back to the main actor on success.
    private func startOffMain(masterGain: Float, brightness: Double) async throws {
        let engine = self.engine
        let preferredSampleRate = self.preferredSampleRate

        let (core, source, loadNote) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(PipaAudioCore, AVAudioSourceNode, String?), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    // Playback only: no microphone permission, so the offline
                    // experience never prompts for recording access.
                    try session.setCategory(.playback, options: [.mixWithOthers])
                    try session.setPreferredSampleRate(preferredSampleRate)
                    try session.setActive(true)

                    // Read the engine's real output format: the session may fall
                    // back from 48000, and the channel count follows the output.
                    // The source node has to match exactly so no converter is
                    // inserted between it and the output.
                    let outputFormat = engine.outputNode.inputFormat(forBus: 0)
                    let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : preferredSampleRate
                    let channels: AVAudioChannelCount = outputFormat.channelCount > 0 ? outputFormat.channelCount : 2

                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate,
                                               channels: channels,
                                               interleaved: false)!

                    // Rebuild the DSP kernel at the real sample rate so source
                    // and output agree and no sample-rate converter can appear.
                    // The fitted open strings are the default voice. If their
                    // resources cannot be read, fall back to the waveguide so
                    // the instrument still sounds and say why in modelNote.
                    let core: PipaAudioCore
                    var loadNote: String?
                    do {
                        let model = try PipaKitModel.load(sampleRate: rate)
                        core = PipaAudioCore(sampleRate: rate,
                                             synth: PipaKitSynth(model: model, sampleRate: rate))
                    } catch {
                        loadNote = "实测音色未载入，已使用波导模型：\(error)"
                        core = PipaAudioCore(sampleRate: rate, bodySizeScale: 1.0)
                    }
                    core.setMasterGain(masterGain)
                    core.setBrightness(brightness)

                    let source = AVAudioSourceNode(format: format,
                                                   renderBlock: VirtualPipaEngine.makeRenderBlock(core: core))
                    engine.attach(source)
                    engine.connect(source, to: engine.outputNode, format: format)
                    try engine.start()

                    cont.resume(returning: (core, source, loadNote))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // Publish the live objects back on the main actor.
        self.core = core
        self.sourceNode = source
        self.modelNote = loadNote
        self.startState = .started
        self.startupError = nil
        self.isRunning = true
    }

    /// Translates a start failure into a user-facing message.
    private     func reportStartError(_ error: Error) {
        modelNote = nil
        // AVAudioSessionErrorInsufficientPriority ('!pri', 561017449): another
        // app (a call, Voice Memos, Siri, etc.) holds a higher-priority audio
        // session. This is environmental, not a code fault — say so clearly
        // and let the UI offer a retry.
        if let ns = error as? NSError,
           ns.domain == "NSOSStatusErrorDomain", ns.code == 561017449 {
            startupError = "Audio is being used by another app (a call, Voice Memos, etc.). Close it and tap Retry."
        } else {
            startupError = String(describing: error)
        }
        print("虚拟琵琶引擎启动失败：\(error)")
    }

    /// Render block factory, created in a nonisolated context.
    ///
    /// Writing the closure directly inside the `@MainActor` `start()` makes the
    /// closure inherit MainActor isolation. When CoreAudio then calls it from
    /// the real-time IO thread, the Swift 6 runtime's `MainActor.assumeIsolated`
    /// check fails and the process dies on `__builtin_trap()`. Creating the
    /// block in a nonisolated factory leaves it free of any actor isolation, so
    /// the IO thread can call it safely.
    nonisolated private static func makeRenderBlock(core: PipaAudioCore) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            core.render(frames: Int(frameCount), bufferList: audioBufferList)
            return noErr
        }
    }

    /// Begins rendering the virtual Pipa and forwards every rendered buffer to
    /// `onBufferReceived` — the exact closure `AudioManager.startListening` would
    /// have handed the microphone tap. Downstream resampling (48 kHz to 16 kHz)
    /// and the mlmodel input therefore behave identically to the live-mic path.
    func startVirtualListening(onBufferReceived: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard ensureStarted(), let source = sourceNode else {
            throw VirtualPipaError.kernelUnavailable
        }
        source.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            guard let self else { return }
            // The mic path is mono, so downmix here to keep the classifier's
            // existing 48 kHz -> 16 kHz resampler happy.
            onBufferReceived(self.makeMono(from: buffer), time)
        }
    }

    func stop() {
        sourceNode?.removeTap(onBus: 0)
        engine.stop()
        startState = .idle
        core = nil
        sourceNode = nil
        modelNote = nil
        startupError = nil
        isRunning = false
    }

    /// Averages interleaved-or-planar multichannel input down to mono. Returns
    /// the input unchanged when it is already mono or cannot be read.
    private func makeMono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1, let src = buffer.floatChannelData else { return buffer }
        let frames = Int(buffer.frameLength)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: buffer.format.sampleRate,
                                      channels: 1,
                                      interleaved: false)!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData else { return buffer }
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += src[c][f] }
            dst[0][f] = sum / Float(channels)
        }
        mono.frameLength = AVAudioFrameCount(frames)
        return mono
    }

    // MARK: - Performance interface

    /// Every entry point guards on a live kernel. Starting the audio session is
    /// allowed to fail on a real device, and the old force-unwrap turned that
    /// into a crash on the very first pluck. A failed start now leaves the view
    /// alive and reports the reason through `startupError`.
    func pluck(string: Int, fret: Int, velocity: Double = 0.85, position: Double = 0.5) {
        guard ensureStarted(), let core else { return }
        core.pluck(string: string, fret: fret, velocity: velocity, position: position)
    }

    func strum(ascending: Bool = true, velocity: Double = 0.78) {
        guard ensureStarted(), let core else { return }
        core.strum(ascending: ascending, velocity: velocity)
    }

    /// Wheel (轮指): five fingers thrown in turn across one string.
    func tremolo(string: Int, fret: Int, rate: Double, cycles: Double, velocity: Double = 0.5) {
        guard ensureStarted(), let core else { return }
        core.tremolo(string: string, fret: fret, rate: rate, cycles: cycles, velocity: velocity)
    }

    func bend(string: Int, to frequency: Double) {
        guard ensureStarted(), let core else { return }
        core.bend(string: string, to: frequency)
    }

    func damp(string: Int) {
        core?.damp(string: string)
    }

    /// Tan-Tiao (弹挑): alternating outward and inward strokes.
    func tanTiao(string: Int, fret: Int, velocity: Double = 0.7, position: Double = 0.5, interval: Double = 0.5, duration: Double = 5.0) {
        guard ensureStarted(), let core else { return }
        core.tanTiao(string: string, fret: fret, velocity: velocity, position: position, interval: interval, duration: duration)
    }

    // MARK: - Sustained rolls (continuous mode)

    func rollStart(kind: RollKind, string: Int, fret: Int, interval: Double,
                   velocity: Double, position: Double = 0.5) {
        guard ensureStarted(), let core else { return }
        core.rollStart(kind: kind, string: string, fret: fret, interval: interval,
                       velocity: velocity, position: position)
    }

    func rollMove(string: Int, fret: Int) {
        core?.rollMove(string: string, fret: fret)
    }

    func rollSetTempo(_ interval: Double) {
        core?.rollSetTempo(interval)
    }

    func rollStop() {
        core?.rollStop()
    }

    func dampAll() {
        core?.dampAll()
    }
}

enum VirtualPipaError: LocalizedError {
    case kernelUnavailable

    var errorDescription: String? {
        switch self {
        case .kernelUnavailable:
            return "Virtual instrument failed to start"
        }
    }
}

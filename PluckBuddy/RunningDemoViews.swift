//
//  RunningDemoViews.swift
//  PluckBuddy
//
//  Running 游戏的两个演示辅助视图 + 拨弦声播放器。
//  供 SSC 评审使用：评委没有真 Pipa，也不装麦克风权限。
//
//  1) DemoPluckSynth  —— 实时合成短促拨弦音，四弦不同音高，随事件触发。
//  2) DemoVideoView   —— 播放演奏视频；视频缺失时显示占位，不崩。
//
//  空弦交互面板在 PipaOpenStringsPad.swift，用的是真实琴身照片。
//

import SwiftUI
import Combine
import AVFoundation
import UIKit

// MARK: - 1. 拨弦声播放器

/// Renders one measured open-string stroke into a mono buffer.
///
/// Touched only from `DemoPluckSynth`'s serial audio queue. A fresh voice is
/// built for every stroke, so one demo note never inherits the ringing tail of
/// the previous one; the model itself is loaded once at the device's rate.
private final class MeasuredPluckRenderer: @unchecked Sendable {
    private let sampleRate: Double
    private var model: PipaKitModel?

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Read the fitted resources on the audio queue before the first stroke,
    /// so the first pluck is not late while a 2 MB model is decoded.
    func prewarm() {
        if model == nil { model = try? PipaKitModel.load(sampleRate: sampleRate) }
    }

    func render(string: Int, velocity: Float) -> AVAudioPCMBuffer? {
        prewarm()
        guard let model,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleRate * 1.0)) else {
            return nil
        }
        let frames = Int(buffer.frameCapacity)
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        // The pad numbers strings from the Zi string down (0 = thinnest);
        // the fitted model numbers them the other way (0 = Chan, thickest).
        let index = 3 - min(max(string, 0), 3)
        let measured = model.measuredFrequency(string: index)
        let target = PipaTuning.frequency(string: index, fret: 0)
        let shift = measured > 0 ? target / measured : 1
        var voice = model.makeVoice(string: index,
                                    fittedPosition: PipaKitSynth.fittedPluckPosition[index])
        voice.start(shift: shift, velocity: Double(velocity), position: 0.5)

        // The fitted string rings far longer than this demo buffer. Fade the
        // last 80 ms so rotating back to a busy voice does not click.
        let fadeStart = frames - Int(sampleRate * 0.08)
        for i in 0..<frames {
            let frame = voice.renderSample()
            var sample = (frame.left + frame.right) * 0.5
            if i > fadeStart {
                sample *= Float(Double(frames - i) / Double(frames - fadeStart))
            }
            channel[i] = sample
        }
        return buffer
    }
}

/// 演示拨弦音用的是与虚拟琴相同的四空弦实测模型：分音、快/慢衰减、拍频对
/// 与残余层全部来自真琴录音的拟合，而不是一段手写的正弦叠加。
/// 每个音离线渲染成一个短 buffer，交给一路声部立刻播放，仍然离线、无需麦克风。
///
/// 线程约定（重要）：音频会话激活与 AVAudioEngine 启动都是可能阻塞的调用，
/// 放在主线程会卡住界面，Xcode 的 Thread Performance Checker 会直接在
/// setCategory / setActive 上报 "AVAudioSession Hang Risk"。
/// 所以"启动引擎 + 排音"整段都放到一条私有串行队列上：既避开主线程阻塞，
/// 又保证"先启动、后排音"的先后顺序，第一次拨弦不会丢音。
@MainActor
final class DemoPluckSynth: ObservableObject {

    private let engine = AVAudioEngine()
    /// 声部池：每个声部是一路独立的播放节点。
    ///
    /// 一个节点上的 buffer 是**顺序**播放的——`scheduleBuffer(at: nil)` 的意思是
    /// "排在上一个后面"，不是"立刻播"。单节点时每声 0.85 秒的余音会把后面的音全堵住：
    /// 手指 0.15 秒扫过四根弦，耳朵听到的是 0.85 / 1.70 / 2.56 秒三声，
    /// 一个跟手指无关的固定节奏。多声部轮流用，过弦就响，余音还能叠着走。
    ///
    /// 数量按"最快连拨也不截断余音"反推：一声 1 秒，12 路轮一圈是 12 声，
    /// 每秒 14 声以内绕回同一路时，那声早就淡出完了。再多只是白占资源。
    private let voices: [AVAudioPlayerNode] = (0..<12).map { _ in AVAudioPlayerNode() }
    private var nextVoice = 0
    private let sampleRate = 44100.0

    /// 子弦→缠弦，索引与 fitted model 一致；音高由模型自己的定弦表给出。
    private let stringCount = 4
    private let renderer = MeasuredPluckRenderer(sampleRate: 44100.0)

    /// 音频启动与排音共用的串行队列，串行是关键：顺序即执行顺序。
    private static let audioQueue = DispatchQueue(
        label: "com.zehuiwu.pluckbuddy.demo-pluck-synth",
        qos: .userInitiated
    )

    /// attach / connect 只在主线程做一次，之后所有音频操作都在 audioQueue 上。
    private var graphBuilt = false

    /// 预热音频引擎。进入弹挑模式时就调用，让第一次点弦立刻出声，
    /// 避免冷启动延迟或被之前的视频播放打断的音频会话影响。
    func prepare() {
        buildGraphIfNeeded()
        let engine = self.engine
        let voices = self.voices
        let renderer = self.renderer
        Self.audioQueue.async {
            renderer.prewarm()
            Self.startEngineIfNeeded(engine: engine, voices: voices)
        }
    }

    func stop() {
        let engine = self.engine
        let voices = self.voices
        Self.audioQueue.async {
            for voice in voices { voice.stop() }
            engine.stop()
        }
    }

    /// 触发一次拨弦：用实测空弦模型渲染一段音，交给一路声部立刻播放。
    ///
    /// 声部轮转是"过弦就响"的关键：新音不会排在上一声的余音后面等。
    /// 正常连拨速度下轮一圈就够旧音衰减完，所以拨弦之间是真的叠着响，像真琴的余音。
    func play(string: Int, velocity: Float) {
        prepare()
        let index = min(max(string, 0), stringCount - 1)
        let voice = voices[nextVoice]
        let renderer = self.renderer
        nextVoice = (nextVoice + 1) % voices.count
        // 渲染放在音频队列上做：模型只有四根空弦，单音 buffer 不占主线程一帧的时间。
        Self.audioQueue.async {
            guard let buffer = renderer.render(string: index, velocity: velocity) else { return }
            if !voice.isPlaying { voice.play() }
            // .interrupts：万一又轮回到这一路、旧音还在响，新音直接把它顶掉、立刻出声，
            // 而不是排在后面等它播完。打断在音频线程的采样级完成，不用重启节点，也就没有爆音。
            voice.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    private func buildGraphIfNeeded() {
        guard !graphBuilt else { return }
        graphBuilt = true
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        for voice in voices {
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
        }
    }

    /// 只能在 audioQueue 上调用。用引擎自身的运行状态做判据，不需要额外的主线程标志位。
    private nonisolated static func startEngineIfNeeded(engine: AVAudioEngine,
                                                        voices: [AVAudioPlayerNode]) {
        if engine.isRunning {
            for voice in voices where !voice.isPlaying { voice.play() }
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // 拨弦音与视频/其他播放共存，不抢独占。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            #endif
            try engine.start()
            for voice in voices { voice.play() }
        } catch {
            print("⚠️ DemoPluckSynth 启动失败: \(error)")
        }
    }

}

// MARK: - 2. 演奏视频控制器与视图

/// 演示视频控制器：播放一段有限时长的演奏视频，播放速度在 limitSeconds 内由慢到快，
/// 到时或视频自然播完即发布 didFinish，由界面自动切到 Play along。
///
/// 播放权交给用户：进演示模式只 prepare（把第一帧摆出来、停在 0），点播放才开始。
/// 暂停/续播按"已播秒数"记账（accumulated + 本段起点），所以反复暂停也不会让
/// 加速曲线和 12 秒限额被暂停时间污染。
@MainActor
final class DemoVideoController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loadFailed = false
    @Published private(set) var didFinish = false
    /// 视频定格后、稍等片刻才置 true，界面据此弹出"要不要自己试"的卡片。
    /// 单纯 didFinish 立刻弹窗太急，画面刚停就盖住最后一帧，观感很突然。
    @Published private(set) var promptReady = false
    @Published private(set) var progress: Double = 0
    /// 是否正在播。界面的播放/暂停图标直接读它，也是小人动画的开关依据。
    @Published private(set) var isPlaying = false

    private let resourceName: String
    private let type: String
    /// 演示视频显示多少秒后自动切到 Play along。想缩短/加长只改这里。
    private let limitSeconds: TimeInterval
    /// 视频播完后停留多久再询问，留出看最后一帧的时间。
    private let promptDelay: TimeInterval = 1.6
    private let startRate: Float = 0.7
    private let endRate: Float = 1.5

    /// 演示视频的播放时长（= limitSeconds）。顶部"剩余时间"在演示模式直接读它，
    /// 保证和视频进度一致；不再用练习时长的默认值。
    var playbackDuration: TimeInterval { limitSeconds }
    /// 已经播过的秒数，由 progress 反推：暂停时 progress 不变，剩余时间也跟着停。
    var elapsedSeconds: TimeInterval { playbackDuration * progress }

    private var endObserver: NSObjectProtocol?
    private var limitWork: DispatchWorkItem?
    private var promptWork: DispatchWorkItem?
    private var ticker: Timer?
    /// 本段连续播放的起点。暂停时为 nil。
    private var startedAt: Date?
    /// 之前各段已经播过的秒数，暂停时结算进来。
    private var accumulated: TimeInterval = 0

    init(resourceName: String = "pipa_performance", type: String = "mp4",
         limitSeconds: TimeInterval = 12) {
        self.resourceName = resourceName
        self.type = type
        self.limitSeconds = limitSeconds
    }

    /// 只加载、不播放：进演示模式时用，先把第一帧摆出来，等用户点播放。
    func prepare() {
        teardown()
        didFinish = false
        promptReady = false
        isPlaying = false
        progress = 0
        accumulated = 0
        startedAt = nil
        loadPlayerIfNeeded()
    }

    /// 播放 / 续播。已经播完过就从头再来。
    func play() {
        // 只补一个播放器，不重置进度账：视频缺失时 player 永远是 nil，
        // 若在这里走一次 prepare 就会把续播的进度抹成 0。
        loadPlayerIfNeeded()
        guard !isPlaying else { return }
        if didFinish { rewind() }

        isPlaying = true
        startedAt = Date()
        if let p = player {
            p.rate = rate(for: progress)
            p.play()
            observeEnd(p)
        }
        startTicker()
        scheduleLimit()
    }

    /// 用户主动暂停：停表、停声，进度停在当前帧。小人的暂停由调用方同步处理。
    func pause() {
        accumulate()
        cancelTimers()
        player?.pause()
        isPlaying = false
    }

    /// 离开整个模块时调用：彻底释放播放器并重置状态，下次进来是"未播放"。
    func stop() {
        teardown()
        didFinish = false
        promptReady = false
        progress = 0
        isPlaying = false
        accumulated = 0
        startedAt = nil
    }

    // MARK: - 内部

    /// 补一个停在第 0 帧的播放器。只建 player，不碰进度账。
    private func loadPlayerIfNeeded() {
        guard player == nil else { return }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: type) else {
            loadFailed = true
            print("⚠️ 未找到演奏视频 \(resourceName).\(type)，显示占位（演示流程照常推进）")
            return
        }
        loadFailed = false
        let p = AVPlayer(url: url)
        p.isMuted = false
        // 不给 rate：rate 一赋值视频立刻就动了，这里要的就是停在第一帧。
        p.pause()
        player = p
    }

    private func rewind() {
        didFinish = false
        promptReady = false
        progress = 0
        accumulated = 0
        startedAt = nil
        player?.seek(to: .zero)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let start = startedAt else { return }
        let elapsed = accumulated + Date().timeIntervalSince(start)
        let p = min(max(elapsed / limitSeconds, 0), 1)
        progress = p
        player?.rate = rate(for: p)
    }

    /// 播放速度随进度从 startRate 线性升到 endRate，观感上是跟着小人一起加速。
    private func rate(for progress: Double) -> Float {
        startRate + (endRate - startRate) * Float(progress)
    }

    private func scheduleLimit() {
        limitWork?.cancel()
        // 剩余额度要扣掉已经播过的，暂停再久也不会被重置。
        let remaining = max(limitSeconds - accumulated, 0.1)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.finish() }
        }
        limitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func observeEnd(_ p: AVPlayer) {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func accumulate() {
        guard let start = startedAt else { return }
        accumulated += Date().timeIntervalSince(start)
        startedAt = nil
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        pause()   // 播放结束立刻停声，不再继续响

        // 定格片刻再发布"可以询问了"，让最后一帧留在屏幕上。中途切模式会被 stop 取消。
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.promptReady = true }
        }
        promptWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + promptDelay, execute: work)
    }

    private func cancelTimers() {
        limitWork?.cancel(); limitWork = nil
        promptWork?.cancel(); promptWork = nil
        ticker?.invalidate(); ticker = nil
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }

    private func teardown() {
        cancelTimers()
        player?.pause()
        player = nil
    }
}

/// 演奏视频展示视图。生命周期由外层 RunningPracticeView 通过 controller 控制。
///
/// 这里刻意不用 SwiftUI 的 VideoPlayer：它自带一套系统播放控件，点一下画面就冒出进度条和
/// 播放键，用户在那儿暂停时跑步动画不会跟着停，等于多出一个管不住的第二开关。
/// 换成裸的 AVPlayerLayer（不接收触摸），播放/暂停只剩界面上那一个按钮。
struct DemoVideoView: View {
    @ObservedObject var controller: DemoVideoController

    var body: some View {
        ZStack {
            if let player = controller.player {
                DemoVideoSurface(player: player)
            } else if controller.loadFailed {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Performance video")
                        .font(.headline)
                    Text("Add pipa_performance.mp4 to the app bundle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView()
            }
        }
    }
}

/// 只负责把 AVPlayer 的画面铺出来，不含任何控件。
private final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct DemoVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

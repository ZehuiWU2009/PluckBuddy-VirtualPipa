//
//  WavePracticeView.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/7/15.
//

import SwiftUI

/// 扫弦水波。版式与「弹挑跑步」「轮指花开」同一套：顶部一行控制栏、上半动画面板、
/// 中间指标条、下半演示视频或琴身；看完演示 → 设置 → 自己扫，练完出报告弹框。
/// 只有水波保留自己的蓝色系——三个模块是一套界面语言的三种性格。
struct WavePracticeView: View {
    @StateObject private var viewModel = WaveViewModel()
    @StateObject private var synth = DemoPluckSynth()
    @StateObject private var video = DemoVideoController()
    @Environment(\.dismiss) private var dismiss

    /// 演示 / 扫弦两种体验。进模块先停在演示，播完弹框询问，不再有手动切换。
    @State private var mode: Int = 0
    @State private var showTryPrompt = false
    @State private var showSettings = false
    /// 设置确认后是否进入 play。看完演示点「确认」→ 先出设置页，确认后才切。
    @State private var enterPlayAfterSettings = false
    /// 演奏页的右滑返回一直锁着，连演奏完弹出的报告页也锁；报告点「确认」才解锁。
    @State private var swipeBackLocked = true

    /// 这一笔已经划过哪几根弦。四根都过一遍才算一次扫弦——
    /// 真琴上扫弦本来就是一笔过四弦，逐根计次会把一次扫弦算成四次。
    @State private var strokeStrings: [Int] = []
    @State private var strokeStartedAt: Date?
    @State private var strokeDirection: String = "挑"

    var body: some View {
        ZStack {
            // 整体底色：淡青 → 淡蓝 → 淡紫蓝，和另外两个模块是同一套亮度关系。
            LinearGradient(colors: [
                Color(red: 0.88, green: 0.95, blue: 0.99),
                Color(red: 0.86, green: 0.93, blue: 0.99),
                Color(red: 0.89, green: 0.92, blue: 0.99)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // 演奏页禁用系统右滑返回：扫弦一笔向右，从边缘起划不会误触发返回。
            // 报告页也继续锁着，只有报告「确认」点了才解锁。
            SwipeBackDisabler(isLocked: $swipeBackLocked)
                .frame(width: 0, height: 0)

            content

            if showTryPrompt { tryPromptCard }

            if isShowingReport { practiceReportCard }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showTryPrompt)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isShowingReport)
        .navigationTitle(L("扫弦水波"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings, onDismiss: {
            // 从「看完演示 → 确认」进设置，用户却点了取消：回到询问卡片。
            if enterPlayAfterSettings {
                enterPlayAfterSettings = false
                showTryPrompt = true
            }
        }) {
            WaveSettingsSheet(
                targetBPM: $viewModel.targetBPM,
                targetDuration: $viewModel.targetDuration,
                metronomeEnabled: Binding(
                    get: { viewModel.metronomeIsEnabled },
                    set: { viewModel.metronomeIsEnabled = $0 }
                ),
                metronomeSoundType: Binding(
                    get: { viewModel.metronomeSoundType },
                    set: { viewModel.metronomeSoundType = $0 }
                ),
                onApply: {
                    if enterPlayAfterSettings {
                        enterPlayAfterSettings = false
                        applyMode(1)
                    } else {
                        viewModel.refreshManualSession()
                    }
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // 与另外两个模块同一个节拍器开关：响着是绿色实心，停了是灰色线框。
                // 颜色跟 isPlaying（真正在打拍）走，不跟 isEnabled 走。
                Button(action: {
                    withAnimation(.spring()) {
                        viewModel.metronomeIsEnabled = !viewModel.metronome.isPlaying
                    }
                }) {
                    Image(systemName: viewModel.metronome.isPlaying ? "metronome.fill" : "metronome")
                        .foregroundStyle(viewModel.metronome.isPlaying ? .green : .primary)
                }
                .accessibilityLabel(Text(L("节拍器")))
            }
        }
        .onAppear {
            // 进模块只"就绪"：视频停在第 0 帧，水面静止，等用户点播放。
            viewModel.prepareDemoSession()
            video.prepare()
            viewModel.metronome.bpm = Int(viewModel.targetBPM)
        }
        .onDisappear {
            video.stop()
            viewModel.stopPractice()
            viewModel.metronome.stop()
            synth.stop()
        }
        // 视频一播完就停脚本事件源，否则画面定住后水波还在荡。
        .onChange(of: video.didFinish) { _, finished in
            if finished {
                viewModel.stopPractice()
                viewModel.metronome.stop()
            }
        }
        .onChange(of: video.promptReady) { _, ready in
            if ready { showTryPrompt = true }
        }
    }

    /// 主内容：顶部控制栏 + 上半水波 + 指标条 + 下半（视频 / 琴身）。
    private var content: some View {
        GeometryReader { geometry in
            let topHeight = geometry.size.height * 0.34
            VStack(spacing: 10) {
                TopControlBar(
                    targetBPM: viewModel.targetBPM,
                    targetDuration: mode == 0 ? video.playbackDuration : viewModel.targetDuration,
                    elapsedTime: mode == 0 ? video.elapsedSeconds : viewModel.sessionDuration,
                    canEditSettings: !viewModel.isRunning,
                    onSettingsTapped: {
                        enterPlayAfterSettings = false
                        showSettings = true
                    },
                    metronomeCurrentBeat: viewModel.metronome.currentBeat,
                    metronomeTotalBeats: viewModel.metronome.beatsPerMeasure,
                    metronomeIsPlaying: viewModel.metronome.isPlaying,
                    onMetronomeToggle: { viewModel.metronome.toggle() }
                )
                .frame(height: geometry.size.height * 0.075)
                .padding(.horizontal)

                waterHalf(height: topHeight)
                    .frame(height: topHeight)

                // 平均力度 / 方向平衡进度条：独立一行放在水面下方。
                // 趋势和占比交给这里的进度条；计数类读数仍在右上角，两边不重复。
                metricStrip

                Group {
                    if mode == 0 { demoHalf } else { playHalf }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.vertical, 4)
        }
    }

    /// 上半：水面 + 左上得分 + 右上指标 + 底部实时提示。
    /// 指标和得分分居左右上角，中间整块留给水面波纹，版式与另外两个模块一致。
    private func waterHalf(height: CGFloat) -> some View {
        ZStack {
            WaterSurfaceView(waves: viewModel.waves, waterColor: viewModel.waterColor)

            // 扫弦瞬间的中心闪光：只做一次呼吸，不常驻。
            if viewModel.isSweeping {
                Circle()
                    .fill(
                        RadialGradient(colors: [Color.white.opacity(0.75),
                                                Color.white.opacity(0.25),
                                                Color.clear],
                                       center: .center, startRadius: 0, endRadius: 50)
                    )
                    .frame(width: 100, height: 100)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            VStack {
                HStack(alignment: .top) {
                    // 左上：得分，三个模块共用同一张卡，字号/材质完全一致。
                    ScoreBadge(score: viewModel.score)

                    Spacer()

                    // 右上只放计数类读数（总计 / 向上 / 向下）。力度、方向平衡已经由
                    // 下方的 metricStrip 进度条承载，这里不再重复一遍。
                    VStack(alignment: .trailing, spacing: 5) {
                        DataBadge(icon: "waveform",
                                  value: "\(viewModel.sweepCount)", unit: L("次"), color: WavePalette.deep)
                        DataBadge(icon: "arrow.up",
                                  value: "\(viewModel.upCount)", unit: L("向上"), color: WavePalette.lagoon)
                        DataBadge(icon: "arrow.down",
                                  value: "\(viewModel.downCount)", unit: L("向下"), color: WavePalette.spray)
                    }
                }
                .padding(10)

                Spacer()

                if !viewModel.statusMessage.isEmpty && !isShowingSummary {
                    HStack(spacing: 5) {
                        Image(systemName: "water.waves")
                            .font(.caption2)
                        Text(statusTipText)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    /// 动画下方的独立指标条：平均力度 / 方向平衡进度条。
    /// 右上角只放计数类读数（总计 / 向上 / 向下），占比交给这里的进度条。
    private var metricStrip: some View {
        VStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L("平均力度"))
                        .font(.caption2)
                    Spacer()
                    Text("\(Int(viewModel.averageStrength * 100))%")
                        .font(.caption2)
                        .foregroundStyle(strengthColor)
                }
                ProgressView(value: viewModel.averageStrength)
                    .tint(strengthColor)
                    .scaleEffect(y: 1.3)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L("方向平衡"))
                        .font(.caption2)
                    Spacer()
                    Text("\(Int(viewModel.directionBalance * 100))%")
                        .font(.caption2)
                        .foregroundStyle(balanceColor)
                }
                ProgressView(value: viewModel.directionBalance)
                    .tint(balanceColor)
                    .scaleEffect(y: 1.3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    /// 演示结束后的询问卡片：与另外两个模块同一套视觉，强调色换蓝青。
    private var tryPromptCard: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [WavePalette.deep, WavePalette.lagoon],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .shadow(color: WavePalette.deep.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text(L("轮到你来试试了"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(L("扫过四根弦，让水面荡开"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showTryPrompt = false
                    // 默认启动节拍器：只把开关置为开，不立即打拍；设置确认后才真正响。
                    viewModel.metronome.isEnabled = true
                    enterPlayAfterSettings = true
                    showSettings = true
                } label: {
                    Text(L("确认"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [WavePalette.deep, WavePalette.lagoon],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            .padding(.horizontal, 40)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var isShowingSummary: Bool {
        !viewModel.isRunning && viewModel.statusMessage.contains("\n")
    }

    /// 只在 play 模式弹报告。演示播完走的是"轮到你来试试"，两套弹框不打架。
    private var isShowingReport: Bool {
        mode == 1 && isShowingSummary
    }

    private var practiceReportCard: some View {
        PracticeReportCard(lines: PracticeReportCard.lines(from: viewModel.statusMessage),
                           accentStart: WavePalette.deep,
                           accentEnd: WavePalette.lagoon,
                           icon: "water.waves") {
            // 报告「确认」才解锁右滑返回：演奏刚结束、报告刚弹出时仍锁着，
            // 手指还在边缘划不会被判成返回上一级。
            swipeBackLocked = false
            dismiss()
        }
    }

    /// 底部单行反馈：去掉开头 emoji，只取第一行。
    private var statusTipText: String {
        let first = viewModel.statusMessage
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        var text = first
        for emoji in ["🌟 ", "👍 ", "👌 ", "💪 ", "🚀 ", "🎵 ", "🎉 "] {
            text = text.replacingOccurrences(of: emoji, with: "")
        }
        return text
    }

    // MARK: - Bottom halves

    /// 演示模式：视频占满，播放键压在右下角，速度进度条压在最底部。
    private var demoHalf: some View {
        ZStack(alignment: .bottom) {
            DemoVideoView(controller: video)

            if !video.loadFailed {
                VStack(spacing: 2) {
                    HStack {
                        Text("Tempo").font(.caption2).foregroundStyle(.white)
                        Text("\(Int(60 + 90 * video.progress)) BPM")
                            .font(.caption2).fontWeight(.bold).monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    ProgressView(value: video.progress)
                        .tint(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        // 没开播时整块画面都算"点这里"；播放中不接手势，避免讲解时误触暂停。
        .contentShape(Rectangle())
        .onTapGesture {
            guard !video.loadFailed, !video.isPlaying else { return }
            toggleDemoPlayback()
        }
        .overlay(alignment: .bottomTrailing) {
            playPauseButton
                .padding(.trailing, 16)
                .padding(.bottom, video.loadFailed ? 14 : 62)
        }
        .overlay(alignment: .center) {
            if !video.loadFailed, !video.isPlaying, !video.didFinish, video.elapsedSeconds < 0.05 {
                DemoPlayHint()
                    .padding(.bottom, 34)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: video.isPlaying)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
    }

    /// play 模式：真琴空弦段，一笔扫过四根弦就是一次扫弦。
    /// 没有"开始练习"按钮——第一次扫弦才触发计时，和另外两个模块一致。
    private var playHalf: some View {
        ZStack(alignment: .bottom) {
            PipaOpenStringsPad { string, direction in
                handlePadPluck(string, direction)
            }

            if viewModel.sweepCount == 0 {
                HStack(spacing: 5) {
                    Image(systemName: "hand.draw.fill")
                        .font(.caption2)
                    Text(L("一笔扫过四根弦"))
                        .font(.caption2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: viewModel.sweepCount == 0)
        .background(Color(red: 0.96, green: 0.94, blue: 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
    }

    private var playPauseButton: some View {
        Button {
            toggleDemoPlayback()
        } label: {
            Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: video.isPlaying ? 0 : 1.5)
                .frame(width: 50, height: 50)
                .background(Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(video.isPlaying ? "Pause demo" : "Play demo"))
    }

    // MARK: - Computed

    private var strengthColor: Color {
        if viewModel.averageStrength > 0.7 { return .green }
        if viewModel.averageStrength > 0.4 { return .orange }
        return .red
    }

    private var balanceColor: Color {
        if viewModel.directionBalance > 0.4 { return .green }
        if viewModel.directionBalance > 0.2 { return .orange }
        return .red
    }

    // MARK: - Actions

    private func toggleDemoPlayback() {
        if video.isPlaying {
            video.pause()
            viewModel.pauseDemo()
        } else {
            if video.didFinish { viewModel.prepareDemoSession() }
            video.play()
            viewModel.resumeDemo()
        }
    }

    /// 虚拟琴划过一根弦：先出声，再把这一笔攒起来。
    /// 一笔跨满四根才算一次扫弦，方向和力度都从这一笔本身推出来——
    /// 往右划是「扫」（向下），往左划是「拂」（向上）。
    private func handlePadPluck(_ string: Int, _ direction: String) {
        synth.play(string: string, velocity: 0.7)

        let now = Date()
        if let started = strokeStartedAt, now.timeIntervalSince(started) > 0.8 {
            // 停顿太久，上一笔已经结束，重新起算。
            strokeStrings.removeAll()
            strokeStartedAt = nil
        }
        if strokeStrings.isEmpty {
            strokeStartedAt = now
            strokeDirection = direction
        }
        if !strokeStrings.contains(string) {
            strokeStrings.append(string)
        }

        guard strokeStrings.count >= 4, let started = strokeStartedAt else { return }

        // 扫得越快力度越大：一笔 0.15 秒扫完算重，拖到 0.6 秒以上算轻。
        let duration = max(now.timeIntervalSince(started), 0.05)
        let strength = min(max(1.15 - duration * 1.1, 0.3), 1.0)
        let isUp = strokeDirection == "弹"

        strokeStrings.removeAll()
        strokeStartedAt = nil

        viewModel.manualSweep(isUp: isUp, strength: strength)
    }

    /// 切换模式：0=演示（脚本事件源 + 视频），1=扫弦（无麦克风，靠虚拟琴驱动）。
    private func applyMode(_ new: Int) {
        mode = new
        showTryPrompt = false
        viewModel.stopPractice()
        if new == 0 {
            viewModel.metronome.stop()
            video.prepare()
            viewModel.prepareDemoSession()
        } else {
            video.stop()
            synth.stop()
            // 预热音频引擎，第一次划弦立刻出声。
            synth.prepare()
            viewModel.prepareManualSession()
            if viewModel.metronomeIsEnabled {
                viewModel.metronome.start()
            }
        }
    }
}

// MARK: - Water Surface View
struct WaterSurfaceView: View {
    let waves: [WaveRipple]
    let waterColor: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            Canvas { context, size in
                // 水面背景
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            waterColor.opacity(0.3),
                            waterColor.opacity(0.6)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                for wave in waves {
                    drawWave(wave, in: context, size: size)
                }
            }
        }
    }

    private func drawWave(_ wave: WaveRipple, in context: GraphicsContext, size: CGSize) {
        let centerX = wave.center.x * size.width
        let centerY = wave.center.y * size.height
        let center = CGPoint(x: centerX, y: centerY)

        let progress = wave.progress
        let opacity = wave.opacity

        let currentRadius = wave.maxRadius * min(size.width, size.height) * CGFloat(progress)

        // 三个同心圆环错开一点，波纹看起来才像水面，不像描边圆
        for i in 0..<3 {
            let delay = Double(i) * 0.15
            let adjustedProgress = max(0, progress - delay)

            guard adjustedProgress > 0 else { continue }

            let adjustedRadius = currentRadius * CGFloat(adjustedProgress / progress)
            let adjustedOpacity = opacity * (1.0 - Double(i) * 0.2)

            let path = Path { p in
                p.addEllipse(in: CGRect(
                    x: center.x - adjustedRadius,
                    y: center.y - adjustedRadius,
                    width: adjustedRadius * 2,
                    height: adjustedRadius * 2
                ))
            }

            context.stroke(
                path,
                with: .color(wave.color.opacity(adjustedOpacity)),
                lineWidth: 3 - CGFloat(i) * 0.5
            )
        }
    }
}

#Preview {
    NavigationStack {
        WavePracticeView()
    }
}

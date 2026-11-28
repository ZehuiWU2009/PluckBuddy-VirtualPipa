//
//  FlowerPracticeView.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/7/15.
//

import SwiftUI

/// 轮指花开。版式与「弹挑跑步」完全对齐：顶部一行控制栏、上半动画面板、
/// 中间指标条、下半演示视频或琴身；看完演示 → 设置 → 自己弹，练完出报告弹框。
/// 只有配色保留粉紫——两个模块是一套界面语言的两个性格，不是两张皮。
struct FlowerPracticeView: View {
    @StateObject private var viewModel = FlowerViewModel()
    @StateObject private var synth = DemoPluckSynth()
    @StateObject private var video = DemoVideoController()
    @Environment(\.dismiss) private var dismiss

    /// 演示 / 弹拨两种体验。进模块先停在演示，播完弹框询问，不再有手动切换。
    @State private var mode: Int = 0
    /// 演示播完后是否弹出"要不要亲自试试"确认框。
    @State private var showTryPrompt = false
    /// 设置弹窗：目标速度 / 时长 / 节拍器开关与音色。
    @State private var showSettings = false
    /// 设置确认后是否进入弹拨模式。看完演示点「确认」→ 先出设置页，确认后才切到 play。
    @State private var enterPlayAfterSettings = false
    /// 演奏页的右滑返回一直锁着，连演奏完弹出的报告页也锁；报告点「确认」才解锁。
    @State private var swipeBackLocked = true

    var body: some View {
        ZStack {
            // 整体底色：淡粉 → 粉紫 → 淡紫，和「弹挑跑步」的蓝绿是同一套亮度关系，
            // 只是色相换了，两块页面并排看不会像两个 App。
            LinearGradient(colors: [
                Color(red: 0.99, green: 0.87, blue: 0.91),
                Color(red: 0.98, green: 0.86, blue: 0.93),
                Color(red: 0.95, green: 0.88, blue: 0.96)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // 演奏页禁用系统右滑返回：轮指横向划弦不被当成"返回上一级"。
            // 报告页也继续锁着，只有报告「确认」点了才解锁。
            SwipeBackDisabler(isLocked: $swipeBackLocked)
                .frame(width: 0, height: 0)

            content

            if showTryPrompt { tryPromptCard }

            // play 到点的练习报告：盖住整页，点「确认」回主菜单。
            if isShowingReport { practiceReportCard }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showTryPrompt)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isShowingReport)
        .navigationTitle(L("轮指花开"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings, onDismiss: {
            // 从「看完演示 → 确认」进设置，用户却点了取消：回到询问卡片，别停在演示结束画面。
            if enterPlayAfterSettings {
                enterPlayAfterSettings = false
                showTryPrompt = true
            }
        }) {
            FlowerSettingsSheet(
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
                        // 从演示确认进来：设置落定后切到弹拨模式。
                        enterPlayAfterSettings = false
                        applyMode(1)
                    } else {
                        // 从顶部齿轮进来：只刷新当前练习。
                        viewModel.refreshManualSession()
                    }
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // 与「弹挑跑步」同一个节拍器开关：响着是绿色实心，停了是灰色线框。
                // 颜色跟 isPlaying（真正在打拍）走，不跟 isEnabled（设置里是否启用）走——
                // 两者会分叉：顶部播放键或计时到点都会停拍，但 isEnabled 未必跟着变，
                // 按 isEnabled 上色就会出现「已经没声音了图标还是绿的」。
                // 点一下的含义也随之明确成「现在响 / 现在停」：
                // 没响就置 true（顺带 start），响着就置 false（顺带 stop），不会点了没反应。
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
            // 声音和花朵共用同一个事件源，节奏严格同步。
            viewModel.onPluckSound = { [weak synth] string, velocity in
                synth?.play(string: string, velocity: velocity)
            }
            // 进模块只"就绪"：视频停在第 0 帧，花还没开，等用户点播放。
            viewModel.prepareDemoSession()
            video.prepare()
            // 节拍器进页面不自动响：只同步速度，要打拍由用户在顶部或设置里开。
            viewModel.metronome.bpm = Int(viewModel.targetBPM)
        }
        .onDisappear {
            video.stop()
            viewModel.stopPractice()
            viewModel.metronome.stop()
            synth.stop()
        }
        // 视频一播完就停脚本事件源，否则画面定住后花还会继续长、声音还会继续响。
        .onChange(of: video.didFinish) { _, finished in
            if finished {
                viewModel.stopPractice()
                // 演示结束：节拍器立即停（声音 + 拍点），不留它在播完后继续响。
                viewModel.metronome.stop()
            }
        }
        .onChange(of: video.promptReady) { _, ready in
            if ready { showTryPrompt = true }
        }
    }

    /// 主内容：顶部控制栏 + 上半动画 + 指标条 + 下半（视频 / 琴身）。
    /// 比例和「弹挑跑步」同一套，切模式时上下两块尺寸不变，只有下半的内容换掉。
    private var content: some View {
        GeometryReader { geometry in
            let topHeight = geometry.size.height * 0.34
            VStack(spacing: 10) {
                // 齿轮 / 目标速度 / 节拍器（拍点 + 播放键）/ 剩余时间，全在一行。
                TopControlBar(
                    targetBPM: viewModel.targetBPM,
                    // 演示模式剩余时间跟视频进度走（总长=视频时长）；弹拨模式用练习设定。
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

                flowerHalf(height: topHeight)
                    .frame(height: topHeight)

                // 速度 / 均值 / 均匀度进度条：独立一行放在动画面板下方。
                // 它不压在花朵上，只是把趋势读数和进度呈现出来；计数类读数仍在右上角。
                metricStrip

                // 下半吃掉剩余高度：视频和琴身都尽量大，手指才有落点。
                Group {
                    if mode == 0 { demoHalf } else { playHalf }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.vertical, 4)
        }
    }

    /// 上半：花朵动画 + 左上得分 + 右上指标 + 底部实时提示。
    /// 指标和得分分居左右上角，中间整块留给花——原来居中的三栏卡和动画下方那条
    /// 都会压到花瓣，现在两处都撤掉，版式和「弹挑跑步」完全一致。
    private func flowerHalf(height: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [Color.pink.opacity(0.30), Color.purple.opacity(0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            FlowerView(
                growth: viewModel.flowerGrowth,
                petalCount: viewModel.petalCount,
                brightness: viewModel.flowerBrightness,
                symmetry: viewModel.flowerSymmetry,
                isRolling: viewModel.isRolling,
                pulseCounter: viewModel.pulseCounter,
                isStageResting: viewModel.isStageResting,
                bloomFlash: viewModel.bloomFlashCounter,
                layers: viewModel.flowerLayers,
                isSpeedTargetMet: viewModel.isSpeedTargetMet,
                vibrancy: viewModel.flowerVibrancy,
                petalCloseCount: viewModel.petalCloseCount
            )
            .frame(width: 200, height: 200)
            // 顶部不再有统计卡，花朵回到面板正中、适度放大，中间一整块都是动画。
            .scaleEffect(min(height / 235, 1.2))
            .animation(.easeOut(duration: 0.25), value: height)

            VStack {
                HStack(alignment: .top) {
                    // 左上：得分，三个模块共用同一张卡，字号/材质完全一致。
                    ScoreBadge(score: viewModel.score)

                    Spacer()

                    // 右上只放计数类读数（轮指 / 序列）。速度、均值、均匀度已经由
                    // 下方的 metricStrip 承载，这里不再重复一遍——同一个数字出现两次，
                    // 既占地方又让人分不清哪个才是当前值。
                    VStack(alignment: .trailing, spacing: 5) {
                        DataBadge(icon: "hand.tap.fill",
                                  value: "\(viewModel.rollCount)", unit: L("次"), color: .pink)
                        DataBadge(icon: "rectangle.3.group",
                                  value: "\(viewModel.sequenceCount)", unit: L("序列"), color: .purple)
                    }
                }
                .padding(10)

                Spacer()

                // 底部提示语：音符 + 实时反馈，和「弹挑跑步」同一个位置、同一种材质。
                if !viewModel.statusMessage.isEmpty && !isShowingSummary {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note")
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

    /// 动画下方的独立指标条：速度 / 均值 / 均匀度进度条。
    /// 右上角只放计数类读数（轮指、序列），趋势和占比交给这里的进度条，两边不重复。
    private var metricStrip: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: L("速度: %.1f 次/秒"), viewModel.currentSpeed))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(String(format: L("均值: %.1f"), viewModel.averageSpeed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "waveform.path")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L("均匀度"))
                        .font(.caption2)
                    Spacer()
                    Text("\(Int(viewModel.uniformity * 100))%")
                        .font(.caption2)
                        .foregroundStyle(uniformityColor)
                }
                ProgressView(value: viewModel.uniformity)
                    .tint(uniformityColor)
                    .scaleEffect(y: 1.3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    /// 演示结束后的询问卡片：与「弹挑跑步」同一套视觉，只有强调色换粉紫。
    private var tryPromptCard: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.pink, .purple],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .shadow(color: .pink.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text(L("轮到你来试试了"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(L("在四根弦上轮指，让花开满吧"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showTryPrompt = false
                    // 默认启动节拍器：只把开关置为开，不立即打拍；设置页确认后才真正响。
                    // 直接写 isEnabled 而非 metronomeIsEnabled，是为了避开 setter 里的 start()。
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
                            LinearGradient(colors: [.pink, .purple],
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

    /// 练习结束的总结是 generateSummary() 产出的带换行文本，用它判定"总结态"。
    private var isShowingSummary: Bool {
        !viewModel.isRunning && viewModel.statusMessage.contains("\n")
    }

    /// 只在弹拨模式下弹报告。演示播完走的是"轮到你来试试"，两套弹框不能同时出现。
    private var isShowingReport: Bool {
        mode == 1 && isShowingSummary
    }

    /// play 模式到点的练习报告弹框，与「弹挑跑步」共用一个组件，强调色换成粉紫。
    private var practiceReportCard: some View {
        PracticeReportCard(lines: PracticeReportCard.lines(from: viewModel.statusMessage),
                           accentStart: .pink,
                           accentEnd: .purple,
                           icon: "camera.macro") {
            // 报告「确认」才解锁右滑返回：演奏刚结束、报告刚弹出时仍锁着，
            // 手指还在边缘划不会被判成返回上一级。
            swipeBackLocked = false
            dismiss()
        }
    }

    /// 底部单行反馈：去掉开头 emoji，只取第一行（均匀度的补充说明放在弹框里看）。
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

    /// 演示模式：演奏视频尽量占满，播放键压在右下角，速度进度条压在最底部。
    private var demoHalf: some View {
        ZStack(alignment: .bottom) {
            DemoVideoView(controller: video)

            // 进度条只在真正播视频时显示；视频缺失占位时不叠在文字上。
            if !video.loadFailed {
                VStack(spacing: 2) {
                    HStack {
                        Text("Tempo").font(.caption2).foregroundStyle(.white)
                        Text("\(Int(60 + 120 * video.progress)) BPM")
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
        // 没开播时整块画面都算"点这里"：提示动画指向哪就点到哪。
        // 播放中不接手势，避免讲解时误触暂停。
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
        // 还没开始看时的单击提示，与「弹挑跑步」共用同一个动画。
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

    /// 弹拨模式：真实琴身的空弦段，连续拨四根弦就是轮指。
    /// 没有"开始练习"按钮——第一次拨弦才触发计时，与「弹挑跑步」一致。
    private var playHalf: some View {
        ZStack(alignment: .bottom) {
            PipaOpenStringsPad { string, _ in
                viewModel.pluckString(string)
            }

            if viewModel.rollCount == 0 {
                // 浮层不吃触摸：手指落在提示条上照样拨到下面那根弦。
                HStack(spacing: 5) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.caption2)
                    Text(L("在四根弦上连续轮指"))
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
        .animation(.easeOut(duration: 0.3), value: viewModel.rollCount == 0)
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

    private var uniformityColor: Color {
        if viewModel.uniformity > 0.8 { return .green }
        if viewModel.uniformity > 0.5 { return .orange }
        return .red
    }

    // MARK: - Actions

    /// 演示的播放/暂停。视频和花朵必须同进同停，否则画面停了花还在长。
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

    /// 切换模式：0=演示（脚本加速 + 视频），1=弹拨（无麦克风，靠虚拟琴拨弦驱动）。
    private func applyMode(_ new: Int) {
        mode = new
        showTryPrompt = false
        viewModel.stopPractice()
        if new == 0 {
            // 切回演示：停节拍器，只做准备、不自动播，视频停在第 0 帧。
            viewModel.metronome.stop()
            video.prepare()
            viewModel.prepareDemoSession()
        } else {
            // 切到弹拨：停视频、停合成音，清空上一轮演示的统计。
            video.stop()
            synth.stop()
            // 提前预热拨弦引擎，让第一次点弦立刻出声，不冷启动。
            synth.prepare()
            viewModel.prepareManualSession()
            // 进入弹拨：节拍器按开关状态启动（看完演示进来时设置页默认已开启）。
            if viewModel.metronomeIsEnabled {
                viewModel.metronome.start()
            }
        }
    }
}

// MARK: - Flower View

struct FlowerView: View {
    let growth: Double // 0-1
    let petalCount: Int
    let brightness: Double // 0-1
    let symmetry: Double // 0-1
    let isRolling: Bool // 是否正在轮指
    let pulseCounter: Int // ✨ 新增：脉冲计数器参数
    let isStageResting: Bool // 是否处于「长一圈→停顿」的台阶停顿
    let bloomFlash: Int // 优秀序列触发的彩色光晕计数
    let layers: Int // 花层数（连续优秀累积的重瓣，1~3）
    let isSpeedTargetMet: Bool // 速度是否达到目标 BPM（达标花心泛起与表现同色的光晕）
    let vibrancy: Double // 花朵鲜艳度 0-1：越优秀花色越鲜艳
    let petalCloseCount: Int // 满花后已收拢的花瓣数（依次收拢用）

    @State private var rotationAngle: Double = 0
    @State private var breathScale: Double = 1.0 // 停顿期间的呼吸缩放
    @State private var restRingScale: Double = 0.85 // 停顿光环的呼吸
    @State private var restRingOpacity: Double = 0.0
    @State private var flashScale: Double = 0.6 // 光晕扩散半径
    @State private var flashOpacity: Double = 0.0 // 光晕不透明度

    var body: some View {
        ZStack {
            // 背景圆圈
            Circle()
                .fill(Color.green.opacity(0.1))

            // 花瓣：支持多层重瓣，满花后按 petalCloseCount 从最后一片起依次收拢
            ForEach(0..<8, id: \.self) { index in
                if index < petalCount {
                    let isClosed = index >= petalCount - petalCloseCount
                    // 花瓣整体尺寸与花心同步由 growth 驱动（保证同步长大、比例协调）。
                    // 均匀度 symmetry 只做 0.8~1.0 的轻微饱满度微调，不再压缩整体大小，
                    // 否则 growth 虽在增大、花瓣却被 symmetry(<1) 压小，花心大花瓣小的比例失调。
                    let petalScale = growth * (0.8 + 0.2 * symmetry)
                    ForEach(0..<layers, id: \.self) { layer in
                        Petal(
                            rotation: Double(index) * 45 + layerAngleOffset(layer),
                            scale: petalScale * layerScale(layer) * (isClosed ? 0.15 : 1.0),
                            colorTop: petalColorTop,
                            colorBottom: petalColorBottom,
                            pulseCounter: pulseCounter, // ✨ 传递脉冲计数器
                            opacity: isClosed ? 0.0 : 1.0
                        )
                        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: growth)
                        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: petalCount)
                        .animation(.easeInOut(duration: 0.24), value: petalCloseCount)
                    }
                }
            }

            // 花心
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.92), petalColorTop, petalColorBottom],
                        center: .center,
                        startRadius: 0,
                        endRadius: 30
                    )
                )
                .frame(width: 60, height: 60)
                .opacity(growth > 0 ? 1 : 0)
                .scaleEffect(growth)
                .scaleEffect(isRolling ? 1.1 : 1.0) // 轮指时轻微放大
                // 速度达标或表现优秀：花心泛起与表现同色的光晕，越鲜艳光晕越强，不再用金色
                .shadow(color: petalColorTop.opacity(0.35 + 0.55 * vibrancy + (isSpeedTargetMet ? 0.1 : 0)),
                        radius: 10 + 12 * vibrancy)
                .animation(.spring(response: 0.5), value: growth)
                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isRolling)
                .animation(.easeInOut(duration: 0.3), value: isSpeedTargetMet)

            // 台阶停顿的「蓄力光环」：停顿期间从花心缓慢外扩呼吸，
            // 让停顿本身有动作可看，而不是一片死寂的静止
            Circle()
                .stroke(Color.orange.opacity(0.6), lineWidth: 2.5)
                .frame(width: 150, height: 150)
                .scaleEffect(restRingScale)
                .opacity(restRingOpacity)
                .allowsHitTesting(false)

            // 优秀序列的彩色光晕：从花心向外扩散一圈再淡出，颜色随表现更鲜艳
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [Color.pink, Color.purple, Color.cyan, Color.pink],
                        center: .center
                    ),
                    lineWidth: 4
                )
                .frame(width: 120, height: 120)
                .scaleEffect(flashScale)
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
        .scaleEffect(breathScale)
        .rotationEffect(.degrees(rotationAngle))
        .onChange(of: pulseCounter) { oldValue, newValue in
            // ✨ 监听脉冲计数器变化，触发旋转动画
            if newValue > oldValue {
                withAnimation(.easeOut(duration: 0.3)) {
                    rotationAngle += 45 // 每次旋转45度（一个花瓣的角度）
                }
            }
        }
        .onChange(of: isStageResting) { _, resting in
            // 台阶停顿期间花朵明显「呼吸」（幅度 12%），并伴一圈外扩光环，
            // 让停顿看得见：花在蓄力，而不是卡住了。
            if resting {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    breathScale = 1.12
                    restRingScale = 1.3
                    restRingOpacity = 0.55
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    breathScale = 1.0
                    restRingScale = 0.85
                    restRingOpacity = 0.0
                }
            }
        }
        .onChange(of: bloomFlash) { oldValue, newValue in
            guard newValue > oldValue else { return }
            flashScale = 0.7
            flashOpacity = 0.55 + 0.4 * vibrancy
            withAnimation(.easeOut(duration: 0.7)) {
                flashScale = 1.8
                flashOpacity = 0.0
            }
        }
    }

    /// 重瓣每层的旋转错开角度，避免层与层完全重叠
    private func layerAngleOffset(_ layer: Int) -> Double {
        switch layer {
        case 0: return 0
        case 1: return 22.5
        default: return 11.25
        }
    }

    /// 重瓣每层的尺寸递减，外层大、内层小，形成层叠感
    private func layerScale(_ layer: Int) -> Double {
        switch layer {
        case 0: return 1.0
        case 1: return 0.72
        default: return 0.5
        }
    }

    /// 花瓣渐变的上端颜色：鲜艳度越高，色相越往鲜艳的玫红/品红偏移、饱和度越高、亮度越足。
    private var petalColorTop: Color {
        // 色相：低鲜艳度偏冷淡蓝紫（~0.72），高鲜艳度偏鲜艳玫红/橙红（~0.95）；
        // 均匀度做轻微微调，保留「弹得稳→色相偏移」的语义。
        let hue = 0.72 + 0.23 * vibrancy + 0.04 * symmetry
        // 饱和度：越优秀越鲜艳（0.35 发灰 → 1.0 极艳）
        let saturation = 0.35 + 0.65 * vibrancy
        let lightness = min(1.0, 0.55 + 0.2 * brightness + 0.12 * vibrancy)
        return Color(hue: hue, saturation: saturation, brightness: lightness)
    }

    /// 花瓣渐变的下端颜色：与上端同一色系、略深略淡，形成柔和的渐变质感（不再是金色）。
    private var petalColorBottom: Color {
        let hue = 0.72 + 0.23 * vibrancy + 0.04 * symmetry + 0.02
        let saturation = max(0.2, (0.35 + 0.65 * vibrancy) * 0.78)
        let lightness = max(0.2, 0.40 + 0.18 * brightness + 0.1 * vibrancy)
        return Color(hue: hue, saturation: saturation, brightness: lightness)
    }
}

// MARK: - Petal Shape
struct Petal: View {
    let rotation: Double
    let scale: Double
    let colorTop: Color
    let colorBottom: Color
    let pulseCounter: Int // ✨ 改用计数器而非布尔值
    let opacity: Double // 收拢时淡出（满花后花瓣依次收拢用）
    
    @State private var pulseScale: Double = 1.0
    
    var body: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [colorTop, colorBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 50, height: 100)
            .offset(y: -60)
            .scaleEffect(pulseScale)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .opacity(opacity)
            .animation(.easeInOut(duration: 0.35), value: colorTop) // 鲜艳度变化时花色平滑过渡
            .onChange(of: pulseCounter) { oldValue, newValue in
                // ✨ 修复：每次计数器变化时触发新的脉冲
                guard newValue > oldValue else { return }
                
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                    pulseScale = 1.2
                }
                
                // 恢复原状
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
                    await MainActor.run {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            pulseScale = 1.0
                        }
                    }
                }
            }
    }
}

#Preview {
    NavigationStack {
        FlowerPracticeView()
    }
}


//
//  RunningPracticeView.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/7/15.
//

import SwiftUI
import Lottie  // Lottie 动画支持

struct RunningPracticeView: View {
    @StateObject private var viewModel = RunningViewModel()
    @StateObject private var synth = DemoPluckSynth()
    @StateObject private var video = DemoVideoController()
    @Environment(\.dismiss) private var dismiss

    /// 演示 / 弹挑 两种体验。进模块先播演示，播完弹框询问；也可手动点 Picker 切换。
    @State private var mode: Int = 0
    /// 演示播完后是否弹出"要不要亲自试试"确认框。
    @State private var showTryPrompt = false

    var body: some View {
        ZStack {
            content

            // 演示播完的询问卡片：自定义样式，和整体 UI 一致。
            if showTryPrompt {
                tryPromptCard
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showTryPrompt)
        .navigationTitle(L("弹挑跑步"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 声音和小人共用同一个事件源，节奏严格同步。
            viewModel.onPluckSound = { [weak synth] string, velocity in
                synth?.play(string: string, velocity: velocity)
            }
            // 进模块只"就绪"：视频停在第 0 帧，小人站着，等评委点播放。
            viewModel.prepareDemoSession()
            video.prepare()
        }
        .onDisappear {
            video.stop()
            viewModel.stopPractice()
            synth.stop()
        }
        // 视频一播完就停脚本事件源，否则小人定格后拨弦声还会继续响。
        .onChange(of: video.didFinish) { _, finished in
            if finished { viewModel.stopPractice() }
        }
        // 视频定格一会儿（DemoVideoController 里控制时长）才弹询问卡片，不直接切模式。
        .onChange(of: video.promptReady) { _, ready in
            if ready { showTryPrompt = true }
        }
    }

    /// 主内容：上半跑步动画 + 指标，下半演示视频或四弦交互区。
    ///
    /// 两种模式共用同一套比例：上半固定 32%，剩下的高度全部给下半。
    /// 之前演示 32%、弹挑 42%，切模式时动画面板会长高、小人和跑道一起挪位置，
    /// 看着像换了一页；现在上下两块都不随模式变，切换时只有下半的内容换掉。
    private var content: some View {
        GeometryReader { geometry in
            let topHeight = geometry.size.height * 0.32
            VStack(spacing: 10) {
                // 模式切换。用显式 Binding 的 setter 统一处理切换，
                // 不再依赖 onChange(of: mode)，避免从 Play along 切回 Watch demo 时
                // 因状态回环（视频 stop 触发 didFinish 变化）导致 Picker 不响应。
                Picker("Mode", selection: Binding(
                    get: { mode },
                    set: { new in applyMode(new) }
                )) {
                    Text("Watch demo").tag(0)
                    Text("Play along").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // 上半：跑步动画 + 指标。高度固定，两种模式一模一样。
                runningHalf(height: topHeight)
                    .frame(height: topHeight)

                // 下半吃掉剩余高度：视频和琴身都尽量大，手指才有落点。
                Group {
                    if mode == 0 {
                        demoHalf
                    } else {
                        playHalf
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.vertical, 4)
        }
    }

    /// 演示结束后的询问卡片。用自定义卡片替代系统 alert：
    /// 圆角 + 材质底 + 渐变主按钮，和页面里的徽章、弦区保持同一套视觉语言。
    private var tryPromptCard: some View {
        ZStack {
            // 遮罩：同时挡住背后页面的触摸，避免卡片弹着还能点到别处。
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.orange, .pink],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .shadow(color: .orange.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text("Want to try it yourself?")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Pluck the strings to make the runner go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    applyMode(1)
                } label: {
                    Text("Yes, let me play")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [.blue, .cyan],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                Button {
                    dismiss()
                } label: {
                    Text("No, go back")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
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

    /// 上半：跑步动画 + 指标。指标沿用旧版布局：左上得分，右上 BPM / 稳定性 / 计时。
    ///
    /// 小人尺寸跟着面板高度算，不写死：Lottie 画布 1080×1080，人只占中间 597×700 那一块，
    /// 所以画布要给到面板高度的 1.1 倍才显得饱满。画布多出来的一圈是纯留白，
    /// 用 .frame 把布局尺寸收回面板大小（否则 ZStack 会被画布撑大、渐变压到上下相邻区域），
    /// 超出的部分交给外层圆角裁掉，人本身正好完整落在面板里。
    private func runningHalf(height: CGFloat) -> some View {
        return ZStack {
            LinearGradient(colors: [.cyan.opacity(0.25), .blue.opacity(0.2)],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            MovingTrackView(speed: viewModel.currentBPM, isActive: viewModel.isRunnerActive)

            // 演示模式连续循环；弹挑模式"弹一下迈一步"，靠 runStepToken 触发半圈。
            LottieRunnerView(isActive: viewModel.isRunnerActive,
                             rhythm: mode == 0 ? .loop : .step(viewModel.runStepToken),
                             currentBPM: viewModel.currentBPM,
                             stepSeconds: viewModel.stepSeconds,
                             displaySize: height * 1.1)
                .frame(width: height, height: height)

            VStack {
                HStack(alignment: .top) {
                    // 左上：得分（比旧版略小，给动画让位）
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.subheadline)
                            .foregroundStyle(.yellow)
                        Text("\(viewModel.score)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Spacer()

                    // 右上：速度 / 稳定性 / 计时
                    VStack(alignment: .trailing, spacing: 5) {
                        DataBadge(icon: "speedometer",
                                  value: bpmText,
                                  unit: bpmUnit, color: .blue)
                        DataBadge(icon: "waveform",
                                  value: stabilityText,
                                  unit: stabilityUnit, color: stabilityColor)
                        DataBadge(icon: "timer",
                                  value: formatDuration(viewModel.sessionDuration),
                                  unit: "", color: .orange)
                    }
                }
                .padding(10)
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var stabilityColor: Color {
        if viewModel.stability > 0.8 { return .green }
        if viewModel.stability > 0.5 { return .orange }
        return .red
    }

    // 弹挑模式要攒够拨弦次数才有节奏可言，没到就显示"—"，不拿默认值充数。
    private var bpmText: String {
        viewModel.currentBPM > 0 ? "\(Int(viewModel.currentBPM))" : "—"
    }

    private var bpmUnit: String {
        viewModel.currentBPM > 0 ? "BPM" : ""
    }

    private var stabilityText: String {
        viewModel.stability > 0 ? "\(Int(viewModel.stability * 100))" : "—"
    }

    private var stabilityUnit: String {
        viewModel.stability > 0 ? "%" : ""
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }

    /// 下半-演示模式：演奏视频尽量占满（给手留出空间），
    /// 播放/暂停按钮压在右下、不挡演奏画面，节奏进度条压到最底部一行。
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
        // 播放/暂停：压在进度条上方，点到就同时控制视频和小人。
        .overlay(alignment: .bottomTrailing) {
            playPauseButton
                .padding(.trailing, 16)
                .padding(.bottom, video.loadFailed ? 14 : 62)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
    }

    /// 演示的播放/暂停按钮。图标读 video.isPlaying，视频和小人的状态只有这一个来源。
    private var playPauseButton: some View {
        Button {
            toggleDemoPlayback()
        } label: {
            Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                // 播放三角视觉重心偏左，只在字形上补一点右移，圆形本身不跟着挪。
                .offset(x: video.isPlaying ? 0 : 1.5)
                .frame(width: 50, height: 50)
                .background(Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(video.isPlaying ? "Pause demo" : "Play demo"))
    }

    /// 下半-弹挑模式：真实琴身的空弦段，四根竖弦，按上去就发声、小人迈一步。
    ///
    /// 提示语做成底部浮层，和演示模式的节奏条同一位置、同一材质：既不再占掉一行高度
    /// （琴身能铺满整块），也让两种模式下半区的边框与浮层位置一致。
    /// 拨过第一下就淡出——手指已经知道该往哪落了，再压着复手反而是干扰。
    private var playHalf: some View {
        ZStack(alignment: .bottom) {
            PipaOpenStringsPad(
                onPluck: { string, direction in
                    viewModel.pluckString(string, direction: direction)
                }
            )

            if viewModel.pluckCount == 0 {
                // 浮层不吃触摸：手指落在提示条上照样拨到下面那根弦。
                HStack(spacing: 5) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.caption2)
                    Text("Pluck the four open strings")
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
        .animation(.easeOut(duration: 0.3), value: viewModel.pluckCount == 0)
        .background(Color(red: 0.96, green: 0.94, blue: 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
    }

    // MARK: - Actions
    /// 演示的播放/暂停。视频和跑步动画必须同进同停：
    /// 只停视频会出现"画面定住了，小人还在跑"的割裂感。
    private func toggleDemoPlayback() {
        if video.isPlaying {
            video.pause()
            viewModel.pauseDemo()
        } else {
            // 播完之后再点播放 = 从头再看一遍，统计跟着归零。
            if video.didFinish { viewModel.prepareDemoSession() }
            video.play()
            viewModel.resumeDemo()
        }
    }

    /// 切换模式：0=演示（脚本加速 + 视频），1=弹挑（无麦克风，全靠评委拨弦驱动）。
    /// 两条路径都不请求麦克风；切走演示时务必停视频，避免声音残留。
    private func applyMode(_ new: Int) {
        // 显式落定 mode：Picker 的 Binding setter 与弹框按钮都走这里，
        // 保证选中态和状态机永远一致。
        mode = new
        showTryPrompt = false
        viewModel.stopPractice()
        if new == 0 {
            // 切回演示：只做准备，不自动播。视频停在第 0 帧，等评委点播放，
            // 否则刚切过去画面就自己动起来，也没法停在某一帧讲解。
            video.prepare()
            viewModel.prepareDemoSession()
        } else {
            // 切到弹挑：停视频、停合成音，清空上一轮演示的统计（四项指标归零），
            // 之后等评委第一次拨弦才开始计时、才驱动小人。
            video.stop()
            synth.stop()
            // 提前预热拨弦引擎，让评委第一次点弦立刻出声，不冷启动。
            synth.prepare()
            viewModel.prepareManualSession()
        }
    }
}

// MARK: - Top Control Bar（顶部控制栏 - 简化版）
struct TopControlBar: View {
    let targetBPM: Double  // 改为只读
    let targetDuration: TimeInterval
    let elapsedTime: TimeInterval
    let canEditSettings: Bool  // 是否可以编辑设置
    let onSettingsTapped: () -> Void  // 设置按钮回调
    
    // 计算剩余时间
    private var remainingTime: TimeInterval {
        max(0, targetDuration - elapsedTime)
    }
    
    // 格式化时间显示
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // 设置按钮（仅在未开始时显示）
            if canEditSettings {
                Button(action: onSettingsTapped) {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            
            // BPM 目标显示（只读，无调整按钮）
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .foregroundStyle(.orange)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                        Text(L("目标速度"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    
                    HStack(spacing: 4) {
                        Text("\(Int(targetBPM))")
                            .font(.title3)
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .frame(minWidth: 50, alignment: .center)
                        
                        Text("BPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 剩余时间显示
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(.blue)
                    .font(.title3)
                
                VStack(alignment: .center, spacing: 2) {
                    Text(L("剩余时间"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatTime(remainingTime))
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(remainingTime < 30 ? .red : .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Compact Running Scene View（紧凑版跑步场景）
struct CompactRunningSceneView: View {
    let score: Int  // 新增：得分
    let trackOffset: Double
    let runningSpeed: Double
    let isRunning: Bool
    let isPlucking: Bool  // 新增：弹奏状态（控制动画）
    let currentBPM: Double
    let stability: Double
    let sessionDuration: TimeInterval
    let statusMessage: String
    
    @State private var animationPhase: Double = 0
    @State private var trackScrollOffset: CGFloat = 0
    
    private var animationDuration: Double {
        guard currentBPM > 0 else { return 1.0 }
        return 60.0 / currentBPM
    }
    
    private var stabilityColor: Color {
        if stability > 0.8 {
            return .green
        } else if stability > 0.5 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景渐变
                LinearGradient(
                    colors: [Color.cyan.opacity(0.3), Color.blue.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                
                // 移动的跑道
                MovingTrackView(
                    speed: currentBPM, // 直接使用 BPM
                    isActive: isPlucking  // 使用弹奏状态控制动画
                )
                
                // Lottie 跑步小人
                LottieRunnerView(
                    isActive: isPlucking,  // 使用弹奏状态控制动画
                    rhythm: .loop,
                    currentBPM: currentBPM
                )
                .position(
                    x: geometry.size.width * 0.4,
                    y: geometry.size.height * 0.6
                )
                .scaleEffect(0.4) // 缩小到 40%（之前是 80%）
                
                // 实时数据叠加层（右侧）
                VStack {
                    HStack {
                        // 左上角：得分显示（放大）
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("得分"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(score)")
                                    .font(.title)  // 放大数字
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.leading, 12)
                        .padding(.top, 12)
                        
                        Spacer()
                        
                        // 右上角：实时数据
                        VStack(alignment: .trailing, spacing: 8) {
                            // 速度
                            DataBadge(
                                icon: "speedometer",
                                value: "\(Int(currentBPM))",
                                unit: "BPM",
                                color: .blue
                            )
                            
                            // 稳定性
                            DataBadge(
                                icon: "waveform",
                                value: "\(Int(stability * 100))",
                                unit: "%",
                                color: stabilityColor
                            )
                            
                            // 时长
                            DataBadge(
                                icon: "timer",
                                value: formatDuration(sessionDuration),
                                unit: "",
                                color: .orange
                            )
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 12)
                    }
                    
                    Spacer()
                    
                    // 状态消息（底部居中）
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .onAppear {
            startAnimation()
        }
        .onChange(of: isRunning) { _, newValue in
            if newValue {
                startAnimation()
            }
        }
    }
    
    private func startAnimation() {
        withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
            animationPhase = 1.0
        }
        
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            trackScrollOffset = -100
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Moving Track View（横版移动跑道）
/// 横版跑道：白色虚线随速度横向滚动。
///
/// 用 TimelineView 按时间积分算位移，而不是 repeatForever 动画：
/// repeatForever 一旦启动就停不下来（旧代码里那个"停止"是个空的 withAnimation，
/// 位移照样在走），在弹挑模式下就会变成"小人不跑了，路还在跑"。
/// 按时间积分还保证中途起步、变速不跳相位。
struct MovingTrackView: View {
    let speed: Double
    let isActive: Bool

    /// 已经滚过的总位移（点）。
    @State private var travelled: CGFloat = 0
    /// 本次连续滚动的时间锚点，nil 表示停着。
    @State private var anchor: Date?
    /// 锚定那一刻的速度（点/秒）。滚动中不再改，避免变速时同一帧里位移突跳。
    @State private var anchorSpeed: Double = 0

    private var pointsPerSecond: Double {
        guard speed > 0 else { return 0 }
        return min(max(speed, 40), 240)   // 60 BPM ≈ 60 pt/s，180 BPM ≈ 180 pt/s
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: anchor == nil)) { context in
            Canvas { ctx, size in
                draw(in: ctx, size: size, offset: currentOffset(at: context.date))
            }
        }
        .onAppear(perform: reanchor)
        .onChange(of: isActive) { _, _ in reanchor() }
        .onChange(of: speed) { _, _ in reanchor() }
    }

    /// 当前累计位移：已结算部分 + 锚点之后按锚定速度走的部分。
    private func currentOffset(at date: Date) -> CGFloat {
        guard let anchor else { return travelled }
        return travelled + CGFloat(max(0, date.timeIntervalSince(anchor)) * anchorSpeed)
    }

    /// 把"已经走过的时间"结算进 travelled，然后按当前状态重新锚定。
    private func reanchor() {
        let now = Date()
        if let anchor {
            travelled += CGFloat(max(0, now.timeIntervalSince(anchor)) * anchorSpeed)
        }
        anchor = (isActive && pointsPerSecond > 0) ? now : nil
        anchorSpeed = pointsPerSecond
    }

    private func draw(in ctx: GraphicsContext, size: CGSize, offset: CGFloat) {
        let spacing: CGFloat = 100
        let dashWidth: CGFloat = 80
        let y = size.height * 0.65

        // 虚线：相位取模，所以位移再大也只是同一排虚线在平移。
        let phase = offset.truncatingRemainder(dividingBy: spacing)
        var x = phase - spacing
        while x < size.width + spacing {
            let rect = CGRect(x: x, y: y - 2, width: dashWidth, height: 4)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white.opacity(0.4)))
            x += spacing
        }

        // 跑道上下边界
        for ratio in [0.55, 0.75] {
            let lineY = size.height * ratio
            let rect = CGRect(x: 0, y: lineY - 1, width: size.width, height: 2)
            ctx.fill(Path(rect), with: .color(.white.opacity(0.2)))
        }
    }
}

// MARK: - Data Badge（数据徽章组件）
struct DataBadge: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            
            Text(value)
                .font(.caption)
                .fontWeight(.bold)
            
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
    }
}

// MARK: - Compact Runner View（紧凑版跑步小人）
struct CompactRunnerView: View {
    let animationPhase: Double
    let isRunning: Bool
    
    private var leftArmAngle: Angle {
        .degrees(sin(animationPhase * .pi * 2) * 30)
    }
    
    private var rightArmAngle: Angle {
        .degrees(-sin(animationPhase * .pi * 2) * 30)
    }
    
    private var leftLegAngle: Angle {
        .degrees(-sin(animationPhase * .pi * 2) * 40)
    }
    
    private var rightLegAngle: Angle {
        .degrees(sin(animationPhase * .pi * 2) * 40)
    }
    
    private var bodyTilt: Angle {
        .degrees(isRunning ? 5 : 0)
    }
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 头部
                Circle()
                    .fill(Color.orange.gradient)
                    .frame(width: 30, height: 30)
                    .overlay {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.black)
                                .frame(width: 4, height: 4)
                            Circle()
                                .fill(Color.black)
                                .frame(width: 4, height: 4)
                        }
                        .offset(y: -2)
                    }
                
                // 躯干
                Capsule()
                    .fill(Color.blue.gradient)
                    .frame(width: 20, height: 40)
                
                // 腿部
                ZStack {
                    Capsule()
                        .fill(Color.green.gradient)
                        .frame(width: 10, height: 35)
                        .offset(y: 17.5)
                        .rotationEffect(leftLegAngle, anchor: .top)
                        .offset(x: -5)
                    
                    Capsule()
                        .fill(Color.green.gradient)
                        .frame(width: 10, height: 35)
                        .offset(y: 17.5)
                        .rotationEffect(rightLegAngle, anchor: .top)
                        .offset(x: 5)
                }
                .frame(height: 35)
            }
            .overlay(alignment: .top) {
                ZStack {
                    Capsule()
                        .fill(Color.orange.gradient)
                        .frame(width: 8, height: 30)
                        .offset(y: 15)
                        .rotationEffect(leftArmAngle, anchor: .top)
                        .offset(x: -15, y: 30)
                    
                    Capsule()
                        .fill(Color.orange.gradient)
                        .frame(width: 8, height: 30)
                        .offset(y: 15)
                        .rotationEffect(rightArmAngle, anchor: .top)
                        .offset(x: 15, y: 30)
                }
            }
            .rotationEffect(bodyTilt)
            
            // 阴影
            Ellipse()
                .fill(Color.black.opacity(0.2))
                .frame(width: 50, height: 12)
                .offset(y: 65)
                .scaleEffect(x: isRunning ? 1.1 : 1.0)
        }
        .animation(.easeInOut(duration: 0.1), value: isRunning)
    }
}


// MARK: - Practice Settings Sheet（练习设置对话框）
struct PracticeSettingsSheet: View {
    @Binding var targetBPM: Double
    @Binding var targetDuration: TimeInterval
    @Binding var metronomeEnabled: Bool  // ✨ 新增：节拍器开关
    @Binding var metronomeSoundType: MetronomeSoundType  // ✨ 新增：节拍器音色
    @Environment(\.dismiss) private var dismiss
    
    // 本地临时状态
    @State private var localBPM: Double
    @State private var localDuration: TimeInterval
    @State private var localMetronomeEnabled: Bool  // ✨ 新增
    @State private var localSoundType: MetronomeSoundType  // ✨ 新增
    
    // 预设时长选项
    private let durationPresets: [(String, TimeInterval)] = [
        (L("1分钟"), 60),
        (L("3分钟"), 180),
        (L("5分钟"), 300),
        (L("10分钟"), 600),
        (L("15分钟"), 900),
        (L("30分钟"), 1800)
    ]
    
    // 格式化时长显示
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes == 0 {
            return L("30秒")
        } else if minutes < 60 {
            return "\(minutes)" + L("分钟")
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours)" + L("小时")
            } else {
                return "\(hours)" + L("小时") + "\(mins)" + L("分钟")
            }
        }
    }
    
    init(targetBPM: Binding<Double>, targetDuration: Binding<TimeInterval>, metronomeEnabled: Binding<Bool>, metronomeSoundType: Binding<MetronomeSoundType>) {
        _targetBPM = targetBPM
        _targetDuration = targetDuration
        _metronomeEnabled = metronomeEnabled
        _metronomeSoundType = metronomeSoundType
        _localBPM = State(initialValue: targetBPM.wrappedValue)
        _localDuration = State(initialValue: targetDuration.wrappedValue)
        _localMetronomeEnabled = State(initialValue: metronomeEnabled.wrappedValue)
        _localSoundType = State(initialValue: metronomeSoundType.wrappedValue)
    }
    
    var body: some View {
        NavigationView {
            Form {
                // BPM 设置区
                Section {
                    VStack(spacing: 16) {
                        // BPM 数值显示
                        HStack {
                            Spacer()
                            Text("\(Int(localBPM))")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                            Text("BPM")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        
                        // 调整按钮
                        HStack(spacing: 12) {
                            Button(action: {
                                localBPM = max(Double(MetronomeManager.minimumBPM), localBPM - 10)
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            Button(action: {
                                localBPM = min(Double(MetronomeManager.maximumBPM), localBPM + 10)
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // 滑块
                        Slider(value: $localBPM, in: Double(MetronomeManager.minimumBPM)...Double(MetronomeManager.maximumBPM), step: 1)
                            .tint(.blue)
                        
                        // 提示文字
                        Text("\(L("范围")): \(MetronomeManager.minimumBPM)-\(MetronomeManager.maximumBPM) BPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Label(L("目标速度"), systemImage: "target")
                }
                
                // 时长设置区
                Section {
                    // 时长数值显示
                    VStack(spacing: 16) {
                        HStack {
                            Spacer()
                            Text(formatDuration(localDuration))
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        
                        // 滑块
                        Slider(value: $localDuration, in: 30...3600, step: 30)
                            .tint(.orange)
                        
                        HStack {
                            Text(L("30秒"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(L("60分钟"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    
                    // 快捷选择按钮
                    VStack(spacing: 8) {
                        Text(L("快捷选择"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ForEach(durationPresets, id: \.0) { name, duration in
                                Button(action: {
                                    localDuration = duration
                                }) {
                                    Text(name)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            isSelected(duration) ? Color.blue : Color(.systemGray5)
                                        )
                                        .foregroundStyle(
                                            isSelected(duration) ? .white : .primary
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Label(L("训练时长"), systemImage: "timer")
                }
                
                // ✨ 节拍器设置区（新增）
                Section {
                    // 节拍器开关
                    Toggle(isOn: $localMetronomeEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "metronome.fill")
                                .foregroundStyle(localMetronomeEnabled ? .green : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("启用节拍器"))
                                    .font(.body)
                                if localMetronomeEnabled {
                                    Text(L("将在练习开始时自动播放"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .tint(.green)
                    
                    // 音色选择（只在启用时显示）
                    if localMetronomeEnabled {
                        Picker(L("节拍器音色"), selection: $localSoundType) {
                            ForEach(MetronomeSoundType.allCases) { type in
                                HStack(spacing: 8) {
                                    Image(systemName: type.icon)
                                    Text(type.displayName)
                                }
                                .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Label(L("节拍器"), systemImage: "metronome")
                } footer: {
                    if localMetronomeEnabled {
                        Text(L("节拍器将使用与练习相同的速度（") + "\(Int(localBPM)) BPM" + L("）"))
                    } else {
                        Text(L("开启节拍器可帮助您保持稳定的练习节奏"))
                    }
                }
            }
            .navigationTitle(L("练习设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("确认")) {
                        targetBPM = localBPM
                        targetDuration = localDuration
                        metronomeEnabled = localMetronomeEnabled  // ✨ 保存节拍器开关
                        metronomeSoundType = localSoundType  // ✨ 保存节拍器音色
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    private func isSelected(_ duration: TimeInterval) -> Bool {
        return abs(localDuration - duration) < 1
    }
}


#Preview {
    NavigationStack {
        RunningPracticeView()
    }
}


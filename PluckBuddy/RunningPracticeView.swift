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

    /// 演示 / 弹挑 两种体验。进模块先播演示，播完弹框询问；也可手动点 Picker 切换。
    @State private var mode: Int = 0
    /// 演示播完后是否弹出"要不要亲自试试"确认框。
    @State private var showTryPrompt = false
    /// 设置弹窗：目标速度 / 时长 / 节拍器开关与音色。
    @State private var showSettings = false
    /// 设置弹窗确认后是否进入弹挑模式。看完演示点「确认」→ 先出设置页，设置确认后才切到 play；
    /// 顶部齿轮直接开设置时保持 false，确认只刷新当前练习、不切模式。
    @State private var enterPlayAfterSettings = false
    /// 演奏页的右滑返回一直锁着，连演奏完弹出的报告页也锁；报告点「确认」才解锁。
    @State private var swipeBackLocked = true

    /// 报告弹框的「确认」要退回主菜单，走导航栈自带的 dismiss。
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // 整体底色：浅蓝 → 淡青 → 淡青绿，和参考图一致。
            LinearGradient(colors: [
                Color(red: 0.66, green: 0.85, blue: 0.94),
                Color(red: 0.74, green: 0.90, blue: 0.93),
                Color(red: 0.82, green: 0.93, blue: 0.87)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // 演奏页禁用系统右滑返回：向右挑弦时手指从边缘起划不会被当成"返回上一级"。
            // 报告页也继续锁着，只有报告「确认」点了才解锁。
            SwipeBackDisabler(isLocked: $swipeBackLocked)
                .frame(width: 0, height: 0)

            content

            // 演示播完的询问卡片：自定义样式，和整体 UI 一致。
            if showTryPrompt {
                tryPromptCard
            }

            // play 到点的练习报告：盖住整页，点「确认」回主菜单。
            if isShowingReport {
                practiceReportCard
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showTryPrompt)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isShowingReport)
        .navigationTitle(L("弹挑跑步"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings, onDismiss: {
            // 从「看完演示 → 确认」进设置，用户却点了取消：回到询问卡片，别停在演示结束画面。
            if enterPlayAfterSettings {
                enterPlayAfterSettings = false
                showTryPrompt = true
            }
        }) {
            PracticeSettingsSheet(
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
                        // 从演示确认进来：设置落定后切到弹挑模式。
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
                // 和双语版一致的节拍器开关：响着是绿色实心，停了是灰色线框。
                // 颜色跟 isPlaying（真正在打拍）走，与轮指页同一套判断。
                // 设置弹窗仍从顶部控制栏的齿轮进入。
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
            // 声音和小人共用同一个事件源，节奏严格同步。
            viewModel.onPluckSound = { [weak synth] string, velocity in
                synth?.play(string: string, velocity: velocity)
            }
            // 进模块只"就绪"：视频停在第 0 帧，小人站着，等评委点播放。
            viewModel.prepareDemoSession()
            video.prepare()
            // 节拍器默认不响：只同步速度，不自动打拍。要打拍由下方节拍器条的播放键决定。
            viewModel.metronome.bpm = Int(viewModel.targetBPM)
        }
        .onDisappear {
            video.stop()
            viewModel.stopPractice()
            viewModel.metronome.stop()
            synth.stop()
        }
        // 视频一播完就停脚本事件源，否则小人定格后拨弦声还会继续响。
        .onChange(of: video.didFinish) { _, finished in
            if finished {
                viewModel.stopPractice()
                // 演示结束：节拍器立即停（声音 + 拍点），不再让它播完后继续响。
                viewModel.metronome.stop()
            }
        }
        // 视频定格一会儿（DemoVideoController 里控制时长）才弹询问卡片，不直接切模式。
        .onChange(of: video.promptReady) { _, ready in
            if ready { showTryPrompt = true }
        }
    }

    /// 主内容：上半跑步动画 + 指标，下半演示视频或四弦交互区。
    ///
    /// 两种模式共用同一套比例：上半固定 38%（含底部提示语位置），剩下的高度全部给下半。
    /// 之前演示 32%、弹挑 42%，切模式时动画面板会长高、小人和跑道一起挪位置，
    /// 看着像换了一页；现在上下两块都不随模式变，切换时只有下半的内容换掉。
    private var content: some View {
        GeometryReader { geometry in
            let topHeight = geometry.size.height * 0.38
            VStack(spacing: 10) {
                // 顶部控制栏：齿轮 / 目标速度 / 节拍器（拍点 + 播放键）/ 剩余时间。
                // 节拍器内联在这一行，不再单独占一行；也没有模式切换 Picker——
                // 进模块即演示，看完点确认自己弹。
                TopControlBar(
                    targetBPM: viewModel.targetBPM,
                    // 演示模式剩余时间跟视频进度走（总长=视频时长）；弹挑模式用练习设定。
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
                        .fill(LinearGradient(colors: [.blue, .cyan],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .shadow(color: .blue.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text(L("轮到你来试试了"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(L("拨动琴弦，让小人跑起来吧"))
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
                            LinearGradient(colors: [.blue, .cyan],
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

    /// 上半：跑步动画 + 指标。指标沿用旧版布局：左上得分，右上 BPM / 稳定性 / 计时。
    ///
    /// 小人尺寸跟着面板高度算，不写死：Lottie 画布 1080×1080，人只占中间 597×700 那一块，
    /// 所以画布给到面板高度的 1.1 倍才显得饱满。画布多出来的一圈是纯留白，
    /// 用 .frame 把布局尺寸收回面板大小（否则 ZStack 会被画布撑大、渐变压到上下相邻区域）。
    /// 整块再上移 11%，脚下影子就落在底部提示语上方，不再和提示语重叠。
    private func runningHalf(height: CGFloat) -> some View {
        return ZStack {
            LinearGradient(colors: [
                Color(red: 0.47, green: 0.76, blue: 0.89),
                Color(red: 0.60, green: 0.83, blue: 0.90)
            ], startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            MovingTrackView(speed: viewModel.currentBPM, isActive: viewModel.isRunnerActive)

            // 演示模式连续循环；弹挑模式"弹一下迈一步"，靠 runStepToken 触发半圈。
            // 小人整体上移一点，让脚下影子落在底部提示语上方，两者不再叠在一起。
            LottieRunnerView(isActive: viewModel.isRunnerActive,
                             rhythm: mode == 0 ? .loop : .step(viewModel.runStepToken),
                             currentBPM: viewModel.currentBPM,
                             stepSeconds: viewModel.stepSeconds,
                             displaySize: height * 1.1)
                .frame(width: height, height: height)
                .offset(y: -height * 0.11)

            VStack {
                HStack(alignment: .top) {
                    // 左上：得分。三个练习模块共用同一个 ScoreBadge，位置/字号/材质完全一致。
                    ScoreBadge(score: viewModel.score)

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

                // 底部提示语：音符 + 实时反馈（如"试着保持匀速弹奏 (可以快一点)"）。
                // 浅色材质胶囊，居中悬浮在跑道下方；文字来自 ViewModel 的 statusMessage。
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

            // 练习结束的完整总结改成居中弹框（见 practiceReportCard），
            // 动画框里不再压一块文字，小人定格这一帧是干净的。
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    /// 练习结束的总结是 generateSummary() 产出的带换行文本（练习结束！\n时长…）。
    /// 用它把"总结态"和练习中的单行反馈区分开：前者走报告弹框，后者走底部胶囊。
    private var isShowingSummary: Bool {
        !viewModel.isRunning && viewModel.statusMessage.contains("\n")
    }

    /// 只在弹挑（play）模式下弹报告。演示播完走的是"轮到你来试试"，两套弹框不能同时出现。
    private var isShowingReport: Bool {
        mode == 1 && isShowingSummary
    }

    /// play 模式到点的练习报告弹框。卡片本体抽到 `PracticeReportCard`，
    /// 和「轮指花开」共用同一套版式，只是强调色不同（这边蓝青、那边粉紫）。
    private var practiceReportCard: some View {
        PracticeReportCard(lines: PracticeReportCard.lines(from: viewModel.statusMessage),
                           accentStart: .blue,
                           accentEnd: .cyan,
                           icon: "chart.bar.fill") {
            // 报告「确认」才解锁右滑返回：演奏刚结束、报告刚弹出时仍锁着，
            // 手指还在边缘划不会被判成返回上一级。
            swipeBackLocked = false
            dismiss()
        }
    }

    /// 练习中的单行反馈：去掉开头 emoji（音符图标已由胶囊自带）。
    /// 只在非总结态调用，所以不含换行。
    private var statusTipText: String {
        viewModel.statusMessage
            .replacingOccurrences(of: "🎉 ", with: "")
            .replacingOccurrences(of: "👍 ", with: "")
            .replacingOccurrences(of: "💪 ", with: "")
            .replacingOccurrences(of: "🎵 ", with: "")
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
        // 没开播时整块画面都算"点这里"：提示动画指向哪就点到哪，
        // 不用非得去右下角找那颗小圆钮。播放中不接手势，避免讲解时误触暂停。
        .contentShape(Rectangle())
        .onTapGesture {
            guard !video.loadFailed, !video.isPlaying else { return }
            toggleDemoPlayback()
        }
        // 播放/暂停：压在进度条上方，点到就同时控制视频和小人。
        .overlay(alignment: .bottomTrailing) {
            playPauseButton
                .padding(.trailing, 16)
                .padding(.bottom, video.loadFailed ? 14 : 62)
        }
        // 还没开始看时的单击提示：波纹从中心一圈圈散出去，指向画面本身。
        // 只停在第 0 帧才出现，一开播就撤掉——演示画面是主角，提示不该压在上面。
        .overlay(alignment: .center) {
            if !video.loadFailed, !video.isPlaying, !video.didFinish, video.elapsedSeconds < 0.05 {
                DemoPlayHint()
                    .padding(.bottom, 34)  // 略微上移，给底部节奏条和播放键让位
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: video.isPlaying)
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

    /// 切换模式：0=演示（脚本加速 + 视频），1=弹挑（无麦克风，全靠用户拨弦驱动）。
    /// 进模块只有演示，视频播完弹出提示，点确认先出设置页、确认后再走到这里切到弹挑；
    /// 不再有手动模式切换。两条路径都不请求麦克风；切走演示时务必停视频，避免声音残留。
    private func applyMode(_ new: Int) {
        mode = new
        showTryPrompt = false
        viewModel.stopPractice()
        if new == 0 {
            // 切回演示：停节拍器，只做准备，不自动播。视频停在第 0 帧，等评委点播放，
            // 否则刚切过去画面就自己动起来，也没法停在某一帧讲解。
            viewModel.metronome.stop()
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
            // 进入弹挑：节拍器按开关状态启动。看完演示进来时设置页默认已开启，这里立即打拍。
            if viewModel.metronomeIsEnabled {
                viewModel.metronome.start()
            }
        }
    }
}

// MARK: - 演示画面的单击提示

/// 演示视频停在第 0 帧时的"点这里"提示。两个练习模块共用，所以不设 private。
///
/// 视觉是一个手指图标外加三圈同心波纹：波纹由时间轴直接算相位，不用开关式的
/// repeatForever 动画——视图被反复插入移除（暂停、开播、切模式）时不会卡在终点，
/// 也不会因为状态残留而整片消失。整块 `allowsHitTesting(false)`，
/// 手指落在提示上仍然打到底下视频那块可点区域，不会出现"点了没反应"。
struct DemoPlayHint: View {
    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        // 每圈错开 1/3 周期，看起来是一圈接一圈往外推。
                        let phase = (time / 1.9 + Double(index) / 3)
                            .truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Color.white.opacity(0.85), lineWidth: 2)
                            .scaleEffect(1 + phase * 0.95)
                            .opacity((1 - phase) * 0.6)
                    }
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 68, height: 68)
            }

            Text(L("点一下，先看演示视频"))
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .allowsHitTesting(false)
        .accessibilityLabel(Text(L("点一下，先看演示视频")))
    }
}

// MARK: - 练习报告弹框

/// 练习到点的报告弹框。「弹挑跑步」用蓝青、「轮指花开」用粉紫，版式完全一样，
/// 所以抽成一个组件：以后改行距、改按钮文案只改这一处，两个模块不会长歪。
struct PracticeReportCard: View {
    let lines: [String]
    let accentStart: Color
    let accentEnd: Color
    /// 卡顶圆形图标里的 SF Symbol。
    let icon: String
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [accentStart, accentEnd],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .shadow(color: accentStart.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: icon)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(L("练习报告"))
                    .font(.headline)

                // 每行一条数据，等宽数字对齐；靠左排，读起来像一张小成绩单。
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button(action: onConfirm) {
                    Text(L("确认"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [accentStart, accentEnd],
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

    /// 把 generateSummary() 的多行总结拆成正文行：去掉首行"练习结束！"——
    /// 标题已经写了「练习报告」，再重复一遍是废话。
    static func lines(from summary: String) -> [String] {
        let all = summary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return all.count > 1 ? Array(all.dropFirst()) : all
    }
}

// MARK: - Top Control Bar（顶部控制栏 - 简化版）
struct TopControlBar: View {
    let targetBPM: Double  // 改为只读
    let targetDuration: TimeInterval
    let elapsedTime: TimeInterval
    let canEditSettings: Bool  // 是否可以编辑设置
    let onSettingsTapped: () -> Void  // 设置按钮回调
    // 节拍器内联：4 个拍点 + 播放/暂停按钮，和设置、速度、时间同一行。
    let metronomeCurrentBeat: Int
    let metronomeTotalBeats: Int
    let metronomeIsPlaying: Bool
    let onMetronomeToggle: () -> Void

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

            // 节拍器：4 个拍点轮流动 + 播放/暂停，内联在这一行。
            HStack(spacing: 8) {
                BeatIndicatorView(
                    currentBeat: metronomeCurrentBeat,
                    totalBeats: metronomeTotalBeats,
                    isPlaying: metronomeIsPlaying
                )
                .scaleEffect(0.62)

                Button(action: onMetronomeToggle) {
                    Image(systemName: metronomeIsPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(metronomeIsPlaying ? Color.orange : Color.green, in: Circle())
                }
                .buttonStyle(.plain)
            }

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
                        .foregroundStyle(remainingTime < 5 ? .red : .primary)
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

// MARK: - Score Badge（左上得分卡 - 三个练习模块共用）
/// 三个练习模块左上角的得分读数都走这里，保证位置、字号、材质完全一致：
/// 星星 .title2 + "得分"小字 + .title 粗体数字。数字用等宽，跳动时宽度不抖。
/// 分数是整页唯一的成绩读数，字号必须比工具栏的目标速度（.title3）大一档。
struct ScoreBadge: View {
    let score: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.title2)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("得分"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(score)")
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.45), lineWidth: 0.5)
        )
    }
}

// MARK: - Data Badge（数据徽章组件）
struct DataBadge: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color

    /// 三页右上读数共用一张卡：总宽、图标列、数值列都固定，
    /// 数字从 9 涨到 100、时长从 0:09 走到 10:09 时卡片都不会变宽或跳动，
    /// 三页的胶囊边缘也就天然对齐。数值列右对齐，位数变化只往左长。
    private static let cardWidth: CGFloat = 120
    private static let iconWidth: CGFloat = 18
    private static let valueWidth: CGFloat = 42

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: Self.iconWidth, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: Self.valueWidth, alignment: .trailing)

            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: Self.cardWidth, alignment: .leading)
        // 早先是 40% 黑底 + 默认黑字：深色胶囊上压黑字，落在浅蓝渐变里几乎读不出来。
        // 改成和左上得分卡同一套浅色材质，文字回到 .primary，强调色只留给图标，
        // 整页的读数就统一成"浅色磨砂胶囊 + 彩色图标"一种语言。
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 0.5))
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


// MARK: - 设置页「功能说明」条目

/// 「功能说明」的一行。两个练习模块的指标不是同一套（拨弦/跑步 vs 轮指/开花），
/// 所以内容由页面传入，设置页只负责排版。
struct PracticeExplainer: Identifiable {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var id: String { title }
}

extension PracticeExplainer {
    /// 弹挑跑步：BPM / 稳定性 / 跑步动画 / 得分。
    static var running: [PracticeExplainer] {
        [
            PracticeExplainer(icon: "metronome", title: "BPM",
                              detail: L("每分钟拨弦的次数，决定弹奏和目标速度。数字越大，要求越快。"),
                              color: .blue),
            PracticeExplainer(icon: "waveform.path.ecg", title: L("节奏稳定性"),
                              detail: L("相邻两次拨弦的间隔越均匀，稳定性越高，满分是一百。"),
                              color: .green),
            PracticeExplainer(icon: "figure.run", title: L("跑步动画"),
                              detail: L("每拨一次弦，小人就往前跑一步；弹得越快，跑得越快。"),
                              color: .orange),
            PracticeExplainer(icon: "star.fill", title: L("得分系统"),
                              detail: L("每次拨弦都能得分，节奏越稳定、坚持越久，总分越高。"),
                              color: .yellow)
        ]
    }

    /// 轮指花开：轮指速度 / 均匀度 / 花开动画 / 得分。
    /// 四个颜色都取自 `FlowerPalette`：系统 `.pink`/`.orange` 在这张粉底页里偏正红，
    /// 读起来像告警，换成低饱和的玫瑰家族后与页面本体一致。
    static var flower: [PracticeExplainer] {
        [
            PracticeExplainer(icon: "metronome", title: L("轮指速度"),
                              detail: L("每秒拨出的音数，乘 60 再除以每拍五个音，就是这一段的实际 BPM。"),
                              color: FlowerPalette.rose),
            PracticeExplainer(icon: "waveform.path", title: L("均匀度"),
                              detail: L("相邻两个音的间隔越一致，均匀度越高，花开得越正。"),
                              color: FlowerPalette.lilac),
            PracticeExplainer(icon: "camera.macro", title: L("花开动画"),
                              detail: L("每完成一轮轮指，花瓣长出一片；连续优秀会长出重瓣。"),
                              color: FlowerPalette.blush),
            PracticeExplainer(icon: "star.fill", title: L("得分系统"),
                              detail: L("每次轮指都能得分，速度、均匀度和序列质量一起决定总分。"),
                              color: FlowerPalette.amber)
        ]
    }

    /// 扫弦水波：扫弦次数 / 方向平衡 / 平均力度 / 得分。
    /// 颜色取自 `WavePalette`，与设置页、报告卡同一套湖蓝。
    static var wave: [PracticeExplainer] {
        [
            PracticeExplainer(icon: "waveform", title: L("扫弦次数"),
                              detail: L("每次从四根弦上扫过算一次，向上和向下分开计数。"),
                              color: WavePalette.deep),
            PracticeExplainer(icon: "arrow.up.arrow.down", title: L("方向平衡"),
                              detail: L("两个方向各扫一半时最高；一直朝一边扫，这一项会低。"),
                              color: WavePalette.lagoon),
            PracticeExplainer(icon: "bolt.fill", title: L("平均力度"),
                              detail: L("扫得越重，水波越大，单次得分也越高。"),
                              color: WavePalette.spray),
            PracticeExplainer(icon: "star.fill", title: L("得分系统"),
                              detail: L("每次扫弦都得分，力度和方向平衡再加成。"),
                              color: WavePalette.amber)
        ]
    }
}

// MARK: - Practice Settings Sheet（练习设置对话框）
struct PracticeSettingsSheet: View {
    @Binding var targetBPM: Double
    @Binding var targetDuration: TimeInterval
    @Binding var metronomeEnabled: Bool  // ✨ 新增：节拍器开关
    @Binding var metronomeSoundType: MetronomeSoundType  // ✨ 新增：节拍器音色
    /// 确认保存后刷新练习：play 模式改了时长/节拍器要重开一轮，否则剩余时长对不上、拨弦冻结不响。
    let onApply: () -> Void
    /// 强调色：弹挑蓝、轮指玫瑰粉。管 BPM、滑块、选中态，以及整页的按钮与开关。
    var accent: Color = .blue
    /// 时长区的颜色。和强调色分开，是为了让「速度」和「时长」两块一眼能分；
    /// 轮指页传淡紫，弹挑页沿用橙。
    var durationAccent: Color = .orange
    /// 「功能说明」的内容由调用方传入——两个模块的指标不是同一套。
    var explainers: [PracticeExplainer] = PracticeExplainer.running
    @Environment(\.dismiss) private var dismiss
    
    // 本地临时状态
    @State private var localBPM: Double
    @State private var localDuration: TimeInterval
    @State private var localMetronomeEnabled: Bool  // ✨ 新增
    @State private var localSoundType: MetronomeSoundType  // ✨ 新增
    
    // 预设时长选项
    private let durationPresets: [(String, TimeInterval)] = [
        (L("15秒"), 15),
        (L("30秒"), 30),
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
            // 下限已放宽到 15 秒，按实际秒数显示，不再写死 30秒。
            return "\(Int(seconds))" + L("秒")
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
    
    init(targetBPM: Binding<Double>, targetDuration: Binding<TimeInterval>, metronomeEnabled: Binding<Bool>, metronomeSoundType: Binding<MetronomeSoundType>, onApply: @escaping () -> Void = {}, accent: Color = .blue, durationAccent: Color = .orange, explainers: [PracticeExplainer] = PracticeExplainer.running) {
        _targetBPM = targetBPM
        _targetDuration = targetDuration
        _metronomeEnabled = metronomeEnabled
        _metronomeSoundType = metronomeSoundType
        self.onApply = onApply
        self.accent = accent
        self.durationAccent = durationAccent
        self.explainers = explainers
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
                                .foregroundStyle(accent)
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
                                    .foregroundStyle(accent)
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            Button(action: {
                                localBPM = min(Double(MetronomeManager.maximumBPM), localBPM + 10)
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(accent)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // 滑块
                        Slider(value: $localBPM, in: Double(MetronomeManager.minimumBPM)...Double(MetronomeManager.maximumBPM), step: 1)
                            .tint(accent)
                        
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
                                .foregroundStyle(durationAccent)
                            Spacer()
                        }
                        
                        // 滑块：下限 15 秒，与默认时长一致；步长 15 秒保证 15 可达。
                        Slider(value: $localDuration, in: 15...3600, step: 15)
                            .tint(durationAccent)
                        
                        HStack {
                            Text(L("15秒"))
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
                                            isSelected(duration) ? accent : Color(.systemGray5)
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
                                .foregroundStyle(localMetronomeEnabled ? accent : .secondary)
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

                // 功能说明：解释四项核心指标，让使用者看懂数据怎么算出来的。
                // 条目由调用方给：「弹挑」讲拨弦和跑步，「轮指」讲轮指和开花。
                Section {
                    ForEach(explainers) { item in
                        explainRow(icon: item.icon, title: item.title,
                                   detail: item.detail, color: item.color)
                    }
                } header: {
                    Label(L("功能说明"), systemImage: "info.circle")
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
                        // 先落定新设置，再刷新练习：剩余时长按新时长重算、拨弦解冻。
                        onApply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        // 取消/确认、音色菜单、开关统一跟强调色走，不再一半系统蓝一半页内色。
        .tint(accent)
    }
    
    private func isSelected(_ duration: TimeInterval) -> Bool {
        return abs(localDuration - duration) < 1
    }

    /// 功能说明里的一行：左侧图标 + 标题 + 说明文字。
    private func explainRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}


#Preview {
    NavigationStack {
        RunningPracticeView()
    }
}


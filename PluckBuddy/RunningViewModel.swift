//
//  RunningViewModel.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/7/16.
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

@MainActor
class RunningViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var isRunning = false
    @Published var distance: Double = 0.0 // 跑步距离（米）
    @Published var pluckCount: Int = 0 // 弹拨次数
    @Published var currentBPM: Double = 0 // 当前速度
    @Published var stability: Double = 0 // 稳定性 0-1（最近窗口的瞬时值）
    @Published var averageStability: Double = 0 // 本次练习稳定性的平均值（停止后展示）
    @Published var score: Int = 0 // 得分
    @Published var statusMessage = L("准备开始")
    @Published var targetBPM: Double = 120 // 目标速度
    @Published var sessionDuration: TimeInterval = 0 // 当前练习时长（秒）
    @Published var targetDuration: TimeInterval = 300 // 目标时长（默认5分钟）

    // MARK: - Demo Mode (SSC / no real Pipa)
    // 演示模式：用脚本事件源代替麦克风检测，评委无需真琵琶即可看到完整动画与评分。
    // 设为 false 即回到原有的麦克风 + RhythmDetector 模式，随时可切回。
    @Published var demoMode: Bool = true

    /// 弹挑交互模式：事件全部来自评委点弦，不请求麦克风、不起演示定时器。
    /// true 时 startPractice 只做状态初始化，速度完全由 pluckString 的间隔决定。
    @Published var manualMode: Bool = false

    // 角色动画状态
    @Published var characterPosition: Double = 0.0 // 角色位置（0-1）- 已废弃，改用跑道移动
    @Published var isCharacterRunning = false
    @Published var isPlucking: Bool = false // 是否正在弹奏（控制动画）
    
    // 跑道动画状态
    @Published var trackOffset: Double = 0.0 // 跑道偏移量（用于滚动效果）
    @Published var runningSpeed: Double = 0.0 // 跑步速度（像素/秒）
    
    // ✨ 新增：节拍器
    let metronome = MetronomeManager()
    
    // ✨ 计算属性：提供节拍器设置的绑定接口
    var metronomeIsEnabled: Bool {
        get { metronome.isEnabled }
        set { metronome.isEnabled = newValue }
    }
    
    var metronomeSoundType: MetronomeSoundType {
        get { metronome.soundType }
        set { metronome.soundType = newValue }
    }
    
    // MARK: - Private Properties
    private var audioManager: AudioManager?
    private var rhythmDetector: RhythmDetector?
    private var startTime: Date?
    private var durationTimer: Timer? // 用于更新实时时长
    private var idleWorkItem: DispatchWorkItem? // 用于检测空闲（无弹奏）
    private var cancellables = Set<AnyCancellable>() // ✨ Combine 订阅
    private var stabilitySum: Double = 0 // 本次练习稳定性采样值之和
    private var stabilitySampleCount: Int = 0 // 有效采样个数（用于算平均）

    // 演示模式的脚本事件源
    private var demoTimer: Timer?
    private var demoEventCount = 0
    /// 演示已经播过的秒数。暂停时结算，恢复时用它把 startTime 往回拨，
    /// 这样减速/加速曲线和 BPM 变化不会因为暂停而跳。
    private var demoElapsed: TimeInterval = 0
    /// 演示从慢到快：起始/结束 BPM 与爬升总时长（秒）。评审约 20 秒看完一次加速。
    private let demoStartBPM: Double = 60
    private let demoEndBPM: Double = 180
    /// 与 DemoVideoController.limitSeconds 保持一致：视频多长，小人就加速多久。
    private let demoRampDuration: TimeInterval = 12
    /// 当前演示进度 0→1，UI 用它画进度条并标注"速度递增"。
    @Published var demoProgress: Double = 0
    /// 每次弹拨触发的声音回调，参数是弦号(0..3)和力度。声音与小人共用同一个事件源，
    /// 所以声音节奏和跑步动画严格同步。将来换成真 Pipa 单音只改回调实现。
    var onPluckSound: ((_ string: Int, _ velocity: Float) -> Void)?

    // 弹挑模式：当前被点/划过的弦号，UI 用来做按下高亮反馈。
    @Published var lastPluckedString: Int?
    @Published var lastPluckDirection: String = "挑" // 弹(向下)/挑(向上)

    /// 弹挑模式：每次拨弦 +1。跑步动画用它做视图身份，换身份 = 重新跑一圈，
    /// 这样"弹一下跑一步"，不会一个音跑出去好多圈。
    @Published var runStepToken: Int = 0
    /// 弹挑模式：一次"跑一圈"的目标时长（秒），取最近几次拨弦的平均间隔。
    @Published var stepSeconds: Double = 0.5
    /// 小人此刻是否在跑。演示模式整段为 true；弹挑模式每拨一次为 true 一个步长。
    @Published var isRunnerActive: Bool = false

    // MARK: - Constants
    private let distancePerPluck: Double = 1.0 // 每次弹拨前进 1 米
    private let scorePerPluck: Int = 10 // 每次弹拨得分
    private let bonusThreshold: Double = 0.8 // 稳定性奖励阈值
    private let idleTimeout: TimeInterval = 2.0 // 空闲超时：2秒无弹奏视为停止
    
    // MARK: - Initialization
    init() {
        print("🏃 RunningViewModel init() 开始")
        // ✨ 设置初始节拍器速度（同步，因为只是赋值）
        metronome.bpm = Int(targetBPM)
        print("🏃 RunningViewModel - 节拍器速度已设置")
        
        // ✨ 延迟设置订阅，避免阻塞初始化
        DispatchQueue.main.async {
            print("🏃 RunningViewModel - 开始设置 BPM 同步")
            self.setupBPMSync()
        }
        print("🏃 RunningViewModel init() 完成")
    }
    
    // ✨ 设置 BPM 同步（延迟调用）
    private func setupBPMSync() {
        // 监听 targetBPM 变化，自动同步节拍器
        $targetBPM
            .dropFirst() // 跳过初始值，避免重复设置
            .sink { [weak self] newBPM in
                guard let self = self else { return }
                self.metronome.bpm = Int(newBPM)
                print("🎯 目标速度已更改为 \(Int(newBPM)) BPM，节拍器已同步")
                // 演示模式速度由 60→180 的加速曲线决定，不随 targetBPM 变化，
                // 这里不需要重建脚本定时器（弹挑模式的手动 BPM 也是实时算的）。
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle
    /// 切到弹挑模式时调用：清空上一轮演示留下的统计，四项指标（得分/速度/稳定性/计时）归零，
    /// 并保持"尚未开始"状态——第一次拨弦才真正开始计时，不让计时器一进页面就跑。
    func prepareManualSession() {
        stopPractice()
        manualMode = true
        demoMode = false
        resetSession()
        isPlucking = false
        lastPluckedString = nil
        lastManualPluckTime = nil
        startTime = nil
        isRunning = false
        statusMessage = L("Tap the strings")
    }
    /// 切到演示模式时调用：归零并停在"未播放"。
    /// 视频侧同时 prepare() 摆好第一帧，小人停在原地，等用户点播放才开始——
    /// 切模式不该自动跑起来，评委会以为动画是自己动的。
    func prepareDemoSession() {
        // 先落定 demoMode，再 stopPractice：stopPractice 只在"非演示"时写练习记录，
        // 顺序反过来会把刚结束的弹挑记录重复写一遍。
        demoMode = true
        manualMode = false
        stopPractice()
        resetSession()
        demoElapsed = 0
        demoProgress = 0
        demoStabilityOverride = nil
        startTime = nil
        isRunning = false
        isRunnerActive = false
        statusMessage = L("准备开始")
    }

    /// 演示暂停：节奏计时和小人一起冻在当前帧，恢复时再从这一拍续上。
    func pauseDemo() {
        guard demoMode, !manualMode, isRunning else { return }
        if let start = startTime {
            demoElapsed += Date().timeIntervalSince(start)
        }
        startTime = nil
        demoTimer?.invalidate()
        demoTimer = nil
        stopDurationTimer()
        isRunning = false
        isRunnerActive = false
    }

    /// 演示继续：把已播秒数补回起点，加速曲线接着走，不会因为暂停而跳。
    func resumeDemo() {
        guard demoMode, !manualMode, !isRunning else { return }
        startTime = Date().addingTimeInterval(-demoElapsed)
        isRunning = true
        isRunnerActive = true
        // 小人的步频立刻跟上演到的那一拍，不让它在第一声拨弦之前用 0 BPM 的慢速空跑。
        let p = min(max(demoElapsed / demoRampDuration, 0), 1)
        currentBPM = demoStartBPM + (demoEndBPM - demoStartBPM) * p
        if demoStabilityOverride == nil { demoStabilityOverride = 0.92 }
        if pluckCount == 0 { statusMessage = L("从慢到快，注意听速度变化") }
        startDurationTimer()
        scheduleNextDemoBeat()
    }

    func startPractice() {
        // 弹挑交互模式：不请求麦克风、事件全部来自评委点弦。
        // 时间从第一次拨弦起算，所以这里才启动时长计时器。
        if manualMode {
            resetSession()
            isRunning = true
            startTime = Date()
            lastManualPluckTime = nil
            statusMessage = L("Tap the strings")
            startDurationTimer()
            return
        }

        // 演示模式：完全绕过麦克风，用脚本事件源驱动，评委无需真琵琶。
        if demoMode {
            startDemoPractice()
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            print("🎵 开始练习...")
            
            // 请求麦克风权限
            audioManager = AudioManager.shared
            guard let manager = audioManager else {
                print("❌ AudioManager 初始化失败")
                return
            }
            
            print("🎤 请求麦克风权限...")
            let hasPermission = await manager.requestMicrophonePermission()
            guard hasPermission else {
                print("❌ 麦克风权限被拒绝")
                statusMessage = L("需要麦克风权限")
                return
            }
            print("✅ 麦克风权限已授予")
            
            // 初始化节奏检测器
            rhythmDetector = RhythmDetector(sampleRate: 48000.0)
            rhythmDetector?.onPluckDetected = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handlePluckEvent(event)
                }
            }
            print("✅ 节奏检测器已初始化")
            
            // 重置状态
            resetSession()
            
            // 启动音频监听
            do {
                print("🎧 启动音频监听...")
                try manager.startListening { [weak self] buffer, _ in
                    guard let self = self,
                          let detector = self.rhythmDetector else { return }
                    
                    // ✅ DSP 启发式门控已回退（实测效果不稳），直接交给节奏检测器处理
                    _ = detector.detectPluck(from: buffer)
                }
                
                print("✅ 音频监听已启动")
                isRunning = true
                startTime = Date()
                statusMessage = L("开始弹奏吧！")
                
                // ✨ 如果节拍器已启用，自动启动
                if metronome.isEnabled {
                    metronome.start()
                    print("🎵 节拍器已自动启动")
                }
                
                // 启动时长计时器
                startDurationTimer()
                
            } catch {
                print("❌ 音频启动失败: \(error.localizedDescription)")
                statusMessage = L("音频启动失败")
            }
        }
    }
    
    // MARK: - Demo Mode (scripted event source)

    /// 演示模式启动：不请求麦克风，脚本事件源从缓到急，20 秒内 BPM 60→180。
    /// 音和小人共用同一个事件，因此"声音从慢到快"和"小人从慢到快"天然同步。
    private func startDemoPractice() {
        print("🎬 演示模式启动（速度递增，无需真 Pipa）")
        resetSession()
        demoEventCount = 0
        demoProgress = 0
        demoElapsed = 0
        // 演示模式没有检测器，给一个高位稳定的模拟值让评分/反馈链路完整运行。
        demoStabilityOverride = 0.92

        isRunning = true
        startTime = Date()
        isRunnerActive = true
        statusMessage = L("从慢到快，注意听速度变化")

        // 演示不启节拍器：其音色不是 Pipa，会干扰"拨弦声递增"的听感。
        startDurationTimer()
        scheduleNextDemoBeat()
    }

    /// 递归式一次性定时器：每次按"当前加速后的 BPM"决定下一次间隔，
    /// 这样 BPM 连续变化时声音和小人的节奏都即时跟上，不会像固定定时器那样滞后。
    private func scheduleNextDemoBeat() {
        demoTimer?.invalidate()
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let p = min(max(elapsed / demoRampDuration, 0), 1)
        demoProgress = p
        let bpm = demoStartBPM + (demoEndBPM - demoStartBPM) * p
        let interval = 60.0 / bpm

        demoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                self.injectPluckAutomatically()
                self.scheduleNextDemoBeat()
            }
        }
    }

    /// 脚本产生一次弹拨事件，构造与真实检测完全一致的 PluckEvent 走同一条处理链。
    /// 弦号 0→1→2→3 轮转，声音分布在四根弦上，听起来更像演奏。
    private func injectPluckAutomatically() {
        guard isRunning else { return }
        demoEventCount += 1
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let p = min(max(elapsed / demoRampDuration, 0), 1)
        let bpm = demoStartBPM + (demoEndBPM - demoStartBPM) * p
        let interval = 60.0 / bpm

        let string = demoEventCount % 4
        let amp: Float = 0.5 + 0.2 * Float(sin(Double(demoEventCount) * 0.7))
        let event = PluckEvent(
            timestamp: Date(),
            amplitude: amp,
            rms: amp * 0.6,
            interval: interval,
            bpm: bpm
        )
        lastPluckedString = string
        lastPluckDirection = "挑"
        // 演示模式由脚本事件源持续供料，小人一直跑；停掉演示时才收。
        isRunnerActive = true
        onPluckSound?(string, amp)
        handlePluckEvent(event)
    }

    /// 弹挑模式：点/划过某根弦触发一次拨弦。string 0=子弦(上) … 3=缠弦(下)。
    /// 速度由评委实际弹拨快慢决定：用最近几次间隔的均值算 BPM，小人据此跑快跑慢。
    ///
    /// 一次拨弦只迈一步：token 变化让跑步动画重建并只播半圈（一整圈是左右各一步）。
    /// 节奏（BPM）要攒够样本才成立——只拨一下就知道速度是假的，
    /// 所以至少三次拨弦（两次间隔）才出 BPM，四次拨弦才出稳定性，之前一律显示"—"。
    func pluckString(_ string: Int, direction: String = "挑") {
        if !isRunning { startPractice() }
        guard isRunning else { return }

        let now = Date()
        if let last = lastManualPluckTime {
            let gap = now.timeIntervalSince(last)
            // 太短的间隔是划过两根弦的连带触发，太长的是中途停手，都不算一个节奏样本。
            if gap >= 0.08, gap <= 2.0 {
                manualIntervals.append(gap)
                if manualIntervals.count > 6 { manualIntervals.removeFirst() }
            }
        }
        lastManualPluckTime = now

        let meanInterval = manualIntervals.isEmpty
            ? 0
            : manualIntervals.reduce(0, +) / Double(manualIntervals.count)
        let hasTempo = manualIntervals.count >= 2
        let manualBPM = hasTempo ? min(max(60.0 / meanInterval, 30), 300) : 0

        if meanInterval > 0 {
            // 迈一步的时长跟着拨弦间隔走，但不给到荒谬的极值。
            stepSeconds = min(max(meanInterval, 0.18), 1.0)
        }
        manualStabilityValue = manualStability()

        let amp: Float = 0.65
        let event = PluckEvent(
            timestamp: now,
            amplitude: amp,
            rms: amp * 0.6,
            interval: meanInterval,
            bpm: manualBPM
        )
        lastPluckedString = string
        lastPluckDirection = direction
        // 弹一下迈一步：token 变化 → 动画重建 → 只播半圈（左腿或右腿）。
        runStepToken &+= 1
        isRunnerActive = true

        onPluckSound?(string, amp)
        handlePluckEvent(event)
        scheduleStepEnd()
    }

    private var lastManualPluckTime: Date?
    /// 弹挑模式的稳定性覆盖值（0-1），由最近几次拨弦间隔的变异系数算出；样本不够时为 0。
    private var manualStabilityValue: Double = 0
    /// 最近几次拨弦的间隔（秒），最多留 6 个。
    private var manualIntervals: [Double] = []
    /// 一步跑完就收：拨完一个步长后小人停下，不再继续空跑。
    private var stepEndWork: DispatchWorkItem?

    /// 间隔越均匀越接近 1：用最近几次间隔的变异系数（标准差/均值）反推。
    /// 少于三次间隔（四次拨弦）不给值——两个点天然"完美均匀"，那个读数是假的。
    private func manualStability() -> Double {
        guard manualIntervals.count >= 3 else { return 0 }
        let mean = manualIntervals.reduce(0, +) / Double(manualIntervals.count)
        guard mean > 0 else { return 0 }
        let variance = manualIntervals
            .map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(manualIntervals.count)
        let cv = variance.squareRoot() / mean
        return max(0, min(1, 1 - cv))
    }

    /// 一个步长结束后让小人停下（跑步动画本身 playOnce，会自己停在末帧）。
    private func scheduleStepEnd() {
        stepEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isRunnerActive = false
        }
        stepEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stepSeconds, execute: work)
    }

    /// 弹挑模式的空闲复位：停速，避免小人一直保持高速。
    func notifyPluckIdle() {
        isPlucking = false
        currentBPM = 0
    }

    private func stopDemoTimer() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoStabilityOverride = nil
        lastManualPluckTime = nil
    }

    func stopPractice() {
        stopDemoTimer()
        stepEndWork?.cancel()
        stepEndWork = nil
        audioManager?.stopListening()
        isRunning = false
        isCharacterRunning = false
        isPlucking = false // 重置弹奏状态
        isRunnerActive = false
        
        // ✨ 停止节拍器
        metronome.stop()
        
        // 停止时长计时器
        stopDurationTimer()
        
        // 取消空闲任务
        idleWorkItem?.cancel()
        idleWorkItem = nil
        
        if let start = startTime {
            sessionDuration = Date().timeIntervalSince(start)
            
            // 保存练习记录（演示模式是脚本事件源，不是真人练习，不写进历史记录）
            if pluckCount > 0 && !demoMode {
                PracticeDataManager.shared.saveRunningSession(
                    duration: sessionDuration,
                    pluckCount: pluckCount,
                    averageBPM: currentBPM,
                    stability: averageStability, // 存整场平均，而非停止瞬间的最后一次瞬时值
                    distance: distance,
                    score: score
                )
            }
        }
        
        updateStatusMessage()
    }
    
    // MARK: - Event Handling
    /// 演示模式专用的稳定性覆盖值。麦克风模式始终读检测器的真实值，
    /// 这里非 nil 时（仅演示模式设置）用它，让评分链路照样跑通。
    private var demoStabilityOverride: Double?

    private func handlePluckEvent(_ event: PluckEvent) {
        guard isRunning else { return }
        // 🔍 添加调试日志
        print("🎸 检测到弹奏！")
        print("   - BPM: \(String(format: "%.1f", event.bpm))")
        print("   - 强度: \(String(format: "%.2f", event.amplitude))")
        print("   - RMS: \(String(format: "%.2f", event.rms))")
        print("   - 间隔: \(String(format: "%.3f", event.interval))s")
        print("   - 弹奏次数: \(pluckCount + 1)")
        print("   - 当前状态：isPlucking=\(isPlucking), currentBPM=\(String(format: "%.1f", currentBPM))")
        
        // 设置为正在弹奏
        isPlucking = true
        print("   ✓ 设置 isPlucking = true")
        
        // 重置空闲计时器
        resetIdleTimer()
        
        // 更新统计
        pluckCount += 1
        distance += distancePerPluck
        
        // 更新速度和稳定性
        let oldBPM = currentBPM
        currentBPM = event.bpm
        print("   ✓ 更新 currentBPM: \(String(format: "%.1f", oldBPM)) → \(String(format: "%.1f", currentBPM))")
        
        // 演示模式用固定高位值，弹挑模式用以拨弦间隔算出的值，麦克风模式读检测器。
        if let override = demoStabilityOverride {
            stability = override
        } else if manualMode {
            stability = manualStabilityValue
        } else {
            stability = rhythmDetector?.calculateStability() ?? 0
        }

        // 累计本次练习的稳定性平均值：只有检测器真正算出值（>0）的采样才计入，
        // 否则开头几个音的 0 会把整场平均值拉低，读起来像「练得很差」。
        if stability > 0 {
            stabilitySum += stability
            stabilitySampleCount += 1
            averageStability = stabilitySum / Double(stabilitySampleCount)
        }

        print("   - 当前稳定性: \(Int(stability * 100))%")
        print("   - 平均稳定性: \(Int(averageStability * 100))%（样本 \(stabilitySampleCount) 个）")
        
        // 计算得分
        var points = scorePerPluck
        
        // 稳定性奖励
        if stability > bonusThreshold {
            points += Int(Double(scorePerPluck) * 0.5) // +50% 奖励
        }
        
        // 速度匹配奖励
        let bpmDiff = abs(currentBPM - targetBPM)
        if bpmDiff < 5 {
            points += Int(Double(scorePerPluck) * 0.3) // +30% 奖励
        }
        
        score += points
        
        // 更新角色动画
        triggerCharacterStep()
        
        // 更新提示信息
        updateStatusMessage()
    }
    
    // MARK: - Idle Timer Management
    
    /// 重置空闲计时器（每次弹奏时调用）
    private func resetIdleTimer() {
        // 取消现有任务
        idleWorkItem?.cancel()
        
        // 创建新任务
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            print("⏸️ 空闲超时（\(self.idleTimeout)秒无弹奏），停止动画")
            print("   - 当前状态：isPlucking=\(self.isPlucking), BPM=\(self.currentBPM)")
            
            self.isPlucking = false
            self.currentBPM = 0
            
            // ✅ 重置节奏检测器，清除历史记录
            print("   - 重置 RhythmDetector 历史记录")
            self.rhythmDetector?.reset()
            
            print("   - 新状态：isPlucking=\(self.isPlucking), BPM=\(self.currentBPM)")
        }
        
        idleWorkItem = workItem
        
        // 在主线程延迟执行
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: workItem)
    }
    
    // MARK: - Animation
    private func triggerCharacterStep() {
        isCharacterRunning = true
        
        // 计算跑步速度（基于 BPM）
        // BPM 60 -> 50 像素/秒
        // BPM 180 -> 300 像素/秒
        let speedMultiplier = currentBPM / 60.0
        runningSpeed = 50.0 * speedMultiplier
        
        // 短暂延迟后停止跑步动画（手脚摆动会持续）
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 秒
            await MainActor.run {
                isCharacterRunning = false
            }
        }
    }
    
    // MARK: - UI Updates
    private func updateStatusMessage() {
        if !isRunning {
            statusMessage = generateSummary()
            return
        }
        
        if pluckCount == 0 {
            statusMessage = L("开始弹奏吧！")
            return
        }
        
        // 根据稳定性给出反馈
        if stability > 0.9 {
            statusMessage = L("🎉 节奏非常稳定！")
        } else if stability > 0.7 {
            statusMessage = L("👍 节奏不错，保持！")
        } else if stability > 0.5 {
            statusMessage = L("💪 继续练习，更稳定一些")
        } else {
            statusMessage = L("🎵 试着保持匀速弹奏")
        }
        
        // 速度提示
        let bpmDiff = currentBPM - targetBPM
        if abs(bpmDiff) > 20 {
            if bpmDiff > 0 {
                statusMessage += L(" (稍慢一点)")
            } else {
                statusMessage += L(" (可以快一点)")
            }
        }
    }
    
    private func generateSummary() -> String {
        guard pluckCount > 0 else {
            return L("准备开始")
        }
        
        let minutes = Int(sessionDuration / 60)
        let seconds = Int(sessionDuration.truncatingRemainder(dividingBy: 60))
        
        var summary = L("练习结束！\n")
        summary += String(format: L("时长: %d:%02d\n"), minutes, seconds)
        summary += String(format: L("弹奏: %d 次\n"), pluckCount)
        summary += String(format: L("距离: %d 米\n"), Int(distance))
        summary += String(format: L("稳定性: %d%%\n"), Int(averageStability * 100))
        summary += String(format: L("得分: %d"), score)
        
        return summary
    }
    
    // MARK: - Reset
    private func resetSession() {
        distance = 0
        pluckCount = 0
        currentBPM = 0
        stability = 0
        averageStability = 0
        stabilitySum = 0
        stabilitySampleCount = 0
        score = 0
        characterPosition = 0
        trackOffset = 0
        runningSpeed = 0
        sessionDuration = 0
        demoEventCount = 0
        manualStabilityValue = 0
        manualIntervals.removeAll()
        runStepToken = 0
        stepSeconds = 0.5
        isRunnerActive = false
        isPlucking = false
        rhythmDetector?.reset()
    }
    
    // MARK: - Timer Management
    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.sessionDuration = Date().timeIntervalSince(start)
                
                // 检查是否到达目标时长
                if self.sessionDuration >= self.targetDuration {
                    print("⏰ 训练时间到！自动停止")
                    self.stopPractice()
                }
            }
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
    
    // MARK: - Settings
    func setTargetBPM(_ bpm: Double) {
        targetBPM = max(60, min(Double(MetronomeManager.maximumBPM), bpm)) // 上限与节拍器一致
    }
}

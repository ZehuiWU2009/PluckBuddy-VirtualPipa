//
//  WaveViewModel.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/7/16.
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

/// 扫弦水波的状态机。
///
/// 和「弹挑跑步」「轮指花开」共用一套流程：进模块先是演示（脚本事件源，不需要真琴），
/// 播完弹确认 → 设置 → 进入 play（虚拟琴扫弦），练到时长出报告。
/// 三个模块的差别只在事件从哪来：这里一次扫弦 = 一笔划过四根弦。
@MainActor
class WaveViewModel: ObservableObject {

    // MARK: - Published Properties
    @Published var isRunning = false
    @Published var sweepCount: Int = 0 // 扫弦次数
    @Published var upCount: Int = 0 // 向上扫次数
    @Published var downCount: Int = 0 // 向下扫次数
    @Published var averageStrength: Double = 0 // 平均力度
    @Published var directionBalance: Double = 0.5 // 方向平衡度
    @Published var score: Int = 0 // 得分
    @Published var statusMessage = L("准备开始")
    @Published var sessionDuration: TimeInterval = 0 // 当前练习时长（秒）
    /// 目标时长。默认 15 秒：和另外两个模块一致，先练一小段看一轮完整的水波。
    @Published var targetDuration: TimeInterval = 15
    @Published var targetBPM: Double = 60 // 目标速度（BPM，扫弦通常较慢）

    // 水波状态
    @Published var waves: [WaveRipple] = [] // 当前的水波
    @Published var waterColor: Color = .blue // 水面颜色
    @Published var isSweeping: Bool = false // 是否正在扫弦（控制动画）

    // 节拍器
    let metronome = MetronomeManager()
    private var cancellables = Set<AnyCancellable>()

    /// 节拍器设置接口：开启即打拍，关闭即停。生命周期只跟开关走。
    var metronomeIsEnabled: Bool {
        get { metronome.isEnabled }
        set {
            metronome.isEnabled = newValue
            if newValue {
                metronome.bpm = Int(targetBPM)
                metronome.start()
            } else {
                metronome.stop()
            }
        }
    }

    var metronomeSoundType: MetronomeSoundType {
        get { metronome.soundType }
        set { metronome.soundType = newValue }
    }

    // MARK: - Private Properties
    private var audioManager: AudioManager?
    private var sweepDetector: SweepDetector?
    private var startTime: Date?
    private var durationTimer: Timer?
    private var demoTimer: Timer?
    private var waveIdCounter: Int = 0
    private var idleWorkItem: DispatchWorkItem?

    private(set) var demoMode = false
    private(set) var manualMode = false
    /// play 到点即冻结：再扫弦不再开启下一段计时（否则剩余时间会从满格重来）。
    private var manualSessionFinished = false

    /// 力度累加，用来算平均力度。麦克风那条路过去直接问检测器要统计，
    /// 虚拟琴和演示脚本没有检测器，只能自己攒。
    private var strengthSum: Double = 0

    // 演示脚本
    private var demoElapsed: TimeInterval = 0
    private var demoEventCount = 0
    private let demoRampDuration: TimeInterval = 12
    private let demoStartBPM: Double = 60
    private let demoEndBPM: Double = 150

    // MARK: - Constants
    private let idleTimeout: TimeInterval = 2.0 // 2秒无扫弦视为停止
    private let scorePerSweep: Int = 10 // 每次扫弦得分
    private let maxWaves = 5 // 屏幕上最多同时显示的水波数

    // MARK: - Initialization
    init() {
        metronome.bpm = Int(targetBPM)

        // 节拍器是独立的 ObservableObject，View 只按值读它的 isPlaying/currentBeat。
        // 不转发变化，右上角图标和四个拍点就不会跟着重绘。
        metronome.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        $targetBPM
            .dropFirst()
            .sink { [weak self] newBPM in self?.metronome.bpm = Int(newBPM) }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// 演示模式：清空上一轮统计，视频停在第一帧，水波静止，等用户点播放。
    func prepareDemoSession() {
        demoMode = true
        manualMode = false
        stopPractice()
        resetSession()
        startTime = nil
        demoElapsed = 0
        isRunning = false
        isSweeping = false
        statusMessage = L("准备开始")
    }

    /// 切到 play：清空演示留下的统计，第一次扫弦才真正开始计时。
    func prepareManualSession() {
        stopPractice()
        manualMode = true
        demoMode = false
        resetSession()
        manualSessionFinished = false
        startTime = nil
        isRunning = false
        isSweeping = false
        statusMessage = L("在四根弦上扫过去")
    }

    /// 设置确认后刷新整轮 play：到点冻结后 sessionDuration 停在旧值，
    /// 只改时长会让剩余时间算错，扫弦也还被冻着。
    func refreshManualSession() {
        guard manualMode, !demoMode else { return }
        startTime = nil
        prepareManualSession()
    }

    /// 演示暂停：脚本事件源和水波一起冻住，恢复时接着走，不跳速度。
    func pauseDemo() {
        guard demoMode, !manualMode, isRunning else { return }
        if let start = startTime { demoElapsed += Date().timeIntervalSince(start) }
        startTime = nil
        demoTimer?.invalidate()
        demoTimer = nil
        isRunning = false
        isSweeping = false
    }

    /// 演示继续：把已播秒数补回起点，加速曲线从暂停处续上。
    func resumeDemo() {
        guard demoMode, !manualMode, !isRunning else { return }
        startTime = Date().addingTimeInterval(-demoElapsed)
        isRunning = true
        isSweeping = true
        statusMessage = L("从慢到快，注意扫弦的力度")
        scheduleNextDemoSweep()
    }

    // MARK: - 麦克风扫弦（真琴路径，保留）

    /// 真琴练习：靠麦克风识别扫弦。当前界面走虚拟琴，这条路留着备用。
    func startPractice() {
        Task { [weak self] in
            guard let self = self else { return }
            audioManager = AudioManager.shared
            guard let manager = audioManager else { return }

            let hasPermission = await manager.requestMicrophonePermission()
            guard hasPermission else {
                statusMessage = L("需要麦克风权限")
                return
            }

            sweepDetector = SweepDetector(sampleRate: 48000.0)
            sweepDetector?.onSweepDetected = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleSweepEvent(event)
                }
            }

            resetSession()

            if metronome.isEnabled {
                metronome.bpm = Int(targetBPM)
                metronome.start()
            }

            do {
                try manager.startListening { [weak self] buffer, _ in
                    guard let self = self,
                          let detector = self.sweepDetector else { return }
                    _ = detector.detectSweep(from: buffer)
                }

                isRunning = true
                startTime = Date()
                statusMessage = L("开始扫弦吧！")
                startDurationTimer()

            } catch {
                statusMessage = L("音频启动失败")
                print("Audio error: \(error.localizedDescription)")
            }
        }
    }

    func stopPractice() {
        demoTimer?.invalidate()
        demoTimer = nil

        audioManager?.stopListening()
        isRunning = false
        isSweeping = false

        if metronome.isPlaying {
            metronome.stop()
        }

        durationTimer?.invalidate()
        durationTimer = nil

        idleWorkItem?.cancel()
        idleWorkItem = nil

        if let start = startTime {
            sessionDuration = Date().timeIntervalSince(start)

            // 演示是脚本事件源，不是真人练习，不写进历史。
            if sweepCount > 0 && !demoMode {
                PracticeDataManager.shared.saveWaveSession(
                    duration: sessionDuration,
                    sweepCount: sweepCount,
                    averageStrength: averageStrength,
                    score: score
                )
            }
        }

        updateStatusMessage()
    }

    // MARK: - Event Sources

    /// 虚拟琴扫弦：一笔划过四根弦，由页面判定「这一笔已经够四根」后调进来。
    /// 力度由页面按这一笔的快慢给（扫得越快越重）。
    func manualSweep(isUp: Bool, strength: Double) {
        guard !manualSessionFinished else { return }
        if !isRunning { startManualSession() }
        guard isRunning else { return }

        let normalized = min(max(strength, 0.15), 1.0)
        registerSweep(direction: isUp ? .up : .down,
                      strength: level(for: normalized),
                      normalized: normalized)
    }

    /// 麦克风检测到的扫弦，走同一条处理链。
    private func handleSweepEvent(_ event: SweepEvent) {
        guard isRunning, !manualMode else { return }
        registerSweep(direction: event.direction,
                      strength: event.strength,
                      normalized: event.normalizedStrength)
    }

    /// 统计、得分、水波、配色、提示语，全都挂在这一个口子上，
    /// 所以脚本、虚拟琴、麦克风三条路给出的反馈完全一致。
    private func registerSweep(direction: SweepDirection, strength: StrengthLevel, normalized: Double) {
        isSweeping = true
        resetIdleTimer()

        sweepCount += 1
        switch direction {
        case .up: upCount += 1
        case .down: downCount += 1
        }

        strengthSum += normalized
        averageStrength = strengthSum / Double(max(sweepCount, 1))
        directionBalance = balanceFromCounts()

        var points = scorePerSweep
        switch strength {
        case .veryStrong: points += 10
        case .strong: points += 5
        case .medium: points += 2
        case .weak: points += 0
        }
        if directionBalance > 0.4 { points += 5 }
        score += points

        createWave(direction: direction, normalized: normalized)
        updateWaterColor()
        updateStatusMessage()
    }

    /// 方向平衡：两个方向各占一半时为 1，全朝一个方向为 0。
    /// 前三次扫弦还不成比例，先给中性值 0.5，免得刚扫一下就显示 0%。
    private func balanceFromCounts() -> Double {
        let total = upCount + downCount
        guard total >= 4 else { return 0.5 }
        return 2.0 * Double(min(upCount, downCount)) / Double(total)
    }

    private func level(for strength: Double) -> StrengthLevel {
        if strength >= 0.85 { return .veryStrong }
        if strength >= 0.6 { return .strong }
        if strength >= 0.35 { return .medium }
        return .weak
    }

    private func startManualSession() {
        manualSessionFinished = false
        resetSession()
        isRunning = true
        startTime = Date()
        statusMessage = L("开始扫弦吧！")
        if metronome.isEnabled { metronome.start() }
        startDurationTimer()
    }

    // MARK: - Demo script

    /// 演示启动：脚本从 60 BPM 加到 150 BPM，方向交替，力度有起伏，
    /// 让水波看起来像有人在真的扫；不需要真琴，也不需要麦克风。
    private func scheduleNextDemoSweep() {
        demoTimer?.invalidate()
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let p = min(max(elapsed / demoRampDuration, 0), 1)
        let bpm = demoStartBPM + (demoEndBPM - demoStartBPM) * p
        let interval = 60.0 / bpm

        demoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                self.injectDemoSweep()
                self.scheduleNextDemoSweep()
            }
        }
    }

    /// 脚本扫弦：方向交替，力度按正弦起伏，四拍里有一拍轻一些，
    /// 这样「平均力度」「方向平衡」两项在演示里也是活的，不是两个常数。
    private func injectDemoSweep() {
        guard isRunning else { return }
        demoEventCount += 1
        let isUp = demoEventCount % 2 == 0
        let wave = sin(Double(demoEventCount) * 0.9)
        let normalized = min(max(0.55 + 0.3 * wave, 0.2), 0.95)
        registerSweep(direction: isUp ? .up : .down,
                      strength: level(for: normalized),
                      normalized: normalized)
    }

    // MARK: - Wave Animation
    private func createWave(direction: SweepDirection, normalized: Double) {
        if waves.count >= maxWaves {
            waves.removeFirst()
        }

        waveIdCounter += 1

        let wave = WaveRipple(
            id: waveIdCounter,
            center: CGPoint(x: 0.5, y: 0.5),
            maxRadius: CGFloat(normalized * 0.8 + 0.2),
            color: direction == .up ? Color.blue : Color.cyan,
            strength: normalized,
            direction: direction
        )

        waves.append(wave)

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if let index = waves.firstIndex(where: { $0.id == wave.id }) {
                    waves.remove(at: index)
                }
            }
        }
    }

    private func updateWaterColor() {
        let hue = 0.55 // 蓝色基调
        let saturation = 0.5 + (averageStrength * 0.5)
        let brightness = 0.6 + (averageStrength * 0.4)

        withAnimation(.easeInOut(duration: 0.5)) {
            waterColor = Color(hue: hue, saturation: saturation, brightness: brightness)
        }
    }

    // MARK: - UI Updates
    private func updateStatusMessage() {
        if !isRunning {
            statusMessage = generateSummary()
            return
        }

        if sweepCount == 0 {
            statusMessage = L("开始扫弦吧！")
            return
        }

        if averageStrength > 0.7 {
            statusMessage = L("💪 力度很好！")
        } else if averageStrength > 0.5 {
            statusMessage = L("👍 力度不错！")
        } else if averageStrength > 0.3 {
            statusMessage = L("👌 可以再用力一点")
        } else {
            statusMessage = L("🎵 试着加大力度")
        }

        if sweepCount >= 5 {
            if directionBalance < 0.2 {
                statusMessage += L("\n尝试两个方向都练习")
            } else if directionBalance > 0.4 {
                statusMessage += L("\n方向平衡很好！")
            }
        }
    }

    private func generateSummary() -> String {
        guard sweepCount > 0 else {
            return L("准备开始")
        }

        let minutes = Int(sessionDuration / 60)
        let seconds = Int(sessionDuration.truncatingRemainder(dividingBy: 60))

        var summary = L("练习结束！\n")
        summary += String(format: L("时长: %d:%02d\n"), minutes, seconds)
        summary += String(format: L("扫弦: %d 次\n"), sweepCount)
        summary += String(format: L("向上: %d 次 | 向下: %d 次\n"), upCount, downCount)
        summary += String(format: L("平均力度: %.1f%%\n"), averageStrength * 100)
        summary += String(format: L("方向平衡: %d%%\n"), Int(directionBalance * 100))
        summary += String(format: L("得分: %d"), score)

        return summary
    }

    // MARK: - Reset
    private func resetSession() {
        sweepCount = 0
        upCount = 0
        downCount = 0
        averageStrength = 0
        directionBalance = 0.5
        score = 0
        waves.removeAll()
        waterColor = .blue
        sessionDuration = 0
        waveIdCounter = 0
        strengthSum = 0
        isSweeping = false
        sweepDetector?.reset()
    }

    // MARK: - Idle Timer Management

    private func resetIdleTimer() {
        idleWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isSweeping = false
            self.sweepDetector?.reset()
        }

        idleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: workItem)
    }

    // MARK: - Timer
    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.sessionDuration = Date().timeIntervalSince(start)

                if self.sessionDuration >= self.targetDuration {
                    self.stopPractice()
                    // 到点：节拍器连同声音和拍灯一起停，开关同步回关。
                    self.metronome.stop()
                    self.metronome.isEnabled = false
                    // play 到点冻结本轮：再扫弦不再开启下一段计时。
                    if self.manualMode { self.manualSessionFinished = true }
                }
            }
        }
    }
}

// MARK: - WaveRipple
/// 水波纹数据模型
class WaveRipple: Identifiable, ObservableObject {
    let id: Int
    let center: CGPoint // 归一化坐标 (0-1)
    let maxRadius: CGFloat // 最大半径（归一化）
    let color: Color
    let strength: Double
    let direction: SweepDirection
    let createdAt: Date

    /// 当前扩散进度 (0-1)，基于时间计算
    var progress: Double {
        let elapsed = Date().timeIntervalSince(createdAt)
        let duration = 2.0 // 2秒完成扩散
        return min(1.0, elapsed / duration)
    }

    /// 透明度（随进度递减）
    var opacity: Double {
        return max(0, 1.0 - progress)
    }

    init(id: Int, center: CGPoint, maxRadius: CGFloat, color: Color, strength: Double, direction: SweepDirection) {
        self.id = id
        self.center = center
        self.maxRadius = maxRadius
        self.color = color
        self.strength = strength
        self.direction = direction
        self.createdAt = Date()
    }
}

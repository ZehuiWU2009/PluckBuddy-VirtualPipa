//
//  LottieRunnerView.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/10/11.
//
//  Lottie 跑步动画视图
//

import SwiftUI
import Lottie

/// 跑步小人。两种节奏对应 Running 模块的两个页签：
///
/// - `.loop`：演示模式。拨弦事件源源不断，小人持续循环跑，速度跟着 BPM 走。
/// - `.step(token)`：弹挑模式。"弹一下迈一步"——每拨一次弦 token +1，
///   视图身份随之变化被强制重建，动画只跑**半圈**（一整圈是左右腿各一步），
///   奇偶拨弦交替跑前半圈和后半圈，视觉上就是左右脚一步步交替迈出去。
///
/// 三条实测结论（Lottie 4.6.1，真机框架跑的探针，别凭直觉改）：
/// 1. `playbackMode` 只在取值变化时才重新应用。值不变的时间里父视图再怎么重绘
///    （计时器每 0.1 秒更新一次分数就会重绘）都不会打断播放。所以要"重新跑一圈"，
///    只能靠 `.id` 换身份重建视图；把同一个 `.playing` 再传一次没有任何效果。
/// 2. 起点必须写明确的 0。`fromProgress: nil` 的含义是"从当前进度开始"，
///    在循环模式下它会顺手把循环区间截成 [当前进度, 1]；从弹挑模式切回演示时
///    就会只剩尾巴那一小段在抖——这正是之前"切回 demo 动画不对"的原因。
/// 3. 这个动画（running_man，30 帧 30fps）一整圈是"左脚一步 + 右脚一步"。
///    弹挑模式只播半圈：第 1、3、5… 下播 0→0.5，第 2、4、6… 下播 0.5→1.0，
///    两半首尾相接（第 0 帧与第 30 帧姿态完全相同），所以既不会一音跑两步，
///    也不会有姿态跳变。
struct LottieRunnerView: View {
    /// 播放节奏。
    enum Rhythm: Equatable {
        /// 持续循环（演示模式）。
        case loop
        /// 一次拨弦迈一步，token 变化即重新起跑。
        case step(Int)
    }

    /// 这一步占整圈的比例。一整圈是左右腿各一步，所以每步半圈。
    private static let stepSpan: CGFloat = 0.5

    /// 这一帧该不该跑。演示模式整段为 true；弹挑模式每次拨弦为 true 一个步长。
    let isActive: Bool
    let rhythm: Rhythm
    let currentBPM: Double
    /// 弹挑模式下"迈一步"的目标时长（秒），一般等于最近几次拨弦的平均间隔。
    var stepSeconds: Double = 0.5
    /// 显示尺寸（正方形边长）。
    var displaySize: CGFloat = 200

    /// 视图身份：换 `step` 的 token 等于重建视图，动画自然从第一帧重来。
    private var identity: String {
        switch rhythm {
        case .loop:
            return "loop"
        case .step(let token):
            return "step-\(token)"
        }
    }

    private var playbackMode: LottiePlaybackMode {
        switch rhythm {
        case .loop:
            return isActive
                ? .playing(.fromProgress(0, toProgress: 1, loopMode: .loop))
                : .paused
        case .step(let token):
            // 还没拨过弦时停在第 0 帧（起始姿态），拨了只迈一步（半圈）。
            guard token > 0 else { return .paused }
            let span = Self.stepSpan
            // 奇偶交替：第 1、3、5… 声跑前半圈，第 2、4、6… 声跑后半圈。
            let start: CGFloat = token % 2 == 1 ? 0 : span
            return .playing(.fromProgress(start, toProgress: start + span, loopMode: .playOnce))
        }
    }

    /// 播放倍速。这个动画画布是 1080×1080、30 帧 30fps，整圈 1 秒。
    private func speed(for animation: LottieAnimation) -> Double {
        switch rhythm {
        case .loop:
            // 120 BPM 为标准 1 倍速。
            guard currentBPM > 0 else { return 0.6 }
            return min(max(currentBPM / 120.0, 0.4), 2.0)
        case .step:
            // 把这半步压进两次拨弦的间隔里：间隔越短迈步越快。
            // 半圈时长 = animation.duration × stepSpan ÷ speed，所以要按比例缩 speed。
            let cycle = min(max(stepSeconds, 0.18), 1.0)
            let spanSeconds = animation.duration * Double(Self.stepSpan)
            return min(max(spanSeconds / cycle, 0.35), 4.0)
        }
    }

    var body: some View {
        ZStack {
            if let animation = LottieAnimation.named("running_man") {
                // 使用 Lottie 官方 SwiftUI 视图。
                // 关键：.resizable() 告诉 SwiftUI 忽略 LottieAnimationView 的固有尺寸
                // （动画画布 1080×1080），完全按外层 .frame 缩放。
                // 之前的 UIViewRepresentable 包装层会让 SwiftUI 读到 intrinsic 1080，
                // 把父 ZStack 撑爆、小人跑出屏幕外——这是反复出问题的真正原因。
                LottieView(animation: animation)
                    .resizable()
                    .animationSpeed(speed(for: animation))
                    .playbackMode(playbackMode)
                    .frame(width: displaySize, height: displaySize)
                    .id(identity)
            } else {
                fallback
            }
        }
    }

    /// 动画文件缺失时的备用方案，不让界面崩。
    private var fallback: some View {
        VStack(spacing: 8) {
            Image(systemName: isActive ? "figure.run" : "figure.stand")
                .font(.system(size: displaySize * 0.55))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
            Text(isActive ? L("运行中...") : L("等待中..."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: displaySize, height: displaySize)
    }
}

#Preview {
    VStack(spacing: 20) {
        LottieRunnerView(isActive: true, rhythm: .loop, currentBPM: 120)
        LottieRunnerView(isActive: true, rhythm: .step(3), currentBPM: 120, stepSeconds: 0.5)
    }
    .frame(width: 300, height: 460)
    .background(Color.gray.opacity(0.2))
}

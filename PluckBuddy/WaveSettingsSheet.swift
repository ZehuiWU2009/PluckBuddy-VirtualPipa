//
//  WaveSettingsSheet.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/8/31.
//

import SwiftUI

/// 「扫弦水波」用的一小套色。
///
/// 系统 `.cyan`（#32ADE6）压在白色小字上对比度只有 2.6:1，选中的时长档会发虚；
/// 这里换成偏深的湖蓝，白字约 4.9:1，和页面顶部那片浅蓝渐变还是一家人。
enum WavePalette {
    /// 主强调：深湖蓝。按钮、选中档、报告卡都用它。
    static let deep = Color(red: 0.129, green: 0.439, blue: 0.702)   // #2170B3
    /// 时长区：青绿。和湖蓝同属冷色，用来把「速度」和「时长」分开。
    static let lagoon = Color(red: 0.090, green: 0.522, blue: 0.541) // #17858A
    /// 点缀：中间调的水蓝，只用在图标上。
    static let spray = Color(red: 0.373, green: 0.659, blue: 0.827)  // #5FA8D3
    /// 得分：压暗的金，保留星星的惯例色。
    static let amber = Color(red: 0.702, green: 0.502, blue: 0.055)  // #B3800E
}

/// 「扫弦水波」的练习设置。
///
/// 版式与另外两个模块共用 `PracticeSettingsSheet`，这里只换强调色和「功能说明」。
/// 之前这个页面自己写了一份 Form：时长八档、音色五档都用分段控件，手机宽度排不下，
/// 右边那几档点不到；现在统一走同一份设置页，这类问题只会在一个地方出现。
struct WaveSettingsSheet: View {
    @Binding var targetBPM: Double
    @Binding var targetDuration: TimeInterval
    @Binding var metronomeEnabled: Bool
    @Binding var metronomeSoundType: MetronomeSoundType
    /// 确认保存后刷新练习：改了时长要重开一轮，否则剩余时长对不上、扫弦还冻着。
    let onApply: () -> Void

    var body: some View {
        PracticeSettingsSheet(
            targetBPM: $targetBPM,
            targetDuration: $targetDuration,
            metronomeEnabled: $metronomeEnabled,
            metronomeSoundType: $metronomeSoundType,
            onApply: onApply,
            accent: WavePalette.deep,
            durationAccent: WavePalette.lagoon,
            explainers: PracticeExplainer.wave
        )
    }
}

// MARK: - Preview

#Preview {
    WaveSettingsSheet(
        targetBPM: .constant(60),
        targetDuration: .constant(15),
        metronomeEnabled: .constant(true),
        metronomeSoundType: .constant(.tick),
        onApply: {}
    )
}

//
//  FlowerSettingsSheet.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/8/31.
//

import SwiftUI

/// 「轮指花开」用的一小套色，避开系统 `.pink` 和 `.orange`。
///
/// 系统 `.pink` 在浅色模式下是 #FF2D55，饱和度接近正红；`.orange` 又是 #FF9500，
/// 两者一起铺在设置页的大数字和滑块上，和一个粉色背景的练习页完全不是一套语言，
/// 看着更像警告色。这里收成一组低饱和的玫瑰 / 淡紫，全部按白底可读挑过亮度。
enum FlowerPalette {
    /// 主强调：柔和玫瑰。白字压上去对比度约 4.5:1，够 12pt 小字的 AA 门槛。
    static let rose = Color(red: 0.776, green: 0.294, blue: 0.471)   // #C64B78
    /// 时长区：淡紫。和玫瑰同属冷粉家族，用来把「速度」和「时长」两块分开。
    static let lilac = Color(red: 0.560, green: 0.396, blue: 0.667)  // #8F65AA
    /// 点缀：中间调的粉，只用在图标这种不承载文字的地方（白底约 3.2:1）。
    static let blush = Color(red: 0.824, green: 0.451, blue: 0.561)  // #D2738F
    /// 得分：压暗的金。保留星星的惯例色，又不至于在粉底上跳成橙色。
    static let amber = Color(red: 0.702, green: 0.502, blue: 0.055)  // #B3800E
}

/// 「轮指花开」的练习设置。
///
/// 版式与「弹挑跑步」共用 `PracticeSettingsSheet`，这里只做三件事：
/// 把强调色换成粉，把时长区的颜色换成淡紫，把「功能说明」换成轮指那一套。
/// 之前这个页面自己写了一份 Form，时长用八档分段控件、音色用五档分段控件——
/// 手机宽度根本排不下，右边的档位点不到；现在统一走同一份设置页，
/// 这类问题只会在一个地方出现。
struct FlowerSettingsSheet: View {
    @Binding var targetBPM: Double
    @Binding var targetDuration: TimeInterval
    @Binding var metronomeEnabled: Bool
    @Binding var metronomeSoundType: MetronomeSoundType
    /// 确认保存后刷新练习：改了时长要重开一轮，否则剩余时长对不上、拨弦冻结不响。
    let onApply: () -> Void

    var body: some View {
        PracticeSettingsSheet(
            targetBPM: $targetBPM,
            targetDuration: $targetDuration,
            metronomeEnabled: $metronomeEnabled,
            metronomeSoundType: $metronomeSoundType,
            onApply: onApply,
            accent: FlowerPalette.rose,
            durationAccent: FlowerPalette.lilac,
            explainers: PracticeExplainer.flower
        )
    }
}

// MARK: - Preview

#Preview {
    FlowerSettingsSheet(
        targetBPM: .constant(120),
        targetDuration: .constant(30),
        metronomeEnabled: .constant(true),
        metronomeSoundType: .constant(.tick),
        onApply: {}
    )
}

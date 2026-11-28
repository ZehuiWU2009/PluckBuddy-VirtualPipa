//
//  SwipeBackDisabler.swift
//  PluckBuddy
//
//  演奏页禁用系统右滑返回：向右挑弦时手指常从屏幕边缘起划，
//  会被 NavigationStack 的 interactivePopGestureRecognizer 当成"返回上一级"。
//

import SwiftUI
import UIKit

/// 把这段挂在视图上，页面存活期间就关掉 NavigationStack 自带的交互式右滑返回。
/// 左上角返回按钮仍然可用，只是不再响应从边缘划回来的手势——弹挑、轮指、扫弦
/// 三个练习页都要横向划弦，尤其扫弦一笔向右，误触返回会让整轮练习丢失。
///
/// 解锁时机由外部传进来的 `isLocked` 控制：默认整页锁住，演奏到点弹出报告后仍然锁着，
/// 只有报告里的「确认」被点了才置为 false 恢复系统手势。这样刚练完手指还在边缘，
/// 不会在报告弹出的一瞬间被判成右滑返回。左上角返回离页时照例恢复，不影响其它页面。
///
/// 实现走一个零尺寸的 UIViewController：进栈时记下手势原状态再关掉，需要时再恢复。
/// 不用 Introspect 是因为工程还没引这个依赖。
///
/// 只在 `viewDidAppear` 里关一次并不可靠：NavigationStack 自己的 hosting controller
/// 可能在之后才完成 push，并把手势重新启用。所以 `viewDidLayoutSubviews` 里再兜一次，
/// 那个方法在导航栈就位后必然还会调用，能保证三个页面都真正关掉。
struct SwipeBackDisabler: UIViewControllerRepresentable {
    /// true：继续禁右滑；false：恢复系统右滑返回。报告弹框点「确认」时才置 false。
    @Binding var isLocked: Bool

    init(isLocked: Binding<Bool> = .constant(true)) {
        self._isLocked = isLocked
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.applyLock(isLocked)
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.applyLock(isLocked)
    }

    final class Controller: UIViewController {
        private weak var guardedGesture: UIGestureRecognizer?
        private var savedEnabled = true
        private var locked = true

        override func viewDidLoad() {
            super.viewDidLoad()
            // 纯桥接用，不占布局、不挡手势。
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyLock(locked)
            // push 动画结束后导航控制器可能再把手势打开一次，动画末尾补一刀。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.applyLock(self.locked)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            disableSwipeBack()
        }

        /// 外部切换锁定状态。解锁时立刻把手势还给系统，之后 layout 兜底不再重新锁上。
        func applyLock(_ newValue: Bool) {
            locked = newValue
            if newValue {
                disableSwipeBack()
            } else if let gesture = guardedGesture {
                gesture.isEnabled = savedEnabled
                guardedGesture = nil
            }
        }

        private func disableSwipeBack() {
            // 报告已确认解锁后，即使导航控制器再触发布局，也不要重新关掉手势。
            guard locked else { return }
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            if guardedGesture == nil {
                savedEnabled = gesture.isEnabled
                guardedGesture = gesture
            }
            if gesture.isEnabled { gesture.isEnabled = false }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // 离页就恢复原状态，避免把右滑返回永久关掉影响其它页面。
            // 报告确认走的是先解锁再 dismiss，这里就不会重复改手势。
            if locked { guardedGesture?.isEnabled = savedEnabled }
            guardedGesture = nil
        }
    }
}

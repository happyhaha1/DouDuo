import SwiftUI
import UIKit

/// 按住加速期间，由播放页向外层顶栏传递清屏状态。
struct DYPlaybackPressKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}


// MARK: - UIKit 手势宿主：Pan 起手定方向（短视频横向导航/影库横向快进，竖向漏给 ScrollView）+ 单击/双击/长按
// 纯 SwiftUI 的 .gesture/.simultaneousGesture 会吞掉整段手势序列导致竖滑分页失效；
// 下沉 UIKit 用一个 UIPanGestureRecognizer，在 shouldBegin 里按起手速度方向仲裁：
//   · 横向主导 → 本次手势归导航或 seek（由调用方选择）
//   · 纵向主导 → return false，手势漏给外层 ScrollView 分页切视频
// 起手那一帧定轴，整段锁死，中途不改（=你说的"一发力就定方向"）。
struct PlayerGestureView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (CGFloat, CGFloat) -> Void
    var onLongPress: (Bool) -> Void
    var onLongPressLock: () -> Void = {}
    var onLongPressUnlock: () -> Void = {}
    var enabled = true
    var topExclusion: CGFloat = 0
    var bottomExclusion: CGFloat = 64
    var onContextMenu: (() -> Void)? = nil
    var onSeekBegan: () -> Void = {}
    var onSeekChanged: (CGFloat, CGFloat) -> Void = { _, _ in }  // (横向位移, 宽度)
    var onSeekEnded: () -> Void = {}
    var onEdgeChanged: (CGFloat) -> Void = { _ in }        // 左缘右滑过程中：位移跟手
    var onEdgeEnded: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }  // 松手：(位移, 横向速度, 屏宽)
    /// 竖向优先（抖音短视频：上下滑切视频是主操作，只有明显横向才接管导航）；影库保持横向偏置
    var verticalFirst = false
    /// When provided, a horizontal gesture navigates once on release and never seeks.
    var onHorizontalSwipe: ((Bool) -> Void)? = nil // true = left

    var onPinchBegan: () -> Void = {}
    var onPinchChanged: (CGFloat) -> Void = { _ in }
    var onPinchEnded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .clear
        v.accessibilityIdentifier = "douyin.video.gestures"
        v.isUserInteractionEnabled = true
        let c = context.coordinator
        c.view = v
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = DYBoostTiming.holdSeconds
        // 识别前必须是静止按住：拖动要让长按失败，避免手指停在下一条视频上误开菜单；
        // 识别成功后（.began）再放开 allowableMovement，长按期间跟手指：
        // 上/下滑 50pt 才判定锁定/解锁，按下过程中轻微漂移不能取消长按。
        long.allowableMovement = 12
        long.delegate = c
        c.long = long

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingle(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        // 长按识别成功后，这一轮触摸不会再落到暂停或双击上。
        single.require(toFail: long)
        double.require(toFail: long)
        single.require(toFail: double)

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = c
        pan.maximumNumberOfTouches = 1
        c.pan = pan

        // 屏幕左缘右滑退出（系统级边缘手势，只在最左 ~20pt 触发，不抢中间区域）
        let edge = UIScreenEdgePanGestureRecognizer(target: c, action: #selector(Coordinator.handleEdge(_:)))
        edge.edges = .left
        edge.delegate = c
        c.edge = edge
        pan.require(toFail: edge)

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = c
        c.pinch = pinch
        v.addGestureRecognizer(pinch)
        v.addGestureRecognizer(pan)
        v.addGestureRecognizer(edge)
        v.addGestureRecognizer(single)
        v.addGestureRecognizer(double)
        v.windowChanged = { [weak c] window in c?.attach(to: window) }
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if !enabled { c.finishPress() }
        c.long?.isEnabled = enabled
    }

    static func dismantleUIView(_ uiView: HostView, coordinator: Coordinator) {
        coordinator.finishPress()
        coordinator.attach(to: nil)
        uiView.windowChanged = nil
    }

    final class HostView: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureView
        weak var view: UIView?
        var long: UILongPressGestureRecognizer?
        weak var pan: UIPanGestureRecognizer?
        weak var edge: UIScreenEdgePanGestureRecognizer?
        weak var pinch: UIPinchGestureRecognizer?
        private var pressStartY: CGFloat = 0
        private var pressLocked = false
        private var pressing = false
        private var pressOpensMenu = false
        /// 长按（加速）结束的时间。松手后系统可能再补一个「单击」，会把视频误暂停，这里吞掉。
        private var lastLongEnd = Date.distantPast
        private var longActive = false
        private weak var frozenScroll: UIScrollView?
        private var scrollWasEnabled = true
        private let feedback = UIImpactFeedbackGenerator(style: .light)

        init(_ p: PlayerGestureView) { parent = p }

        private var pagingScroll: UIScrollView? {
            var p = view?.superview
            while let v = p {
                if let scroll = v as? UIScrollView { return scroll }
                p = v.superview
            }
            return nil
        }

        func attach(to window: UIWindow?) {
            guard let long, long.view !== window else { return }
            finishPress()
            long.view?.removeGestureRecognizer(long)
            window?.addGestureRecognizer(long)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard parent.enabled, let view, view.window != nil else { return false }
            let p = touch.location(in: view)
            let region = view.bounds.inset(by: UIEdgeInsets(top: parent.topExclusion, left: 0,
                                                           bottom: parent.bottomExclusion, right: 0))
            guard region.contains(p) else { return false }
            // 窗口上还有评论面板、顶栏等兄弟层；只接收视频分页容器里的触摸。
            if let scroll = pagingScroll, let target = touch.view, !target.isDescendant(of: scroll) { return false }
            // 弹幕输入/键盘等编辑控件保持自己的交互。
            var target = touch.view
            while let v = target {
                if v is UITextField || v is UITextView { return false }
                target = v.superview
            }
            feedback.prepare()
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // SwiftUI 按钮也用手势追踪按下；让它等待长按失败，按住加速后松手不会点击按钮。
            // 分页的 Pan 不等待长按，正常竖滑可以立即切视频。
            gestureRecognizer === long && !(other is UIPanGestureRecognizer)
        }

        @objc func handleSingle(_ g: UITapGestureRecognizer) {
            // 长按松手后系统可能再补一个「单击」，会把视频误暂停，这里吞掉。
            if longActive || Date().timeIntervalSince(lastLongEnd) < 0.8 { return }
            if parent.enabled, !pressing { parent.onSingleTap() }
        }

        @objc func handleDouble(_ g: UITapGestureRecognizer) {
            guard parent.enabled, !pressing, let view else { return }
            parent.onDoubleTap(g.location(in: view).x, view.bounds.width)
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                pressing = true
                // 只有已经识别成功的长按才能转入锁定/解锁拖动。
                longActive = true
                pressStartY = g.location(in: view).y
                pressLocked = false
                g.allowableMovement = .greatestFiniteMagnitude
                // 只冻结当前视频所属的分页容器，清屏不会移除手势宿主。
                if let scroll = pagingScroll {
                    scrollWasEnabled = scroll.panGestureRecognizer.isEnabled
                    scroll.panGestureRecognizer.isEnabled = false
                    frozenScroll = scroll
                }
                // 用窗口坐标算横向比例：状态栏那一条也属于屏幕，不能把 30% / 70% 的分界挤偏。
                let coordinateView: UIView? = view?.window ?? view
                let fraction = g.location(in: coordinateView).x / max(coordinateView?.bounds.width ?? 1, 1)
                pressOpensMenu = parent.onContextMenu != nil && (0.3...0.7).contains(fraction)
                if pressOpensMenu {
                    feedback.impactOccurred()
                    parent.onContextMenu?()
                } else {
                    #if DEBUG
                    DYGestureDiagnostics.shared.boostStarts += 1
                    #endif
                    parent.onLongPress(true)
                }
            case .changed:
                guard !pressOpensMenu else { return }
                let dy = g.location(in: view).y - pressStartY
                if !pressLocked, abs(dy) > 50 {
                    pressLocked = true
                    feedback.impactOccurred()
                    if dy > 0 { parent.onLongPressLock() } else { parent.onLongPressUnlock() }
                }
            case .ended, .cancelled, .failed:
                // 松手后恢复初始识别阈值，让下一次拖动照常打断长按。
                g.allowableMovement = 12
                finishPress()
            default: break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                // A second finger cancels any single-finger boost/navigation.
                long?.isEnabled = false
                pan?.isEnabled = false
                var ancestor = view?.superview
                while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
                if let scroll = ancestor as? UIScrollView {
                    scrollWasEnabled = scroll.panGestureRecognizer.isEnabled
                    scroll.panGestureRecognizer.isEnabled = false
                    frozenScroll = scroll
                }
                parent.onPinchBegan()
                parent.onPinchChanged(gesture.scale)
            case .changed:
                parent.onPinchChanged(gesture.scale)
            case .ended, .cancelled, .failed:
                parent.onPinchEnded()
                long?.isEnabled = true
                pan?.isEnabled = true
                frozenScroll?.panGestureRecognizer.isEnabled = scrollWasEnabled
                frozenScroll = nil
            default: break
            }
        }

        /// 结束长按：恢复外层分页滑动、清锁，并按需通知播放页退出加速。
        func finishPress() {
            frozenScroll?.panGestureRecognizer.isEnabled = scrollWasEnabled
            frozenScroll = nil
            pressLocked = false
            if longActive { lastLongEnd = Date() }
            longActive = false
            let openedMenu = pressOpensMenu
            pressOpensMenu = false
            guard pressing else { return }
            pressing = false
            // 长按只是唤出了菜单、没有进入加速，就不该再反向结束加速。
            if !openedMenu { parent.onLongPress(false) }
        }

        @objc func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
            guard let v = view else { return }
            let dx = g.translation(in: v).x
            switch g.state {
            case .began:
                parent.onEdgeChanged(0)
            case .changed:
                parent.onEdgeChanged(max(0, dx))      // 跟手位移上报给容器，画面 1:1 右移
            case .ended, .cancelled, .failed:
                parent.onEdgeEnded(max(0, dx), g.velocity(in: v).x, v.bounds.width)
            default: break
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            if let navigate = parent.onHorizontalSwipe {
                guard g.state == .ended else { return }
                let dx = g.translation(in: v).x
                let velocity = g.velocity(in: v).x
                guard abs(dx) >= max(40, v.bounds.width * 0.12)
                    || (abs(dx) > 20 && abs(velocity) > 650) else { return }
                navigate(dx < 0)
                return
            }
            switch g.state {
            case .began: parent.onSeekBegan()
            case .changed: parent.onSeekChanged(g.translation(in: v).x, v.bounds.width)
            case .ended, .cancelled, .failed: parent.onSeekEnded()
            default: break
            }
        }

        // 方向仲裁：Pan 起手定轴。横向偏置——除非竖向明显主导才让给 ScrollView 切视频，
        // 否则都判为快进，避免快进时带点下滑分量被误识别成切视频。

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UIPinchGestureRecognizer { return true }
            if let pinch, pinch.state == .began || pinch.state == .changed { return false }
            if g === long {
                if let pan, pan.state == .began || pan.state == .changed { return false }
                var ancestor = view?.superview
                while let current = ancestor {
                    if let scroll = current as? UIScrollView,
                       scroll.isDragging || scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed {
                        return false
                    }
                    ancestor = current.superview
                }
            }
            if g is UIScreenEdgePanGestureRecognizer { return parent.onHorizontalSwipe == nil }
            guard let pg = g as? UIPanGestureRecognizer, let v = view else { return true }
            // 长按（2 倍速）期间不触发快进
            if let l = long, l.state == .began || l.state == .changed { return false }
            let vel = pg.velocity(in: v)
            // 底部 ~64pt 留给底部进度条手势，避免与全屏横滑重复触发
            let start = pg.location(in: v)
            if start.y > v.bounds.height - 64 { return false }
            // 起手那一帧速度可能是 0（0 >= 0 会被误判成快进，竖滑切不了视频）→ 退回用位移判方向；都为 0 让给分页
            var d = vel
            if abs(d.x) < 1, abs(d.y) < 1 { d = pg.translation(in: v) }
            if abs(d.x) < 0.5, abs(d.y) < 0.5 { return false }
            if parent.verticalFirst {
                // 横向要比竖向大 20% 才接管，其余一律交给分页切视频
                return abs(d.x) > abs(d.y) * 1.2
            }
            // 竖向速度要比横向大 50% 以上才算"切视频"，否则一律快进（横向偏置，抗误判）
            return abs(d.x) * 1.5 >= abs(d.y)
        }

        // 手势互斥：Pan 已激活（横向快进）→ 独占，不允许 ScrollView 同时响应
        // Pan 被拒绝（竖向）→ 返回 true 让 ScrollView 接管分页
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer { return false }
            if let pg = pan, pg.state == .began || pg.state == .changed {
                return false   // 横向导航/拖进度，独占
            }
            return true        // Pan 还没开始或已结束，让 ScrollView 自由分页
        }
    }
}

#if DEBUG
/// UI regression evidence for a hold that might start and end within one drag.
/// Excluded from the installable Release app.
@Observable final class DYGestureDiagnostics {
    static let shared = DYGestureDiagnostics()
    var boostStarts = 0
}
#endif

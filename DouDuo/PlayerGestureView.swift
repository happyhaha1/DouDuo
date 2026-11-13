import SwiftUI
import UIKit

/// 按住加速期间，由播放页向外层顶栏传递清屏状态。
struct DYPlaybackPressKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension EnvironmentValues {
    /// 本次浏览会话的清屏开关，翻页保留；详情播放器独立持有。
    @Entry var dyClearScreen: Binding<Bool> = .constant(false)
}

// 单击/双击留在画面层；长按挂在窗口上，并按宿主的可见区域过滤触摸，覆盖同页的操作按钮。
// 进度条独立处理拖动，不注册全屏横滑跳转。
struct PlayerGestureView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (CGFloat, CGFloat) -> Void
    var onLongPress: (Bool) -> Void
    var onLongPressLock: () -> Void = {}
    var onLongPressUnlock: () -> Void = {}
    var enabled = true
    var topExclusion: CGFloat = 0
    var bottomExclusion: CGFloat = 64

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        let c = context.coordinator
        c.view = v
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = 0.5
        // 长按期间要跟手指：上/下滑 50pt 才判定锁定/解锁，按下过程中轻微漂移不能取消长按
        long.allowableMovement = .greatestFiniteMagnitude
        long.delegate = c
        c.long = long

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingle(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        // 长按识别成功后，这一轮触摸不会再落到暂停或双击上。
        single.require(toFail: long)
        double.require(toFail: long)
        single.require(toFail: double)
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
        private var pressStartY: CGFloat = 0
        private var pressLocked = false
        private var pressing = false
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
                parent.onLongPress(true)
            case .changed:
                let dy = g.location(in: view).y - pressStartY
                if !pressLocked, abs(dy) > 50 {
                    pressLocked = true
                    feedback.impactOccurred()
                    if dy > 0 { parent.onLongPressLock() } else { parent.onLongPressUnlock() }
                }
            case .ended, .cancelled, .failed:
                finishPress()
            default: break
            }
        }

        func finishPress() {
            frozenScroll?.panGestureRecognizer.isEnabled = scrollWasEnabled
            frozenScroll = nil
            pressLocked = false
            longActive = false
            guard pressing else { return }
            pressing = false
            lastLongEnd = Date()
            parent.onLongPress(false)
        }
    }
}

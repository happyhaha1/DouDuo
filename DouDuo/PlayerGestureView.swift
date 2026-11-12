import SwiftUI
import UIKit

// MARK: - UIKit 手势宿主：单击/双击/长按 + 左缘右滑退出
// 横滑快进已移除：进度跳转只认底部进度条（进度条自己带 DragGesture），画面上的横滑不再改进度。
// 纯 SwiftUI 的 .gesture/.simultaneousGesture 会吞掉整段手势序列导致竖滑分页失效，
// 所以这些手势仍下沉到 UIKit，竖滑漏给外层 ScrollView 分页切视频。
struct PlayerGestureView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (CGFloat, CGFloat) -> Void          // (触点x, 宽度)
    var onLongPress: (Bool) -> Void                       // pressing
    /// 小红书同款：长按 2 倍速后手指下滑一段 → 锁定 2 倍速（松手也不恢复）
    var onLongPressLock: () -> Void = {}
    /// 长按后手指上滑一段 → 取消锁定、恢复 1 倍
    var onLongPressUnlock: () -> Void = {}
    var onEdgeChanged: (CGFloat) -> Void = { _ in }        // 左缘右滑过程中：位移跟手
    var onEdgeEnded: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }  // 松手：(位移, 横向速度, 屏宽)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let c = context.coordinator
        c.view = v

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingle(_:)))
        single.numberOfTapsRequired = 1

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)

        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = 0.5
        // 长按期间要能跟手指：上/下滑 50pt 才判定锁定/解锁（原来 12pt 就取消长按，导致锁不上 2 倍速）
        long.allowableMovement = .greatestFiniteMagnitude
        c.long = long

        // 屏幕左缘右滑退出（系统级边缘手势，只在最左 ~20pt 触发，不抢中间区域）
        let edge = UIScreenEdgePanGestureRecognizer(target: c, action: #selector(Coordinator.handleEdge(_:)))
        edge.edges = .left
        c.edge = edge

        v.addGestureRecognizer(single)
        v.addGestureRecognizer(double)
        v.addGestureRecognizer(long)
        v.addGestureRecognizer(edge)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self   // 刷新闭包，回调读到最新 @State
    }

    final class Coordinator: NSObject {
        var parent: PlayerGestureView
        weak var view: UIView?
        weak var edge: UIScreenEdgePanGestureRecognizer?
        weak var long: UILongPressGestureRecognizer?
        private var pressStartY: CGFloat = 0
        private var pressLocked = false
        private weak var frozenScroll: UIScrollView?
        init(_ p: PlayerGestureView) { parent = p }

        @objc func handleSingle(_ g: UITapGestureRecognizer) { parent.onSingleTap() }

        @objc func handleDouble(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            parent.onDoubleTap(g.location(in: v).x, v.bounds.width)
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                parent.onLongPress(true)
                pressStartY = g.location(in: view).y; pressLocked = false
                // 长按期间下滑不能触发外层切视频：先把外层 ScrollView 的滑动关掉，松手再恢复
                var p = view?.superview
                while let x = p, !(x is UIScrollView) { p = x.superview }
                if let sv = p as? UIScrollView { sv.panGestureRecognizer.isEnabled = false; frozenScroll = sv }
            case .changed:
                let dy = g.location(in: view).y - pressStartY
                if !pressLocked, abs(dy) > 50 {
                    pressLocked = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if dy > 0 { parent.onLongPressLock() } else { parent.onLongPressUnlock() }
                }
            case .ended, .cancelled, .failed:
                frozenScroll?.panGestureRecognizer.isEnabled = true; frozenScroll = nil
                pressLocked = false
                parent.onLongPress(false)
            default: break
            }
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

        // 底部进度条在自己的 SwiftUI DragGesture 里接管拖拽；这里不再有全屏横滑快进。
    }
}

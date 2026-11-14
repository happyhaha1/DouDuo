import SwiftUI

/// Declaration order is also the system vertical tab bar's order.
enum DYMainTab: String, CaseIterable, Hashable {
    case mine = "我的", messages = "私信", home = "首页"
}

/// Let the system compress tabs before video actions when its shared vertical
/// column runs out of room. The expanded selector remains a native TabView.
struct DYSystemTabBar: ViewModifier {
    var hidden = false
    @AppStorage(DDChromeMode.key) private var mode = DDChromeMode.classic.rawValue
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *), mode == DDChromeMode.duoClassic.rawValue {
            content.toolbarVisibility(hidden ? .hidden : .visible, for: .tabBar)
                // 展开内屏冷启动时纵向空间还没量准，prefersToolbarItems 会让
                // 系统先压掉标签栏、只留工具栏按钮，等一次交互才恢复；
                // 因此互动胶囊必须留在列里，压缩时也不许整列为空。
                .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
                .toolbarBackgroundVisibility(.hidden, for: .bottomBar)
                // 内屏展开态冷启动时，系统会把底部选择器先折叠成小胶囊，
                // 要等一次交互才恢复；两种最小化接口都钉成 never。
                .tabBarMinimizeBehavior(.never)
                .toolbarMinimizationBehavior(.never, for: .tabBar)
        } else { content }
    }
}

/// The current video supplies its existing controls and callbacks; moving
/// these views into the toolbar must not create another player or data model.
struct DYActiveVideoActionsKey: PreferenceKey {
    static var defaultValue: DYVideoToolbarActions? { nil }

    static func reduce(value: inout DYVideoToolbarActions?, nextValue: () -> DYVideoToolbarActions?) {
        if let next = nextValue() { value = next }
    }
}

struct DYVideoToolbarActions {
    let avatarImage: UIImage?
    let authorName: String
    let onAuthor: () -> Void
    let follow: AnyView?
    let like: AnyView
    let comments: AnyView
    let collect: AnyView
    let share: AnyView
}

/// 经典布局在系统工具栏里画的那颗清屏按钮。经典以外的三种布局复用同一份实现，
/// 样式、无障碍标签和点击面积与经典完全一致。
@available(iOS 27.1, *)
struct DYCleanScreenButton: View {
    let isClean: Bool
    let action: () -> Void
    /// 竖栏与互动列里自己套一层玻璃圆（和相邻的模块入口、更多一致）；
    /// 系统工具栏里由系统提供背景，这里就不再加一层。
    var circled = false
    var iconFont: Font = .title3
    var tint: Color = .white

    var body: some View {
        Button(action: action) {
            if circled {
                Image(systemName: isClean ? "eye" : "eye.slash")
                    .font(iconFont)
                    .foregroundStyle(tint)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
                    .ddGlassCircle()
            } else {
                Image(systemName: isClean ? "eye" : "eye.slash")
                    .font(iconFont)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
            .accessibilityLabel(isClean ? "退出清屏" : "清屏")
            .accessibilityIdentifier("douyin.cleanScreen")
    }
}

@available(iOS 27.1, *)
struct DYNativeVideoActions: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let actions: DYVideoToolbarActions?
    /// 评论区/UP 主页展开时只收互动胶囊；眼睛必须留在列里，
    /// 否则整条工具栏为空，系统会把标签栏也一起收掉。
    var hidesActions = false
    let isClean: Bool
    let onToggleClean: () -> Void
    @State private var anchorFrame: CGRect = .zero
    @State private var windowHeight: CGFloat = 0
    private var slotHeight: CGFloat {
        guard !anchorFrame.isEmpty else { return 262 }
        return max(262, (windowHeight - anchorFrame.maxY - 112).rounded(.down))
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DYCleanScreenButton(isClean: isClean, action: onToggleClean)
                        .background(DYToolbarFrameReader { frame, height in
                            withTransaction(Transaction(animation: nil)) {
                                anchorFrame = frame
                                windowHeight = height
                            }
                        })
                }
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                // 眼睛是这条工具栏的稳定锚点：互动胶囊收起时也必须留在列里，
                // 否则整条列为空，系统会把标签栏一起压缩掉。
                // The stable clear-screen anchor is independent of this group's size.
                // A new item identity invalidates the native cached fitting size.
                ToolbarItem(id: "video-actions-\(Int(slotHeight))", placement: .bottomBar) {
                    if verticalEdge != nil, let actions {
                        VStack(spacing: 4) {
                            DYAuthorAvatarControl(image: actions.avatarImage, name: actions.authorName,
                                                  onAuthor: actions.onAuthor, follow: actions.follow)
                            actions.like
                            actions.comments
                            actions.collect
                            actions.share
                        }
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .frame(height: slotHeight, alignment: .bottom)
                        // 评论区常驻、清屏时内容让位但不改列高：列一空，
                        // 冷启动时系统会把标签栏一起压掉。
                        .opacity(hidesActions || isClean ? 0 : 1)
                        .allowsHitTesting(!hidesActions && !isClean)
                        .accessibilityHidden(hidesActions || isClean)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("douyin.video.actions")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                .hidden(actions == nil || verticalEdge == nil)
            }
            // Retain the last measured slot across navigation and sheets.
            // Resetting it would briefly expand the tabs on every return,
            // until the system lays out the anchor again.
    }
}
/// Standalone works have no tab selector. Keep Back separate from the compact
/// interaction capsule, so the system never turns the video actions into More.
@available(iOS 27.1, *)
struct DYStandaloneVideoActions: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let actions: DYVideoToolbarActions?
    let onBack: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("返回", systemImage: "chevron.backward", action: onBack)
                        .labelStyle(.iconOnly).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("douyin.list.back")
                }
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                ToolbarItem(placement: .bottomBar) {
                    if let actions {
                        VStack(spacing: 4) {
                            DYAuthorAvatarControl(image: actions.avatarImage, name: actions.authorName,
                                                  onAuthor: actions.onAuthor, follow: actions.follow)
                            actions.like
                            actions.comments
                            actions.collect
                            actions.share
                        }
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("douyin.video.actions")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                .hidden(actions == nil || verticalEdge == nil)
            }
    }
}

/// Keep the same avatar footprint before and after following, so changing
/// relationship state cannot resize the native toolbar or its collapsed tabs.
struct DYAuthorAvatarControl: View {
    let image: UIImage?
    let name: String
    let onAuthor: () -> Void
    let follow: AnyView?

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onAuthor) {
                Group {
                    if let image { Image(uiImage: image).renderingMode(.original) }
                    else { Image(systemName: "person.crop.circle").font(.title) }
                }
                .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("作者，" + name)
            .accessibilityIdentifier("douyin.author.avatar")
            if let follow {
                follow.frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: 44, height: 52)
    }
}

/// Measure our own toolbar host in window coordinates. SwiftUI's `.global`
/// space inside a toolbar is local to its separate hosting view.
private struct DYToolbarFrameReader: UIViewRepresentable {
    let onChange: (CGRect, CGFloat) -> Void
    func makeUIView(context: Context) -> FrameView {
        let view = FrameView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }
    func updateUIView(_ view: FrameView, context: Context) {
        view.onChange = onChange
    }

    final class FrameView: UIView {
        var onChange: ((CGRect, CGFloat) -> Void)?
        private var lastFrame: CGRect = .zero
        private var lastHeight: CGFloat = 0
        private var candidateFrame: CGRect = .zero
        private var displayLink: CADisplayLink?
        private lazy var observer = FrameObserver(view: self)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: observer, selector: #selector(FrameObserver.sample))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 10, preferred: 5)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        deinit { displayLink?.invalidate() }

        // A native toolbar can move its host without laying out our child.
        // Sample only this view's public window rectangle and publish changes
        // after it settles, not the intermediate frames of navigation animation.
        fileprivate func reportFrame() {
            guard let window else { return }
            let frame = convert(bounds, to: window)
            guard !frame.isEmpty, frame.minY >= 0, frame.maxY < window.bounds.height else { return }
            guard frame == candidateFrame else { candidateFrame = frame; return }
            let height = window.bounds.height
            guard frame != lastFrame || height != lastHeight else { return }
            lastFrame = frame
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.onChange?(frame, height) }
        }
    }

    private final class FrameObserver {
        weak var view: FrameView?
        init(view: FrameView) { self.view = view }
        @objc func sample() { view?.reportFrame() }
    }
}

/// Shared author status mark. Classic hides followed badges at its call site.
struct DYAuthorFollowMark: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let followed: Bool
    var busy = false
    var diameter: CGFloat = 14
    var symbolSize: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().fill(followed ? theme.status.success.color(for: scheme) : theme.status.danger.color(for: scheme))
            if !busy { Image(systemName: followed ? "checkmark" : "plus")
                .font(.system(size: symbolSize, weight: .heavy)).foregroundStyle(.white) }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
        // Flatten the solid badge before the native toolbar applies its glass
        // foreground treatment. The red fill must remain opaque over video.
        .drawingGroup()
        .overlay {
            if busy { ProgressView().controlSize(.mini).tint(.white) }
        }
    }
}

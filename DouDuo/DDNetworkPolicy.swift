// 省流模式与直播封面策略：短视频预载、播放缓冲、直播预览共用同一份判断。
// 网络状态只信 NWPathMonitor（蜂窝 / 受限网络），设置页可强制「始终开启」或「关闭」；
// 省流开启时只收紧自动预载与直播预览，手动保存、已开始播放的流不受影响。
import Foundation
import Network
import Combine
import os

/// 省流三档。原始值就是 UserDefaults 里保存的值，与设置页 Picker 的 tag 完全一致。
enum DDDataSaverMode: String, CaseIterable, Identifiable {
    case cellular
    case always
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cellular: return "仅蜂窝与受限网络"
        case .always: return "始终开启"
        case .off: return "关闭"
        }
    }

    var detail: String {
        switch self {
        case .cellular: return "蜂窝、热点与低数据模式生效，Wi‑Fi 下保持正常缓冲。"
        case .always: return "任何网络都按省流处理，适合流量卡或热点。"
        case .off: return "自动预载与缓冲按正常档位运行。"
        }
    }
}

/// UserDefaults 键与变化通知。放在全局 actor 之外，缓存 actor 与非主线程可直接读。
enum DDNetworkPolicyKeys {
    /// 省流三档，对应 `DDDataSaverMode.rawValue`
    static let mode = "douyin_data_saver_mode_v1"
    /// 直播列表只显示封面
    static let liveCoverOnly = "douyin_live_cover_only_v1"
    /// 变化通知：actor 与后台下载据此取消在飞的预载/预热。
    static let changed = Notification.Name("DDNetworkPolicy.changed")
}

/// 主线程写、任意线程读的只读快照：缓存 actor 与预热请求据此判断要不要让路。
/// 初始值保守取「省流」：第一次路径结果（或第一次设置读取）之前不许自动整条下载。
enum DDNetworkPolicySnapshot {
    /// 初始保守取省流；`DDNetworkPolicy` 初始化与每次路径回调都会成对写入。
    private static let state = OSAllocatedUnfairLock(initialState: (saving: true, deferred: true))

    static var isSavingData: Bool { state.withLock { $0.saving } }
    static var isPreviewDeferred: Bool { state.withLock { $0.deferred } }

    static func set(saving: Bool, deferred: Bool) {
        state.withLock { $0 = (saving, deferred) }
    }
}

/// 省流开关的唯一数据源：设置页只在 UserDefaults 里写两个键。
@MainActor
final class DDNetworkPolicy: ObservableObject {
    static let shared = DDNetworkPolicy()

    @Published private(set) var mode: DDDataSaverMode
    @Published private(set) var isSavingData: Bool
    @Published private(set) var liveCoverOnly: Bool
    /// 省流或「直播列表只显示封面」：直播间未进房时不自动拉流。
    @Published private(set) var isPreviewDeferred: Bool

    /// 供 actor / 后台线程读取，不跳主线程。
    nonisolated static var isSavingDataNow: Bool { DDNetworkPolicySnapshot.isSavingData }

    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "douyin.network-policy")
    private var defaultsObserver: NSObjectProtocol?
    /// `nil` = NWPathMonitor 还没给出第一条结果。此时按省流算，避免启动瞬间在蜂窝上先烧流量。
    private var pathSnapshot: (cellular: Bool, expensive: Bool, constrained: Bool)?
    private var lastNotified: (saving: Bool, deferred: Bool)?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: DDNetworkPolicyKeys.mode)
        let mode = DDDataSaverMode(rawValue: stored ?? "") ?? .cellular
        let coverOnly = defaults.object(forKey: DDNetworkPolicyKeys.liveCoverOnly) as? Bool ?? true
        let saving = Self.savesData(mode: mode, path: nil)
        self.mode = mode
        self.liveCoverOnly = coverOnly
        self.isSavingData = saving
        self.isPreviewDeferred = Self.defersPreview(savingData: saving, coverOnly: coverOnly)
        DDNetworkPolicySnapshot.set(saving: isSavingData, deferred: isPreviewDeferred)
        startMonitoring()
    }

    /// 回到前台时重读一次设置（设置页可能在别的窗口写过键）。
    func refresh() {
        reload()
    }

    // MARK: - 纯判断

    /// 省流是否生效，含「路径未知」这一档：模式不是关闭就一律保守省流，等第一条路径结果再放开。
    /// `cellular` 之外把系统的 expensive/constrained 也算进来，覆盖个人热点、低数据模式这些官方标成「贵」的连接。
    static func savesData(mode: DDDataSaverMode, path: (cellular: Bool, expensive: Bool, constrained: Bool)?) -> Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .cellular:
            guard let path else { return true }
            return path.cellular || path.expensive || path.constrained
        }
    }

    /// 直播是否停在封面：省流与「直播列表只显示封面」任一成立即不自动拉流。
    static func defersPreview(savingData: Bool, coverOnly: Bool) -> Bool {
        savingData || coverOnly
    }

    // MARK: - 状态同步

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            // NWPath 不跨线程送，先取布尔值再回主线程。
            let cellular = path.usesInterfaceType(.cellular)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.applyPath(cellular: cellular, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: monitorQueue)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func reload() {
        let stored = defaults.string(forKey: DDNetworkPolicyKeys.mode)
        let mode = DDDataSaverMode(rawValue: stored ?? "") ?? .cellular
        let coverOnly = defaults.object(forKey: DDNetworkPolicyKeys.liveCoverOnly) as? Bool ?? true
        if mode != self.mode { self.mode = mode }
        if coverOnly != liveCoverOnly { liveCoverOnly = coverOnly }
        publish()
    }

    private func applyPath(cellular: Bool, expensive: Bool, constrained: Bool) {
        pathSnapshot = (cellular, expensive, constrained)
        publish()
    }

    private func publish() {
        let saving = Self.savesData(mode: mode, path: pathSnapshot)
        let deferred = Self.defersPreview(savingData: saving, coverOnly: liveCoverOnly)
        if isSavingData != saving { isSavingData = saving }
        if isPreviewDeferred != deferred { isPreviewDeferred = deferred }
        DDNetworkPolicySnapshot.set(saving: saving, deferred: deferred)

        let current = (saving: saving, deferred: deferred)
        if let last = lastNotified, last == current { return }
        lastNotified = current
        NotificationCenter.default.post(name: DDNetworkPolicyKeys.changed, object: self)
    }
}

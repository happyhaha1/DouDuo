// 方向锁与「启动静音」的会话状态。
// 播放器/直播只读 `isStartupMuted`，与持久手动静音 `douyin_muted_v1` 做 OR；
// 这里绝不写回 `douyin_muted_v1`，也不改系统音量，避免覆盖用户以前的手动静音设置。
import AVFoundation
import Combine
import UIKit

@MainActor
final class DDPlaybackSession: ObservableObject {
    static let shared = DDPlaybackSession()

    enum Keys {
        /// 下次启动时静音（偏好，启动时读一次）
        static let startupMuted = "douyin_start_muted_v1"
        /// 系统音量实际变化时解除本次启动静音（默认开）
        static let volumeUnmutes = "douyin_volume_unmutes_v1"
        /// 持久手动静音。本类只读语义上对应的状态，永远不写这个键。
        static let persistentMuted = "douyin_muted_v1"
    }

    /// 当前是否锁定方向。只在本次运行内有效，重启回到解锁。
    /// 直接赋值也会同步窗口的旋转掩码；外部请优先用 `setOrientationLocked(_:)`。
    @Published var orientationLocked = false {
        didSet {
            guard oldValue != orientationLocked else { return }
            syncOrientationMask()
        }
    }

    /// 本次会话的启动静音。UI 手动解除或系统音量实际变化后变 false。
    @Published private(set) var isStartupMuted: Bool

    /// 当前生效的旋转掩码，供 AppDelegate 的 supportedInterfaceOrientationsFor 读取。
    private(set) var supportedInterfaceOrientations: UIInterfaceOrientationMask

    private let defaults: UserDefaults
    private var volumeObservation: NSKeyValueObservation?
    private var volumeBaseline: Float?
    private var refreshBaselineOnActivate = false
    private var observers: [NSObjectProtocol] = []
    private var lastKnownOrientation: UIInterfaceOrientation = .portrait

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.supportedInterfaceOrientations = Self.appSupportedOrientations
        // 只读「启动静音」偏好；手动静音仍旧由播放器自己读 douyin_muted_v1，这里既不读也不覆盖。
        self.isStartupMuted = defaults.bool(forKey: Keys.startupMuted)
        installObservers()
        if isStartupMuted {
            // 首次真正活跃时以当时系统音量重新校准，避免启动到前台之间的音量变化误触发。
            refreshBaselineOnActivate = true
            startVolumeUnmuteMonitor()
        }
    }

    // MARK: - 方向锁

    func setOrientationLocked(_ locked: Bool) {
        orientationLocked = locked
    }


    private func syncOrientationMask() {
        if orientationLocked {
            let current = currentInterfaceOrientation()
            lastKnownOrientation = current
            var mask = Self.mask(for: current).intersection(Self.appSupportedOrientations)
            if mask.isEmpty { mask = Self.appSupportedOrientations }
            supportedInterfaceOrientations = mask
        } else {
            // 解锁 = 回到 App 声明的全部方向，不额外指定某个方向。
            supportedInterfaceOrientations = Self.appSupportedOrientations
        }
        applyOrientationMask()
    }

    /// 只改旋转掩码与 scene 的方向偏好，不碰任何 frame/size，折叠分栏的 GeometryProxy 保持原样。
    private func applyOrientationMask() {
        guard let scene = targetWindowScene else { return }
        rootViewController(in: scene)?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let current = scene.effectiveGeometry.interfaceOrientation
        guard current != .unknown else { return }
        // 只有当前方向已经不被允许时才请求旋转；折叠/分屏改尺寸不会触发这里。
        guard !supportedInterfaceOrientations.contains(Self.mask(for: current)) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { _ in }
    }

    private var targetWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    private func rootViewController(in scene: UIWindowScene) -> UIViewController? {
        (scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)?.rootViewController
    }

    /// 锁住「当前 scene 的方向」。设备水平放置时 interfaceOrientation 仍是最后一次有效值；
    /// 万一拿到 unknown，再用窗口宽高推断，避免把横屏误锁成竖屏。
    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        guard let scene = targetWindowScene else { return lastKnownOrientation }
        let current = scene.effectiveGeometry.interfaceOrientation
        if current != .unknown {
            lastKnownOrientation = current
            return current
        }
        let bounds = (scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)?.bounds ?? .zero
        if bounds.width > bounds.height {
            return lastKnownOrientation.isLandscape ? lastKnownOrientation : .landscapeRight
        }
        if bounds.height > bounds.width {
            return lastKnownOrientation.isPortrait ? lastKnownOrientation : .portrait
        }
        return lastKnownOrientation
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .all
        }
    }

    /// 取 Info.plist 里当前 idiom 声明的方向（iPhone 不含倒置竖屏，iPad 含）。
    /// 解锁时回到这组方向，而不是硬编码 .all，避免声明外的方向被 delegate 放出去。
    private static let appSupportedOrientations: UIInterfaceOrientationMask = {
        let info = Bundle.main.infoDictionary ?? [:]
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let keys = isPad
            ? ["UISupportedInterfaceOrientations~ipad", "UISupportedInterfaceOrientations"]
            : ["UISupportedInterfaceOrientations"]
        var mask: UIInterfaceOrientationMask = []
        for key in keys {
            guard let raw = info[key] as? [String], !raw.isEmpty else { continue }
            for value in raw {
                switch value {
                case "UIInterfaceOrientationPortrait": mask.insert(.portrait)
                case "UIInterfaceOrientationPortraitUpsideDown": mask.insert(.portraitUpsideDown)
                case "UIInterfaceOrientationLandscapeLeft": mask.insert(.landscapeLeft)
                case "UIInterfaceOrientationLandscapeRight": mask.insert(.landscapeRight)
                default: break
                }
            }
            if !mask.isEmpty { break }
        }
        if mask.isEmpty { mask = isPad ? .all : .allButUpsideDown }
        return mask
    }()

    // MARK: - 启动静音

    /// UI 手动解除本次启动静音（保留持久手动静音）。
    func endStartupMute() {
        guard isStartupMuted else { return }
        isStartupMuted = false
        volumeObservation?.invalidate()
        volumeObservation = nil
        volumeBaseline = nil
    }

    private var volumeUnmutes: Bool {
        (defaults.object(forKey: Keys.volumeUnmutes) as? Bool) ?? true
    }

    private func startVolumeUnmuteMonitor() {
        guard isStartupMuted, volumeUnmutes, volumeObservation == nil else { return }
        let audioSession = AVAudioSession.sharedInstance()
        // 只记录基准值，不设置系统音量；首次观察回调会被 .new 选项过滤掉。
        volumeBaseline = audioSession.outputVolume
        volumeObservation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.handleOutputVolume(value) }
        }
    }

    private func handleOutputVolume(_ value: Float) {
        guard isStartupMuted, volumeUnmutes else { return }
        // 非前台期间（锁屏/切走/控制中心）的按键不算；回前台时以当时音量重新做基准。
        guard UIApplication.shared.applicationState == .active else {
            volumeBaseline = value
            refreshBaselineOnActivate = true
            return
        }
        guard let base = volumeBaseline else {
            volumeBaseline = value
            return
        }
        guard abs(value - base) > 0.001 else { return }
        endStartupMute()
    }

    // MARK: - 设置同步与前后台

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBaselineOnActivate = true }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applicationBecameActive() }
        })
        // 设置页可能用 @AppStorage 直接写音量开关，这里把外部写入同步回会话状态。
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncFromDefaults() }
        })
    }

    private func applicationBecameActive() {
        guard isStartupMuted, volumeUnmutes else { return }
        if refreshBaselineOnActivate {
            refreshBaselineOnActivate = false
            volumeBaseline = AVAudioSession.sharedInstance().outputVolume
        }
        startVolumeUnmuteMonitor()
    }

    private func syncFromDefaults() {
        if isStartupMuted {
            if volumeUnmutes { startVolumeUnmuteMonitor() }
            else {
                volumeObservation?.invalidate()
                volumeObservation = nil
                volumeBaseline = nil
            }
        }
    }

}


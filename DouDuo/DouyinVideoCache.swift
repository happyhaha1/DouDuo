// 本地视频缓存：
// - 正在播的这条：立刻开始缓存（长视频只缓存头部），划走就停
// - 后面 1–2 条：只预取头部，刷到时能本地起播
// - 完整缓存的条目下次刷到/重开 App 直接播本地
import Foundation
import UIKit

/// 浏览会话保存在 Application Support，不随视频缓存清理或系统回收而丢失。
struct DYFeedSession: Codable {
    var items: [DYAweme]
    var currentID: String
    var positions: [String: Double]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feed-session.json")
    }
    static func load() -> DYFeedSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Self.self, from: data),
              session.items.contains(where: { $0.id == session.currentID }) else { return nil }
        return session
    }
    func save() {
        guard items.contains(where: { $0.id == currentID }),
              let data = try? JSONEncoder().encode(self) else { return }
        do { try data.write(to: Self.url, options: .atomic) }
        catch { DYLiveModel.log("DDSESSION 保存失败 \(error.localizedDescription)") }
    }
}

/// 会话落盘节流器：把 200ms 内的多次保存合并成一次，JSON 编码与写文件都放到串行后台队列。
/// 原来每次划走都在主线程编码最多 80 条作品 + 原子写文件，正好压在翻页动画上。
/// 只在主线程调用（schedule / flushNow 都是主线程触发）。
final class DYFeedSessionSaver: ObservableObject {
    private let queue = DispatchQueue(label: "douduo.feed.session.save", qos: .utility)
    private var pending: DispatchWorkItem?

    func schedule(_ session: DYFeedSession) {
        pending?.cancel()
        let work = DispatchWorkItem { session.save() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 切后台 / 退出前用：同步写完再返回，避免进程被挂起丢掉最后一次进度
    func flushNow(_ session: DYFeedSession) {
        pending?.cancel()
        pending = nil
        queue.sync { session.save() }
    }
}

actor DYVideoCache {
    static let shared = DYVideoCache()
    static let countKey = "douyin_cache_count_v2"
    static let defaultCount = 5
    /// 超过这个时长不整条下载，只缓存头部
    static let maxDuration: Double = 600
    /// 头部缓存字节数：约 6–20 秒（抖音码率 0.5–3 Mbps），够起播
    static let headBytes = 4_000_000
    /// 后面几条做整条预取（刷过来不卡的关键）。只留 1 条：整条下载会吃掉正在播那条的带宽，
    /// 滑到就播靠上面 DYPreloader 的 preroll，不靠预下载。
    static let headPrefetch = 1
    /// 保守按 3.2 Mbps 折算，宁可早一点切在线流，也不要播到没数据的尾部
    static let assumeBitsPerSecond: Double = 2_500_000
    static let maxBytes = 2 * 1024 * 1024 * 1024

    struct Entry: Codable {
        var aweme: DYAweme
        var watched: Bool
        var added: Double
        var bytes: Int
    }
    /// 头部缓存索引
    struct Head: Codable {
        var id: String
        var bytes: Int
        var added: Double
    }

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }
    nonisolated static var headIndexURL: URL { dir.appendingPathComponent("heads.json") }
    nonisolated static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).mp4") }
    nonisolated static func headURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).head") }

    nonisolated static var limit: Int {
        (UserDefaults.standard.object(forKey: countKey) as? Int) ?? defaultCount
    }

    /// 已经整条下完的本地文件
    nonisolated static func localURL(_ id: String) -> URL? {
        let f = fileURL(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// 头部缓存（够起播即可）
    nonisolated static func headFile(_ id: String) -> URL? {
        let f = headURL(id)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int, size > 120_000 else { return nil }
        return f
    }

    /// 头部缓存能安全播到的秒数（保守折算，留 1.5 秒余量）
    nonisolated static func headPlayableSeconds(_ id: String) -> Double? {
        guard let f = headFile(id),
              let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int else { return nil }
        let s = Double(size) * 8 / assumeBitsPerSecond - 2.0
        return s > 1 ? s : nil
    }

    /// 启动时用：缓存好、还没看过的，按加入顺序
    nonisolated static func pendingSnapshot() -> [DYAweme] {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list.filter { !$0.watched && localURL($0.aweme.id) != nil }.map(\.aweme)
    }

    /// 调试日志用（不要求精确）
    nonisolated(unsafe) static var activeDownloads = 0

    private var entries: [Entry]
    private var heads: [Head]
    private var job: Task<Void, Never>?
    private var jobID: String?
    private var failed: Set<String> = []
    /// async 方法里不直接引用 DYAweme 作为参数类型（该编译器在此处解析失败），改用它中转
    private var pending: [String: DYAweme] = [:]
    private let session: URLSession
    /// 省流开关变化时取消在飞的预载（省流下不该再拉整条）
    private var policyObserver: NSObjectProtocol?

    init() {
        let cfg = URLSessionConfiguration.default
        // 预取是"锦上添花"，不该跟正在起播的播放器抢带宽：串行一条一条下
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        if let d = try? Data(contentsOf: Self.indexURL), let list = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = list.filter { Self.localURL($0.aweme.id) != nil }
        } else {
            entries = []
        }
        if let d = try? Data(contentsOf: Self.headIndexURL), let list = try? JSONDecoder().decode([Head].self, from: d) {
            heads = list.filter { Self.headFile($0.id) != nil }
        } else {
            heads = []
        }

        policyObserver = NotificationCenter.default.addObserver(
            forName: DDNetworkPolicyKeys.changed, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.policyChanged() }
        }
    }

    /// 播放焦点变了：只预取「后面几条」，不动正在播的这一条。
    /// 以前先下 current：它和播放器拉的是同一个 CDN 地址，等于把同一条视频拉两遍，
    /// 起播最需要带宽的那几秒被后台下载抢走。预取窗口本身就覆盖了「迟早要播」的内容，
    /// 所以缓存覆盖率不变；只有列表末尾（后面没有可预取的）才回落到缓存当前条。
    func focus(current: DYAweme?, ahead: [DYAweme]) {
        guard Self.limit > 0 else { job?.cancel(); job = nil; jobID = nil; return }
        // 省流：一条都不下；起播靠播放器自己的 1 秒缓冲，预热交给 AVPlayer 预载
        if DDNetworkPolicy.isSavingDataNow {
            stopCaching()
            return
        }
        let follow = Array(ahead.prefix(Self.headPrefetch))
        let target = follow.isEmpty ? current : nil
        guard target != nil || !follow.isEmpty else { return }
        let jobKey = target?.id ?? follow.map(\.id).joined(separator: ",")
        if jobID == jobKey, job != nil { return }
        job?.cancel()
        job = nil
        jobID = jobKey
        if let target { pending[target.id] = target }
        for a in follow { pending[a.id] = a }
        job = Task { [weak self] in
            guard let self else { return }
            if let target { await self.store(id: target.id) }
            for a in follow {
                if Task.isCancelled { return }
                await self.store(id: a.id)
            }
        }
    }

    /// 划走 / 离开：立刻停止缓存
    func stopCaching() {
        job?.cancel(); job = nil; jobID = nil
    }

    /// 省流打开就立刻停掉在飞的整条下载；关掉后由下一次 focus 重新排队。
    private func policyChanged() {
        guard DDNetworkPolicy.isSavingDataNow else { return }
        stopCaching()
    }

    /// 只缓存整条视频：不再存「头部」，也就没有「头部播完接在线流」那一下切换
    /// （切换必然有一瞬闪烁/缓冲，长痛不如短痛）
    private func store(id: String) async {
        // 省流下一条都不下：策略刚切换时这里立刻退出，别把整条拉下来
        guard !DDNetworkPolicy.isSavingDataNow else { return }
        guard let a = pending[id], a.images.isEmpty, a.play != nil else { return }
        if Self.localURL(a.id) != nil { return }
        if failed.contains(a.id) { return }
        // 超长的视频整条太大，干脆不缓存，直接走在线流（不会闪，只是首帧慢一点）
        guard a.duration <= Self.maxDuration else { return }
        if Task.isCancelled { return }
        await storeFull(id: id)
    }

    /// 头部缓存：Range 请求前 2.5MB（服务端忽略 Range 返回整条时截取前段）
    /// 抖音直连 CDN 的 play 地址对 App 自己的请求会 403（播放器能播）；
    /// 实测 `/aweme/v1/play/`（带 sign，302 跳 CDN）和 playFast 可以正常下载。
    private func downloadURLs(_ a: DYAweme) -> [URL] {
        [a.playAlt, a.playFast, a.play].compactMap { $0 }.compactMap { URL(string: $0) }
    }

    private func storeHead(id: String) async {
        guard let a = pending[id] else { return }
        let t0 = Date()
        Self.activeDownloads = 1
        defer { Self.activeDownloads = 0 }
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            var r = URLRequest(url: u)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("bytes=0-\(Self.headBytes - 1)", forHTTPHeaderField: "Range")
            do {
                let (data, resp) = try await session.data(for: r)
                guard let h = resp as? HTTPURLResponse else { continue }
                guard h.statusCode == 200 || h.statusCode == 206 else {
                    DYLiveModel.log("DDHEAD status=\(h.statusCode) host=\(u.host ?? "-") id=\(a.id)")
                    continue
                }
                let slice = data.count > Self.headBytes ? data.prefix(Self.headBytes) : data
                guard slice.count > 120_000 else { continue }
                try slice.write(to: Self.headURL(a.id))
                heads.removeAll { $0.id == a.id }
                heads.append(Head(id: a.id, bytes: slice.count, added: Date().timeIntervalSince1970))
                let cap = max(Self.limit * 2, 40)
                if heads.count > cap { heads.removeFirst(heads.count - cap) }
                saveHeads()
                DYLiveModel.log("DDHEAD ok \(a.id) \(slice.count / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                return
            } catch {
                DYLiveModel.log("DDHEAD fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
        if !Task.isCancelled { failed.insert(a.id) }
    }

    /// 整条缓存（≤300 秒的视频才做；划走会取消，头部缓存已留下）
    private func storeFull(id: String) async {
        guard let a = pending[id] else { return }
        let t0 = Date()
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            var r = URLRequest(url: u)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            do {
                let (tmp, resp) = try await session.download(for: r)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                    DYLiveModel.log("DDCACHE status=\(h.statusCode) host=\(u.host ?? "-") id=\(a.id)")
                    continue
                }
                let dst = Self.fileURL(a.id)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int) ?? 0
                guard bytes > 50_000 else { try? FileManager.default.removeItem(at: dst); continue }
                entries.removeAll { $0.aweme.id == a.id }
                entries.append(Entry(aweme: a, watched: false, added: Date().timeIntervalSince1970, bytes: bytes))
                evict()
                save()
                DYLiveModel.log("DDCACHE ok \(a.id) \(bytes / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
                return
            } catch {
                DYLiveModel.log("DDCACHE fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
        if !Task.isCancelled { failed.insert(a.id) }
    }

    func markWatched(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.aweme.id == id }), !entries[i].watched else { return }
        entries[i].watched = true
        save()
    }

    func usage() -> (count: Int, bytes: Int) {
        (entries.count + heads.count, entries.reduce(0) { $0 + $1.bytes } + heads.reduce(0) { $0 + $1.bytes })
    }

    func clear() -> Int {
        let bytes = entries.reduce(0) { $0 + $1.bytes } + heads.reduce(0) { $0 + $1.bytes }
        job?.cancel(); job = nil; jobID = nil
        entries = []; heads = []
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        return bytes
    }

    /// 超上限：先删看过的（最早的先删），还超就删最早加进来的
    private func evict() {
        let lim = max(Self.limit, 0)
        while entries.count > lim || (entries.count > 1 && entries.reduce(0, { $0 + $1.bytes }) > Self.maxBytes) {
            let idx = entries.firstIndex(where: \.watched) ?? 0
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id))
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
    private func saveHeads() {
        if let d = try? JSONEncoder().encode(heads) { try? d.write(to: Self.headIndexURL, options: .atomic) }
    }
}

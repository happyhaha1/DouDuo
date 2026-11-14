import SwiftUI

struct DDVideoQuality: Codable, Equatable, Identifiable, Sendable {
    let url: String
    let alternate: String?
    let height: Int
    let bitrate: Int
    let isHEVC: Bool
    var id: String { url }
    var title: String {
        let resolution = height > 0 ? "\(height)p" : "原始画质"
        return bitrate > 0 ? "\(resolution) · \(bitrate / 1000) kbps" : resolution
    }
}

enum DDVideoQualityPolicy {
    static let defaultKey = "douyin_video_quality_v1"

    static func select(_ item: DYAweme, preference: String, savingData: Bool) -> DDVideoQuality? {
        let sources = item.qualitySources ?? []
        if let explicit = sources.first(where: { $0.url == preference }) { return explicit }
        if preference == "low" || (preference == "auto" && savingData) {
            if let low = sources.min(by: { $0.bitrate < $1.bitrate }) { return low }
            if let url = item.playFast ?? item.play {
                return DDVideoQuality(url: url, alternate: item.playAlt, height: 0, bitrate: 0, isHEVC: false)
            }
        }
        if let original = sources.first(where: { $0.url == item.play }) { return original }
        guard let url = item.play else { return nil }
        return DDVideoQuality(url: url, alternate: item.playAlt,
                              height: Int(min(item.width, item.height)), bitrate: 0, isHEVC: false)
    }
}

enum DDRecommendationTimeFilter {
    static let unitKey = "douyin_recent_unit_v1"
    static let valueKey = "douyin_recent_value_v1"
    static let undatedKey = "douyin_recent_undated_v1"

    static func includes(_ publishedAt: TimeInterval?, unit: String, value: Int,
                         includeUndated: Bool, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard unit == "days" || unit == "months" else { return true }
        guard let publishedAt, publishedAt.isFinite, publishedAt > 0,
              publishedAt <= now.timeIntervalSince1970 else { return includeUndated }
        let component: Calendar.Component = unit == "months" ? .month : .day
        let limit = unit == "months" ? 24 : 365
        guard let start = calendar.date(byAdding: component, value: -min(max(1, value), limit), to: now) else { return true }
        return publishedAt >= start.timeIntervalSince1970
    }
}

enum DDChromeGroup: String, CaseIterable, Identifiable {
    case top, controls, author, information, progress
    var id: String { rawValue }
    var key: String { "douyin_opacity_\(rawValue)_v1" }
    var title: String {
        switch self {
        case .top: return "顶部标签与模块入口"
        case .controls: return "侧边操作按钮"
        case .author: return "作者信息"
        case .information: return "作品描述与配乐"
        case .progress: return "播放时间与进度"
        }
    }
}

struct DDChromeOpacity: ViewModifier {
    @AppStorage private var value: Double
    var active: Bool
    init(_ group: DDChromeGroup, active: Bool = true) {
        _value = AppStorage(wrappedValue: 1.0, group.key)
        self.active = active
    }
    func body(content: Content) -> some View {
        content.opacity(active ? min(max(value, 0.1), 1) : 1)
    }
}

private struct DDOpacitySetting: View {
    let group: DDChromeGroup
    @AppStorage private var value: Double
    init(_ group: DDChromeGroup) {
        self.group = group
        _value = AppStorage(wrappedValue: 1.0, group.key)
    }
    var body: some View {
        DDPercentSlider(title: group.title, value: $value)
            .accessibilityIdentifier("douyin.personalization.opacity.\(group.rawValue)")
    }
}

private struct DDPercentSlider: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0.1...1, step: 0.05) { Text(title) }
                .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
        }
    }
}

struct DDPlaybackPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("douyin_data_saver_mode_v1") private var saver = "cellular"
    @AppStorage("douyin_live_cover_only_v1") private var liveCoverOnly = true
    @AppStorage(DDVideoQualityPolicy.defaultKey) private var quality = "auto"
    @AppStorage("douyin_start_muted_v1") private var startMuted = false
    @AppStorage("douyin_volume_unmutes_v1") private var volumeUnmutes = true
    @AppStorage("douyin_hide_status_bar_v1") private var hideStatusBar = false
    @AppStorage("douyin_show_music_v1") private var showMusic = true
    @AppStorage("douyin_show_publication_v1") private var showPublication = true
    @AppStorage("douyin_danmaku_v1") private var danmaku = true
    @AppStorage("douyin_danmaku_font_size_v1") private var danmakuSize = 15.0
    @AppStorage("douyin_danmaku_lines_v1") private var danmakuLines = 0
    @AppStorage("douyin_danmaku_opacity_v1") private var danmakuOpacity = 0.92
    @AppStorage("douyin_danmaku_in_clear_v1") private var danmakuInClear = true
    @AppStorage(DDRecommendationTimeFilter.unitKey) private var recentUnit = "off"
    @AppStorage(DDRecommendationTimeFilter.valueKey) private var recentValue = 7
    @AppStorage(DDRecommendationTimeFilter.undatedKey) private var includeUndated = true
    @ObservedObject private var network = DDNetworkPolicy.shared
    @ObservedObject private var session = DDPlaybackSession.shared
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("省流模式", selection: $saver) {
                        Text("仅蜂窝与受限网络").tag("cellular")
                        Text("始终开启").tag("always")
                        Text("关闭").tag("off")
                    }
                    .accessibilityIdentifier("douyin.personalization.dataSaver")
                    Label(network.isSavingData ? "省流已开启" : "当前使用正常缓冲", systemImage: network.isSavingData ? "leaf" : "wifi")
                        .foregroundStyle(.secondary)
                    Toggle("直播列表只显示封面", isOn: $liveCoverOnly)
                    Picker("默认短视频画质", selection: $quality) {
                        Text("自动（跟随省流）").tag("auto")
                        Text("最高画质").tag("best")
                        Text("省流画质").tag("low")
                    }
                } header: { Text("网络与画质") } footer: {
                    Text("省流时停止整条自动预下载，仅预热下一条开头，优先低码率。可在视频「更多 → 画质」单独提高清晰度；手动下载不受影响。直播进入房间后才拉流。")
                }
                Section {
                    ForEach(DDChromeGroup.allCases) { DDOpacitySetting($0) }
                    Toggle("隐藏系统状态栏", isOn: $hideStatusBar)
                } header: { Text("分组透明度") } footer: {
                    Text("10%–100%，保存后即时生效。清屏仍保留半透明信息、可拖进度与退出按钮；退出按钮始终可见。")
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle").modifier(DDChromeOpacity(.author))
                        Text("作者信息").modifier(DDChromeOpacity(.author))
                        Text("作品描述预览").modifier(DDChromeOpacity(.information))
                    }.padding(.vertical, 8)
                }
                Section("横屏与声音") {
                    Toggle("锁定当前屏幕方向", isOn: Binding(get: { session.orientationLocked }, set: { session.setOrientationLocked($0) }))
                    Toggle("下次启动时静音", isOn: $startMuted)
                    Toggle("系统音量变化时解除启动静音", isOn: $volumeUnmutes)
                    if session.isStartupMuted {
                        Button("解除本次启动静音") { session.endStartupMute() }
                    }
                    Text("仅解除本次启动静音，保留手动静音设置。系统音量已在上限或下限、音量没有实际变化时，请手动解除。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("弹幕与作品信息") {
                    Toggle("显示弹幕", isOn: $danmaku)
                    HStack {
                        Text("弹幕字号")
                        Spacer()
                        Text("\(Int(danmakuSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $danmakuSize, in: 10...28, step: 1) { Text("弹幕字号") }
                        .accessibilityIdentifier("douyin.personalization.danmakuSize")
                    Picker("弹幕行数", selection: $danmakuLines) {
                        Text("自动").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0) 行").tag($0) }
                    }
                    DDPercentSlider(title: "弹幕透明度", value: $danmakuOpacity)
                    Toggle("清屏时保留弹幕", isOn: $danmakuInClear)
                    Toggle("显示发布时间", isOn: $showPublication)
                    Toggle("显示配乐文字", isOn: $showMusic)
                    Text("弹幕仍限制在画面上方三分之一；大字号时自动减少行数，避免重叠。隐藏配乐文字不会关闭声音。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Picker("发布时间范围", selection: $recentUnit) {
                        Text("不限").tag("off")
                        Text("最近若干天").tag("days")
                        Text("最近若干月").tag("months")
                    }.accessibilityIdentifier("douyin.personalization.recent")
                    if recentUnit != "off" {
                        Stepper("最近 \(recentValue) \(recentUnit == "months" ? "个月" : "天")", value: $recentValue,
                                in: 1...(recentUnit == "months" ? 24 : 365))
                        Toggle("保留没有发布时间的作品", isOn: $includeUndated)
                    }
                } header: { Text("推荐时间筛选") } footer: {
                    Text("只筛后续推荐，当前视频与播放进度保留。关注、搜索、收藏等列表不受影响；筛选过窄时可放宽范围。")
                }
                Section {
                    Button("恢复本页默认设置", role: .destructive) { confirmReset = true }
                        .accessibilityIdentifier("douyin.personalization.reset")
                }
            }
            .navigationTitle("个性化与播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: recentUnit) { _, unit in recentValue = min(max(1, recentValue), unit == "months" ? 24 : 365) }
            .confirmationDialog("恢复本页默认设置？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("恢复默认", role: .destructive, action: reset)
            } message: { Text("只恢复本页选项，保留账号、缓存、倍速和界面模式。") }
        }
    }

    private func reset() {
        saver = "cellular"; liveCoverOnly = true; quality = "auto"
        startMuted = false; volumeUnmutes = true
        hideStatusBar = false; showMusic = true; showPublication = true
        danmaku = true; danmakuSize = 15; danmakuLines = 0; danmakuOpacity = 0.92; danmakuInClear = true
        recentUnit = "off"; recentValue = 7; includeUndated = true
        session.setOrientationLocked(false)
        session.endStartupMute()
        for group in DDChromeGroup.allCases { UserDefaults.standard.set(1.0, forKey: group.key) }
    }
}

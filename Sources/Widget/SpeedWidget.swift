import Foundation
import SwiftUI
import WidgetKit

/// 同一个 systemSmall 小组件同时服务：iPhone 桌面 / 锁屏 / StandBy /
/// iOS 26 CarPlay Dashboard。工程上只有这一份代码。
///
/// 界面定义（用户要求）：极度纯粹，整个画面只有速度数值，
/// 用自绘标准 7 段数码管显示，字号按可用空间撑到最大，
/// 0~60 绿 / 61~100 黄 / >100 红（见 Sources/Shared/SevenSegment.swift）。
/// 不放标题、单位、档位、时间戳、实时/快照等任何文字。
///
/// ⚠️ CarPlay 适配要点（WWDC25-216）：
///   · 必须支持 .systemSmall —— CarPlay 只取这个 family
///   · 不要设置 .disfavoredLocations([.carPlay])，否则会被归到「未优化」且禁用交互
///   · 数据不能用 protection class A/B（见 SharedSpeedStore）
///
/// 不冒充实时：数据过期 / 为快照时，数字整体降到 55% 不透明度；
/// 完整状态写在 accessibility label / value 里（VoiceOver 与车机朗读可读）。
/// 若希望有一个肉眼可辨的状态标记，把 SevenSegmentSpeedView 的
/// showsStatusDot 设为 true，会多一个 5pt 圆点（绿=实时、橙=快照）。
///
/// 实时性边界：
///   · 主 App 前台时 reloadTimelines 不计入 WidgetKit 预算 → 约 1~2 秒级
///   · 锁屏（CarPlay 常见状态）时退回带时间戳的快照，
///     此时 CarPlay 上的秒级实时由 SpeedLiveActivity 承担
struct SpeedEntry: TimelineEntry {
    let date: Date
    let snapshot: SpeedSnapshot?
    let hasSharedContainer: Bool
}

struct SpeedTimelineProvider: TimelineProvider {
    private let store = SharedSpeedStore.shared

    func placeholder(in context: Context) -> SpeedEntry {
        SpeedEntry(date: Date(), snapshot: SpeedSnapshot(
            speed: 88, speedText: "88", unit: "KM/H", gearLabel: "D",
            connected: true, live: true, updatedAt: Date()
        ), hasSharedContainer: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedEntry) -> Void) {
        completion(SpeedEntry(date: Date(), snapshot: store.read(),
                             hasSharedContainer: store.hasSharedContainer))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedEntry>) -> Void) {
        let entry = SpeedEntry(date: Date(), snapshot: store.read(),
                               hasSharedContainer: store.hasSharedContainer)
        // 正常预算下的保守策略；主 App 前台时由 WidgetCenter.reloadTimelines 覆盖
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SpeedWidgetView: View {
    let entry: SpeedEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: SpeedSnapshot? { entry.snapshot }
    private var text: String { snapshot?.speedText ?? "--" }
    private var speed: Int? { snapshot?.speed }

    private var isLive: Bool {
        guard let snapshot = snapshot else { return false }
        return snapshot.live && snapshot.connected &&
               Date().timeIntervalSince(snapshot.updatedAt) <= 300
    }

    var body: some View {
        Group {
            if family == .accessoryInline {
                // inline 家族只能显示一行文字，无法容纳数码管图形
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(SpeedPalette.color(for: speed))
            } else {
                SevenSegmentSpeedView(
                    text: text,
                    speed: speed,
                    isLive: isLive,
                    showsStatusDot: false   // 改 true 可加一个 5pt 状态点
                )
                .padding(family == .systemSmall ? 8 : 12)
            }
        }
        .containerBackground(for: .widget) { Color(white: 0.03) }
    }
}

struct SpeedWidget: Widget {
    let kind = TSLConfig.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedTimelineProvider()) { entry in
            SpeedWidgetView(entry: entry)
        }
        .configurationDisplayName("TSL 车速")
        .description("纯粹的大号 7 段数码管车速；随速度自动切换绿 / 黄 / 红")
        .supportedFamilies([
            .systemSmall,          // ← CarPlay 必需
            .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
        // 注意：绝对不要加 .disfavoredLocations([.carPlay], for: [.systemSmall])。
    }
}

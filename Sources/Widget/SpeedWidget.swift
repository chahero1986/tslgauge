import Foundation
import SwiftUI
import WidgetKit

/// 同一个 systemSmall 小组件同时服务：iPhone 桌面 / 锁屏 / StandBy /
/// iOS 26 CarPlay Dashboard。工程上只有这一份代码。
///
/// ⚠️ CarPlay 适配要点（WWDC25-216）：
///   · 必须支持 .systemSmall —— CarPlay 只取这个 family
///   · 不要设置 .disfavoredLocations([.carPlay])，否则会被归到「未优化」且禁用交互
///   · 用系统字体/颜色，文字一瞥可读；依赖 widgetContentMargins
///   · 数据不能用 protection class A/B（见 SharedSpeedStore）
///
/// 实时性边界：
///   · 默认受 WidgetKit 预算约束（约 15~60 分钟一次）
///   · 主 App 前台时 reloadTimelines 不计入预算 → SpeedRefreshDriver 会
///     逐帧刷新，可达约 1~2 秒级（视图本身仍有渲染节流）
///   · iPhone 锁屏（CarPlay 常见状态）时主 App 不再前台 → 退回带时间戳的快照，
///     此时 CarPlay 上的秒级实时由 SpeedLiveActivity 承担
///
/// Target membership：仅 Widget Extension（SharedSpeedStore 需两个 target）。
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

    var body: some View {
        let snapshot = entry.snapshot
        let stale = snapshot.map { Date().timeIntervalSince($0.updatedAt) > 300 } ?? true
        let live = snapshot?.live == true && snapshot?.connected == true && !stale

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                Text("TSL 车速")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.cyan)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(snapshot?.speedText ?? "--")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text(snapshot?.unit ?? "KM/H")
                    .font(.caption2)
            }

            if entry.hasSharedContainer {
                HStack(spacing: 4) {
                    Text(snapshot?.gearLabel ?? "-")
                    Text("·")
                    Text(live ? "实时" : "快照")
                        .foregroundStyle(live ? .green : .orange)
                    Spacer()
                    if let date = snapshot?.updatedAt {
                        Text(date, style: .time)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                // 自签工具未提供 App Group 时的降级：不冒充有数据
                Text("打开 App 查看实时车速")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .containerBackground(for: .widget) { Color(white: 0.06) }
    }
}

struct SpeedWidget: Widget {
    let kind = TSLConfig.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedTimelineProvider()) { entry in
            SpeedWidgetView(entry: entry)
        }
        .configurationDisplayName("TSL 车速")
        .description("桌面与 CarPlay 上显示车速；锁屏时以带时间戳的快照呈现")
        .supportedFamilies([
            .systemSmall,          // ← CarPlay 必需
            .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
        // iOS 17+ 如 Xcode 支持，可追加 .containerBackgroundRemovable(true)
        // 让 CarPlay 去掉容器背景；不同 SDK 版本 API 略有差异，报错就删掉。
        // 注意：绝对不要加 .disfavoredLocations([.carPlay], for: [.systemSmall])。
    }
}

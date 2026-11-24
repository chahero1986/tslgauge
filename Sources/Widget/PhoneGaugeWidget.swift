import Foundation
import SwiftUI
import WidgetKit

/// 小组件 3「TSL 手机仪表」——完全依赖 iPhone 自身传感器，不连车辆。
///
/// 用户定稿布局（仅 .systemSmall，CarPlay Dashboard 原生槽位）：
///   左上：海拔（如 128 m）      右上：坡度（如 坡 +3.2°）
///   上方居中：航向八方向（如 东北 NE）
///   正中：7 段码速度，尽量铺满（0~60 绿 / 61~100 黄 / >100 红，规则不变）
///   下方居中：纵向 G（如 +0.35 G，中性灰，不加颜色规则）
///
/// 数据由主 App 的 PhoneSensorManager 写入 SharedPhoneGaugeStore，
/// 本 Extension 只读取渲染；无 App Group / 数据过期时显示 "--" 占位，
/// 不冒充实时。完整状态写进 accessibility 供 VoiceOver / 车机朗读。
struct PhoneGaugeEntry: TimelineEntry {
    let date: Date
    let snapshot: PhoneGaugeState?
    let hasSharedContainer: Bool
}

struct PhoneGaugeTimelineProvider: TimelineProvider {
    private let store = SharedPhoneGaugeStore.shared

    func placeholder(in context: Context) -> PhoneGaugeEntry {
        PhoneGaugeEntry(date: Date(), snapshot: .demo, hasSharedContainer: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PhoneGaugeEntry) -> Void) {
        completion(PhoneGaugeEntry(date: Date(), snapshot: store.read(),
                                   hasSharedContainer: store.hasSharedContainer))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneGaugeEntry>) -> Void) {
        let entry = PhoneGaugeEntry(date: Date(), snapshot: store.read(),
                                    hasSharedContainer: store.hasSharedContainer)
        // 主 App 前台时由 WidgetCenter.reloadTimelines 覆盖为秒级；
        // 这里给系统预算下的保守兜底（15 分钟后过期重建）。
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct PhoneGaugeWidgetView: View {
    let entry: PhoneGaugeEntry

    private var snapshot: PhoneGaugeState? { entry.snapshot }
    private var text: String { snapshot?.speedText ?? "--" }
    private var speed: Int? { snapshot?.speed }

    private var isLive: Bool {
        guard let snapshot = snapshot else { return false }
        return snapshot.valid && !SharedPhoneGaugeStore.shared.isStale(snapshot)
    }

    var body: some View {
        PhoneGaugeLayout(
            text: text,
            speed: speed,
            heading: snapshot?.headingLabel ?? "--",
            altitude: snapshot?.altitudeM,
            slope: snapshot?.slopeText ?? "坡 --",
            gText: snapshot?.gText ?? "-- G",
            isLive: isLive
        )
        .containerBackground(for: .widget) { Color(white: 0.03) }
    }
}

/// 小号布局：四角小字贴边，中央数码管尽量铺满。
private struct PhoneGaugeLayout: View {
    let text: String
    let speed: Int?
    let heading: String
    let altitude: Int?
    let slope: String
    let gText: String
    let isLive: Bool

    private var altitudeText: String {
        if let altitude = altitude { return "\(altitude) m" }
        return "-- m"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶行：海拔（左）· 航向（中）· 坡度（右）
            HStack(alignment: .top) {
                Text(altitudeText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(slope)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)

            // 正中：7 段码速度，把剩余空间全部吃掉
            SevenSegmentNumber(
                text: text,
                color: SpeedPalette.color(for: speed),
                inactiveColor: SpeedPalette.inactive(for: speed)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isLive ? 1.0 : 0.55)
            .padding(.vertical, 1)

            // 底行：纵向 G（居中，中性灰）
            Text(gText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.78))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("手机仪表车速 \(text)")
        .accessibilityValue("航向 \(heading)，\(altitudeText)，\(slope)，\(gText)，\(isLive ? "实时" : "快照")")
    }
}

struct PhoneGaugeWidget: Widget {
    let kind = TSLConfig.phoneGaugeWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PhoneGaugeTimelineProvider()) { entry in
            PhoneGaugeWidgetView(entry: entry)
        }
        .configurationDisplayName("TSL 手机仪表")
        .description("不连车辆：手机 GPS 速度 + 航向 + 海拔 + 坡度 + 纵向 G")
        .supportedFamilies([.systemSmall])   // CarPlay 只要小号
        // 刻意不做 CarPlay 位置降级配置，否则 CarPlay gallery 会被禁用
    }
}

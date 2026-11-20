import Foundation
import SwiftUI
import WidgetKit

/// 小组件 1「速度主仪表」（同时服务 iPhone 桌面 / 锁屏 / StandBy /
/// iOS 26 CarPlay Dashboard，工程上只有这一份代码）。
///
/// 用户定稿布局：
///   顶部：左档位（正常字体，P 红 / R 蓝 / N 白 / D 绿）·
///         中 AP 状态（开 = 蓝，关 = 灰「-」）·
///         右电量（≤20% 红 / 21~80% 绿 / >80% 白）
///   中部：左右居中的转向灯箭头（激活侧绿）+
///         大号 7 段码速度（0~60 绿 / 61~100 黄 / >100 红，规则不变）+
///         速度下方正常字体的融合限速（P 档 / 短帧显示 "--"）
///   底部：左车内温度 · 右环境温度（33 字节完整帧才有，否则 "--"）
///
/// ⚠️ CarPlay 适配要点（WWDC25-216）：
///   · 必须支持 .systemSmall —— CarPlay 只取这个 family
///   · 不要设置 .disfavoredLocations([.carPlay])，否则会被归到「未优化」且禁用交互
///   · 数据不能用 protection class A/B（见 SharedSpeedStore）
///
/// 不冒充实时：数据过期 / 为快照时数字降到 55% 不透明度；
/// 完整状态写在 accessibility label / value 里（VoiceOver 与车机朗读可读）。
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
            connected: true, live: true, updatedAt: Date(),
            extras: GaugeExtrasState.demo
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
            } else if family == .accessoryCircular || family == .accessoryRectangular {
                // 手表 / 配件位：保持纯数字
                SevenSegmentSpeedView(
                    text: text,
                    speed: speed,
                    isLive: isLive,
                    showsStatusDot: false
                )
                .padding(6)
            } else {
                // systemSmall（CarPlay 必需）与 systemMedium 共用布局
                SpeedGaugeLayout(
                    text: text,
                    speed: speed,
                    extras: snapshot?.extras,
                    isLive: isLive
                )
            }
        }
        .containerBackground(for: .widget) { Color(white: 0.03) }
    }
}

/// 小号（1×1）与中号（2×4）共用的速度主仪表布局。
/// 所有附加字段用正常字体（非 7 段码），主视觉仍是放大的数码管速度。
private struct SpeedGaugeLayout: View {
    let text: String
    let speed: Int?
    let extras: GaugeExtrasState?
    let isLive: Bool

    private var gearText: String {
        let label = extras?.gearLabel ?? "-"
        return label == "0" ? "-" : label
    }

    private var apActive: Bool { extras?.autoPilotLabel == "AP" }

    private var batteryText: String {
        guard let percent = extras?.batteryPercent, percent > 0, percent <= 100 else {
            return "--%"
        }
        return "\(percent)%"
    }

    private var limitText: String {
        if let limit = extras?.speedLimitKmh, limit > 0 { return "限速 \(limit)" }
        return "限速 --"
    }

    private var cabinText: String {
        if let v = extras?.cabinTempC { return "车内 \(Int(v.rounded()))°" }
        return "车内 --"
    }

    private var ambientText: String {
        if let v = extras?.ambientTempC { return "环境 \(Int(v.rounded()))°" }
        return "环境 --"
    }

    var body: some View {
        VStack(spacing: 3) {
            // 顶部：档位（左）· AP（中）· 电量（右）
            ZStack {
                HStack(alignment: .firstTextBaseline) {
                    Text(gearText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(GaugePalette.gearColor(gearText))
                    Spacer(minLength: 4)
                    Text(batteryText)
                        .font(.system(size: 18, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(GaugePalette.batteryColor(extras?.batteryPercent))
                }
                Text(apActive ? "AP" : "-")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(apActive ? GaugePalette.info : GaugePalette.dim)
            }
            .frame(height: 24)

            // 中部：转向灯（左右居中）+ 速度 + 限速
            ZStack {
                HStack(spacing: 0) {
                    TurnArrowShape(pointingLeft: true)
                        .fill(extras?.turnLeftActive == true ? GaugePalette.ok : GaugePalette.dim)
                        .frame(width: 14, height: 18)
                    Spacer(minLength: 0)
                    TurnArrowShape(pointingLeft: false)
                        .fill(extras?.turnRightActive == true ? GaugePalette.ok : GaugePalette.dim)
                        .frame(width: 14, height: 18)
                }
                VStack(spacing: 1) {
                    SevenSegmentNumber(
                        text: text,
                        color: SpeedPalette.color(for: speed),
                        inactiveColor: SpeedPalette.inactive(for: speed)
                    )
                    .frame(maxHeight: .infinity)
                    .opacity(isLive ? 1.0 : 0.55)
                    Text(limitText)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(
                            (extras?.speedLimitKmh ?? 0) > 0
                                ? Color(white: 0.92)
                                : Color(white: 0.40)
                        )
                }
            }
            .frame(maxHeight: .infinity)

            // 底部：车内温度（左）· 环境温度（右）
            HStack(alignment: .firstTextBaseline) {
                Text(cabinText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.78))
                Spacer(minLength: 4)
                Text(ambientText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.78))
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 340)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("车速 \(text)")
        .accessibilityValue(
            "\(gearText) 档 · 电量 \(batteryText) · \(limitText) · \(isLive ? "实时" : "快照")"
        )
    }
}

/// 转向灯箭头：实心三角形，指向左 / 右
private struct TurnArrowShape: Shape {
    let pointingLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        if pointingLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        path.closeSubpath()
        return path
    }
}

struct SpeedWidget: Widget {
    let kind = TSLConfig.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedTimelineProvider()) { entry in
            SpeedWidgetView(entry: entry)
        }
        .configurationDisplayName("TSL 车速")
        .description("大号 7 段码车速 + 档位 / 电量 / AP / 限速 / 转向灯 / 双温度")
        .supportedFamilies([
            .systemSmall,          // ← CarPlay 必需
            .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
        // 注意：绝对不要加 .disfavoredLocations([.carPlay], for: [.systemSmall])。
    }
}

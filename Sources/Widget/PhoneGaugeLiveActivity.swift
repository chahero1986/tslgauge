import SwiftUI
import WidgetKit
import ActivityKit

/// 小组件 3 的秒级实时载体：锁屏 / 灵动岛 / iOS 26 原厂 CarPlay Dashboard。
///
/// 与桌面小组件的区别（这是「切到桌面还能实时」的关键）：
///   · 桌面小组件 = WidgetKit 快照，后台刷新被系统限流，只能低频瞥一眼；
///   · Live Activity = 系统维持的展示面，主 App 后台也能用 activity.update 推数据，
///     不走 WidgetKit 刷新预算，因此秒级实时。
/// 数据由主 App 的 PhoneGaugeActivityController 本地推送（pushType: nil，无需 APNs）。
///
/// 后台诚实边界：CoreMotion / 气压计在后台停更，主 App 推送前会把坡度 / 纵向 G
/// 清空为 "--"，所以这里后台看到的姿态字段是 "--"，不是冻结的旧值。
struct PhoneGaugeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneGaugeActivityAttributes.self) { context in
            PhoneGaugeLockView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.headingLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(white: 0.92))
                        Text(context.state.slopeText)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.62))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        altitudeText(for: context.state.altitudeM)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.62))
                        Text(context.state.gText)
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.78))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        SevenSegmentNumber(
                            text: context.state.speedText,
                            color: SpeedPalette.color(for: context.state.speed),
                            inactiveColor: SpeedPalette.inactive(for: context.state.speed)
                        )
                        .frame(width: 96, height: 40)
                        Spacer()
                        Text(context.isStale ? "数据已过期" : "实时")
                            .foregroundStyle(context.isStale
                                ? Color.orange
                                : Color.secondary)
                            .font(.caption2)
                    }
                }
            } compactLeading: {
                Image(systemName: "location.fill")
                    .foregroundStyle(SpeedPalette.color(for: context.state.speed))
            } compactTrailing: {
                Text(context.state.speedText)
                    .monospacedDigit()
                    .foregroundStyle(SpeedPalette.color(for: context.state.speed))
            } minimal: {
                Text(context.state.speedText)
                    .monospacedDigit()
                    .foregroundStyle(SpeedPalette.color(for: context.state.speed))
            }
            .keylineTint(SpeedPalette.color(for: context.state.speed))
        }
    }

    private func altitudeText(for altitude: Int?) -> Text {
        if let altitude = altitude {
            return Text("\(altitude) m")
        }
        return Text("-- m")
    }
}

/// 锁屏 / CarPlay Dashboard 上的手机仪表：沿用桌面小组件的定稿布局。
/// 7 段码速度最大化 + 顶中航向 + 左上海拔 + 右上坡度 + 底中纵向 G。
private struct PhoneGaugeLockView: View {
    let context: ActivityViewContext<PhoneGaugeActivityAttributes>

    private var isLive: Bool {
        !context.isStale && context.state.valid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                altitudeText
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(context.state.headingLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)

                Text(context.state.slopeText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1)
            }

            SevenSegmentNumber(
                text: context.state.speedText,
                color: SpeedPalette.color(for: context.state.speed),
                inactiveColor: SpeedPalette.inactive(for: context.state.speed)
            )
            .frame(height: 84)
            .opacity(isLive ? 1.0 : 0.55)

            Text(context.state.gText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.78))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .activityBackgroundTint(Color(white: 0.03))
        .activitySystemActionForegroundColor(.white)
    }

    private var altitudeText: Text {
        if let altitude = context.state.altitudeM {
            return Text("\(altitude) m")
        }
        return Text("-- m")
    }
}

import SwiftUI
import WidgetKit
import ActivityKit

/// 秒级实时的主载体：锁屏 / 灵动岛 / iOS 26 原厂 CarPlay Dashboard。
///
/// · 数据由主 App 用 Activity.update 本地推送，pushType: nil，不需要 APNs
///   （免费个人 Team 没有 aps-environment，这是自签能跑通的关键）。
/// · iOS 26 起，iPhone 上一启动 Live Activity 就自动出现在 CarPlay Dashboard；
///   Dashboard 不可见时还会以车机底部通知形式出现（WWDC25-216）。
/// · 与桌面小组件共用同一套 7 段数码管 + 速度分段配色，车机看到的画面一致。
/// · staleDate 由主 App 设为 now+8s，BLE 断流后 context.isStale 自动变 true，
///   数字变暗 + 状态点变橙，避免拿旧车速冒充实时。
///
/// Target membership：仅 Widget Extension（数据契约在 SpeedAttributes.swift）。
struct SpeedLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            SpeedLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.gearLabel, systemImage: "speedometer")
                        .font(.caption)
                        .foregroundStyle(SpeedPalette.color(for: context.state.speed))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SevenSegmentNumber(
                        text: context.state.speedText,
                        color: SpeedPalette.color(for: context.state.speed),
                        inactiveColor: SpeedPalette.inactive(for: context.state.speed)
                    )
                    .frame(width: 82, height: 36)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.unit)
                        Text("·")
                        Text(context.state.updatedAt, style: .time)
                        Spacer()
                        Text(context.isStale ? "数据已过期" : "实时")
                            // 显式写 Color，避免 ?: 两端被推断成
                            // Color 与 HierarchicalShapeStyle 导致类型不一致编译失败
                            .foregroundStyle(context.isStale
                                ? Color.orange
                                : Color.secondary)
                    }
                    .font(.caption2)
                }
            } compactLeading: {
                Image(systemName: "speedometer")
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
}

/// 锁屏 / CarPlay Dashboard 上的纯速度界面：只有数码管数字，
/// 加一个 5pt 状态点区分实时与过期，不放任何其它文字。
private struct SpeedLockScreenView: View {
    let context: ActivityViewContext<SpeedActivityAttributes>

    private var isLive: Bool {
        !context.isStale && context.state.live && context.state.connected
    }

    var body: some View {
        SevenSegmentSpeedView(
            text: context.state.speedText,
            speed: context.state.speed,
            isLive: isLive,
            showsStatusDot: true
        )
        .frame(height: 92)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .activityBackgroundTint(Color(white: 0.03))
        .activitySystemActionForegroundColor(.white)
    }
}

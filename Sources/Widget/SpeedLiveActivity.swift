import SwiftUI
import WidgetKit
import ActivityKit

/// 秒级实时的主载体：锁屏 / 灵动岛 / iOS 26 CarPlay Dashboard。
///
/// · 数据由主 App 用 Activity.update 本地推送，pushType: nil，不需要 APNs
///   （免费个人 Team 没有 aps-environment，这是自签能跑通的关键）。
/// · iOS 26 起，iPhone 上一启动 Live Activity 就自动出现在 CarPlay Dashboard；
///   Dashboard 不可见时还会以车机底部通知形式出现（WWDC25-216）。
/// · staleDate 由主 App 设为 now+8s，BLE 断流后 context.isStale 自动变 true，
///   界面必须显示失效态，避免拿旧车速冒充实时。
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
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.speedText)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.unit)
                        Text("·")
                        Text(context.state.updatedAt, style: .time)
                        Spacer()
                        Text(context.isStale ? "数据已过期" : "实时")
                            .foregroundStyle(context.isStale ? .orange : .secondary)
                    }
                    .font(.caption2)
                }
            } compactLeading: {
                Image(systemName: "speedometer")
            } compactTrailing: {
                Text(context.state.speedText).monospacedDigit()
            } minimal: {
                Text(context.state.speedText).monospacedDigit()
            }
            .keylineTint(.cyan)
        }
    }
}

private struct SpeedLockScreenView: View {
    let context: ActivityViewContext<SpeedActivityAttributes>

    var body: some View {
        let invalid = context.isStale || !context.state.live || !context.state.connected

        HStack(spacing: 16) {
            Image(systemName: "speedometer")
                .font(.title2)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(context.state.speedText)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(context.state.unit)
                        .font(.caption)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(context.state.gearLabel)
                    .font(.title3)
                Text(invalid ? "数据已过期" : "实时")
                    .font(.caption2)
                    .foregroundStyle(invalid ? .orange : .green)
                Text(context.state.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .opacity(invalid ? 0.6 : 1)
        .activityBackgroundTint(Color(white: 0.06))
        .activitySystemActionForegroundColor(.white)
    }
}

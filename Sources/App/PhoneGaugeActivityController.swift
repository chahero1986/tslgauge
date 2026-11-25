import Foundation
import Combine
import ActivityKit
import UIKit

/// 手机仪表 Live Activity 控制器（仅主 App target）。
///
/// 全部本地更新（pushType: nil），不需要 APNs / aps-environment，
/// 免费个人 Team 自签（全能签）可用。与车辆速度的 SpeedActivityController 并行，
/// 两者是不同 attributes 类型的独立活动，互不覆盖。
///
/// 为什么这是「切到桌面后仍秒级」的唯一解：
///   Live Activity 由系统维持，主 App 在后台也能用 activity.update() 推新数据，
///   不经过 WidgetKit 的 reload 预算。桌面小组件做不到这一点。
@MainActor
final class PhoneGaugeActivityController {
    static let shared = PhoneGaugeActivityController()

    private let staleAfter: TimeInterval = 5
    private var activity: Activity<PhoneGaugeActivityAttributes>?

    /// 上车前打开一次 App 即可启动。App 重启后用 activities 找回已有活动续更。
    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let existing = Activity<PhoneGaugeActivityAttributes>.activities.first {
            activity = existing
            return
        }
        // Activity.request 只能在 App 前台调用
        guard UIApplication.shared.applicationState == .active else { return }

        let content = ActivityContent(
            state: PhoneGaugeState.empty,
            staleDate: Date().addingTimeInterval(staleAfter)
        )
        activity = try? Activity.request(
            attributes: PhoneGaugeActivityAttributes(),
            content: content,
            pushType: nil
        )
    }

    /// 由 PhoneSensorManager 每 1 秒调用。
    /// - Parameter inBackground: App 是否处于后台。后台时 CoreMotion / 气压计已停更，
    ///   坡度与纵向 G 是冻结的旧值，这里主动清空，避免冒充实时姿态。
    func update(_ state: PhoneGaugeState, inBackground: Bool) {
        guard let activity = activity else { return }
        let pushed = inBackground
            ? PhoneGaugeState(
                speed: state.speed,
                speedText: state.speedText,
                headingLabel: state.headingLabel,
                altitudeM: state.altitudeM,
                slopeText: "坡 --",
                gText: "-- G",
                valid: state.valid,
                updatedAt: state.updatedAt
            )
            : state
        let content = ActivityContent(
            state: pushed,
            staleDate: Date().addingTimeInterval(staleAfter)
        )
        Task { await activity.update(content) }
    }

    func end() {
        let current = activity
        activity = nil
        Task {
            await current?.end(
                ActivityContent(state: PhoneGaugeState.empty, staleDate: Date()),
                dismissalPolicy: .immediate
            )
        }
    }
}

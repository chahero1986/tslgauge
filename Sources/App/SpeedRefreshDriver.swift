import Foundation
import Combine
import UIKit
import WidgetKit
import ActivityKit

/// Live Activity 控制器（主 App target）。
/// 全部使用【本地更新】：pushType 传 nil，不需要 APNs / aps-environment，
/// 免费个人 Team 自签也能跑。
@MainActor
final class SpeedActivityController {
    static let shared = SpeedActivityController()

    private let staleAfter: TimeInterval = 8
    private var activity: Activity<SpeedActivityAttributes>?

    /// ⚠️ Activity.request 只能在 App 前台调用 → 上车前打开一次 App 即可。
    /// App 被重启后用 Activity.activities 找回已存在的活动继续更新。
    func start(deviceName: String = "TSL 模块") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let existing = Activity<SpeedActivityAttributes>.activities.first {
            activity = existing
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }

        let attributes = SpeedActivityAttributes(deviceName: deviceName)
        let state = SpeedActivityAttributes.ContentState(
            speedText: "--",
            speed: nil,
            unit: "KM/H",
            gearLabel: "-",
            connected: false, live: false, updatedAt: Date(),
            extras: nil
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(staleAfter)
        )
        activity = try? Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil          // 本地更新，不要改成 .token（自签没有推送权限）
        )
    }

    func update(_ gauge: GaugeState, extras: GaugeExtrasState?) {
        guard let activity else { return }
        let state = SpeedActivityAttributes.ContentState(
            speedText: gauge.speedText,
            speed: gauge.speed,
            unit: gauge.unit,
            gearLabel: gauge.gearLabel,
            connected: true,
            live: true,
            updatedAt: gauge.receivedAt,
            extras: extras
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(staleAfter)
        )
        Task { await activity.update(content) }
    }

    func markDisconnected() {
        guard let activity else { return }
        let state = SpeedActivityAttributes.ContentState(
            speedText: "--",
            speed: nil,
            unit: "KM/H",
            gearLabel: "-",
            connected: false, live: false, updatedAt: Date(),
            extras: nil
        )
        // staleDate = now → 系统立刻标记为过期，UI 显示失效态而不是旧车速
        let content = ActivityContent(state: state, staleDate: Date())
        Task { await activity.update(content) }
    }

    func end() {
        let current = activity
        activity = nil
        let final = SpeedActivityAttributes.ContentState(
            speedText: "--",
            speed: nil,
            unit: "KM/H",
            gearLabel: "-",
            connected: false, live: false, updatedAt: Date(),
            extras: nil
        )
        Task {
            await current?.end(
                ActivityContent(state: final, staleDate: Date()),
                dismissalPolicy: .immediate
            )
        }
    }
}

/// 把 BLE 帧转换成两条展示链路的节流调度器（主 App target）。
///
/// 系统对 Live Activity 更新有静默节流预算；无脑每 1.5s update 会被降级成
/// 「冻结的胶囊」。策略：数值/档位/单位变化才更新，并设 1s 最小间隔 +
/// 3s 强制心跳（用于刷新 staleDate，证明数据还活着）。
@MainActor
final class SpeedRefreshDriver: ObservableObject {
    static let shared = SpeedRefreshDriver()

    @Published private(set) var latest: GaugeState?
    @Published private(set) var connected = false

    private let store = SharedSpeedStore.shared
    private let widgetKind = TSLConfig.widgetKind
    private let carBodyWidgetKind = TSLConfig.carBodyWidgetKind

    private var lastWidgetReload = Date.distantPast
    private var lastActivityUpdate = Date.distantPast
    private var lastSignature = ""

    private let minReloadInterval: TimeInterval = 1.0
    private let minActivityInterval: TimeInterval = 1.0
    private let activityHeartbeat: TimeInterval = 3.0

    func ingest(_ gauge: GaugeState, frameExtras: GaugeExtras? = nil) {
        latest = gauge
        connected = true

        // GaugeExtras（App target 内解析）→ GaugeExtrasState（跨进程展示契约，
        // 同时进 Live Activity 与 App Group 快照，供两个小组件读取）
        let extrasState: GaugeExtrasState? = frameExtras.map { source in
            GaugeExtrasState(
                gearLabel: source.gearLabel,
                batteryPercent: source.batteryPercent,
                autoPilotLabel: source.autoPilotLabel,
                turnLeftActive: source.turnLeftActive,
                turnRightActive: source.turnRightActive,
                speedLimitKmh: (source.hasFullFrame && source.speedLimitKmh > 0)
                    ? source.speedLimitKmh
                    : nil,
                cabinTempC: source.cabinTempC,
                ambientTempC: source.ambientTempC,
                tirePressuresBar: source.tirePressuresBar,
                brakeTempsC: source.brakeTempsC,
                doorOpen: ["左前门", "右前门", "左后门", "右后门"]
                    .map { doorName in source.openDoors.contains(doorName) },
                frunkOpen: source.frunkOpen,
                trunkOpen: source.trunkOpen,
                blindSpotLevel: source.hasFullFrame
                    ? source.blindSpotLabels.map { label in
                        GaugeFrame176.blindSpotLevelLabels.firstIndex(of: label) ?? 0
                    }
                    : nil,
                lightHex: source.hasFullFrame ? source.lightHex : nil,
                batteryHeatLabel: source.batteryHeatLabel
            )
        }

        store.write(SpeedSnapshot(
            speed: gauge.speed,
            speedText: gauge.speedText,
            unit: gauge.unit,
            gearLabel: gauge.gearLabel,
            connected: true,
            live: true,
            updatedAt: gauge.receivedAt,
            extras: extrasState
        ))

        let now = Date()
        var signature = "\(gauge.speedText)|\(gauge.unit)|\(gauge.gearLabel)"
        if let extrasState = extrasState {
            signature += "|\(extrasState.batteryPercent)"
            signature += "|\(extrasState.autoPilotLabel)"
            signature += "|\(extrasState.turnLeftActive)|\(extrasState.turnRightActive)"
            signature += "|\(extrasState.speedLimitKmh ?? -1)"
        }
        let changed = signature != lastSignature
        let heartbeatDue = now.timeIntervalSince(lastActivityUpdate) >= activityHeartbeat

        // L2：Live Activity（锁屏 / 灵动岛 / iOS 26 CarPlay Dashboard）
        if (changed || heartbeatDue),
           now.timeIntervalSince(lastActivityUpdate) >= minActivityInterval {
            SpeedActivityController.shared.update(gauge, extras: extrasState)
            lastActivityUpdate = now
            lastSignature = signature
        }

        // L3：WidgetKit（两个小组件一起刷新）。Apple 明确「主 App 在前台时的
        // reload 不计入预算」，所以只在 .active 时逐帧刷新；后台/锁屏时交给
        // 系统预算，避免被限额。
        if UIApplication.shared.applicationState == .active,
           now.timeIntervalSince(lastWidgetReload) >= minReloadInterval {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
            WidgetCenter.shared.reloadTimelines(ofKind: carBodyWidgetKind)
            lastWidgetReload = now
        }
    }

    func markDisconnected() {
        connected = false
        store.write(SpeedSnapshot(
            speed: nil, speedText: "--", unit: "KM/H", gearLabel: "-",
            connected: false, live: false, updatedAt: Date(),
            extras: nil
        ))
        SpeedActivityController.shared.markDisconnected()
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: carBodyWidgetKind)
        lastSignature = ""
    }
}

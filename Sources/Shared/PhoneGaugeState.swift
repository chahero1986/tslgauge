import Foundation
import SwiftUI

/// 小组件 3「TSL 手机仪表」跨进程展示契约（主 App ↔ Widget Extension）。
///
/// 与车辆仪表完全无关：所有字段都由 iPhone 自身传感器产生——
///   · 速度 / 航向：CoreLocation（GPS + 磁力计）
///   · 海拔：GPS 给基准 + 气压计（CMAltimeter）给相对变化
///   · 坡度：CoreMotion 设备姿态 pitch（需停车时校准水平基准）
///   · 纵向 G：CoreMotion userAcceleration.y（已去重力，低通 + 静止归零）
///
/// 所有展示字符串在 App 侧格式化好再写进契约，Widget 侧只负责排版，
/// 避免 Extension 里重复实现格式化逻辑造成两台设备显示不一致。
///
/// ⚠️ 字段顺序 = 逐一构造器实参顺序，改动必须同步全部调用点；
///    scripts/verify_swift_calls.py 会在 CI 编译前逐处校验。
struct PhoneGaugeState: Codable, Hashable, Sendable {
    var speed: Int?               // GPS 速度 km/h，负值无效
    var speedText: String         // 数码管显示串，无效为 "--"
    var headingLabel: String      // 八方向，如 "东北 NE"；无效 "--"
    var altitudeM: Int?           // 海拔（米），气压计校准后
    var slopeText: String         // 坡度，如 "坡 +3.2°"；无效 "坡 --"
    var gText: String             // 纵向 G，如 "+0.35 G"；无效 "-- G"
    var valid: Bool               // 是否至少拿到一次有效定位
    var updatedAt: Date

    /// 小组件库 / 预览用演示数据（与定稿效果图状态 A 一致）
    static let demo = PhoneGaugeState(
        speed: 78,
        speedText: "78",
        headingLabel: "东北 NE",
        altitudeM: 128,
        slopeText: "坡 +3.2°",
        gText: "+0.35 G",
        valid: true,
        updatedAt: Date()
    )

    /// 无数据时的占位（权限未开 / 定位失败）
    static let empty = PhoneGaugeState(
        speed: nil,
        speedText: "--",
        headingLabel: "--",
        altitudeM: nil,
        slopeText: "坡 --",
        gText: "-- G",
        valid: false,
        updatedAt: Date()
    )

    var accessibilitySummary: String {
        var parts: [String] = []
        parts.append("车速 \(speedText)")
        parts.append("航向 \(headingLabel)")
        if let altitude = altitudeM { parts.append("海拔 \(altitude) 米") }
        parts.append(slopeText)
        parts.append(gText)
        return parts.joined(separator: "，")
    }
}

/// 小组件 3 专用共享容器。
///
/// 复用 SharedSpeedStore 的 CarPlay 可读性经验：显式把文件 protection class
/// 设为 .completeUntilFirstUserAuthentication，锁屏（CarPlay 常见状态）也能读。
/// 独立文件避免与车辆速度快照互相覆盖——两条数据流互不依赖，可同时存在。
final class SharedPhoneGaugeStore {
    static let shared = SharedPhoneGaugeStore()

    let suiteName: String? = TSLConfig.appGroupID
    private let filename = "tsl-phone-gauge.json"

    var hasSharedContainer: Bool {
        guard let suiteName else { return false }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil
    }

    private var fileURL: URL? {
        if let suiteName,
           let container = FileManager.default
               .containerURL(forSecurityApplicationGroupIdentifier: suiteName) {
            return container.appendingPathComponent(filename)
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(filename)
    }

    func write(_ state: PhoneGaugeState) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(state) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            print("[SharedPhoneGaugeStore] write failed: \(error)")
        }
    }

    func read() -> PhoneGaugeState? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhoneGaugeState.self, from: data)
    }

    func isStale(_ state: PhoneGaugeState, maxAge: TimeInterval = 30) -> Bool {
        Date().timeIntervalSince(state.updatedAt) > maxAge
    }
}

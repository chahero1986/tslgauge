import Foundation
import ActivityKit

/// 小组件 3「TSL 手机仪表」的 Live Activity 契约（主 App ↔ Widget Extension 共用）。
///
/// 为什么用 typealias 复用 PhoneGaugeState，而不是再写一个 ContentState：
///   · 字段顺序只有一份真相，避免重蹈首次 CI 编译失败
///     （"argument 'speed' must precede argument 'unit'" 的覆辙）；
///   · ActivityKit 通过系统直接传 state，不需要 App Group，是自签场景
///     唯一能做到秒级实时的通道；
///   · 桌面小组件仍走共享文件 / 定位缓存降级，两条链路互不干扰。
///
/// Target membership：必须同时加入【主 App】和【Widget Extension】。
struct PhoneGaugeActivityAttributes: ActivityAttributes {
    typealias ContentState = PhoneGaugeState
}

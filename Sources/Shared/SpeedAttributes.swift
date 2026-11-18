import Foundation
import ActivityKit

/// Live Activity 的数据契约。
/// ⚠️ 本文件必须同时加入【主 App target】和【Widget Extension target】：
///    主 App 用 ContentState 发起/更新活动，Extension 用 ActivityViewContext
///    渲染。ActivityKit 通过系统传递 state，因此这条链路【不需要 App Group】，
///    是自签场景下最稳的秒级实时通道。
struct SpeedActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var speedText: String
        var unit: String
        var gearLabel: String
        var connected: Bool
        var live: Bool
        var updatedAt: Date
    }

    var deviceName: String
}

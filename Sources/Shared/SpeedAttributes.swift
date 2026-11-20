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
        /// 原始速度数值，用于 0~60 绿 / 61~100 黄 / >100 红 的分段配色。
        /// 与 speedText 分开传，避免 Extension 侧解析 "--" 之类的显示串。
        var speed: Int?
        var unit: String
        var gearLabel: String
        var connected: Bool
        var live: Bool
        var updatedAt: Date
        /// 除速度外的仪表字段（档位 / 电量 / AP / 限速 / 转向灯 / 双温度 /
        /// 胎压 / 刹车温度 / 车门 / 前后备箱 / 盲区 / 灯光位 / 电池加热），
        /// 定义在 GaugeExtrasState.swift。短帧或未连接时为 nil → 界面显示 "--"。
        var extras: GaugeExtrasState?
    }

    var deviceName: String
}

import Foundation
import SwiftUI

/// 176 帧「除速度以外」字段跨进程传递的展示契约（主 App ↔ Widget Extension）。
///
/// 数据流：TSLBLEManager → GaugeExtras（App target 内解析，见 GaugeExtras.swift）
///   → 本结构
///   → ① SpeedActivityAttributes.ContentState（Live Activity，不需要 App Group）
///   → ② SpeedSnapshot（App Group 共享容器，供两个桌面小组件读取）
///
/// 字段按「模块短帧可能缺失」设计成 Optional：界面用 nil 显示 "--"，不拿 0 冒充。
/// 帧长度门槛（与 GaugeExtras 一致）：
///   ≥4 字节：档位 / 电量 / AP / 转向灯 / 车门 / 灯光位
///   ≥8 字节：前后备箱
///   ≥12 字节：胎压
///   ≥33 字节：限速 / 盲区 / 双温度 / 刹车温度 / 电池加热
struct GaugeExtrasState: Codable, Hashable {
    var gearLabel: String            // P / R / N / D / 0（0 = 未知）
    var batteryPercent: Int          // 0~127 %
    var autoPilotLabel: String       // "-" / "AP"
    var turnLeftActive: Bool
    var turnRightActive: Bool
    var speedLimitKmh: Int?          // 融合限速，仅 R/N/D 且完整帧有效
    var cabinTempC: Double?          // 座舱温度（33 字节完整帧才有）
    var ambientTempC: Double?        // 环境温度（33 字节完整帧才有）
    var tirePressuresBar: [Double]?  // [左前, 右前, 左后, 右后]
    var brakeTempsC: [Int]?          // [左前, 右前, 左后, 右后]
    var doorOpen: [Bool]?            // [左前, 右前, 左后, 右后]
    var frunkOpen: Bool?
    var trunkOpen: Bool?
    var blindSpotLevel: [Int]?       // [左, 右]：0 无 / 1 近距 / 2 中距 / 3 危险
    var lightHex: String?            // 灯光位原始十六进制（如 "0x02"）
    var batteryHeatLabel: String     // 关闭 / 加热 / 预热 / 保温

    /// 小组件库 / 预览用的演示数据（与定稿效果图示例一致）
    static let demo = GaugeExtrasState(
        gearLabel: "D",
        batteryPercent: 78,
        autoPilotLabel: "-",
        turnLeftActive: true,
        turnRightActive: false,
        speedLimitKmh: 80,
        cabinTempC: 24.0,
        ambientTempC: 18.0,
        tirePressuresBar: [2.8, 2.7, 2.9, 2.8],
        brakeTempsC: [42, 45, 38, 40],
        doorOpen: [false, false, false, true],
        frunkOpen: false,
        trunkOpen: false,
        blindSpotLevel: [0, 1],
        lightHex: "0x02",
        batteryHeatLabel: "关闭"
    )

    /// VoiceOver / 车机朗读用的摘要（告警优先）
    var accessibilitySummary: String {
        var parts: [String] = []
        parts.append("档位 \(gearLabel)")
        parts.append("电量 \(batteryPercent)%")
        if autoPilotLabel == "AP" { parts.append("辅助驾驶已开启") }
        if let limit = speedLimitKmh, limit > 0 { parts.append("限速 \(limit)") }
        if let v = cabinTempC { parts.append("车内 \(Int(v.rounded())) 度") }
        if let v = ambientTempC { parts.append("车外 \(Int(v.rounded())) 度") }
        if let doors = doorOpen, doors.contains(true) { parts.append("有车门未关") }
        if frunkOpen == true { parts.append("前备箱开启") }
        if trunkOpen == true { parts.append("后备箱开启") }
        return parts.joined(separator: "，")
    }
}

/// 两个小组件共用的状态配色（用户定稿规则）：
///   档位   P 红 / R 蓝 / N 白 / D 绿，未知灰
///   电量   ≤20% 红 / 21~80% 绿 / >80% 白
///   盲区   0 绿 / 1 黄 / 2 橙 / 3 红
///   电池加热 关闭灰，工作中黄
/// 速度分段配色沿用 SevenSegment.swift 里的 SpeedPalette，不在此重复。
enum GaugePalette {
    static let alert = Color(red: 1.00, green: 0.24, blue: 0.22)   // 红
    static let warning = Color(red: 0.95, green: 0.52, blue: 0.09) // 橙
    static let caution = Color(red: 1.00, green: 0.78, blue: 0.10) // 黄
    static let ok = Color(red: 0.16, green: 0.88, blue: 0.36)      // 绿
    static let info = Color(red: 0.12, green: 0.52, blue: 1.00)    // 蓝
    static let neutral = Color(white: 0.95)                        // 白
    static let dim = Color(white: 0.35)                            // 熄灭灰

    static func gearColor(_ label: String) -> Color {
        switch label {
        case "P": return alert
        case "R": return info
        case "N": return neutral
        case "D": return ok
        default: return dim
        }
    }

    static func batteryColor(_ percent: Int?) -> Color {
        guard let percent = percent, percent >= 0 else { return dim }
        if percent <= 20 { return alert }
        if percent <= 80 { return ok }
        return neutral
    }

    static func blindSpotColor(_ level: Int?) -> Color {
        guard let level = level else { return dim }
        switch level {
        case 0: return ok
        case 1: return caution
        case 2: return warning
        default: return alert
        }
    }

    /// 电池加热：标签不是「关闭」即视为工作中（黄）
    static func batteryHeatColor(_ label: String) -> Color {
        label == "关闭" ? dim : caution
    }
}

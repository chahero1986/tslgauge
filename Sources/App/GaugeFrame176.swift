import Foundation

/// 176 帧（仪表数据）解析结果
struct GaugeState {
    let speed: Int?             // nil 表示档位无效，界面显示 "--"
    let speedText: String
    let speedRaw: Int
    let gear: Int
    let gearLabel: String
    let unit: String
    let turn: Int
    let autoPilot: Int
    let door: Int
    let light: Int
    let tirePressures: [Double]
    let batteryHeat: Int
    let handsOn: Bool
    let hasFullFrame: Bool
    let receivedAt: Date

    /// 速度环占比（JS: Math.min(100, Math.round(speedRaw / 120 * 100))）
    var speedRingPercent: Int {
        min(100, Int((Double(speedRaw) / 120.0 * 100.0).rounded()))
    }
}

/// 从 parseGaugeFrame 逐位还原（wxapkg_app/app-service.js）
///
/// 位域（payload 前 4 字节按小端读成 UInt32 P）：
///   bit 0..8    speedRaw（9 bit, 0...511）
///   bit 9..11   gear，1=P 2=R 3=N 4=D；仅在 1...4 时显示速度
///   bit 12..13  turn（0 关闭 / 1 左 / 2 右 / 3 双闪）
///   bit 14..15  autoPilot
///   bit 16..19  door
///   bit 20..23 / bit 27 / byte4  light
/// 仅当 payload.count >= 33 时 hasFullFrame = true，单位等扩展字段才有效。
enum GaugeFrame176 {
    static let type: UInt8 = 176
    static let fullFrameLength = 33
    static let gearLabels = ["0", "P", "R", "N", "D"]
    static let turnLabels = ["关闭", "左转", "右转", "双闪"]
    static let heatLabels = ["关闭", "加热", "预热", "保温"]

    static func parse(_ payload: [UInt8]) -> GaugeState? {
        guard payload.count >= 4 else { return nil }

        func byte(_ i: Int) -> UInt32 {
            i < payload.count ? UInt32(payload[i]) : 0
        }
        func le32(_ i: Int) -> UInt32 {
            (byte(i + 3) << 24) | (byte(i + 2) << 16) | (byte(i + 1) << 8) | byte(i)
        }

        let head = le32(0)
        let speedRaw = Int(head & 0x1FF)
        let gear = Int((head >> 9) & 0x7)
        let validGear = (1...4).contains(gear)

        let turn = Int((head >> 12) & 0x3)
        let autoPilot = Int((head >> 14) & 0x3)
        let door = Int((head >> 16) & 0xF)
        let light = Int((head >> 20) & 0xF)
            | Int((head >> 27) & 0x10)
            | ((Int(byte(4)) << 1) & 0x20)

        var tires: [Double] = []
        if payload.count >= 12 {
            for i in 8...11 {
                let v = Int(payload[i])
                tires.append((v == 0 || v == 255) ? 0 : 0.025 * Double(v))
            }
        }

        let full = payload.count >= fullFrameLength
        let speedUnits = full ? Int((byte(17) >> 6) & 1) : 1
        let batteryHeat = full ? Int((byte(17) >> 4) & 3) : 0
        let handsOn = full ? ((byte(17) >> 7) & 1) == 1 : false

        return GaugeState(
            speed: validGear ? speedRaw : nil,
            speedText: validGear ? (speedRaw == 0 ? "0" : String(speedRaw)) : "--",
            speedRaw: speedRaw,
            gear: gear,
            gearLabel: gear < gearLabels.count ? gearLabels[gear] : String(gear),
            unit: speedUnits == 1 ? "KM/H" : "MPH",
            turn: turn,
            autoPilot: autoPilot,
            door: door,
            light: light,
            tirePressures: tires,
            batteryHeat: batteryHeat,
            handsOn: handsOn,
            hasFullFrame: full,
            receivedAt: Date()
        )
    }
}

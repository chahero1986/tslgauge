import Foundation

/// 176 帧里「除速度以外」的全部可显示字段（从 wxapkg_app/app-service.js 的
/// parseGaugeFrame / createEmptyGaugeState / toMetricGroups 逐位还原）。
///
/// 设计目的：当前小组件按你的要求只显示速度，本结构【不改动】GaugeState 与
/// ContentState 的数据契约，只作为「看中哪个字段就能直接接上」的解析层。
/// Optional = 该帧长度不够时才没有（模块短帧 / 长帧两种形态都兼容）。
struct GaugeExtras {

    // MARK: 只要 >= 4 字节就有（head 位域）
    var gearLabel: String
    var batteryPercent: Int          // %
    var turnLabel: String            // 关闭 / 左转 / 右转 / 双闪
    var turnLeftActive: Bool
    var turnRightActive: Bool
    var autoPilotRaw: Int            // 原始 2 bit
    var autoPilot: Int               // 按原 JS 抑制抖动后的值
    var autoPilotLabel: String       // - / AP
    var openDoors: [String]          // 左前门 / 右前门 / 左后门 / 右后门
    var lightHex: String             // 0xNN 灯光位

    // MARK: >= 8 字节
    var odometerKm: Double?
    var frunkOpen: Bool?
    var trunkOpen: Bool?
    var sport: Bool?
    var keepScreenOn: Bool?
    var aspect: Int?

    // MARK: >= 12 字节
    var tirePressuresBar: [Double]?  // 左前 / 右前 / 左后 / 右后

    // MARK: >= 16 字节
    var accelPedalPercent: Int?
    var frontPowerKW: Int?
    var rearPowerKW: Int?
    var totalPowerKW: Int?

    // MARK: >= 33 字节（完整帧）
    var handsOn: Bool
    var batteryHeatLabel: String     // 关闭 / 加热 / 预热 / 保温
    var speedLimitKmh: Int
    var blindSpotLabels: [String]    // 左右后侧盲区：无 / 近距 / 中距 / 危险
    var altitudeM: Int?
    var brakeTempsC: [Int]?
    var remainRangeKm: Int?
    var cellVoltageV: Double?
    var batteryTempC: Double?
    var ambientTempC: Double?
    var cabinTempC: Double?
    var blowerRPM: Int?
    var evapWatts: Int?
    var hasFullFrame: Bool

    /// 诊断页用的「最近一帧字段预览」：能亲眼看到这些数字，就说明 BLE 链路
    /// 已经完全打通，而不是只连上没有数据。
    var previewLines: [String] {
        var lines: [String] = []
        lines.append("档位  \(gearLabel)")
        lines.append("电量  \(batteryPercent)%")
        lines.append("转向  \(turnLabel)")
        lines.append("AP  \(autoPilotLabel)")
        lines.append("车门  \(openDoors.isEmpty ? "全关" : openDoors.joined(separator: "、"))")
        lines.append("灯光位  \(lightHex)")
        if let v = odometerKm { lines.append("总里程  \(String(format: "%.1f", v)) km") }
        if let v = tirePressuresBar {
            lines.append("胎压  " + v.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " Bar")
        }
        if let v = totalPowerKW { lines.append("合计功率  \(v) kW") }
        if let v = remainRangeKm { lines.append("剩余续航  \(v) km") }
        if hasFullFrame {
            lines.append("融合限速  \(speedLimitKmh) km/h")
            lines.append("盲区  \(blindSpotLabels.joined(separator: " / "))")
            lines.append("手扶提醒  \(handsOn ? "提示" : "正常")")
            lines.append("电池加热  \(batteryHeatLabel)")
            if let v = batteryTempC { lines.append("电池温度  \(String(format: "%.1f", v)) ℃") }
            if let v = altitudeM { lines.append("海拔  \(v) m") }
        }
        return lines
    }
}

extension GaugeFrame176 {

    static let autoPilotLabels = ["-", "AP", "AP", "AP"]
    static let blindSpotLevelLabels = ["无", "近距", "中距", "危险"]
    /// JS: c = [{左前门,bit0},{右前门,bit2},{左后门,bit1},{右后门,bit3}]
    static let doorBits: [(String, Int)] = [
        ("左前门", 0), ("右前门", 2), ("左后门", 1), ("右后门", 3)
    ]

    /// 解析 176 帧全部字段。与 parse(_:) 互不干扰，可选字段解析失败不影响车速。
    /// previousAutoPilot 对应原 JS 的「上一次 autoPilot 值」：raw=3 且上次为 0
    /// 时视为抖动、抑制成 0，否则会误报 AP 开启。
    static func parseExtras(_ payload: [UInt8], previousAutoPilot: Int = 0) -> GaugeExtras? {
        guard payload.count >= 4 else { return nil }

        func b(_ i: Int) -> UInt32 { i < payload.count ? UInt32(payload[i]) : 0 }
        func le(_ i: Int) -> UInt32 { (b(i + 3) << 24) | (b(i + 2) << 16) | (b(i + 1) << 8) | b(i) }
        /// JS: p(e,t) 取低 t 位并做补码有符号还原
        func signed(_ value: UInt32, _ bits: Int) -> Int {
            let mask = (1 << bits) - 1
            let v = Int(value) & mask
            return v >= (1 << (bits - 1)) ? v - (1 << bits) : v
        }

        let head = le(0)
        let gear = Int((head >> 9) & 0x7)
        let turn = Int((head >> 12) & 0x3)
        let ap = Int((head >> 14) & 0x3)
        let resolvedAP = (ap == 3 && previousAutoPilot == 0) ? 0 : ap
        let door = Int((head >> 16) & 0xF)
        let light = Int((head >> 20) & 0xF)
            | Int((head >> 27) & 0x10)
            | ((Int(b(4)) << 1) & 0x20)

        var extras = GaugeExtras(
            gearLabel: gear < gearLabels.count ? gearLabels[gear] : String(gear),
            batteryPercent: Int((head >> 24) & 0x7F),
            turnLabel: turn < turnLabels.count ? turnLabels[turn] : String(turn),
            turnLeftActive: (turn & 1) == 1,
            turnRightActive: (turn & 2) == 2,
            autoPilotRaw: ap,
            autoPilot: resolvedAP,
            autoPilotLabel: resolvedAP < autoPilotLabels.count
                ? autoPilotLabels[resolvedAP] : String(resolvedAP),
            openDoors: doorBits.filter { (door >> $0.1) & 1 == 1 }.map { $0.0 },
            lightHex: String(format: "0x%02X", light),
            odometerKm: nil,
            frunkOpen: nil,
            trunkOpen: nil,
            sport: nil,
            keepScreenOn: nil,
            aspect: nil,
            tirePressuresBar: nil,
            accelPedalPercent: nil,
            frontPowerKW: nil,
            rearPowerKW: nil,
            totalPowerKW: nil,
            handsOn: false,
            batteryHeatLabel: heatLabels[0],
            speedLimitKmh: 0,
            blindSpotLabels: [blindSpotLevelLabels[0], blindSpotLevelLabels[0]],
            altitudeM: nil,
            brakeTempsC: nil,
            remainRangeKm: nil,
            cellVoltageV: nil,
            batteryTempC: nil,
            ambientTempC: nil,
            cabinTempC: nil,
            blowerRPM: nil,
            evapWatts: nil,
            hasFullFrame: false
        )

        // JS: s(e,8) → P = u(e,4)
        if payload.count >= 8 {
            let p2 = le(4)
            extras.odometerKm = Double((p2 >> 6) & 0x3FF_FFFF) / 10.0
            extras.frunkOpen = ((p2 >> 1) & 1) == 1
            extras.trunkOpen = ((p2 >> 5) & 1) == 1
            extras.sport = ((p2 >> 3) & 1) == 1
            extras.keepScreenOn = (p2 & 1) == 0
            extras.aspect = Int((p2 >> 2) & 1)
        }

        // JS: s(e,12) → pressure = [8,9,10,11] * 0.025
        if payload.count >= 12 {
            extras.tirePressuresBar = (8...11).map { i -> Double in
                let v = Int(b(i))
                return (v == 0 || v == 255) ? 0 : 0.025 * Double(v)
            }
        }

        // JS: s(e,16) → P = u(e,12)，功率字段是有符号补码
        if payload.count >= 16 {
            let p3 = le(12)
            extras.accelPedalPercent = min(100, Int((100.0 * Double(p3 & 0xFF) / 250.0).rounded()))
            // JS Math.round(x) == floor(x + 0.5)；负数（能量回收）时
            // 不能直接用 Swift 默认的 .rounded()（它是 awayFromZero）。
            let rear = Int((Double(signed(p3 >> 8, 11)) / 2.0 + 0.5).rounded(.down))
            let front = Int((Double(signed(p3 >> 19, 11)) / 2.0 + 0.5).rounded(.down))
            extras.rearPowerKW = rear
            extras.frontPowerKW = front
            extras.totalPowerKW = front + rear
        }

        // JS: s(e,33) → hasFullFrame = true
        if payload.count >= fullFrameLength {
            extras.hasFullFrame = true
            let byte17 = b(17)
            extras.handsOn = ((byte17 >> 7) & 1) == 1
            let heat = Int((byte17 >> 4) & 3)
            extras.batteryHeatLabel = heat < heatLabels.count ? heatLabels[heat] : String(heat)

            let p4 = (byte17 << 16) | (b(16) << 8) | b(15)
            extras.altitudeM = signed(p4 >> 6, 14)

            let p5 = le(18)
            extras.brakeTempsC = [
                Int(p5 & 1023) - 40,
                Int((p5 >> 10) & 1023) - 40,
                Int((p5 >> 20) & 1023) - 40,
                (Int(b(22)) << 2 | Int(p5 >> 30)) - 40
            ]

            let p6 = le(23)
            extras.blowerRPM = 5 * Int(p6 & 1023)
            extras.evapWatts = 5 * Int((p6 >> 10) & 2047)
            extras.cabinTempC = 0.1 * Double((p6 >> 21) & 2047) - 40.0
            extras.ambientTempC = 0.5 * Double(b(27)) - 40.0

            let p7 = le(28)
            extras.cellVoltageV = 0.002 * Double(p7 & 4095)
            extras.remainRangeKm = Int((1.61 * Double((p7 >> 12) & 1023)).rounded())
            extras.batteryTempC = 0.5 * Double((p7 >> 22) & 511) - 40.0

            let p8 = (b(32) << 8) | b(31)
            extras.speedLimitKmh = (2...4).contains(gear) ? 5 * Int((p8 >> 7) & 31) : 0
            let left = Int((p8 >> 12) & 3)
            let right = Int((p8 >> 14) & 3)
            extras.blindSpotLabels = [
                left < blindSpotLevelLabels.count ? blindSpotLevelLabels[left] : String(left),
                right < blindSpotLevelLabels.count ? blindSpotLevelLabels[right] : String(right)
            ]
        }

        return extras
    }
}

import Foundation
import SwiftUI
import WidgetKit

/// 小组件 2「车身状态地图」（用户定稿：图标化，不用文字标签）。
///
/// 中央是俯视车身示意图（挡风线朝上 = 车头方向）：
///   · 四角 = 四个车轮：胎压（大数字）+ 刹车温度（温度计图标）+ 车门图标
///   · 顶部 / 底部盖板图标 = 前备箱 / 后备箱（开 = 红 + 抬起小杆）
///   · 左右中部波纹图标 = 盲区雷达（0 绿 / 1 黄 / 2 橙 / 3 红）
///   · 车身中央：大灯图标 + 灯光位数值（0x02 为协议原始值）、
///     电池图标 + 温度计 = 电池加热（灰 = 关 / 黄 = 加热·预热·保温）
/// 颜色即状态：绿正常、黄注意、橙接近、红告警。
///
/// 数据经 App Group 共享容器传入（SpeedSnapshot.extras）；
/// 无 App Group 或模块只发短帧时对应位置显示 "--"，整体降透明度，不冒充实时。
/// 支持 systemSmall（CarPlay Dashboard 原生槽位）与 systemMedium。
struct CarBodyWidget: Widget {
    let kind = TSLConfig.carBodyWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedTimelineProvider()) { entry in
            CarBodyWidgetView(entry: entry)
        }
        .configurationDisplayName("TSL 车况")
        .description("俯视车身示意图：四轮胎压与刹车温度、车门、前后备箱、盲区、灯光位、电池加热")
        .supportedFamilies([.systemSmall, .systemMedium])
        // 与小组件 1 一样：不设置 .disfavoredLocations，保持 CarPlay 可见
    }
}

struct CarBodyWidgetView: View {
    let entry: SpeedEntry

    private var snapshot: SpeedSnapshot? { entry.snapshot }
    private var extras: GaugeExtrasState? { snapshot?.extras }

    private var isLive: Bool {
        guard let snapshot = snapshot else { return false }
        return snapshot.live && snapshot.connected &&
               Date().timeIntervalSince(snapshot.updatedAt) <= 300
    }

    var body: some View {
        CarBodyMap(extras: extras, isLive: isLive)
            .padding(5)
            .containerBackground(for: .widget) { Color(white: 0.03) }
    }
}

/// 俯视车身地图：按可用空间最小边等比布点，小号 / 中号共用一份坐标。
private struct CarBodyMap: View {
    let extras: GaugeExtrasState?
    let isLive: Bool

    private func tireText(_ index: Int) -> String {
        guard let values = extras?.tirePressuresBar,
              index < values.count, values[index] > 0 else { return "--" }
        return String(format: "%.1f", values[index])
    }

    private func brakeText(_ index: Int) -> String {
        guard let values = extras?.brakeTempsC,
              index < values.count, values[index] > -39 else { return "--" }
        return "\(values[index])°"
    }

    private func doorOpen(_ index: Int) -> Bool {
        guard let values = extras?.doorOpen, index < values.count else { return false }
        return values[index]
    }

    private var heatActive: Bool {
        if let value = extras { return value.batteryHeatLabel != "关闭" }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2

            ZStack {
                // 车身（挡风线在前 = 车头朝上）
                CarBodyShape()
                    .frame(width: s * 0.20, height: s * 0.64)
                    .position(x: cx, y: cy)
                CarCabinArc(controlUp: true)
                    .stroke(Color(white: 0.28), lineWidth: 1.6)
                    .frame(width: s * 0.165, height: s * 0.06)
                    .position(x: cx, y: cy - s * 0.155)
                CarCabinArc(controlUp: false)
                    .stroke(Color(white: 0.28), lineWidth: 1.6)
                    .frame(width: s * 0.155, height: s * 0.06)
                    .position(x: cx, y: cy + s * 0.155)

                // 四个车轮
                wheel
                    .frame(width: s * 0.036, height: s * 0.105)
                    .position(x: cx - s * 0.114, y: cy - s * 0.155)
                wheel
                    .frame(width: s * 0.036, height: s * 0.105)
                    .position(x: cx + s * 0.114, y: cy - s * 0.155)
                wheel
                    .frame(width: s * 0.036, height: s * 0.105)
                    .position(x: cx - s * 0.114, y: cy + s * 0.155)
                wheel
                    .frame(width: s * 0.036, height: s * 0.105)
                    .position(x: cx + s * 0.114, y: cy + s * 0.155)

                // 四角数据块：胎压 + 刹车温度 + 车门（0左前 1右前 2左后 3右后）
                WheelBlock(
                    tireText: tireText(0), brakeText: brakeText(0),
                    doorOpen: doorOpen(0), alignTrailing: false, width: s * 0.36
                )
                .position(x: cx - s * 0.30, y: cy - s * 0.21)
                WheelBlock(
                    tireText: tireText(1), brakeText: brakeText(1),
                    doorOpen: doorOpen(1), alignTrailing: true, width: s * 0.36
                )
                .position(x: cx + s * 0.30, y: cy - s * 0.21)
                WheelBlock(
                    tireText: tireText(2), brakeText: brakeText(2),
                    doorOpen: doorOpen(2), alignTrailing: false, width: s * 0.36
                )
                .position(x: cx - s * 0.30, y: cy + s * 0.21)
                WheelBlock(
                    tireText: tireText(3), brakeText: brakeText(3),
                    doorOpen: doorOpen(3), alignTrailing: true, width: s * 0.36
                )
                .position(x: cx + s * 0.30, y: cy + s * 0.21)

                // 左右盲区雷达
                RadarIcon(level: extras?.blindSpotLevel?.first, pointingLeft: true)
                    .frame(width: s * 0.085, height: s * 0.085)
                    .position(x: cx - s * 0.375, y: cy)
                RadarIcon(level: extras?.blindSpotLevel?.last, pointingLeft: false)
                    .frame(width: s * 0.085, height: s * 0.085)
                    .position(x: cx + s * 0.375, y: cy)

                // 车身中央：大灯 + 灯光位数值
                VStack(spacing: 2) {
                    LightIcon()
                    Text(extras?.lightHex ?? "--")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.72))
                }
                .position(x: cx, y: cy - s * 0.045)

                // 车身中央：电池加热
                BatteryHeatIcon(active: heatActive)
                    .position(x: cx, y: cy + s * 0.095)

                // 顶部 / 底部：前备箱 / 后备箱盖板
                LidIcon(open: extras?.frunkOpen == true)
                    .frame(width: s * 0.115, height: s * 0.042)
                    .position(x: cx, y: cy - s * 0.375)
                LidIcon(open: extras?.trunkOpen == true)
                    .frame(width: s * 0.115, height: s * 0.042)
                    .position(x: cx, y: cy + s * 0.375)
            }
        }
        .opacity(isLive ? 1.0 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("车身状态地图")
        .accessibilityValue(extras?.accessibilitySummary ?? "暂无数据")
    }

    private var wheel: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(white: 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(white: 0.26), lineWidth: 1.2)
            )
    }
}

/// 四角数据块：胎压（大数字）+ 刹车温度（温度计 + 数字）+ 车门图标
private struct WheelBlock: View {
    let tireText: String
    let brakeText: String
    let doorOpen: Bool
    let alignTrailing: Bool
    let width: CGFloat

    var body: some View {
        VStack(
            alignment: alignTrailing ? HorizontalAlignment.trailing : HorizontalAlignment.leading,
            spacing: 2
        ) {
            Text(tireText)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.95))
            HStack(spacing: 3) {
                ThermometerIcon()
                    .frame(width: 5, height: 9)
                Text(brakeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.72))
            }
            DoorIcon(open: doorOpen)
                .frame(width: 10, height: 13)
        }
        .frame(width: width, alignment: alignTrailing ? Alignment.trailing : Alignment.leading)
    }
}

/// 车门图标：关闭 = 灰色竖直；打开 = 红色并绕上铰链张开
private struct DoorIcon: View {
    let open: Bool

    private var color: Color { open ? GaugePalette.alert : Color(white: 0.54) }

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 3)
                .stroke(color, lineWidth: 1.8)
            Capsule()
                .fill(color)
                .frame(width: 3.2, height: 1.8)
                .offset(x: -2.5)
        }
        .rotationEffect(.degrees(open ? 30 : 0), anchor: .topLeading)
    }
}

/// 温度计图标（刹车温度前缀）
private struct ThermometerIcon: View {
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.54))
                .frame(width: 1.6, height: 6)
            Circle()
                .fill(Color(white: 0.54))
                .frame(width: 3.2, height: 3.2)
        }
    }
}

/// 盲区雷达波纹：0 绿 / 1 黄 / 2 橙 / 3 红；pointingLeft 时左右镜像
private struct RadarIcon: View {
    let level: Int?
    let pointingLeft: Bool

    var body: some View {
        RadarShape()
            .stroke(GaugePalette.blindSpotColor(level), lineWidth: 1.8)
            .overlay(
                Circle()
                    .fill(GaugePalette.blindSpotColor(level))
                    .frame(width: 3.4, height: 3.4)
                    .offset(x: -2)
            )
            .rotationEffect(.degrees(pointingLeft ? 180 : 0))
    }
}

/// 两道向右发散的波纹（用二次曲线近似圆弧，避免 addArc 方向歧义）
private struct RadarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        for factor in [0.55, 1.0] {
            let h = rect.height * 0.5 * factor
            let w = rect.width * 0.55 * factor
            path.move(to: CGPoint(x: rect.minX, y: rect.midY - h))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.midY + h),
                control: CGPoint(x: rect.minX + w, y: rect.midY)
            )
        }
        return path
    }
}

/// 大灯图标：灯体 + 三道光束
private struct LightIcon: View {
    var body: some View {
        HStack(spacing: 3) {
            Capsule()
                .stroke(Color(white: 0.92), lineWidth: 1.6)
                .frame(width: 8, height: 13)
            VStack(spacing: 2.5) {
                Rectangle().fill(Color(white: 0.92)).frame(width: 8, height: 1.6)
                Rectangle().fill(Color(white: 0.92)).frame(width: 10, height: 1.6)
                Rectangle().fill(Color(white: 0.92)).frame(width: 8, height: 1.6)
            }
        }
    }
}

/// 电池加热图标：电池壳内温度计 + 正极凸头（灰 = 关 / 黄 = 工作中）
private struct BatteryHeatIcon: View {
    let active: Bool

    private var color: Color { active ? GaugePalette.caution : Color(white: 0.54) }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(color, lineWidth: 1.6)
                ThermometerIcon()
            }
            .frame(width: 15, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2.5, height: 5)
        }
    }
}

/// 前备箱 / 后备箱盖板图标：关闭 = 灰色；打开 = 红色 + 抬起小杆
private struct LidIcon: View {
    let open: Bool

    private var color: Color { open ? GaugePalette.alert : Color(white: 0.54) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: 1.8)
            if open {
                Rectangle()
                    .fill(color)
                    .frame(width: 7, height: 2.2)
                    .offset(x: 0, y: -4)
                    .rotationEffect(.degrees(-25))
            }
        }
    }
}

/// 车身主体（俯视）
private struct CarBodyShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0.075))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(white: 0.19), lineWidth: 1.6)
            )
    }
}

/// 挡风线 / 后窗线：controlUp = 弧线朝车头方向鼓起
private struct CarCabinArc: Shape {
    let controlUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let y = controlUp ? rect.maxY : rect.minY
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: y),
            control: CGPoint(x: rect.midX, y: rect.midY)
        )
        return path
    }
}

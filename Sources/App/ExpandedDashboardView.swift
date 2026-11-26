import SwiftUI

/// 主 App 完整仪表盘。
///
/// 原来的首页只有一个纯速度，用户要求把三个小组件里的信息都搬到 App 内：
///   · 速度主仪表：档位 / AP / 电量 / 转向灯 / 限速 / 车内 / 环境温度
///   · 车况：四轮胎压 + 刹车温度 + 车门 / 前后备箱 / 盲区 / 灯光位 / 电池加热
///   · 手机传感器（不依赖车辆）：航向 / 海拔 / 坡度 / 纵向 G
///
/// 数据全部来自主 App 已经持有的三个可观察对象，不读 Widget 的共享文件：
///   ble.latest  → 速度与档位
///   ble.extras  → 176 帧完整字段（短帧时对应项显示 "--"）
///   phone.lastSnapshot → 手机传感器融合结果
///
/// HUD 抬头显示：开启后把【仪表内容】水平镜像（可再叠加上下翻转），
/// 手机平放仪表台时画面经前挡风玻璃反射即为正向。控制按钮不参与镜像，
/// 否则镜像后按钮左右对调、点起来反手。镜像状态用 @AppStorage 持久化。
struct ExpandedDashboardView: View {
    @ObservedObject var ble: TSLBLEManager
    @ObservedObject var driver: SpeedRefreshDriver
    @ObservedObject var phone: PhoneSensorManager

    @AppStorage("tsl_hud_mirrored") private var hudMirrored = false
    @AppStorage("tsl_hud_vertical_flip") private var hudVerticalFlip = false
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            Color(white: 0.03).ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    headerRow
                    speedBlock
                    carStatusBlock
                    phoneBlock
                }
                .padding(.horizontal, 16)
                .padding(.top, 30)
                .padding(.bottom, 64)
            }
            // HUD：只镜像内容，控制层留在最外层保持正向可点
            .scaleEffect(x: hudMirrored ? -1 : 1, y: hudVerticalFlip ? -1 : 1)

            controls
        }
        .sheet(isPresented: $showDiagnostics) {
            ConnectionDiagnosticsView(ble: ble, log: BLELog.shared)
        }
    }

    // MARK: - 顶部：档位 / AP / 电量

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(gearText)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(GaugePalette.gearColor(gearText))
            Spacer()
            Text(apActive ? "AP" : "-")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(apActive ? GaugePalette.info : GaugePalette.dim)
            Spacer()
            Text(batteryText)
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(GaugePalette.batteryColor(extras?.batteryPercent))
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("档位 \(gearText)，辅助驾驶\(apActive ? "开启" : "关闭")，电量 \(batteryText)")
    }

    // MARK: - 中部：转向灯 + 大速度 + 限速 + 双温度

    private var speedBlock: some View {
        ZStack {
            HStack {
                DashTurnArrow(pointingLeft: true)
                    .fill(ble.extras?.turnLeftActive == true ? GaugePalette.ok : GaugePalette.dim)
                    .frame(width: 20, height: 24)
                Spacer()
                DashTurnArrow(pointingLeft: false)
                    .fill(ble.extras?.turnRightActive == true ? GaugePalette.ok : GaugePalette.dim)
                    .frame(width: 20, height: 24)
            }

            VStack(spacing: 2) {
                SevenSegmentNumber(
                    text: speedText,
                    color: SpeedPalette.color(for: speed),
                    inactiveColor: SpeedPalette.inactive(for: speed)
                )
                .frame(height: 168)
                .opacity(isLive ? 1.0 : 0.55)

                Text(limitText)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(hasLimit ? Color(white: 0.92) : Color(white: 0.40))

                HStack {
                    Text(cabinText)
                    Spacer()
                    Text(ambientText)
                }
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.78))
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("车速 \(speedText)")
        .accessibilityValue("\(limitText)，\(cabinText)，\(ambientText)")
    }

    // MARK: - 车况：四轮 + 门 / 盖板 / 盲区 / 灯光 / 电池加热

    private var carStatusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("车况")
            tireRow(label: "前", left: 0, right: 1)
            tireRow(label: "后", left: 2, right: 3)
            statusGrid
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tireRow(label: String, left: Int, right: Int) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 16)
            tireCell(title: "左", pressure: tire(left), brake: brake(left), doorOpen: doorOpen(left))
            tireCell(title: "右", pressure: tire(right), brake: brake(right), doorOpen: doorOpen(right))
        }
    }

    private func tireCell(title: String, pressure: String, brake: String, doorOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.5))
                Text(pressure)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.95))
                Text("bar")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.5))
            }
            HStack(spacing: 6) {
                Text("刹 \(brake)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.72))
                if doorOpen {
                    Text("门开")
                        .font(.caption2)
                        .foregroundStyle(GaugePalette.alert)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            statusChip("前备箱", value: extras?.frunkOpen == true ? "开" : "关",
                       color: extras?.frunkOpen == true ? GaugePalette.alert : Color(white: 0.75))
            statusChip("后备箱", value: extras?.trunkOpen == true ? "开" : "关",
                       color: extras?.trunkOpen == true ? GaugePalette.alert : Color(white: 0.75))
            statusChip("盲区左", value: blindText(0), color: blindColor(0))
            statusChip("盲区右", value: blindText(1), color: blindColor(1))
            statusChip("灯光", value: extras?.lightHex ?? "--", color: Color(white: 0.85))
            statusChip("电池加热", value: extras?.batteryHeatLabel ?? "--",
                       color: GaugePalette.batteryHeatColor(extras?.batteryHeatLabel ?? "关闭"))
        }
    }

    private func statusChip(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 手机传感器（不依赖车辆）

    private var phoneBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("手机传感器 · 不连车辆")
            HStack(spacing: 6) {
                phoneMetric("航向", phone.lastSnapshot?.headingLabel ?? "--")
                phoneMetric("海拔", altitudeText)
                phoneMetric("坡度", phone.lastSnapshot?.slopeText ?? "坡 --")
                phoneMetric("纵向 G", phone.lastSnapshot?.gText ?? "-- G")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func phoneMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.5))
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color(white: 0.92))
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(Color(white: 0.5))
    }

    // MARK: - 控制层（不镜像）

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(spacing: 8) {
                    hudButton
                    if hudMirrored {
                        flipButton
                    }
                }
            }
            Spacer()
            diagnosticsButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var hudButton: some View {
        Button {
            hudMirrored.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.and.right")
                Text(hudMirrored ? "HUD 开" : "HUD")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(hudMirrored ? GaugePalette.ok : Color(white: 0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(hudMirrored ? GaugePalette.ok : Color(white: 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hudMirrored ? "关闭 HUD 镜像" : "开启 HUD 镜像")
    }

    /// _phone 平放方式不同，有的只需左右镜像、有的还要上下翻转；HUD 开启后提供微调。
    private var flipButton: some View {
        Button {
            hudVerticalFlip.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.and.down")
                Text(hudVerticalFlip ? "上下翻 开" : "上下翻")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(hudVerticalFlip ? GaugePalette.caution : Color(white: 0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hudVerticalFlip ? "关闭上下翻转" : "开启上下翻转")
    }

    private var diagnosticsButton: some View {
        Button { showDiagnostics = true } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(ble.connectionState)
                    .font(.footnote)
                Image(systemName: "chevron.up")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开连接诊断，当前状态：\(ble.connectionState)")
    }

    private var statusColor: Color {
        switch ble.stage {
        case .streaming: return .green
        case .failed, .bluetoothOff, .unauthorized: return .red
        case .disconnected, .idle: return .gray
        default: return .orange
        }
    }

    // MARK: - 数据适配

    private var extras: GaugeExtras? { ble.extras }

    private var speedText: String { ble.latest?.speedText ?? "--" }
    private var speed: Int? { ble.latest?.speed }
    private var isLive: Bool { driver.connected }

    private var gearText: String {
        let label = ble.latest?.gearLabel ?? "-"
        return label == "0" ? "-" : label
    }

    private var apActive: Bool { extras?.autoPilotLabel == "AP" }

    private var batteryText: String {
        guard let percent = extras?.batteryPercent, percent > 0, percent <= 100 else {
            return "--%"
        }
        return "\(percent)%"
    }

    private var hasLimit: Bool {
        extras?.hasFullFrame == true && (extras?.speedLimitKmh ?? 0) > 0
    }

    private var limitText: String {
        guard hasLimit, let limit = extras?.speedLimitKmh else { return "限速 --" }
        return "限速 \(limit)"
    }

    private var cabinText: String {
        if let v = extras?.cabinTempC { return "车内 \(Int(v.rounded()))°" }
        return "车内 --"
    }

    private var ambientText: String {
        if let v = extras?.ambientTempC { return "环境 \(Int(v.rounded()))°" }
        return "环境 --"
    }

    private func tire(_ index: Int) -> String {
        guard let values = extras?.tirePressuresBar,
              index < values.count, values[index] > 0 else { return "--" }
        return String(format: "%.1f", values[index])
    }

    private func brake(_ index: Int) -> String {
        guard let values = extras?.brakeTempsC,
              index < values.count, values[index] > -39 else { return "--" }
        return "\(values[index])°"
    }

    /// 车门顺序与 GaugeExtras.openDoors 一致：0 左前 / 1 右前 / 2 左后 / 3 右后
    private func doorOpen(_ index: Int) -> Bool {
        let names = ["左前门", "右前门", "左后门", "右后门"]
        guard index < names.count else { return false }
        return extras?.openDoors.contains(names[index]) == true
    }

    private func blindText(_ index: Int) -> String {
        guard let labels = extras?.blindSpotLabels, index < labels.count else { return "--" }
        return labels[index]
    }

    private func blindColor(_ index: Int) -> Color {
        guard let labels = extras?.blindSpotLabels, index < labels.count else {
            return GaugePalette.dim
        }
        let level = GaugeFrame176.blindSpotLevelLabels.firstIndex(of: labels[index]) ?? 0
        return GaugePalette.blindSpotColor(level)
    }

    private var altitudeText: String {
        if let altitude = phone.lastSnapshot?.altitudeM { return "\(altitude) m" }
        return "-- m"
    }
}

/// 转向灯箭头（小组件里那份是 Widget target 的 private，App 用不了，这里独立实现）。
private struct DashTurnArrow: Shape {
    let pointingLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        if pointingLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        path.closeSubpath()
        return path
    }
}

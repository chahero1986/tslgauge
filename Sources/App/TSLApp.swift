import SwiftUI
import UIKit

/// 主 App 入口（仅主 App target）。
///
/// 行车时让 App 保持前台并禁止自动锁屏有两个作用：
///   1) BLE 连接最稳（配合 UIBackgroundModes bluetooth-central 与状态恢复）
///   2) 主 App 前台时 WidgetCenter.reloadTimelines 不计入 WidgetKit 预算，
///      桌面 / CarPlay 上的 systemSmall 才能做到约 1~2 秒级刷新
/// 锁屏后实时数值请看 Live Activity（iOS 26 会自动上 CarPlay Dashboard）。
@main
struct TSLGaugeApp: App {
    @StateObject private var ble = TSLBLEManager.shared

    var body: some Scene {
        WindowGroup {
            SpeedDashboardView(ble: ble, driver: SpeedRefreshDriver.shared)
                .onAppear {
                    Task { @MainActor in
                        UIApplication.shared.isIdleTimerDisabled = true

                        ble.onSpeedUpdate = { state in
                            Task { @MainActor in
                                SpeedRefreshDriver.shared.ingest(state, frameExtras: ble.extras)
                            }
                        }
                        ble.onDisconnect = {
                            Task { @MainActor in
                                SpeedRefreshDriver.shared.markDisconnected()
                            }
                        }

                        SpeedActivityController.shared.start()
                        BLELog.shared.add(.info, "主界面就绪 · 启动实时活动并开始扫描")
                        ble.startScanning()
                    }
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}

/// 全屏仪表：既是最可靠的秒级实时界面，也是 AirPlay / AI Box 镜像投屏的源画面。
///
/// 按「界面要纯粹」的要求，这里只保留大号 7 段速度数字 + 一个极小的状态入口；
/// 密码、重新扫描、连接日志、字段预览全部收进弹出的「连接诊断」页。
struct SpeedDashboardView: View {
    @ObservedObject var ble: TSLBLEManager
    @ObservedObject var driver: SpeedRefreshDriver

    @State private var showDiagnostics = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SevenSegmentSpeedView(
                text: ble.latest?.speedText ?? "--",
                speed: ble.latest?.speed,
                isLive: driver.connected,
                showsStatusDot: true
            )
            .frame(height: 200)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

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
            .padding(.bottom, 28)
            .accessibilityLabel("打开连接诊断，当前状态：\(ble.connectionState)")
        }
        .sheet(isPresented: $showDiagnostics) {
            ConnectionDiagnosticsView(ble: ble, log: BLELog.shared)
        }
    }

    /// 绿 = 实时数据；橙 = 正在连接/认证；红 = 明确失败；灰 = 未连接
    private var statusColor: Color {
        switch ble.stage {
        case .streaming:                          return .green
        case .failed, .bluetoothOff, .unauthorized: return .red
        case .disconnected, .idle:                return .gray
        default:                                  return .orange
        }
    }
}

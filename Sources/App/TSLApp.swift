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
                                SpeedRefreshDriver.shared.ingest(state)
                            }
                        }
                        ble.onDisconnect = {
                            Task { @MainActor in
                                SpeedRefreshDriver.shared.markDisconnected()
                            }
                        }

                        SpeedActivityController.shared.start()
                        ble.startScanning()
                    }
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}

/// 全屏仪表：既是最可靠的秒级实时界面，也是 AirPlay / AI Box 镜像投屏的源画面
/// （iOS < 26 或 CarPlay widget 不生效时的兜底，见方案第 8 节）。
struct SpeedDashboardView: View {
    @ObservedObject var ble: TSLBLEManager
    @ObservedObject var driver: SpeedRefreshDriver

    @State private var passwordDraft = "1234"

    var body: some View {
        VStack(spacing: 18) {
            // 与小组件 / 车机完全同一套 7 段数码管与分段配色
            SevenSegmentSpeedView(
                text: ble.latest?.speedText ?? "--",
                speed: ble.latest?.speed,
                isLive: driver.connected,
                showsStatusDot: true
            )
            .frame(height: 200)
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Text(ble.latest?.unit ?? "KM/H")
                Text("·")
                Label(ble.latest?.gearLabel ?? "-", systemImage: "gearshape")
                Text("·")
                Text(ble.connectionState)
                Text("·")
                Text(ble.authenticated ? "已认证" : "未认证")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 40)

            HStack {
                TextField("蓝牙密码", text: $passwordDraft)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("应用密码") { ble.setPassword(passwordDraft) }
                    .buttonStyle(.bordered)
            }

            HStack {
                Button("重新扫描") { ble.startScanning() }
                    .buttonStyle(.borderedProminent)
                Button("断开") {
                    ble.disconnect()
                    SpeedRefreshDriver.shared.markDisconnected()
                }
                .buttonStyle(.bordered)
            }

            Text("保持本界面常亮时，桌面 / CarPlay 小组件可秒级刷新；"
               + "锁屏后的实时数值请看锁屏实时活动。数据仅供参考，以车辆仪表为准。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

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
    @StateObject private var phone = PhoneSensorManager.shared

    var body: some Scene {
        WindowGroup {
            // 完整仪表：速度 + 三块小组件的全部信息 + HUD 镜像开关，
            // 详见 ExpandedDashboardView.swift。
            ExpandedDashboardView(
                ble: ble,
                driver: SpeedRefreshDriver.shared,
                phone: phone
            )
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

                    // 小组件 3：纯手机数据仪表，与 BLE 链路独立并行启动
                    PhoneSensorManager.shared.start()
                    // 手机仪表 Live Activity：回到前台时补一次，
                    // 找回被系统清理的活动（内部有幂等与前台判断）
                    PhoneGaugeActivityController.shared.start()

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

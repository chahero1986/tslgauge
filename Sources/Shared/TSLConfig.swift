import Foundation

/// 全局配置（主 App 与 Widget Extension 共用，属于 Sources/Shared）。
///
/// 这里刻意不硬编码 App Group / Team ID：未签名 IPA 的最终 entitlements
/// 由自签工具（AltStore / SideStore / Sideloadly）决定，编译期写死只会造成
/// 「IPA 里写了 group、profile 里没有」的签名冲突。
///
/// 配置注入方式（两条链路都不需要改 Swift 源码）：
///   1) GitHub Actions 的 workflow_dispatch 输入 app_group_id / display_name
///   2) 构建脚本把它们作为 xcodebuild 的 build setting（TSL_APP_GROUP /
///      TSL_DISPLAY_NAME）传入，两个 Info.plist 用 $(...) 展开
enum TSLConfig {

    /// 从当前进程的 Info.plist 读取。
    /// - 主 App：Bundle.main 是 TSLGauge.app
    /// - Widget Extension：Bundle.main 是 PlugIns/TSLWidgets.appex
    /// 所以两个 Info.plist 都必须带 TSLAppGroup 键，取值必须一致。
    static var appGroupID: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "TSLAppGroup") as? String ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空串 / 未展开的字面量 / 构建时的「不启用」哨兵，一律视为无 App Group
        if value.isEmpty || value.hasPrefix("$(") || value == "__NO_APP_GROUP__" {
            return nil
        }
        return value
    }

    /// WidgetKit 的 kind，主 App reloadTimelines 与 Widget 声明必须完全一致
    static let widgetKind = "TSLSpeedWidget"

    /// 第二个小组件（车身状态地图）的 kind，同样要求主 App 与声明一致
    static let carBodyWidgetKind = "TSLCarBodyWidget"

    /// CoreBluetooth 状态恢复标识（每次启动必须一致，否则后台恢复链会断）
    static let bleRestoreIdentifier = "com.tsl.gauge.ble.central"

    /// TSL 模块默认 4 位蓝牙密码
    static let defaultBLEPassword = "1234"

    /// BLE 服务 / 特征（从小程序 app-service.js 还原）
    ///
    /// 原 JS 用的是「UUID 字符串包含」而不是精确相等，且通知特征有回退链：
    ///   写特征 = UUID 含 FFF1 且可写
    ///   通知特征 = FFF1 同时「可通知 + 可写」→ 用 FFF1
    ///             否则 → 找 UUID 含 FFE0 的特征（实测模块常见形态）
    /// 所以特征发现必须请求【全部】特征，不能只 discover FFF1 一个。
    static let serviceUUID = "FFF0"
    static let characteristicUUID = "FFF1"
    static let writeCharacteristicUUID = "FFF1"
    static let notifyFallbackUUID = "FFE0"

    /// 扫描 / 认证看门狗阈值（秒），诊断页会如实显示当前阶段
    static let scanTimeout: TimeInterval = 12
    static let dataSilenceTimeout: TimeInterval = 8

    /// 2026-11-21 增补：FFF0 同时是大量蓝牙打印机 / 标签机的通用服务，
    /// 实测环境里 CASL / iKey / LEX / GLACIER 等设备都会广播 FFF0，容易撞车。
    ///
    /// RSSI 立即连接门槛：信号强于该值的候选立刻连（车内真模块通常 > -70）；
    /// 更弱的候选先暂存，等扫描超时后仍无强信号才退而连接。
    static let rssiConnectThreshold: Int = -75

    /// 认证阶段（连上 + 订阅成功后）连续多少轮重发仍收不到任何 TSL 协议帧，
    /// 就判定当前设备「不是 TSL 模块」并拉黑（本轮会话内不再尝试），继续找下一台。
    static let authRetryLimit = 3
}

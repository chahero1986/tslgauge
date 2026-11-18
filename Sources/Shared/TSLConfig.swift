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

    /// CoreBluetooth 状态恢复标识（每次启动必须一致，否则后台恢复链会断）
    static let bleRestoreIdentifier = "com.tsl.gauge.ble.central"

    /// TSL 模块默认 4 位蓝牙密码
    static let defaultBLEPassword = "1234"

    /// BLE 服务 / 特征（从小程序 app-service.js 还原）
    static let serviceUUID = "FFF0"
    static let characteristicUUID = "FFF1"
}

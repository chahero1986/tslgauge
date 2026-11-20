import Foundation
import Combine

/// 连接日志级别。行车排查时肉眼一眼区分「正常 / 数据 / 警告 / 失败」。
enum BLELogLevel: String {
    case info, ok, warn, error, data

    var marker: String {
        switch self {
        case .info:  return "·"
        case .ok:    return "✓"
        case .warn:  return "!"
        case .error: return "✕"
        case .data:  return "→"
        }
    }
}

struct BLELogEntry: Identifiable {
    let id: UUID
    let time: Date
    let timeText: String
    let level: BLELogLevel
    let message: String
}

/// BLE 链路阶段。界面与看门狗都以这个枚举为准，不再靠猜字符串状态。
enum BLEStage: String {
    case idle
    case bluetoothOff
    case unauthorized
    case scanning
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case subscribing
    case awaitingAuth
    case streaming
    case disconnected
    case failed

    var label: String {
        switch self {
        case .idle:                        return "待启动"
        case .bluetoothOff:                return "蓝牙关闭"
        case .unauthorized:                return "蓝牙未授权"
        case .scanning:                    return "扫描设备"
        case .connecting:                  return "建立连接"
        case .discoveringServices:         return "发现服务"
        case .discoveringCharacteristics:  return "发现特征"
        case .subscribing:                 return "订阅通知"
        case .awaitingAuth:                return "等待认证"
        case .streaming:                   return "实时数据"
        case .disconnected:                return "已断开"
        case .failed:                      return "链路失败"
        }
    }

    /// 每个阶段的看门狗超时（秒）。streaming 单独按「距上次收帧」判断。
    var timeout: TimeInterval {
        switch self {
        case .scanning:                    return TSLConfig.scanTimeout
        case .connecting:                  return 10
        case .discoveringServices:         return 8
        case .discoveringCharacteristics:  return 8
        case .subscribing:                 return 6
        case .awaitingAuth:                return 10
        default:                           return 0
        }
    }
}

/// 环形日志（只留最近 300 条），全部在主线程读写，避免 CBCentralManager
/// 回调与 SwiftUI 刷新之间的数据竞争。
final class BLELog: ObservableObject {
    static let shared = BLELog()
    static let limit = 300

    @Published private(set) var entries: [BLELogEntry] = []

    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func append(_ level: BLELogLevel, _ message: String) {
        let now = Date()
        let entry = BLELogEntry(
            id: UUID(),
            time: now,
            timeText: formatter.string(from: now),
            level: level,
            message: message
        )
        entries.append(entry)
        if entries.count > BLELog.limit {
            entries.removeFirst(entries.count - BLELog.limit)
        }
    }

    /// 可从任何线程调用；内部统一切换到主线程。
    func add(_ level: BLELogLevel, _ message: String) {
        if Thread.isMainThread {
            append(level, message)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(level, message) }
        }
    }

    func clear() {
        if Thread.isMainThread {
            entries.removeAll()
            append(.info, "日志已清空")
        } else {
            DispatchQueue.main.async { [weak self] in self?.clear() }
        }
    }

    /// 导出成可复制 / 可发给别人的纯文本（含设备与阶段信息由调用方追加）。
    func exportText() -> String {
        entries.map { "\($0.timeText) \($0.level.marker) \($0.message)" }
            .joined(separator: "\n")
    }
}

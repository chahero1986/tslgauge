import Foundation

/// 主 App 与 Widget Extension 之间传递车速快照的共享容器。
///
/// ⚠️ 两个关键点（自签 + CarPlay 场景）：
///  1) 原小程序里 wx.setStorageSync 写的是小程序沙盒，与这里不是同一个存储，
///     而且原 App 的实时速度只存在于 JS 内存。独立 App 必须自己落盘。
///  2) WWDC25-216：CarPlay 多数在 iPhone 锁屏时使用，依赖 data protection
///     class A / B 的 widget 在车机上读不到内容。因此这里显式把共享文件设为
///     .completeUntilFirstUserAuthentication（首次解锁后一直可读），
///     绝不能用 .complete / .completeUnlessOpen。
///
/// 无 App Group 时：退化为写主 App 自己的 Documents，Widget Extension 读不到，
/// 会显示占位提示；但 Live Activity 不依赖本文件，秒级实时仍然可用。
struct SpeedSnapshot: Codable {
    var speed: Int?
    var speedText: String
    var unit: String
    var gearLabel: String
    var connected: Bool
    var live: Bool            // 主 App 是否仍在持续收到 176 帧
    var updatedAt: Date
    /// 除速度外的仪表字段，供两个桌面小组件（速度主仪表 / 车身状态地图）读取
    var extras: GaugeExtrasState?
}

final class SharedSpeedStore {
    static let shared = SharedSpeedStore()

    /// App Group ID 来自两个 target 各自的 Info.plist 键 TSLAppGroup，
    /// 由 GitHub Actions 的 workflow 输入 app_group_id 注入（$(TSL_APP_GROUP)）。
    /// 留空 = 签名工具不提供 App Group，本文件自动走降级路径。
    /// ⚠️ 主 App 与 .appex 最终签名里的 com.apple.security.application-groups
    ///    必须包含同一个 group，否则 containerURL 返回 nil。
    let suiteName: String?
    private let filename = "tsl-speed-snapshot.json"

    init(suiteName: String? = TSLConfig.appGroupID) {
        self.suiteName = suiteName
    }

    /// 是否真的拿到了跨进程共享容器（可在 App 里打印自检）
    var hasSharedContainer: Bool {
        guard let suiteName else { return false }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil
    }

    private var fileURL: URL? {
        if let suiteName,
           let container = FileManager.default
               .containerURL(forSecurityApplicationGroupIdentifier: suiteName) {
            return container.appendingPathComponent(filename)
        }
        // 降级路径：只有写它的那个进程能读到（Widget Extension 有自己的沙盒）
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(filename)
    }

    func write(_ snapshot: SpeedSnapshot) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: .atomic)
            // CarPlay 锁屏可读性：不要用 .complete / .completeUnlessOpen
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            print("[SharedSpeedStore] write failed: \(error)")
        }
    }

    func read() -> SpeedSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeedSnapshot.self, from: data)
    }

    func isStale(_ snapshot: SpeedSnapshot, maxAge: TimeInterval = 300) -> Bool {
        Date().timeIntervalSince(snapshot.updatedAt) > maxAge
    }
}

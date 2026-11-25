import Foundation
import SwiftUI
import WidgetKit
import CoreLocation

/// 小组件 3「TSL 手机仪表」——完全依赖 iPhone 自身传感器，不连车辆。
///
/// 用户定稿布局（仅 .systemSmall，CarPlay Dashboard 原生槽位）：
///   左上：海拔（如 128 m）      右上：坡度（如 坡 +3.2°）
///   上方居中：航向八方向（如 东北 NE）
///   正中：7 段码速度，尽量铺满（0~60 绿 / 61~100 黄 / >100 红，规则不变）
///   下方居中：纵向 G（如 +0.35 G，中性灰，不加颜色规则）
///
/// 数据来源（2026-11-24 修正：自签无 App Group 时也能显示）：
///   1) 首选 App Group 共享文件（主 App 写入，含坡度 / 纵向 G 全字段）；
///   2) 降级读【系统定位缓存】CLLocationManager.location —— Widget 扩展与宿主
///      App 共享定位授权，主 App 前台持续定位时该缓存接近实时，无需 App Group。
///      降级路径有速度 / 航向 / 海拔，坡度与纵向 G 显示 "--"（姿态只有主 App 有）。
/// 两条路都拿不到时显示 "--"，不冒充实时。完整状态写进 accessibility。
struct PhoneGaugeEntry: TimelineEntry {
    let date: Date
    let snapshot: PhoneGaugeState?
    let hasSharedContainer: Bool
    let fromCacheFallback: Bool
}

// MARK: - 系统定位缓存降级读取（不依赖 App Group）

/// 无 App Group 时的兜底数据源。
/// 两级策略：
///   1) 同步读 CLLocationManager.location —— 主 App 持续定位时系统缓存最接近实时；
///   2) 缓存为空则 requestLocation() 主动取一次（带超时，避免 completion 永不回调）。
/// Widget 扩展与宿主 App 同属一个 App，共享定位授权，无需 App Group。
private final class CachedLocationFallback: NSObject, CLLocationManagerDelegate {
    static let shared = CachedLocationFallback()

    private let manager = CLLocationManager()
    private var pending: ((PhoneGaugeState?) -> Void)?
    private var finished = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    }

    /// 同步缓存够新（10 分钟内）就直接用，避免每次都触发定位。
    func cachedState() -> PhoneGaugeState? {
        guard let location = manager.location,
              Date().timeIntervalSince(location.timestamp) < 600 else { return nil }
        return Self.state(from: location)
    }

    /// 主动请求一次定位；3 秒兜底返回，保证 timeline 一定能生成。
    /// 用 DispatchQueue 而非 Timer——扩展生命周期短，不依赖 runloop mode 更稳。
    func requestState(completion: @escaping (PhoneGaugeState?) -> Void) {
        pending = completion
        finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            self.finish(with: self.manager.location)
        }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last ?? manager.location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: manager.location)
    }

    /// 只回调一次（定位成功与超时可能竞态，用 finished 去重）。
    private func finish(with location: CLLocation?) {
        guard !finished else { return }
        finished = true
        let callback = pending
        pending = nil
        callback?(location.map { Self.state(from: $0) })
    }

    private static func state(from location: CLLocation) -> PhoneGaugeState {
        let speedMps = location.speed
        let speed: Int? = speedMps >= 0 ? max(0, Int((speedMps * 3.6).rounded())) : nil
        let heading = location.course >= 0 ? compassLabel(location.course) : "--"
        let altitude: Int? = location.verticalAccuracy >= 0
            ? Int(location.altitude.rounded()) : nil

        return PhoneGaugeState(
            speed: speed,
            speedText: speed.map { String($0) } ?? "--",
            headingLabel: heading,
            altitudeM: altitude,
            slopeText: "坡 --",       // 姿态只有主 App 的 CoreMotion 有，缓存不含
            gText: "-- G",
            valid: speed != nil || altitude != nil || location.course >= 0,
            updatedAt: location.timestamp   // 用定位时间判定新鲜度，旧缓存会自动降透明度
        )
    }

    private static func compassLabel(_ degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % 8
        let labels = ["北 N", "东北 NE", "东 E", "东南 SE",
                      "南 S", "西南 SW", "西 W", "西北 NW"]
        return labels[index]
    }
}

struct PhoneGaugeTimelineProvider: TimelineProvider {
    private let store = SharedPhoneGaugeStore.shared

    func placeholder(in context: Context) -> PhoneGaugeEntry {
        PhoneGaugeEntry(date: Date(), snapshot: .demo,
                        hasSharedContainer: true, fromCacheFallback: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PhoneGaugeEntry) -> Void) {
        resolveEntry { completion($0) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneGaugeEntry>) -> Void) {
        resolveEntry { entry in
            // 主 App 前台时由 WidgetCenter.reloadTimelines 覆盖为秒级；
            // 后台靠系统预算调度，1 分钟后过期重建（用户要求缩短，且能拿到
            // 系统定位缓存的新值；实际刷新频率仍受系统预算，不保证准点）。
            // 真正的秒级实时请看手机仪表的 Live Activity。
            let next = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// 先取共享文件（全字段），过期/无 App Group 则降级到系统定位缓存。
    /// 同步缓存也没有时，主动请求一次定位（异步，带 3 秒超时）。
    private func resolveEntry(completion: @escaping (PhoneGaugeEntry) -> Void) {
        let shared = store.read()
        let sharedFresh = shared.map { !store.isStale($0) } ?? false
        if sharedFresh, let shared = shared {
            completion(PhoneGaugeEntry(date: Date(), snapshot: shared,
                                       hasSharedContainer: store.hasSharedContainer,
                                       fromCacheFallback: false))
            return
        }

        let fallback = CachedLocationFallback.shared
        let applyCache: (PhoneGaugeState?) -> Void = { cached in
            if let cached = cached {
                // 缓存比共享快照新才用；否则保留共享快照（哪怕稍旧，字段更全）
                if let shared = shared, shared.updatedAt > cached.updatedAt {
                    completion(PhoneGaugeEntry(date: Date(), snapshot: shared,
                                               hasSharedContainer: self.store.hasSharedContainer,
                                               fromCacheFallback: false))
                } else {
                    completion(PhoneGaugeEntry(date: Date(), snapshot: cached,
                                               hasSharedContainer: self.store.hasSharedContainer,
                                               fromCacheFallback: true))
                }
            } else {
                completion(PhoneGaugeEntry(date: Date(), snapshot: shared,
                                           hasSharedContainer: self.store.hasSharedContainer,
                                           fromCacheFallback: false))
            }
        }

        if let cached = fallback.cachedState() {
            applyCache(cached)
        } else {
            fallback.requestState(completion: applyCache)
        }
    }
}

struct PhoneGaugeWidgetView: View {
    let entry: PhoneGaugeEntry

    private var snapshot: PhoneGaugeState? { entry.snapshot }
    private var text: String { snapshot?.speedText ?? "--" }
    private var speed: Int? { snapshot?.speed }

    private var isLive: Bool {
        guard let snapshot = snapshot else { return false }
        return snapshot.valid && !SharedPhoneGaugeStore.shared.isStale(snapshot)
    }

    var body: some View {
        PhoneGaugeLayout(
            text: text,
            speed: speed,
            heading: snapshot?.headingLabel ?? "--",
            altitude: snapshot?.altitudeM,
            slope: snapshot?.slopeText ?? "坡 --",
            gText: snapshot?.gText ?? "-- G",
            isLive: isLive
        )
        .containerBackground(for: .widget) { Color(white: 0.03) }
    }
}

/// 小号布局：四角小字贴边，中央数码管尽量铺满。
private struct PhoneGaugeLayout: View {
    let text: String
    let speed: Int?
    let heading: String
    let altitude: Int?
    let slope: String
    let gText: String
    let isLive: Bool

    private var altitudeText: String {
        if let altitude = altitude { return "\(altitude) m" }
        return "-- m"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶行：海拔（左）· 航向（中）· 坡度（右）
            HStack(alignment: .top) {
                Text(altitudeText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(slope)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)

            // 正中：7 段码速度，把剩余空间全部吃掉
            SevenSegmentNumber(
                text: text,
                color: SpeedPalette.color(for: speed),
                inactiveColor: SpeedPalette.inactive(for: speed)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isLive ? 1.0 : 0.55)
            .padding(.vertical, 1)

            // 底行：纵向 G（居中，中性灰）
            Text(gText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.78))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("手机仪表车速 \(text)")
        .accessibilityValue("航向 \(heading)，\(altitudeText)，\(slope)，\(gText)，\(isLive ? "实时" : "快照")")
    }
}

struct PhoneGaugeWidget: Widget {
    let kind = TSLConfig.phoneGaugeWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PhoneGaugeTimelineProvider()) { entry in
            PhoneGaugeWidgetView(entry: entry)
        }
        .configurationDisplayName("TSL 手机仪表")
        .description("不连车辆：手机 GPS 速度 + 航向 + 海拔 + 坡度 + 纵向 G")
        .supportedFamilies([.systemSmall])   // CarPlay 只要小号
        // 刻意不做 CarPlay 位置降级配置，否则 CarPlay gallery 会被禁用
    }
}

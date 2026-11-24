import Foundation
import Combine
import CoreLocation
import CoreMotion
import UIKit
import WidgetKit

/// 小组件 3「TSL 手机仪表」的数据源（仅主 App target）。
///
/// 完全不依赖 BLE / 车辆数据：只用 iPhone 自身传感器。
///   · GPS 速度：CLLocation.speed（m/s → km/h），负值 = 无效
///   · 航向：运动中优先 GPS course；低速/静止用磁力计 trueHeading；转八方向汉字
///   · 海拔：GPS altitude 给绝对基准 + CMAltimeter 相对高度做灵敏修正
///   · 坡度：CMDeviceMotion.attitude.pitch 相对「水平基准」换算角度
///   · 纵向 G：userAcceleration.y 低通滤波 + 静止归零，消除安装角度偏置
///
/// 校准约定（真机必读）：上车后把手机固定支架、车辆停在水平路面静止 2 秒，
/// 调用 calibrate()（诊断页按钮）——此时记下气压计与姿态基准。
/// 未校准时坡度/纵向 G 会带安装角偏置，属正常现象，速度/航向/海拔不受影响。
///
/// 权限：NSLocationAlwaysAndWhenInUseUsageDescription + NSMotionUsageDescription，
/// 后台定位靠 UIBackgroundModes location；自签可用，无需特殊 entitlement。
final class PhoneSensorManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PhoneSensorManager()

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()

    private let store = SharedPhoneGaugeStore.shared
    private let widgetKind = TSLConfig.phoneGaugeWidgetKind

    /// 传感器可用性 / 权限状态，供诊断显示
    @Published private(set) var authorizationNote = "未启动"
    @Published private(set) var lastSnapshot: PhoneGaugeState?

    // GPS / 航向
    private var gpsSpeedMps: Double = -1
    private var gpsCourse: Double = -1
    private var magneticHeading: Double = -1
    private var gpsAltitude: Double?

    // 气压计：基准海拔 + 相对变化（米）
    private var barometerBaseAltitude: Double?
    private var relativeAltitude: Double = 0

    // 姿态：水平基准（弧度）
    private var pitchBaseline: Double?
    private var currentPitch: Double = 0

    // 纵向 G：低通 + 静止偏置归零
    private var filteredAccelY: Double = 0
    private var accelBias: Double = 0
    private var lastEmit = Date.distantPast

    private let emitInterval: TimeInterval = 1.0
    private let lowPassAlpha: Double = 0.18

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = 1
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - 生命周期

    func start() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
            authorizationNote = "等待定位授权"
        case .denied, .restricted:
            authorizationNote = "定位被拒绝：请在系统设置里允许「始终」"
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationNote = "定位已授权"
            startUpdates()
        @unknown default:
            authorizationNote = "未知定位权限状态"
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        altimeter.stopRelativeAltitudeUpdates()
        motionManager.stopDeviceMotionUpdates()
    }

    /// 车辆静止、水平路面时调用：把当前气压高度与姿态记为基准。
    func calibrate() {
        if let gpsAltitude = gpsAltitude {
            barometerBaseAltitude = gpsAltitude
        }
        relativeAltitude = 0
        pitchBaseline = currentPitch
        accelBias = filteredAccelY
        authorizationNote = "已校准（静止水平基准）"
        emit(force: true)
    }

    private func startUpdates() {
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self = self, let data = data else { return }
                self.relativeAltitude = data.relativeAltitude.doubleValue
                self.emit(force: false)
            }
        }

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self = self, let motion = motion else { return }
                self.currentPitch = motion.attitude.pitch
                let rawY = motion.userAcceleration.y
                self.filteredAccelY = self.filteredAccelY * (1 - self.lowPassAlpha)
                    + rawY * self.lowPassAlpha
                self.emit(force: false)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        start()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if location.speed >= 0 {
            gpsSpeedMps = location.speed
        }
        if location.course >= 0 {
            gpsCourse = location.course
        }
        if location.verticalAccuracy >= 0 {
            gpsAltitude = location.altitude
            if barometerBaseAltitude == nil {
                barometerBaseAltitude = location.altitude
            }
        }
        emit(force: false)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 {
            magneticHeading = newHeading.trueHeading >= 0
                ? newHeading.trueHeading
                : newHeading.magneticHeading
        }
        emit(force: false)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        authorizationNote = "定位失败：\(error.localizedDescription)"
    }

    // MARK: - 融合计算

    private var speedKmh: Int? {
        guard gpsSpeedMps >= 0 else { return nil }
        let value = Int((gpsSpeedMps * 3.6).rounded())
        return max(0, value)
    }

    private var altitude: Int? {
        if let base = barometerBaseAltitude {
            return Int((base + relativeAltitude).rounded())
        }
        if let gpsAltitude = gpsAltitude {
            return Int(gpsAltitude.rounded())
        }
        return nil
    }

    private var heading: (degrees: Double, source: String)? {
        let speed = speedKmh ?? 0
        // 移动中优先 GPS 航向（不受车内金属干扰）；低速时用磁力计
        if speed >= 5, gpsCourse >= 0 {
            return (gpsCourse, "GPS")
        }
        if magneticHeading >= 0 {
            return (magneticHeading, "磁力计")
        }
        if gpsCourse >= 0 {
            return (gpsCourse, "GPS")
        }
        return nil
    }

    private func compassLabel(_ degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % 8
        let labels = ["北 N", "东北 NE", "东 E", "东南 SE",
                      "南 S", "西南 SW", "西 W", "西北 NW"]
        return labels[index]
    }

    private var slopeDegrees: Double? {
        guard let baseline = pitchBaseline else { return nil }
        let delta = currentPitch - baseline
        return min(45, max(-45, delta * 180.0 / .pi))
    }

    private var longitudinalG: Double {
        // 静止时把残余偏置缓慢归零，避免支架倾斜导致常显 +0.2G
        if (speedKmh ?? 0) < 2 {
            accelBias = accelBias * 0.95 + filteredAccelY * 0.05
        }
        let value = filteredAccelY - accelBias
        return min(3, max(-3, value))
    }

    // MARK: - 输出

    private func emit(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= emitInterval else { return }
        lastEmit = now

        let speed = speedKmh
        let headingValue = heading
        let slope = slopeDegrees
        let gValue = longitudinalG

        let snapshot = PhoneGaugeState(
            speed: speed,
            speedText: speed.map { String($0) } ?? "--",
            headingLabel: headingValue.map { compassLabel($0.degrees) } ?? "--",
            altitudeM: altitude,
            slopeText: slope.map { value in
                String(format: "坡 %+.1f°", value)
            } ?? "坡 --",
            gText: String(format: "%+.2f G", gValue),
            valid: gpsAltitude != nil || speed != nil || headingValue != nil,
            updatedAt: now
        )

        lastSnapshot = snapshot
        store.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}

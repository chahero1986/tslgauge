import Foundation
import Combine
import CoreBluetooth

/// TSL 模块 BLE 连接骨架（路径 A：独立原生 App 直连模块，不依赖微信壳）
///
/// 依赖：
///   - Info.plist 加 UIBackgroundModes = [ bluetooth-central ]（锁屏/后台保持 BLE）
///   - NSBluetoothAlwaysUsageDescription
///   - TSLFrameCodec.swift / GaugeFrame176.swift / SpeedRefreshDriver.swift
///
/// ⚠️ 本文件是「可编译起点」而非成品：断线重连、密码输入 UI、BOOT 升级模式
///    判断、MTU 协商（默认 23，chunkSize 20）需要在真机上补齐并抓包核对。
final class TSLBLEManager: NSObject, ObservableObject {

    static let shared = TSLBLEManager()

    static let serviceUUID = CBUUID(string: TSLConfig.serviceUUID)
    static let characteristicUUID = CBUUID(string: TSLConfig.characteristicUUID)
    /// 状态恢复标识必须每次启动都相同，否则恢复链会断
    static let restoreIdentifier = TSLConfig.bleRestoreIdentifier

    @Published private(set) var connectionState = "未连接"
    @Published private(set) var authenticated = false
    @Published private(set) var latest: GaugeState?

    /// 收到新速度时回调，用于驱动 Live Activity 更新 / WidgetCenter.reloadTimelines
    var onSpeedUpdate: ((GaugeState) -> Void)?
    /// 断开时通知刷新驱动把实时活动标记为过期
    var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private let decoder = TSLFrameDecoder()
    // 落盘与刷新统一交给 SpeedRefreshDriver，本类只负责 BLE 与回调

    private var heartbeat: Timer?
    private var deviceInfoProofCount = 0
    private var password = TSLConfig.defaultBLEPassword
    private var pendingChunks: [Data] = []
    private var writeType: CBCharacteristicWriteType = .withResponse

    override init() {
        super.init()
        // 状态恢复：App 在后台被系统回收后，iOS 可为 BLE 事件重新拉起进程并归还连接
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    /// 修改 4 位蓝牙密码（默认 "1234"），下次握手生效
    func setPassword(_ newPassword: String) {
        let digits = newPassword.filter { $0.isNumber }.prefix(4)
        if digits.count == 4 { password = String(digits) }
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        connectionState = "正在搜索 TSL 模块…"
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func disconnect() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - 发送

    private func send(type: UInt8, payload: [UInt8] = []) {
        guard let peripheral = peripheral,
              peripheral.state == .connected,
              writeCharacteristic != nil else { return }
        pendingChunks = TSLFrame.chunks(TSLFrame.encode(type: type, payload: payload), size: 20)
        flushPendingWrites()
    }

    private func flushPendingWrites() {
        guard let peripheral = peripheral,
              let characteristic = writeCharacteristic,
              !pendingChunks.isEmpty else { return }
        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()
            peripheral.writeValue(chunk, for: characteristic, type: writeType)
            if writeType == .withResponse { break }   // 等 didWriteValue 再继续
        }
    }

    private func sendKey() {
        // tx(168, [4 个 ASCII 字节])，默认 "1234"
        let bytes = Array(password.utf8.prefix(4))
        guard bytes.count == 4 else { return }
        send(type: 168, payload: bytes)
    }

    private func completeAuth() {
        guard !authenticated else { return }
        authenticated = true
        connectionState = "已连接"
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        // 对应 JS gaugeHub：每 1.5s 发 tx(176, [0x01])，模块持续回 176 帧
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.send(type: 176, payload: [0x01])
        }
        send(type: 176, payload: [0x01])
    }

    // MARK: - 接收分发

    private func handle(_ frame: TSLFrameDecoder.Frame) {
        switch frame.type {
        case 160:   // 设备信息 / 运行固件就绪证明
            deviceInfoProofCount += 1
            // JS: 收到 2 次 160 且 deviceRuntimeReady 才算认证完成
            if !authenticated, deviceInfoProofCount >= 2,
               (frame.payload.first ?? 0) != 0 {
                completeAuth()
            }

        case 168:  // 密码校验回包：payload[0] 1=正确 0=错误 254/255=需要提交密码
            switch frame.payload.first ?? 255 {
            case 1:
                connectionState = "密码正确，等待运行固件"
                send(type: 160)
            case 0:
                connectionState = "蓝牙密码错误"
                // TODO: 弹出输入 4 位密码的界面后重新 sendKey()
            case 254, 255:
                sendKey()
            default:
                break
            }

        case 176:  // 仪表数据帧
            guard authenticated,
                  let state = GaugeFrame176.parse(frame.payload) else { return }
            latest = state
            // SpeedRefreshDriver 负责：写共享容器 + 节流刷新 Widget / Live Activity
            onSpeedUpdate?(state)

        default:
            break
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TSLBLEManager: CBCentralManagerDelegate {
    /// 后台被系统回收后重新拉起时，优先接管系统保留的 peripheral，不要重扫
    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = restored.first {
            self.peripheral = peripheral
            peripheral.delegate = self
            connectionState = "已恢复后台连接"
        }
        // 系统已保留的扫描目标不要再手动 scanForPeripherals
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // 已有恢复的连接时直接重新发现服务；后台扫描必须带 service UUID 过滤
            if let peripheral = self.peripheral, peripheral.state == .connected {
                peripheral.discoverServices([Self.serviceUUID])
            } else {
                startScanning()
            }
        case .poweredOff: connectionState = "蓝牙已关闭"
        case .unauthorized: connectionState = "未授权蓝牙"
        default: connectionState = "蓝牙不可用"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        connectionState = "正在连接…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = "正在发现服务…"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        heartbeat?.invalidate()
        heartbeat = nil
        authenticated = false
        deviceInfoProofCount = 0
        decoder.reset()
        connectionState = "已断开"
        onDisconnect?()
        // TODO: 自动重连（TSL 模块上车后会自动广播）
        startScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "连接失败"
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate

extension TSLBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let candidates = service.characteristics?.filter { $0.uuid == Self.characteristicUUID } ?? []
        writeCharacteristic = candidates.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
        notifyCharacteristic = candidates.first {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        guard let write = writeCharacteristic, let notify = notifyCharacteristic else {
            connectionState = "FFF1 特征不完整"
            return
        }
        writeType = write.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.setNotifyValue(true, for: notify)

        connectionState = "等待蓝牙密码验证"
        deviceInfoProofCount = 0
        send(type: 160)        // queryDeviceInfo，触发模块上报
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let value = characteristic.value else { return }
        for frame in decoder.feed(value) { handle(frame) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        flushPendingWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushPendingWrites()
    }
}

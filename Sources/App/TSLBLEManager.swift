import Foundation
import Combine
import CoreBluetooth

/// TSL 模块 BLE 连接（路径 A：独立原生 App 直连模块，不依赖微信壳）
///
/// 依赖：
///   - Info.plist 加 UIBackgroundModes = [ bluetooth-central ]（锁屏/后台保持 BLE）
///   - NSBluetoothAlwaysUsageDescription
///   - TSLFrameCodec.swift / GaugeFrame176.swift / GaugeExtras.swift
///   - BLELog.swift（全链路连接日志）/ ConnectionDiagnosticsView.swift（诊断界面）
///
/// 2026-11 修复：原实现假设「FFF1 同时可写 + 可通知」，只 discover FFF1 一个特征，
/// 遇到「FFF1 只写、FFE0 负责通知」的模块就会停在「FFF1 特征不完整」。
/// 现按原小程序 app-service.js 的真实规则全量发现并回退，见 didDiscoverCharacteristicsFor。
final class TSLBLEManager: NSObject, ObservableObject {

    static let shared = TSLBLEManager()

    static let serviceUUID = CBUUID(string: TSLConfig.serviceUUID)
    /// 状态恢复标识必须每次启动都相同，否则恢复链会断
    static let restoreIdentifier = TSLConfig.bleRestoreIdentifier

    // MARK: - 界面可观察状态

    @Published private(set) var connectionState = "未连接"
    @Published private(set) var stage: BLEStage = .idle
    @Published private(set) var hint = "正在初始化蓝牙…"
    @Published private(set) var authenticated = false
    @Published private(set) var latest: GaugeState?
    @Published private(set) var extras: GaugeExtras?
    @Published private(set) var frameCount = 0
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var deviceSummary = "-"
    @Published private(set) var serviceSummary = "-"
    @Published private(set) var characteristicSummary = "-"
    @Published private(set) var writeSummary = "-"
    @Published private(set) var notifySummary = "-"

    /// 收到新速度时回调，用于驱动 Live Activity 更新 / WidgetCenter.reloadTimelines
    var onSpeedUpdate: ((GaugeState) -> Void)?
    /// 断开时通知刷新驱动把实时活动标记为过期
    var onDisconnect: (() -> Void)?

    private let log = BLELog.shared

    // MARK: - BLE 对象

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    /// 订阅候选（按优先级）：FFF1（可写+可通知）→ FFE0 回退 → 其它可通知特征
    private var notifyCandidates: [CBCharacteristic] = []
    private let decoder = TSLFrameDecoder()

    private var heartbeat: Timer?
    private var watchdog: Timer?
    private var stageSince = Date()
    private var didWarn = false
    private var scanRestartCount = 0
    private var autoReconnect = true
    private var subscriptionSucceeded = false
    private var notifiedDataOnce = false
    private var fragmentCount = 0
    private var deviceInfoProofCount = 0
    private var lastAutoPilot = 0
    private var password = TSLConfig.defaultBLEPassword
    private var pendingChunks: [Data] = []
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var chunkSize = TSLFrame.defaultChunkSize

    override init() {
        super.init()
        // 状态恢复：App 在后台被系统回收后，iOS 可为 BLE 事件重新拉起进程并归还连接
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
        log.add(.info, "App 启动 · BLE 管理器已创建（恢复标识 \(Self.restoreIdentifier)）")
        log.add(.info, "协议配置：服务 FFF0 / 写特征 FFF1 / 通知特征 FFF1 或 FFE0 / 密码 \(password)")
        startWatchdog()
    }

    // MARK: - 阶段切换

    private func transition(_ newStage: BLEStage,
                            state: String? = nil,
                            hint newHint: String? = nil,
                            level: BLELogLevel = .info,
                            detail: String? = nil) {
        stage = newStage
        stageSince = Date()
        didWarn = false
        if let state { connectionState = state }
        if let newHint { hint = newHint }
        let suffix = detail.map { " · \($0)" } ?? ""
        log.add(level, "[\(newStage.label)] \(connectionState)\(suffix)")
    }

    // MARK: - 扫描 / 断开

    func startScanning() {
        autoReconnect = true
        guard central.state == .poweredOn else {
            transition(.bluetoothOff, state: "蓝牙不可用",
                       hint: "请先在 iPhone「设置 → 蓝牙」打开蓝牙，并允许本 App 使用蓝牙",
                       level: .error,
                       detail: "CBCentralManager.state=\(central.state.rawValue)")
            return
        }
        central.stopScan()
        decoder.reset()
        frameCount = 0
        lastFrameAt = nil
        notifiedDataOnce = false
        fragmentCount = 0
        scanRestartCount += 1
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        transition(.scanning, state: "正在搜索 TSL 模块…",
                   hint: "正在监听 FFF0 广播。若 12 秒无结果，会提示最可能的三个原因",
                   detail: "第 \(scanRestartCount) 次扫描")
    }

    private func restartScan() {
        guard central.state == .poweredOn, autoReconnect else { return }
        central.stopScan()
        scanRestartCount += 1
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        transition(.scanning, state: "重新搜索 TSL 模块…",
                   hint: "已自动重启扫描（第 \(scanRestartCount) 次）。模块上车通电后会自动广播",
                   detail: "自动重试")
    }

    func disconnect() {
        autoReconnect = false
        heartbeat?.invalidate()
        heartbeat = nil
        log.add(.info, "手动断开（暂停自动重连）")
        if let peripheral = peripheral { central.cancelPeripheralConnection(peripheral) }
        resetLink()
        transition(.disconnected, state: "已断开",
                   hint: "已暂停自动重连。点「重新扫描」可恢复")
    }

    private func resetLink() {
        authenticated = false
        deviceInfoProofCount = 0
        lastAutoPilot = 0
        subscriptionSucceeded = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        notifyCandidates = []
        pendingChunks = []
        decoder.reset()
        latest = nil
        extras = nil
        lastFrameAt = nil
        onDisconnect?()
    }

    /// 修改 / 重新提交 4 位蓝牙密码（默认 "1234"），立即重新握手，不用重连。
    /// 界面「重新提交密码」按钮直接调用这个。
    func submitPassword(_ newPassword: String) {
        let digits = newPassword.filter { $0.isNumber }.prefix(4)
        guard digits.count == 4 else {
            log.add(.warn, "密码必须是 4 位数字，收到「\(newPassword)」")
            hint = "密码必须是 4 位数字（模块默认 1234）"
            return
        }
        password = String(digits)
        guard isReadyToWrite else {
            log.add(.warn, "密码已记为 \(password)，但写特征未就绪，重连后生效")
            hint = "密码已保存为 \(password)；当前还没连上写特征，点「重新扫描」后会自动提交"
            return
        }
        authenticated = false
        deviceInfoProofCount = 0
        decoder.reset()
        transition(.awaitingAuth, state: "重新提交密码中…",
                   hint: "已发送新密码，等待模块回 168/160 帧；若仍提示密码错误请核对模块设置",
                   detail: "密码 \(password)")
        sendKey()
        // 160 = queryDeviceInfo，触发模块上报运行固件就绪证明；两帧用队列串行发送
        send(type: 160)
    }

    func setPassword(_ newPassword: String) {
        let digits = newPassword.filter { $0.isNumber }.prefix(4)
        if digits.count == 4 { password = String(digits) }
    }

    // MARK: - 看门狗

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkTimeouts()
        }
    }

    private func checkTimeouts() {
        if stage == .streaming {
            guard let last = lastFrameAt else { return }
            let silence = Date().timeIntervalSince(last)
            if silence >= TSLConfig.dataSilenceTimeout && !didWarn {
                didWarn = true
                log.add(.warn, "已 \(Int(silence))s 没有新仪表帧（心跳可能停了）")
                hint = "数据中断 \(Int(silence)) 秒：确认模块通电、原 App 没占用蓝牙；断线会自动重连"
            } else if silence < TSLConfig.dataSilenceTimeout && didWarn {
                didWarn = false
                log.add(.ok, "仪表数据恢复")
                hint = "连接正常，正在持续接收 176 帧"
            }
            return
        }

        let timeout = stage.timeout
        guard timeout > 0 else { return }
        let elapsed = Date().timeIntervalSince(stageSince)
        guard elapsed >= timeout, !didWarn else { return }
        didWarn = true

        switch stage {
        case .scanning:
            log.add(.warn, "扫描 \(Int(elapsed))s 未发现 FFF0 广播")
            hint = "没搜到模块：① 模块是否通电 ② 原「TSL模块管理」App 是否还连着蓝牙（BLE 单连接互斥）③ 两台 iPhone 不要同时连"
            restartScan()

        case .connecting:
            log.add(.error, "连接 \(Int(elapsed))s 未成功（常见于模块被其它 App 占用）")
            hint = "连接超时：先在原 App 里断开蓝牙或重启模块电源，再点「重新扫描」"
            if let peripheral = peripheral { central.cancelPeripheralConnection(peripheral) }
            restartScan()

        case .discoveringServices, .discoveringCharacteristics:
            log.add(.error, "\(stage.label) \(Int(elapsed))s 无回调")
            hint = "服务/特征发现卡住：多半连到了非 TSL 设备，或模块处于 BOOT/DFU 固件模式，点「重新扫描」重连"
            if let peripheral = peripheral { central.cancelPeripheralConnection(peripheral) }
            restartScan()

        case .subscribing:
            log.add(.warn, "订阅通知 \(Int(elapsed))s 无回调")
            hint = "订阅没回应：FFF1 可能只写不通知，代码会自动尝试 FFE0；若仍失败请看下方特征清单"
            tryNextNotifyCandidate(reason: "订阅超时")

        case .awaitingAuth:
            log.add(.warn, "认证 \(Int(elapsed))s 未完成，重发设备信息查询与密码")
            if subscriptionSucceeded {
                log.add(.warn, "订阅已成功但一帧都没收到，怀疑通知特征选错，尝试备用特征")
            }
            hint = "模块没回应 160/168 帧：检查 4 位密码；若模块在固件升级模式请先退出；也可点「重新提交密码」"
            if isReadyToWrite {
                send(type: 160)
                sendKey()
            }
            tryNextNotifyCandidate(reason: "认证超时，尝试备用通知特征")

        default:
            break
        }
    }

    // MARK: - 发送

    private var isReadyToWrite: Bool {
        guard let peripheral = peripheral, peripheral.state == .connected,
              writeCharacteristic != nil else { return false }
        return true
    }

    private func send(type: UInt8, payload: [UInt8] = []) {
        guard isReadyToWrite else {
            log.add(.warn, "发送 type=\(type) 被跳过：写特征或连接未就绪")
            return
        }
        // ⚠️ 用 append 而不是覆盖：连续 send(160) + sendKey() 时，
        // 若上一帧还在等 didWriteValueFor，覆盖会丢掉半个帧。
        pendingChunks.append(contentsOf: TSLFrame.chunks(
            TSLFrame.encode(type: type, payload: payload), size: chunkSize))
        if pendingChunks.count > 40 {
            pendingChunks.removeFirst(pendingChunks.count - 20)
            log.add(.warn, "写队列积压，丢弃最早的待发分片")
        }
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
        transition(.streaming, state: "已连接 · 实时数据",
                   hint: "连接正常：每 1.5s 请求一次 176 帧，桌面 / CarPlay 小组件与锁屏实时活动同步刷新",
                   level: .ok)
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
            let first = frame.payload.first ?? 0
            log.add(.data, "160 设备信息帧 len=\(frame.payload.count) first=0x\(String(format: "%02X", Int(first)))")
            deviceInfoProofCount += 1
            // JS: 收到 2 次 160 且 deviceRuntimeReady 才算认证完成
            if !authenticated, deviceInfoProofCount >= 2, first != 0 {
                completeAuth()
            }

        case 168:  // 密码校验回包：payload[0] 1=正确 0=错误 254/255=需要提交密码
            let code = frame.payload.first ?? 255
            switch code {
            case 1:
                log.add(.ok, "168 密码校验通过")
                transition(.awaitingAuth, state: "密码正确，等待运行固件",
                           hint: "密码已通过，正在等设备信息帧（160）确认运行固件就绪")
                send(type: 160)
            case 0:
                log.add(.error, "168 密码错误（当前提交的是 \(password)）")
                connectionState = "蓝牙密码错误"
                hint = "密码错误：在下方输入正确 4 位密码并点「重新提交密码」，不用重新连接蓝牙"
            case 254, 255:
                log.add(.info, "168 要求提交密码 → 发送 \(password)")
                sendKey()
            default:
                log.add(.warn, "168 未知回包 code=\(code)")
            }

        case 176:  // 仪表数据帧
            // 能收到仪表帧本身就是链路可用的最强证据，避免卡在「未认证」假阴性
            if !authenticated {
                log.add(.ok, "收到 176 仪表帧 → 视为链路已就绪，自动完成认证")
                completeAuth()
            }
            guard authenticated,
                  let state = GaugeFrame176.parse(frame.payload) else { return }
            let parsedExtras = GaugeFrame176.parseExtras(
                frame.payload, previousAutoPilot: lastAutoPilot)
            latest = state
            extras = parsedExtras
            if let parsedExtras = parsedExtras { lastAutoPilot = parsedExtras.autoPilot }
            // SpeedRefreshDriver 负责：写共享容器 + 节流刷新 Widget / Live Activity
            onSpeedUpdate?(state)

        default:
            log.add(.data, "其它帧 type=\(frame.type) len=\(frame.payload.count)")
        }
    }

    // MARK: - 特征描述工具

    private func propertiesText(_ properties: CBCharacteristicProperties) -> String {
        var items: [String] = []
        if properties.contains(.read) { items.append("read") }
        if properties.contains(.write) { items.append("write") }
        if properties.contains(.writeWithoutResponse) { items.append("writeNR") }
        if properties.contains(.notify) { items.append("notify") }
        if properties.contains(.indicate) { items.append("indicate") }
        return items.isEmpty ? "(无)" : items.joined(separator: ",")
    }

    private func describe(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.uuid.uuidString)[\(propertiesText(characteristic.properties))]"
    }

    private func matches(_ characteristic: CBCharacteristic, _ token: String) -> Bool {
        characteristic.uuid.uuidString.uppercased().contains(token)
    }

    private func isWritable(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.write)
            || characteristic.properties.contains(.writeWithoutResponse)
    }

    private func isNotifiable(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.notify)
            || characteristic.properties.contains(.indicate)
    }
}

// MARK: - CBCentralManagerDelegate

extension TSLBLEManager: CBCentralManagerDelegate {
    /// 后台被系统回收后重新拉起时，优先接管系统保留的 peripheral，不要重扫
    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        log.add(.info, "收到 BLE 状态恢复事件 willRestoreState")
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = restored.first {
            self.peripheral = peripheral
            peripheral.delegate = self
            deviceSummary = "\(peripheral.name ?? "未命名")（后台恢复）"
            transition(.discoveringServices, state: "已恢复后台连接",
                       hint: "系统保留了 BLE 连接，正在重新发现服务", level: .ok,
                       detail: deviceSummary)
            // 系统已保留的扫描目标不要再手动 scanForPeripherals
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.add(.ok, "蓝牙已开启（CBCentralManager.state = poweredOn）")
            if let peripheral = peripheral, peripheral.state == .connected {
                transition(.discoveringServices, state: "正在发现服务…",
                           hint: "已连接，正在读取模块的完整服务列表")
                peripheral.discoverServices(nil)
            } else if autoReconnect {
                startScanning()
            } else {
                transition(.idle, state: "蓝牙就绪（未连接）",
                           hint: "点「重新扫描」开始连接 TSL 模块")
            }

        case .poweredOff:
            transition(.bluetoothOff, state: "蓝牙已关闭",
                       hint: "请打开 iPhone 蓝牙；打开后 App 会自动重新扫描", level: .error)
        case .unauthorized:
            transition(.unauthorized, state: "未授权蓝牙",
                       hint: "iPhone「设置 → 隐私与安全性 → 蓝牙」里允许本 App，然后重开 App",
                       level: .error)
        case .unsupported:
            transition(.bluetoothOff, state: "设备不支持 BLE",
                       hint: "这台设备不支持蓝牙低功耗，无法连接 TSL 模块", level: .error)
        case .resetting:
            log.add(.warn, "蓝牙正在重置，等待 poweredOn")
            connectionState = "蓝牙正在重置"
        case .unknown:
            log.add(.info, "蓝牙状态未知，等待系统回调")
            connectionState = "蓝牙初始化中"
        @unknown default:
            log.add(.warn, "未知蓝牙状态 rawValue=\(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let shortID = String(peripheral.identifier.uuidString.prefix(8))
        deviceSummary = "\(peripheral.name ?? "未命名") · RSSI \(RSSI) dBm · \(shortID)"
        log.add(.ok, "发现 FFF0 设备：\(deviceSummary)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        transition(.connecting, state: "正在连接…",
                   hint: "已发现模块，正在建立 BLE 连接。若一直卡在这里，通常是被原 App 占用了连接",
                   detail: deviceSummary)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.add(.ok, "BLE 连接成功：\(peripheral.name ?? "未命名")")
        transition(.discoveringServices, state: "已连接，正在发现服务…",
                   hint: "连接已建立，正在读取服务列表（会显示全部服务，便于排查）", level: .ok)
        // 全量发现：诊断页要能看到「实际有哪些服务」，而不是只问 FFF0
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        heartbeat?.invalidate()
        heartbeat = nil
        let reason = error?.localizedDescription ?? "无错误信息"
        log.add(error == nil ? .warn : .error, "BLE 已断开：\(reason)")
        resetLink()
        transition(.disconnected, state: "已断开",
                   hint: autoReconnect ? "1.5 秒后自动重新扫描；若反复断开，检查原 App 是否占着蓝牙" : "已暂停自动重连，点「重新扫描」恢复")
        if autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.autoReconnect, self.stage == .disconnected else { return }
                self.startScanning()
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.add(.error, "连接失败：\(error?.localizedDescription ?? "未知原因")")
        transition(.disconnected, state: "连接失败",
                   hint: "连不上常见原因：模块被原 App / 另一台 iPhone 占用、模块未通电、距离过远",
                   level: .error)
        if autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.autoReconnect else { return }
                self.restartScan()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension TSLBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log.add(.error, "服务发现失败：\(error.localizedDescription)")
            transition(.failed, state: "服务发现失败",
                       hint: "读服务出错，点「重新扫描」重连；持续失败请确认模块固件正常", level: .error)
            return
        }
        let services = peripheral.services ?? []
        serviceSummary = services.isEmpty
            ? "(空)" : services.map { $0.uuid.uuidString }.joined(separator: ", ")
        log.add(.info, "实际服务列表：\(serviceSummary)")

        guard let service = services.first(where: {
            $0.uuid.uuidString.uppercased().contains(TSLConfig.serviceUUID.uppercased())
        }) else {
            transition(.failed, state: "未找到 FFF0 服务",
                       hint: "实际服务：\(serviceSummary)。可能连到非 TSL 设备，或模块处于 BOOT/DFU 固件模式",
                       level: .error)
            return
        }
        log.add(.ok, "命中 TSL 服务：\(service.uuid.uuidString)")
        transition(.discoveringCharacteristics, state: "正在发现特征…",
                   hint: "已找到 FFF0 服务，正在读取全部特征（FFF1 写 / FFF1 或 FFE0 通知）")
        // ⚠️ 必须全量发现：只问 FFF1 会漏掉负责通知的 FFE0，正是「特征不完整」的根因
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            log.add(.error, "特征发现失败：\(error.localizedDescription)")
            transition(.failed, state: "特征发现失败",
                       hint: "读特征出错，点「重新扫描」重连", level: .error)
            return
        }

        let all = service.characteristics ?? []
        characteristicSummary = all.isEmpty
            ? "(空)" : all.map { describe($0) }.joined(separator: "  ")
        log.add(.info, "FFF0 服务特征清单：\(characteristicSummary)")

        // ① 写特征：UUID 含 FFF1 且可写（原 JS: 未找到写特征（FFF1））
        guard let write = all.first(where: {
            matches($0, TSLConfig.writeCharacteristicUUID) && isWritable($0)
        }) else {
            transition(.failed, state: "FFF1 写特征未找到",
                       hint: "实际特征：\(characteristicSummary)。请确认连的是 TSL 模块，不是同名的其它 BLE 设备",
                       level: .error)
            return
        }
        writeCharacteristic = write
        writeSummary = describe(write)
        writeType = write.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        let maxLength = peripheral.maximumWriteValueLength(for: writeType)
        chunkSize = max(TSLFrame.defaultChunkSize, min(244, maxLength - 3))
        log.add(.ok, "写特征 → \(writeSummary)｜writeType=\(writeType == .withResponse ? "withResponse" : "withoutResponse")｜分片=\(chunkSize) 字节")

        // ② 通知特征：原 JS 的真实规则
        //    FFF1 同时「可通知 + 可写」→ 用 FFF1
        //    否则 → 找 UUID 含 FFE0 的特征（原 JS 不检查 FFE0 的 notify 属性）
        //    最后 → 兜底用任意可通知特征，并把候选按优先级排队逐个尝试订阅
        let writeFFF1 = all.first { matches($0, TSLConfig.writeCharacteristicUUID) }
        notifyCandidates = []
        if let candidate = writeFFF1, isNotifiable(candidate), isWritable(candidate) {
            notifyCandidates.append(candidate)
            log.add(.ok, "FFF1 同时可写+可通知 → 通知首选 FFF1")
        } else {
            log.add(.warn, "FFF1 不是「可写+可通知」组合 → 按原协议回退到 FFE0")
        }
        if let ffe0 = all.first(where: { matches($0, TSLConfig.notifyFallbackUUID) }) {
            if !notifyCandidates.contains(where: { $0.uuid == ffe0.uuid }) {
                notifyCandidates.append(ffe0)
            }
            log.add(.info, "FFE0 回退候选：\(describe(ffe0))")
        } else {
            log.add(.warn, "未发现 FFE0 特征（若 FFF1 可通知则不影响）")
        }
        for extra in all where isNotifiable(extra)
            && !notifyCandidates.contains(where: { $0.uuid == extra.uuid }) {
            notifyCandidates.append(extra)
        }

        guard !notifyCandidates.isEmpty else {
            transition(.failed, state: "通知特征未找到（FFF1/FFE0）",
                       hint: "实际特征：\(characteristicSummary)。模块可能处于固件升级模式，或需要先在原 App 里完成一次初始化",
                       level: .error)
            return
        }
        subscriptionSucceeded = false
        tryNextNotifyCandidate(reason: "开始订阅")
    }

    private func tryNextNotifyCandidate(reason: String) {
        guard frameCount == 0 else {
            log.add(.info, "\(reason)：已有数据帧，不再切换通知特征")
            return
        }
        guard let candidate = notifyCandidates.first else {
            log.add(.warn, "\(reason)：没有更多通知特征可尝试")
            transition(.failed, state: "通知订阅失败（FFF1/FFE0 都试过）",
                       hint: "所有通知特征都试过仍无数据：看上方特征清单，确认模块固件正常、不处于 BOOT/DFU 模式，再点「重新扫描」",
                       level: .error)
            return
        }
        notifyCandidates.removeFirst()
        notifyCharacteristic = candidate
        notifySummary = describe(candidate)
        transition(.subscribing, state: "正在订阅通知…",
                   hint: "正在对 \(candidate.uuid.uuidString) 开启 notify；失败会自动换下一个候选",
                   detail: notifySummary)
        peripheral?.setNotifyValue(true, for: candidate)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.add(.error, "订阅 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
            if notifyCharacteristic?.uuid == characteristic.uuid { notifyCharacteristic = nil }
            tryNextNotifyCandidate(reason: "订阅失败")
            return
        }
        guard characteristic.isNotifying else {
            log.add(.warn, "订阅 \(characteristic.uuid.uuidString) 返回成功但 isNotifying=false")
            tryNextNotifyCandidate(reason: "未真正开启通知")
            return
        }
        subscriptionSucceeded = true
        log.add(.ok, "订阅成功：\(characteristic.uuid.uuidString)（isNotifying=true）")
        transition(.awaitingAuth, state: "等待蓝牙密码验证",
                   hint: "通知已打开，正在查询设备信息（160）并验证 4 位密码（默认 1234）",
                   level: .ok,
                   detail: "通知特征 \(characteristic.uuid.uuidString)")
        deviceInfoProofCount = 0
        send(type: 160)        // queryDeviceInfo，触发模块上报
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.add(.error, "notify 读取失败：\(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value, !value.isEmpty else { return }
        if !notifiedDataOnce {
            notifiedDataOnce = true
            log.add(.ok, "收到首个 notify 数据包：\(characteristic.uuid.uuidString)，\(value.count) 字节")
        }
        let frames = decoder.feed(value)
        if frames.isEmpty {
            fragmentCount += 1
            if fragmentCount == 1 || fragmentCount % 20 == 0 {
                log.add(.warn, "收到 \(value.count) 字节但未解析出完整帧（累计 \(fragmentCount) 次）：可能是分片未对齐或校验和不匹配")
            }
            return
        }
        for frame in frames {
            frameCount += 1
            lastFrameAt = Date()
            if frameCount <= 5 || frameCount % 20 == 0 {
                log.add(.data, "帧 #\(frameCount) type=\(frame.type) len=\(frame.payload.count)")
            }
            if frameCount == 1 {
                // 已经收到数据，备用特征不再需要
                notifyCandidates.removeAll()
                log.add(.ok, "数据链路打通：写=\(writeSummary)｜通知=\(notifySummary)")
            }
            handle(frame)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.add(.error, "写入失败：\(error.localizedDescription)")
        }
        flushPendingWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushPendingWrites()
    }
}

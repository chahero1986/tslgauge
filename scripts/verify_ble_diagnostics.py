#!/usr/bin/env python3
"""编译前静态校验「BLE 连接诊断 + FFF1/FFE0 特征回退 + 字段清单」。

背景
--------------------------------------------------------------------------
真机反馈「界面显示 FFF1 特征不完整，无法判断蓝牙有没有连上」。
根因是原实现只 discover FFF1 一个特征、并假设它同时可写 + 可通知；
而原小程序 app-service.js 的真实规则是：

    service  = UUID 含 FFF0
    write    = UUID 含 FFF1 且可写
    notify   = FFF1 同时「可通知 + 可写」→ 用 FFF1
               否则 → UUID 含 FFE0 的特征
               都没有 → 抛「未找到通知特征（FFF1/FFE0）」

本脚本在 CI 编译前确认这些规则没被改回去，并确认全链路日志、看门狗、
密码重提、诊断界面、字段清单都还在。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


errors = []


def check(label, condition, detail=""):
    print(f"  {'PASS' if condition else 'FAIL'}  {label} {detail}")
    if not condition:
        errors.append(label)


def main() -> int:
    config = read("Sources/Shared/TSLConfig.swift")
    ble = read("Sources/App/TSLBLEManager.swift")
    log = read("Sources/App/BLELog.swift")
    ui = read("Sources/App/ConnectionDiagnosticsView.swift")
    app = read("Sources/App/TSLApp.swift")
    extras = read("Sources/App/GaugeExtras.swift")
    setup = read("SETUP.txt")
    workflow = read(".github/workflows/build-unsigned-ipa.yml")
    field_doc = ROOT / "可显示字段清单.txt"

    print("=== 1. FFF1 / FFE0 特征发现规则 ===")
    for token in ['static let serviceUUID = "FFF0"',
                  'static let writeCharacteristicUUID = "FFF1"',
                  'static let notifyFallbackUUID = "FFE0"']:
        check(f"配置含 {token}", token in config)
    check("服务发现是全量（能看到实际服务列表）", "discoverServices(nil" in ble)
    check("特征发现是全量（不会漏掉 FFE0）", "discoverCharacteristics(nil, for: service)" in ble)
    check("写特征优先 FFF1，FFF1 不可写时回退任意可写特征",
          "isWritable(preferred)" in ble
          and "all.first(where: isWritable)" in ble)
    check("写特征无任何可写回退时判定非 TSL 并跳过",
          "没有任何可写特征" in ble)
    check("FFF1 可通知+可写时优先用作通知",
          "isNotifiable(candidate), isWritable(candidate)" in ble)
    check("否则回退到 FFE0",
          'matches($0, TSLConfig.notifyFallbackUUID)' in ble)
    check("最后兜底任意可通知特征（覆盖角色对调固件）",
          "for extra in all where isNotifiable(extra)" in ble)
    check("通知候选按优先级排队逐个订阅",
          "notifyCandidates" in ble and "tryNextNotifyCandidate" in ble)
    check("订阅结果有回调校验 isNotifying",
          "didUpdateNotificationStateFor" in ble and "characteristic.isNotifying" in ble)
    # 只看字符串字面量；注释里回顾旧症状不算「还在报这个错」
    check("失败提示不再是笼统的 FFF1 特征不完整",
          '"FFF1 特征不完整"' not in ble)
    check("失败时说明原因并给出实际特征清单",
          "判定非 TSL 模块" in ble)
    check("写队列用 append 而不是覆盖（连续 send 不丢帧）",
          "pendingChunks.append(contentsOf:" in ble)
    check("按 MTU 计算分片大小",
          "maximumWriteValueLength(for: writeType)" in ble)

    print("\n=== 2. 全链路连接日志覆盖 ===")
    callbacks = [
        "centralManagerDidUpdateState", "willRestoreState", "didDiscover peripheral",
        "didConnect peripheral", "didDisconnectPeripheral", "didFailToConnect",
        "didDiscoverServices", "didDiscoverCharacteristicsFor",
        "didUpdateNotificationStateFor", "didUpdateValueFor", "didWriteValueFor",
        "peripheralIsReady",
    ]
    for name in callbacks:
        check(f"回调 {name}", name in ble)
    for token in ["log.add(.ok,", "log.add(.warn,", "log.add(.error,",
                  "log.add(.data,", "log.add(.info,"]:
        check(f"日志级别 {token}", token in ble)
    check("BLELog 有环形上限", "static let limit = 300" in log)
    check("BLELog 可从任意线程调用", "Thread.isMainThread" in log and "DispatchQueue.main.async" in log)
    check("BLELog 可导出文本", "func exportText()" in log)
    check("阶段枚举自带超时", "var timeout: TimeInterval" in log and "case .streaming:" in log)
    check("看门狗每秒巡检 + 数据静默判断",
          "checkTimeouts()" in ble and "TSLConfig.dataSilenceTimeout" in ble)
    check("收到 176 帧可自动解除未认证假阴性",
          "自动完成认证" in ble)

    print("\n=== 3. 诊断界面与密码重提 ===")
    check("密码可立即重新提交", "func submitPassword(" in ble and "sendKey()" in ble)
    check("主 App 用 sheet 挂上诊断页",
          "ConnectionDiagnosticsView(ble: ble, log: BLELog.shared)" in app
          and ".sheet(isPresented: $showDiagnostics)" in app)
    check("诊断页显示阶段 / 建议 / 帧数 / 距上次收帧",
          all(t in ui for t in ["ble.stage.label", "ble.hint", "ble.frameCount", "lastFrameText"]))
    check("诊断页显示实际服务 / 全部特征 / 写与通知特征",
          all(t in ui for t in ["ble.serviceSummary", "ble.characteristicSummary",
                                "ble.writeSummary", "ble.notifySummary"]))
    check("诊断页能复制 / 清空日志",
          "UIPasteboard.general.string" in ui and "log.clear()" in ui
          and "log.exportText()" in ui)
    check("诊断页能预览 176 帧全部字段", "ble.extras?.previewLines" in ui)
    check("主界面保持纯速度（只有状态入口按钮）",
          "SevenSegmentSpeedView(" in app and "TextField(" not in app)

    print("\n=== 4. 176 帧全字段解析（GaugeExtras）===")
    required_fields = [
        "gearLabel", "batteryPercent", "turnLabel", "autoPilotRaw", "autoPilot",
        "autoPilotLabel", "openDoors",
        "lightHex", "odometerKm", "frunkOpen", "trunkOpen", "sport",
        "tirePressuresBar", "accelPedalPercent", "frontPowerKW", "rearPowerKW",
        "totalPowerKW", "handsOn", "batteryHeatLabel", "speedLimitKmh",
        "blindSpotLabels", "altitudeM", "brakeTempsC", "remainRangeKm",
        "cellVoltageV", "batteryTempC", "ambientTempC", "cabinTempC",
        "blowerRPM", "evapWatts", "hasFullFrame",
    ]
    missing = [f for f in required_fields if f not in extras]
    check(f"字段齐全（{len(required_fields)} 项）", not missing, f"缺 {missing}")
    for token in ["0.025", "1.61", "0.002", "0x7F", "0x3FF_FFFF",
                  "fullFrameLength", "func signed(", "rounded(.down)",
                  "previousAutoPilot"]:
        check(f"位域/系数 {token}", token in extras)
    check("AP 抖动抑制状态在连接层持续传递",
          "previousAutoPilot: lastAutoPilot" in ble
          and "lastAutoPilot = parsedExtras.autoPilot" in ble)
    check("按帧长度分级判空（>=8 / >=12 / >=16 / >=33）",
          all(t in extras for t in ["payload.count >= 8", "payload.count >= 12",
                                    "payload.count >= 16", "payload.count >= fullFrameLength"]))
    check("不改动原 GaugeState 数据契约",
          "struct GaugeState" not in extras and "GaugeState(" not in extras)

    print("\n=== 5. 文档与 CI 接线 ===")
    check("可显示字段清单.txt 存在", field_doc.exists())
    if field_doc.exists():
        doc = field_doc.read_text(encoding="utf-8")
        check("清单含 A/B/C/D/E 分组与接入方式",
              all(t in doc for t in ["【A.", "【B.", "【C.", "【D.", "【E.", "【F."]))
        check("清单覆盖推荐字段",
              all(t in doc for t in ["档位", "剩余续航", "融合限速", "胎压", "AP", "盲区"]))
    check("SETUP.txt 有诊断与字段清单章节",
          "【11." in setup and "【12." in setup)
    check("workflow 有 Verify BLE diagnostics 步骤",
          "Verify BLE diagnostics" in workflow
          and "python3 scripts/verify_ble_diagnostics.py" in workflow)

    print("\n=== 6. 非 TSL 设备识别与拉黑（FFF0 撞车打印机） ===")
    check("配置含 RSSI 立即连接门槛", "rssiConnectThreshold" in config)
    check("配置含认证重试上限", "authRetryLimit" in config)
    check("发现设备先查拉黑清单", "rejectedDevices[peripheral.identifier]" in ble)
    check("名称含 TSL 优先连接", 'contains("TSL")' in ble)
    check("弱信号候选先暂存，扫描超时再退而连接",
          "pendingCandidate" in ble and "弱信号 FFF0 设备先观察" in ble)
    check("无 FFF0 服务 → 拉黑跳过",
          "rejectCurrentDevice(\"FFF0 服务不存在" in ble)
    check("无可写特征 → 拉黑跳过",
          "rejectCurrentDevice(\"FFF0 服务下没有任何可写特征" in ble)
    check("认证零回应超限 → 拉黑跳过",
          "authRetryCount >= TSLConfig.authRetryLimit" in ble
          and "零回应" in ble)
    check("拉黑清单在诊断页显示并导出",
          "rejectedSummary" in ble and "已跳过的非 TSL 设备" in ui)
    check("连接新候选时清空上一台诊断残留（防张冠李戴）",
          "serviceSummary = \"-\"" in ble)
    check("回前台补一次超时检查（修后台计时器挂起）",
          "willEnterForegroundNotification" in ble)
    check("连接失败 / 连接超时也会拉黑（不反复撞同一台）",
          "连接失败（" in ble and "无响应" in ble)

    print("\n=== 7. 双小组件数据链路 ===")
    state_src = read("Sources/Shared/GaugeExtrasState.swift")
    attributes_src = read("Sources/Shared/SpeedAttributes.swift")
    store_src = read("Sources/Shared/SharedSpeedStore.swift")
    driver_src = read("Sources/App/SpeedRefreshDriver.swift")
    bundle_src = read("Sources/Widget/TSLWidgetsBundle.swift")
    car_widget = ROOT / "Sources" / "Widget" / "CarBodyWidget.swift"
    check("共享展示契约 GaugeExtrasState 存在",
          "struct GaugeExtrasState" in state_src)
    check("契约含 demo 演示数据（小组件库预览）", "static let demo" in state_src)
    check("档位 / 电量 / 盲区配色函数齐全",
          all(t in state_src for t in ["func gearColor", "func batteryColor",
                                       "func blindSpotColor"]))
    check("Live Activity 契约携带 extras", "var extras: GaugeExtrasState?" in attributes_src)
    check("共享快照携带 extras", "var extras: GaugeExtrasState?" in store_src)
    check("数据链路把 GaugeExtras 映射进契约",
          "frameExtras" in driver_src and "GaugeExtrasState(" in driver_src)
    check("两个小组件 kind 同时刷新", "carBodyWidgetKind" in driver_src)
    check("主 App 把 ble.extras 传进驱动器", "frameExtras: ble.extras" in read("Sources/App/TSLApp.swift"))
    check("Bundle 注册 CarBodyWidget", "CarBodyWidget()" in bundle_src)
    check("车身状态地图小组件文件存在", car_widget.exists())

    print()
    if errors:
        print(f"=== FAIL: {len(errors)} 项 ===")
        for item in errors:
            print("  -", item)
        return 1
    print("=== ALL PASS: BLE 诊断链路、特征回退与字段清单完整 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())

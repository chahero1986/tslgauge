#!/usr/bin/env python3
"""校验小组件 3「纯手机仪表」的权限声明、App 接线与数据独立性。

与 verify_seven_segment.py 的分工：
  · verify_seven_segment.py 检查 UI 布局 / 段码 / 配色 / 传感器融合算法
  · 本脚本检查跨文件「接线」类约束——这些漏了不会编译报错，但真机上功能失效：
      - Info.plist 必须有定位 + 运动权限描述，否则 App 直接崩溃 / 拿不到数据
      - UIBackgroundModes 必须含 location，否则锁屏 / CarPlay 场景速度停更
      - 主 App 必须 start() 传感器、诊断页必须能校准
      - 第三小组件的 kind 三处一致（Config / Widget / reload）
      - 手机数据与 BLE 数据写入【不同】文件，互不覆盖
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

APP_PLIST = ROOT / "App" / "Info.plist"
CONFIG = ROOT / "Sources" / "Shared" / "TSLConfig.swift"
APP = ROOT / "Sources" / "App" / "TSLApp.swift"
SENSOR = ROOT / "Sources" / "App" / "PhoneSensorManager.swift"
STATE = ROOT / "Sources" / "Shared" / "PhoneGaugeState.swift"
WIDGET = ROOT / "Sources" / "Widget" / "PhoneGaugeWidget.swift"
DIAGNOSTICS = ROOT / "Sources" / "App" / "ConnectionDiagnosticsView.swift"
WORKFLOW = ROOT / ".github" / "workflows" / "build-unsigned-ipa.yml"

errors = []


def check(label, condition, detail=""):
    print(f"  {'PASS' if condition else 'FAIL'}  {label} {detail}")
    if not condition:
        errors.append(label)


def read(path):
    return path.read_text(encoding="utf-8")


def main() -> int:
    print("=== 1. Info.plist 权限（漏了会崩溃或拿不到数据） ===")
    plist = read(APP_PLIST)
    for key in ["NSLocationAlwaysAndWhenInUseUsageDescription",
                "NSLocationWhenInUseUsageDescription",
                "NSMotionUsageDescription"]:
        check(f"含 {key}", f"<key>{key}</key>" in plist)
    check("UIBackgroundModes 含 location（锁屏/CarPlay 后台定位）",
          "<key>UIBackgroundModes</key>" in plist and "<string>location</string>" in plist)
    check("保留 bluetooth-central（原 BLE 链路不受影响）",
          "<string>bluetooth-central</string>" in plist)

    print("\n=== 2. kind 三处一致 ===")
    config = read(CONFIG)
    widget = read(WIDGET)
    sensor = read(SENSOR)
    check("Config 定义 phoneGaugeWidgetKind",
          'phoneGaugeWidgetKind = "TSLPhoneGaugeWidget"' in config)
    check("Widget 声明用 TSLConfig.phoneGaugeWidgetKind",
          "let kind = TSLConfig.phoneGaugeWidgetKind" in widget)
    check("采集层 reload 用同一 kind",
          "reloadTimelines(ofKind: widgetKind)" in sensor
          and "let widgetKind = TSLConfig.phoneGaugeWidgetKind" in sensor)

    print("\n=== 3. 主 App 接线 ===")
    app = read(APP)
    check("主界面启动 PhoneSensorManager",
          "PhoneSensorManager.shared.start()" in app)
    diag = read(DIAGNOSTICS)
    check("诊断页持有传感器状态", "PhoneSensorManager.shared" in diag)
    check("诊断页提供校准按钮（坡度/G 水平基准）", "phone.calibrate()" in diag)

    print("\n=== 4. 数据独立：不与车辆速度快照互相覆盖 ===")
    state = read(STATE)
    check("手机仪表用独立文件名 tsl-phone-gauge.json",
          'filename = "tsl-phone-gauge.json"' in state)
    check("车辆速度快照仍是 tsl-speed-snapshot.json",
          'filename = "tsl-speed-snapshot.json"' in read(ROOT / "Sources" / "Shared" / "SharedSpeedStore.swift"))
    # 注意：PhoneGaugeState 含 GaugeState 子串，不能用裸子串匹配
    check("传感器层不引用 TSLBLEManager / GaugeExtras / GaugeState（零车辆依赖）",
          "TSLBLEManager" not in sensor
          and "GaugeExtras" not in sensor
          and "GaugeState(" not in sensor.replace("PhoneGaugeState", ""))

    print("\n=== 5. CI 接线 ===")
    workflow = read(WORKFLOW)
    check("workflow 有 Verify phone gauge 步骤",
          "Verify phone gauge" in workflow
          and "python3 scripts/verify_phone_gauge.py" in workflow)

    print()
    if errors:
        print(f"=== FAIL: {len(errors)} 项 ===")
        for item in errors:
            print("  -", item)
        return 1
    print("=== ALL PASS: 手机仪表权限 / 接线 / 数据独立正确 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())

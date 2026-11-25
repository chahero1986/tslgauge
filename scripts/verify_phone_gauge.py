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

    print("\n=== 5. 无 App Group 时的定位缓存降级（自签场景小组件不显示 -- 的根因修复） ===")
    widget_src = read(WIDGET)
    check("Widget 引入 CoreLocation 读系统定位缓存",
          "import CoreLocation" in widget_src)
    check("降级读 CLLocationManager.location（不依赖 App Group）",
          "manager.location" in widget_src
          and "CachedLocationFallback" in widget_src)
    check("缓存为空时主动 requestLocation（带超时兜底）",
          "manager.requestLocation()" in widget_src
          and "DispatchQueue.main.asyncAfter" in widget_src
          and "CLLocationManagerDelegate" in widget_src)
    check("Timeline 入口先读共享文件、再降级缓存",
          "let shared = store.read()" in widget_src
          and "fallback.cachedState()" in widget_src
          and "fallback.requestState" in widget_src)
    check("缓存快照用定位时间判定新鲜度（旧数据自动降透明度）",
          "updatedAt: location.timestamp" in widget_src)
    check("Entry 标记降级来源 fromCacheFallback",
          "fromCacheFallback" in widget_src and "let fromCacheFallback: Bool" in widget_src)
    check("缓存降级仍走原 7 段码与配色（无重复实现）",
          "SpeedPalette.color(for: speed)" in widget_src)
    check("Widget Info.plist 含定位权限（否则扩展读缓存被系统拒绝）",
          "<key>NSLocationWhenInUseUsageDescription</key>" in read(ROOT / "Widget" / "Info.plist"))

    print("\n=== 6. 手机仪表 Live Activity（切后台仍秒级实时的关键） ===")
    attrs = read(ROOT / "Sources" / "Shared" / "PhoneGaugeActivityAttributes.swift")
    controller = read(ROOT / "Sources" / "App" / "PhoneGaugeActivityController.swift")
    live = read(ROOT / "Sources" / "Widget" / "PhoneGaugeLiveActivity.swift")
    bundle = read(ROOT / "Sources" / "Widget" / "TSLWidgetsBundle.swift")
    check("Activity 契约复用 PhoneGaugeState（typealias，规避构造器顺序坑）",
          "typealias ContentState = PhoneGaugeState" in attrs)
    check("控制器用本地更新 pushType nil（自签无 APNs 也能跑）",
          "pushType: nil" in controller)
    check("控制器后台时把坡度 / 纵向 G 清空为 --（不拿冻结姿态冒充实时）",
          'slopeText: "坡 --"' in controller and 'gText: "-- G"' in controller)
    check("Live Activity 用 7 段码 + 分段配色",
          "SevenSegmentNumber" in live and "SpeedPalette.color" in live)
    check("?: 两端显式 Color（避免上次编译的类型不一致）",
          "Color.orange" in live and "Color.secondary" in live)
    check("WidgetBundle 注册手机仪表 Live Activity",
          "PhoneGaugeLiveActivity()" in bundle)

    print("\n=== 7. 刷新策略（修后台烧预算 + 缩短兜底间隔） ===")
    check("传感器层驱动 Live Activity 更新",
          "PhoneGaugeActivityController.shared.update" in sensor)
    check("Widget reload 加前台判断（后台不计入预算浪费）",
          "applicationState != .active" in sensor
          and "if !inBackground" in sensor
          and "reloadTimelines(ofKind: widgetKind)" in sensor)
    check("timeline 兜底间隔缩短到 1 分钟",
          "value: 1, to: Date()" in widget_src)

    print("\n=== 8. CI 接线 ===")
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

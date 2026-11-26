#!/usr/bin/env python3
"""校验主 App 完整仪表 + HUD 抬头显示镜像。

背景
--------------------------------------------------------------------------
用户真机反馈：蓝牙已连上、首页速度已显示，但「软件打开界面只有速度」，
要求把三个小组件里的信息都搬进 App；并加一个 HUD 开关，按下后字全部
反向显示，方便手机平放仪表台、内容经前挡风玻璃反射后正向可读。

本脚本在 CI 编译前确认这些接线没被改回去（漏了不报编译错，但功能静默失效）：
  · 主入口用 ExpandedDashboardView，且三个数据源对象都接好
  · 完整仪表覆盖速度主表 + 车况 + 手机传感器三组字段
  · HUD 只镜像内容层、控制按钮留在外层，且镜像状态持久化
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

APP = ROOT / "Sources" / "App" / "TSLApp.swift"
DASH = ROOT / "Sources" / "App" / "ExpandedDashboardView.swift"
WORKFLOW = ROOT / ".github" / "workflows" / "build-unsigned-ipa.yml"

errors = []


def check(label, condition, detail=""):
    print(f"  {'PASS' if condition else 'FAIL'}  {label} {detail}")
    if not condition:
        errors.append(label)


def read(path):
    return path.read_text(encoding="utf-8")


def main() -> int:
    app = read(APP)
    dash = read(DASH)

    print("=== 1. 主入口接线 ===")
    check("主入口实例化 ExpandedDashboardView",
          "ExpandedDashboardView(" in app)
    check("传入 ble / driver / phone 三个数据源",
          all(t in app for t in ["ble: ble", "driver: SpeedRefreshDriver.shared", "phone: phone"]))
    check("App 持有 phone 的 StateObject",
          "@StateObject private var phone = PhoneSensorManager.shared" in app)
    check("BLE 速度回调仍驱动刷新链路",
          "SpeedRefreshDriver.shared.ingest(state, frameExtras: ble.extras)" in app)
    check("仍启动 BLE 扫描与手机传感器",
          "ble.startScanning()" in app and "PhoneSensorManager.shared.start()" in app)

    print("\n=== 2. 完整仪表覆盖三组小组件字段 ===")
    # 速度主仪表
    for token in ["speedText", "gearText", "apActive", "batteryText",
                  "turnLeftActive", "turnRightActive", "limitText",
                  "cabinText", "ambientText"]:
        check(f"速度主表字段 {token}", token in dash)
    check("速度仍用 7 段码 + 分段配色",
          "SevenSegmentNumber(" in dash
          and "SpeedPalette.color(for: speed)" in dash)
    # 车况
    for token in ["tirePressuresBar", "brakeTempsC", "openDoors",
                  "frunkOpen", "trunkOpen", "blindSpotLabels",
                  "lightHex", "batteryHeatLabel"]:
        check(f"车况字段 {token}", token in dash)
    check("车况配色沿用 GaugePalette",
          all(t in dash for t in ["GaugePalette.blindSpotColor",
                                  "GaugePalette.batteryHeatColor",
                                  "GaugePalette.gearColor",
                                  "GaugePalette.batteryColor"]))
    # 手机传感器
    for token in ["headingLabel", "altitudeM", "slopeText", "gText"]:
        check(f"手机传感器字段 {token}", token in dash)
    check("手机数据取自 phone.lastSnapshot",
          "phone.lastSnapshot?" in dash)
    check("四轮胎压/刹车温度按 4 个索引取",
          "tire(left)" in dash and "tire(right)" in dash
          and "brake(left)" in dash and "brake(right)" in dash)
    check("车门顺序与 GaugeExtras 解析一致（左前/右前/左后/右后）",
          '["左前门", "右前门", "左后门", "右后门"]' in dash)

    print("\n=== 3. HUD 抬头显示镜像 ===")
    check("HUD 开关持久化（镜像）",
          '@AppStorage("tsl_hud_mirrored")' in dash)
    check("上下翻转开关持久化（不同平放方式）",
          '@AppStorage("tsl_hud_vertical_flip")' in dash)
    check("镜像作用于内容层（scaleEffect x 取反）",
          ".scaleEffect(x: hudMirrored ? -1 : 1" in dash)
    check("上下翻转作用于 y 轴",
          "y: hudVerticalFlip ? -1 : 1" in dash)
    check("控制层独立于镜像容器（按钮不被镜像）",
          "controls" in dash and "hudButton" in dash and "diagnosticsButton" in dash)
    # 关键顺序：controls 必须与镜像后的 ScrollView 是兄弟节点、在其之后，
    # 而不是嵌在 ScrollView 里——否则按钮会被一起镜像。
    scale_pos = dash.find(".scaleEffect(x: hudMirrored")
    controls_def = dash.find("private var controls")
    controls_use = dash.rfind("            controls")
    check("controls 在镜像 ScrollView 之外（兄弟节点）",
          scale_pos != -1 and controls_def != -1 and controls_use > scale_pos,
          f"scale@{scale_pos} controlsDef@{controls_def} controlsUse@{controls_use}")
    check("HUD 按钮可切换并带无障碍标签",
          "hudMirrored.toggle()" in dash and "关闭 HUD 镜像" in dash)
    check("HUD 开启后才出现上下翻转微调按钮",
          "if hudMirrored" in dash and "flipButton" in dash)

    print("\n=== 4. CI 接线 ===")
    workflow = read(WORKFLOW)
    check("workflow 有 Verify expanded dashboard 步骤",
          "Verify expanded dashboard" in workflow
          and "python3 scripts/verify_expanded_dashboard.py" in workflow)

    print()
    if errors:
        print(f"=== FAIL: {len(errors)} 项 ===")
        for item in errors:
            print("  -", item)
        return 1
    print("=== ALL PASS: 完整仪表与 HUD 镜像接线正确 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())

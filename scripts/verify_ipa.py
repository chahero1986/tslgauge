#!/usr/bin/env python3
"""校验未签名 IPA 的结构（macOS / Windows / Linux 均可运行）。

检查项：
  - Payload/*.app 与 PlugIns/*.appex 是否齐全
  - 主 App 的蓝牙后台模式 / Live Activity 开关 / Info.plist 变量是否已展开
  - Extension 的 NSExtensionPointIdentifier 是否为 widgetkit
  - 两个 Info.plist 的 TSLAppGroup 是否一致
  - 是否确实【未签名】（无 _CodeSignature / embedded.mobileprovision）
"""
import argparse
import plistlib
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath


def read_plist(zf, name):
    with zf.open(name) as fh:
        return plistlib.load(fh)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("--list", action="store_true", help="打印 IPA 内主要结构")
    args = ap.parse_args()

    ipa = Path(args.ipa)
    if not ipa.is_file():
        print(f"[FAIL] 找不到 IPA: {ipa}", file=sys.stderr)
        return 1

    errors = []
    with zipfile.ZipFile(ipa) as zf:
        names = zf.namelist()

        app_plists = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(app_plists) != 1:
            errors.append(f"主 App Info.plist 数量应为 1，实际 {len(app_plists)}: {app_plists}")
            app_info = {}
            app_prefix = ""
        else:
            app_info = read_plist(zf, app_plists[0])
            app_prefix = str(PurePosixPath(app_plists[0]).parent) + "/"

        appex_plists = [n for n in names
                        if re.fullmatch(r"Payload/[^/]+\.app/PlugIns/[^/]+\.appex/Info\.plist", n)]
        if len(appex_plists) != 1:
            errors.append(f"Widget Extension Info.plist 数量应为 1，实际 {len(appex_plists)}: {appex_plists}")
            ext_info = {}
        else:
            ext_info = read_plist(zf, appex_plists[0])

        # ---- 主 App ----
        modes = app_info.get("UIBackgroundModes") or []
        if "bluetooth-central" not in modes:
            errors.append("主 App 缺少 UIBackgroundModes / bluetooth-central")
        if not app_info.get("NSSupportsLiveActivities"):
            errors.append("主 App 缺少 NSSupportsLiveActivities = YES")
        if not app_info.get("NSBluetoothAlwaysUsageDescription"):
            errors.append("主 App 缺少 NSBluetoothAlwaysUsageDescription")

        # ---- Extension ----
        point = (ext_info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
        if point != "com.apple.widgetkit-extension":
            errors.append(f"Extension 类型不正确: {point!r}")

        # ---- 变量展开 & App Group 一致性 ----
        app_group = app_info.get("TSLAppGroup") or ""
        ext_group = ext_info.get("TSLAppGroup") or ""
        for label, value in (("主 App", app_group), ("Extension", ext_group)):
            if str(value).startswith("$("):
                errors.append(f"{label} 的 TSLAppGroup 未被 xcodebuild 展开: {value!r}")
        if app_group != ext_group:
            errors.append(f"两个 target 的 TSLAppGroup 不一致: {app_group!r} vs {ext_group!r}")
        display = str(app_info.get("CFBundleDisplayName") or "")
        if display.startswith("$("):
            errors.append(f"CFBundleDisplayName 未展开: {display!r}")

        # ---- 未签名 ----
        leftovers = [n for n in names
                     if n.endswith("embedded.mobileprovision")
                     or "/_CodeSignature/" in n]
        if leftovers:
            errors.append(f"发现签名残留（未签名 IPA 不应有）: {leftovers[:5]}")
        if "Payload/iTunesMetadata.plist" in names:
            errors.append("发现 iTunesMetadata.plist，疑似商店包而非开发包")

        print("=== IPA 校验 ===")
        print(f"  文件            : {ipa.name} ({ipa.stat().st_size:,} bytes)")
        print(f"  主 App          : {app_info.get('CFBundleIdentifier', '?')}")
        print(f"  Extension       : {ext_info.get('CFBundleIdentifier', '?')}")
        print(f"  显示名          : {display or '?'}")
        if app_group == "__NO_APP_GROUP__":
            group_display = "(未启用 → Widget 降级, Live Activity 不受影响)"
        else:
            group_display = app_group or "(空 → Widget 降级, Live Activity 不受影响)"
        print(f"  App Group       : {group_display}")
        print(f"  蓝牙后台模式    : {modes}")
        print(f"  Live Activity   : {bool(app_info.get('NSSupportsLiveActivities'))}")
        print(f"  appex 路径      : {appex_plists[0] if appex_plists else '(缺失)'}")

        if args.list:
            print("\n=== IPA 主要结构 ===")
            keep = [n for n in names
                    if n.startswith("Payload/") and
                    (n.count("/") <= 4 or n.endswith(("Info.plist", ".appex/TSLWidgets", "TSLGauge")))]
            for n in sorted(keep)[:80]:
                print("  ", n)

        if errors:
            print("\n=== FAIL ===")
            for e in errors:
                print("  -", e)
            return 1

    print("\n=== PASS: 结构完整，可交给自签工具 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())

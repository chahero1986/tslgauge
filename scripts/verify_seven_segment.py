#!/usr/bin/env python3
"""校验 7 段数码管字形表与速度分段配色（不依赖 Xcode，CI 里也能跑）。

直接从 Sources/Shared/SevenSegment.swift 解析实现，逐项比对标准 7 段真值表，
并验证 0~60 / 61~100 / >100 的边界，避免改 UI 时把段码或阈值写错。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARED = ROOT / "Sources" / "Shared" / "SevenSegment.swift"
WIDGET = ROOT / "Sources" / "Widget" / "SpeedWidget.swift"
ACTIVITY = ROOT / "Sources" / "Widget" / "SpeedLiveActivity.swift"

EXPECTED = {
    "0": "abcdef",
    "1": "bc",
    "2": "abdeg",
    "3": "abcdg",
    "4": "bcfg",
    "5": "acdfg",
    "6": "acdefg",
    "7": "abc",
    "8": "abcdefg",
    "9": "abcdfg",
    "-": "g",
}

errors = []


def check(label, condition, detail=""):
    print(f"  {'PASS' if condition else 'FAIL'}  {label} {detail}")
    if not condition:
        errors.append(label)


def main() -> int:
    src = SHARED.read_text(encoding="utf-8")

    print("=== 1. 段位定义 ===")
    bit_line = re.search(r"^\s*static let (a\s*=\s*\d+.*)$", src, re.M)
    if not bit_line:
        print("  FAIL  找不到 a~g 位定义")
        return 1
    bits = {name: int(value) for name, value in re.findall(r"(\w+)\s*=\s*(\d+)", bit_line.group(1))}
    print("  bits:", bits)
    check("7 个段位齐全且为 2 的幂", sorted(bits) == list("abcdefg") and
          sorted(bits.values()) == [1, 2, 4, 8, 16, 32, 64])
    check("allMask = 127", sum(bits.values()) == 127)

    print("\n=== 2. 字形真值表 ===")
    cases = re.findall(r'case\s*"([^"]+)"\s*:\s*return\s+([a-g](?:\s*\|\s*[a-g])*)', src)
    parsed = {}
    for character, expression in cases:
        names = re.findall(r"[a-g]", expression)
        parsed[character] = (sum(bits[n] for n in names), "".join(sorted(set(names))))
    check("覆盖 0~9 与 '-'", set(parsed) == set(EXPECTED),
          f"实际 {sorted(parsed)}")
    for character, segments in EXPECTED.items():
        actual = parsed.get(character)
        ok = actual is not None and actual[1] == "".join(sorted(segments))
        check(f"'{character}' → {segments}", ok,
              f"实际 {actual[1] if actual else '缺失'} (mask={actual[0] if actual else '-'})")

    print("\n=== 3. 速度分段配色边界 ===")
    thresholds = [int(v) for v in re.findall(r"if speed <= (\d+)", src)]
    print("  thresholds:", thresholds)
    check("阈值为 60 / 100", thresholds == [60, 100])

    def bucket(value):
        if value is None or value < 0:
            return "none"
        if value <= thresholds[0]:
            return "low"
        if value <= thresholds[1]:
            return "mid"
        return "high"

    for value, want in [(None, "none"), (-1, "none"), (0, "low"), (30, "low"),
                        (60, "low"), (61, "mid"), (88, "mid"), (100, "mid"),
                        (101, "high"), (180, "high"), (511, "high")]:
        check(f"{str(value):>4} → {want}", bucket(value) == want)

    print("\n=== 4. 界面纯净度与 CarPlay 兼容 ===")
    widget_src = WIDGET.read_text(encoding="utf-8")
    activity_src = ACTIVITY.read_text(encoding="utf-8")
    check("Widget 使用 SevenSegmentSpeedView", "SevenSegmentSpeedView(" in widget_src)
    check("Widget 默认无状态点（纯数字）", "showsStatusDot: false" in widget_src)
    check("Widget 仍支持 systemSmall（CarPlay 必需）", ".systemSmall" in widget_src)
    check("Widget 未残留标题/单位文字", "Text(\"TSL 车速\")" not in widget_src)
    check("Live Activity 也用 7 段数码管", "SevenSegmentSpeedView(" in activity_src)
    check("Live Activity 用数值而非解析显示串", "state.speed" in activity_src)

    print()
    if errors:
        print(f"=== FAIL: {len(errors)} 项 ===")
        for item in errors:
            print("  -", item)
        return 1
    print("=== ALL PASS: 7 段码与配色规则正确 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())

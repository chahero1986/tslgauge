#!/usr/bin/env python3
"""编译前静态校验 Swift「逐一构造器」(memberwise initializer) 的调用点。

背景 / 为什么要这个脚本
--------------------------------------------------------------------------
Swift 编译器要求结构体 memberwise init 的实参顺序与属性声明顺序【完全一致】，
且默认必须提供全部 stored property。给结构体插入新字段时，只要漏改或插错
某个调用点，本地看不出来，只有 GitHub Actions 跑到 xcodebuild 才会报：

    error: argument 'speed' must precede argument 'unit'

一次 macOS runner 编译要几分钟。本脚本直接解析源码，把这类错误提前到
编译前的秒级检查里；同时检查括号平衡、@main 数量、target 归属等工程约束。

校验对象（数据契约结构体，全是纯 stored property）：
    SpeedActivityAttributes.ContentState  Sources/Shared/SpeedAttributes.swift
    SpeedSnapshot                         Sources/Shared/SharedSpeedStore.swift
    SpeedEntry                            Sources/Widget/SpeedWidget.swift
    GaugeState                            Sources/App/GaugeFrame176.swift
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

DECL_FILES = {
    "ContentState": "Sources/Shared/SpeedAttributes.swift",
    "SpeedSnapshot": "Sources/Shared/SharedSpeedStore.swift",
    "SpeedEntry": "Sources/Widget/SpeedWidget.swift",
    "GaugeState": "Sources/App/GaugeFrame176.swift",
}

# 防止正则失效时「零调用 = 全部通过」的假阳性
MIN_CALLS = {"ContentState": 4, "SpeedSnapshot": 3, "SpeedEntry": 3, "GaugeState": 1}

errors = []


def check(label, condition, detail=""):
    print(f"  {'PASS' if condition else 'FAIL'}  {label} {detail}")
    if not condition:
        errors.append(label)


def strip_comments(src: str) -> str:
    """把注释替换成空格（保留换行与字符偏移），字符串字面量保持原样。"""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif src[i] == '"':
            j = skip_string(src, i)
            i = j
        else:
            i += 1
    return "".join(out)


def skip_string(src: str, i: int) -> int:
    """i 指向开头的双引号，返回字符串结束后的下标。"""
    j = i + 1
    while j < len(src):
        if src[j] == "\\":
            j += 2
            continue
        if src[j] == '"':
            return j + 1
        j += 1
    return len(src)


def blank_strings(src: str) -> str:
    """把字符串字面量内容抹成空格，避免 "$(" 这类内容干扰括号平衡统计。"""
    out = list(src)
    i = 0
    while i < len(src):
        if src[i] == '"':
            j = skip_string(src, i)
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def match_paren(src: str, i: int) -> int:
    """i 指向 '('，返回与之配对的 ')' 下标（跳过字符串里的括号）。"""
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        if c == '"':
            j = skip_string(src, j)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def match_brace(src: str, i: int) -> int:
    """i 指向 '{'，返回与之配对的 '}' 下标。"""
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        if c == '"':
            j = skip_string(src, j)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def split_top_level(text: str):
    """按顶层逗号切分实参列表（嵌套调用 / 数组 / 字符串里的逗号不算）。"""
    parts, buf, depth, i = [], [], 0, 0
    while i < len(text):
        c = text[i]
        if c == '"':
            j = skip_string(text, i)
            buf.append(text[i:j])
            i = j
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    parts.append("".join(buf))
    return parts


def struct_body(src: str, name: str):
    m = re.search(r"\bstruct\s+" + re.escape(name) + r"\b[^{]*\{", src)
    if not m:
        return None
    open_idx = m.end() - 1
    close_idx = match_brace(src, open_idx)
    if close_idx < 0:
        return None
    return src[open_idx + 1:close_idx]


def stored_properties(body: str):
    """按声明顺序取 stored property；跳过 computed property（行内含 { }）。"""
    fields = []
    for line in body.splitlines():
        if "{" in line or "}" in line:
            continue
        m = re.match(
            r"^\s*(?:(?:public|private|internal|fileprivate)\s+)?"
            r"(?:var|let)\s+(\w+)\s*:",
            line,
        )
        if m:
            fields.append(m.group(1))
    return fields


def call_sites(src: str, name: str):
    """返回 [(行号, [实参标签...]), ...]，只处理带标签的调用。"""
    result = []
    for m in re.finditer(r"\b" + re.escape(name) + r"\s*\(", src):
        open_idx = src.rfind("(", m.start(), m.end())
        close_idx = match_paren(src, open_idx)
        if close_idx < 0:
            continue
        # 排除 `let x: Type(...)` 之外的声明性文本（正常源码里不会出现）
        args = src[open_idx + 1:close_idx]
        labels = []
        for segment in split_top_level(args):
            lm = re.match(r"^\s*(\w+)\s*:", segment)
            labels.append(lm.group(1) if lm else None)
        line = src.count("\n", 0, m.start()) + 1
        result.append((line, labels))
    return result


def main() -> int:
    swift_files = sorted(SOURCES.rglob("*.swift"))
    clean = {p.as_posix(): strip_comments(p.read_text(encoding="utf-8"))
             for p in swift_files}

    print("=== 1. 括号平衡 / 工程约束 ===")
    pairs = {"{": "}", "(": ")", "[": "]"}
    for path, src in clean.items():
        stack, ok = [], True
        for ch in blank_strings(src):
            if ch in pairs:
                stack.append(pairs[ch])
            elif ch in pairs.values():
                if not stack or stack.pop() != ch:
                    ok = False
                    break
        ok = ok and not stack
        rel = path.replace((ROOT.as_posix() + "/"), "")
        check(f"{rel} 括号平衡", ok)
    mains = [p.name for p, s in zip(swift_files, clean.values()) if "@main" in s]
    check("@main 恰好 2 个（主 App + Widget Extension）", len(mains) == 2, str(mains))
    check("无残留 YOURTEAM 占位符",
          all("YOURTEAM" not in s for s in clean.values()))

    print("\n=== 2. 结构体逐一构造器声明顺序 ===")
    declarations = {}
    for name, rel in DECL_FILES.items():
        body = struct_body(clean[(ROOT / rel).as_posix()], name)
        fields = stored_properties(body) if body is not None else []
        declarations[name] = fields
        check(f"{name} 声明顺序可读 ({len(fields)} 字段)", bool(fields),
              " → ".join(fields))

    # 速度配色依赖 ContentState / SpeedSnapshot 都带原始数值
    check("ContentState 含 speed（供分段配色）",
          "speed" in declarations.get("ContentState", []))
    check("SpeedSnapshot 含 speed（供分段配色）",
          "speed" in declarations.get("SpeedSnapshot", []))

    print("\n=== 3. 所有调用点：实参数量与顺序 ===")
    for name, fields in declarations.items():
        calls = []
        for path, src in clean.items():
            for line, labels in call_sites(src, name):
                calls.append((path.replace((ROOT.as_posix() + "/"), ""), line, labels))
        check(f"{name} 调用点数量 ≥ {MIN_CALLS[name]}", len(calls) >= MIN_CALLS[name],
              f"实际 {len(calls)} 处")
        for rel, line, labels in calls:
            where = f"{rel}:{line}"
            expected = list(fields)
            ok_set = (None not in labels and set(labels) == set(expected)
                      and len(labels) == len(expected))
            ok_order = labels == expected
            check(f"{name} @ {where}", ok_set and ok_order,
                  f"声明={expected} 实参={labels}")

    print("\n=== 4. Extension 侧配色使用原始数值 ===")
    activity = clean[(ROOT / "Sources/Widget/SpeedLiveActivity.swift").as_posix()]
    widget = clean[(ROOT / "Sources/Widget/SpeedWidget.swift").as_posix()]
    check("Live Activity 用 state.speed 取色", "state.speed" in activity)
    check("Widget 用 snapshot.speed 取色", "speed: speed" in widget)
    check("?: 两侧显式 Color（避免 ShapeStyle 类型不一致）",
          "Color.orange" in activity and "Color.secondary" in activity)

    print()
    if errors:
        print(f"=== FAIL: {len(errors)} 项 ===")
        for item in errors:
            print("  -", item)
        return 1
    print("=== ALL PASS: Swift 逐一构造器调用顺序与工程约束正确 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())

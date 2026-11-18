#!/usr/bin/env python3
"""根据 workflow 输入改写 project.yml 的 Bundle ID，并做基础合法性校验。

环境变量：
  TSL_BUNDLE_ID      主 App Bundle ID，默认 com.tsl.gauge
  TSL_BUNDLE_ID_EXT  Widget Extension Bundle ID，默认 <主>.widgets
  TSL_APP_GROUP      App Group ID，可为空
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "project.yml"

bundle_id = os.environ.get("TSL_BUNDLE_ID", "com.tsl.gauge").strip()
ext_id = os.environ.get("TSL_BUNDLE_ID_EXT", "").strip() or (bundle_id + ".widgets")
app_group = os.environ.get("TSL_APP_GROUP", "").strip()

if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.\-]*[A-Za-z0-9]", bundle_id) or "." not in bundle_id:
    sys.exit(f"[configure] 非法 Bundle ID: {bundle_id!r}（应为反向域名，如 com.example.gauge）")
if app_group and not app_group.startswith("group."):
    print(f"[configure] 警告: App Group 通常以 group. 开头，当前为 {app_group!r}", file=sys.stderr)

lines = SPEC.read_text(encoding="utf-8").splitlines(keepends=True)
out = []
seen = 0
for line in lines:
    m = re.match(r"^(\s*PRODUCT_BUNDLE_IDENTIFIER:\s*)([^\s#]+)(.*)$", line)
    if m:
        value = bundle_id if seen == 0 else ext_id
        ending = "\n" if line.endswith("\n") else ""
        out.append(f"{m.group(1)}{value}{m.group(3).rstrip()}{ending}")
        seen += 1
    else:
        out.append(line)

if seen != 2:
    sys.exit(f"[configure] project.yml 中应恰好有 2 个 PRODUCT_BUNDLE_IDENTIFIER，实际 {seen} 个")

SPEC.write_text("".join(out), encoding="utf-8")

print("=== configure ===")
print(f"  主 App Bundle ID       : {bundle_id}")
print(f"  Widget Ext Bundle ID   : {ext_id}")
print(f"  App Group              : {app_group or '(空 → 走降级路径)'}")
print(f"  已更新                 : {SPEC.relative_to(ROOT)}")

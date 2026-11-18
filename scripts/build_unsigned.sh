#!/usr/bin/env bash
# 在 macOS（本机或 GitHub Actions runner）上生成【未签名 IPA】。
# 产物：build/TSLGauge-unsigned.ipa  —— 交给 Windows 上的 Sideloadly / AltStore 自签。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 留空时写入哨兵，保证 Info.plist 变量一定被展开成确定值
APP_GROUP="${TSL_APP_GROUP:-__NO_APP_GROUP__}"
[[ -n "$APP_GROUP" ]] || APP_GROUP="__NO_APP_GROUP__"
DISPLAY_NAME="${TSL_DISPLAY_NAME:-TSL 车速}"

echo "=== 0. 环境 ==="
xcodebuild -version
sw_vers

echo "=== 1. 准备 XcodeGen ==="
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
  fi
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "::error::xcodegen 不可用，且 brew install 未能安装" >&2
  exit 1
fi
xcodegen --version

echo "=== 2. 生成 Xcode 工程 ==="
xcodegen generate

echo "=== 3. 编译（关闭签名）==="
rm -rf "$ROOT/build"
mkdir -p "$ROOT/build"
DERIVED="$ROOT/build/DerivedData"
LOG="$ROOT/build/xcodebuild.log"
set -o pipefail
xcodebuild \
  -project TSLGauge.xcodeproj \
  -scheme TSLGauge \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ENTITLEMENTS_REQUIRED=NO \
  "TSL_APP_GROUP=$APP_GROUP" \
  "TSL_DISPLAY_NAME=$DISPLAY_NAME" \
  clean build 2>&1 | tee "$LOG"

echo "=== 4. 组装未签名 IPA ==="
APP_DIR="$(find "$DERIVED/Build/Products" -maxdepth 4 -type d -name 'TSLGauge.app' -print -quit)"
if [[ -z "$APP_DIR" ]]; then
  echo "::error::未找到 TSLGauge.app，编译产物目录内容如下：" >&2
  find "$DERIVED/Build/Products" -maxdepth 4 -print >&2 || true
  exit 1
fi

mkdir -p "$ROOT/build/Payload"
cp -R "$APP_DIR" "$ROOT/build/Payload/TSLGauge.app"
# 未签名构建理论上不会有这些，清掉以兼容对签名敏感的重签工具
rm -rf "$ROOT/build/Payload/TSLGauge.app/_CodeSignature" \
       "$ROOT/build/Payload/TSLGauge.app/embedded.mobileprovision"

APPEX="$ROOT/build/Payload/TSLGauge.app/PlugIns/TSLWidgets.appex"
if [[ ! -d "$APPEX" ]]; then
  echo "::error::IPA 内缺少 PlugIns/TSLWidgets.appex —— 小组件和实时活动都会消失" >&2
  find "$ROOT/build/Payload/TSLGauge.app" -maxdepth 3 -print >&2
  exit 1
fi

( cd "$ROOT/build" && zip -qry TSLGauge-unsigned.ipa Payload )

echo "=== 5. 结构自检 ==="
python3 scripts/verify_ipa.py "$ROOT/build/TSLGauge-unsigned.ipa"

echo "=== 6. 构建信息 ==="
GROUP_NOTE="$APP_GROUP"
if [[ "$APP_GROUP" == "__NO_APP_GROUP__" ]]; then
  GROUP_NOTE="(未启用 → 桌面 Widget 降级, Live Activity / CarPlay 实时不受影响)"
fi
{
  echo "TSLGauge 未签名 IPA 构建信息"
  echo "----------------------------------------"
  echo "时间        : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Xcode       : $(xcodebuild -version | tr '\n' ' ')"
  echo "macOS       : $(sw_vers -productVersion)"
  echo "Bundle ID   : $(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER' project.yml | awk '{print $2}')"
  echo "App Group   : $GROUP_NOTE"
  echo "显示名      : $DISPLAY_NAME"
  echo "----------------------------------------"
  echo "IPA SHA256  : $(shasum -a 256 "$ROOT/build/TSLGauge-unsigned.ipa" | awk '{print $1}')"
  echo "IPA 体积    : $(du -h "$ROOT/build/TSLGauge-unsigned.ipa" | awk '{print $1}')"
  echo ""
  echo "IPA 结构："
  python3 scripts/verify_ipa.py "$ROOT/build/TSLGauge-unsigned.ipa" --list
} > "$ROOT/build/build-info.txt"
cat "$ROOT/build/build-info.txt"

echo "=== DONE: build/TSLGauge-unsigned.ipa ==="

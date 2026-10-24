#!/usr/bin/env bash
# 用法：
#   ./build.sh           编译并生成 build/Lucent.app
#   ./build.sh install   编译、安装到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")"

APP=Lucent
BUNDLE="build/${APP}.app"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP" "$BUNDLE/Contents/MacOS/$APP"
strip -x "$BUNDLE/Contents/MacOS/$APP"          # 去掉本地符号，减小体积
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp -R Resources/Fonts "$BUNDLE/Contents/Resources/Fonts"               # Doto / JetBrains Mono，启动时注册
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"     # 程序图标（scripts/make-icon.sh 生成）
# 用本机 Apple Development 证书签名：签名身份固定，钥匙串里记住的账号更新后不再弹授权框。
# 没有证书的机器退回 ad-hoc 签名（登录启动仍可用，但每次更新后读钥匙串会弹一次）。
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$BUNDLE"
else
    codesign --force --sign - "$BUNDLE"
fi

echo "✓ 已生成 ${BUNDLE}（$(du -sh "$BUNDLE" | cut -f1)）"

if [[ "${1:-}" == "install" ]]; then
    pkill -x "$APP" 2>/dev/null || true
    rm -rf "/Applications/${APP}.app"
    cp -R "$BUNDLE" /Applications/
    open "/Applications/${APP}.app"
    echo "✓ 已安装到 /Applications 并启动"
fi

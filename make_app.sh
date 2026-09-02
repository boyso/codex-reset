#!/bin/bash
# 构建并打包 CodexReset.app（带图标，ad-hoc 签名）
# 用法：
#   ./make_app.sh                    # 安装到 /Applications（不可写时自动回退 ~/Applications）
#   INSTALL_DIR="$HOME/Applications" ./make_app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CodexReset"
BUNDLE_ID="com.codexreset.CodexReset"

# 1. 编译 release
echo "==> swift build -c release"
swift build -c release

BIN=".build/release/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "错误：找不到 $BIN" >&2
    exit 1
fi

# 2. 确定安装目录：优先 /Applications，不可写则回退 ~/Applications
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    echo "==> /Applications 不可写，回退安装到 $INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"

APP="$INSTALL_DIR/$APP_NAME.app"
echo "==> 组装 $APP"

# 3. 用 logo.png 生成应用图标（支持透明底/不规则：居中补透明画布 + LANCZOS 高质量缩放）
ICON_SRC="Resources/AppIcon.icns"
if [ -f "logo.png" ]; then
    echo "==> 从 logo.png 生成 AppIcon.icns（透明底/不规则）"
    if ! python3 Resources/generate_icon.py logo.png "$ICON_SRC" 2>/dev/null; then
        echo "    PIL 不可用，回退 sips 生成（需方形源图）"
        ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
        mkdir -p "$ICONSET_DIR"
        for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" \
                    "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" \
                    "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" \
                    "1024:icon_512x512@2x.png"; do
            px="${spec%%:*}"
            name="${spec##*:}"
            sips -z "$px" "$px" logo.png --out "$ICONSET_DIR/$name" >/dev/null 2>&1
        done
        iconutil -c icns "$ICONSET_DIR" -o "$ICON_SRC" 2>/dev/null || true
        rm -rf "$(dirname "$ICONSET_DIR")"
    fi
fi

# 4. 组装 bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
[ -f logo.png ] && cp logo.png "$APP/Contents/Resources/logo.png" || true
[ -f Resources/icon_1024.png ] && cp Resources/icon_1024.png "$APP/Contents/Resources/icon_1024.png" || true

# 5. 签名：优先固定证书（辅助功能授权持久），否则用本机 Apple Development 证书（用哈希避免同名 ambiguous），最后 ad-hoc
CERT="CodexResetDev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT\""; then
    echo "==> codesign ($CERT)"
    codesign --force --deep --sign "$CERT" "$APP"
elif DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')"; [ -n "$DEV_ID" ]; then
    echo "==> codesign (Apple Development: $DEV_ID)"
    codesign --force --deep --sign "$DEV_ID" "$APP"
else
    echo "==> codesign (ad-hoc)"
    codesign --force --deep --sign - "$APP"
    echo "    提示：运行 ./make_cert.sh 创建固定证书，可避免每次打包后辅助功能授权失效"
fi

echo "==> 完成：$APP"
echo "    下一步：./install_launchagent.sh 安装开机自启"

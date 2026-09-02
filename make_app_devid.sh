#!/bin/bash
# Developer ID 签名 + 公证打包 CodexReset.app
# 用法：
#   先一次性配置：创建 Developer ID Application 证书 + 配置 notary 凭据（见下方注释）
#   ./make_app_devid.sh                    # 签名+公证+staple+安装到 /Applications
#
# 前置准备（一次即可）：
#   1) 创建 Developer ID Application 证书：
#      Xcode → Settings → Accounts → 选中团队 → Manage Certificates → + → Developer ID Application
#   2) 生成 Apple ID 专用密码：appleid.apple.com → 登录与安全 → App 专用密码（生成一个）
#   3) 配置 notary 凭据（专用密码只在此处输入一次，存入钥匙串）：
#      xcrun notarytool store-credentials "CodexGuard-Notary" \
#          --apple-id "你的AppleID邮箱" --team-id "DXE4MMW55S" --password "专用密码"
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CodexReset"
PROFILE="CodexGuard-Notary"

# 1. 查找 Developer ID Application 证书（用哈希避免同名 ambiguous）
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')"
if [ -z "$DEV_ID" ]; then
    echo "错误：未找到 Developer ID Application 证书。" >&2
    echo "请在 Xcode → Settings → Accounts → Manage Certificates 中创建 Developer ID Application 证书。" >&2
    exit 1
fi
echo "==> 使用证书：$DEV_ID"

# 2. 编译 release
echo "==> swift build -c release"
swift build -c release

# 3. 组装 bundle（临时目录）
BUILD_DIR="$(mktemp -d)"
APP="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICON_SRC="Resources/AppIcon.icns"
[ -f logo.png ] && cp logo.png "$APP/Contents/Resources/logo.png" || true
[ -f Resources/icon_1024.png ] && cp Resources/icon_1024.png "$APP/Contents/Resources/icon_1024.png" || true
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

# 4. 签名（hardened runtime，公证必需）
echo "==> codesign (Developer ID, hardened runtime)"
codesign --force --options runtime --sign "$DEV_ID" "$APP"

# 5. 公证（1-3 分钟）
ZIP="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> 提交公证（notarytool --wait，可能需要 1-3 分钟）…"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
    echo "错误：公证失败。若提示找不到凭据，请先执行：" >&2
    echo "  xcrun notarytool store-credentials \"$PROFILE\" --apple-id 你的邮箱 --team-id DXE4MMW55S --password 专用密码" >&2
    exit 1
fi

# 6. staple（把公证凭证打进 app，离线也可验证）
echo "==> stapler staple"
xcrun stapler staple "$APP"

# 7. 安装到 /Applications（不可写则回退 ~/Applications）
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    echo "==> /Applications 不可写，回退安装到 $INSTALL_DIR"
fi
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"

# 8. 重启 LaunchAgent 使其生效
echo "==> 重启 LaunchAgent"
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.codexreset.CodexReset.plist 2>/dev/null || true
sleep 1
./install_launchagent.sh >/dev/null 2>&1 || true

echo "==> 完成：$INSTALL_DIR/$APP_NAME.app（Developer ID + 公证）"
echo "    现在重新勾选一次辅助功能授权，之后重新打包不再失效。"

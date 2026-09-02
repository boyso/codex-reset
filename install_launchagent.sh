#!/bin/bash
# 安装 LaunchAgent：登录时自动启动 CodexReset 菜单栏 app
# 用法：./install_launchagent.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CodexReset"
BUNDLE_ID="com.codexreset.CodexReset"

# 与 make_app.sh 相同的安装目录逻辑
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [ ! -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    INSTALL_DIR="$HOME/Applications"
fi
APP_PATH="$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
if [ ! -x "$APP_PATH" ]; then
    echo "错误：找不到 $APP_PATH，请先运行 ./make_app.sh" >&2
    exit 1
fi

LA="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
mkdir -p "$HOME/Library/LaunchAgents"

# 生成 LaunchAgent（替换 app 路径）
sed "s|__APP_PATH__|$APP_PATH|g" Resources/launchd.plist > "$LA"

# 先卸载旧注册再注册
launchctl bootout "gui/$(id -u)" "$LA" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA"

echo "==> 已安装 LaunchAgent：$LA"
echo "==> 已启动（登录时也会自动启动）"
echo "    卸载：./uninstall.sh"

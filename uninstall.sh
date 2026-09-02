#!/bin/bash
# 卸载 CodexReset：停止并移除 LaunchAgent，删除 .app
# 用法：./uninstall.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CodexReset"
BUNDLE_ID="com.codexreset.CodexReset"
LA="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

# 1. 停止并移除 LaunchAgent
if [ -f "$LA" ]; then
    echo "==> 停止并移除 LaunchAgent"
    launchctl bootout "gui/$(id -u)" "$LA" 2>/dev/null || true
    rm -f "$LA"
fi

# 2. 删除 .app（两个候选位置）
for d in /Applications "$HOME/Applications"; do
    if [ -d "$d/$APP_NAME.app" ]; then
        echo "==> 删除 $d/$APP_NAME.app"
        rm -rf "$d/$APP_NAME.app"
    fi
done

echo "==> 卸载完成"

#!/bin/zsh
set -e

LABEL="com.heic2jpg.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DIR="$HOME/Applications/heic2jpg.app"

echo "Stopping heic2jpg..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true

rm -f "$PLIST_PATH"
rm -rf "$APP_DIR"
# Clean up old binary-only install if present
rm -f "$HOME/.local/bin/heic2jpg" "$HOME/.local/bin/heic2jpg.swift"

echo "Uninstalled."

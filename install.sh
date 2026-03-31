#!/bin/zsh
set -e

APP_DIR="$HOME/Applications/heic2jpg.app"
BINARY_PATH="$APP_DIR/Contents/MacOS/heic2jpg"
PLIST_DIR="$HOME/Library/LaunchAgents"
LABEL="com.heic2jpg.agent"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"

# Unload existing agent if present
launchctl unload "$PLIST_PATH" 2>/dev/null || true

echo "Building heic2jpg..."
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -O -o "$BINARY_PATH" heic2jpg.swift

# Create app bundle Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<'INFOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.heic2jpg.app</string>
	<key>CFBundleName</key>
	<string>heic2jpg</string>
	<key>CFBundleExecutable</key>
	<string>heic2jpg</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
INFOPLIST

echo "Installing launch agent..."
mkdir -p "$PLIST_DIR"

# Build the list of watch directories from arguments, or use defaults
if [ $# -gt 0 ]; then
    DIRS=("$@")
else
    DIRS=("$HOME/Desktop" "$HOME/Downloads")
fi

# Generate ProgramArguments XML
ARGS_XML="		<string>$BINARY_PATH</string>"
for dir in "${DIRS[@]}"; do
    ARGS_XML="$ARGS_XML
		<string>$dir</string>"
done

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
$ARGS_XML
	</array>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/tmp/heic2jpg.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"
echo ""
echo "heic2jpg is running."
echo "Watching: ${DIRS[*]}"
echo "Logs: /tmp/heic2jpg.log"
echo ""
echo "To uninstall: ./uninstall.sh"

#!/bin/bash
# Builds DeepSeek.app (release) into ./build/.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/DeepSeek"
APP="build/DeepSeek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeepSeek"

# App icon from the harness macOS icon.
ICONSET="build/AppIcon.iconset"
if [ ! -f build/AppIcon.icns ]; then
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-macos.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon-macos.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle ripgrep for the glob/grep tools when available.
RG=""
for c in "$HOME/deepseek-harness/node_modules/.pnpm/@vscode+ripgrep-darwin-arm64@"*/node_modules/@vscode/ripgrep-darwin-arm64/bin/rg \
         "$HOME/deepseek-harness/node_modules/.pnpm/@vscode+ripgrep@"*/node_modules/@vscode/ripgrep/bin/rg \
         /opt/homebrew/bin/rg /usr/local/bin/rg; do
  if [ -x "$c" ]; then RG="$c"; break; fi
done
if [ -n "$RG" ]; then cp "$RG" "$APP/Contents/Resources/rg"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DeepSeek</string>
  <key>CFBundleDisplayName</key><string>DeepSeek</string>
  <key>CFBundleIdentifier</key><string>ai.deepseek.harness.native</string>
  <key>CFBundleExecutable</key><string>DeepSeek</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

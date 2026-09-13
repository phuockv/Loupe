#!/bin/bash
# Đóng gói ProxyManCloneApp thành một .app bundle thật.
#
# Vì sao cần: `swift run` chạy binary trần, không nằm trong bundle. Một tiến
# trình như vậy không có icon Dock, không vào được Cmd+Tab, và — quan trọng
# nhất — không trình được hộp thoại uỷ quyền admin, nên nút "Cài Root CA"
# thất bại với "The authorization was denied since no user interaction was
# possible". Chạy qua `open` một bundle thật thì nó vào đúng phiên Aqua và
# hộp thoại mật khẩu hiện bình thường.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
APP="ProxyManClone.app"
BIN="ProxyManCloneApp"

swift build -c "$CONFIG" --product "$BIN"
BUILT=$(swift build -c "$CONFIG" --product "$BIN" --show-bin-path)/"$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$BIN</string>
    <key>CFBundleIdentifier</key><string>com.proxymanclone.app</string>
    <key>CFBundleName</key><string>ProxyManClone</string>
    <key>CFBundleDisplayName</key><string>ProxyManClone</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign. KHÔNG phải notarize — đủ để chạy trên máy này, không đủ để
# phát hành cho máy khác. Xem pre-release blocker trong nhật ký quyết định.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Đã dựng $APP ($CONFIG)"
echo "Chạy:  open $APP"

#!/bin/bash
# Build the release binary and wrap it into .build/Mole Review.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
swift_args=()
if [[ "${MOLE_SWIFTPM_NO_SANDBOX:-0}" == 1 ]]; then swift_args+=(--disable-sandbox); fi
swift build -c release ${swift_args[@]+"${swift_args[@]}"}
BIN="$(swift build -c release ${swift_args[@]+"${swift_args[@]}"} --show-bin-path)/MoleReview"
APP=".build/Mole Review.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MoleReview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>fit.mole.review.local</string>
    <key>CFBundleName</key><string>Mole Review</string>
    <key>CFBundleDisplayName</key><string>Mole Review</string>
    <key>CFBundleExecutable</key><string>MoleReview</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
codesign --verify "$APP"
echo "Built $APP"

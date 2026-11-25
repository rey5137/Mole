#!/bin/bash
# Build the release binary and wrap it into .build/Mole Review.app.
# Signed with the login-keychain identity "Mole Review Local" (create it once with
# ./make-signing-cert.sh) so macOS keeps the app's privacy grants (Full Disk Access,
# folder access) across rebuilds; without it the app is ad-hoc signed, and every build
# is a new identity to macOS.
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
cat > "$APP/Contents/Info.plist" << 'PLIST'
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
# shellcheck source=signing-identity.sh
source "$(dirname "$0")/signing-identity.sh"
HASH=$(mole_review_identity_hash)
signed=0
if [[ -n "$HASH" ]]; then
    if codesign --force -s "$HASH" "$APP"; then
        echo "Signed with \"$MOLE_REVIEW_IDENTITY\" ($HASH)"
        signed=1
    else
        echo "warning: codesign with \"$MOLE_REVIEW_IDENTITY\" failed (locked keychain or key access denied?); falling back to ad-hoc." >&2
    fi
else
    echo "warning: no \"$MOLE_REVIEW_IDENTITY\" signing identity; ad-hoc signing, so macOS will ask for folder access again after each build. Run ./make-signing-cert.sh once." >&2
fi
if [[ "$signed" == 0 ]]; then codesign --force -s - "$APP"; fi
codesign --verify "$APP"
echo "Built $APP"

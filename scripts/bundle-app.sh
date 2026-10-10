#!/bin/sh
# Builds dist/TokenGlance.app from the SwiftPM products and signs it ad hoc.
# The statusline hook ships in Contents/Resources; the installer copies it from there to
# ~/Library/Application Support/TokenGlance/bin when the user installs the hook.
set -eu
cd "$(dirname "$0")/.."

config="${CONFIG:-release}"
# Optional: extra `swift build` flags (e.g. SWIFT_FLAGS="-Xswiftc -DTG_STRESS" for the measurement
# build described in docs/perf.md) and another output folder (OUT_DIR, default dist).
swift_flags="${SWIFT_FLAGS:-}"
out_dir="${OUT_DIR:-dist}"
bundle_id="io.github.yim0327.token-glance"
# Single source of truth for the version: the VERSION file (e.g. 0.1.0). The build number is the
# commit count, so every build from a later commit sorts higher.
version="$(tr -d ' \n' < VERSION)"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# shellcheck disable=SC2086 # swift_flags is a list of flags
swift build -c "$config" $swift_flags --product TokenGlanceApp
# shellcheck disable=SC2086
swift build -c "$config" $swift_flags --product token-glance-hook
# shellcheck disable=SC2086
bin="$(swift build -c "$config" $swift_flags --show-bin-path)"

app="$out_dir/TokenGlance.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/TokenGlanceApp" "$app/Contents/MacOS/TokenGlance"
cp "$bin/token-glance-hook" "$app/Contents/Resources/token-glance-hook"
# Localized strings (SwiftPM resource bundle of TokenGlanceText). Located by Localizer in
# Contents/Resources; without it the app would only work next to the build directory.
resources="$bin/token-glance_TokenGlanceText.bundle"
if [ ! -d "$resources" ]; then
    echo "missing resource bundle: $resources" >&2
    exit 1
fi
cp -R "$resources" "$app/Contents/Resources/"
# App icon (Finder, Get Info, alerts, notifications). Built from assets/AppIcon/AppIcon.svg by
# scripts/make-app-icon.sh; the .icns is committed so bundling does not render it.
icon="assets/AppIcon/AppIcon.icns"
if [ ! -s "$icon" ]; then
    echo "missing app icon: $icon (run scripts/make-app-icon.sh)" >&2
    exit 1
fi
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
chmod 755 "$app/Contents/MacOS/TokenGlance" "$app/Contents/Resources/token-glance-hook"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>TokenGlance</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Token Glance</string>
    <key>CFBundleDisplayName</key><string>Token Glance</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Anthropic or OpenAI.</string>
</dict>
</plist>
PLIST

# Ad hoc signature (no Apple Developer account): sign the nested hook first, then the app.
codesign --force --sign - "$app/Contents/Resources/token-glance-hook"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "$app"

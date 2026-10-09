#!/bin/sh
# Builds dist/TokenGlance.app from the SwiftPM products and signs it ad hoc.
# The statusline hook ships in Contents/Resources; the installer copies it from there to
# ~/Library/Application Support/TokenGlance/bin when the user installs the hook.
set -eu
cd "$(dirname "$0")/.."

config="${CONFIG:-release}"
bundle_id="io.github.yim0327.token-glance"
# Single source of truth for the version: the VERSION file (e.g. 0.1.0). The build number is the
# commit count, so every build from a later commit sorts higher.
version="$(tr -d ' \n' < VERSION)"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$config" --product TokenGlanceApp
swift build -c "$config" --product token-glance-hook
bin="$(swift build -c "$config" --show-bin-path)"

app="dist/TokenGlance.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/TokenGlanceApp" "$app/Contents/MacOS/TokenGlance"
cp "$bin/token-glance-hook" "$app/Contents/Resources/token-glance-hook"
chmod 755 "$app/Contents/MacOS/TokenGlance" "$app/Contents/Resources/token-glance-hook"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>TokenGlance</string>
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

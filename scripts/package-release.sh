#!/bin/sh
# Builds dist/TokenGlance.app, checks it, and writes the release zip and its SHA-256 checksum to
# dist/release (git-ignored). Used locally and by .github/workflows/release.yml.
#
# Checks: Info.plist version = VERSION, app and hook built for the same architectures, the
# localized string tables, the service mark SVGs and the app icon are inside the app (the icon
# named in Info.plist and equal to assets/AppIcon/AppIcon.icns), and the ad hoc signature verifies.
set -eu
cd "$(dirname "$0")/.."

version="$(tr -d ' \n' < VERSION)"
./scripts/bundle-app.sh

app="dist/TokenGlance.app"
plist="$app/Contents/Info.plist"
fail() { echo "package-release: $*" >&2; exit 1; }

short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[ "$short" = "$version" ] || fail "CFBundleShortVersionString $short does not match VERSION $version"
case "$build" in ''|*[!0-9]*) fail "CFBundleVersion '$build' is not a number" ;; esac

for file in Contents/MacOS/TokenGlance Contents/Resources/token-glance-hook \
    Contents/Resources/token-glance_TokenGlanceText.bundle/en.lproj/Localizable.strings \
    Contents/Resources/token-glance_TokenGlanceText.bundle/ko.lproj/Localizable.strings \
    Contents/Resources/token-glance_TokenGlanceText.bundle/claude-spark.svg \
    Contents/Resources/token-glance_TokenGlanceText.bundle/openai-blossom.svg \
    Contents/Resources/AppIcon.icns; do
    [ -s "$app/$file" ] || fail "missing $file"
done

icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" 2>/dev/null || true)"
[ "$icon_file" = "AppIcon" ] || fail "CFBundleIconFile is '$icon_file', expected AppIcon"
cmp -s "$app/Contents/Resources/AppIcon.icns" assets/AppIcon/AppIcon.icns \
    || fail "AppIcon.icns in the app differs from assets/AppIcon/AppIcon.icns"

archs="$(lipo -archs "$app/Contents/MacOS/TokenGlance")"
hook_archs="$(lipo -archs "$app/Contents/Resources/token-glance-hook")"
[ "$archs" = "$hook_archs" ] || fail "app ($archs) and hook ($hook_archs) architectures differ"

codesign --verify --strict --deep "$app" || fail "signature does not verify"

out="dist/release"
zip="TokenGlance-$version-macos-$(echo "$archs" | tr ' ' '-').zip"
mkdir -p "$out"
rm -f "$out/$zip" "$out/$zip.sha256"
# ditto keeps the bundle structure, permissions and signature (plain `zip` can break them).
ditto -c -k --keepParent "$app" "$out/$zip"
(cd "$out" && shasum -a 256 "$zip" > "$zip.sha256")

echo "version   $version (build $build)"
echo "archs     $archs"
echo "zip       $out/$zip"
echo "sha256    $(cut -d ' ' -f 1 "$out/$zip.sha256")"

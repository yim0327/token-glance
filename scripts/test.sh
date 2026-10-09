#!/bin/sh
# Runs `swift test`, adding the Testing.framework paths that a Command Line
# Tools-only toolchain (no Xcode) leaves out. Without them SwiftPM silently
# runs zero swift-testing tests and exits 0. With Xcode (and on CI) this is
# plain `swift test`.
set -eu

dev_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
clt=/Library/Developer/CommandLineTools
fw="$clt/Library/Developer/Frameworks"
lib="$clt/Library/Developer/usr/lib"

if [ "$dev_dir" = "$clt" ] && [ -d "$fw/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F"$fw" \
        -Xlinker -F"$fw" \
        -Xlinker -rpath -Xlinker "$fw" \
        -Xlinker -rpath -Xlinker "$lib" \
        "$@"
fi
exec swift test "$@"

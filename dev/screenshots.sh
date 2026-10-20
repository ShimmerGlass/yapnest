#!/bin/sh
# Takes the App Store screenshots from the `screenshots` dev fixture:
# dev/screenshots.sh [udid] [outdir]. Builds Debug first, as the fixtures are
# debug-only. The status bar shows the current time (override with CLOCK=9:41),
# as the fixture's message times are relative to now. The simulator should be a 6.9-inch iPhone (1320x2868).
set -eu
cd "$(dirname "$0")/.."
udid=${1:-8A2A994C-669B-43DD-9C92-1B3767BBD27C}
out=${2:-design/screenshots}
derived=${DERIVED_DATA:-${TMPDIR:-/tmp}/yapnest-screenshots}
bundle=fr.yapnest.app
if ! command -v magick >/dev/null 2>&1; then
    echo "error: ImageMagick is needed (brew install imagemagick)" >&2
    exit 1
fi
mkdir -p "$out" "$out/6.3"

xcodebuild -scheme Yapnest -configuration Debug -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$derived" build -quiet CODE_SIGNING_ALLOWED=NO
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$derived/Build/Products/Debug-iphonesimulator/Yapnest.app"
xcrun simctl ui "$udid" appearance light
xcrun simctl status_bar "$udid" override --time "${CLOCK:-$(date +%H:%M)}" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi

cleanup() {
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl ui "$udid" appearance light 2>/dev/null || true
    xcrun simctl status_bar "$udid" clear 2>/dev/null || true
    xcrun simctl shutdown "$udid" 2>/dev/null || true
}
trap cleanup EXIT

# shot <file> [chat]: launches on a fresh fixture, opening <chat> if given.
shot() {
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    if [ -n "${2:-}" ]; then
        SIMCTL_CHILD_YAPNEST_DEV_FIXTURE=screenshots SIMCTL_CHILD_YAPNEST_DEV_OPEN="$2" xcrun simctl launch "$udid" "$bundle" >/dev/null
    else
        SIMCTL_CHILD_YAPNEST_DEV_FIXTURE=screenshots xcrun simctl launch "$udid" "$bundle" >/dev/null
    fi
    sleep "${SETTLE:-8}"
    xcrun simctl io "$udid" screenshot "$out/$1" 2>/dev/null
}

shot 01-chats.png
shot 02-conversation.png lea@fixture.test
shot 03-group.png climbing@groups.fixture.test
xcrun simctl ui "$udid" appearance dark
shot 04-conversation-dark.png lea@fixture.test

for file in "$out"/0*.png; do
    size=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')
    [ "$size" = "1320 2868 " ] || echo "warning: $file is $size, not 1320 2868" >&2
done
# Apple refuses screenshots with an alpha channel, and `PNG24:` is what makes
# magick write none. The medium display slot (6.3-inch) is the one Apple
# requires and only takes its own sizes; the 1320x2868 originals go in the large
# slot. The aspect differs by under 0.1%, so the copies are resized, not cropped.
for file in "$out"/0*.png; do
    name=$(basename "$file")
    magick "$file" -alpha off "PNG24:$file"
    magick "$file" -resize '1206x2622!' "PNG24:$out/6.3/$name"
done
echo "Screenshots are in $out"

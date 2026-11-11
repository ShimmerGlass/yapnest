#!/bin/sh
# Takes the App Store screenshots from the `screenshots` dev fixture:
# dev/screenshots.sh [--ipad] [udid] [outdir]. Builds Debug first, as the
# fixtures are debug-only. The status bar shows the current time (override with
# CLOCK=9:41), as the fixture's message times are relative to now. The simulator
# should be a 6.9-inch iPhone (1320x2868), or with --ipad a 13-inch iPad
# (2064x2752), the iPad size Apple requires, whose shots go in ipad-13/.
set -eu
cd "$(dirname "$0")/.."
ipad=0
if [ "${1:-}" = --ipad ]; then
    ipad=1
    shift
fi
if [ "$ipad" = 1 ]; then
    udid=${1:-E9D43D6A-D1B3-4832-8D91-8429049588A3}
    out=${2:-design/screenshots/ipad-13}
    expected="2064 2752 "
else
    udid=${1:-8A2A994C-669B-43DD-9C92-1B3767BBD27C}
    out=${2:-design/screenshots}
    expected="1320 2868 "
fi
derived=${DERIVED_DATA:-${TMPDIR:-/tmp}/yapnest-screenshots}
bundle=fr.yapnest.app
if ! command -v magick >/dev/null 2>&1; then
    echo "error: ImageMagick is needed (brew install imagemagick)" >&2
    exit 1
fi
mkdir -p "$out"
[ "$ipad" = 1 ] || mkdir -p "$out/6.3"

# Signed with the team in Config/Local.xcconfig: unsigned, the app has no
# keychain, the fixture can't sign in, and every shot is of the login screen.
xcodebuild -scheme Yapnest -configuration Debug -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$derived" build -quiet
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

# A freshly booted simulator shows its own banners for a while, over the first
# shot otherwise.
shot warm-up.png
rm -f "$out/warm-up.png"

if [ "$ipad" = 1 ]; then
    # The list is beside the chat on the iPad, so every shot has a chat open:
    # with none, the empty side says "No Chat Selected".
    shot 01-conversation.png lea@fixture.test
    shot 02-group.png climbing@groups.fixture.test
    shot 03-book-club.png bookclub@groups.fixture.test
    xcrun simctl ui "$udid" appearance dark
    shot 04-conversation-dark.png lea@fixture.test
else
    shot 01-chats.png
    shot 02-conversation.png lea@fixture.test
    shot 03-group.png climbing@groups.fixture.test
    xcrun simctl ui "$udid" appearance dark
    shot 04-conversation-dark.png lea@fixture.test
fi

for file in "$out"/0*.png; do
    size=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')
    [ "$size" = "$expected" ] || echo "warning: $file is $size, not $expected" >&2
done
# Apple refuses screenshots with an alpha channel, and `PNG24:` is what makes
# magick write none. The medium display slot (6.3-inch) is the one Apple
# requires and only takes its own sizes; the 1320x2868 originals go in the large
# slot. The aspect differs by under 0.1%, so the copies are resized, not cropped.
for file in "$out"/0*.png; do
    name=$(basename "$file")
    magick "$file" -alpha off "PNG24:$file"
    [ "$ipad" = 1 ] || magick "$file" -resize '1206x2622!' "PNG24:$out/6.3/$name"
done
echo "Screenshots are in $out"

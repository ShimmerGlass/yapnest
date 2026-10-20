#!/bin/sh
# Opens a fuzz seed's chat in the booted simulator, to look at what a fuzz
# test failed on: dev/fuzz.sh <seed> [group]. Builds Debug first, as the
# fixtures are debug-only.
set -eu
seed=${1:?usage: dev/fuzz.sh <seed> [group]}
case ${2:-} in
    group) chat=fuzz-group@conference.fixture.test ;;
    *) chat=fuzz@fixture.test ;;
esac
cd "$(dirname "$0")/.."
derived=${DERIVED_DATA:-${TMPDIR:-/tmp}/yapnest-fuzz}
simulator=$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F-]{27}') || {
    echo "No simulator is booted." >&2
    exit 1
}
xcodebuild -scheme Yapnest -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath "$derived" build -quiet
xcrun simctl install "$simulator" "$derived/Build/Products/Debug-iphonesimulator/Yapnest.app"
xcrun simctl terminate "$simulator" fr.yapnest.app 2>/dev/null || true
SIMCTL_CHILD_YAPNEST_DEV_FIXTURE="fuzz:$seed" SIMCTL_CHILD_YAPNEST_DEV_OPEN="$chat" \
    xcrun simctl launch "$simulator" fr.yapnest.app

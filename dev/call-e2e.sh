#!/bin/bash
# Rings bob from alice between two simulators, with the dev server's accounts,
# and checks from each one's log that the call became active and ended, and
# for video that a picture arrived: dev/call-e2e.sh [--audio]
# Builds Debug signed (an unsigned build has no keychain entitlement, and the
# dev sign-in fails), so it needs Config/Local.xcconfig. The dev ejabberd or
# Prosody must be running with alice and bob.
#
# SIM_A (default: iPhone 17) calls, SIM_B (default: Yapnest iOS 26) answers;
# both are names or ids of simulators that already exist. OUTPUT_DIR holds the
# screenshots and the logs, HANGUP_SECONDS is how long the call lasts.
set -euo pipefail

video=1
case ${1:-} in
    --audio) video=0 ;;
    "") ;;
    *) echo "usage: dev/call-e2e.sh [--audio]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
bundle=fr.yapnest.app
sim_a=${SIM_A:-iPhone 17}
sim_b=${SIM_B:-Yapnest iOS 26}
hangup=${HANGUP_SECONDS:-12}
output=${OUTPUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/yapnest-call-e2e.XXXXXX")}
derived=${DERIVED_DATA:-$output/derived}
mkdir -p "$output"
kind=video
[ "$video" = 1 ] || kind=audio

booted=()
cleanup() {
    for id in "$sim_a" "$sim_b"; do
        xcrun simctl terminate "$id" "$bundle" >/dev/null 2>&1 || true
    done
    # Only what this run booted: a simulator someone was using stays up.
    for id in ${booted[@]+"${booted[@]}"}; do
        xcrun simctl shutdown "$id" >/dev/null 2>&1 || true
    done
    echo "Screenshots and logs: $output"
}
trap cleanup EXIT

fail() {
    echo "FAIL ($kind call): $*" >&2
    exit 1
}

# A name is looked up among the available simulators; an id is used as it is.
resolve() {
    case $1 in
        *-*-*-*-*) echo "$1" ;;
        *) xcrun simctl list devices available | grep -F "    $1 (" | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' ;;
    esac
}
sim_a=$(resolve "$sim_a") && [ -n "$sim_a" ] || fail "no simulator named ${SIM_A:-iPhone 17}"
sim_b=$(resolve "$sim_b") && [ -n "$sim_b" ] || fail "no simulator named ${SIM_B:-Yapnest iOS 26}"
[ "$sim_a" != "$sim_b" ] || fail "SIM_A and SIM_B are the same simulator"

boot() {
    if ! xcrun simctl list devices booted | grep -q "$1"; then
        xcrun simctl boot "$1" || fail "could not boot $1"
        booted+=("$1")
    fi
    xcrun simctl bootstatus "$1" -b >/dev/null || fail "$1 did not finish booting"
}
boot "$sim_a"
boot "$sim_b"

echo "Building Debug into $derived"
xcodebuild -scheme Yapnest -configuration Debug -destination "platform=iOS Simulator,id=$sim_a" \
    -derivedDataPath "$derived" build -quiet >"$output/build.log" 2>&1 || {
    tail -20 "$output/build.log" >&2
    fail "the build failed (see $output/build.log)"
}
app="$derived/Build/Products/Debug-iphonesimulator/Yapnest.app"

for id in "$sim_a" "$sim_b"; do
    xcrun simctl terminate "$id" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl install "$id" "$app"
    xcrun simctl privacy "$id" grant camera "$bundle"
    xcrun simctl privacy "$id" grant microphone "$bundle"
done

# The simulator's clock is the Mac's, in local time, as `log show` reads it.
started=$(date '+%Y-%m-%d %H:%M:%S')

calls_log() {
    xcrun simctl spawn "$1" log show --info --start "$started" \
        --predicate 'subsystem == "Yapnest" AND category == "Calls"' 2>/dev/null
}

# Waits up to $3 seconds for a log line of simulator $1 matching the pattern $2.
wait_for() {
    local deadline=$((SECONDS + $3))
    while [ $SECONDS -lt $deadline ]; do
        calls_log "$1" | grep -Eq "$2" && return 0
        sleep 1
    done
    return 1
}

common=(SIMCTL_CHILD_YAPNEST_DEV_PASSWORD=password SIMCTL_CHILD_YAPNEST_DEV_HOST=127.0.0.1 SIMCTL_CHILD_YAPNEST_DEV_NO_AUDIO=1)

echo "Launching bob on $sim_b"
env "${common[@]}" SIMCTL_CHILD_YAPNEST_DEV_ACCOUNT=bob@localhost SIMCTL_CHILD_YAPNEST_DEV_ANSWER=1 \
    xcrun simctl launch --terminate-running-process "$sim_b" "$bundle" >/dev/null
sleep 3

echo "Launching alice on $sim_a, calling bob with $kind"
caller_env=(SIMCTL_CHILD_YAPNEST_DEV_ACCOUNT=alice@localhost SIMCTL_CHILD_YAPNEST_DEV_CALL=bob@localhost
    SIMCTL_CHILD_YAPNEST_DEV_HANGUP_AFTER="$hangup")
[ "$video" = 1 ] && caller_env+=(SIMCTL_CHILD_YAPNEST_DEV_CALL_VIDEO=1)
env "${common[@]}" "${caller_env[@]}" \
    xcrun simctl launch --terminate-running-process "$sim_a" "$bundle" >/dev/null

# Past signing in, the presence that says bob takes calls, and ringing out.
wait_for "$sim_a" 'outgoing: active' 90 || fail "alice's call never became active (is the dev server running?)"
wait_for "$sim_b" 'incoming: active' 30 || fail "bob's call never became active"
echo "Both sides are active"

# Time for pictures to arrive, then a look at both screens mid-call.
sleep 4
xcrun simctl io "$sim_a" screenshot "$output/alice-$kind.png" >/dev/null 2>&1
xcrun simctl io "$sim_b" screenshot "$output/bob-$kind.png" >/dev/null 2>&1

wait_for "$sim_a" 'outgoing: ended' $((hangup + 30)) || fail "alice's call never ended"
wait_for "$sim_b" 'incoming: ended' 30 || fail "bob's call never ended"

calls_log "$sim_a" >"$output/alice-calls.log"
calls_log "$sim_b" >"$output/bob-calls.log"

if [ "$video" = 1 ]; then
    for side in alice bob; do
        grep -q 'first remote video frame' "$output/$side-calls.log" || fail "$side logged no remote video frame (see $output/$side-calls.log)"
    done
fi
echo "PASS ($kind call): both sides were active and ended$([ "$video" = 1 ] && echo ', and saw the peer'"'"'s video')"

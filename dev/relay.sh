#!/bin/sh
# Runs yapnest-relay (a checkout next to this repository, or $RELAY_DIR) against
# the local Prosody, which serves push.localhost for it. Without a real APNs
# key, it makes a throwaway one: registering and enabling work, Apple refuses
# the pushes. With the real key, pushes reach the simulator:
#   APNS_KEY_FILE=AuthKey_….p8 APNS_KEY_ID=… APNS_TEAM_ID=… dev/relay.sh
set -eu
cd "$(dirname "$0")"
relay=${RELAY_DIR:-../../yapnest-relay}
state=${TMPDIR:-/tmp}/yapnest-relay
mkdir -p "$state"
[ -f "$state/key" ] || head -c32 /dev/urandom | base64 >"$state/key"
if [ -z "${APNS_KEY_FILE:-}" ]; then
    [ -f "$state/fake.p8" ] || openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt >"$state/fake.p8"
    APNS_KEY_FILE=$state/fake.p8 APNS_KEY_ID=FAKE APNS_TEAM_ID=FAKE
fi
export APNS_KEY_FILE APNS_KEY_ID APNS_TEAM_ID
export RELAY_DOMAIN=push.localhost RELAY_SERVER=127.0.0.1:5347 RELAY_COMPONENT_SECRET=relay RELAY_KEY="$(cat "$state/key")"
cd "$relay" && exec go run .

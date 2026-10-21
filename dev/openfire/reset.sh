#!/bin/sh
# Wipes the Openfire dev server and the integration tests' device databases,
# then sets it up again (`OPENFIRE_BARE=1` for the variant without the push
# and upload plugins). See ../prosody/reset.sh.
set -e
cd "$(dirname "$0")"
if [ -n "$OPENFIRE_BARE" ]; then export COMPOSE_PROJECT_NAME=openfire-bare; fi
docker compose down -v
rm -rf "${TMPDIR:-/tmp}/yapnest-integration" "${TMPDIR:-/tmp}/yapnest-integration-kept"
./setup.sh

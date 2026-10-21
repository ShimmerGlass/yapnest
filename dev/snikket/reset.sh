#!/bin/sh
# Wipes the Snikket dev server and the integration tests' device databases,
# then sets it up again. See ../prosody/reset.sh.
set -e
cd "$(dirname "$0")"
docker compose down -v
rm -rf "${TMPDIR:-/tmp}/yapnest-integration" "${TMPDIR:-/tmp}/yapnest-integration-kept"
./setup.sh

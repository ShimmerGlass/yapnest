#!/bin/sh
# Wipes the dev server (accounts, archives, published OMEMO devices) and the
# integration tests' device databases, then sets the server up again. Test
# runs with fresh devices keep adding OMEMO devices and archived messages,
# which slow every new session down; reset when they pile up.
set -e
cd "$(dirname "$0")"
docker compose down -v
rm -rf "${TMPDIR:-/tmp}/yapnest-integration" "${TMPDIR:-/tmp}/yapnest-integration-kept"
./setup.sh

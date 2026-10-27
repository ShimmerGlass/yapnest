#!/bin/sh
# Starts the ejabberd dev server, on 15222 and 15280 so it can run beside the
# Prosody one, and creates alice, bob, carol, pwchange and admin @localhost
# (password: "password").
set -e
cd "$(dirname "$0")"
# Every start is a fresh server: accounts, archives and published OMEMO
# devices left by earlier runs (or a run stopped halfway, such as one that
# changed a password) would otherwise carry over. The tests' device
# databases for this server go too, as they remember that server's archive.
docker compose down -v
rm -rf "${TMPDIR:-/tmp}/yapnest-integration/ejabberd-15222" "${TMPDIR:-/tmp}/yapnest-integration-kept/ejabberd-15222"
../certs/make.sh
# TURN has to be advertised on an address WebRTC on this Mac can send to, and
# macOS drops packets from the network interface to 127.0.0.1. The Mac's own
# address also reaches the Android emulator and phones on the network. Compose
# reads it from .env, so a later `docker compose up` keeps it.
if [ -z "$TURN_HOST" ]; then
    iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')
    TURN_HOST=$(ipconfig getifaddr "${iface:-en0}" 2>/dev/null || echo 127.0.0.1)
fi
echo "TURN_HOST=$TURN_HOST" > .env
docker compose up -d
# The image's health check, rather than polling with `docker compose exec`,
# which can hang while the server starts.
tries=0
until [ "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q ejabberd)")" = healthy ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 120 ]; then docker compose logs --tail 20 ejabberd; exit 1; fi
    sleep 1
done
for user in alice bob carol pwchange admin; do
    docker compose exec -T ejabberd ejabberdctl register "$user" localhost password || true
done

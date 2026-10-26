#!/bin/sh
# Starts the Snikket dev server on port 25222 (HTTP uploads on 25280, so it
# runs beside the Prosody and ejabberd ones) and creates alice, bob, carol and pwchange
# @localhost (password: "password"). Group chats are on groups.localhost, and
# uploads on localhost:25280 (dev.cfg.lua).
set -e
cd "$(dirname "$0")"
# Every start is a fresh server: accounts, archives and published OMEMO
# devices left by earlier runs (or a run stopped halfway, such as one that
# changed a password) would otherwise carry over. The tests' device
# databases for this server go too, as they remember that server's archive.
docker compose down -v
rm -rf "${TMPDIR:-/tmp}/yapnest-integration/snikket-25222" "${TMPDIR:-/tmp}/yapnest-integration-kept/snikket-25222"
# Snikket refuses to start without a certificate for its domain. A cert manager
# fetches one from Let's Encrypt in production; here it's the dev CA's.
../certs/make.sh
docker compose up -d
tries=0
until curl -s -o /dev/null http://127.0.0.1:25280/; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then docker compose logs --tail 20 snikket; exit 1; fi
    sleep 2
done
for user in alice bob carol pwchange; do
    docker compose exec -T -u prosody snikket prosodyctl register "$user" localhost password
done

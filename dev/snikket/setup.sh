#!/bin/sh
# Starts the Snikket dev server on port 25222 (HTTP uploads on 25280, so it
# runs beside the Prosody and ejabberd ones) and creates alice, bob, carol and pwchange
# @localhost (password: "password"). Group chats are on groups.localhost, and
# uploads on localhost:25280 (dev.cfg.lua).
set -e
cd "$(dirname "$0")"
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

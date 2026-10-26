#!/bin/sh
# Starts the dev server and creates the test accounts alice, bob, carol and pwchange @localhost (password: "password").
set -e
cd "$(dirname "$0")"
# Every start is a fresh server: accounts, archives and published OMEMO
# devices left by earlier runs (or a run stopped halfway, such as one that
# changed a password) would otherwise carry over. The tests' device
# databases for this server go too, as they remember that server's archive.
docker compose down -v
rm -rf "${TMPDIR:-/tmp}/yapnest-integration/prosody-5222" "${TMPDIR:-/tmp}/yapnest-integration-kept/prosody-5222"
../certs/make.sh
docker compose up -d
sleep 2
# Community modules the config enables: SASL2 (XEP-0388), Bind 2 (XEP-0386),
# FAST (XEP-0484), spam reports (XEP-0377) and moderated retraction
# (XEP-0425). They go in the data volume.
for module in mod_sasl2 mod_sasl2_bind2 mod_sasl2_sm mod_sasl2_fast mod_spam_reporting mod_muc_moderation; do
    docker compose exec -T prosody prosodyctl install --server=https://modules.prosody.im/rocks/ "$module" >/dev/null
done
docker compose restart prosody
sleep 2
for user in alice bob carol pwchange; do
    docker compose exec -T prosody prosodyctl register "$user" localhost password
done

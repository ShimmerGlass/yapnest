#!/bin/sh
# Runs the XMPP Compliance Tester (https://codeberg.org/iNPUTmice/caas, the tool
# behind compliance.conversations.im) against a running dev server and writes
# the report to <server>.txt. Needs git, a JDK (11+) and Maven.
#
#   dev/compliance/run.sh prosody|ejabberd|snikket|openfire|openfire-bare
#
# The tester finds a server through its domain's SRV records and wants TLS.
# caas-local.patch lets CAAS_HOST and CAAS_PORT name the connection instead,
# without TLS, so the dev servers on localhost can be tested. It signs in as
# alice, so don't leave the app signed in to the same server.
set -e
server=${1:?usage: run.sh prosody|ejabberd|snikket|openfire|openfire-bare}
case "$server" in
    prosody) port=5222 ;;
    ejabberd) port=15222 ;;
    snikket) port=25222 ;;
    openfire|openfire-bare) port=35222 ;;
    *) echo "unknown server $server" >&2; exit 1 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
work=${CAAS_DIR:-${TMPDIR:-/tmp}/yapnest-caas}
if [ ! -f "$work/src/caas-app/target/caas-app.jar" ]; then
    mkdir -p "$work"
    git clone --depth 1 https://codeberg.org/iNPUTmice/caas.git "$work/src"
    git -C "$work/src" apply "$here/caas-local.patch"
    (cd "$work/src" && mvn -q package -pl caas-annotations,caas-app -DskipTests)
fi
# The tester keeps the account's password in accounts.xml in its working directory.
mkdir -p "$work/run"
cd "$work/run"
CAAS_HOST=127.0.0.1 CAAS_PORT=${YAPNEST_SERVER_PORT:-$port} \
    java -jar "$work/src/caas-app/target/caas-app.jar" alice@localhost password \
    | sed 's/\x1b\[[0-9;]*m//g' | tee "$here/$server.txt"

#!/bin/sh
# Starts the Openfire dev server on port 35222 (HTTP uploads on 35280, the
# admin console on 35090 with admin/admin, so it runs beside the other dev
# servers) and sets it up on its own: openfire.xml makes the first start run
# the setup with an embedded database, and creates alice, bob, carol and pwchange
# @localhost (password: "password").
#
# Plugins, downloaded from igniterealtime.org: Monitoring (message archive,
# XEP-0313), Push Notification (XEP-0357) and HTTP File Upload (XEP-0363).
# `OPENFIRE_BARE=1 ./setup.sh` leaves out the last two, as a server that
# lacks them. It keeps its own data, so switching between the two takes a
# `reset.sh` of the one that's running (both use the same ports).
set -e
cd "$(dirname "$0")"
plugins=https://www.igniterealtime.org/projects/openfire/plugins
if [ -n "$OPENFIRE_BARE" ]; then
    export COMPOSE_PROJECT_NAME=openfire-bare
    export OPENFIRE_PLUGINS=./plugins-bare
else
    export OPENFIRE_PLUGINS=./plugins
fi
mkdir -p "$OPENFIRE_PLUGINS"
fetch() {
    [ -f "$OPENFIRE_PLUGINS/$2.jar" ] || curl -fsSL "$plugins/$1/$2.jar" -o "$OPENFIRE_PLUGINS/$2.jar"
}
fetch 2.8.0 monitoring
if [ -z "$OPENFIRE_BARE" ]; then
    fetch 1.1.1 pushnotification
    fetch 1.5.0 httpfileupload
fi
../certs/make.sh
docker compose up -d --build
# The log says when the plugins are in; Docker publishes the ports before that.
# $1 is when to start reading it, so a restart isn't mistaken for the first start.
wait_for_plugins() {
    tries=0
    until docker compose logs ${1:+--since "$1"} openfire 2>/dev/null | grep -q "Finished processing all plugins"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 180 ]; then docker compose logs --tail 30 openfire; exit 1; fi
        sleep 2
    done
}
wait_for_plugins
# Openfire offers STARTTLS with a self-signed certificate of its own. Swap in
# the dev CA's, which the tests trust, and restart so it takes effect.
keystore=/var/lib/openfire/conf/security/keystore
if ! docker compose exec -T openfire keytool -list -v -keystore "$keystore" -storepass changeit 2>/dev/null | grep -q "Issuer: CN=Yapnest dev CA"; then
    p12=$(mktemp)
    openssl pkcs12 -export -in ../certs/fullchain.pem -inkey ../certs/server.key -name localhost_rsa -passout pass:changeit -out "$p12"
    docker compose cp "$p12" openfire:/tmp/server.p12
    rm -f "$p12"
    docker compose exec -T openfire sh -c "keytool -delete -alias localhost_rsa -keystore $keystore -storepass changeit >/dev/null 2>&1; \\
        keytool -importkeystore -srckeystore /tmp/server.p12 -srcstoretype pkcs12 -srcstorepass changeit -destkeystore $keystore -deststorepass changeit -noprompt >/dev/null 2>&1; \\
        chown openfire:openfire $keystore; rm /tmp/server.p12"
    restarted=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose restart openfire
    wait_for_plugins "$restarted"
fi
# System properties live in the database, so the setup can only set them through
# the admin console. A session whose connection dropped stays online for ten
# minutes by default, which keeps its contacts seeing it; Prosody's dev config
# gives it one.
admin=http://127.0.0.1:35090
jar=$(mktemp)
token() { grep -o 'name="csrf" value="[^"]*"' | sed 's/.*value="//; s/"//'; }
curl -s -c "$jar" -b "$jar" "$admin/login.jsp" -o "$jar.page"
curl -s -c "$jar" -b "$jar" -o /dev/null -d "url=&login=true&username=admin&password=admin" --data-urlencode "csrf=$(token < "$jar.page")" "$admin/login.jsp"
curl -s -c "$jar" -b "$jar" "$admin/server-properties.jsp" -o "$jar.page"
curl -s -c "$jar" -b "$jar" -o /dev/null -d "action=save&key=xmpp.session.detach.timeout&value=60000&encrypt=false" --data-urlencode "csrf=$(token < "$jar.page")" "$admin/server-properties.jsp"
rm -f "$jar" "$jar.page"

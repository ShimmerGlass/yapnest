#!/bin/sh
# Makes the dev servers' TLS certificate: a local CA, and one server
# certificate signed by it, for localhost and every component domain the dev
# servers use. The servers offer it on STARTTLS (TLS stays optional, so the
# plaintext test suites still work), and the SASL2/Bind 2/FAST tests trust
# ca.pem, so they run over real TLS with the hostname and expiry checked.
# Nothing here leaves the dev machine; the files are git-ignored.
#
# Writes ca.pem, server.pem (the certificate), server.key and fullchain.pem
# (certificate then CA, which Snikket and Prosody read) next to this script.
# Does nothing while they are valid; regenerates them in the last month.
set -e
cd "$(dirname "$0")"
if [ -f ca.pem ] && [ -f server.pem ] && [ -f server.key ] && [ -f fullchain.pem ] \
    && openssl x509 -checkend 2592000 -noout -in server.pem >/dev/null \
    && openssl x509 -checkend 2592000 -noout -in ca.pem >/dev/null; then
    exit 0
fi
domains="localhost conference.localhost groups.localhost share.localhost upload.localhost push.localhost pubsub.localhost proxy.localhost search.localhost"
san=""
for d in $domains; do san="$san,DNS:$d"; done
san="${san#,}"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Yapnest dev CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
# macOS refuses a server certificate valid for more than 825 days.
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 800 \
    -extfile /dev/stdin -out server.pem 2>/dev/null <<EXT
subjectAltName=$san
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
cat server.pem ca.pem > fullchain.pem
rm -f server.csr ca.srl
# The servers run as other users inside their containers.
chmod 644 ca.pem server.pem server.key fullchain.pem ca.key
echo "Dev certificates written to $(pwd)"

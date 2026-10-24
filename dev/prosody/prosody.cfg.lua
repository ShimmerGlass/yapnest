-- Local development server. Not for production: no TLS requirement, open accounts.
-- STARTTLS is offered all the same, with the dev CA's certificate (dev/certs/make.sh),
-- for the tests that run over TLS. The plaintext ones need TLS to stay optional.
admins = {}
plugin_paths = {}

modules_enabled = {
    "roster"; "saslauth"; "tls"; "disco"; "carbons"; "pep"; "private";
    "blocklist"; "vcard4"; "vcard_legacy"; "version"; "uptime"; "time"; "ping";
    "register"; "mam"; "smacks"; "csi_simple"; "admin_shell"; "bookmarks";
    "cloud_notify";
    -- Community modules, installed by setup.sh: faster sign-in (SASL2,
    -- Bind 2, FAST) and spam reports.
    "sasl2"; "sasl2_bind2"; "sasl2_sm"; "sasl2_fast"; "spam_reporting";
    -- Last seen (XEP-0012) of offline users, for contacts who ask.
    "lastactivity";
    -- The admins' ad-hoc commands (XEP-0133), which servers offer: the tests
    -- check an ordinary user is refused them. Nobody here is an admin.
    "admin_adhoc";
}

ssl = {
    key = "/etc/prosody/certs/server.key";
    certificate = "/etc/prosody/certs/fullchain.pem";
}

allow_registration = false
c2s_require_encryption = false
allow_unencrypted_plain_auth = true
authentication = "internal_hashed"
storage = "internal"
archive_expires_after = "1w"
default_archive_policy = true
smacks_hibernation_time = 60

log = { debug = "*console" }

-- HTTP for XEP-0363 uploads, reachable from the host and the simulator.
http_ports = { 5280 }
http_interfaces = { "*" }
https_ports = {}
http_external_url = "http://localhost:5280/"

-- For the push relay (yapnest-relay), which connects as a component (XEP-0114).
component_ports = { 5347 }
component_interfaces = { "0.0.0.0" }

VirtualHost "localhost"

Component "upload.localhost" "http_file_share"
    http_file_share_size_limit = 50 * 1024 * 1024
    -- Serve on the external URL's host rather than upload.localhost.
    http_host = "localhost"

-- Group chats, with their own archive (XEP-0313) for catching up, and
-- moderated retraction (XEP-0425), a community module installed by setup.sh.
Component "conference.localhost" "muc"
    modules_enabled = { "muc_mam"; "muc_moderation" }
    muc_room_default_persistent = true
    muc_log_by_default = true
    muc_log_expires_after = "1w"

-- The push relay (yapnest-relay), connected as a component.
Component "push.localhost"
    component_secret = "relay"

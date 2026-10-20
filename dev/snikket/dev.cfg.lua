-- Local development tweaks on top of Snikket's own configuration, included
-- last through SNIKKET_TWEAK_EXTRA_CONFIG. Not for production.

-- Snikket requires TLS and a real certificate; Yapnest's tests connect without TLS.
c2s_require_encryption = false
allow_unencrypted_plain_auth = true
disable_sasl_mechanisms = {}

-- The test accounts' password is "password".
password_policy = { length = 1 }

-- Serve uploads on the host's own address, like the other dev servers do,
-- instead of behind Snikket's web proxy at https://localhost.
http_external_url = "http://localhost:25280/"

-- mod_limits throttles each client to 10 kB/s by default, which holds back
-- encrypted messages (about 850 ms each) and fails the latency test.
limits = { c2s = { rate = "10mb/s"; burst = "2s" } }

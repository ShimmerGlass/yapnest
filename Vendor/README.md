# Vendored libraries: Martin and MartinOMEMO

Yapnest talks XMPP through [Martin](https://github.com/tigase/Martin), and
does OMEMO encryption through [MartinOMEMO](https://github.com/tigase/MartinOMEMO),
both by Tigase. This folder holds our own copies of the two, with fixes
upstream doesn't have. YapnestKit builds from these copies, not from GitHub.

| Library | Upstream | Our copy is based on |
|---|---|---|
| Martin | https://github.com/tigase/Martin | `6daa5f871bbbb4022d7c99f3108ae7345e8b46c1` (master, 2026-09-14) |
| MartinOMEMO | https://github.com/tigase/MartinOMEMO | `3c162154d646aa258c9a86c0a07655a536e55a94` (2.2.3, 2023-03-09) |

Both are GPL/AGPL licensed (see their `COPYING` / `LICENSE`), the same terms
we were already using them under.

## Why we forked

The bugs below aren't edge cases for an app like Yapnest. They sat under the
features we treat as essential:

- **Encryption silently failing for new devices.** Someone sets up a new
  phone, a contact writes to them, and the first message arrives as "this
  message is encrypted and couldn't be decrypted". Several separate races
  in MartinOMEMO led there, and our integration tests caught them failing
  about one fresh run in three or four.
- **No encryption at all on ejabberd.** Martin misread every error ejabberd
  sends, so MartinOMEMO never published our keys. One of the two big
  server families was unusable for encrypted chat.
- **Group chats needed things upstream doesn't offer**, like retracting a
  bookmark so our other devices hear about it.

Working around them from the outside didn't hold up. We tried: a stanza
filter to reorder ejabberd's errors, calling MartinOMEMO one account at a
time, building our own devices' sessions by hand, feeding device lists back
into MartinOMEMO's notification handler. Each patched one symptom. Some made
others worse, because the faults are inside MartinOMEMO's state, which only
the library itself can see. Fixing them where they live took less code than
the workarounds, and YapnestKit's encryption code got simpler once they were
gone.

MartinOMEMO has had no upstream commit since March 2023, so waiting for a
fix wasn't an option. Martin is still maintained, which is why its changes
are kept small and easy to offer upstream.

Copying the sources into the repo, rather than forking on GitHub, keeps
every build reproducible from a single clone. Each fix also shows up as an
ordinary diff in Yapnest's history.

## What we changed

Each entry gives what went wrong for users, why, and what changed.

### Martin

**Errors from ejabberd read as "undefined condition"**
(`XMPPError.parse`, `Stanza.errorCondition`)
- *Symptom:* on ejabberd, encryption never started. Group join refusals
  lost their reason ("only members can join" became "couldn't join").
- *Cause:* Martin took the first child of `<error>` in the stanza-errors
  namespace as the condition. The human-readable `<text>` lives in the same
  namespace, and ejabberd puts it first, which XMPP allows. Prosody puts it
  last, so the bug never showed there.
- *Fix:* skip `<text>` when looking for the condition.

**A `recipient-unavailable` error read as "undefined condition"**
(`ErrorCondition.recipient_unavailable`)
- *Symptom:* a message bounced because the recipient had no session showed
  the generic failure, and the error's type and text were lost.
- *Cause:* the condition's name was misspelt `recipiend-unavailable`, so
  `XMPPError.parse` never matched it.
- *Fix:* spell it as RFC 6120 does.

**Error types disagreed with RFC 6120, and a pubsub error lost its type**
(`ErrorCondition.type`, `PubSubError.errorType`)
- *Symptom:* a server's internal error or a policy violation was written
  with the wrong `type`, and a failed pubsub request couldn't tell an error
  that passes (`wait`) from a final one, as `XMPPError` keeps no type.
- *Cause:* `internal-server-error`, `gone` and `policy-violation` had other
  types than §8.3.3 recommends, and `PubSubError.parseError` dropped the
  attribute.
- *Fix:* the table follows the RFC, and `PubSubError` keeps the `type` it
  was parsed with. `XMPPError` is an enum without room for it, so it still
  falls back on its condition's type.

**Archive queries ignored the `with` filter**
(`MessageArchiveManagementModule.queryItems(with:)`)
- *Symptom:* asking for one contact's archive returned the whole account's.
- *Cause:* the parameter was accepted, then set to nil instead of the
  query form.
- *Fix:* set the form's `with` to it.

**Retracting a pubsub item couldn't notify subscribers**
(`PubSubModule.retractItem`)
- *Symptom:* leaving a group on one device didn't make our other devices
  leave it.
- *Cause:* XEP-0402 bookmarks tell other devices about a removal through a
  retraction notification. The server only sends one when the retraction
  asks with `notify="true"`, and Martin had no way to ask.
- *Fix:* an optional `notify` parameter, off by default.

**Reading a node's configuration was refused by ejabberd**
(`PubSubModule.retrieveNodeConfiguration`)
- *Symptom:* ejabberd answered "bad request" to anything that read a
  node's configuration. Changing our display name failed this way when the
  node already existed with another access model.
- *Cause:* the request carried a stray `<default/>` next to `<configure>`,
  left over from the request for a service's default configuration. XEP-0060
  allows only one of them, and ejabberd checks, where Prosody ignores it.
- *Fix:* the request is a `<configure>` alone.

**Withdrawn contact requests went unseen**
(`PresenceModule.SubscriptionChange`)
- *Symptom:* someone who asked to add us and then changed their mind
  stayed in our contact requests until the next sign-in.
- *Cause:* the module only published `subscribe` and `unsubscribed`
  presences. An `unsubscribe`, which is how a pending request is taken
  back, was logged as a "weird type" and dropped.
- *Fix:* it's published too, as a new `unsubscribe` action.

**Blocklist changes from the server went unanswered**
(`BlockingCommandModule`)
- *Symptom:* blocking someone on another device left the server waiting
  for an answer it never got. The reports we attach when blocking someone
  named the offending messages in a form servers don't recognize.
- *Cause:* the module applied the server's block and unblock pushes but
  never acknowledged them, which RFC 6120 requires of every `set`. It
  also took them from anyone. The `<stanza-id>` elements of a XEP-0377
  report lacked their `urn:xmpp:sid:0` namespace, and `ReportedStanza`
  couldn't be built outside the module.
- *Fix:* pushes are acknowledged, and only accepted from our own server.
  Reports name messages in the right namespace, and `ReportedStanza` has a
  public initializer.

**Client state was never sent to the server**
(`ClientStateIndicationModule.setState`)
- *Symptom:* the server never learned the app was in the background, so it
  kept pushing presence and chat states to a client nobody was looking at.
- *Cause:* both `setState` methods began with `guard state != state`. The
  parameter shadows the property, so the guard compared it with itself and
  always returned early. Nothing was ever sent.
- *Fix:* the check is gone. A repeated `<active/>` or `<inactive/>` is
  harmless, and skipping on a match would be wrong after a resumed stream,
  where the server may hold a state we don't remember. The stored state also
  starts as active, and resets to active on a new session, which is what a
  server assumes for one.

**No way to know which messages the server received**
(`StreamManagementModule.ackedStanzas`)
- *Symptom:* a message that never reached the server could show as sent,
  and messages to servers that don't archive them were sent again after
  every new session.
- *Cause:* the module tracks which stanzas the server acknowledged
  (XEP-0198), but only to resend the rest on resumption. Nothing outside
  could tell a message was received.
- *Fix:* acknowledged stanzas are published, in the order they were sent,
  on an ack and on resumption.

**No SASL2, Bind 2 or FAST** (new `Sasl2Module`, `HTMechanism`)
- *Symptom:* every connection took several round trips to sign in, bind
  and resume, and hashed the password each time. That's slow on mobile
  networks, and a push only gives the notification extension seconds.
- *Cause:* Martin only knows RFC 6120 SASL, resource binding and a
  separate stream management step.
- *Fix:* `Sasl2Module` signs in with XEP-0388, binding (XEP-0386) and
  resuming or enabling stream management inline, and asks for a XEP-0484
  token, which `HTMechanism` (HT-SHA-256-NONE, -EXPR or -ENDP) uses on the
  next sign-in instead of the password. A refused token falls back to the password on
  the same stream. `AuthModule` picks it when the server offers it, and
  `SocketSessionLogic` skips the stream restart and takes the binding or
  resumption from it. Servers without SASL2 go through the old path,
  unchanged.
- *How a resumption connects:* `Sasl2Module` applies a `<resumed>` to
  stream management as soon as `<success>` is processed, before the `<r/>`
  and resent stanzas the server sends right behind it. The session logic
  then carries on to connected from the authorization itself: a server that
  resumes inline has nothing new to announce (ejabberd sends no features),
  so waiting for features would hang until the watchdog gave up. Features
  that do follow a resumption are ignored. A bound session still carries on
  from the features.
- *Race when binding:* Bind 2's `<enabled>` and the bound JID were applied
  only when the session logic handled the authorization, a queue hop after
  `<success>`. A stanza read along with `<success>` was handled first, with
  stream management not yet enabled: it wasn't counted, so the `h` we
  reported was short and the server resent it on resumption, and an `<r/>`
  went unanswered. `Sasl2Module` now applies both as soon as `<success>` is
  processed, as for `<resumed>`; the session logic only carries on. When
  the server refused an inline resumption and bound a new session, the old
  session is cleared first, so the reset doesn't undo the new one.
- *Transport:* the FAST token is only sent, and `HTMechanism` only used,
  when TLS is active or the configuration turned it off (`disableTLS`), the
  same rule as PLAIN below.

**Partial stream acks marked unsent messages as delivered**
(`StreamManagementModule.processAckAnswer`)
- *Symptom:* a message sent while an earlier one was still unacknowledged
  could be reported as sent before the server had it. If the connection
  dropped then, it was lost: it was no longer queued for resending.
- *Cause:* each ack reset the count of stanzas written to the server's
  count, although the unacknowledged ones stayed queued. The count then
  lagged the queue, so the next ack released stanzas the server hadn't
  handled yet, and every later partial ack did the same.
- *Fix:* the count keeps counting what was written, and an ack drops the
  stanzas it covers from the front of the queue. Counters now wrap at 32
  bits as XEP-0198 says, rather than trapping, and the difference between
  ours and the server's is read as signed: a server claiming more than we
  wrote releases the whole queue and takes over its count, instead of
  silencing acks for the rest of the stream. Resumption still starts the
  count from the server's, since it writes the remaining queue again.

**A delayed stream ack landed on the next stream**
(`StreamManagementModule.processAckRequest`, `processIncoming`, `reset(scopes:)`)
- *Symptom:* now and then a reconnect failed: the server closed the new
  stream with `unsupported-stanza-type` and the client signed in again from
  scratch, without resuming. Prosody's log shows `<a xmlns='urn:xmpp:sm:3'
  h='708'/>` arriving on a stream that hasn't authenticated yet, right after
  the server had sent `<r/>` on the old one.
- *Cause:* answering an `<r/>`, and acking received stanzas, wait 0.1 s
  before writing. Nothing tied that wait to its stream: the answer to a
  request was never cancelled, and one for received stanzas was only
  cancelled by a flag the next stream could set again. If the connection
  dropped and reopened inside the wait, the ack went out on the new stream.
- *Fix:* the module counts streams, a reset of the stream scope advances the
  count, and a delayed ack that finds the count changed is dropped.

**A stanza sent while stream management was starting was lost to it**
(`StreamManagementModule.processOutgoing`)
- *Symptom:* on ejabberd, which enables stream management after binding,
  a stanza written while it was being enabled (one iq, in practice) wasn't
  kept for resending, and our count of written stanzas stayed one behind
  the server's for the rest of the stream.
- *Cause:* the server counts every stanza after it reads `<enable>`, but
  Martin only started counting, and queueing, when `<enabled>` came back.
  Resetting our count to the server's on every ack hid the gap; once the
  partial ack fix above stopped that reset, it left no ack able to release
  anything until the difference was read as signed.
- *Fix:* counting starts when `<enable>` passes through `processOutgoing`,
  which is in step with the socket writes, and stops again on a reset.

**A message resent on resumption was never confirmed**
(`StreamManagementModule.processResumed`)
- *Symptom:* a message written just as the connection died, and never
  received by the server, stayed unconfirmed (a clock in the app) after the
  stream was resumed, until the user sent something else.
- *Cause:* resumption writes the unacknowledged stanzas again but asks for
  no acknowledgement of them. A request only follows a send of ours or
  more than three stanzas waiting, so the server never said it had them.
- *Fix:* when any stanza is written again, an ack is requested right after.

**A dead connection was never dropped**
(`SocketSessionLogic.keepalive`)
- *Symptom:* after a switch from Wi-Fi to cellular, a router forgetting the
  connection, or a laptop waking up, the app stayed "connected" while
  nothing arrived, until the user restarted it.
- *Cause:* a half-open TCP connection reports no error, so Martin only
  learns of it from a ping that goes unanswered. The keepalive pinged the
  server, logged "possible that connection is broken, reconnecting..." when
  that failed, and did nothing. `SO_KEEPALIVE` is off, and with the OS's
  default timers (hours) turning it on alone wouldn't help.
- *Fix:* a ping that times out closes the socket by force, which leaves
  the stream management session intact so the reconnect resumes it. An
  error reply doesn't count, as it proves the link works. We left
  `SO_KEEPALIVE` off: tuned timers short enough to matter would wake the
  radio constantly, and the ping covers the case.

**Unexpected sign-in input wasn't handled gracefully**
(`SaslModule.processSuccess`, `StreamManagementModule.processResumed`,
`ScramMechanism`)
- *Cause:* a few values read from the server during sign-in and resumption
  were force-unwrapped or used in a range that traps: the mechanism in use
  when a `<success/>` arrives, the `h` attribute of `<resumed/>`, the
  decoded SCRAM challenge, and its iteration count.
- *Fix:* a `<success/>` outside an authentication fails it, which closes
  the stream. A `<resumed/>` without `h` counts as 0, a challenge that isn't
  UTF-8 is a bad challenge, and SCRAM takes iteration counts from 1 to
  1,000,000 (servers use a few thousand).

**A message written to a dead connection counted as sent**
(`LogicPacketWriter.write(_:writeCompleted:)`)
- *Symptom:* a message sent just as the connection dropped could stay
  unsent until the next new session, which can be days away, with nothing
  telling the user.
- *Cause:* the session drops a stanza written once it is no longer
  connected, and tells the caller through a completion. The writer didn't
  pass that on: it called `writeCompleted(.success)` right after handing the
  stanza over, so the caller kept its claim on a message that never left.
- *Fix:* the writer forwards `writeCompleted` to the session, so a dropped
  write reports its failure.

**An unknown roster `subscription` value crashed the app**
(`RosterModule.processRosterItem`)
- *Symptom:* a roster item whose `subscription` isn't one of the values in
  RFC 6121 killed the app on every connect, as the roster is fetched then.
- *Cause:* `RosterItemSubscription(rawValue:)!` force-unwrapped a value the
  server chooses.
- *Fix:* the item is skipped. A missing attribute still means `none`.

**The certificate check ran apart from the stream's reads and writes**
(`SocketConnector.certificateAllowsIO`)
- *Cause:* the check ran when the output stream first reported space, an
  event that takes a detour through the main thread, while reads and writes
  carried on their own thread.
- *Fix:* once TLS is started, writes wait in the buffer and what is read is
  held, not parsed, until the certificate is accepted. Either stream's first
  event, or the first write or read, runs the check as soon as the TLS layer
  can show the certificate, so a good connection loses no time. A connection
  whose certificate is refused is closed with the data dropped.

**STARTTLS now follows RFC 6120 5.4.3.3 strictly**
(`SocketConnector.parsed`, `proceedTLS`)
- *Fix:* anything the parser reports between `<proceed/>` and the restart of
  the stream closes the connection, as the server sends nothing there, and
  the connector reads nothing else from the stream until then. A
  `<proceed/>` we didn't ask for closes it too.

**PLAIN is only used over TLS**
(`PlainMechanism.isAllowedToUse`)
- *Fix:* PLAIN is used only when TLS is active, or when the configuration
  turned TLS off (`disableTLS`), which Yapnest does only for local
  development servers on localhost. The app prefers SCRAM-SHA-256-PLUS and
  SCRAM-SHA-1-PLUS (see the next entry), then SCRAM-SHA-256, SCRAM-SHA-1 and
  PLAIN, and a FAST token first when it holds one.

**A password sign-in wasn't tied to the TLS connection**
(new `ChannelBinding.swift`; `ScramMechanism`, `SaslModule`, `Sasl2Module`,
`SocketConnectorNetwork`)
- *Symptom:* someone able to relay the connection with a certificate the
  device trusts (a mis-issued one, or a CA a device was made to install)
  could pass a SCRAM proof on to the real server and sign in as the user.
  The server could tell, but was never asked to.
- *Cause:* Martin had no channel binding. SCRAM always said `n` (the client
  can't bind), and there were no -PLUS mechanisms. Upstream `devel` has
  -PLUS, but it never runs: the mechanism doesn't hear the stream features,
  so it never learns the server's binding types. Its connectors have no
  binding data of their own either.
- *Fix:* once TLS is up, the connector reads RFC 9266's `tls-exporter`
  (TLS 1.3 only: on 1.2 it needs the extended master secret, which the
  connection doesn't report) and RFC 5929's `tls-server-end-point` (the
  certificate hashed with its signature's hash, read from the certificate;
  none for EdDSA or RSASSA-PSS). SCRAM-SHA-256-PLUS and SCRAM-SHA-1-PLUS are
  tried first wherever the server lists a type both sides have (XEP-0440),
  preferring the exporter. Without one, plain SCRAM says `y` when the server
  offered no -PLUS at all, which a server that can bind must refuse, as it
  means the -PLUS offer was taken out on the way; and `n` when it did offer
  -PLUS but with no type in common. A failed binding is a refused sign-in,
  never a quiet fallback. The same change gives SCRAM a 32-character nonce
  from the whole alphabet (it used only A to T) and escapes `,` and `=` in
  the user name (RFC 5802's saslname). FAST tokens are bound the same way
  where the server lists `HT-SHA-256-EXPR` (tls-exporter) or
  `HT-SHA-256-ENDP` (tls-server-end-point): both proofs then cover the
  binding data, and the strongest variant the connection can bind is
  requested. `HT-SHA-256-NONE` stays for servers that offer no other.

**A server could hide the strong mechanisms and get the password**
(new `SignInStrength.swift`; `SaslModule`, `Sasl2Module`)

- *Cause:* the mechanism was whatever the server offered, down to PLAIN, so
  someone in the connection with a certificate the device trusts could
  offer only PLAIN and defeat SCRAM-PLUS.
- *Fix:* the modules are given the mechanism of the strongest sign-in that
  worked for the account (`signInRecord`, kept by the app) and refuse to
  start one below it, with `WeakerSignInError`, before anything is sent.
  The tiers are bound (SCRAM-*-PLUS, HT-SHA-256-EXPR/ENDP), SCRAM (without
  binding, and HT-SHA-256-NONE) and PLAIN. A stored token is used only as
  the mechanism it was issued for, and not below the record.

**TLS stopped at 1.2, so TLS 1.3 only servers were out of reach**
(`SocketConnectorNetwork`, new `StartTLSFramer` and `StartTLSPreamble`,
`ConnectionConfiguration.connectorOptions`)
- *Symptom:* signing in to a server that only offers TLS 1.3 failed. That is
  Snikket's default configuration, and what servers are moving to.
- *Cause:* `SocketConnector` starts TLS through CFStream's SSL settings,
  which is Secure Transport: deprecated, TLS 1.2 at most, and without the
  system's TLS fixes. Martin's other connector, `SocketConnectorNetwork`, is
  on Network.framework but expected an external TLS implementation (Siskin
  brings an OpenSSL one) that Martin doesn't ship.
- *Fix:* `SocketConnectorNetwork` does the TLS itself, with Apple's, and is
  now the default connector. STARTTLS has no API in Network.framework, so a
  protocol layer, `StartTLSFramer`, sits between TCP and TLS. It opens a
  stream, reads the features, sends `<starttls/>` and waits for
  `<proceed/>` over the bare TCP connection, then passes bytes through, and
  TLS handshakes on the same socket. The XMPP code never sees that exchange;
  it opens a fresh stream over TLS, as RFC 6120 says. `StartTLSPreamble`
  holds the parsing, apart from the network so it can be tested. A server
  without STARTTLS in its features, a `<failure/>`, a stream error, or any
  byte after `<proceed/>` ends the connection (a refusal, never plaintext).
  Direct TLS (XEP-0368, from the `_xmpps-client` SRV record) skips the layer
  and offers ALPN `xmpp-client`. `disableTLS` gives a plain TCP connection.
  The certificate goes through the `sslCertificateValidation` option in the
  TLS verify block, with the server name set to the account's domain
  (`.default` now checks it as a server's certificate, where the old
  connector used the client policy, which rejects Let's Encrypt
  certificates; `InBandRegistrationModule` relies on it). A connection is
  only ready, and nothing is written, once the certificate is accepted, and
  a refusal ends as `.sslCertError`. A server that doesn't offer STARTTLS
  ends as an `xmlError` with the message `startTLSNotOffered`, which
  Yapnest treats as fatal, as it did before. The connector keeps
  SO_KEEPALIVE off, times the whole connect (DNS to handshake) by
  `connectionTimeout` (the old connector's option is spelled
  `conntectionTimeout`), and reports the negotiated TLS version as
  `negotiatedTLSVersion`. Network.framework retries a connection it can't
  make forever (`.waiting`); the connector gives up on it, as the session
  decides when to try again. The older entries that name `SocketConnector`
  describe code Yapnest no longer runs: it stays in the tree, unused,
  because `SocketConnector` is also where Martin keeps types other code
  names (its events and `preprocessConnectionDetails`).

**A dead SRV port kept the account offline**
(`SocketConnectorNetwork.start`, `XMPPDNSSrvResolver.markAsInvalid`, `XMPPSrvResult.candidates`)
- *Symptom:* on a server whose `_xmpps-client` port (5223) accepted TCP but
  never answered the TLS handshake, the app never connected, though its
  `_xmpp-client` port (5222) worked.
- *Cause:* the connector tried only the first SRV record. When it failed or
  timed out, the record was marked invalid, but the default resolver
  ignored that, so every reconnect started with the same record again.
- *Change:* an attempt that resolved SRV records itself tries them in turn:
  those not marked invalid first, then the invalid ones, so it never gives
  up while one is untried. An endpoint that times out, fails or is
  unreachable is dropped without a state change, marked invalid for 15
  minutes, and the next is tried; the attempt ends only when none is left,
  for the last one's reason. `connectionTimeout` now applies to the DNS
  query and to each endpoint in turn, not to the attempt as a whole. A
  rejected certificate and a STARTTLS failure still end the attempt, so a
  certificate the user didn't accept isn't worked around through another
  port. An explicit endpoint (resumption, see-other-host) or
  `connectionDetails` is tried alone, as before. `XMPPDNSSrvResolver` now
  remembers what is marked invalid, in memory, and marks it on the records
  it returns, so the next reconnect starts with a working one. The record's
  fields and `isValid` are public. When the connection reports it is
  waiting and the system has no usable network, the attempt ends as
  unreachable without marking or trying any endpoint: none is at fault.
  A refused connection is reported as waiting too, but with a network, so
  it falls back.

**Capabilities couldn't change after the first presence**
(`CapabilitiesModule.invalidateVerificationString`)
- *Symptom:* turning a feature on or off while connected left the old
  capabilities hash in our presence, so contacts' clients saw the wrong
  features until the next launch.
- *Cause:* the module worked the hash out once and kept it.
- *Change:* the new method marks it out of date, so the next presence works
  it out again. The old hash is kept until then, so that working out the new
  one unregisters its `node#ver` disco entry; forgetting it outright left
  every earlier entry answering with features that no longer matched its
  hash. The hash is behind a lock, as the setting changes on a background
  thread while presences are built on the XMPP queue. Yapnest calls it when
  the user changes the last seen setting.

**Calls: Jingle and SDP fixes**
(`JingleModule`, `SDP`, `Jingle`, `ExternalServiceDiscoveryModule`)
- *Symptom:* calls with Conversations, Dino and Chrome-shaped SDP dropped
  codec parameters, candidates and fingerprints, and Martin answered
  call proposals on its own.
- *Cause and change, one by one:*
  - `process(message:)` answered a propose it had no description for with a
    reject, to the sender and to our other devices, whoever the sender was,
    and a message to a module with message initiation off got an error
    reply. It is now `open` (Yapnest overrides it to do nothing, as the
    session reads these messages itself) and such a message is ignored.
  - An `fmtp` line was split at every `=`, cutting a base64 value, and a
    parameter without one (RED's `111/111`) was written back as `111/111=`.
    Only the first `=` splits now. A bare token is a parameter whose name is
    the token and whose value is empty; it is sent with `value=""`, which
    XEP-0167 requires, read whether or not `value` is there, and written as
    the bare token in SDP.
  - `transportInfo`, `terminateSession` and `sessionInfo` printed the
    answer. They take an optional `completionHandler` instead.
  - `Candidate(fromSDP:)` dropped a candidate without `generation`, which
    trickled candidates from WebRTC often lack. It is 0 then, and a
    candidate line needs only the eight fields up to the type.
  - `Candidate(from:)` read `protocol` case-sensitively and only knew `udp`
    and `tcp`. RFC 8445 allows any token, so `protocolType` is now a
    lower-case `String` (the `ProtocolType` enum is gone).
  - A fingerprint without a valid `setup` was dropped, and with it the
    whole transport's encryption. It defaults to `actpass`, in Jingle and in
    SDP.
  - `Candidate.foundation` was a number, so a candidate with a foundation
    such as pjnath's `Hc0a80001` was dropped. RFC 8445 allows 1 to 32
    letters, digits, `+` and `/`, so it is a `String`.
  - `bundle(from:)` took the first `<group>` whatever its semantics. It
    takes the one with `BUNDLE`.
  - `ExternalServiceDiscoveryModule.isAvailable` was false until the
    server's disco#info had arrived, so a call made right after connecting
    got no STUN or TURN. It is true until the server's answer is known and
    lacks the feature.
  - Nothing asked for the credentials of a service listed `restricted`
    (XEP-0215, "Requesting Credentials"), which is how TURN servers such as
    ejabberd's usually come. `ExternalServiceDiscoveryModule.credentials(for:)`
    sends the request, naming the service by host, type and port, and
    returns a copy of the service with the answer's username, password and
    expiry. Yapnest asks for every restricted service without credentials
    and drops a TURN one whose request fails.

**A login made as a connection drops was lost, with the resumption**
(`XMPPClient`)
- *Symptom:* a `login()` in the same millisecond as a drop (a network change
  landing as the connection died) started a session, then vanished. The
  retry after the backoff connected as a new session, with stream management
  enabled again instead of resumed.
- *Cause:* the session logic's `.disconnected` was published to `state`
  first, and only then did the clean-up reset the stream, unbind and drop
  the session logic. A `login()` in between saw `.disconnected` and built a
  new session logic, which the clean-up then threw away, along with the
  stream state the new attempt needed. The state check in `login()` also ran
  outside the queue that starts the attempt, so two logins could both pass it.
- *Change:* the clean-up runs first and publishes `.disconnected` last,
  together with dropping the session logic, on the context's queue. `login()`
  checks the state on that queue. The clean-up also leaves alone a session
  logic that is no longer the client's current one. Checked by
  `LoginDuringDisconnectTests`, and by `twentyResumesInARow`, which logs in
  with no delay on every other round.

**A catch-up cut off by a drop read as finished** (`XMPPClient`,
`ResponseManager`)
- *Symptom:* a connection that dropped while the archive query was out
  showed as connected and synced for a moment before it read as
  disconnected, and the resumed stream never ran the catch-up again, so what
  the archive held was not fetched.
- *Cause:* with the clean-up first, unbinding the session logic failed the
  unanswered requests while `state` still read connected. Their callbacks,
  which tell a drop from the server's answer by asking whether the client is
  connected, took it for an answer on a live stream.
- *Change:* the clean-up takes the unanswered requests out of the response
  manager before it unbinds, and fails them after it publishes
  `.disconnected`, outside the context's queue. Checked by
  `LoginDuringDisconnectTests.aRequestTheDropLeftUnansweredFailsOnceTheClientReadsDisconnected`
  and `SessionResilienceIntegrationTests.aDropDuringCatchUpNeverReadsConnectedAndSyncsAfterTheResume`.

**Nothing to tell why a connection attempt failed**
(`SocketConnectorNetwork.Options.diagnostics`)
- *Symptom:* "can't connect on 4G" reports came with no way to see which
  step failed: the SRV lookup, a refused port, a stalled TLS handshake.
- *Cause:* the connector only wrote that to the system log, which the app
  can't read back to put in an exported log.
- *Change:* the options take a `diagnostics` callback, called with
  `ConnectEvent`s: the SRV result (record count, whether the domain itself
  was used), each endpoint tried (kind, port), when one came up (address
  family, duration) and why one didn't (reason, the `NWError` kind and code).
  The events hold enums and numbers only, never a host or an address, so the
  app can log them as they are. If the SRV lookup never answers before the
  connection timeout, a `resolveTimedOut` event says so and the attempt ends.
  `SaslModule` and `Sasl2Module` clear `lastMechanism` (and `Sasl2Module`
  `signedInWithToken`) when a sign-in starts, so the app doesn't report an
  earlier stream's mechanism.
- *Privacy:* Martin's own logging is otherwise unchanged, except that the
  `<feature-not-implemented>` stanza dump is private now, and so are the
  domain and results in `XMPPDNSSrvResolver` and the JID and disco result in
  `CapabilitiesModule`, which logged them as public. `MucOccupant.set(presence:)`
  no longer prints the occupant's nickname on every presence.

**Unanswered requests failed on the main thread** (`ResponseManager.checkTimeouts`)
- *Symptom:* the debug build crashed when a group's info request went
  unanswered: joining it went on to read the database on the main thread.
  The release build did the same read there, holding up the interface.
- *Cause:* the timer that fails timed-out requests is on the main run loop,
  and it called their callbacks there, inside the manager's lock. A
  callback that cancelled a request would also have crashed on that lock.
- *Fix:* the timed-out requests are taken out under the lock, and their
  callbacks run after it on a queue of their own. Pinned by
  `ResponseTimeoutTests`.

**A stanza past the server's size limit blocked every message after it**
(`StreamFeaturesModule.fits`, `XmppSessionLogic.send`, `LogicPacketWriter`)
- *Symptom:* one huge message (a crash report pasted as text) stuck as
  pending, and nothing queued behind it was ever delivered, however often
  the app reconnected.
- *Cause:* Prosody closes the stream with `policy-violation` on a stanza past
  its `c2s_stanza_size_limit` (262144 bytes), 30 seconds later when its rate
  limit slows the read. The pending message was written first on every
  connect, so the cycle repeated. Martin never checked a stanza's size and
  ignored XEP-0478.
- *Fix:* `StreamFeaturesModule` keeps the `max-bytes` of stream features
  received after sign-in, 262144 when there is none. Before sign-in a server
  advertises the limit for unauthenticated streams (Prosody: 10000), which
  is ignored; a resumed SASL2 stream gets no new features, so the default
  applies there. A stanza
  over it is refused in `send`, before the filters so stream management never
  counts it, with `XMPPError.stanzaTooLarge`; a request fails with it rather
  than as a timeout. `stanzaRefused` reports a refusal. Pinned by
  `StreamLimitTests` and `StreamLimitIntegrationTests`.
- *Also:* `StreamManagementModule.unacknowledgedStanzas` (and
  `oldestUnacknowledged`) name the stanzas a server hadn't acknowledged when
  it closed the stream, so Yapnest can tell which stanza it keeps closing
  the stream on, and whether it was alone. The queue is still held when the
  disconnect is reported; only a new session clears it. Pinned by
  `StreamErrorStrikeTests`.

**A control character in a message closed the stream** (`EscapeUtils.escape`)
- *Symptom:* a message pasted from a terminal (with `\u{1B}` or `\u{07}`)
  stayed pending, and nothing queued behind it was delivered.
- *Cause:* the escaping handled `& < > " '` only, so a character XML 1.0
  forbids was written as it was. Prosody and ejabberd close the stream with
  `not-well-formed` on it and Openfire with `internal-server-error`, on
  every reconnect, as the message was written first each time.
- *Fix:* `escape` drops U+0000 to U+001F except tab, line feed and carriage
  return, and U+FFFE and U+FFFF, from text and attribute values. Strings
  without any are not rebuilt; `EscapeUtils.removingForbidden` is the same
  filter for callers that must agree with the wire. Pinned by `XMLEscapingTests` and
  `ControlCharacterIntegrationTests`.

**The roster was fetched in full on every connect, and a failed fetch went unseen**
(`RosterModule.requestRoster`, `requestsRosterOnConnect`)
- *Symptom:* every sign-in downloaded the whole roster, although we store its
  version, and a roster request that timed out left the contacts as they were
  until the next session, with nothing to say so.
- *Cause:* the stored version was sent only if the stream features announced
  roster versioning, which servers do after authentication and a SASL 2 sign-in
  with an inline bind has no stream restart to read them from. The request
  was made from the module's state callback, out of the app's reach.
- *Fix:* the stored version (or an empty one, to be given a version) is always
  sent, which servers without versioning ignore (RFC 6121 section 2.6); an
  answer with no items to a versioned request removes the contacts we hold
  only if its `ver` isn't the one we sent, as the version then says it is the
  full, empty roster (RFC 6121 section 2.6.3 signals no change with a result
  without a query; some servers send the old version back instead). `requestsRosterOnConnect` turns the automatic request off, so
  Yapnest asks itself, retries and shows the failure. Pinned by
  `RosterVersionTests`.

**A failed account discovery left the session syncing for good** (`DiscoveryModule.accountDiscoveryFailed`)
- *Symptom:* when the server answered the discovery of the account's
  features with an error, or the request got no answer, the session stayed
  "syncing" for good: nothing pending was sent, and push, settings and read
  states were never set up.
- *Cause:* Martin starts the discovery itself when the session is bound,
  with no completion handler, and a failure only left the result empty.
- *Fix:* `discoverAccountFeaturesOnBind()` is what the session start calls,
  and it tells `accountDiscoveryFailed` when the request fails. Yapnest asks
  again while the error can pass and then goes on without the features.
  Pinned by `AccountDiscoveryFailureTests`.

**A request timed out up to 30 seconds late** (`ResponseManager.registerResponseHandler`)
- *Symptom:* a request given a 5 or 10 second timeout failed after 5 to 35
  (sign-out waiting on push, the Openfire fallback for the settings node, a
  message confirmed by ping).
- *Cause:* expired requests were only swept by a timer that fires every 30
  seconds.
- *Fix:* each request also schedules a sweep for its own deadline. Pinned by
  `ResponseDeadlineTests`.

**Acknowledgement requests were sent without stream management, and never throttled** (`StreamManagementModule.request`)
- *Symptom:* a stream that never negotiated stream management was sent
  `<r/>`, which ejabberd answers with `unexpected-request` (a stricter
  server may close the stream), and every call wrote one however close
  together.
- *Cause:* `request()` had no check for stream management being enabled,
  and its throttle compared against `timeIntervalSinceNow < 1`, which is
  always true for a past date.
- *Fix:* nothing is sent unless stream management is enabled, and a request
  within a second of the last waits for the second to pass, once, rather
  than going out at once or being lost. Pinned by `AcknowledgementRequestTests`.

**Carbons were enabled a second time after Bind 2** (`Sasl2Module.carbonsEnabledInline`)
- *Symptom:* on a server that takes carbons inline in Bind 2, the session
  sent a second `<enable/>`, and could not tell whether the inline one
  worked.
- *Cause:* nothing recorded the server's `<enabled xmlns='urn:xmpp:carbons:2'/>`
  in the `<success>` of the sign-in.
- *Fix:* the module keeps whether it was there. Pinned by `CarbonsEnableTests`.

**The server itself couldn't be the upload service** (`findHttpUploadComponents`)
- *Symptom:* a server that offers HTTP File Upload on its own domain, as
  XEP-0363 §4.1 allows, read as having none.
- *Cause:* only the items of the domain were asked about.
- *Fix:* the domain is asked too, and listed first. Failing to list the items
  is only an error if the domain offers nothing either.

**A server's redirect could crash the app on every launch**
(`SocketConnector.preprocessConnectionDetails`, `SocketSessionLogic.onStreamError`)
- *Symptom:* a `see-other-host` naming a port outside 1–65535 crashed the
  app where the endpoint was made, and every launch met the same redirect.
- *Cause:* the port was read as any `Int` and later made a `UInt16`. The
  redirect was also followed before STARTTLS, where anyone on the network
  path can write one.
- *Fix:* an address whose port isn't one is ignored, as is a resumption
  location of that kind, and a redirect is followed only on an encrypted
  stream or an account that never uses one. Pinned by `SeeOtherHostTests`.

**A group member could change a group's picture** (`PubSubModule.process(message:)`)
- *Symptom:* a member's group message carrying an empty avatar event cleared
  the group's picture for every member, and one naming a cached picture
  swapped it in; a nickname event renamed it.
- *Cause:* an event was taken from any message, and a room passes on what
  its members put in theirs, from room/nick, whose bare address is the
  room's.
- *Fix:* an event in a group message, or from an address with a resource,
  is ignored: a service notifies from its bare address. Pinned by
  `PubSubEventSourceTests`.

**Anyone could say what a popular client can do** (`CapabilitiesModule.onReceivedPresence`)
- *Symptom:* a presence claiming another client's caps `ver`, answered with
  a made-up feature list, could hide the call buttons, or change how files
  are sent, for every contact on that client until the app restarted.
- *Cause:* the answer was cached under the claimed `node#ver` without
  working out its hash (XEP-0115 §5.4), and that entry stands for everyone
  who shows the same `ver`.
- *Fix:* the answer's verification string is computed (SHA-1 or SHA-256,
  with identities, features and extended forms as §5.1 orders them) and the
  answer is cached only if it matches; a `node#ver` that didn't isn't asked
  about again. Pinned by `CapsVerificationTests`, on the XEP's own examples,
  and `CapabilitiesTests`.

**Two repeating timers wake the main thread at exact times**
(`ResponseManager.start`, `XMPPClient.scheduleKeepAlive`)
- *Symptom:* a connected app, the Mac's always, woke the main thread every
  30 s for the response sweep and every 175 s for the keepalive, at moments
  the system couldn't batch with other work, which costs battery.
- *Cause:* both `Timer`s had no tolerance.
- *Fix:* the sweep has a tolerance of 5 s (each request also checks itself
  when its timeout is up) and the keepalive a tenth of its interval, at most
  15 s. Not covered by a test: a timer's tolerance can't be observed.

### MartinOMEMO

**A device list of thousands of ids cost thousands of bundle fetches**
(`limitDevices`, `addresses(for:)`, `checkAndPublishDevicesListIfNeeded`)
- *Symptom:* a contact, or a server, that published a list of thousands of
  device ids had us fetch a bundle for each and send a stanza to each, most
  of which bounced.
- *Change:* a list we read is passed through `limitDevices`, a hook the app
  sets, before sessions are built, statuses set or anything is emitted, in
  both places a list is parsed (a notification, and the fetch made when
  encrypting). The policy (at most 64 devices: those in use first, then new
  ones, then those gone quiet) is in YapnestKit's `OMEMOStore.limited`.

**Logs named people publicly** (`OMEMOModule`)
- *Symptom:* the system log held the addresses whose device lists or bundles
  failed, readable by anyone who collects a sysdiagnose.
- *Change:* the JID and the address name in those lines are private (hashed),
  as everything that names a person or a server should be.
- *Also:* the lines that logged a failed request's `description` as public
  (device list, bundle, node configuration) now log only the error
  condition, as the description holds the server's `<text>`, which can name
  an address. Device ids are private (hashed) too. The `print` of an address
  and error when a session couldn't be completed is a private `Logger` call.
  `SignalContext` sends libsignal's log text to a private debug `Logger`
  instead of `print`.

**Our keys were published twice at once on a new device**
(`isPepAvailable`, `publishDeviceBundleIfNeeded`)
- *Symptom:* the first message to a brand-new device often couldn't be
  decrypted.
- *Cause:* publishing ran every time account discovery reported PEP, and a
  session can see that report more than once. Two runs at the same time
  each found no keys and each generated signed prekey 1 and prekeys 1–100.
  The second run overwrote the first in our key store, but the server could
  keep the first set, whose private keys no longer existed.
- *Fix:* publish when PEP *becomes* available, and run one publish at a
  time. Calls that arrive meanwhile wait, then the publish runs once more.

**Failed publishes went unnoticed**
- *Symptom:* a device could stay unregistered for the whole session. Others
  never encrypted for it, and our own "ready" flag never came on.
- *Cause:* when a server refused the publish options (precondition-not-met,
  a *conflict* condition), MartinOMEMO only reconfigured the node and
  retried if the error had no text, and servers usually add text. A failed
  key publish never called back, which left the device stuck.
- *Fix:* on any conflict, reconfigure the node and retry, for both the
  device list and the keys. A device whose keys didn't publish never
  registers, rather than registering without keys.

**A failed key publish was never tried again**
(`registerDevice`, `resumeRegistrationIfNeeded`, `publishDeviceBundleIfNeeded`)
- *Symptom:* after one dropped or refused request while signing in, a device
  stayed unregistered until the next new session. Contacts and our other
  devices never encrypted for it, so what they sent showed as "couldn't be
  decrypted", with nothing in the interface to say why.
- *Cause:* nothing retried a failed publish. A failure dropped the waiting
  steps without calling them, so our device id was never listed and the
  "ready" flag stayed off. Upstream published again each time account
  discovery reported PEP, which sometimes covered for a failure; our fix for
  the double publish above made it run only when PEP becomes available,
  which took that away. A resumed stream, the usual mobile reconnect,
  doesn't discover PEP again, so nothing started it over. Separately,
  a device list that already named us marked the device ready without
  checking that its keys were published.
- *Fix:* a failed registration is retried after 5 seconds, 30 seconds, 2
  minutes, then every 5 minutes (`registrationRetryDelays`), while PEP is
  available and the device isn't ready. A timer never starts a publish on
  top of one in flight, and ends with readiness or a reset of the stream or
  session. The waiting steps are kept for the next publish that works,
  rather than dropped, and the registration queues only once. A resumed
  stream starts it at once if the device isn't ready
  (`resumeRegistrationIfNeeded`, called by `XMPPSession`). The device only
  becomes ready on a list naming it once its keys are known to be published.

**A server that ignored the open access model hid our device list**
(`ensureOpen`, `deviceListError(for:)`)
- *Symptom:* on Openfire, a contact we aren't subscribed to couldn't read
  our device list or keys, so their encrypted messages to us, and ours to
  them, never got anywhere.
- *Cause:* Openfire answers a publish that asks for `access_model=open`
  with success and keeps its own presence-based model. The conflict
  retry never fires, as nothing is refused.
- *Fix:* after a successful publish of the device list or the keys, the
  node's configuration is read, and set to open if it isn't. A failed
  fetch of someone's device list is remembered (`deviceListError(for:)`),
  so the sender can say why it can't encrypt.

**A device that failed once was ignored for the whole connection**
(`devices(for:)`, `markDeviceAsFailed`)
- *Symptom:* a contact's new device never received our messages until we
  reconnected, even though it showed in their published device list.
- *Cause:* if fetching a device's keys failed once, even briefly, the device
  was filtered out for the rest of the session. The list of failed devices
  was also read and written from several threads without a lock.
- *Fix:* failed devices are skipped for a minute, then retried. The mark
  clears once a session is built, and the list is only touched on
  MartinOMEMO's own queue.

**Looking up several accounts at once mixed their results**
(`addresses(for:)`)
- *Symptom:* encrypting for a group, which has several members, was slow and
  unreliable. Sessions were sometimes built twice, and the second attempt
  failed.
- *Cause:* every account's lookup appended to one shared list, from
  callbacks on any thread. Each callback then rebuilt sessions for
  everything in the list so far, including other accounts' devices. Asked
  for our own account, it also tried to build a session with the device
  doing the asking, which never finishes.
- *Fix:* each account's results are kept apart, collected under a lock, and
  this device is left out.

**Session building could wait forever** (`buildSession`)
- *Symptom:* a send could hang until its 45-second timeout.
- *Cause:* for one of our own devices with no published keys, the
  completion handler was never called.
- *Fix:* it's always called, whatever the outcome.

**Removing our dead devices could loop forever**
(`checkAndPublishDevicesListIfNeeded`)
- *Symptom:* two of our own clients online together kept rewriting our
  device list. A new device could drop out of it for a moment, and anything
  sent in that moment never reached it.
- *Cause:* our devices with no published keys get removed from the list
  once all session attempts are done. But the "all done" callback was
  registered before any attempt was queued, so it fired at once, on results
  from earlier rounds. A live device removed that way also had its keys
  deleted. It then re-added itself to the list, still without keys, and got
  removed again, over and over.
- *Fix:* the callback is registered after the attempts, and only removes
  devices still in the list. A device that finds itself missing republishes
  its keys before re-adding itself.

**Removing a device could fight it forever** (`checkAndPublishDevicesListIfNeeded`,
`removeDevices`, `publishDeviceList`)
- *Symptom:* after the user removed one of their devices that was still in
  use, the log filled with "Removing own devices: they have no bundles" and
  the device list was rewritten again and again.
- *Cause:* the device came back into the list at once, as it should, but
  without a bundle (another client, or an older build, doesn't republish
  it). Every round of sessions then found it bundle-less and removed it
  again, deleting its bundle node too, which raced with any republish. The
  list notification each publish caused started the next round.
- *Fix:* our own bundle-less devices are only taken out of the list; no
  bundle is deleted, as there is none. A device taken out, by us or by the
  user, isn't taken out again for 24 hours (`ownDeviceDropBackoff`): it came
  back, so it is alive, and its bundle is its own business. Its bundle is
  looked for again with the next sends instead. The user's removal still
  deletes the bundle, which is clean-up for devices that are gone; one that
  is not comes back and republishes it, and our own client always fetches
  its bundle afresh before it lists itself again. The automatic removal
  stays because a dead device without a bundle otherwise stays in the list
  for good, and contacts keep trying to build sessions with it. Automatic
  publishes of the list are also at least `listPublishInterval` (10 s)
  apart; one held back is made when the time is up, and so is a removal of
  bundle-less devices that the interval held back (it would not be found
  again otherwise), after fetching their bundles once more: one that
  published its bundle during the wait stays in the list. The stray `print` of the
  published list is gone.

**Every encrypted message waited for a round trip to the server**
(`addresses(for:)`, `devices(for:)`)
- *Symptom:* on a network with any delay, an encrypted message took twice as
  long to show as sent as a plain one, and a burst of them took one extra
  round trip each. A stall on the way, as Wi-Fi sometimes has, cost seconds.
- *Cause:* a contact's device list was only remembered when the server sent
  a notification for it. For anyone whose notification hadn't arrived, the
  list was fetched again for every message, and what the fetch found was
  thrown away.
- *Fix:* a fetched list is kept for a minute (`fetchedListLifetime`), so a
  conversation pays the round trip once. Lists that came by notification
  stay current as before, and replace a fetched one.

**Sends waited for the main thread** (`addresses(for:)`)
- *Symptom:* a message could sit unsent while the interface was busy.
- *Cause:* the lookup reported back on the main queue, and the send waits
  for that report.
- *Fix:* it reports on a background queue.

**Session repair wasn't held back during an archive sync**
(`mamSyncStarted`, `postponeHealing`, `reset`)
- *Symptom:* after the app was away for a while, a device whose session had
  broken could leave later messages undecryptable. Its peer got a burst of
  key-transport messages and used up as many of its prekeys.
- *Cause:* every archived message from a device we couldn't decrypt started
  a repair: a bundle fetch, a new session, and a message to the peer.
  `mamSyncStarted` was meant to hold these back until the sync was through,
  but only made room for postponed prekey cleanup, never for repairs, so
  `postponeHealing` always said no. Several repairs of one device replaced
  its session one after another and could leave the two sides on different
  ones. A sync that a disconnect cut short also stayed marked as running.
- *Fix:* a sync makes room for repairs too, which run once per device when
  it finishes. A reset of the stream or session forgets syncs in progress
  and what they held back, as nothing will finish them.

**A broken session was repaired once per message the server had stored**
(`decode`, `processPostponed`, `claimHealing`)
- *Symptom:* after the app was away, a contact's broken session was
  repaired once for every message the server had kept for us, and each
  repair used up one of their prekeys.
- *Cause:* the hold-back during an archive sync only covers messages that
  arrive while a sync runs. A server's stored messages (offline messages)
  are delivered live as soon as we are online, before the sync starts, so
  each failure started its own repair, and the archive's copies started one
  more.
- *Fix:* a device is repaired at most once in 10 minutes
  (`healingInterval`), whichever way the failing messages arrive. It is
  forgotten when a message from the device decrypts, but not while its
  repair is still under way (a second one would replace the session being
  built), and on a reset of the stream or session. The claims have their own
  lock, so a decrypt never waits for `devicesQueue`. A repair that fails (no usable bundle, no session, no
  message to send) gives its claim back at once, so the device isn't shut
  out for the 10 minutes.

**Removing our own devices couldn't say whether it worked**
(`removeDevices`, `publishDeviceIdIfNeeded`, `publishDeviceList`)
- *Symptom:* a "Remove" button for our old devices had no way to show
  progress or an error: the removal could be refused or the list unreadable,
  and the caller never found out.
- *Cause:* `removeDevices(withIds:)` was fire and forget, built for the
  library's own cleanup of devices without keys. It also deleted the bundle
  of any id it was given, our own included.
- *Fix:* an optional completion handler, passed down to the publish and
  called with its result, including a refused publish, a list that can't be
  read and an unavailable PEP. This device's id is dropped from the ids to
  remove, so its bundle stays; the list always names it, as before.

**Our own devices were always encrypted to, quiet or not**
(`encode(message:forAddresses:forSelf:)`)
- *Symptom:* an old phone of ours, long unused, went on getting every
  message's key, so its sessions and the message size kept growing.
- *Cause:* the encoder added all our devices with a trusted session itself,
  with no way for the app to leave some out.
- *Fix:* a `forSelf` parameter, true as before. Yapnest passes false and
  names our devices itself, leaving out the ones that went quiet.

**A passing fetch error read as "no OMEMO"** (`deviceListError`, `bundleError`)
- *Symptom:* a contact's server that answered the device list request with
  `remote-server-timeout` or another `wait` error, or a bundle request that
  timed out, ended a send with "Turn off encryption to send without it".
- *Cause:* the module kept only the error's condition for a failed list, and
  nothing for a failed bundle, so the `type` that says whether the error
  passes was gone.
- *Fix:* `deviceListError(for:)` returns the whole `PubSubError`, and
  `bundleError(for:)` is the same for a bundle. `forgetFetchFailures(for:)`
  lets a retry ask again at once, as a device whose bundle failed is
  otherwise skipped for a minute. Pinned by `OMEMOFetchErrorTests` and
  `EncryptedSendRetryTests`.

**Publish options had no `FORM_TYPE`** (`openPublishOptions`)
- *Symptom:* the form of the options that publish our device list and
  bundle held only `pubsub#access_model`.
- *Fix:* it names `http://jabber.org/protocol/pubsub#publish-options`, as
  XEP-0060 §7.1.5 asks. Pinned by `OMEMOPublishOptionsTests`.

**The extensions published our keys too** (`publishesKeys`)
- *Symptom:* the notification and share extensions registered the device on
  every run, reading our bundle and device list and sometimes publishing,
  within the 20 seconds they have; a publish they cut off left prekeys stored
  and not on the server.
- *Fix:* `publishesKeys` is on by default and switched off by the extensions'
  sessions. Off, the module publishes neither the bundle nor the device list
  and drops no device of ours, and registers nothing; it still reads lists and
  bundles to encrypt. The one exception is the bundle after a prekey message:
  the used prekey is already gone from the store and from what the app would
  republish for, so the bundle is republished there and then
  (`publishDeviceBundleIfNeeded(afterPreKeyUse:)`). Pinned by
  `ExtensionOMEMOPublishTests`.

**A used prekey stayed usable and published until a flush that might not come**
(`reset`, `registerDevice`, `signedPreKeyRotationDue`)
- *Symptom:* a one-time prekey used during a catch-up, or in an extension
  that ended before it, could be used again, and after a reset of the
  session it stayed in our published bundle for good. The signed prekey was
  never replaced.
- *Cause:* the store only marks a prekey deleted, and the module removes it
  and republishes after a prekey message, or when the catch-up ends if the
  session was held back. A reset forgets what was held back, and an
  extension that dies never gets there.
- *Fix:* the store treats a prekey marked deleted as gone (several messages
  built from one prekey still decrypt, as libsignal sets the session up from
  the first and recognizes the rest by their base key). A reset of the stream
  or session flushes and republishes if sessions were held back, and
  registering flushes what is left marked, so the bundle is rebuilt without
  it. `signedPreKeyRotationDue` is a hook asked whenever the bundle is
  checked; true makes a new signed prekey with the next id. Yapnest's store
  rotates it weekly and keeps the replaced one for four weeks. Pinned by
  `OMEMOPreKeyTests`.

**The Signal wrappers leaked libsignal objects and cached keys unsafely**
(`SignalPreKey`, `SignalSignedPreKey`, `generatePreKeys`,
`SignalIdentityKeyPair`, `SignalIdentityKey`, `SignalContext`)
- *Symptom:* memory grew with every load of a prekey, signed prekey or
  identity pair (publishing loads up to 100 prekeys per run), and reading an
  identity key from libsignal's callback while the app read it too could
  race.
- *Cause:* the wrappers added a reference to objects libsignal had already
  handed them with one, so each load leaked. Identity pairs never released
  the `ratchet_identity_key_pair` they were built from, `generatePreKeys`
  never freed its list, and the context was never destroyed. The public,
  private and pair caches were filled lazily with no lock. A typo set the
  identity store's callback data where the sender key store's was meant.
- *Fix:* the wrappers take over the reference they are given
  (`generatePreKeys` refs each key, as the list frees its own, then frees
  the list). An identity pair owns exactly one `ratchet_identity_key_pair`,
  released in `deinit`, and its key data is computed at init, so reads need
  no lock. The context is destroyed in `deinit`, and the sender key store
  gets its own callback data. Pinned by `OMEMOSignalMemoryTests`, which
  reads libsignal's reference counts.

## How the bugs were found and how the fixes are checked

They surfaced in YapnestKit's integration tests, which run real sessions
against local Prosody and ejabberd servers (`dev/prosody`, `dev/ejabberd`):

```sh
dev/prosody/setup.sh     # or dev/ejabberd/setup.sh; stop the other one first
cd Packages/YapnestKit && YAPNEST_INTEGRATION=1 swift test --filter LiveServer
```

Before the fixes, a run on a freshly reset server failed about one time in
three or four, and encryption didn't work on ejabberd at all. With them, 8
fresh runs on Prosody and 6 on ejabberd all passed. Run the tests on both
servers after touching anything here.

## Working with these copies

- **Where things point:** `Packages/YapnestKit/Package.swift` depends on
  `../../Vendor/Martin` and `../../Vendor/MartinOMEMO`. MartinOMEMO in turn
  depends on `../Martin` instead of GitHub, so both resolve to the same
  copy.
- **Seeing our changes:** compare a folder with upstream at the commit in
  the table at the top.
- **Taking an upstream update:** copy the new upstream tree over the old one
  in a commit of its own, update the table at the top, then reapply the
  fixes above and run the integration tests on both servers.
- **Sending fixes upstream:** the Martin changes are small and
  self-contained, and good candidates. The MartinOMEMO ones could go too,
  but with no upstream activity since 2023 we don't count on it.

## Emoji shortcodes

The composer's `:shortcode:` suggestions use the emoji names from GitHub's
[gemoji](https://github.com/github/gemoji) (MIT), trimmed to the emoji, aliases
and keywords, and to Unicode 15.0, which iOS 17 can draw. The data and its
licence are in `Packages/YapnestKit/Sources/YapnestKit/Resources/Emoji`.

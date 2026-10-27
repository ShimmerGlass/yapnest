# Contributing to Yapnest

How to build Yapnest, run it against local servers, and test it. `CLAUDE.md`
is a more detailed map of where things live, and the conventions the code
follows.

## Before sending a change

- Read the tests that cover what you're changing, in
  `Packages/YapnestKit/Tests`, `App/Tests` and `App/UITests`. Their names and
  comments record the behaviour to keep.
- Every bug fix comes with a test that fails without it.
- Adding, extending or dropping support for an XEP updates the "Supported
  XEPs" table in `README.md` in the same change, and "Server compatibility"
  when it depends on a server feature or a run finds a new gap.
- Check both platforms build:
  ```sh
  xcodebuild -scheme Yapnest -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
  xcodebuild -scheme Yapnest -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO
  ```

## Layout

- `Packages/YapnestKit`: all non-UI code (storage, XMPP, OMEMO). It builds and tests on macOS with `swift test`.
- `App/`: the app, for iOS and for the Mac through Mac Catalyst. SwiftUI everywhere except the conversation's composer, which is UIKit. It embeds two extensions: one shows push notifications, the other is the share sheet.
- `Config/Base.xcconfig`: shared build settings. Put your `DEVELOPMENT_TEAM` (and optionally `BUNDLE_ID_PREFIX`) in `Config/Local.xcconfig`, which is not committed and survives `xcodegen`.

## Building

```sh
brew install xcodegen
xcodegen generate
open Yapnest.xcodeproj
```

The Xcode project is generated and not committed. Re-run `xcodegen generate` after adding files.

For the Mac, pick the "My Mac (Mac Catalyst)" destination. It needs the same signing as iOS, with the Mac enabled for both App IDs: the app shares its bundle ids with the iOS one, so pushes go through the same APNs topic. Without signing it starts, but can't reach the app group where accounts live. On the Mac the app stays connected while another app is in front and posts notifications itself, rather than handing over to pushes as iOS makes it.

The app group and keychain access group are shared with both extensions, so each extension's App ID (`<prefix>.notifications`, `<prefix>.share`) needs the same two capabilities as the app's. Share sheet suggestions (the chats shown at the top) only appear on a signed build installed on a device.

## Development servers

The Server compatibility table in `README.md` is what the `LiveServer` tests show against each of these servers.


`dev/prosody/setup.sh` starts a local Prosody in Docker, with community modules for SASL2, Bind 2, FAST, spam reports and moderated retraction installed from modules.prosody.im, and the accounts `alice@localhost`, `bob@localhost` and `carol@localhost` (password `password`), plus `pwchange@localhost`, which only the password change test uses and restores, group chats on `conference.localhost`, and HTTP uploads on port 5280. Integration tests run against it:

```sh
cd Packages/YapnestKit && YAPNEST_INTEGRATION=1 swift test --filter LiveServer
```

`YAPNEST_SLOW=1` adds the tests that wait minutes, such as the one that checks Martin's keepalive drops a silent connection (about five and a half minutes); without it they are skipped, with the reason in the test output.

Every `setup.sh` starts from a wiped server: it removes the server's data (accounts, archives, published OMEMO devices) and the tests' device databases for it, then creates the accounts again. Runs leave all of that behind, and a run stopped halfway can leave an account changed, so run `setup.sh` again for a clean server. Don't leave the app signed in to the dev server while the tests run: its OMEMO device takes part in theirs.

The Prosody also serves `push.localhost` for the push relay ([yapnest-relay](https://github.com/ShimmerGlass/yapnest-relay), checked out next to this repository). `dev/relay.sh` runs it with a throwaway key: debug builds signed in to `localhost` register with it, and the server publishes to it, but Apple refuses the pushes. With the real key (`APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`), pushes reach the simulator. `YAPNEST_RELAY=1` adds the test that enables push through it. Release builds use `push.yapnest.fr`.

Every dev server also offers STARTTLS, with a certificate from a local CA that `dev/certs/make.sh` makes (the setup scripts call it; the files are git-ignored, and it renews them in their last month). TLS stays optional, because most suites connect with `disableTLS: true` and the resilience proxy reads plaintext stanzas. The suites for SASL2, Bind 2 and FAST (`FastSignInIntegrationTests`) and for signing in over TLS (`TLSIntegrationTests`) connect with TLS instead, trusting `dev/certs/ca.pem` (`YAPNEST_DEV_CA` names another file) in place of the system's roots, with the host name and expiry still checked. ejabberd offers SASL2 only on an encrypted stream, which is why they run this way. A server that doesn't offer SASL2 even then (Openfire 5.1) cancels the SASL2 tests, with the reason in the test output. A server already running needs a restart to pick up the certificate (`docker compose restart`, or `setup.sh`). `YAPNEST_PUBLIC_SERVER=<domain> swift test --filter PublicServerTLS` connects to a public server by its domain alone, to check SRV lookup and the system's trust over real TLS; it signs in to nothing.

`dev/ejabberd/` is the same setup on ejabberd, on ports of its own (15222 and 15280), so it runs beside Prosody. It also offers STUN and TURN for calls on UDP 3478, relaying from UDP 49152–49171, and hands out TURN credentials through External Service Discovery (XEP-0215). `setup.sh` advertises them on the Mac's network address (in `dev/ejabberd/.env`; `TURN_HOST` overrides it), since WebRTC on the Mac can't reach a relay on 127.0.0.1, and that address also reaches the Android emulator and phones. TURN takes only the credentials XEP-0215 hands out, not the account's password, as the accounts are stored as SCRAM.

Each server has ports of its own, so all four can run together:

| Server | `YAPNEST_SERVER` | Client port | HTTP uploads |
| --- | --- | --- | --- |
| Prosody (`dev/prosody/`) | `prosody` (the default) | 5222 | 5280 |
| ejabberd (`dev/ejabberd/`) | `ejabberd` | 15222 | 15280 |
| Snikket (`dev/snikket/`) | `snikket` | 25222 | 25280 |
| Openfire (`dev/openfire/`) | `openfire`, `openfire-bare` | 35222 | 35280 |

`YAPNEST_SERVER=<name>` makes the `LiveServer` tests run against that one, with the same accounts (`alice`, `bob` and `carol` @localhost, and `pwchange` for the password change test). `YAPNEST_SERVER_PORT` and `YAPNEST_SERVER_HTTP_PORT` override its ports, for a server started on others. A test that needs something the server doesn't advertise (stanza-ids, XEP-0402 bookmarks, HTTP File Upload) is skipped, with the reason in the test output.

`dev/snikket/` runs the official `snikket/snikket-server` image, which is Prosody with Snikket's own configuration: invite-only accounts, `groups.localhost` for group chats, built-in file sharing and push. It expects a real domain and a Let's Encrypt certificate, so it gets the dev CA's certificate from `dev/certs`. It keeps Snikket's default TLS profile, which is TLS 1.3 only, so it is the server that shows a client can't get by on TLS 1.2. `dev.cfg.lua` (included last through `SNIKKET_TWEAK_EXTRA_CONFIG`) relaxes what the tests can't meet: TLS isn't required (it is offered), PLAIN is allowed, a one-letter password passes the policy (the test accounts are made with `prosodyctl register`, as invitations need the web portal), uploads are served on `localhost:25280` instead of behind Snikket's web proxy, and the 10 kB/s limit on each client is lifted, which slows encrypted messages to about 850 ms each and fails the send latency test.

`dev/openfire/` runs Openfire from `ghcr.io/igniterealtime/openfire`, an amd64 image that Docker emulates on Apple silicon, so it is slower than the others. The image would start Openfire's setup wizard; instead `openfire.xml` has an `autosetup` block (embedded database, domain `localhost`, the three accounts, admin console on `localhost:35090` with `admin`/`admin`). The Monitoring (message archive, XEP-0313), Push Notification (XEP-0357) and HTTP File Upload (XEP-0363) plugins are downloaded from igniterealtime.org by `setup.sh`. `OPENFIRE_BARE=1 dev/openfire/setup.sh` leaves out the push and upload plugins, for seeing how Yapnest copes with a server that lacks them (`YAPNEST_SERVER=openfire-bare`); it uses the same ports, so stop the other variant first (`docker compose down` in `dev/openfire/`, with `COMPOSE_PROJECT_NAME=openfire-bare` for the bare one). `setup.sh` also swaps the dev CA's certificate into Openfire's keystore and restarts it. MAM, carbons, stream management, PEP, blocking and MUC are on by default.

`dev/compliance/run.sh <server>` runs the [XMPP Compliance Tester](https://codeberg.org/iNPUTmice/caas) (the tool behind compliance.conversations.im) against a running dev server and saves the report as `dev/compliance/<server>.txt`. It needs git, a JDK and Maven. `caas-local.patch` lets it connect to a host and port without TLS, which the dev servers need.

## UI tests

`YapnestUITests` drives the app in the simulator through the conversation screen: opening a chat from the list, closing the keyboard, scrolling up until older messages load. It needs no server. Debug builds launched with `YAPNEST_DEV_FIXTURE=<name>` sign in to an offline account filled from scratch with one of these:

- `tall-newest`: a chat, Mail, whose newest message is an email more than two screens tall, with long unbroken links.
- `long-history`: a chat, History, with more messages than the first window holds, of mixed heights.
- `tall-history`: a chat, Archive, of 300 mostly email-sized messages of varied lengths, both ways, with a tall one newest.
- `learned-reactions`: a short chat, Reactions, on an account whose quick reactions have been learned, to see the long-press menu's row.
- `quick-responses`: a chat, Bot, whose newest message offers suggested replies and actions (XEP-0439), and one before it with an action only.
- `previews`: a chat, previews@fixture.test, of photos not downloaded yet, announced with their sizes and a tiny preview. `YAPNEST_DEV_HOLD_DOWNLOADS=1` keeps the downloads waiting until the test taps a hidden "Release downloads" button beside the frame recorder, to check that no row changes size when they do.
- `late-content`: a chat, late@fixture.test, whose newest messages grow once they load: photos from an encrypted chat, which say nothing of their shape until downloaded, and links whose preview cards come late. With `YAPNEST_DEV_HOLD_DOWNLOADS=1` they wait for the same "Release downloads" button, to check that the list doesn't move when rows below what's on screen grow.

The conversation's frame recorder (`ScrollRecorder.swift`) keeps what the list did on every frame: how far it strayed from the bottom while it was to stay there, how far the topmost message moved when older ones came in, how many rows were on screen. A glitch that lasts a frame is caught even though the test looks at the screen only now and then. The tests read it from an invisible element in the list's margin.

```sh
task ui   # iPhone 17, then the iOS 26 simulator
```

`task ui -- -only-testing:YapnestUITests/MessageActionsUITests` runs some of them. Each parallel worker boots a simulator clone of up to 2.5 GB, so the Taskfile caps them at 6 (`WORKERS`); pass `-parallel-testing-worker-count 6` to any `xcodebuild test` you run by hand. `task check` runs YapnestKit's tests, both builds, the unit tests and the UI tests.

The scheme runs test classes in parallel, on clones of the simulator; add `-parallel-testing-worker-count 4` to cap them (15 to 25 minutes depending on what else the Mac is doing, against 52 in one; more workers on a 12-core Mac made tests fail from load). The long fuzz and scroll checks are split over classes so that none runs for much longer than the rest; `-parallel-testing-enabled NO` runs them one by one.

The keyboard tests need the simulator's software keyboard: turn off I/O > Keyboard > Connect Hardware Keyboard in Simulator, or run on a simulator Simulator.app isn't showing. `-only-testing:YapnestUITests/ConversationScrollingUITests/<test>` runs one.

### Fuzz

`YAPNEST_DEV_FIXTURE=fuzz:<seed>` fills two chats from a seed (`FuzzFixture.swift`): Fuzz, a 1:1 chat, and Fuzz Group. They mix everything the list draws: photos and videos of every shape, GIFs, files and contacts, link cards and previews waiting to be allowed, locations, reactions (some still sending), replies, quotes and styling, emoji, tall emails with long links, edits, deletions, undecryptable and failed messages, in runs of one sender and across days. Pictures, videos and previews are written as if downloaded, so nothing is fetched. The same seed always gives the same chats; one seed in six is past the first window, so older messages load.

`FuzzScrollingUITests` runs the list's checks on five fixed seeds: opening at the bottom, the keyboard closing, flicking to the top and back to the newest message, never a blank list. A failure names its seed. More seeds:

```sh
TEST_RUNNER_YAPNEST_FUZZ_SEEDS=31,32,33 xcodebuild test -scheme YapnestUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-worker-count 6 \
  -only-testing:YapnestUITests/FuzzScrollingUITests/testSeedsFromTheEnvironment
```

To look at a seed yourself, `dev/fuzz.sh <seed> [group]` builds Debug for the booted simulator and opens that seed's chat.

`dev/call-e2e.sh [--audio]` builds Debug and has alice call bob between two simulators (`SIM_A`, `SIM_B`; `iPhone 17` and `Yapnest iOS 26` by default) against the running dev server, then checks each one's log that the call became active and ended, and for video that a remote picture arrived. It keeps screenshots of both screens mid-call.

Other launch variables for driving the simulator from scripts, in Debug builds: `YAPNEST_DEV_ACCOUNT` and `YAPNEST_DEV_PASSWORD` sign in to a dev server account (`YAPNEST_DEV_HOST` if it isn't on this Mac), `YAPNEST_DEV_OPEN=<address>` opens that chat at launch, `YAPNEST_DEV_RECORD=1` turns the frame recorder on outside a fixture, and `YAPNEST_DEV_INCOMING=<seconds>[,<seconds>...]` makes a message from the `YAPNEST_DEV_OPEN` chat arrive after each delay (on a fixture only), for watching the glow that plays when one comes in.

## Licences

Settings > Open source licences shows Yapnest's licence and every library's, from the folder `App/Licences`. After adding or updating a dependency, or changing `Vendor/`, regenerate it with `dev/licences.py` (it reads the package checkouts: `xcodebuild -resolvePackageDependencies -scheme Yapnest -derivedDataPath /tmp/yapnest-dd`, then `dev/licences.py /tmp/yapnest-dd/SourcePackages/checkouts`). `LicencesTests` fails when a package in a `Package.resolved` or a folder in `Vendor/` is missing from it.

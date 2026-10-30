# Yapnest

An XMPP client for iOS 18+ and the Mac (Mac Catalyst, Mac idiom). `README.md` covers features and server support for users; `CONTRIBUTING.md` building, the dev servers and the tests. This file maps where things live.

## Layout

- `Taskfile.yml`: the checks, through [Task](https://taskfile.dev): `task kit`, `build`, `unit`, `ui`, and `check` for all of them. `task testflight` archives and uploads the iOS and Mac apps (`dev/testflight.sh`) and sets each build's "What to Test" from its changelog (`dev/testflight-notes.swift`), then adds both builds to the "friends" external test group and sends them to Beta App Review (`dev/testflight-group.swift`), with the App Store Connect API key in the git-ignored `keys/`. UI tests run on at most 6 simulator clones (`WORKERS`), as each takes up to 2.5 GB; keep that cap in any `xcodebuild test` run.
- `project.yml`: the xcodegen spec. `Yapnest.xcodeproj` is generated and ignored by git, so put project and scheme settings here, never in Xcode. Run `xcodegen generate` after adding or removing files.
- `Config/Base.xcconfig`: shared build settings. `Config/Local.xcconfig` holds the signing team, and isn't committed.
- `Packages/YapnestKit`: everything that isn't UI. It builds and tests on macOS with `swift test`.
- `Vendor/Martin`, `Vendor/MartinOMEMO`: our forks of Tigase's XMPP and OMEMO libraries. `Vendor/README.md` says why and what changed.
- `App/Sources/Yapnest`: the app. It's SwiftUI, except the conversation's composer, which is UIKit.
- `App/NotificationService`: the push extension. It fetches and decrypts what a push announces, through `NotificationFetcher`.
- `App/ShareExtension`: the share sheet extension. SwiftUI, hosted by `ShareViewController`. It sends what's shared to a chosen chat through `ShareSender`, without opening the app.
- `App/Shared`: source both the app and the share extension compile, such as `AvatarView`.
- `App/Sounds`: the CC0 notification sounds a chat can choose (`NotificationSound` in YapnestKit holds the list and the decision). They sit in the app's main bundle, where a notification's sound is looked up; `README.md` there says where each came from.
- `App/Tests`: unit tests hosted in the app. `App/UITests`: UI tests on the debug fixtures (`App/Sources/Yapnest/DevFixture.swift`), in their own scheme.
- `dev/`: local Prosody, ejabberd, Snikket and Openfire servers in Docker (Snikket on ports 25222/25280, Openfire on 35222/35280, ejabberd on 15222/15280, Prosody on 5222/5280), `certs/make.sh` for their TLS certificate (a local CA's, offered on STARTTLS beside plaintext: the SASL2 and TLS live tests trust it, the rest don't use TLS), `compliance/` for running the XMPP Compliance Tester against them, the push relay script, and `call-e2e.sh`, which runs a video or audio call between two simulators against the dev server and checks their logs. `dev/licences.py` regenerates `App/Licences` (the licence texts and `manifest.json` behind Settings > Open source licences) from the package checkouts and `Vendor/`; run it after changing a dependency. `LicencesTests` fails if a package is missing from it.
- `changelogs/`: what changed in each build, one file per build named `<version>-<build>.md` after `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`, written for the people testing it (TestFlight's "What to Test"). Changes are added to the newest file as they land. A file is frozen once its build is uploaded: on release, the uploaded commit is tagged `<version>-<build>` (`git tag -a 1.0-7`), `CURRENT_PROJECT_VERSION` is raised, and the next build's file is created, so later changes never go into a build that has shipped.
- `design/screenshots/`: the App Store screenshots, taken by `dev/screenshots.sh` on the `screenshots` fixture (`ScreenshotsFixture.swift`) in the 6.9″ simulator, with 6.3″ copies in `6.3/` for the medium display slot.
- `design/app-icon/`: the app icon. `make_icon.py` lays twigs from a fixed seed around the bird in `base.svg`, and writes `AppIcon.svg` and the asset catalog's PNG.
- The website at yapnest.fr (home, privacy policy, terms, support) lives in its own repo, `yapnest-website` (`github.com/ShimmerGlass/yapnest-website`), with its own CI and nginx image. The app opens `/privacy`, `/terms` and `/support` from it, so those paths must keep working.

## YapnestKit

- `XMPP/XMPPSession.swift`: one account's connection. It keeps the database in sync with the server and is the API the app calls: send, react, retry, trust, devices and so on. Its extensions each cover one area:
  - `+Groups`: group chats, with `RoomStatus` and `GroupChat`.
  - `+Moderation`: removing, banning and promoting members, and a moderator's retraction of messages; `GroupModeration` holds who may act on whom.
  - `+Contacts`: the roster and contact requests.
  - `+Blocking`: blocking and spam reports.
  - `+Attachments`: file uploads.
  - `+DisplayedSync`: read state synced across devices.
  - `+Settings`: Yapnest's own settings synced through a private PEP node (`SettingsSyncModule`). Before anything is published the node is checked to be whitelist, and syncing stops for the session if the server keeps it open; it is never deleted. A fetch that isn't complete never deletes local items.
  - `+Push`: push notifications through the relay.
  - `+History`: older messages from the archive when scrolling back. `+Restore` uses it after a sync that began without a cursor (a reinstall) to bring back the chats older than the sync window.
  - `+AdHoc`: ad-hoc commands (XEP-0050): finding and running a server's, a contact's device's or a group's, a stage at a time. What they ask is an `XDataForm` (`XDataForm.swift`, XEP-0004).
  - `+Password`: changing the account's password (XEP-0077). `AppModel.changePassword` checks the current one against the keychain, then stores the new one and drops every client's FAST token.
- `Sharing/ShareSender.swift`: the share extension's counterpart to `NotificationFetcher`. It writes what's shared as pending messages, then sends them in a `.share` session under the lock. If the app holds the lock it signals through `PendingSendsSignal`, and `XMPPSession.resendPending()` sends them. `ShareContent` turns shared items into messages, and `ShareSuggestions` donates the intents behind the share sheet's suggested chats.
- `XMPP/XMPPURI.swift`: an `xmpp:` link (XEP-0147, with the XEP-0379 `preauth` token) parsed and checked. `LinkConfirmation.swift` in the app asks the user before a link adds a contact or joins a group; `AppModel.pendingLink` holds one until the chat list can act on it.
- `XMPP/InboundMessage.swift`: what an incoming stanza means, independent of Martin. `OutboundStanza.swift` builds outgoing ones.
- `XMPP/FileMetadata.swift`: what a message says about a file before it's downloaded (XEP-0446 size, width and height, XEP-0264 thumbnail), checked on the way in and built on the way out. It sits outside the OMEMO payload, so it is only ever sent in unencrypted chats; `OutboundStanza.addFile` is where that's decided. `InboundMessage` drops it, and the ids that name an announcement, from an encrypted message, since a server could have written it. Dino sends it in a message of its own, which ingest keeps in `fileAnnouncement` until the message with the link arrives.
- `Storage/AppDatabase*.swift`: the GRDB database, one per account, with its schema and migrations in `AppDatabase.swift`. It's split by area:
  - `+Ingest`: applying inbound stanzas.
  - `+Messages`, `+Conversations`, `+Groups`, `+Notifications`, `+Session`, `+Settings`.
  - `+SyncedSettings`: the synced settings' entries, versions (a hybrid logical clock) and merging; `touch` records a local change in the setter's transaction.
  - `+GroupInvitations`: invitations through a room that can't vouch for the inviter, held until the user answers.
  - `+PendingEdits`: a retraction or correction that names a message not stored yet (archive pages arrive newest first), kept and applied when that message arrives if its author fits. A correction shows meanwhile as a stand-in message, removed once applied.

  `ChatListItem` and `ConversationItem` are the read models the UI observes.
- `Storage/SharedContainer.swift`, `Keychain.swift`, `FastTokenStore.swift`: what the app and the extension share, and the account's credentials.
- `OMEMO/`: encryption over MartinOMEMO.
  - `OMEMOStore`: keys, sessions and identities.
  - `OMEMODevice`: a device and how far it's trusted.
- `Model/`: the GRDB records: `Message`, `Conversation`, `Contact`, `GroupChat`, `Reaction`, and `JID`, which is always bare and normalized.
- `Attachments/`, `LinkPreviews/`: file encryption and storage; link detection and OpenGraph previews.
- `Attachments/LongText.swift`: text past 8,000 characters, pasted, dropped or shared, goes out as a .txt file rather than a message.
- `Attachments/AudioFormat.swift` says which files are sound and which the player can play (not Ogg or Opus, which show as files); `AudioWaveform.swift` works out the bars drawn in a voice message's bubble and keeps them beside the file. `Rules/VoiceRecordingRules.swift` holds what decides how a recording ends.
- `Diagnostics/`: the exportable log, written by the app and both extensions. `DiagLog` takes a static message and typed `DiagField`s only (no free-form strings: identifiers go through `Redacted.id`, a keyed hash whose key never leaves the install; errors are logged as domain and code, never their description). `DiagnosticsStore` keeps each process's two rotating files in `SharedContainer.url/Logs`, `DiagnosticsExport` merges them under a header, and `DiagLog.network` logs what an `NWPath` allows. The session's connect, send and upload paths log through it (events are enums in `DiagEvents.swift`); Martin's connector reports its endpoint steps through `SocketConnectorNetwork.Options.diagnostics`. Lines are stamped to the second, and sizes (`DiagField.size`) and ports (`PortKind`) are coarsened, so a line can't be matched to a message. New `os.Logger` calls must not interpolate addresses, names or error text as `.public`.
- `Gifs/`: `GifService`, the KLIPY client behind the GIF picker, and the setting that turns it off.
- Tests are in `Tests/YapnestKitTests`. The `LiveServer` tests need `YAPNEST_INTEGRATION=1` and the dev server running; `YAPNEST_SERVER` (`prosody`, `ejabberd`, `snikket`, `openfire`, `openfire-bare`) picks which, and `LiveServer.target` in `SessionFixtures.swift` holds its ports.

## App

- `YapnestApp.swift`: the app delegate (push token, notification taps) and the Mac menu commands.
- `AppModel.swift`: owns the signed-in session and exposes its state to the UI: presences, typing, rooms, unread counts. On the Mac it also posts notifications itself.
- `ChatListView.swift`: the chat list, and the open chat beside it on wide screens.
- `ContactRequests.swift`: contact requests, and `AddContactButton`.
- `GroupInvitations.swift`: pending group invitations on the chat list, with the warning shown before joining.
- `GroupViews.swift`: creating, joining and inviting to groups. `Conversation/MemberModeration.swift` adds the members list's remove, ban and admin actions.
- `DevicesView.swift`: OMEMO devices and how far each is trusted.
- `LicencesView.swift`: Open source licences, in Settings, read from the bundled `Licences` folder.
- `Commands/`: ad-hoc commands. `CommandsListView` lists what an entity offers (from Profile, and chat settings), `CommandRunView` runs one over `AdHocRun`, and `XDataFormView` draws a form or a result. Everything the entity sends is shown verbatim, never as markup.
- `BlockConfirmation.swift`, `LoginView.swift`, `NewChatView.swift`, `AvatarView.swift`.
- `Conversation/`:
  - `ConversationView.swift`: the screen. It has the header, banners and blocked or left bars, and puts the message list over the composer.
  - `ConversationModel.swift`: everything the screen does with the messages. It observes the database window, builds the rows, pages older history, jumps to quotes, marks messages read, sends, and keeps the composer's state. It also decides where the list scrolls, and sets that along with the rows so both land in one frame.
  - `MessageRow.swift`: a row's ready-to-draw content, compared by a revision number. `MessageText.swift` turns a body into links, quotes and styled spans once per revision. A body past 14 lines or 700 characters is cut short with Show more (`MessageText.collapse`): the lazy stack guesses the height of undrawn rows from the drawn ones, and rows of thousands of points among rows of a hundred made the list's length run away from a flicking user.
  - `MessageList.swift`: the `ScrollView` and `LazyVStack`. On iOS the list is flipped (`upsideDown(_:)`, `Platform.flipsMessageList`): the newest message is at scroll offset 0, where the scroll view rests, so the lazy stack's changing estimates past the far end, and older pages added there, don't move what's on screen. Each row is turned back. The system's scroll edge effect and the context menu's lifted preview don't work upside down, so the list draws its own `TopEdgeBlur` under the bars and `MessageRowView` gives the menu a preview. The Mac keeps the bottom-anchored list, as flipping would reverse its scroll wheel. It also has the scroll-to-end button and the placeholder.
  - `MessageRowView.swift`: a row, with the day header, unread divider and swipe to reply. `MessageBubble.swift` lays out the bubble, quote and reactions chip; `AttachmentContent.swift` and `LinkPreviewCard.swift` fill it. `MessageMenu.swift` is the context menu.
  - `GifPicker.swift`: the KLIPY sheet behind the composer's GIF button. A chosen GIF is downloaded and staged like any attachment. `AnimatedImageView.swift` plays GIFs, in the picker and in bubbles, only while on screen.
  - `ComposerBar.swift` hosts `ConversationInputBar.swift` (the composer, glass on iOS 26, with the Mac's key handling) under the list, which is stretched down behind it by the composer's measured height so messages scroll under its glass, and keeps that much room past its newest message (flipped, a safe area padding; unflipped, padding on the last row). Not a `safeAreaInset` or a `ZStack`: the list then reaches into the keyboard's safe area and its layout never settles. SwiftUI's own keyboard avoidance lifts both together; there is no custom keyboard layout. `AttachmentPicker.swift` has the pickers and QuickLook; `ConversationPrompts.swift` the alerts. What's picked, pasted or dropped waits in the composer's field until the user sends it: `PendingAttachments.swift` holds it and `AttachmentTray.swift` draws it.
  - `VoiceRecorder.swift`: recording a voice message (hold, tap to lock, slide to cancel) over AVAudioRecorder; `ConversationInputBar` draws it through `VoiceRecordingRow.swift` and sends the result at once as an `.m4a` attachment, with its length in the XEP-0446 metadata in unencrypted chats. `VoiceMessageView.swift` is the player in a bubble, a fixed size in every state, and `VoicePlayback.swift` plays one clip at a time.
  - `ChatSettingsView.swift`: settings for one chat.

## Conventions

- Before changing something, read the tests that cover it: in `Packages/YapnestKit/Tests`, `App/Tests` and `App/UITests` (the scrolling and composer UI tests for anything around the message list). Their names and comments record the behaviour to keep and the gotchas found the hard way, and a fix that breaks one has usually rediscovered an old bug.
- Every bug fix comes with a test that fails without it.
- Comments explain why, in plain sentences. They don't narrate what the code does. Commit messages follow the same style: a short imperative title, then a paragraph on why.
- Adding, extending or dropping support for an XEP updates the "Supported XEPs" table in `README.md` in the same change, and "Server compatibility" when it depends on a server feature.
- Observe the database with GRDB's `values(in:bufferingPolicy: .bufferingNewest(1))`, so a burst of changes redraws once.
- Keep database writes and catch-up work off the main thread. Run repeated requests as a single background run (see `markRead()` and `notifyInBackground`).
- Show progress for every server action: a spinner in the button or toolbar, and an alert if it fails.
- An update made while offline is queued and sent once connected, never dropped or refused: stored so it survives the app being killed, and cleared only once the server confirms it. The exceptions fail with an offline error: an action whose effect could differ if sent later (ad-hoc commands, a password change), one that depends on the server's live answer or our current role so that what follows would fail out of order (joining or creating a group, inviting, moderation), and one that needs the connection itself (calls, file transfers). Typing notifications and receipts only matter in the moment and are dropped.
- Never swallow or hide a server's error: show it to the user, unless a comment says why it's safe not to. Logging it alone counts as hiding it. What can pass by itself is retried without asking: a dropped connection, a timeout, or an error of type `wait`. Only a final error (type `cancel`, `modify` or `auth`) is shown, with a Retry where trying again could help, as the user may have fixed the cause.
- On the Mac, UIKit buttons draw as Mac controls unless given `preferredBehavioralStyle = .pad`. A button drawn that way doesn't open its menu on click, which is why the attach button is set up the way it is.

## Gotchas

- With the debugger attached, launch stalls on every library load, and the first taps lag. The scheme runs Release without the debugger for that reason; this is set in `project.yml`. Profile before chasing lag.
- Flipped (iOS), the list's newest end is the scroll view's resting point, so keyboard and inset changes need nothing from the model. Unflipped (Mac), it stays at the bottom through `defaultScrollAnchor(.bottom, for: .sizeChanges)`, which follows the container and content changing size but not insets, and `reanchorWhenStill()` and `layoutNudge` recover a list the lazy stack left blank. Older messages inserted above an unflipped list are held in place by scrolling to the topmost message in the same update (`keepAnchorInPlace()`); `scrollPosition(id:)` can't be used, as it switches the bottom anchor off. Don't give a list a bottom inset on the Mac (a safe area inset or content margin): the scroll view is then left past its end.
- Check both platforms build:
  ```sh
  xcodebuild -scheme Yapnest -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
  xcodebuild -scheme Yapnest -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO
  ```
  SourceKit's "No such module" errors in the editor are noise.
- Installing on the user's own devices, signed with the team in `Config/Local.xcconfig`. Use a derived data folder outside the repo (`$DD` below). Never sign the Mac app in with a dev server account: it's the user's real install.
  ```sh
  # iPhone (find its id with `xcrun devicectl list devices`)
  xcodebuild -scheme Yapnest -configuration Release -destination "id=$PHONE" -derivedDataPath "$DD/phone" -allowProvisioningUpdates build
  xcrun devicectl device install app --device "$PHONE" "$DD/phone/Build/Products/Release-iphoneos/Yapnest.app"
  # Mac: quit the running copy, replace it in /Applications, reopen it
  xcodebuild -scheme Yapnest -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DD/mac" -allowProvisioningUpdates build
  osascript -e 'quit app "Yapnest"'
  ditto "$DD/mac/Build/Products/Release-maccatalyst/Yapnest.app" /Applications/Yapnest.app && open /Applications/Yapnest.app
  ```
  "Could not resolve package dependencies" on the iPhone build comes from a stale `$DD/phone/SourcePackages`: delete it and build again. Install Release on the devices: a Debug build runs unoptimized and stutters where the shipped app doesn't, so it can't be used to judge smoothness. Debug fixtures (`YAPNEST_DEV_FIXTURE`) exist only in Debug builds, so check fixtures in a Debug simulator build.
- After changing the message list, the keyboard layout or the conversation's scrolling, run the UI tests (CONTRIBUTING.md, "UI tests"): `task ui` runs them on the iPhone 17 and on `Yapnest iOS 26`, six simulator clones at a time. Run both: the scroll view and lazy stack behave differently on iOS 26, which most phones run, and the keyboard jumps reproduce only there (an iPhone 15 Plus on the iOS 26.5 runtime; create it with `xcrun simctl create` if it's missing). They run on offline fixtures (`DevFixture.swift`, `YAPNEST_DEV_FIXTURE`) and read the frame recorder (`ScrollRecorder.swift`), which catches one-frame jumps and blank lists. A new scroll bug gets a fixture and a test there first.
- The UI tests are very slow: the whole suite takes a long time on each simulator. Run them only when a change touches what they cover (the message list, the keyboard, scrolling, or a screen a UI test drives), not after every change. While working, run only the tests for what changed with `task ui -- -only-testing:YapnestUITests/<Class>[/<test>]`, or one `xcodebuild test` with `-only-testing` on a single simulator. Run the full `task ui` once, at the end of the change.
- Memory is tight on the dev Mac. A plain `xcodebuild test` clones the simulator to run test classes in parallel, each clone taking up to 2.5 GB, so a filtered run passes `-parallel-testing-enabled NO` to stay on one simulator; shut simulators down afterwards (`xcrun simctl shutdown all`). Run one heavy job at a time: no `xcodebuild` or `swift build`/`swift test` beside another, and the live suites one server at a time. Agents working in parallel, in worktrees or not, share this limit.
- `FuzzScrollingUITests` runs the same checks on seeded chats of every kind of content (`FuzzFixture.swift`, `YAPNEST_DEV_FIXTURE=fuzz:<seed>`). A failure names its seed; `dev/fuzz.sh <seed> [group]` opens it in the simulator. A seed that caught a bug stays in the fixed list.

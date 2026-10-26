# Yapnest

A modern XMPP chat app for iPhone and the Mac. Chat with anyone on any XMPP
server, with end-to-end encryption, and without an account tied to a big
company or a phone number.

## What it does

- **Encrypted chats.** One-to-one chats and private groups are end-to-end
  encrypted with OMEMO by default. A contact's new devices are trusted
  automatically until you verify one of theirs; after that, you decide on
  each new device.
- **Everything you'd expect from a chat app.** Reactions, replies, edits and
  deleting messages, mentions, photos, videos, files, GIFs, voice messages,
  link previews, locations, and read state that follows you across your
  devices.
- **Groups.** Create private groups, invite people, and manage members,
  admins and the group's settings.
- **Contact requests you control.** Accept or decline requests, block
  people, and report spam where your server supports it.
- **Fast and reliable connections.** Quick sign-in on servers that support
  it, a dropped connection picks up where it left off, and push
  notifications arrive even when the app is closed.
- **Bots and services.** Run your server's or a bot's commands, and tap a
  bot's suggested replies.
- **Make it yours.** A notification sound for each contact, and a share
  sheet that sends photos, videos, files, text and links to a chat without
  opening the app.
- **Audio and video calls.** Call a contact and answer on any of your
  devices, with the sound and picture encrypted (DTLS-SRTP) and your
  server's relays used when there's no direct path. An iPhone or iPad only
  rings while Yapnest is open on screen.

### On the Mac

- The chat list sits beside the open chat.
- The app stays connected while you use other apps, and notifies you itself.
- Return sends, and Command-, Shift- or Option-Return starts a new line.
- ⌘N starts a chat. Right-click a chat for what swiping does on the iPhone,
  and hover over a message for reactions, reply and more.

### What encryption covers

Yapnest uses OMEMO 0.3, the version most XMPP apps speak. It encrypts a
message's text and files and nothing else. Your server still sees who talks
to whom and when, and reactions, deletions, read markers, typing
notifications, who a message mentions, and which message a reply or edit
refers to travel unencrypted. An encrypted file is uploaded under a random name (keeping its
extension), so the upload server doesn't learn what it was called; the
people you send it to see that random name too, as OMEMO 0.3 has nowhere
else to carry the real one. This device's encryption key stays on it: it's
kept out of iCloud and computer backups.

Calls are encrypted separately (DTLS-SRTP), and their key isn't yet checked
against OMEMO, so nothing confirms who is on the other end. The server sees
who calls whom and when.

## Requirements

- iOS 18 or later, or macOS 15 or later.
- An account on an XMPP server. Any standard server works; see
  [Server compatibility](#server-compatibility) for what each one needs for
  every feature.

## Help and feedback

See [yapnest.fr](https://yapnest.fr) or write to
[support@yapnest.fr](mailto:support@yapnest.fr).

## Server compatibility

A feature the server doesn't offer is left out of the app rather than
failing: its option is simply hidden.

| Server | Status | Needs |
|---|---|---|
| Prosody 13 | Everything works. | Community modules for faster sign-in and spam reports (`mod_sasl2`, `mod_sasl2_bind2`, `mod_sasl2_sm`, `mod_sasl2_fast`, `mod_spam_reporting`) and for moderation in groups (`mod_muc_moderation`), installed from modules.prosody.im. `mod_cloud_notify` for push, `mod_lastactivity` for last seen, and `mod_turn_external` (part of Prosody) with a TURN server such as coturn for calls that can't connect directly. Without the sign-in modules, Yapnest signs in without SASL2 and FAST; without the others, it hides what they offer. Invitation links need `mod_invites`. |
| Snikket | Everything Prosody does, and invitation links work out of the box. | Nothing. |
| ejabberd | Works. Password change needs `mod_register`. Call signalling (ringing, answering across devices, TURN credentials from `mod_stun_disco`) is tested on it, and so is managing a group (configuration, subject, bans, owners, kick, picture, destroy) and removing members' messages as a moderator. Jingle file transfers between two accounts are tested on it and on Prosody. | Spam reports aren't tested on it, as the dev server takes none, and nor are invitation links. |
| Openfire | Partial. Chats, groups and file upload work, but see the gaps below. | The Monitoring (archive), Push Notification and HTTP File Upload plugins. |

Yapnest's settings name your contacts, so before publishing them it reads the node's configuration back and only syncs if the server keeps it readable by nobody else (`whitelist`); it sets it right once, and otherwise syncs nothing that session. It never deletes the node.

Openfire's gaps:
- It adds no stanza-id to messages, so read state syncing, spam reports and matching messages against the archive work less well or not at all.
- Its rooms don't advertise message moderation (XEP-0425), so moderators can't remove others' messages there, and spam reports, which need the stanza-id above, don't work either.
- The first block an account ever makes doesn't take effect for its sessions that were already online; it does for any that start later.
- It doesn't mirror XEP-0402 bookmarks to the older PEP bookmarks (no `#compat`), so Yapnest keeps its groups in the older ones (XEP-0048) there instead.
- It never answers, or fails, a publish or node creation that asks for `max_items=max`. Yapnest's settings node is then given a limit of 1000 items and published to without asking for `max`.

## Supported XEPs

What Yapnest implements, and where it stops short.

| Spec | Name | Support |
|---|---|---|
| RFC 6120 | XMPP Core | Full. TLS is required by default, with the certificate checked for the domain. |
| RFC 6121 | Instant Messaging and Presence | Full: roster, presence, subscription requests to accept or decline. |
| XEP-0004 | Data Forms | Used for room configuration, publish options, the push command and password change, and to fill in and read the forms and result tables of ad-hoc commands (every field type, with required fields and JIDs checked before sending). The media element (XEP-0221) isn't shown, so a form never loads anything from the entity that sent it. |
| XEP-0012 | Last Activity | Opt-in as Activity Status, off by default (Settings > Privacy), which also shows the user away while the iOS app is suspended, or the Mac has been idle for 10 minutes or is locked. On the Mac, the idle time answered is the Mac's own. When on, answers contacts with a presence subscription, and asks offline contacts' servers for when they were last online. |
| XEP-0030 | Service Discovery | Full. |
| XEP-0045 | Multi-User Chat | Partial: join, create private groups, invite members, leave, member list. Owners edit the room's configuration (name, description, members only, who sees addresses, who may invite and change the subject), make and unmake admins and owners, and destroy the room. Owners and admins remove, ban and unban members. Moderators kick occupants ranked below them, and change the subject, as participants may too where the room allows it. Declining a mediated invitation is sent to a contact who invited us, never to anyone else. A room's password from an invitation is used to join it. |
| XEP-0047 | In-Band Bytestreams | The transport of Jingle file transfers (XEP-0261), in `iq` stanzas only: `message` stanzas are refused. |
| XEP-0048 | Bookmarks | Only the PEP form (`storage:bookmarks`), read and written on servers that don't mirror XEP-0402 bookmarks to it (no `#compat`), and when a XEP-0402 publish fails or goes unanswered. |
| XEP-0050 | Ad-Hoc Commands | Client side: lists and runs the commands of the server, of a contact's devices that advertise them, of a group, and of a group's members that offer them (bots), including ones with several stages (next, previous, complete, cancel), forms, result tables and notes. Also used to register with the push relay. |
| XEP-0059 | Result Set Management | Used by MAM, and to read the settings node a page at a time. |
| XEP-0060 | Publish-Subscribe | Full for what Yapnest uses: publish with an access model, reconfigure a node that refuses it, create a node with its configuration, read all items a page at a time (RSM). |
| XEP-0066 | Out of Band Data | Full, for uploaded files. |
| XEP-0077 | In-Band Registration | Password change only; no account registration. |
| XEP-0084 | User Avatar | Full: publish, remove, receive. |
| XEP-0085 | Chat State Notifications | Full; can be turned off. |
| XEP-0115 | Entity Capabilities | Full. |
| XEP-0147 | XMPP URI Query Components | Receive: `xmpp:` links open a chat (`message`, with `body` in the composer) or ask before adding a contact (`roster`, `subscribe`) or joining a group (`join`; a `password` is ignored). Nothing is sent without the user's confirmation. See RFC 5122 for the form of the address. |
| XEP-0153 | vCard-Based Avatars | Read as a fallback for contacts, and for room avatars, which owners also set (XEP-0486). Our own avatar is published only through PEP (XEP-0084). |
| XEP-0163 | Personal Eventing Protocol | Full. |
| XEP-0166 | Jingle | Audio and video calls: session-initiate, session-accept, transport-info and session-terminate, with an audio content and, for a video call, a video one. Video is decided when the call is proposed: content changes, so adding or dropping video mid-call, aren't supported. It also carries file transfers (XEP-0234). |
| XEP-0167 | Jingle RTP Sessions | Audio, and video chosen when the call is proposed. `urn:xmpp:jingle:apps:rtp:video` is advertised, and a contact is offered video calls only if one of their devices advertises it too. |
| XEP-0172 | User Nickname | Full: published, read from contacts, sent with contact requests. |
| XEP-0176 | Jingle ICE-UDP Transport Method | Audio and video calls: candidates are trickled in `transport-info`. |
| XEP-0184 | Message Delivery Receipts | Full. |
| XEP-0191 | Blocking Command | Full. |
| XEP-0198 | Stream Management | Full: acks and resumption, inline with SASL2. |
| XEP-0199 | XMPP Ping | Full. Also confirms a sent message on a server without stream management. |
| XEP-0203 | Delayed Delivery | Read. |
| XEP-0215 | External Service Discovery | STUN and TURN servers are asked for from the account's server when a call starts or rings, and kept until their credentials run out (10 minutes when they don't say). Without any the call still tries a direct path. |
| XEP-0223 | Persistent Storage of Private Data via PubSub | Used for bookmarks and read state, and for Yapnest's own settings (pins, archived chats, link preview and sound choices, GIF favorites, emoji usage and the like), in a node only the account can read, so they follow the user to their other devices. |
| XEP-0234 | Jingle File Transfer | Receive and send file offers over in-band bytestreams, in 1:1 chats with contacts, unencrypted only. A file is sent this way only when the server's upload can't take it (no upload service, or the file is over its limit) and a device of the contact advertises it; encrypted chats and requests for a file aren't supported. A received offer is accepted at once up to 15 MB, and waits to be accepted above that. The file's SHA-256 is checked when given, and files over 1 GiB are declined. Offers end when the connection does. |
| XEP-0245 | The /me Command | Display. |
| XEP-0249 | Direct MUC Invitations | Full; received only from contacts. The invitation's password is used to join the room. |
| XEP-0261 | Jingle In-Band Bytestreams Transport Method | The only transport for file transfers: blocks of up to 8 KiB, eight in flight. SOCKS5 (XEP-0260) isn't supported. |
| XEP-0264 | Jingle Content Thumbnails | Receive: a small `data:` image in a file's metadata is shown blurred until the file is downloaded (`cid:` and web URIs are not fetched). Sent only in unencrypted chats. |
| XEP-0280 | Message Carbons | Full. |
| XEP-0297 | Stanza Forwarding | Used by carbons and MAM. |
| XEP-0300 | Use of Cryptographic Hash Functions in XMPP | A SHA-256 hash is sent with a picture's or a sound file's metadata, in unencrypted chats only; received hashes there are not checked. A Jingle file transfer (XEP-0234) carries one in both directions, and a received file is checked against it. |
| XEP-0308 | Last Message Correction | Full. |
| XEP-0313 | Message Archive Management | Full, for the account and for rooms. |
| XEP-0320 | Use of DTLS-SRTP in Jingle Sessions | Audio and video calls: the fingerprint is sent and read, but not yet verified against OMEMO. |
| XEP-0333 | Chat Markers | Partial: `displayed` only, sent and read; can be turned off. |
| XEP-0334 | Message Processing Hints | `<store/>` only. |
| XEP-0338 | Jingle Grouping Framework | Calls: the BUNDLE group is sent and read, so a video call's audio and video share one transport. Not advertised as a feature. |
| XEP-0352 | Client State Indication | Full. On the Mac the app is never suspended, so it never sends `inactive`. |
| XEP-0353 | Jingle Message Initiation | Audio and video calls: propose (with an audio description and, for video, a video one), ringing, proceed, accept, reject, retract and finish, sent and read, including the copies from carbons and the archive, which become the call rows in a chat. Two calls proposed at the same moment between the same two people are settled by the tie-break of section 4.1 (the lower session id goes on), and a video-only propose is turned down as unsupported. Calls ring for contacts only. Ringing a phone whose app is closed isn't built yet. |
| XEP-0357 | Push Notifications | Full, through Yapnest's relay. |
| XEP-0359 | Unique and Stable Stanza IDs | Full. |
| XEP-0363 | HTTP File Upload | Full. The server's own domain counts as an upload service as well as its components. A `file-too-large` answer is told to the user (or hands the file to Jingle where that works), a `retry` stamp is waited for once, and a slot or upload that fails in a way that can pass is tried again. |
| XEP-0368 | SRV records for XMPP over TLS | Full. |
| XEP-0372 | References | Mentions only. |
| XEP-0377 | Spam Reporting | Full, where the server offers it. |
| XEP-0379 | Pre-Authenticated Roster Subscription | Send: a `preauth` token in an `xmpp:` link goes with the subscription request. Account registration (`ibr=y`) isn't done. |
| XEP-0384 | OMEMO Encryption | Legacy 0.3 (`eu.siacs.conversations.axolotl`) only, in 1:1 chats and private groups; not OMEMO 2. |
| XEP-0386 | Bind 2 | Full, where the server offers it. |
| XEP-0388 | Extensible SASL Profile | Full, falling back to SASL. |
| XEP-0393 | Message Styling | Yes: bold, italic, strikethrough, code, quotes and preformatted blocks. |
| XEP-0402 | PEP Native Bookmarks | Full. |
| XEP-0410 | MUC Self-Ping | Full. |
| XEP-0421 | Occupant Identifiers | Read. |
| XEP-0422 | Message Fastening | Read, for older retractions and moderations only. |
| XEP-0424 | Message Retraction | Full. |
| XEP-0425 | Moderated Message Retraction | A moderator removes others' messages (version 1), where the room offers it; a room's retraction is read in both versions, from the room itself only. |
| XEP-0428 | Fallback Indication | Full. |
| XEP-0439 | Quick Response | Receive: a message's suggested replies, shown as buttons under the newest message of a chat and sent as ordinary text, and its actions, shown as buttons under the bubble, each chosen once, and sent as an `<action-selected>`, which the account's other devices read from the carbon or the archive to stop offering the action too. Both are ignored in encrypted messages, as they are not covered by OMEMO, and in groups and their private messages, where an action would reach the whole room. |
| XEP-0440 | SASL Channel-Binding Type Capability | Password sign-ins over TLS use SCRAM-SHA-256-PLUS or SCRAM-SHA-1-PLUS with `tls-exporter` (TLS 1.3) or `tls-server-end-point`, whichever the server lists, and tell a server that offered no -PLUS that we could have bound (`y`). FAST tokens are not bound. |
| XEP-0444 | Message Reactions | Full. |
| XEP-0446 | File Metadata Element | Receive: size and, for pictures and videos, width and height, so a bubble has its final shape before the download, and a thumbnail; for sound, its length, shown on a voice message before it is downloaded. Sent for pictures and sound files (with their length) only in unencrypted chats; the metadata is not covered by OMEMO, so an encrypted chat sends none. |
| XEP-0447 | Stateless File Sharing | Partial. Receive: the metadata of a `<file-sharing>`, in the message with the link or in an earlier message without a body (as Dino sends it). Sent in one message with the link and the XEP-0066 element, for pictures and sound files in unencrypted chats only. Sources other than the message's own link are ignored. |
| XEP-0454 | OMEMO Media Sharing | Full. |
| XEP-0461 | Message Replies | Full. |
| XEP-0478 | Stream Limits Advertisement | Receive: the `max-bytes` a server advertises after sign-in is the largest stanza Yapnest sends (262144 bytes when it says none). A stream resumed through SASL2 gets no new features, so the default applies there. A message over it is marked failed instead of closing the stream. |
| XEP-0484 | Fast Authentication Streamlining Tokens | Full, where the server offers it. |
| XEP-0486 | MUC Avatars | Shown, and set or removed by a group's owner through the room's vCard, where the server keeps one for rooms. |
| XEP-0490 | Message Displayed Synchronization | Full. |
| XEP-0492 | Chat Notification Settings | Full, synced through bookmarks. |

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers building the app, the local
development servers and the tests.

## License

Yapnest is free software under the GNU Affero General Public License, version
3 or later (`NOTICE`, with the licence's text in `LICENSE`). It has to be: it is built on Martin (AGPL-3.0) and on
libsignal through MartinOMEMO (GPL-3.0), and both require the whole app to be
released under a compatible license, with its source available to everyone
who gets the app. `Vendor/README.md` lists what we changed in our copies of
those libraries. Settings > Open source licences in the app shows every
library's licence.

Copyright © 2026 Mathilde Gilles.

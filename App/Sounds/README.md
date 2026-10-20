# Notification sounds

The sounds a chat can use for its notifications (`NotificationSound.bundled` in YapnestKit lists them). They are bundled in the app's main bundle, which is where iOS looks for a notification's sound file. Never rename one: chats store the file name.

All are from Kenney's **Interface Sounds** pack, by Kenney (https://kenney.nl), released under CC0 1.0 (public domain): https://kenney.nl/assets/interface-sounds. The pack's own `License.txt` says "Creative Commons Zero, CC0". The legal text is in `LICENSE-CC0.txt`, and shows in the app under Settings > Open source licences (`dev/licences.py`).

They were converted from the pack's `.ogg` files with `ffmpeg -ac 1 -ar 44100 -c:a pcm_s16le`, then `afconvert -f caff -d LEI16@44100 -c 1`.

| File | Name | Pack file |
| --- | --- | --- |
| `chime.caf` | Chime | `confirmation_002.ogg` |
| `ding.caf` | Ding | `confirmation_001.ogg` |
| `glass.caf` | Glass | `glass_001.ogg` |
| `bloom.caf` | Bloom | `maximize_006.ogg` |
| `pluck.caf` | Pluck | `pluck_002.ogg` |
| `pop.caf` | Pop | `open_001.ogg` |
| `drop.caf` | Drop | `drop_001.ogg` |
| `bong.caf` | Bong | `bong_001.ogg` |
| `hmm.caf` | Hmm | `question_001.ogg` |
| `ripple.caf` | Ripple | `select_006.ogg` |

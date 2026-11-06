# amanuensis
A macOS menu bar app that detects web meetings, records them, and transcribes Japanese speech afterwards

## Meeting detection

Every 2 seconds, amanuensis reads Core Audio's per-process audio state. A meeting is in progress while a process of one of these apps uses microphone input. Helper processes whose bundle ID starts with the app's bundle ID followed by `.` count as the app.

| Meeting | Bundle ID |
| :-- | :-- |
| Zoom | `us.zoom.xos` |
| Microsoft Teams | `com.microsoft.teams2` |
| Google Meet | `com.google.Chrome` |
| Slack huddles | `com.tinyspeck.slackmacgap` |

- Google Meet is detected as any microphone use by Google Chrome, so other sites that use the microphone in Chrome are detected too. Delete such recordings with "破棄…" in the menu.
- A meeting starts when the microphone use is observed, and ends when the microphone is not used for 15 seconds in a row.
- amanuensis's own microphone use is not counted.
- Only recordings started by meeting detection stop automatically. Recordings started with "録音を開始" keep going.
- If you turn off automatic recording in Settings, amanuensis only shows a notification when it detects a meeting.
- amanuensis does not read window titles, URLs, or meeting names.
- While Microphone or System Audio Recording is denied, meeting detection stops and the menu shows the missing permission with a link to System Settings. "録音を開始" still works.

## Requirements

- macOS 15 or later
- Apple Silicon

## Permissions

amanuensis asks for these permissions:

- Microphone
- System Audio Recording: used for the system audio of meeting apps (System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only).
- Documents folder: the default save location.
- Notifications

The app is ad-hoc signed, so macOS may ask for the permissions again after an update. If you turn on System Audio Recording in System Settings, relaunch the app.

## Recording

Use "録音を開始", "停止", and "破棄…" in the menu bar. A detected meeting also starts a recording automatically unless turned off in Settings (see Meeting detection). Recordings are saved under `~/Documents/amanuensis/` by default (changeable in Settings) as `<yyyy-MM-dd_HHmmss>/recording.caf`.

## Audio format

- Container: CAF
- Codec: LPCM, 16-bit signed integer
- Sample rate: 48 kHz
- Channels: 2 (left = microphone, right = system audio)
- Size: about 691 MB per hour

Audio is flushed to disk every 5 seconds, so a forced quit keeps everything up to the last flush.

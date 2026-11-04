# amanuensis
A macOS menu bar app that detects web meetings, records them, and transcribes Japanese speech afterwards

## Requirements

- macOS 15 or later
- Apple Silicon

## Permissions

amanuensis asks for these permissions:

- Microphone
- Screen & System Audio Recording: used for the system audio of meeting apps. The app does not save video.
- Documents folder: the default save location.
- Notifications

The app is ad-hoc signed, so macOS may ask for the permissions again after an update. After granting Screen & System Audio Recording, relaunch the app.

## Recording

Use "録音を開始", "停止", and "破棄…" in the menu bar. Recordings are saved under `~/Documents/amanuensis/` by default (changeable in Settings) as `<yyyy-MM-dd_HHmmss>/recording.caf`.

## Audio format

- Container: CAF
- Codec: LPCM, 16-bit signed integer
- Sample rate: 48 kHz
- Channels: 2 (left = microphone, right = system audio)
- Size: about 691 MB per hour

Audio is flushed to disk every 5 seconds, so a forced quit keeps everything up to the last flush.

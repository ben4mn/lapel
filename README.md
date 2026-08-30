# Lapel

**Multi-track voice memos for macOS.** Record two people wearing two lapel mics, get
back two audio files and two transcripts — one per speaker.

Voice Memos records one track. If you clip a DJI Mic Mini transmitter to each person
and plug the receiver into your Mac, the hardware is already keeping them apart —
TX1 on the left channel, TX2 on the right. Lapel is the app that stops throwing that
away.

<!-- screenshot goes here once the UI lands -->

## Why

A two-person conversation recorded to one mixed track is a transcript full of
guesses about who said what. Diarization models exist and they are mediocre. But if
each speaker is already wearing their own microphone, the separation is *physical* —
perfect, deterministic, and free. Lapel just refuses to discard it.

## What it does

- **Sees the receiver arrive.** Hotplug detection via CoreAudio, no polling.
- **Tells you how many lapels are actually live** — not how many the receiver could
  take, how many are switched on and transmitting right now.
- **Meters each transmitter separately**, with proper ballistics and clip detection.
- **Records to one file per speaker**, named by whoever was wearing that mic.
- **Transcribes each track on-device**, so the transcript is already attributed.
- **Warns you when the receiver is in Mono mode**, where the two lapels are mixed
  together and separation is impossible — with the fix, on the hardware, in words.

## Status

Under construction. Working today:

| | |
|---|---|
| ✅ | Device enumeration, hotplug and channel-mode detection |
| ✅ | Level metering, live transmitter count, speaking indicator |
| ✅ | Recording state machine, per-channel file writing, session store |
| ✅ | `lapel-probe` terminal harness |
| 🚧 | SwiftUI app |
| 🚧 | On-device transcription |

## Try the hardware layer now

No app needed — the probe verifies everything below the UI against your own gear:

```bash
swift run lapel-probe
```

```
Input devices
────────────────────────────────────────────────────────────────────────
  ▸ DJI MIC MINI                  2 channels   48000 Hz  usb
    MacBook Air Microphone        1 channel    48000 Hz  builtIn
────────────────────────────────────────────────────────────────────────

DJI MIC MINI — 2 of 2 microphones live
  TX1    [███████████████|·················]  -18.4 dBFS  ● speaking
  TX2    [████|···························]  -46.1 dBFS  ○ live
```

Plug and unplug the receiver, or press its mode button, while it runs.

## Requirements

- macOS 14 or later (on-device transcription requires macOS 26)
- A DJI Mic Mini, DJI Mic 2, or any multi-channel USB audio input
- **The receiver must be in S (Stereo) mode.** In M (Mono) it mixes both lapels into
  a single channel before your Mac ever sees them. Lapel will tell you if it is.

## Design

The rule the codebase is built around: **hardware types stop at the bridge.**

Metering, receiver detection, transmitter presence, the recording state machine and
the session store contain no CoreAudio or AVFoundation types whatsoever. Audio
reaches them as `[[Float]]` — one array per channel. Everything above the bridge is
therefore testable against synthetic signals with exact arithmetic, and the entire
suite runs on a CI machine with no audio interface attached.

Exactly three files talk to hardware:

- `CoreAudioDeviceEnumerator` — reads the device list from the HAL
- `AudioDeviceMonitor` — hotplug and channel-mode listeners
- `AudioCapture` — the AVAudioEngine tap, deinterleaving to `[[Float]]`

### Two things worth knowing

**Counting live microphones is inference, not a query.** CoreAudio cannot tell you
how many transmitters are linked; the receiver enumerates as a fixed 2-channel USB
device whether one lapel is on or both. But a channel with no transmitter carries
*true digital zero*, while a linked transmitter sitting silent still sends its own
self-noise, around -60 dBFS and never exactly zero. That gap is the whole
discriminator. Presence is believed on the first buffer so the UI lights up
instantly; absence must persist for a confirmation window, so an RF dropout cannot
make the count flicker.

**Reading device names needs no microphone permission.** The CoreAudio HAL will name
every attached device before the user has granted anything, so Lapel can show
"DJI MIC MINI — 2 of 2 microphones live" on first launch and only prompt when you
actually press record. A browser-based equivalent cannot do this: `getUserMedia`
hides device labels until permission is granted.

## Development

```bash
swift build              # build the library and the probe
swift test               # full suite, no audio hardware required
swift run lapel-probe    # live readout against real hardware
```

Red/green TDD throughout — tests are written first and confirmed failing before any
implementation exists. Every commit message says what was red. Tests use
[swift-testing](https://github.com/swiftlang/swift-testing).

## License

MIT

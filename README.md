# Lapel

**Multi-track voice memos for macOS.** Record two people wearing two lapel mics, get
back two audio files and two transcripts — one per speaker.

**[ben4mn.github.io/lapel](https://ben4mn.github.io/lapel/)**

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
- **Exports a shareable pair**: all speakers mixed into one audio file, and one
  combined transcript with every line attributed — as plain text, Markdown or SRT.

## Status

Under construction. Working today:

| | |
|---|---|
| ✅ | Device enumeration, hotplug and channel-mode detection |
| ✅ | Level metering, live transmitter count, speaking indicator |
| ✅ | Recording state machine, per-channel file writing, session store |
| ✅ | `lapel-probe` terminal harness |
| ✅ | SwiftUI app — live meters, transport, session library |
| ✅ | Combined audio + transcript export (txt, Markdown, SRT) |
| ✅ | On-device transcription with `SpeechAnalyzer` (requires macOS 26) |

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

No receiver to hand? Write a demo session and open the app:

```bash
swift run lapel-probe --demo-session ~/Library/Containers/com.4mn.lapel/Data/Library/Application\ Support/Lapel/Sessions
```

## Requirements

- macOS 14 or later. On-device transcription requires macOS 26 and a build made
  with Xcode 26 — on older toolchains the engine compiles out and the app says so.
- A DJI Mic Mini, DJI Mic 2, or any multi-channel USB audio input
- **The receiver must be in S (Stereo) mode.** In M (Mono) it mixes both lapels
  together before your Mac ever sees them. Lapel will tell you if it is — including
  the case the channel count cannot reveal, below.

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

### Exporting

The per-speaker files are the point, but they are awkward to send to someone. So
export produces the shareable pair *alongside* them: every track mixed to one audio
file, and one transcript with each line attributed.

The mixdown is a sum, not an average. Averaging is the textbook answer and it is
wrong here — two people taking turns is the normal case, so only one track is loud
at any instant, and dividing by the track count would halve the volume of a
recording that never came close to clipping. Instead the sum is taken at full
weight, and a single gain is applied across the whole mix only if its peak would
exceed −1 dBFS.

Mixing the audio discards the separation, so the transcript has to carry it in the
text. Names you typed are used as written; an unnamed track becomes `Speaker 1`
rather than `TX1`, because a hardware label has no business in a document meant to
be read. A numbered mode overrides names entirely, for sharing a transcript without
naming anyone.

### Channel count is not the mode

A real DJI Mic Mini enumerates as `Wireless Mic Rx`, two input channels, 48 kHz,
USB — **even in Mono mode**, where it sends the identical mix down both channels. A
receiver can therefore claim stereo and still be incapable of separating speakers.

So Lapel compares the two channels sample for sample. If they match while carrying
signal, it says so and names the fix. Silence is never treated as evidence: two
channels of digital zero are identical, but that is exactly what a correctly
configured stereo receiver looks like with both lapels switched off.

The device's product name also contains no vendor string at all, which is why
detection matches on the manufacturer field rather than the name.

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

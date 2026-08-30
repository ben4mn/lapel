# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Lapel is a macOS app for multi-track voice recording from a DJI Mic Mini (or any
multi-channel USB input). Each transmitter lands on its own channel, so each
speaker gets their own audio file and their own transcript.

## Build and test

```bash
swift build              # build LapelKit and the probe
swift test               # run the full suite (no audio hardware required)
swift run lapel-probe    # live device/level readout against real hardware
```

The Xcode app target lives in `App/` and is generated from `App/project.yml`
with XcodeGen; the `.xcodeproj` is not committed.

## Architecture

The design rule is that **hardware types stop at the bridge**. `LevelMeter`,
`ReceiverDetector`, `MicPresenceDetector`, `ReceiverState`, `SessionStore` and
`RecordingSession` contain no CoreAudio or AVFoundation types at all — audio
reaches them as `[[Float]]`, one array per channel. That is what makes the
suite runnable on a CI machine with no audio interface.

Only three files talk to hardware:

| File | Responsibility |
|---|---|
| `CoreAudioDeviceEnumerator` | reads the device list from the HAL |
| `AudioDeviceMonitor` | hotplug and channel-mode-change listeners |
| `AudioCapture` | AVAudioEngine tap, deinterleaves to `[[Float]]` |

When adding a feature, ask which side of that line it belongs on. If it can be
expressed over `[Float]` and value types, it belongs above the bridge and it
gets tests.

## Testing

Red/green TDD. Write the failing test first, confirm it fails for the reason
you expect, then implement. Tests use swift-testing (`import Testing`,
`@Test`, `#expect`), not XCTest.

Two macro constraints worth knowing:
- `#expect` cannot expand `allSatisfy(_:)` with a keypath through a `rethrows`
  call. Use `filter(...).count` instead.
- Comparing directory `URL`s with `==` is string comparison, so a trailing
  slash makes it fail spuriously. Compare `.standardizedFileURL.path`.

## Things only hardware catches

The audio tap runs on AVFAudio's realtime queue. `AudioCapture.start` is
main-actor isolated, so the tap closure must be marked `@Sendable` or it
inherits that isolation and the compiler injects an executor assertion at its
entry — which trips and kills the process with SIGTRAP the instant real audio
arrives. It compiles cleanly either way and no test reaches that thread. If you
touch the tap, test with a device attached.

## Hardware facts that constrain the design

- The DJI receiver has M / Ms / S modes. In **S (Stereo)** it puts TX1 on the
  left channel and TX2 on the right. In **M (Mono)** it mixes both lapels
  together, and no software can unmix that.
- **Channel count does not tell you the mode.** A real DJI Mic Mini enumerates
  as `Wireless Mic Rx`, 2 input channels, 48 kHz, USB — *even in Mono mode*,
  where it sends the identical mix down both channels. Verified on hardware
  2026-08-30. `DuplicateChannelDetector` compares the two channels sample for
  sample and raises the advisory when they match; silence is never taken as
  evidence, because a correctly configured stereo receiver with both lapels off
  looks exactly the same.
- **The product name contains no vendor string.** Detection matches on the
  manufacturer field (`DJI Technology Co., Ltd.`), which is why a name-only
  match would miss the real device entirely.
- CoreAudio cannot report how many transmitters are linked. The receiver
  enumerates as a fixed 2-channel device either way. Live mic count is inferred
  from the signal: an unlinked channel carries true digital zero, a linked but
  quiet one carries self-noise around -60 dBFS.
- Reading device names through the HAL needs no microphone permission, so
  connection state is shown before the user is ever prompted.

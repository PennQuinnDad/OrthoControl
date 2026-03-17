# OrthoControl — Overview

A two-piece system that turns a **Teenage Engineering ORTHO Remote** (a minimalist Bluetooth knob) into a wireless controller for **Roon** music playback and **macOS system audio**.

## Components

### OrthoControl.app (Swift / SwiftUI)

A native macOS menu bar application. Connects to the ORTHO Remote over Bluetooth Low Energy, activates macOS's built-in BLE-MIDI driver, and receives MIDI events via CoreMIDI. Runs as a lightweight menu bar utility with no Dock icon. Zero external dependencies — uses only Apple system frameworks (CoreBluetooth, CoreMIDI, CoreAudio, Foundation). Built with Swift Package Manager.

### Roon Ortho Extension (Node.js)

A background service that bridges OrthoControl to Roon. Discovers Roon Core automatically over the local network using Roon's SOOD multicast protocol. Exposes a local HTTP + WebSocket API on `127.0.0.1:9330`. Runs as a launchd service that starts at login and auto-restarts on failure.

## How They Work Together

```
ORTHO Remote ──BLE──▶ OrthoControl.app ──HTTP──▶ roon-extension ──WebSocket──▶ Roon Core
  (knob)              (menu bar, Swift)          (Node.js :9330)               (on LAN)
```

The ORTHO Remote sends MIDI CC (knob rotation) and Note On (button press) events over Bluetooth. OrthoControl receives them and, depending on the selected mode, either adjusts macOS system volume via CoreAudio, or sends HTTP commands to the Node.js extension which forwards them to Roon Core.

## Features

- **Two control modes** — System (macOS volume with native HUD) and Roon (zone-based playback)
- **Multi-zone support** — Browse and switch between all Roon zones from the menu bar
- **Live playback indicators** — Animated equalizer bars next to zones that are playing
- **Transport controls** — Play/pause, next, previous, volume up/down
- **Real-time updates** — WebSocket pushes zone changes, volume, and now-playing info instantly
- **Zone persistence** — Selected zone saved across restarts
- **Auto-everything** — BLE auto-connect, sleep/wake reconnection, SOOD rediscovery, launchd auto-restart
- **Now-playing metadata** — Track title, artist, album, seek position via the API

## Requirements

### Hardware

- Teenage Engineering ORTHO Remote
- Any Mac with Bluetooth 4.0+ (any Mac from 2012 onward, all Apple Silicon Macs)

### For System Mode

- macOS 14 (Sonoma) or later

That's it — turn the knob to control macOS system volume, press to play/pause.

### For Roon Mode

- macOS 14 (Sonoma) or later
- Node.js 18+
- Roon with an active subscription and at least one audio zone configured
- Mac on the same local network as Roon Core (they don't need to be the same machine)

### Optional

- **Accessibility permission** — enables the native macOS volume HUD overlay in System mode (volume still works without it)

## Development

- **Platform:** macOS (ARM64)
- **Source:** [github.com/PennQuinnDad/OrthoControl](https://github.com/PennQuinnDad/OrthoControl) (MIT license)
- **Swift app:** `swift build -c release` + `build.sh`
- **Node.js extension:** npm, deployed as a launchd agent
- **Current version:** 2.0.0

## Notes

OrthoControl runs entirely on your own hardware. There is no cloud service, no account, no login or password, and no data collection of any kind. All communication stays on your local network — Bluetooth between the knob and your Mac, HTTP on localhost between the app and the extension, and a LAN WebSocket connection to Roon Core. The source code is open source under the MIT license. Everything runs natively on macOS with no telemetry, no analytics, and no phone-home behavior.

This is a personal hobby project. I'm not a software developer — all of the coding was done with the help of Claude Opus 4.6 (Anthropic). This was never intended as a commercial product or supported software; it's an experiment for my own use and personal development. If you find it useful or learn something from it, that's great, but please understand it comes with no support, no warranty, and no guarantees.

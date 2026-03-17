# OrthoControl for Roon

A macOS menu bar app that turns a [Teenage Engineering ORTHO Remote](https://teenage.engineering/products/ortho-remote) into a wireless volume knob — for both **system volume** and **Roon** playback.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

<img src="images/menu-bar-system.png" width="300" alt="OrthoControl in System mode controlling macOS volume"> &nbsp; <img src="images/menu-bar.png" width="300" alt="OrthoControl in Roon mode connected to a zone">

## What it does

- **Turn the knob** to change volume (1/64 step precision, same as Option+Shift+Volume)
- **Press the button** to play/pause
- **System mode** controls macOS system volume with native volume HUD
- **Roon mode** controls a Roon zone via the included Node.js extension
- **Multi-zone support** — switch between Roon zones from the menu bar dropdown
- **Live playback indicators** — animated equalizer bars show which zones are playing
- **WebSocket real-time updates** — zone state, volume, and now-playing info pushed instantly
- Auto-connects via Bluetooth, auto-reconnects on wake from sleep
- Runs as a lightweight menu bar app (no Dock icon)

## How it works

The ORTHO Remote is a Bluetooth Low Energy (BLE) MIDI device. OrthoControl:

1. Discovers the ORTHO Remote via CoreBluetooth
2. Activates macOS's built-in BLE-MIDI driver (`MIDIBluetoothDriverActivateAllConnections`)
3. Receives MIDI CC (knob) and Note On/Off (button) events via CoreMIDI
4. Routes events to either macOS audio (CoreAudio) or Roon (via HTTP to the Node.js extension)

No pairing in Audio MIDI Setup required. No MIDI token needed.

### Where does the Roon extension run?

The Roon extension runs on the **same Mac as OrthoControl** — it does **not** need to run on your Roon Core machine. It discovers Roon Core automatically over the local network via multicast (SOOD protocol) and bridges between OrthoControl (local HTTP) and Roon Core (remote WebSocket).

**Example:** Your Roon Server runs on a Mac mini in a closet, and you want to control it with an ORTHO Remote at your desk. You install OrthoControl and the Roon extension on your MacBook Pro — the Mac you sit at. The extension finds the Mac mini's Roon Core over your home network automatically. The ORTHO Remote connects via Bluetooth to your MacBook, and OrthoControl routes knob turns and button presses to Roon on the Mac mini. Nothing needs to be installed on the Mac mini.

```
┌───────── MacBook Pro (your desk) ──────────┐         ┌─── Mac mini (closet) ───┐
│                                             │         │                         │
│  ORTHO Remote ──BLE──▶ OrthoControl.app     │         │    Roon Server          │
│                            │                │         │         ▲               │
│                          HTTP               │         │         │               │
│                            ▼                │         │         │               │
│                     roon-extension ─── ── ──│── WS ──▶│─ ── ── ─┘               │
│                    (Node.js :9330)           │  (LAN)  │                         │
└─────────────────────────────────────────────┘         └─────────────────────────┘
```

## Requirements

- macOS 14 (Sonoma) or later
- A [Teenage Engineering ORTHO Remote](https://teenage.engineering/products/ortho-remote)
- For Roon mode: [Roon](https://roon.app) with a networked audio zone, and Node.js 18+

## Installation

### Build the macOS app

```bash
cd app
swift build -c release
bash build.sh
cp -r OrthoControl.app /Applications/
```

### Set up the Roon extension (optional)

```bash
cd roon-extension
cp config.example.json config.json
# Edit config.json — set your Roon zone name
npm install
npm start
```

On first run, go to **Roon Settings > Extensions** and authorize "Ortho Remote."

The `zone_name` in `config.json` sets the initial zone. Once the extension is running, you can switch zones from the OrthoControl menu bar dropdown — the selection is persisted automatically.

### Run as a background service (recommended)

The extension needs to stay running for Roon mode to work. Instead of leaving a terminal open, install it as a launchd service that starts automatically at login and restarts if it crashes:

```bash
# Edit the plist — update WorkingDirectory and node path for your system
cp roon-extension/com.orthocontrol.roon-extension.plist ~/Library/LaunchAgents/
nano ~/Library/LaunchAgents/com.orthocontrol.roon-extension.plist

# Load the service
launchctl load ~/Library/LaunchAgents/com.orthocontrol.roon-extension.plist

# Check status
curl http://127.0.0.1:9330/status

# View logs
tail -f /tmp/roon-ortho.log

# Stop the service
launchctl unload ~/Library/LaunchAgents/com.orthocontrol.roon-extension.plist
```

The extension automatically reconnects to Roon Core after network interruptions or sleep/wake cycles.

## Configuration

### Roon extension (`roon-extension/config.json`)

```json
{
  "zone_name": "Your Zone Name",
  "volume_step": 2,
  "http_port": 9330
}
```

| Key | Description |
|-----|-------------|
| `zone_name` | Initial Roon zone (can be changed from the menu bar at runtime) |
| `volume_step` | dB change per knob tick (default: 2) |
| `http_port` | Local HTTP port for OrthoControl communication (default: 9330) |

### API Endpoints

The Roon extension exposes these HTTP endpoints on `127.0.0.1:9330`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/status` | GET | Current zone status, volume, playback state, and now-playing info |
| `/zones` | GET | List all available Roon zones with playback states |
| `/zone` | POST | Switch the active zone (`{"zone_id": "..."}`) |
| `/command` | POST | Send a transport command (`play_pause`, `next`, `prev`, `volume_up`, `volume_down`) |

A WebSocket endpoint is also available at `ws://127.0.0.1:9330` for real-time state updates.

### Accessibility (optional)

For the native macOS volume HUD to appear when using System mode, grant OrthoControl accessibility access:

**System Settings > Privacy & Security > Accessibility > OrthoControl**

Without this, volume still changes — you just won't see the on-screen indicator.

## Architecture

```
OrthoControl.app (Swift/SwiftUI)
├── Bluetooth/       # BLE discovery + MIDI driver activation
├── MIDI/            # CoreMIDI event parsing
├── Audio/           # CoreAudio volume + media key simulation
├── Roon/            # HTTP client for the Roon extension
├── Models/          # App state, connection status, control mode
├── Views/           # Menu bar UI
└── App/             # App entry point + coordinator

roon-extension/ (Node.js)
├── index.js         # Roon API + HTTP/WebSocket server
├── config.json      # Zone config (user-specific, gitignored)
└── scripts/         # postinstall patch for Node.js 22+
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| ORTHO Remote not found | Turn it on (press button), wait ~5 seconds, check Bluetooth is on |
| Knob works but no volume HUD | Grant Accessibility permission (see above) |
| "Roon extension not running" | Start it: `cd roon-extension && npm start` (or set up the launchd service) |
| Extension loses Roon after sleep | The extension auto-reconnects within ~15s. If using launchd, it also auto-restarts on crash |
| Roon zone not found | Check `zone_name` in config.json matches Roon exactly (or switch zones from the menu bar) |
| Volume too sensitive / too slow | Adjust `volume_step` in config.json (1 = fine, 5 = coarse) |

## License

MIT

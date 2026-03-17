import SwiftUI

struct MenuBarView: View {
    let state: OrthoRemoteState
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onToggleLaunchAtLogin: (Bool) -> Void
    let onSetControlMode: (ControlMode) -> Void
    let onSelectZone: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("OrthoControl")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(state.connectionStatus.color)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline)
                if let name = state.deviceName, state.connectionStatus == .connected {
                    Text("(\(name))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Mode-specific content when connected
            if state.connectionStatus == .connected {
                // Mode picker
                Picker("Control", selection: Binding(
                    get: { state.controlMode },
                    set: { onSetControlMode($0) }
                )) {
                    ForEach(ControlMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if state.controlMode == .roon {
                    // Roon zone list
                    if state.roonConnected {
                        if !state.roonZones.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(state.roonZones) { zone in
                                    ZoneRow(
                                        zone: zone,
                                        isSelected: zone.zone_id == state.roonSelectedZoneId
                                    ) {
                                        onSelectZone(zone.zone_id)
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "hifispeaker.fill")
                                Text("No zones available")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "hifispeaker.fill")
                            Text("Roon extension not running")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } else {
                    // System volume
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.fill")
                        Text("Volume: \(state.volumePercent)%")
                            .font(.subheadline)
                        Spacer()
                    }

                    ProgressView(value: Double(state.currentVolume))
                        .tint(.accentColor)

                    // Accessibility guidance
                    if !state.accessibilityGranted {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Volume indicator requires Accessibility")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("System Settings \u{203A} Privacy & Security \u{203A} Accessibility")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            // Tips
            if state.connectionStatus == .disconnected {
                Text("Turn on your ORTHO Remote to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.connectionStatus == .connecting {
                Text("Detected nearby. Waiting for MIDI...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Actions
            if state.connectionStatus == .connected {
                Button("Disconnect") {
                    onDisconnect()
                }
            } else {
                Button(state.connectionStatus == .scanning ? "Scanning..." : "Scan for Device") {
                    onConnect()
                }
                .disabled(state.connectionStatus == .scanning)
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { onToggleLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.subheadline)

            Button("Quit OrthoControl") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }

    private var statusText: String {
        switch state.connectionStatus {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .scanning:
            return "Scanning..."
        case .disconnected:
            return "Disconnected"
        }
    }
}

private struct ZoneRow: View {
    let zone: RoonZone
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Animated playing indicator or static icon
                if zone.state == "playing" {
                    NowPlayingBars(isPlaying: true)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                } else if zone.state == "paused" || zone.state == "loading" {
                    NowPlayingBars(isPlaying: false)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "hifispeaker.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                }

                Text(zone.display_name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .opacity(isSelected ? 1.0 : 0.75)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

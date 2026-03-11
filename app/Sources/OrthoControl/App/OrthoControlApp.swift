import ApplicationServices
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "com.ericanderson.OrthoControl", category: "App")

@main
struct OrthoControlApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                state: coordinator.state,
                onConnect: { coordinator.connect() },
                onDisconnect: { coordinator.disconnect() },
                onToggleLaunchAtLogin: { coordinator.toggleLaunchAtLogin($0) },
                onSetControlMode: { coordinator.setControlMode($0) }
            )
        } label: {
            StatusItemIcon(status: coordinator.state.connectionStatus)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Wires together CoreMIDI (for MIDI events) and Bluetooth (for device presence detection).
/// MIDI events flow exclusively through CoreMIDI — macOS's Bluetooth MIDI driver handles
/// the BLE-MIDI service connection.
@Observable
@MainActor
final class AppCoordinator {
    let state = OrthoRemoteState()
    private var bluetoothManager: BluetoothManager?
    private var coreMIDIManager: CoreMIDIManager?
    private let mediaController = MediaKeyController()
    private let volumeController = SystemVolumeController()
    private let roonController = RoonController()
    private var roonStatusTask: Task<Void, Never>?

    init() {
        // Check accessibility permission (prompts on first launch)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        state.accessibilityGranted = AXIsProcessTrustedWithOptions(options)

        // Check launch-at-login status
        state.launchAtLogin = SMAppService.mainApp.status == .enabled

        // Restore control mode
        if let saved = UserDefaults.standard.string(forKey: "OrthoRemote_ControlMode"),
           let mode = ControlMode(rawValue: saved)
        {
            state.controlMode = mode
        }

        // CoreMIDI for receiving MIDI events
        let midi = CoreMIDIManager()
        midi.onMIDIEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleMIDIEvent(event)
            }
        }
        midi.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                if connected {
                    self?.bluetoothManager?.markConnected()
                    self?.state.midiSourceOnline = true
                    log.info("CoreMIDI source connected")
                } else {
                    self?.bluetoothManager?.markDisconnected()
                    self?.state.midiSourceOnline = false
                    log.info("CoreMIDI source disconnected")
                }
            }
        }
        coreMIDIManager = midi

        // Bluetooth for BLE connection + MIDI driver activation
        let manager = BluetoothManager(state: state)
        manager.onMIDIActivated = { [weak self] in
            // Give the MIDI driver a moment to bring the source online
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.coreMIDIManager?.connectToOrthoRemote()
            }
        }
        bluetoothManager = manager

        // Read initial volume
        if let vol = volumeController.getVolume() {
            state.currentVolume = vol
            log.info("Initial volume: \(vol)")
        }

        // Listen for sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self?.bluetoothManager?.reconnect()
                self?.coreMIDIManager?.connectToOrthoRemote()
            }
        }

        // Start Roon status polling if in Roon mode
        if state.controlMode == .roon {
            startRoonStatusPolling()
        }
    }

    func connect() {
        bluetoothManager?.reconnect()
        coreMIDIManager?.connectToOrthoRemote()
    }

    func disconnect() {
        bluetoothManager?.disconnect()
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            state.launchAtLogin = enabled
        } catch {
            log.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }

    func setControlMode(_ mode: ControlMode) {
        state.controlMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "OrthoRemote_ControlMode")

        if mode == .roon {
            startRoonStatusPolling()
        } else {
            stopRoonStatusPolling()
            state.roonConnected = false
            state.roonZoneName = nil
        }
    }

    // MARK: - Roon Status Polling

    private func startRoonStatusPolling() {
        stopRoonStatusPolling()
        roonStatusTask = Task { @MainActor in
            while !Task.isCancelled {
                let status = await roonController.checkStatus()
                if let status {
                    log.debug("Roon poll: connected=\(status.connected) zone=\(status.zoneName ?? "nil")")
                    state.roonConnected = status.connected
                    state.roonZoneName = status.zoneName
                } else {
                    log.debug("Roon poll: unreachable")
                    state.roonConnected = false
                    state.roonZoneName = nil
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopRoonStatusPolling() {
        roonStatusTask?.cancel()
        roonStatusTask = nil
    }

    // MARK: - MIDI Event Handling

    private func handleMIDIEvent(_ event: MIDIEvent) {
        // Mark as connected if we're receiving MIDI
        if state.connectionStatus != .connected {
            bluetoothManager?.markConnected()
        }

        switch event {
        case .controlChange(let channel, let controller, let value):
            log.debug("CC: ch=\(channel) cc=\(controller) val=\(value)")

            if state.controlMode == .roon {
                handleVolumeRoon(value: value)
            } else {
                handleVolumeSystem(value: value)
            }

        case .noteOn(let channel, let note, let velocity):
            log.debug("NoteOn: ch=\(channel) note=\(note) vel=\(velocity)")
            if state.controlMode == .roon {
                roonController.sendCommand("play_pause")
            } else {
                mediaController.sendPlayPause()
            }

        case .noteOff(let channel, let note, let velocity):
            log.debug("NoteOff: ch=\(channel) note=\(note) vel=\(velocity)")
        }
    }

    private func handleVolumeRoon(value: UInt8) {
        // Relative CC mode: 1-63 = clockwise, 65-127 = counter-clockwise
        if value >= 1 && value <= 63 {
            roonController.sendCommand("volume_up", count: Int(value))
        } else if value >= 65 && value <= 127 {
            let steps = 128 - Int(value)
            roonController.sendCommand("volume_down", count: steps)
        }
    }

    private func handleVolumeSystem(value: UInt8) {
        // Re-check accessibility (user may have granted since launch)
        let accessible = AXIsProcessTrusted()
        if accessible != state.accessibilityGranted {
            state.accessibilityGranted = accessible
        }

        // Relative CC mode: 1-63 = clockwise, 65-127 = counter-clockwise
        if accessible {
            // Media key simulation: changes volume AND shows native HUD
            if value >= 1 && value <= 63 {
                for _ in 0..<Int(value) {
                    mediaController.sendVolumeUp()
                }
            } else if value >= 65 && value <= 127 {
                let steps = 128 - Int(value)
                for _ in 0..<steps {
                    mediaController.sendVolumeDown()
                }
            }

            // Read back volume after media key events process
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                if let vol = self.volumeController.getVolume() {
                    self.state.currentVolume = vol
                }
            }
        } else {
            // Fallback: direct CoreAudio (no HUD but no permissions needed)
            if value >= 1 && value <= 63 {
                for _ in 0..<Int(value) {
                    volumeController.increment()
                }
            } else if value >= 65 && value <= 127 {
                let steps = 128 - Int(value)
                for _ in 0..<steps {
                    volumeController.decrement()
                }
            }

            if let vol = volumeController.getVolume() {
                state.currentVolume = vol
            }
        }
    }
}

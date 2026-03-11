@preconcurrency import CoreBluetooth
import CoreMIDI
import Foundation
import os

private let log = Logger(subsystem: "com.ericanderson.OrthoControl", category: "Bluetooth")

/// Manages BLE connection to the ORTHO Remote and activates the Bluetooth MIDI driver.
///
/// Flow:
/// 1. Scan for the ORTHO Remote by name
/// 2. Connect via CBCentralManager
/// 3. Call MIDIBluetoothDriverActivateAllConnections() to tell macOS's Bluetooth MIDI
///    driver to activate the BLE-MIDI service — this brings the CoreMIDI source online
/// 4. CoreMIDIManager picks up the online source and receives MIDI events
///
/// We do NOT discover services or subscribe to characteristics — the system MIDI driver
/// handles all BLE-MIDI communication once activated.
@Observable
@MainActor
final class BluetoothManager: NSObject, CBCentralManagerDelegate {
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var userRequestedDisconnect = false

    private(set) var state: OrthoRemoteState

    /// Called after MIDIBluetoothDriverActivateAllConnections() succeeds
    var onMIDIActivated: (() -> Void)?

    init(state: OrthoRemoteState) {
        self.state = state
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log.warning("Cannot scan: Bluetooth not powered on (state: \(self.centralManager.state.rawValue))")
            return
        }

        state.connectionStatus = .scanning

        // Scan without service filter to find the ORTHO Remote by name
        log.info("Scanning for ORTHO Remote...")
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Stop scanning after 15 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if state.connectionStatus == .scanning {
                centralManager.stopScan()
                log.info("Scan timed out after 15s")
                state.connectionStatus = .disconnected
            }
        }
    }

    func disconnect() {
        userRequestedDisconnect = true
        centralManager.stopScan()
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        state.connectionStatus = .disconnected
        state.deviceName = nil
    }

    func reconnect() {
        guard centralManager.state == .poweredOn else { return }
        guard connectedPeripheral == nil else { return }

        userRequestedDisconnect = false

        // Try to reconnect to previously known device
        if let uuidString = UserDefaults.standard.string(
            forKey: OrthoRemoteConstants.storedPeripheralUUIDKey),
            let uuid = UUID(uuidString: uuidString)
        {
            log.info("Attempting reconnect to stored peripheral")
            let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = peripherals.first {
                state.connectionStatus = .connecting
                connectedPeripheral = peripheral
                centralManager.connect(peripheral)

                // Timeout — fall back to scan
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    if state.connectionStatus == .connecting && connectedPeripheral === peripheral {
                        log.info("Stored peripheral reconnect timed out, falling back to scan")
                        centralManager.cancelPeripheralConnection(peripheral)
                        connectedPeripheral = nil
                        startScanning()
                    }
                }
                return
            }
        }

        startScanning()
    }

    /// Called by AppCoordinator when CoreMIDI receives its first MIDI event.
    func markConnected(deviceName: String? = nil) {
        state.connectionStatus = .connected
        state.deviceName = deviceName ?? state.deviceName ?? "ORTHO Remote"
    }

    /// Called by AppCoordinator when CoreMIDI loses the MIDI source.
    func markDisconnected() {
        if state.connectionStatus == .connected {
            state.connectionStatus = .disconnected
        }
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            log.info("Bluetooth state changed: \(central.state.rawValue)")
            switch central.state {
            case .poweredOn:
                if !userRequestedDisconnect {
                    reconnect()
                }
            case .poweredOff, .unauthorized, .unsupported:
                connectedPeripheral = nil
                state.connectionStatus = .disconnected
            case .resetting:
                log.info("Bluetooth resetting — clearing stale peripheral")
                connectedPeripheral = nil
                state.connectionStatus = .disconnected
            case .unknown:
                log.info("Bluetooth state unknown — waiting")
            @unknown default:
                log.info("Unhandled Bluetooth state: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name =
            peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""

        guard name.lowercased().contains(OrthoRemoteConstants.advertisedName) else { return }

        MainActor.assumeIsolated {
            log.info("Found ORTHO Remote: '\(name, privacy: .public)' RSSI: \(RSSI)")
            centralManager.stopScan()
            state.connectionStatus = .connecting
            state.deviceName = name

            connectedPeripheral = peripheral
            centralManager.connect(peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didConnect peripheral: CBPeripheral
    ) {
        MainActor.assumeIsolated {
            log.info("Connected to: \(peripheral.name ?? "unknown") (\(peripheral.identifier))")
            state.connectionStatus = .connecting
            state.deviceName = peripheral.name ?? "ORTHO Remote"

            // Store for reconnection
            UserDefaults.standard.set(
                peripheral.identifier.uuidString,
                forKey: OrthoRemoteConstants.storedPeripheralUUIDKey
            )

            // KEY: Activate the Bluetooth MIDI driver for all connected BLE devices.
            // This tells macOS to bring the BLE-MIDI service online as a CoreMIDI source.
            let status = MIDIBluetoothDriverActivateAllConnections()
            log.info("MIDIBluetoothDriverActivateAllConnections() returned: \(status)")

            if status == noErr {
                log.info("Bluetooth MIDI driver activated — CoreMIDI should pick up the source")
            } else {
                log.error("Failed to activate Bluetooth MIDI driver: \(status)")
            }

            // Notify AppCoordinator to rescan CoreMIDI sources
            onMIDIActivated?()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            log.error("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
            connectedPeripheral = nil
            state.connectionStatus = .disconnected

            if !userRequestedDisconnect {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self.reconnect()
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            log.info("Disconnected: \(error?.localizedDescription ?? "clean disconnect")")
            connectedPeripheral = nil

            if !userRequestedDisconnect {
                // Auto-reconnect
                state.connectionStatus = .connecting
                connectedPeripheral = peripheral
                centralManager.connect(peripheral)
            } else {
                state.connectionStatus = .disconnected
                state.deviceName = nil
            }
        }
    }
}

import CoreMIDI
import Foundation
import os

private let log = Logger(subsystem: "com.ericanderson.OrthoControl", category: "CoreMIDI")

/// Receives MIDI events from the ORTHO Remote via macOS CoreMIDI.
/// Uses two strategies:
/// 1. Standard MIDIGetSource() for online sources
/// 2. Direct entity source connection for offline Bluetooth MIDI devices
final class CoreMIDIManager: @unchecked Sendable {
    private var midiClient = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var rescanTimer: Timer?
    private var rescanCount = 0

    // Protected by `lock` — accessed from CoreMIDI threads and main thread
    private let lock = NSLock()
    private var _connectedSource: MIDIEndpointRef = 0
    private var _onMIDIEvent: (@Sendable (MIDIEvent) -> Void)?
    private var _onConnectionChange: (@Sendable (_ connected: Bool) -> Void)?

    private var connectedSource: MIDIEndpointRef {
        get { lock.withLock { _connectedSource } }
        set { lock.withLock { _connectedSource = newValue } }
    }

    var onMIDIEvent: (@Sendable (MIDIEvent) -> Void)? {
        get { lock.withLock { _onMIDIEvent } }
        set { lock.withLock { _onMIDIEvent = newValue } }
    }

    var onConnectionChange: (@Sendable (_ connected: Bool) -> Void)? {
        get { lock.withLock { _onConnectionChange } }
        set { lock.withLock { _onConnectionChange = newValue } }
    }

    init() {
        setupMIDI()
    }

    deinit {
        rescanTimer?.invalidate()
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }

    // MARK: - Setup

    private func setupMIDI() {
        // Force CoreMIDI to refresh its device list
        MIDIRestart()

        // Create MIDI client
        var status = MIDIClientCreateWithBlock(
            "OrthoControl" as CFString, &midiClient
        ) { [weak self] notification in
            self?.handleMIDINotification(notification)
        }

        guard status == noErr else {
            log.error("Failed to create MIDI client: \(status)")
            return
        }
        log.info("MIDI client created")

        // Create input port
        status = MIDIInputPortCreateWithProtocol(
            midiClient,
            "OrthoControl Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, _ in
            self?.handleMIDIEventList(eventList)
        }

        guard status == noErr else {
            log.error("Failed to create MIDI input port: \(status)")
            return
        }
        log.info("MIDI input port created")

        // Log all MIDI devices for diagnostics
        logMIDIDiagnostics()

        // Try to connect to ORTHO Remote
        connectToOrthoRemote()

        // Start periodic rescanning
        startPeriodicRescan()
    }

    // MARK: - Source Discovery

    func connectToOrthoRemote() {
        // Strategy 1: Check online sources (standard approach)
        let sourceCount = MIDIGetNumberOfSources()
        log.info("Scanning \(sourceCount) online MIDI source(s)...")

        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let name = getMIDIEndpointName(source)
            log.info("  Online Source \(i): '\(name, privacy: .public)'")

            if name.lowercased().contains("ortho") {
                log.info("  -> Found ORTHO Remote online source!")
                connectToSource(source)
                return
            }
        }

        // Strategy 2: Look for offline "ortho remote" devices and connect to their entity sources
        // This can activate Bluetooth MIDI devices that are paired but not currently online
        let deviceCount = MIDIGetNumberOfDevices()
        log.info("Checking \(deviceCount) MIDI device(s) for offline ortho remote...")

        for i in 0..<deviceCount {
            let device = MIDIGetDevice(i)
            let name = getMIDIObjectName(device)

            guard name.lowercased().contains("ortho") else { continue }

            let entityCount = MIDIDeviceGetNumberOfEntities(device)
            log.info("  Device '\(name, privacy: .public)' has \(entityCount) entities")

            for j in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, j)
                let entityName = getMIDIObjectName(entity)
                let srcCount = MIDIEntityGetNumberOfSources(entity)

                log.info("    Entity '\(entityName, privacy: .public)': \(srcCount) source(s)")

                if srcCount > 0 {
                    let source = MIDIEntityGetSource(entity, 0)
                    let sourceName = getMIDIEndpointName(source)
                    log.info("    -> Trying entity source: '\(sourceName, privacy: .public)' (ref: \(source))")

                    if source != 0 {
                        let connectStatus = MIDIPortConnectSource(inputPort, source, nil)
                        if connectStatus == noErr {
                            connectedSource = source
                            log.info("    -> Connected to entity source '\(sourceName, privacy: .public)' successfully!")
                            return
                        } else {
                            log.warning("    -> Failed to connect to entity source: \(connectStatus)")
                        }
                    }
                }
            }
        }

        log.info("ORTHO Remote not available via online sources or device entities (will retry)")
    }

    private func connectToSource(_ source: MIDIEndpointRef) {
        // Disconnect from previous source
        if connectedSource != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
        }

        let status = MIDIPortConnectSource(inputPort, source, nil)
        if status == noErr {
            connectedSource = source
            let name = getMIDIEndpointName(source)
            log.info("Connected to MIDI source: '\(name, privacy: .public)'")
            onConnectionChange?(true)
        } else {
            log.error("Failed to connect to MIDI source: \(status)")
        }
    }

    // MARK: - Periodic Rescan

    private func startPeriodicRescan() {
        rescanCount = 0
        rescanTimer?.invalidate()

        DispatchQueue.main.async { [weak self] in
            self?.rescanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }

                self.rescanCount += 1

                // If already connected, just verify it's still valid
                if self.connectedSource != 0 {
                    return
                }

                // After 40 attempts (2 minutes), slow down
                if self.rescanCount == 40 {
                    timer.invalidate()
                    log.info("Switching to slow MIDI rescan (every 30s)")
                    self.rescanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                        guard let self, self.connectedSource == 0 else { return }
                        self.connectToOrthoRemote()
                    }
                    return
                }

                self.connectToOrthoRemote()
            }
        }
    }

    // MARK: - MIDI Data Handling

    private func handleMIDIEventList(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        eventListPtr.unsafeSequence().forEach { event in
            let wordCount = Int(event.pointee.wordCount)
            guard wordCount > 0 else { return }

            let words = UnsafeRawBufferPointer(
                start: UnsafeRawPointer(event) + MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!,
                count: wordCount * MemoryLayout<UInt32>.size
            )

            for i in 0..<wordCount {
                let word = words.load(fromByteOffset: i * MemoryLayout<UInt32>.size, as: UInt32.self)
                parseMIDI1Word(word)
            }
        }
    }

    private func parseMIDI1Word(_ word: UInt32) {
        let messageType = (word >> 28) & 0xF
        let statusByte = UInt8((word >> 16) & 0xFF)
        let data1 = UInt8((word >> 8) & 0xFF)
        let data2 = UInt8(word & 0xFF)

        let hex = String(format: "%08X", word)
        log.debug("MIDI word: 0x\(hex, privacy: .public) type=\(messageType) status=\(String(format: "0x%02X", statusByte), privacy: .public) d1=\(data1) d2=\(data2)")

        guard messageType == 0x2 else { return }

        let statusType = statusByte & 0xF0
        let channel = statusByte & 0x0F

        switch statusType {
        case 0xB0:  // Control Change
            let event = MIDIEvent.controlChange(channel: channel, controller: data1, value: data2)
            onMIDIEvent?(event)

        case 0x90:  // Note On
            if data2 == 0 {
                onMIDIEvent?(.noteOff(channel: channel, note: data1, velocity: 0))
            } else {
                onMIDIEvent?(.noteOn(channel: channel, note: data1, velocity: data2))
            }

        case 0x80:  // Note Off
            onMIDIEvent?(.noteOff(channel: channel, note: data1, velocity: data2))

        default:
            break
        }
    }

    // MARK: - MIDI Notifications

    private func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        let type = notification.pointee.messageID

        switch type {
        case .msgSetupChanged:
            log.info("MIDI setup changed, rescanning...")
            logMIDIDiagnostics()
            connectToOrthoRemote()

        case .msgObjectAdded:
            log.info("MIDI object added, rescanning...")
            logMIDIDiagnostics()
            connectToOrthoRemote()

        case .msgObjectRemoved:
            log.info("MIDI object removed")
            if connectedSource != 0 {
                let sourceCount = MIDIGetNumberOfSources()
                var found = false
                for i in 0..<sourceCount {
                    if MIDIGetSource(i) == connectedSource {
                        found = true
                        break
                    }
                }
                if !found {
                    log.info("Connected MIDI source was removed, will retry")
                    connectedSource = 0
                    onConnectionChange?(false)
                    connectToOrthoRemote()
                }
            }

        default:
            break
        }
    }

    // MARK: - Diagnostics

    private func logMIDIDiagnostics() {
        let sourceCount = MIDIGetNumberOfSources()
        let destCount = MIDIGetNumberOfDestinations()
        let deviceCount = MIDIGetNumberOfDevices()
        let extDeviceCount = MIDIGetNumberOfExternalDevices()

        log.info("=== MIDI Diagnostics ===")
        log.info("Sources: \(sourceCount), Destinations: \(destCount), Devices: \(deviceCount), External: \(extDeviceCount)")

        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let name = getMIDIEndpointName(source)
            log.info("  Online Source \(i): '\(name, privacy: .public)' (ref: \(source))")
        }

        for i in 0..<deviceCount {
            let device = MIDIGetDevice(i)
            let name = getMIDIObjectName(device)
            let entityCount = MIDIDeviceGetNumberOfEntities(device)

            // Check online status
            var isOnline: Int32 = 0
            MIDIObjectGetIntegerProperty(device, kMIDIPropertyOffline, &isOnline)

            let statusStr = isOnline == 0 ? "online" : "offline"
            log.info("  Device \(i): '\(name, privacy: .public)' (\(entityCount) entities, \(statusStr, privacy: .public))")

            for j in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, j)
                let entityName = getMIDIObjectName(entity)
                let srcCount = MIDIEntityGetNumberOfSources(entity)
                let dstCount = MIDIEntityGetNumberOfDestinations(entity)

                var entityOffline: Int32 = 0
                MIDIObjectGetIntegerProperty(entity, kMIDIPropertyOffline, &entityOffline)
                let entityStatus = entityOffline == 0 ? "online" : "offline"

                log.info("    Entity \(j): '\(entityName, privacy: .public)' (src: \(srcCount), dst: \(dstCount), \(entityStatus, privacy: .public))")

                for k in 0..<srcCount {
                    let source = MIDIEntityGetSource(entity, k)
                    let srcName = getMIDIEndpointName(source)
                    var srcOffline: Int32 = 0
                    MIDIObjectGetIntegerProperty(source, kMIDIPropertyOffline, &srcOffline)
                    let srcStatus = srcOffline == 0 ? "online" : "offline"
                    log.info("      Source \(k): '\(srcName, privacy: .public)' ref=\(source) \(srcStatus, privacy: .public)")
                }
            }
        }

        log.info("========================")
    }

    // MARK: - Helpers

    private func getMIDIEndpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        if status == noErr, let cfName = name?.takeRetainedValue() {
            return cfName as String
        }
        return "Unknown"
    }

    private func getMIDIObjectName(_ obj: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(obj, kMIDIPropertyName, &name)
        if status == noErr, let cfName = name?.takeRetainedValue() {
            return cfName as String
        }
        return "Unknown"
    }
}

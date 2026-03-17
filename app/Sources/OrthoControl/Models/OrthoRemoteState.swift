import SwiftUI

@Observable
@MainActor
final class OrthoRemoteState {
    var connectionStatus: ConnectionStatus = .disconnected
    var currentVolume: Float = 0.0
    var deviceName: String? = nil
    var midiSourceOnline = false
    var accessibilityGranted = false
    var launchAtLogin = false

    // Control mode
    var controlMode: ControlMode = .system
    var roonConnected = false
    var roonZoneName: String?
    var roonSelectedZoneId: String?
    var roonZones: [RoonZone] = []

    var volumePercent: Int {
        Int(currentVolume * 100)
    }
}

struct RoonZone: Identifiable, Sendable {
    let zone_id: String
    let display_name: String
    let state: String?

    var id: String { zone_id }
}

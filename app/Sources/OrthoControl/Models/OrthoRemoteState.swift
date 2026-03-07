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

    var volumePercent: Int {
        Int(currentVolume * 100)
    }
}

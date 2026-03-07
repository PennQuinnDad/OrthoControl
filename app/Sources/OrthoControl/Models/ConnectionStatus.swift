import SwiftUI

enum ConnectionStatus: String, Sendable {
    case disconnected = "Disconnected"
    case scanning = "Scanning..."
    case connecting = "Connecting..."
    case connected = "Connected"

    var color: Color {
        switch self {
        case .connected: .green
        case .scanning, .connecting: .yellow
        case .disconnected: .red
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: "antenna.radiowaves.left.and.right.slash"
        case .scanning, .connecting: "antenna.radiowaves.left.and.right"
        case .connected: "dial.high.fill"
        }
    }
}

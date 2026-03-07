import AppKit
import CoreGraphics

/// Simulates media key presses via CGEvent.
@MainActor
final class MediaKeyController {
    // NX_KEYTYPE constants for media keys
    private static let playPauseKeyCode: UInt32 = 16  // NX_KEYTYPE_PLAY
    private static let volumeUpKeyCode: UInt32 = 0  // NX_KEYTYPE_SOUND_UP
    private static let volumeDownKeyCode: UInt32 = 1  // NX_KEYTYPE_SOUND_DOWN

    func sendPlayPause() {
        sendMediaKey(keyCode: Self.playPauseKeyCode)
    }

    /// Send a fine-grained volume up (1/64 step) by simulating Opt+Shift+VolumeUp
    func sendVolumeUp() {
        sendMediaKey(keyCode: Self.volumeUpKeyCode, optionShift: true)
    }

    /// Send a fine-grained volume down (1/64 step) by simulating Opt+Shift+VolumeDown
    func sendVolumeDown() {
        sendMediaKey(keyCode: Self.volumeDownKeyCode, optionShift: true)
    }

    private func sendMediaKey(keyCode: UInt32, optionShift: Bool = false) {
        // Base flags: 0xa00 for key down, 0xb00 for key up
        // Add Option (0x080000) + Shift (0x020000) for fine-grained volume
        let extraFlags: UInt = optionShift ? 0x0A_0000 : 0

        // Key down
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00 | extraFlags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xa << 8)),
            data2: -1
        )
        keyDown?.cgEvent?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00 | extraFlags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xb << 8)),
            data2: -1
        )
        keyUp?.cgEvent?.post(tap: .cghidEventTap)
    }
}

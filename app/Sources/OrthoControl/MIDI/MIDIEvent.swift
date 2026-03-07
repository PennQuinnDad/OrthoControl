/// Represents a parsed MIDI event from CoreMIDI.
enum MIDIEvent: Sendable {
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
}

import CoreAudio
import Foundation

/// Controls macOS system output volume via CoreAudio.
@MainActor
final class SystemVolumeController {
    /// Volume step size: 1/64 for fine-grained control (same as Alt+Shift+Volume)
    private let stepSize: Float = 1.0 / 64.0

    // 'vmvc' — the virtual main volume property selector
    private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    // MARK: - Public API

    func getVolume() -> Float? {
        guard let deviceID = getDefaultOutputDevice() else { return nil }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &volume
        )

        return status == noErr ? volume : nil
    }

    func setVolume(_ value: Float) {
        guard let deviceID = getDefaultOutputDevice() else { return }

        var volume = max(0.0, min(1.0, value))
        let size = UInt32(MemoryLayout<Float32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, size, &volume
        )
    }

    func increment() {
        guard let current = getVolume() else { return }
        setVolume(current + stepSize)
    }

    func decrement() {
        guard let current = getVolume() else { return }
        setVolume(current - stepSize)
    }

    // MARK: - Private

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )

        return status == noErr ? deviceID : nil
    }
}

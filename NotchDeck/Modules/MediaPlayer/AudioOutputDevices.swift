import CoreAudio
import Foundation

nonisolated struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case builtIn, bluetooth, airPlay, other }

    let id: AudioDeviceID
    let name: String
    let kind: Kind

    var symbolName: String {
        switch kind {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .airPlay: "airplayaudio"
        case .other: "hifispeaker"
        }
    }
}

/// System output device list and selection via CoreAudio (the "output device picker").
nonisolated enum AudioOutputDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioOutputDevice] {
        var devicesAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streamsAddress = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 else {
                return nil // input-only device
            }

            var nameAddress = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let deviceName = name?.takeRetainedValue() as String? else { return nil }

            var transportAddress = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            let kind: AudioOutputDevice.Kind = switch transport {
            case kAudioDeviceTransportTypeBuiltIn: .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
            case kAudioDeviceTransportTypeAirPlay: .airPlay
            default: .other
            }
            return AudioOutputDevice(id: id, name: deviceName, kind: kind)
        }
    }

    static func defaultDeviceID() -> AudioDeviceID? {
        var defaultAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &defaultAddress, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefault(_ id: AudioDeviceID) -> Bool {
        var defaultAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var newID = id
        return AudioObjectSetPropertyData(
            system, &defaultAddress, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &newID
        ) == noErr
    }
}

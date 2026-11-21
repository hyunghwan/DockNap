import CoreAudio
import Foundation

enum ChimeOutput {
    /// Never substitute headphones, a dock, or the system default for the Mac's own speakers.
    static func builtInSpeakerUID() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let scope = kAudioObjectPropertyScopeOutput
        for device in values(system, kAudioHardwarePropertyDevices) {
            guard values(device, kAudioDevicePropertyTransportType).first == kAudioDeviceTransportTypeBuiltIn
            else { continue }
            // Apple built-in drivers can report an unknown stream terminal but select "ispk"
            // as their current output source. A switched headphone jack has a different source.
            let isSpeaker: Bool
            if let source = values(device, kAudioDevicePropertyDataSource, scope).first {
                isSpeaker = source == 0x6973706B // "ispk"
            } else {
                let streams = values(device, kAudioDevicePropertyStreams, scope)
                isSpeaker = !streams.isEmpty && streams.allSatisfy {
                    values($0, kAudioStreamPropertyTerminalType).first == kAudioStreamTerminalTypeSpeaker
                }
            }
            guard isSpeaker else { continue }
            if values(device, kAudioDevicePropertyMute, scope).first == 1 { return nil }
            if let volume = values(device, kAudioDevicePropertyVolumeScalar, scope).first,
               Float(bitPattern: volume) == 0 { return nil }
            return deviceUID(device)
        }
        return nil
    }

    private static func values(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size.isMultiple(of: 4) else { return [] }
        var words = [UInt32](repeating: 0, count: Int(size) / 4)
        let status = words.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(words.prefix(Int(size) / 4)) : []
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

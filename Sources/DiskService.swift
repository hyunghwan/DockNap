import DiskArbitration
import Foundation
import IOKit

struct ExternalVolume {
    let id: String
    let sessionID: String
    let name: String
    let isMounted: Bool
    let isAmbiguous: Bool
    let deviceName: String
}

/// All calls and callbacks run on the main run loop. An attachment ID changes when
/// a device is unplugged, even if macOS reassigns the same BSD name to its replacement.
final class DiskService {
    private struct Entry: Equatable {
        let uuid: String
        let attachment: UInt64
        let name: String
        let deviceName: String
        let mounted: Bool
    }

    private final class Reply {
        let finish: (Bool) -> Void
        init(_ finish: @escaping (Bool) -> Void) { self.finish = finish }
    }

    private let session = DASessionCreate(nil)
    private var entries: [String: Entry] = [:]
    private var onChange: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    var volumes: [ExternalVolume] {
        Dictionary(grouping: entries.values, by: \.uuid).values.compactMap { group in
            guard let entry = group.min(by: { $0.attachment < $1.attachment }) else { return nil }
            return ExternalVolume(id: entry.uuid, sessionID: String(entry.attachment),
                                  name: entry.name, isMounted: entry.mounted,
                                  isAmbiguous: group.count > 1, deviceName: entry.deviceName)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    @discardableResult
    func start(onChange: @escaping () -> Void) -> Bool {
        guard let session else { return false }
        if self.onChange != nil { self.onChange = onChange; return true }
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<DiskService>.fromOpaque(context).takeUnretainedValue().update(disk)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            Unmanaged<DiskService>.fromOpaque(context).takeUnretainedValue().update(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk) else { return }
            let service = Unmanaged<DiskService>.fromOpaque(context).takeUnretainedValue()
            if let entry = service.entries.removeValue(forKey: String(cString: name)) {
                service.onDisconnect?(entry.uuid)
                service.onChange?()
            }
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return true
    }

    deinit {
        if let session, onChange != nil {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }

    func unmount(_ id: String, completion: @escaping (Bool) -> Void) {
        setMounted(false, id: id, completion: completion)
    }

    func mount(_ id: String, completion: @escaping (Bool) -> Void) {
        setMounted(true, id: id, completion: completion)
    }

    private func setMounted(_ mount: Bool, id: String, completion: @escaping (Bool) -> Void) {
        let matches = entries.filter { $0.value.uuid == id }
        guard matches.count == 1, let (bsd, previous) = matches.first, let session,
              let disk = DADiskCreateFromBSDName(nil, session, bsd),
              let current = Self.inspect(disk), current.uuid == id,
              current.attachment == previous.attachment, current.mounted != mount else {
            completion(false)
            return
        }
        let reply = Reply { [weak self] success in
            // A delayed reply may arrive after this BSD name has been reused.
            guard let self, let live = DADiskCreateFromBSDName(nil, session, bsd),
                  let entry = self.update(live), entry.uuid == id,
                  entry.attachment == previous.attachment else {
                completion(false)
                return
            }
            completion(success)
        }
        let context = Unmanaged.passRetained(reply).toOpaque()
        let finished: DADiskMountCallback = { _, dissenter, context in
            guard let context else { return }
            Unmanaged<Reply>.fromOpaque(context).takeRetainedValue().finish(dissenter == nil)
        }
        if mount {
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), finished, context)
        } else {
            // No force, eject, or whole-disk flag: siblings and any busy volume stay mounted.
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), finished, context)
        }
    }

    @discardableResult
    private func update(_ disk: DADisk) -> Entry? {
        guard let name = DADiskGetBSDName(disk) else { return nil }
        let key = String(cString: name)
        let old = entries[key]
        let entry = Self.inspect(disk)
        guard old != entry else { return entry }
        entries[key] = entry
        if let old, let entry, old.attachment != entry.attachment {
            onDisconnect?(old.uuid)
        }
        onChange?()
        return entry
    }

    private static func inspect(_ disk: DADisk) -> Entry? {
        guard let d = DADiskCopyDescription(disk) as? [String: Any],
              d[kDADiskDescriptionVolumeMountableKey as String] as? Bool == true,
              d[kDADiskDescriptionVolumeNetworkKey as String] as? Bool != true,
              let value = d[kDADiskDescriptionVolumeUUIDKey as String],
              CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID(),
              let name = d[kDADiskDescriptionVolumeNameKey as String] as? String, !name.isEmpty
        else { return nil }

        let content = (d[kDADiskDescriptionMediaContentKey as String] as? String ?? "").uppercased()
        guard !["EFI", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"].contains(content) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        if let roles = IORegistryEntryCreateCFProperty(media, "Role" as CFString, nil, 0)?
            .takeRetainedValue() as? [String],
           roles.contains(where: { !["", "none", "backup"].contains($0.lowercased()) }) { return nil }

        let removable = d[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true
        let external = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false
        guard isPhysicalExternal(media, external: external, removable: removable) else { return nil }
        var attachment: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &attachment) == KERN_SUCCESS else { return nil }
        let uuid = CFUUIDCreateString(nil, (value as! CFUUID)) as String
        let model = (d[kDADiskDescriptionDeviceModelKey as String] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Entry(uuid: uuid.uppercased(), attachment: attachment, name: name,
                     deviceName: model, mounted: d[kDADiskDescriptionVolumePathKey as String] is URL)
    }

    private static func isPhysicalExternal(_ media: io_service_t, external: Bool, removable: Bool) -> Bool {
        // APFS presents synthesized volumes. Follow their I/O Service ancestors to the
        // underlying storage transport; disk images also expose ordinary mountable volumes.
        var node = media
        IOObjectRetain(node)
        var found = false
        while node != 0 {
            let current = node
            defer { IOObjectRelease(current) }
            var className = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(node, &className) == KERN_SUCCESS else { return false }
            let type = String(cString: className).lowercased()
            if type.contains("diskimage") || type.contains("hdix") ||
                ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(where: { (name: String) in
                    name.withCString { IOObjectConformsTo(current, $0) != 0 }
                }) {
                return false
            }
            if let properties = IORegistryEntryCreateCFProperty(node, "Protocol Characteristics" as CFString, nil, 0)?
                .takeRetainedValue() as? [String: Any],
               let bus = properties["Physical Interconnect"] as? String {
                let location = properties["Physical Interconnect Location"] as? String
                if ["File", "RAM", "Virtual"].contains(location ?? "") || bus == "Virtual Interface" { return false }
                let card = removable && bus == "Secure Digital"
                if location == "External" || card || (external && location != "Internal" && !bus.isEmpty) {
                    found = true
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            node = parent
        }
        return found
    }
}

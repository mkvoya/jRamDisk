import Foundation
import DiskArbitration
import IOKit
import Darwin

struct OwnedDisk: Codable, Equatable {
    let parentDisk: String
    let registryID: UInt64
    let bootSession: String
    let name: String
    let sizeMB: Int
    var volumeUUID: String?
    var id: String { "\(bootSession):\(registryID)" }
}

/// BSD disk numbers are reusable. An I/O Registry ID is tied to one live media
/// object; the boot-session UUID prevents reuse across reboots.
enum DiskIdentity {
    static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    static func registryID(_ device: String) -> UInt64? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(device)") else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS else { return nil }
        return id
    }

    static func matches(_ disk: OwnedDisk, boot: String?, registryID: UInt64?) -> Bool {
        boot != nil && registryID != nil && disk.bootSession == boot && disk.registryID == registryID
    }
}

struct DiskVolume: Equatable {
    let device: String
    let parent: String
    let uuid: String
    let name: String
    let mountPoint: String
}

struct DiskSnapshot {
    let devices: Set<String>
    let volumes: [DiskVolume]
    let volumeNames: Set<String>

    init(data: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw CommandFailure(message: "Invalid disk list returned by diskutil")
        }
        func names(in rows: [[String: Any]]) -> [String] {
            rows.flatMap { row -> [String] in
                let own = (row["VolumeName"] as? String).map { [$0] } ?? []
                return own + names(in: row["Partitions"] as? [[String: Any]] ?? [])
                    + names(in: row["APFSVolumes"] as? [[String: Any]] ?? [])
            }
        }
        volumeNames = Set(names(in: disks))
        devices = Set(disks.compactMap { $0["DeviceIdentifier"] as? String })
        var found: [DiskVolume] = []
        for disk in disks {
            // Never claim a container spanning multiple physical stores.
            guard let stores = disk["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
                  let store = stores.first?["DeviceIdentifier"] as? String,
                  let volumes = disk["APFSVolumes"] as? [[String: Any]] else { continue }
            let parent = store.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
            for volume in volumes {
                guard let device = volume["DeviceIdentifier"] as? String,
                      let uuid = volume["VolumeUUID"] as? String,
                      let name = volume["VolumeName"] as? String else { continue }
                found.append(DiskVolume(device: device, parent: parent, uuid: uuid, name: name,
                                        mountPoint: volume["MountPoint"] as? String ?? ""))
            }
        }
        self.volumes = found
    }
}

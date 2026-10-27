import Foundation

actor FakeDisks {
    var volumes: [DiskVolume] = []
    var parents: Set<String> = []
    var next = 90
    var calls: [[String]] = []
    var failList = false
    var failFormat = false
    var failEject = false
    var delay: UInt64 = 0
    var mutations = 0
    var maxMutations = 0

    func configure(failFormat: Bool = false, failEject: Bool = false, failList: Bool = false, delay: UInt64 = 0) {
        self.failList = failList
        self.failFormat = failFormat; self.failEject = failEject; self.delay = delay
    }
    func seed(_ volume: DiskVolume) { volumes.append(volume); parents.insert(volume.parent) }
    func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        calls.append(args)
        let mutation = args.first != "list"
        if mutation { mutations += 1; maxMutations = max(maxMutations, mutations) }
        defer { if mutation { mutations -= 1 } }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        var output = Data()
        switch args.first {
        case "list":
            if failList { throw CommandFailure(message: "temporary list failure") }
            var disks: [[String: Any]] = parents.sorted().map { ["DeviceIdentifier": $0] }
            for parent in parents.sorted() {
                let rows = volumes.filter { $0.parent == parent }.map {
                    ["DeviceIdentifier": $0.device, "VolumeUUID": $0.uuid, "VolumeName": $0.name, "MountPoint": $0.mountPoint]
                }
                disks.append(["DeviceIdentifier": "container-\(parent)", "APFSPhysicalStores": [["DeviceIdentifier": parent]], "APFSVolumes": rows])
            }
            output = try PropertyListSerialization.data(fromPropertyList: ["AllDisksAndPartitions": disks], format: .xml, options: 0)
        case "image":
            next += 1
            let parent = "disk\(next)"
            parents.insert(parent)
            output = Data("/dev/\(parent)\n".utf8)
        case "apfs":
            if failFormat { throw CommandFailure(message: "format failure details") }
            let parent = String(args[2].dropFirst(5))
            volumes.append(DiskVolume(device: "\(parent)s1", parent: parent, uuid: "uuid-\(parent)", name: args[3], mountPoint: "/Volumes/\(args[3])"))
            // Deliberately no English success phrase: exit status + plist must suffice.
            output = Data("完成".utf8)
        case "eject":
            if failEject { throw CommandFailure(message: "device busy") }
            let parent = String(args.last!.dropFirst(5))
            parents.remove(parent)
            volumes.removeAll { $0.parent == parent }
        default: fatalError("Unexpected command: \(args)")
        }
        return CommandResult(stdout: output, stderr: Data(), status: 0)
    }
    func replaceVolumeUUID() {
        volumes = volumes.map { DiskVolume(device: $0.device, parent: $0.parent, uuid: "replacement", name: $0.name, mountPoint: $0.mountPoint) }
    }
    func ejectCalls() -> [[String]] { calls.filter { $0.first == "eject" } }
}

final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var replacement: UInt64?
    func replace(with id: UInt64) { lock.lock(); replacement = id; lock.unlock() }
    func id(_ name: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return replacement ?? UInt64(name.dropFirst(4))
    }
}

@main
struct DiskManagerTests {
    @MainActor static func main() async throws {
        var suites: [String] = []
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        func manager(_ fake: FakeDisks, memory: Int = 1024, registry: Registry = Registry()) -> RamDiskManager {
            let suite = "jRamDisk.tests.\(UUID())"
            suites.append(suite)
            return RamDiskManager(defaults: UserDefaults(suiteName: suite)!, startAutomatically: false,
                                  physicalMemoryMB: memory, bootSession: "boot", registryID: { registry.id($0) },
                                  execute: { try await fake.run($0, $1) })
        }
        func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let owned = OwnedDisk(parentDisk: "disk91", registryID: 91, bootSession: "boot", name: "Test", sizeMB: 64, volumeUUID: "uuid")
        require(DiskIdentity.matches(owned, boot: "boot", registryID: 91), "Matching identity rejected")
        require(!DiskIdentity.matches(owned, boot: "new-boot", registryID: 91), "Old boot accepted")
        require(!DiskIdentity.matches(owned, boot: "boot", registryID: 92), "Reused BSD number accepted")
        require(!DiskIdentity.matches(owned, boot: nil, registryID: 91), "Unknown boot accepted")
        for name in ["", "..", "a/b", "a:b", "bad\u{00}name", String(repeating: "界", count: 86)] {
            require((try? RamDiskManager.validatedName(name, sizeMB: 64)) == nil, "Invalid name accepted")
        }
        require((try? RamDiskManager.validatedName(" Valid ", sizeMB: 64)) == "Valid", "Name not normalized")
        require((try? RamDiskManager.validatedName("Valid", sizeMB: Int.max)) == nil, "Overflow-sized disk accepted")

        let fake = FakeDisks(), registry = Registry()
        let m = manager(fake, registry: registry)
        require(await m.createRamDisk(name: "Test", sizeMB: 128), "Creation failed")
        let disk = m.ramDisks[0]
        await m.refreshRamDisks()
        require(m.ramDisks[0].id == disk.id, "Refresh changed identity")
        require(!(await m.createRamDisk(name: "Test", sizeMB: 128)), "Duplicate name accepted")
        registry.replace(with: 999)
        require(!(await m.removeRamDisk(disk)), "Reused device ejected")
        require(await fake.ejectCalls().isEmpty, "Destructive command ran before identity verification")

        let busyFake = FakeDisks(), busy = manager(busyFake)
        require(await busy.createRamDisk(name: "Busy", sizeMB: 64), "Setup failed")
        await busyFake.configure(failEject: true)
        require(!(await busy.removeRamDisk(busy.ramDisks[0])), "Busy eject succeeded")
        let ejects = await busyFake.ejectCalls()
        require(ejects.count == 1 && !ejects[0].contains("force"), "Automatic force eject attempted")
        require(busy.errorMessage?.contains("device busy") == true, "Useful error discarded")

        let changedFake = FakeDisks(), changed = manager(changedFake)
        require(await changed.createRamDisk(name: "Changed", sizeMB: 64), "Setup failed")
        let changedDisk = changed.ramDisks[0]
        await changedFake.replaceVolumeUUID()
        require(!(await changed.removeRamDisk(changedDisk)), "Changed volume UUID accepted")
        require(await changedFake.ejectCalls().isEmpty, "Changed volume was ejected")

        let transientFake = FakeDisks(), transient = manager(transientFake)
        require(await transient.createRamDisk(name: "Transient", sizeMB: 64), "Setup failed")
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeFailure = transient.ramDisks
        await transientFake.configure(failList: true)
        await transient.refreshRamDisks()
        require(transient.ramDisks == beforeFailure && transient.allocatedMB == 64, "Query error discarded ownership")

        let cleanFake = FakeDisks(), clean = manager(cleanFake)
        await cleanFake.configure(failFormat: true)
        require(!(await clean.createRamDisk(name: "Cleanup", sizeMB: 64)), "Failed format accepted")
        let cleanupCalls = await cleanFake.ejectCalls()
        require(clean.allocatedMB == 0 && cleanupCalls.count == 1, "New device not cleaned up")

        let rollbackFake = FakeDisks(), rollback = manager(rollbackFake)
        await rollbackFake.configure(failFormat: true, failEject: true)
        require(!(await rollback.createRamDisk(name: "Broken", sizeMB: 64)), "Failed format accepted")
        require(rollback.allocatedMB == 64, "Failed cleanup lost device ownership")
        require(rollback.errorMessage?.contains("Cleanup failed") == true, "Cleanup error hidden")

        let concurrentFake = FakeDisks(), concurrent = manager(concurrentFake)
        await concurrentFake.configure(delay: 10_000_000)
        async let first = concurrent.createRamDisk(name: "RamDisk", sizeMB: 256, chooseUniqueName: true)
        async let second = concurrent.createRamDisk(name: "RamDisk", sizeMB: 256, chooseUniqueName: true)
        let results = await (first, second)
        require(results.0 && results.1, "Queued creation failed")
        require(Set(concurrent.ramDisks.map(\.volumeName)) == ["RamDisk", "RamDisk 2"], "Quick-create names collide")
        require(await concurrentFake.maxMutations == 1, "Mutations ran concurrently")
        require(!(await concurrent.createRamDisk(name: "TooMuch", sizeMB: 64)), "Total memory cap bypassed")
        require(concurrent.allocatedMB == 512, "Memory budget incorrect")
        print("Disk identity, lifecycle, validation and concurrency tests passed")
    }
}

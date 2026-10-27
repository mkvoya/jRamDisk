//
//  RamDiskManager.swift
//  jRamDisk
//
//  Handles RAM disk creation, removal, and status monitoring
//

import Foundation
import Combine
import ServiceManagement
import AppKit

// Configuration for auto-creating RAM disks at login
struct AutoCreateConfig: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let sizeMB: Int
    
    var formattedSize: String {
        if sizeMB >= 1024 {
            return "\(sizeMB / 1024) GB"
        }
        return "\(sizeMB) MB"
    }
}

struct RamDisk: Identifiable, Equatable {
    let id: String
    let ownershipID: String
    let deviceNode: String
    let parentDisk: String
    let volumeName: String
    let size: UInt64
    let mountPoint: String
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory) }
}

@MainActor
class RamDiskManager: ObservableObject {
    @Published var ramDisks: [RamDisk] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published private(set) var autoCreateConfigs: [AutoCreateConfig] = []
    @Published private(set) var launchAtLogin = false

    typealias Execute = @Sendable (String, [String]) async throws -> CommandResult
    private let execute: Execute
    private let registryID: @Sendable (String) -> UInt64?
    private let bootSession: String?
    private let defaults: UserDefaults
    let physicalMemoryMB: Int
    private var owned: [OwnedDisk] = []
    private let ownedKey = "com.jramdisk.ownedDisks.v2"
    private let autoCreateKey = "com.jramdisk.autoCreateConfigs"
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var refreshing = false
    private var generation = 0
    private var diskEvents: DiskEvents?
    private var refreshDebounce: Task<Void, Never>?
    private var showingEjectConfirmation = false
    private var canRetryForcedEject = false
    private var refreshPending = false
    private var refreshTimer: Timer?

    var allocatedMB: Int { owned.reduce(0) { $0 + $1.sizeMB } }
    var allocationLimitMB: Int { physicalMemoryMB / 2 }

    init(defaults: UserDefaults = .standard, startAutomatically: Bool = true,
         physicalMemoryMB: Int = Int(ProcessInfo.processInfo.physicalMemory / 1048576),
         bootSession: String? = DiskIdentity.bootSession(),
         registryID: @escaping @Sendable (String) -> UInt64? = { DiskIdentity.registryID($0) },
         execute: @escaping Execute = { try await CommandRunner().run($0, $1) }) {
        self.defaults = defaults
        self.physicalMemoryMB = physicalMemoryMB
        self.bootSession = bootSession
        self.registryID = registryID
        self.execute = execute
        if let data = defaults.data(forKey: ownedKey),
           let records = try? JSONDecoder().decode([OwnedDisk].self, from: data) {
            var seen = Set<String>()
            owned = records.filter {
                (64...8192).contains($0.sizeMB) && $0.parentDisk.range(of: #"^disk\d+$"#, options: .regularExpression) != nil
                    && DiskIdentity.matches($0, boot: bootSession, registryID: registryID($0.parentDisk))
                    && seen.insert($0.id).inserted
            }
        }
        loadAutoCreateConfigs()
        if startAutomatically {
            diskEvents = DiskEvents { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshRamDisks() }
            }
            Task {
                updateLaunchAtLoginStatus()
                await refreshRamDisks()
                await createAutoCreateDisks()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        refreshDebounce?.cancel()
    }

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            await self?.refreshRamDisks()
        }
    }

    func updateLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateLaunchAtLoginStatus()
            if enabled && !launchAtLogin {
                errorMessage = "Approve jRamDisk in System Settings → General → Login Items."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func loadAutoCreateConfigs() {
        if let data = defaults.data(forKey: autoCreateKey),
           let configs = try? JSONDecoder().decode([AutoCreateConfig].self, from: data) {
            var names = Set<String>()
            autoCreateConfigs = configs.filter { names.insert($0.name).inserted }
        }
    }

    func saveAutoCreateConfigs() {
        if let data = try? JSONEncoder().encode(autoCreateConfigs) { defaults.set(data, forKey: autoCreateKey) }
    }

    func addAutoCreateConfig(name: String, sizeMB: Int) {
        do {
            let name = try Self.validatedName(name, sizeMB: sizeMB)
            autoCreateConfigs.removeAll { $0.name == name }
            autoCreateConfigs.append(AutoCreateConfig(name: name, sizeMB: sizeMB))
            saveAutoCreateConfigs()
            successMessage = "'\(name)' will be created when jRamDisk starts"
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAutoCreateConfig(name: String) {
        autoCreateConfigs.removeAll { $0.name == name }
        saveAutoCreateConfigs()
    }

    func isAutoCreate(name: String) -> Bool { autoCreateConfigs.contains { $0.name == name } }

    func createAutoCreateDisks() async {
        var failures: [String] = []
        for config in autoCreateConfigs {
            if !ramDisks.contains(where: { $0.volumeName == config.name }) {
                if !(await createRamDisk(name: config.name, sizeMB: config.sizeMB)) {
                    failures.append("\(config.name): \(errorMessage ?? "Creation failed")")
                }
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    static func validatedName(_ name: String, sizeMB: Int) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"), !name.contains(":") else {
            throw CommandFailure(message: "Use a volume name of 1–255 UTF-8 bytes without slashes, colons or control characters.")
        }
        guard (64...8192).contains(sizeMB) else { throw CommandFailure(message: "RAM disk size must be between 64 MB and 8 GB.") }
        return name
    }

    private func acquireOperation() async {
        if isLoading { await withCheckedContinuation { waiters.append($0) } }
        else { isLoading = true }
        generation += 1
    }

    private func releaseOperation() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        else {
            isLoading = false
            Task { await refreshRamDisks() }
        }
    }

    private func persistOwnership() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(owned), data != defaults.data(forKey: ownedKey) {
            defaults.set(data, forKey: ownedKey)
        }
    }

    private func isCurrent(_ record: OwnedDisk) -> Bool {
        DiskIdentity.matches(record, boot: bootSession, registryID: registryID(record.parentDisk))
    }

    private func snapshot() async throws -> DiskSnapshot {
        try await DiskSnapshot(data: execute("/usr/sbin/diskutil", ["list", "-plist"]).stdout)
    }

    private func publish(_ snapshot: DiskSnapshot) {
        owned.removeAll { !snapshot.devices.contains($0.parentDisk) || !isCurrent($0) }
        persistOwnership()
        let disks = owned.flatMap { record -> [RamDisk] in
            let volumes = snapshot.volumes.filter { $0.parent == record.parentDisk && $0.uuid == record.volumeUUID }
            if volumes.isEmpty {
                // Retain an owned, unformatted or externally changed device for safe recovery.
                return [RamDisk(id: record.id, ownershipID: record.id, deviceNode: "/dev/\(record.parentDisk)",
                                parentDisk: record.parentDisk, volumeName: "\(record.name) (unavailable)",
                                size: UInt64(record.sizeMB) * 1048576, mountPoint: "")]
            }
            return volumes.map {
                RamDisk(id: "\(record.id):\($0.uuid)", ownershipID: record.id,
                        deviceNode: "/dev/\($0.device)", parentDisk: record.parentDisk,
                        volumeName: $0.name, size: UInt64(record.sizeMB) * 1048576, mountPoint: $0.mountPoint)
            }
        }.sorted { $0.id < $1.id }
        if disks != ramDisks { ramDisks = disks }
    }

    func refreshRamDisks() async {
        guard !isLoading, !refreshing else { refreshPending = true; return }
        updateLaunchAtLoginStatus()
        guard !owned.isEmpty else { ramDisks = []; return }
        refreshing = true
        refreshPending = false
        let revision = generation
        defer {
            refreshing = false
            if refreshPending && !isLoading { Task { await refreshRamDisks() } }
        }
        do {
            let current = try await snapshot()
            guard !isLoading, revision == generation else { refreshPending = true; return }
            publish(current)
        } catch {
            // A transient query failure must not discard the last known disks or ownership.
            errorMessage = "Could not refresh RAM disks: \(error.localizedDescription)"
        }
    }

    func createRamDisk(name: String, sizeMB: Int, chooseUniqueName: Bool = false) async -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        errorMessage = nil
        successMessage = nil
        var created: OwnedDisk?
        do {
            try Task.checkCancellation()
            var name = try Self.validatedName(name, sizeMB: sizeMB)
            guard let bootSession else { throw CommandFailure(message: "Cannot identify the current boot session; refusing to create a disk.") }
            let current = try await snapshot()
            publish(current)
            let existingNames = current.volumeNames.union(owned.map(\.name))
            if chooseUniqueName {
                let base = name
                var suffix = 2
                while existingNames.contains(name) { name = "\(base) \(suffix)"; suffix += 1 }
            } else if existingNames.contains(name) {
                throw CommandFailure(message: "A disk named '\(name)' already exists. Choose another name.")
            }
            guard allocatedMB + sizeMB <= allocationLimitMB else {
                throw CommandFailure(message: "RAM disks may use at most half of physical memory (\(allocationLimitMB) MB). Currently allocated: \(allocatedMB) MB.")
            }
            let result = try await execute("/usr/sbin/diskutil", ["image", "attach", "-noMount", "ram://\(sizeMB * 2048)"])
            guard let range = result.output.range(of: #"/dev/disk\d+\b"#, options: .regularExpression) else {
                throw CommandFailure(message: "Created device could not be identified. Inspect Disk Utility before trying again.")
            }
            let device = String(result.output[range])
            let parent = String(device.dropFirst(5))
            guard let id = registryID(parent) else {
                throw CommandFailure(message: "Could not verify \(device). It was left attached; inspect Disk Utility before trying again.")
            }
            var record = OwnedDisk(parentDisk: parent, registryID: id, bootSession: bootSession, name: name, sizeMB: sizeMB)
            created = record
            owned.append(record)
            persistOwnership()
            guard isCurrent(record) else { throw CommandFailure(message: "Device identity changed before formatting.") }
            _ = try await execute("/usr/sbin/diskutil", ["apfs", "create", device, name])
            let formatted = try await snapshot()
            guard isCurrent(record), let volume = formatted.volumes.first(where: { $0.parent == parent && $0.name == name }) else {
                throw CommandFailure(message: "Formatted volume could not be verified.")
            }
            record.volumeUUID = volume.uuid
            owned.removeAll { $0.id == record.id }
            owned.append(record)
            persistOwnership()
            publish(formatted)
            successMessage = "RAM disk '\(name)' created (\(sizeMB) MB)"
            return true
        } catch {
            let original = error.localizedDescription
            var cleanup = ""
            if let record = created, isCurrent(record) {
                do {
                    // Cleanup uses its own task so cancellation cannot skip releasing the new device.
                    let execute = self.execute
                    let registryID = self.registryID
                    let boot = self.bootSession
                    _ = try await Task.detached {
                        guard DiskIdentity.matches(record, boot: boot, registryID: registryID(record.parentDisk)) else {
                            throw CommandFailure(message: "Device identity changed before cleanup")
                        }
                        return try await execute("/usr/sbin/diskutil", ["eject", "/dev/\(record.parentDisk)"])
                    }.value
                    owned.removeAll { $0.id == record.id }
                    persistOwnership()
                } catch { cleanup = " Cleanup failed: \(error.localizedDescription). The device remains tracked for recovery." }
            }
            errorMessage = original + cleanup
            return false
        }
    }

    /// Both the main window and menu bar enter the same confirmation flow.
    func requestEject(_ disk: RamDisk) async {
        guard !showingEjectConfirmation, !isLoading else { return }
        showingEjectConfirmation = true
        defer { showingEjectConfirmation = false }
        let alert = NSAlert()
        alert.messageText = "Eject RAM Disk?"
        alert.informativeText = "All data on '\(disk.volumeName)' and any other volumes on this RAM disk will be permanently lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Eject")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if await removeRamDisk(disk) { return }
        guard canRetryForcedEject else {
            let failure = NSAlert()
            failure.messageText = "Disk was not ejected"
            failure.informativeText = errorMessage ?? "Unable to verify disk identity."
            failure.runModal()
            return
        }
        let forceAlert = NSAlert()
        forceAlert.messageText = "The RAM disk could not be ejected"
        forceAlert.informativeText = "\(errorMessage ?? "The disk may be in use.")\n\nClose files and try again. Force Eject can discard pending writes and all data on this RAM disk."
        forceAlert.alertStyle = .critical
        forceAlert.addButton(withTitle: "Cancel")
        forceAlert.addButton(withTitle: "Force Eject")
        if forceAlert.runModal() == .alertSecondButtonReturn {
            _ = await removeRamDisk(disk, force: true)
        }
    }

    func removeRamDisk(_ disk: RamDisk, force: Bool = false) async -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        errorMessage = nil
        successMessage = nil
        canRetryForcedEject = false
        do {
            try Task.checkCancellation()
            guard let record = owned.first(where: { $0.id == disk.ownershipID && $0.parentDisk == disk.parentDisk }),
                  isCurrent(record) else { throw CommandFailure(message: "Disk identity changed. Refresh the list; no disk was ejected.") }
            let current = try await snapshot()
            if let uuid = record.volumeUUID {
                guard current.volumes.contains(where: { $0.parent == record.parentDisk && $0.uuid == uuid }) else {
                    throw CommandFailure(message: "Volume identity changed. Use Disk Utility to inspect the device; no disk was ejected.")
                }
            }
            // Recheck after the async query, immediately before the destructive command.
            guard isCurrent(record) else { throw CommandFailure(message: "Disk identity changed; no disk was ejected.") }
            var arguments = ["eject"]
            if force { arguments.append("force") }
            arguments.append("/dev/\(record.parentDisk)")
            do { _ = try await execute("/usr/sbin/diskutil", arguments) }
            catch { canRetryForcedEject = !force && isCurrent(record); throw error }
            owned.removeAll { $0.id == record.id }
            persistOwnership()
            ramDisks.removeAll { $0.ownershipID == record.id }
            successMessage = "RAM disk '\(disk.volumeName)' ejected"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

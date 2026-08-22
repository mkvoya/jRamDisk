//
//  RamDiskManager.swift
//  jRamDisk
//
//  Handles RAM disk creation, removal, and status monitoring
//

import Foundation
import Combine
import ServiceManagement

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
    let id = UUID()
    let deviceNode: String
    let parentDisk: String
    let volumeName: String
    let size: UInt64
    let mountPoint: String
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

class RamDiskManager: ObservableObject {
    @MainActor @Published var ramDisks: [RamDisk] = []
    @MainActor @Published var isLoading = false
    @MainActor @Published var errorMessage: String?
    @MainActor @Published var successMessage: String?
    @MainActor @Published var autoCreateConfigs: [AutoCreateConfig] = []
    @MainActor @Published var launchAtLogin: Bool = false
    
    private var refreshTimer: Timer?
    
    // Track parent disks created by this app (persisted in UserDefaults)
    private let trackedDisksKey = "com.jramdisk.trackedParentDisks"
    private let autoCreateKey = "com.jramdisk.autoCreateConfigs"
    
    private var trackedParentDisks: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: trackedDisksKey) ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: trackedDisksKey)
        }
    }
    
    init() {
        startAutoRefresh()
        Task { @MainActor in
            loadAutoCreateConfigs()
            updateLaunchAtLoginStatus()
            await refreshRamDisks()
            await createAutoCreateDisks()
        }
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
    
    // MARK: - Launch at Login
    
    @MainActor
    func updateLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    
    @MainActor
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            errorMessage = "Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Auto Create Configs
    
    @MainActor
    func loadAutoCreateConfigs() {
        if let data = UserDefaults.standard.data(forKey: autoCreateKey),
           let configs = try? JSONDecoder().decode([AutoCreateConfig].self, from: data) {
            autoCreateConfigs = configs
        }
    }
    
    @MainActor
    func saveAutoCreateConfigs() {
        if let data = try? JSONEncoder().encode(autoCreateConfigs) {
            UserDefaults.standard.set(data, forKey: autoCreateKey)
        }
    }
    
    @MainActor
    func addAutoCreateConfig(name: String, sizeMB: Int) {
        let config = AutoCreateConfig(name: name, sizeMB: sizeMB)
        if !autoCreateConfigs.contains(where: { $0.name == name }) {
            autoCreateConfigs.append(config)
            saveAutoCreateConfigs()
            successMessage = "'\(name)' will be created at login"
        }
    }
    
    @MainActor
    func removeAutoCreateConfig(name: String) {
        autoCreateConfigs.removeAll { $0.name == name }
        saveAutoCreateConfigs()
    }
    
    @MainActor
    func isAutoCreate(name: String) -> Bool {
        return autoCreateConfigs.contains { $0.name == name }
    }
    
    @MainActor
    func createAutoCreateDisks() async {
        for config in autoCreateConfigs {
            // Check if disk with this name already exists
            if !ramDisks.contains(where: { $0.volumeName == config.name }) {
                _ = await createRamDisk(name: config.name, sizeMB: config.sizeMB)
            }
        }
    }
    
    // MARK: - Refresh
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshRamDisks()
            }
        }
    }
    
    @MainActor
    func refreshRamDisks() async {
        let disks = await fetchRamDisks()
        self.ramDisks = disks
        
        // Clean up tracked disks that no longer exist
        await cleanupTrackedDisks()
    }
    
    private func cleanupTrackedDisks() async {
        // Get list of all currently existing disk identifiers
        guard let output = await runCommand("/usr/sbin/diskutil", arguments: ["list"]) else {
            return
        }
        
        var existingDisks = Set<String>()
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains("/dev/disk") {
                // Extract disk identifier like "disk5"
                if let range = line.range(of: "disk\\d+", options: .regularExpression) {
                    existingDisks.insert(String(line[range]))
                }
            }
        }
        
        // Remove tracked disks that no longer exist
        var tracked = trackedParentDisks
        tracked = tracked.filter { existingDisks.contains($0) }
        trackedParentDisks = tracked
    }
    
    private func fetchRamDisks() async -> [RamDisk] {
        let tracked = trackedParentDisks
        
        guard !tracked.isEmpty else {
            return []
        }
        
        // Get detailed info about all disks
        guard let plistOutput = await runCommand("/usr/sbin/diskutil", arguments: ["list", "-plist"]) else {
            return []
        }
        
        var foundDisks: [RamDisk] = []
        
        if let data = plistOutput.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            
            for disk in allDisks {
                guard let deviceId = disk["DeviceIdentifier"] as? String else { continue }
                
                // Check if this disk is directly one we created (for HFS+ or simple formats)
                if tracked.contains(deviceId) {
                    // Check partitions (for HFS+)
                    if let partitions = disk["Partitions"] as? [[String: Any]] {
                        for partition in partitions {
                            if let partitionId = partition["DeviceIdentifier"] as? String,
                               let volumeName = partition["VolumeName"] as? String,
                               let size = partition["Size"] as? UInt64,
                               !volumeName.isEmpty {
                                let mountPoint = partition["MountPoint"] as? String ?? ""
                                
                                let ramDisk = RamDisk(
                                    deviceNode: "/dev/\(partitionId)",
                                    parentDisk: deviceId,
                                    volumeName: volumeName,
                                    size: size,
                                    mountPoint: mountPoint
                                )
                                foundDisks.append(ramDisk)
                            }
                        }
                    }
                }
                
                // Check if this is an APFS container whose physical store is one of our tracked disks
                if let physicalStores = disk["APFSPhysicalStores"] as? [[String: Any]] {
                    var matchedParentDisk: String? = nil
                    
                    for store in physicalStores {
                        if let storeDeviceId = store["DeviceIdentifier"] as? String,
                           tracked.contains(storeDeviceId) {
                            matchedParentDisk = storeDeviceId
                            break
                        }
                    }
                    
                    // If this APFS container is backed by one of our RAM disks, get its volumes
                    if let parentDisk = matchedParentDisk,
                       let apfsVolumes = disk["APFSVolumes"] as? [[String: Any]] {
                        for volume in apfsVolumes {
                            if let volumeId = volume["DeviceIdentifier"] as? String,
                               let volumeName = volume["VolumeName"] as? String,
                               !volumeName.isEmpty {
                                let size = volume["Size"] as? UInt64 ?? volume["CapacityInUse"] as? UInt64 ?? 0
                                let mountPoint = volume["MountPoint"] as? String ?? ""
                                
                                // Get the container size for display (more meaningful than volume size)
                                let containerSize = disk["Size"] as? UInt64 ?? size
                                
                                let ramDisk = RamDisk(
                                    deviceNode: "/dev/\(volumeId)",
                                    parentDisk: parentDisk,
                                    volumeName: volumeName,
                                    size: containerSize,
                                    mountPoint: mountPoint
                                )
                                foundDisks.append(ramDisk)
                            }
                        }
                    }
                }
            }
        }
        
        return foundDisks
    }
    
    @MainActor
    func createRamDisk(name: String, sizeMB: Int) async -> Bool {
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        defer { isLoading = false }
        
        // Calculate sectors (512 bytes per sector)
        let sectors = sizeMB * 2048
        
        // Create RAM disk device
        guard let device = await attachRamDisk(sectors: sectors) else {
            errorMessage = "Failed to create RAM disk device"
            return false
        }
        
        // Extract the disk identifier (e.g., "disk5" from "/dev/disk5")
        let parentDiskId = device.replacingOccurrences(of: "/dev/", with: "")
        
        // Track this disk as created by our app
        var tracked = trackedParentDisks
        tracked.insert(parentDiskId)
        trackedParentDisks = tracked
        
        // Format the RAM disk with APFS (using apfs create for proper APFS container structure)
        guard let formatOutput = await runCommand("/usr/sbin/diskutil", arguments: ["apfs", "create", device, name]) else {
            // If formatting fails, try to detach the device and remove from tracking
            _ = await detachRamDisk(device: device)
            tracked.remove(parentDiskId)
            trackedParentDisks = tracked
            errorMessage = "Failed to format RAM disk"
            return false
        }
        
        if formatOutput.contains("Finished APFS operation") || formatOutput.contains("successfully") {
            successMessage = "RAM disk '\(name)' created successfully (\(sizeMB) MB)"
            await refreshRamDisks()
            return true
        } else {
            _ = await detachRamDisk(device: device)
            tracked.remove(parentDiskId)
            trackedParentDisks = tracked
            errorMessage = "Failed to format RAM disk: \(formatOutput)"
            return false
        }
    }
    
    @MainActor
    func removeRamDisk(_ ramDisk: RamDisk) async -> Bool {
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        defer { isLoading = false }
        
        // First try to unmount
        _ = await runCommand("/usr/sbin/diskutil", arguments: ["unmount", ramDisk.deviceNode])
        
        // Then eject/detach using parent disk
        let parentDiskPath = "/dev/\(ramDisk.parentDisk)"
        
        var success = false
        if await detachRamDisk(device: parentDiskPath) {
            success = true
        } else if await detachRamDisk(device: parentDiskPath, force: true) {
            success = true
        }
        
        if success {
            // Remove from tracked disks
            var tracked = trackedParentDisks
            tracked.remove(ramDisk.parentDisk)
            trackedParentDisks = tracked
            
            successMessage = "RAM disk '\(ramDisk.volumeName)' removed successfully"
            await refreshRamDisks()
            return true
        } else {
            errorMessage = "Failed to remove RAM disk"
            return false
        }
    }
    
    private func attachRamDisk(sectors: Int) async -> String? {
        let output = await runCommand("/usr/sbin/diskutil", arguments: ["image", "attach", "-noMount", "ram://\(sectors)"])
        return parseDevicePath(from: output)
    }
    
    private func detachRamDisk(device: String, force: Bool = false) async -> Bool {
        var arguments = ["eject"]
        if force {
            arguments.append("force")
        }
        arguments.append(device)
        let output = await runCommand("/usr/sbin/diskutil", arguments: arguments)
        return output != nil
    }
    
    private func parseDevicePath(from output: String?) -> String? {
        guard let output else { return nil }
        
        let pattern = #"/dev/disk\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range, in: output) else {
            return nil
        }
        
        return String(output[range])
    }
    
    private func runCommand(_ command: String, arguments: [String]) async -> String? {
        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

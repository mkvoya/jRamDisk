//
//  RamDiskManager.swift
//  jRamDisk
//
//  Handles RAM disk creation, removal, and status monitoring
//

import Foundation
import Combine

struct RamDisk: Identifiable, Equatable {
    let id = UUID()
    let deviceNode: String
    let volumeName: String
    let size: UInt64
    let mountPoint: String
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

@MainActor
class RamDiskManager: ObservableObject {
    @Published var ramDisks: [RamDisk] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    
    private var refreshTimer: Timer?
    
    init() {
        startAutoRefresh()
        Task {
            await refreshRamDisks()
        }
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshRamDisks()
            }
        }
    }
    
    func refreshRamDisks() async {
        let disks = await fetchRamDisks()
        self.ramDisks = disks
    }
    
    private func fetchRamDisks() async -> [RamDisk] {
        // Use diskutil list to find RAM disks
        guard let output = await runCommand("/usr/sbin/diskutil", arguments: ["list"]) else {
            return []
        }
        
        var foundDisks: [RamDisk] = []
        let lines = output.components(separatedBy: "\n")
        var currentDisk: String?
        
        for line in lines {
            // Look for disk identifiers that might be RAM disks
            if line.contains("/dev/disk") {
                let components = line.components(separatedBy: " ").filter { !$0.isEmpty }
                if let diskPath = components.first {
                    currentDisk = diskPath
                }
            }
        }
        
        // Get detailed info about each disk to identify RAM disks
        guard let plistOutput = await runCommand("/usr/sbin/diskutil", arguments: ["list", "-plist"]) else {
            return []
        }
        
        if let data = plistOutput.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            
            for disk in allDisks {
                guard let deviceId = disk["DeviceIdentifier"] as? String else { continue }
                
                // Check if this is a RAM disk by examining its properties
                if let infoOutput = await runCommand("/usr/sbin/diskutil", arguments: ["info", "-plist", deviceId]),
                   let infoData = infoOutput.data(using: .utf8),
                   let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] {
                    
                    let mediaName = infoPlist["MediaName"] as? String ?? ""
                    let ioRegName = infoPlist["IORegistryEntryName"] as? String ?? ""
                    
                    // RAM disks typically have "disk image" in their properties or are created via hdid/hdiutil
                    if mediaName.lowercased().contains("ram") || 
                       ioRegName.lowercased().contains("disk image") ||
                       (infoPlist["VirtualOrPhysical"] as? String) == "Virtual" {
                        
                        // Check partitions
                        if let partitions = disk["Partitions"] as? [[String: Any]] {
                            for partition in partitions {
                                if let partitionId = partition["DeviceIdentifier"] as? String,
                                   let volumeName = partition["VolumeName"] as? String,
                                   let size = partition["Size"] as? UInt64,
                                   let mountPoint = partition["MountPoint"] as? String,
                                   !volumeName.isEmpty {
                                    
                                    let ramDisk = RamDisk(
                                        deviceNode: "/dev/\(partitionId)",
                                        volumeName: volumeName,
                                        size: size,
                                        mountPoint: mountPoint
                                    )
                                    foundDisks.append(ramDisk)
                                }
                            }
                        }
                        
                        // Also check APFSVolumes for APFS formatted RAM disks
                        if let apfsVolumes = disk["APFSVolumes"] as? [[String: Any]] {
                            for volume in apfsVolumes {
                                if let volumeId = volume["DeviceIdentifier"] as? String,
                                   let volumeName = volume["VolumeName"] as? String,
                                   let size = volume["Size"] as? UInt64,
                                   let mountPoint = volume["MountPoint"] as? String,
                                   !volumeName.isEmpty {
                                    
                                    let ramDisk = RamDisk(
                                        deviceNode: "/dev/\(volumeId)",
                                        volumeName: volumeName,
                                        size: size,
                                        mountPoint: mountPoint
                                    )
                                    foundDisks.append(ramDisk)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return foundDisks
    }
    
    func createRamDisk(name: String, sizeMB: Int) async -> Bool {
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        defer { isLoading = false }
        
        // Calculate sectors (512 bytes per sector)
        let sectors = sizeMB * 2048
        
        // Create RAM disk device
        guard let deviceOutput = await runCommand("/usr/bin/hdiutil", arguments: ["attach", "-nomount", "ram://\(sectors)"]) else {
            errorMessage = "Failed to create RAM disk device"
            return false
        }
        
        let device = deviceOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !device.isEmpty else {
            errorMessage = "Failed to get device identifier"
            return false
        }
        
        // Format the RAM disk with APFS
        guard let formatOutput = await runCommand("/usr/sbin/diskutil", arguments: ["erasevolume", "APFS", name, device]) else {
            // If formatting fails, try to detach the device
            _ = await runCommand("/usr/bin/hdiutil", arguments: ["detach", device])
            errorMessage = "Failed to format RAM disk"
            return false
        }
        
        if formatOutput.contains("Finished erase") || formatOutput.contains("successfully") {
            successMessage = "RAM disk '\(name)' created successfully (\(sizeMB) MB)"
            await refreshRamDisks()
            return true
        } else {
            _ = await runCommand("/usr/bin/hdiutil", arguments: ["detach", device])
            errorMessage = "Failed to format RAM disk: \(formatOutput)"
            return false
        }
    }
    
    func removeRamDisk(_ ramDisk: RamDisk) async -> Bool {
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        defer { isLoading = false }
        
        // First try to unmount
        _ = await runCommand("/usr/sbin/diskutil", arguments: ["unmount", ramDisk.deviceNode])
        
        // Then eject/detach
        // Get the parent disk (e.g., disk2 from disk2s1)
        let parentDisk = getParentDisk(from: ramDisk.deviceNode)
        
        if let _ = await runCommand("/usr/bin/hdiutil", arguments: ["detach", parentDisk]) {
            successMessage = "RAM disk '\(ramDisk.volumeName)' removed successfully"
            await refreshRamDisks()
            return true
        } else {
            // Try force detach
            if let _ = await runCommand("/usr/bin/hdiutil", arguments: ["detach", "-force", parentDisk]) {
                successMessage = "RAM disk '\(ramDisk.volumeName)' removed successfully"
                await refreshRamDisks()
                return true
            }
            errorMessage = "Failed to remove RAM disk"
            return false
        }
    }
    
    private func getParentDisk(from deviceNode: String) -> String {
        // Convert /dev/disk2s1 to /dev/disk2
        let device = deviceNode.replacingOccurrences(of: "/dev/", with: "")
        var parentDisk = device
        
        // Remove partition suffix (s1, s2, etc.)
        if let range = device.range(of: "s\\d+$", options: .regularExpression) {
            parentDisk = String(device[..<range.lowerBound])
        }
        
        return "/dev/\(parentDisk)"
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
                continuation.resume(returning: output)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

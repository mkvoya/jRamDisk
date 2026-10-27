import Foundation

/// Opt-in only: creates and removes one new 64 MB RAM disk using isolated preferences.
@main
struct RuntimeSmoke {
    @MainActor static func main() async throws {
        let suite = "jRamDisk.smoke.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = RamDiskManager(defaults: defaults, startAutomatically: false)
        let name = "jRamDisk-Test-\(UUID().uuidString.prefix(8))"
        guard await manager.createRamDisk(name: name, sizeMB: 64), let disk = manager.ramDisks.first else {
            throw CommandFailure(message: manager.errorMessage ?? "No test disk created")
        }
        let reopened = RamDiskManager(defaults: defaults, startAutomatically: false)
        await reopened.refreshRamDisks()
        guard reopened.ramDisks.first?.id == disk.id else {
            _ = await manager.removeRamDisk(disk)
            throw CommandFailure(message: "Identity did not survive manager restart")
        }
        guard await reopened.removeRamDisk(disk) else {
            throw CommandFailure(message: reopened.errorMessage ?? "Test disk cleanup failed")
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Runtime smoke passed: created, rediscovered and safely ejected \(name)")
    }
}

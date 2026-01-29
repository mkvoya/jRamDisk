//
//  jRamDiskApp.swift
//  jRamDisk
//
//  A macOS app for managing RAM disks
//

import SwiftUI
import AppKit

// Shared instance for the RamDiskManager
@MainActor
let sharedRamDiskManager = RamDiskManager()

@main
struct jRamDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sharedRamDiskManager)
                .frame(minWidth: 500, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - App Delegate with Status Bar
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.setupStatusBar()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    @MainActor
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            // Try to use SF Symbol, fallback to app icon
            if let image = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: "jRamDisk") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
                button.image?.isTemplate = true
            } else if let appIcon = NSImage(named: NSImage.applicationIconName) {
                // Use app icon as fallback
                let size = NSSize(width: 18, height: 18)
                appIcon.size = size
                button.image = appIcon
            } else {
                // Last resort: use a basic symbol
                button.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "jRamDisk")
                button.image?.isTemplate = true
            }
        }
        
        statusMenu = NSMenu()
        statusMenu?.delegate = self
        statusItem?.menu = statusMenu
        rebuildMenu()
    }
    
    @MainActor
    func rebuildMenu() {
        guard let statusMenu = statusMenu else { return }
        statusMenu.removeAllItems()
        
        // Header
        let headerItem = NSMenuItem(title: "jRamDisk", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        statusMenu.addItem(headerItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Get RAM disks
        let ramDisks = sharedRamDiskManager.ramDisks
        
        // RAM Disks list
        if ramDisks.isEmpty {
            let noDisksItem = NSMenuItem(title: "No RAM Disks", action: nil, keyEquivalent: "")
            noDisksItem.isEnabled = false
            statusMenu.addItem(noDisksItem)
        } else {
            for (index, disk) in ramDisks.enumerated() {
                let diskMenu = NSMenu()
                
                let openItem = NSMenuItem(title: "Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: "")
                openItem.target = self
                openItem.tag = index
                openItem.isEnabled = !disk.mountPoint.isEmpty
                diskMenu.addItem(openItem)
                
                diskMenu.addItem(NSMenuItem.separator())
                
                let ejectItem = NSMenuItem(title: "Eject", action: #selector(ejectDisk(_:)), keyEquivalent: "")
                ejectItem.target = self
                ejectItem.tag = index
                diskMenu.addItem(ejectItem)
                
                let diskItem = NSMenuItem(title: "\(disk.volumeName) - \(disk.formattedSize)", action: nil, keyEquivalent: "")
                diskItem.image = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: nil)
                diskItem.submenu = diskMenu
                statusMenu.addItem(diskItem)
            }
        }
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Quick Create submenu
        let quickCreateMenu = NSMenu()
        
        let sizes = [(512, "512 MB"), (1024, "1 GB"), (2048, "2 GB"), (4096, "4 GB")]
        for (size, label) in sizes {
            let item = NSMenuItem(title: "\(label) RAM Disk", action: #selector(quickCreate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            quickCreateMenu.addItem(item)
        }
        
        let quickCreateItem = NSMenuItem(title: "Quick Create", action: nil, keyEquivalent: "")
        quickCreateItem.submenu = quickCreateMenu
        statusMenu.addItem(quickCreateItem)
        
        // Open main window
        let openItem = NSMenuItem(title: "Open jRamDisk...", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        statusMenu.addItem(openItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Launch at login toggle
        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = sharedRamDiskManager.launchAtLogin ? .on : .off
        statusMenu.addItem(launchAtLoginItem)
        
        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshDisks), keyEquivalent: "r")
        refreshItem.target = self
        statusMenu.addItem(refreshItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit jRamDisk", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }
    
    @MainActor
    @objc func toggleLaunchAtLogin() {
        sharedRamDiskManager.setLaunchAtLogin(!sharedRamDiskManager.launchAtLogin)
        rebuildMenu()
    }
    
    @MainActor
    @objc func openInFinder(_ sender: NSMenuItem) {
        let index = sender.tag
        let ramDisks = sharedRamDiskManager.ramDisks
        guard index < ramDisks.count else { return }
        let path = ramDisks[index].mountPoint
        if !path.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
    
    @MainActor
    @objc func ejectDisk(_ sender: NSMenuItem) {
        let index = sender.tag
        let ramDisks = sharedRamDiskManager.ramDisks
        guard index < ramDisks.count else { return }
        let disk = ramDisks[index]
        Task {
            await sharedRamDiskManager.removeRamDisk(disk)
            self.rebuildMenu()
        }
    }
    
    @objc func quickCreate(_ sender: NSMenuItem) {
        let sizeMB = sender.tag
        Task { @MainActor in
            await sharedRamDiskManager.createRamDisk(name: "RamDisk", sizeMB: sizeMB)
            self.rebuildMenu()
        }
    }
    
    @objc func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Find and show the main window, or create a new one
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
    
    @objc func refreshDisks() {
        Task { @MainActor in
            await sharedRamDiskManager.refreshRamDisks()
            self.rebuildMenu()
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            await sharedRamDiskManager.refreshRamDisks()
            self.rebuildMenu()
        }
    }
}

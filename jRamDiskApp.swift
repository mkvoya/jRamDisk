//
//  jRamDiskApp.swift
//  jRamDisk
//
//  A macOS app for managing RAM disks
//

import SwiftUI

@main
struct jRamDiskApp: App {
    @StateObject private var ramDiskManager = RamDiskManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ramDiskManager)
                .frame(minWidth: 500, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

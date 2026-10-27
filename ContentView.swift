//
//  ContentView.swift
//  jRamDisk
//
//  Main user interface for RAM disk management
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    @State private var showCreateSheet = false
    @State private var showSettingsSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(showCreateSheet: $showCreateSheet, showSettingsSheet: $showSettingsSheet)
            
            Divider()
            
            // Status messages
            StatusBarView()
            
            // Main content
            if ramDiskManager.ramDisks.isEmpty && ramDiskManager.autoCreateConfigs.isEmpty {
                EmptyStateView(showCreateSheet: $showCreateSheet)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Active RAM Disks
                        if !ramDiskManager.ramDisks.isEmpty {
                            RamDiskListView()
                        }
                        
                        // Auto-create configs (not currently mounted)
                        let unmountedConfigs = ramDiskManager.autoCreateConfigs.filter { config in
                            !ramDiskManager.ramDisks.contains { $0.volumeName == config.name }
                        }
                        if !unmountedConfigs.isEmpty {
                            AutoCreateListView(configs: unmountedConfigs)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showCreateSheet) {
            CreateRamDiskSheet(isPresented: $showCreateSheet)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsSheet(isPresented: $showSettingsSheet)
        }
    }
}

// MARK: - Header View
struct HeaderView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    @Binding var showCreateSheet: Bool
    @Binding var showSettingsSheet: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("jRamDisk")
                    .font(.title.bold())
                Text("RAM Disk Manager")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: { showSettingsSheet = true }) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Settings")
                
                Button(action: {
                    Task {
                        await ramDiskManager.refreshRamDisks()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Refresh disk list")
                .disabled(ramDiskManager.isLoading)
                
                Button(action: { showCreateSheet = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("New RAM Disk")
                    }
                    .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(ramDiskManager.isLoading)
            }
        }
        .padding()
    }
}

// MARK: - Status Bar View
struct StatusBarView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    
    var body: some View {
        Group {
            if ramDiskManager.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Processing...")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
            } else if let error = ramDiskManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        ramDiskManager.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            } else if let success = ramDiskManager.successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        ramDiskManager.successMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            }
        }
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    @Binding var showCreateSheet: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "memorychip")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("No RAM Disks")
                    .font(.title2.bold())
                Text("Create a RAM disk to store temporary files in memory\nfor ultra-fast read/write performance.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button(action: { showCreateSheet = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Your First RAM Disk")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - RAM Disk List View
struct RamDiskListView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active RAM Disks")
                .font(.headline)
                .foregroundColor(.secondary)
            
            LazyVStack(spacing: 12) {
                ForEach(ramDiskManager.ramDisks) { disk in
                    RamDiskRowView(ramDisk: disk)
                }
            }
        }
    }
}

// MARK: - Auto Create List View
struct AutoCreateListView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    let configs: [AutoCreateConfig]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto-Create at Login (Not Mounted)")
                .font(.headline)
                .foregroundColor(.secondary)
            
            LazyVStack(spacing: 12) {
                ForEach(configs) { config in
                    AutoCreateRowView(config: config)
                }
            }
        }
    }
}

// MARK: - Auto Create Row View
struct AutoCreateRowView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    let config: AutoCreateConfig
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Disk icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                
                Image(systemName: "memorychip")
                    .font(.title2)
                    .foregroundColor(.gray)
            }
            
            // Config info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(config.name)
                        .font(.headline)
                    
                    Text("(Not mounted)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Label(config.formattedSize, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                Button(action: {
                    Task {
                        _ = await ramDiskManager.createRamDisk(name: config.name, sizeMB: config.sizeMB)
                    }
                }) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .help("Create now")
                .disabled(ramDiskManager.isLoading)
                
                Button(action: {
                    ramDiskManager.removeAutoCreateConfig(name: config.name)
                }) {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove from auto-create")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 8 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - RAM Disk Row View
struct RamDiskRowView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    let ramDisk: RamDisk
    @State private var isHovering = false
    
    private var isAutoCreate: Bool {
        ramDiskManager.isAutoCreate(name: ramDisk.volumeName)
    }
    
    private var diskSizeMB: Int {
        Int(ramDisk.size / (1024 * 1024))
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Disk icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [.blue.opacity(0.8), .purple.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 50, height: 50)
                
                Image(systemName: "memorychip.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            // Disk info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ramDisk.volumeName)
                        .font(.headline)
                    
                    if isAutoCreate {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                            .help("Creates at login")
                    }
                }
                
                HStack(spacing: 16) {
                    Label(ramDisk.formattedSize, systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label(ramDisk.deviceNode, systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !ramDisk.mountPoint.isEmpty {
                    Label(ramDisk.mountPoint, systemImage: "folder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                // Auto-create toggle
                Button(action: toggleAutoCreate) {
                    Image(systemName: isAutoCreate ? "clock.badge.checkmark.fill" : "clock.badge.questionmark")
                        .font(.title3)
                        .foregroundColor(isAutoCreate ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isAutoCreate ? "Remove from auto-create" : "Create at login")
                
                Button(action: openInFinder) {
                    Image(systemName: "folder")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Open in Finder")
                .disabled(ramDisk.mountPoint.isEmpty)
                
                Button(action: { Task { await ramDiskManager.requestEject(ramDisk) } }) {
                    Image(systemName: "eject.fill")
                        .font(.title3)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .help("Eject RAM Disk")
                .disabled(ramDiskManager.isLoading)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 8 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }

    }
    
    private func openInFinder() {
        guard !ramDisk.mountPoint.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: ramDisk.mountPoint))
    }
    
    private func toggleAutoCreate() {
        if isAutoCreate {
            ramDiskManager.removeAutoCreateConfig(name: ramDisk.volumeName)
        } else {
            ramDiskManager.addAutoCreateConfig(name: ramDisk.volumeName, sizeMB: diskSizeMB)
        }
    }
}

// MARK: - Settings Sheet
struct SettingsSheet: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            
            Divider()
            
            // Settings content
            VStack(alignment: .leading, spacing: 20) {
                // Launch at login
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { ramDiskManager.launchAtLogin },
                        set: { ramDiskManager.setLaunchAtLogin($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.headline)
                            Text("Start jRamDisk automatically when you log in")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                
                Divider()
                
                // Auto-create disks
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Create RAM Disks")
                        .font(.headline)
                    Text("These RAM disks will be created automatically when the app starts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if ramDiskManager.autoCreateConfigs.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "clock.badge.questionmark")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("No auto-create disks configured")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Click the clock icon on a RAM disk to enable")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            Spacer()
                        }
                    } else {
                        ForEach(ramDiskManager.autoCreateConfigs) { config in
                            HStack {
                                Image(systemName: "memorychip.fill")
                                    .foregroundColor(.blue)
                                Text(config.name)
                                    .font(.body)
                                Spacer()
                                Text(config.formattedSize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button(action: {
                                    ramDiskManager.removeAutoCreateConfig(name: config.name)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Close button
            HStack {
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 400)
    }
}

// MARK: - Create RAM Disk Sheet
struct CreateRamDiskSheet: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    @Binding var isPresented: Bool
    
    @State private var diskName = "RamDisk"
    @State private var sliderValue: Double = 9 // log2(512) = 9
    @State private var autoCreateAtLogin = false
    
    // Slider range: 64 MB (2^6 * 64 = 64) to 8192 MB (2^13 = 8192)
    // Using log scale: 6 to 13 maps to 64 MB to 8 GB
    private let minPower: Double = 6  // 64 MB
    private let maxPower: Double = 13 // 8192 MB (8 GB)
    
    private var selectedSizeMB: Int {
        Int(pow(2, sliderValue))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create New RAM Disk")
                    .font(.title2.bold())
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            
            Divider()
            
            // Form
            VStack(spacing: 24) {
                if let error = ramDiskManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
                // Name field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume Name")
                        .font(.headline)
                    TextField("Enter name", text: $diskName)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                }
                
                // Size selector
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Size")
                            .font(.headline)
                        Spacer()
                        Text(formatSize(selectedSizeMB))
                            .font(.system(.title2, design: .rounded).bold())
                            .foregroundColor(.blue)
                    }
                    
                    Slider(value: $sliderValue, in: minPower...maxPower, step: 1) {
                        Text("Size")
                    } minimumValueLabel: {
                        Text("64 MB")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } maximumValueLabel: {
                        Text("8 GB")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .tint(.blue)
                    
                    // Size presets
                    HStack(spacing: 8) {
                        ForEach([6, 8, 9, 10, 11, 12, 13], id: \.self) { power in
                            Button(action: { sliderValue = Double(power) }) {
                                Text(formatSize(Int(pow(2, Double(power)))))
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Int(sliderValue) == power ? Color.blue : Color.secondary.opacity(0.2))
                                    )
                                    .foregroundColor(Int(sliderValue) == power ? .white : .primary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    Text("Managed RAM disks: \(ramDiskManager.allocatedMB) MB · Physical memory: \(ramDiskManager.physicalMemoryMB) MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("After creation: \(ramDiskManager.allocatedMB + selectedSizeMB) / \(ramDiskManager.allocationLimitMB) MB limit (50% of RAM)")
                        .font(.caption)
                        .foregroundColor(ramDiskManager.allocatedMB + selectedSizeMB > ramDiskManager.allocationLimitMB ? .red : .secondary)
                    Text("Memory pressure can increase SSD swap writes. Leave room for your apps.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Auto-create option
                Toggle(isOn: $autoCreateAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create at Login")
                            .font(.subheadline)
                        Text("Automatically create this RAM disk when jRamDisk starts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                // Info box
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About RAM Disks")
                            .font(.caption.bold())
                        Text("RAM disks store data in memory, providing extremely fast read/write speeds. Data is lost when the disk is ejected or the computer restarts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .padding()
            
            Divider()
            
            // Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(action: createDisk) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled((try? RamDiskManager.validatedName(diskName, sizeMB: selectedSizeMB)) == nil || ramDiskManager.isLoading || ramDiskManager.allocatedMB + selectedSizeMB > ramDiskManager.allocationLimitMB)
            }
            .padding()
        }
        .frame(width: 450)
    }
    
    private func formatSize(_ mb: Int) -> String {
        if mb >= 1024 {
            return "\(mb / 1024) GB"
        }
        return "\(mb) MB"
    }
    
    private func createDisk() {
        let name = diskName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        
        Task {
            let success = await ramDiskManager.createRamDisk(name: name, sizeMB: selectedSizeMB)
            if success {
                if autoCreateAtLogin {
                    ramDiskManager.addAutoCreateConfig(name: name, sizeMB: selectedSizeMB)
                }
                isPresented = false
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RamDiskManager(startAutomatically: false))
        .frame(width: 550, height: 500)
}

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
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(showCreateSheet: $showCreateSheet)
            
            Divider()
            
            // Status messages
            StatusBarView()
            
            // Main content
            if ramDiskManager.ramDisks.isEmpty {
                EmptyStateView(showCreateSheet: $showCreateSheet)
            } else {
                RamDiskListView()
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showCreateSheet) {
            CreateRamDiskSheet(isPresented: $showCreateSheet)
        }
    }
}

// MARK: - Header View
struct HeaderView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    @Binding var showCreateSheet: Bool
    
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
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(ramDiskManager.ramDisks) { disk in
                    RamDiskRowView(ramDisk: disk)
                }
            }
            .padding()
        }
    }
}

// MARK: - RAM Disk Row View
struct RamDiskRowView: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    let ramDisk: RamDisk
    @State private var showDeleteConfirmation = false
    @State private var isHovering = false
    
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
                Text(ramDisk.volumeName)
                    .font(.headline)
                
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
                Button(action: openInFinder) {
                    Image(systemName: "folder")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Open in Finder")
                .disabled(ramDisk.mountPoint.isEmpty)
                
                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "eject.fill")
                        .font(.title3)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .help("Eject RAM Disk")
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
        .alert("Eject RAM Disk?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Eject", role: .destructive) {
                Task {
                    await ramDiskManager.removeRamDisk(ramDisk)
                }
            }
        } message: {
            Text("Are you sure you want to eject '\(ramDisk.volumeName)'?\n\nAll data on this RAM disk will be permanently lost.")
        }
    }
    
    private func openInFinder() {
        guard !ramDisk.mountPoint.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: ramDisk.mountPoint))
    }
}

// MARK: - Create RAM Disk Sheet
struct CreateRamDiskSheet: View {
    @EnvironmentObject var ramDiskManager: RamDiskManager
    @Binding var isPresented: Bool
    
    @State private var diskName = "RamDisk"
    @State private var sliderValue: Double = 9 // log2(512) = 9
    
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
                    
                    Text("Recommended: 512 MB - 2 GB for most use cases")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
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
                .disabled(diskName.trimmingCharacters(in: .whitespaces).isEmpty || ramDiskManager.isLoading)
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
                isPresented = false
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RamDiskManager())
        .frame(width: 550, height: 500)
}

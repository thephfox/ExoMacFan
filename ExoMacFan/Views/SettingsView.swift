// ============================================================
// File: SettingsView.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Application settings and configuration
// ============================================================

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @EnvironmentObject var sensorDiscovery: SensorDiscovery
    @AppStorage("monitoringInterval") private var monitoringInterval = 2.0
    @ObservedObject private var smcHelper = SMCHelper.shared
    @State private var storageUsed: String = "Calculating..."
    @State private var showClearConfirmation = false
    @State private var showUninstallConfirmation = false

    var body: some View {
        Form {
                // Monitoring Settings
                Section("Monitoring") {
                    HStack {
                        Text("Update Interval")
                        Spacer()
                        Text(String(format: "%.1fs", monitoringInterval))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $monitoringInterval, in: 1.0...10.0, step: 0.5)
                        .onChange(of: monitoringInterval) { newValue in
                            thermalMonitor.setPollingInterval(newValue)
                            sensorDiscovery.setRefreshInterval(newValue)
                        }
                    
                    Text("Lower intervals provide more responsive readings but use more CPU.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Fan Control Daemon
                Section("Fan Control Daemon") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(smcHelper.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(smcHelper.isConnected ? "Running" : "Not Running")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Installed")
                        Spacer()
                        Text(smcHelper.isInstalled ? "Yes" : "No")
                            .foregroundColor(.secondary)
                    }

                    if smcHelper.isInstalled {
                        Button("Uninstall Helper Daemon") {
                            showUninstallConfirmation = true
                        }
                        .foregroundColor(.red)
                        .alert("Uninstall Helper?", isPresented: $showUninstallConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Uninstall", role: .destructive) {
                                Task { await smcHelper.uninstall() }
                            }
                        } message: {
                            Text("This will remove the fan control daemon. Fan control will stop working until it is reinstalled on next app launch.")
                        }
                    }

                    Text("The helper daemon runs as a system service for fan control. It is installed once and persists across reboots.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Hardware Information
                if let hardwareInfo = sensorDiscovery.hardwareInfo {
                    Section("Hardware Information") {
                        HardwareInfoRow(title: "Generation", value: hardwareInfo.macGeneration.displayName)
                        HardwareInfoRow(title: "Chip", value: hardwareInfo.chipType)
                        HardwareInfoRow(title: "Total Cores", value: "\(hardwareInfo.totalCores)")
                        HardwareInfoRow(title: "Performance Cores", value: "\(hardwareInfo.performanceCores)")
                        HardwareInfoRow(title: "Efficiency Cores", value: "\(hardwareInfo.efficiencyCores)")
                        HardwareInfoRow(title: "GPU Cores", value: "\(hardwareInfo.gpuCores)")
                        HardwareInfoRow(title: "Fans", value: hardwareInfo.hasFans ? "\(hardwareInfo.fanCount)" : "None")
                        HardwareInfoRow(title: "Model", value: hardwareInfo.modelIdentifier)
                    }
                }
                
                // Data Management
                Section("Data Management") {
                    Button("Clear Thermal History") {
                        showClearConfirmation = true
                    }
                    .foregroundColor(.red)
                    .alert("Clear History?", isPresented: $showClearConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Clear", role: .destructive) {
                            clearHistory()
                            calculateStorageUsed()
                        }
                    } message: {
                        Text("This will permanently delete all thermal history data.")
                    }

                    Button("Export All Data") {
                        exportData()
                    }

                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(storageUsed)
                            .foregroundColor(.secondary)
                    }
                    .onAppear { calculateStorageUsed() }
                }
                
                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(getVersionString())
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Architecture")
                        Spacer()
                        Text(getArchitectureString())
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("License")
                        Spacer()
                        Text("MIT + Attribution")
                            .foregroundColor(.secondary)
                    }
                    
                    Link("View on GitHub", destination: URL(string: "https://github.com/thephfox/ExoMacFan")!)
                    
                    Link("Report an Issue", destination: URL(string: "https://github.com/thephfox/ExoMacFan/issues")!)

                    HStack {
                        Spacer()
                        Text("by phfox.com")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
    }
    
    private func clearHistory() {
        thermalMonitor.clearHistory()
    }
    
    private func exportData() {
        guard let data = thermalMonitor.exportHistory() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ExoMacFan_AllData.json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
    
    private func getVersionString() -> String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let commit = Bundle.main.infoDictionary?["GitCommit"] as? String
        var s = "\(ver) (\(build))"
        if let commit, commit != "unknown" { s += " [\(commit)]" }
        return s
    }

    private func getArchitectureString() -> String {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &ret, &size, nil, 0) == 0, ret == 1 {
            return "Apple Silicon"
        }
        return "Intel"
    }

    private func calculateStorageUsed() {
        let path = NSString(string: "~/Documents/ExoMacFan_thermal_history.json").expandingTildeInPath
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int {
            if size < 1024 {
                storageUsed = "\(size) B"
            } else if size < 1024 * 1024 {
                storageUsed = String(format: "%.1f KB", Double(size) / 1024)
            } else {
                storageUsed = String(format: "%.1f MB", Double(size) / (1024 * 1024))
            }
        } else {
            storageUsed = "0 B"
        }
    }
}

// MARK: - Hardware Info Row
struct HardwareInfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ThermalMonitor())
        .environmentObject(SensorDiscovery())
}

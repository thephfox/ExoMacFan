// ============================================================
// File: SensorDiscovery.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Description: Comprehensive sensor discovery for all Mac generations
// ============================================================

import Foundation
import IOKit
import Combine

@MainActor
class SensorDiscovery: ObservableObject {
    // MARK: - Published Properties
    @Published var discoveredSensors: [SensorInfo] = []
    @Published var hardwareInfo: HardwareInfo?
    @Published var isDiscovering = false
    @Published var discoveryProgress: Double = 0.0
    @Published var error: Error?
    
    // MARK: - Private Properties
    private let ioKitInterface = IOKitInterface.shared
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var refreshInterval: TimeInterval = 2.0
    
    // MARK: - Public Methods
    func discoverSensors() {
        guard !isDiscovering else { return }
        
        isDiscovering = true
        discoveryProgress = 0.0
        discoveredSensors.removeAll()
        
        Task {
            await performDiscovery()
            startRefreshTimer()
        }
    }
    
    func refreshSensors() {
        discoverSensors()
    }
    
    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        if refreshTimer != nil {
            startRefreshTimer()
        }
    }
    
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                await self.updateSensorValues()
            }
        }
    }
    
    /// Re-read current values for all discovered sensors without full re-discovery.
    private func updateSensorValues() async {
        guard !discoveredSensors.isEmpty, !isDiscovering else { return }
        
        var updated: [SensorInfo] = []
        for sensor in discoveredSensors {
            if let value = try? await ioKitInterface.readRawValue(key: sensor.key) {
                let isLiveTemp = value > 10.0 && value < 150.0
                updated.append(SensorInfo(
                    key: sensor.key,
                    name: sensor.name,
                    component: sensor.component,
                    currentValue: value,
                    unit: isLiveTemp ? "°C" : sensor.unit,
                    minValue: sensor.minValue,
                    maxValue: sensor.maxValue,
                    isActive: isLiveTemp,
                    lastUpdated: Date()
                ))
            } else {
                updated.append(sensor)
            }
        }
        discoveredSensors = updated
    }
    
    func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    func getSensorsForComponent(_ component: ComponentType) -> [SensorInfo] {
        return discoveredSensors.filter { $0.component == component }
    }
    
    func getSensorByKey(_ key: String) -> SensorInfo? {
        return discoveredSensors.first { $0.key == key }
    }
    
    // MARK: - Private Methods
    private func performDiscovery() async {
        do {
            // Step 1: Identify hardware
            await updateProgress(0.1, "Identifying hardware...")
            let hardware = try await identifyHardware()
            hardwareInfo = hardware
            
            // Step 2: Discover sensors via SMC key enumeration (works on all Macs)
            await updateProgress(0.3, "Discovering sensors...")
            var sensors = try await discoverSensorsViaSMCEnumeration()
            
            // Supplement with generation-specific named sensors if enumeration found few
            if sensors.count < 5 {
                let generationSensors = try await discoverSensorsForGeneration(hardware.macGeneration)
                let existingKeys = Set(sensors.map(\.key))
                for sensor in generationSensors where !existingKeys.contains(sensor.key) {
                    sensors.append(sensor)
                }
            }
            
            // Step 3: Validate and categorize sensors
            await updateProgress(0.7, "Validating sensors...")
            let validatedSensors = try await validateSensors(sensors, hardware: hardware)
            
            // Step 4: Sort and organize
            await updateProgress(0.9, "Organizing sensors...")
            discoveredSensors = sortSensors(validatedSensors)
            
            await updateProgress(1.0, "Discovery complete")
            
            // Discovery complete
            
        } catch {
            self.error = error
            print("Sensor discovery failed: \(error)")
        }
        
        isDiscovering = false
    }
    
    private func updateProgress(_ progress: Double, _ message: String) async {
        await MainActor.run {
            discoveryProgress = progress
            // progress: \(message)
        }
    }
    
    private func identifyHardware() async throws -> HardwareInfo {
        let macGeneration = try await detectMacGeneration()
        let chipType = try await getChipType()
        let coreCount = try await getCoreCount()
        let performanceCores = try await getPerformanceCoreCount()
        let efficiencyCores = try await getEfficiencyCoreCount()
        let gpuCores = try await getGPUCoreCount()
        let hasFans = try await checkFanPresence()
        let fanCount = hasFans ? try await getFanCount() : 0
        let maxFanSpeed = hasFans ? try await getMaxFanSpeed() : 0
        let modelIdentifier = try await getModelIdentifier()
        
        return HardwareInfo(
            macGeneration: macGeneration,
            chipType: chipType,
            coreCount: coreCount,
            performanceCores: performanceCores,
            efficiencyCores: efficiencyCores,
            gpuCores: gpuCores,
            hasFans: hasFans,
            fanCount: fanCount,
            maxFanSpeed: maxFanSpeed,
            modelIdentifier: modelIdentifier
        )
    }
    
    private func detectMacGeneration() async throws -> MacGeneration {
        let machine = try await getMachineIdentifier()
        let isAppleSilicon = machine.contains("arm64") || machine.contains("Apple")
        
        if isAppleSilicon {
            // Apple Silicon - detect specific generation via system_profiler
            let chipInfo = try await getChipInfo()
            if chipInfo.contains("M5") { return .m5 }
            if chipInfo.contains("M4") { return .m4 }
            if chipInfo.contains("M3") { return .m3 }
            if chipInfo.contains("M2") { return .m2 }
            if chipInfo.contains("M1") { return .m1 }
            // Apple Silicon but unknown specific generation
            return .m1
        }
        
        return .intel
    }
    
    private func discoverSensorsForGeneration(_ generation: MacGeneration) async throws -> [SensorInfo] {
        switch generation {
        case .intel:
            return try await discoverIntelSensors()
        case .m1:
            return try await discoverM1Sensors()
        case .m2:
            return try await discoverM2Sensors()
        case .m3:
            return try await discoverM3Sensors()
        case .m4:
            return try await discoverM4Sensors()
        case .m5:
            return try await discoverM4Sensors() // M5 uses same sensor layout as M4
        case .unknown:
            return try await discoverGenericSensors()
        }
    }
    
    /// Discover sensors by enumerating all SMC 'T' keys.
    /// Keys with realistic values (>10°C, <150°C) are marked active.
    /// Keys with low/zero/extreme values are marked inactive with descriptive names
    /// (threshold registers, config data, powered-down sensors).
    private func discoverSensorsViaSMCEnumeration() async throws -> [SensorInfo] {
        let keys = try await ioKitInterface.discoverAllSensorKeys()
        var sensors: [SensorInfo] = []

        for key in keys {
            guard let value = try? await ioKitInterface.readRawValue(key: key) else { continue }

            let component = classifyTemperatureKey(key)
            let isLiveTemp = value > 10.0 && value < 150.0

            let name: String
            let unit: String
            let isActive: Bool

            if isLiveTemp {
                name = describeTemperatureKey(key)
                unit = "°C"
                isActive = true
            } else {
                // Not a live temperature — identify what it actually is
                name = describeNonTemperatureKey(key, value: value)
                unit = identifyUnit(for: key, value: value)
                isActive = false
            }

            let sensor = SensorInfo(
                key: key,
                name: name,
                component: component,
                currentValue: value,
                unit: unit,
                minValue: 0,
                maxValue: isLiveTemp ? getExpectedMaxTemp(for: component) : max(value * 2, 150),
                isActive: isActive,
                lastUpdated: Date()
            )
            sensors.append(sensor)
        }

        return sensors
    }

    // MARK: - Non-Temperature Key Identification

    /// Known SMC keys that are NOT live temperature sensors.
    /// Maps key → human-readable description.
    private let knownNonTemperatureKeys: [String: String] = [
        // CPU thermal thresholds / trip points
        "TCHP": "CPU Hot Protection Threshold",
        "TCXC": "CPU Critical Threshold",
        "TCTD": "CPU Throttle Delta",
        "TCSA": "CPU System Agent Threshold",
        "TCGP": "CPU/GPU Package Threshold",
        // GPU thresholds
        "TGVP": "GPU VRAM Protection Threshold",
        // Memory thresholds
        "TMTP": "Memory Thermal Protection",
        // General thermal management
        "TDTC": "Die Thermal Cutoff",
        "TDTP": "Die Thermal Protection",
    ]

    /// Describe a key that is NOT a live temperature sensor.
    private func describeNonTemperatureKey(_ key: String, value: Double) -> String {
        // Check known keys first
        if let known = knownNonTemperatureKeys[key] {
            return known
        }

        let component = classifyTemperatureKey(key)
        let prefix: String
        switch component {
        case .cpuPerformance: prefix = "CPU"
        case .cpuEfficiency:  prefix = "CPU Efficiency"
        case .gpu:            prefix = "GPU"
        case .ane:            prefix = "ANE"
        case .soc:            prefix = "SoC"
        case .ambient:        prefix = "Ambient"
        case .battery:        prefix = "Battery"
        case .unknown:        prefix = "Sensor"
        }

        // Classify by value range
        if value <= 0 {
            return "\(prefix) \(key) (Powered Down)"
        } else if value <= 10 {
            return "\(prefix) \(key) (Threshold/Config)"
        } else {
            // value >= 150 — not a temperature
            return "\(prefix) \(key) (Non-Temperature Data)"
        }
    }

    /// Identify the unit for a non-temperature key based on its value.
    private func identifyUnit(for key: String, value: Double) -> String {
        if value <= 0 {
            return "(off)"
        } else if value <= 10 {
            return "°C (thr)"
        } else {
            return "(raw)"
        }
    }
    
    /// Classify a temperature key into a ComponentType based on its prefix.
    private func classifyTemperatureKey(_ key: String) -> ComponentType {
        let k = key.lowercased()
        // CPU Performance: Tp (P-core die sensors), TC0/TC1 (CPU package)
        if k.hasPrefix("tp") || k.hasPrefix("tc0") || k.hasPrefix("tc1") { return .cpuPerformance }
        // CPU general/multi-core (TC2-TC5, TCHP, TCM, TCD)
        if k.hasPrefix("tc") { return .cpuPerformance }
        // CPU Efficiency
        if k.hasPrefix("te") { return .cpuEfficiency }
        // GPU
        if k.hasPrefix("tg") { return .gpu }
        // Ambient: only TA0P and TAOL are true ambient/airflow sensors
        if k == "ta0p" || k == "taol" { return .ambient }
        // ANE (Neural Engine): TaP prefix
        if k.hasPrefix("ta") { return .ane }
        // Heatsink: TH prefix → classify as SoC (not ambient)
        if k.hasPrefix("th") { return .soc }
        // Memory/SoC
        if k.hasPrefix("tm") || k.hasPrefix("ts") { return .soc }
        // Die temps, thunderbolt
        if k.hasPrefix("td") { return .soc }
        // Battery
        if k.hasPrefix("tb") { return .battery }
        return .unknown
    }
    
    /// Generate a human-readable name for a temperature sensor key.
    private func describeTemperatureKey(_ key: String) -> String {
        let component = classifyTemperatureKey(key)
        switch component {
        case .cpuPerformance: return "CPU \(key)"
        case .cpuEfficiency: return "CPU Efficiency \(key)"
        case .gpu: return "GPU \(key)"
        case .ane: return "ANE \(key)"
        case .soc: return "SoC \(key)"
        case .ambient: return "Ambient \(key)"
        case .battery: return "Battery \(key)"
        default: return "Sensor \(key)"
        }
    }
    
    private func discoverIntelSensors() async throws -> [SensorInfo] {
        var sensors: [SensorInfo] = []
        
        // Intel sensors use traditional SMC keys
        let intelSensorKeys: [(String, String, ComponentType)] = [
            ("TC0C", "CPU Core 1", .cpuPerformance),
            ("TC0D", "CPU Core 2", .cpuPerformance),
            ("TC0E", "CPU Core 3", .cpuPerformance),
            ("TC0F", "CPU Core 4", .cpuPerformance),
            ("TG0D", "GPU Core", .gpu),
            ("TM0P", "Memory Proximity", .soc),
            ("TA0P", "Ambient", .ambient),
            ("TB0T", "Battery", .battery)
        ]
        
        for (key, name, component) in intelSensorKeys {
            if let value = try? await ioKitInterface.readRawValue(key: key), value > 10 && value < 150 {
                let sensor = SensorInfo(
                    key: key,
                    name: name,
                    component: component,
                    currentValue: value,
                    unit: "°C",
                    minValue: 0,
                    maxValue: 100,
                    isActive: true,
                    lastUpdated: Date()
                )
                sensors.append(sensor)
            }
        }
        
        return sensors
    }
    
    private func discoverM1Sensors() async throws -> [SensorInfo] {
        var sensors: [SensorInfo] = []
        
        // M1 sensor mappings
        let m1SensorKeys: [(String, String, ComponentType)] = [
            // CPU Performance Cores
            ("Tp01", "CPU Performance Core 1", .cpuPerformance),
            ("Tp05", "CPU Performance Core 2", .cpuPerformance),
            ("Tp09", "CPU Performance Core 3", .cpuPerformance),
            ("Tp0D", "CPU Performance Core 4", .cpuPerformance),
            ("Tp0H", "CPU Performance Core 5", .cpuPerformance),
            ("Tp0L", "CPU Performance Core 6", .cpuPerformance),
            ("Tp0P", "CPU Performance Core 7", .cpuPerformance),
            ("Tp0X", "CPU Performance Core 8", .cpuPerformance),
            
            // CPU Efficiency Cores
            ("Tp0T", "CPU Efficiency Core 1", .cpuEfficiency),
            
            // GPU Cores
            ("Tg0f", "GPU Core 1", .gpu),
            ("Tg0n", "GPU Core 2", .gpu),
            
            // ANE
            ("TaP0", "ANE Core", .ane),
            
            // System
            ("Tp0P", "SoC", .soc),
            ("Th0H", "Ambient", .ambient),
            ("TB0T", "Battery", .battery)
        ]
        
        for (key, name, component) in m1SensorKeys {
            if let value = try await ioKitInterface.readTemperature(key: key) {
                let sensor = SensorInfo(
                    key: key,
                    name: name,
                    component: component,
                    currentValue: value,
                    unit: "°C",
                    minValue: 0,
                    maxValue: getExpectedMaxTemp(for: component),
                    isActive: true,
                    lastUpdated: Date()
                )
                sensors.append(sensor)
            }
        }
        
        return sensors
    }
    
    private func discoverM2Sensors() async throws -> [SensorInfo] {
        var sensors: [SensorInfo] = []
        
        // M2 sensor mappings (different from M1)
        let m2SensorKeys: [(String, String, ComponentType)] = [
            // CPU Efficiency Cores
            ("Tp05", "CPU Efficiency Core 1", .cpuEfficiency),
            ("Tp0D", "CPU Efficiency Core 2", .cpuEfficiency),
            ("Tp0j", "CPU Efficiency Core 3", .cpuEfficiency),
            ("Tp0r", "CPU Efficiency Core 4", .cpuEfficiency),
            
            // CPU Performance Cores
            ("Tp01", "CPU Performance Core 1", .cpuPerformance),
            ("Tp09", "CPU Performance Core 2", .cpuPerformance),
            ("Tp0f", "CPU Performance Core 3", .cpuPerformance),
            ("Tp0n", "CPU Performance Core 4", .cpuPerformance),
            
            // GPU Cores
            ("Tg0f", "GPU Core 1", .gpu),
            ("Tg0n", "GPU Core 2", .gpu),
            
            // ANE
            ("TaP0", "ANE Core", .ane),
            
            // System
            ("Tp0P", "SoC", .soc),
            ("Th0H", "Ambient", .ambient),
            ("TB0T", "Battery", .battery)
        ]
        
        for (key, name, component) in m2SensorKeys {
            if let value = try await ioKitInterface.readTemperature(key: key) {
                let sensor = SensorInfo(
                    key: key,
                    name: name,
                    component: component,
                    currentValue: value,
                    unit: "°C",
                    minValue: 0,
                    maxValue: getExpectedMaxTemp(for: component),
                    isActive: true,
                    lastUpdated: Date()
                )
                sensors.append(sensor)
            }
        }
        
        return sensors
    }
    
    private func discoverM3Sensors() async throws -> [SensorInfo] {
        var sensors: [SensorInfo] = []
        
        // M3 sensor mappings (enhanced from M2)
        let m3SensorKeys: [(String, String, ComponentType)] = [
            // CPU Performance Cores
            ("Tp01", "CPU Performance Core 1", .cpuPerformance),
            ("Tp09", "CPU Performance Core 2", .cpuPerformance),
            ("Tp0f", "CPU Performance Core 3", .cpuPerformance),
            ("Tp0n", "CPU Performance Core 4", .cpuPerformance),
            ("Tp0b", "CPU Performance Core 5", .cpuPerformance),
            ("Tp0g", "CPU Performance Core 6", .cpuPerformance),
            
            // CPU Efficiency Cores
            ("Tp05", "CPU Efficiency Core 1", .cpuEfficiency),
            ("Tp0D", "CPU Efficiency Core 2", .cpuEfficiency),
            ("Tp0j", "CPU Efficiency Core 3", .cpuEfficiency),
            ("Tp0r", "CPU Efficiency Core 4", .cpuEfficiency),
            
            // GPU Cores (more cores in M3)
            ("Tg0f", "GPU Core 1", .gpu),
            ("Tg0n", "GPU Core 2", .gpu),
            ("Tg0b", "GPU Core 3", .gpu),
            ("Tg0g", "GPU Core 4", .gpu),
            
            // ANE (enhanced)
            ("TaP0", "ANE Core 1", .ane),
            ("TaP1", "ANE Core 2", .ane),
            
            // System
            ("Tp0P", "SoC", .soc),
            ("Th0H", "Ambient", .ambient),
            ("TB0T", "Battery", .battery),
            
            // Additional M3 specific sensors
            ("Tm0P", "Memory Controller", .soc),
            ("Tc0P", "Cache", .soc)
        ]
        
        for (key, name, component) in m3SensorKeys {
            if let value = try await ioKitInterface.readTemperature(key: key) {
                let sensor = SensorInfo(
                    key: key,
                    name: name,
                    component: component,
                    currentValue: value,
                    unit: "°C",
                    minValue: 0,
                    maxValue: getExpectedMaxTemp(for: component),
                    isActive: true,
                    lastUpdated: Date()
                )
                sensors.append(sensor)
            }
        }
        
        return sensors
    }
    
    private func discoverM4Sensors() async throws -> [SensorInfo] {
        // M4 sensors - similar to M3 but with additional optimizations
        var sensors = try await discoverM3Sensors()
        
        // Add M4-specific sensors if available
        let m4SpecificKeys: [(String, String, ComponentType)] = [
            ("TaP2", "ANE Core 3", .ane),
            ("Tm1P", "Memory Controller 2", .soc),
            ("Tc1P", "Cache 2", .soc)
        ]
        
        for (key, name, component) in m4SpecificKeys {
            if let value = try await ioKitInterface.readTemperature(key: key) {
                let sensor = SensorInfo(
                    key: key,
                    name: name,
                    component: component,
                    currentValue: value,
                    unit: "°C",
                    minValue: 0,
                    maxValue: getExpectedMaxTemp(for: component),
                    isActive: true,
                    lastUpdated: Date()
                )
                sensors.append(sensor)
            }
        }
        
        return sensors
    }
    
    private func discoverGenericSensors() async throws -> [SensorInfo] {
        // Fallback for unknown generations - try common sensor keys
        var sensors: [SensorInfo] = []
        
        let genericKeys: [(String, String, ComponentType)] = [
            ("TC0C", "CPU Core", .cpuPerformance),
            ("TG0D", "GPU Core", .gpu),
            ("TM0P", "Memory", .soc),
            ("Th0H", "Ambient", .ambient),
            ("TB0T", "Battery", .battery)
        ]
        
        for (key, name, component) in genericKeys {
            if let value = try await ioKitInterface.readTemperature(key: key) {
                let sensor = SensorInfo(
                    key: key,
                    name: name,
                    component: component,
                    currentValue: value,
                    unit: "°C",
                    minValue: 0,
                    maxValue: getExpectedMaxTemp(for: component),
                    isActive: true,
                    lastUpdated: Date()
                )
                sensors.append(sensor)
            }
        }
        
        return sensors
    }
    
    private func validateSensors(_ sensors: [SensorInfo], hardware: HardwareInfo) async throws -> [SensorInfo] {
        return sensors.filter { sensor in
            // Keep active sensors with valid temperature values,
            // AND inactive sensors (thresholds, config, powered-down)
            // so they appear under the "Show inactive" toggle.
            // Only drop sensors with truly undecodable / nonsensical values.
            sensor.isActive || sensor.currentValue >= 0
        }
    }
    
    private func sortSensors(_ sensors: [SensorInfo]) -> [SensorInfo] {
        return sensors.sorted { sensor1, sensor2 in
            // Active sensors before inactive
            if sensor1.isActive != sensor2.isActive {
                return sensor1.isActive
            }
            // Then by component type, then by name
            if sensor1.component.rawValue != sensor2.component.rawValue {
                return sensor1.component.rawValue < sensor2.component.rawValue
            }
            return sensor1.name < sensor2.name
        }
    }
    
    private func getExpectedMaxTemp(for component: ComponentType) -> Double {
        switch component {
        case .cpuPerformance, .cpuEfficiency:
            return 105.0
        case .gpu:
            return 100.0
        case .ane:
            return 95.0
        case .soc:
            return 90.0
        case .ambient:
            return 60.0
        case .battery:
            return 50.0
        case .unknown:
            return 100.0
        }
    }
    
    // MARK: - Hardware Detection Helpers
    private func getMachineIdentifier() async throws -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        
        return String(cString: machine)
    }
    
    private func getChipType() async throws -> String {
        // Try to get chip info from system profiler
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["-n", "machdep.cpu.brand_string"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func getCoreCount() async throws -> Int {
        return ProcessInfo.processInfo.processorCount
    }
    
    private func getPerformanceCoreCount() async throws -> Int {
        // This would need more complex detection - simplified for now
        return ProcessInfo.processInfo.processorCount / 2
    }
    
    private func getEfficiencyCoreCount() async throws -> Int {
        return ProcessInfo.processInfo.processorCount / 2
    }
    
    private func getGPUCoreCount() async throws -> Int {
        // Would need GPU-specific detection
        return 8 // Default
    }
    
    private func checkFanPresence() async throws -> Bool {
        // Try to read fan information
        return try await ioKitInterface.hasFans()
    }
    
    private func getFanCount() async throws -> Int {
        return try await ioKitInterface.getFanCount()
    }
    
    private func getMaxFanSpeed() async throws -> Double {
        return try await ioKitInterface.getMaxFanSpeed()
    }
    
    private func getModelIdentifier() async throws -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        
        return String(cString: model)
    }
    
    private func getChipInfo() async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPHardwareDataType", "-json"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hardwareData = json["SPHardwareDataType"] as? [[String: Any]],
           let hardware = hardwareData.first,
           let chip = hardware["chip_type"] as? String {
            return chip
        }
        
        return "Unknown"
    }
}

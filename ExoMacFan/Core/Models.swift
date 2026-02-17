// ============================================================
// File: Models.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-17
// Description: Core data models for thermal monitoring and sensors
// ============================================================

import Foundation
import SwiftUI

// MARK: - Thermal Pressure Levels
enum ThermalPressureLevel: Int, CaseIterable, Codable {
    case nominal = 0     // Normal operation
    case moderate = 1     // Light thermal stress
    case heavy = 2        // Throttling begins
    case trapping = 3     // Critical thermal state
    case sleeping = 4     // Emergency protection
    
    var displayName: String {
        switch self {
        case .nominal: return "Nominal"
        case .moderate: return "Moderate"
        case .heavy: return "Heavy"
        case .trapping: return "Critical"
        case .sleeping: return "Emergency"
        }
    }
    
    var color: Color {
        switch self {
        case .nominal: return .green
        case .moderate: return .yellow
        case .heavy: return .orange
        case .trapping: return .red
        case .sleeping: return .purple
        }
    }
    
    var icon: String {
        switch self {
        case .nominal: return "thermometer.sun"
        case .moderate: return "thermometer.medium"
        case .heavy: return "thermometer.high"
        case .trapping: return "thermometer.sun.fill"
        case .sleeping: return "exclamationmark.triangle.fill"
        }
    }
    
    var description: String {
        switch self {
        case .nominal: return "Normal thermal state"
        case .moderate: return "Light thermal stress"
        case .heavy: return "Throttling may occur"
        case .trapping: return "Critical thermal state"
        case .sleeping: return "Emergency protection active"
        }
    }
}

// MARK: - Component Types
enum ComponentType: String, CaseIterable, Codable {
    case cpuPerformance = "CPU Performance"
    case cpuEfficiency = "CPU Efficiency"
    case gpu = "GPU"
    case ane = "ANE"
    case soc = "SoC"
    case ambient = "Ambient"
    case battery = "Battery"
    case unknown = "Unknown"
    
    var icon: String {
        switch self {
        case .cpuPerformance: return "cpu"
        case .cpuEfficiency: return "cpu"
        case .gpu: return "gpu"
        case .ane: return "brain.head.profile"
        case .soc: return "memorychip"
        case .ambient: return "thermometer"
        case .battery: return "battery.100"
        case .unknown: return "questionmark.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .cpuPerformance: return .blue
        case .cpuEfficiency: return .cyan
        case .gpu: return .purple
        case .ane: return .pink
        case .soc: return .orange
        case .ambient: return .green
        case .battery: return .mint
        case .unknown: return .gray
        }
    }
}

// MARK: - Sensor Information
struct SensorInfo: Identifiable, Codable {
    var id: String { key }
    let key: String
    let name: String
    let component: ComponentType
    let currentValue: Double
    let unit: String
    let minValue: Double
    let maxValue: Double
    let isActive: Bool
    let lastUpdated: Date
    
    init(key: String, name: String, component: ComponentType, currentValue: Double, unit: String, minValue: Double, maxValue: Double, isActive: Bool, lastUpdated: Date) {
        self.key = key
        self.name = name
        self.component = component
        self.currentValue = currentValue
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.isActive = isActive
        self.lastUpdated = lastUpdated
    }
    
    var formattedValue: String {
        return String(format: "%.1f %@", currentValue, unit)
    }
    
    var percentageOfMax: Double {
        guard maxValue > minValue else { return 0 }
        return min(1.0, max(0.0, (currentValue - minValue) / (maxValue - minValue)))
    }
}

// MARK: - Thermal State
struct ThermalState: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let pressureLevel: ThermalPressureLevel
    let componentTemperatures: [ComponentType: Double]
    let fanSpeed: Double?           // Primary fan RPM (backward compat)
    let fanSpeeds: [Int: Double]    // All fan RPMs keyed by fan index
    let isThrottling: Bool
    let throttlingComponents: Set<ComponentType>
    
    init(timestamp: Date, pressureLevel: ThermalPressureLevel, componentTemperatures: [ComponentType: Double], fanSpeed: Double?, isThrottling: Bool, throttlingComponents: Set<ComponentType>, fanSpeeds: [Int: Double] = [:]) {
        self.id = UUID()
        self.timestamp = timestamp
        self.pressureLevel = pressureLevel
        self.componentTemperatures = componentTemperatures
        self.fanSpeed = fanSpeed
        self.fanSpeeds = fanSpeeds
        self.isThrottling = isThrottling
        self.throttlingComponents = throttlingComponents
    }
    
    var maxTemperature: Double {
        componentTemperatures.values.max() ?? 0
    }
    
    var averageTemperature: Double {
        guard !componentTemperatures.isEmpty else { return 0 }
        return componentTemperatures.values.reduce(0, +) / Double(componentTemperatures.count)
    }
}

// MARK: - Fan Information
struct FanInfo: Identifiable, Codable {
    let id: UUID
    let fanIndex: Int
    let currentSpeed: Double
    let maxSpeed: Double
    let minSpeed: Double
    let targetSpeed: Double
    let isControlled: Bool
    let lastUpdated: Date
    
    var speedPercentage: Double {
        guard maxSpeed > 0 else { return 0 }
        return currentSpeed / maxSpeed * 100
    }
    
    init(fanIndex: Int, currentSpeed: Double, maxSpeed: Double, minSpeed: Double, targetSpeed: Double, isControlled: Bool, lastUpdated: Date) {
        self.id = UUID()
        self.fanIndex = fanIndex
        self.currentSpeed = currentSpeed
        self.maxSpeed = maxSpeed
        self.minSpeed = minSpeed
        self.targetSpeed = targetSpeed
        self.isControlled = isControlled
        self.lastUpdated = lastUpdated
    }
    
    var formattedSpeed: String {
        return "\(currentSpeed.safeInt) RPM"
    }
    
    var status: String {
        if isControlled {
            return "Controlled"
        } else {
            return "Auto"
        }
    }
}

// MARK: - Mac Generation Information
enum MacGeneration: String, CaseIterable, Codable {
    case intel = "Intel"
    case m1 = "Apple M1"
    case m2 = "Apple M2"
    case m3 = "Apple M3"
    case m4 = "Apple M4"
    case m5 = "Apple M5"
    case unknown = "Unknown"
    
    var displayName: String {
        return rawValue
    }
    
    var chipImage: String {
        switch self {
        case .intel: return "cpu"
        case .m1, .m2, .m3, .m4, .m5: return "cpu"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Hardware Information
struct HardwareInfo: Codable {
    let macGeneration: MacGeneration
    let chipType: String
    let coreCount: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int
    let hasFans: Bool
    let fanCount: Int
    let maxFanSpeed: Double
    let modelIdentifier: String
    
    var totalCores: Int {
        performanceCores + efficiencyCores
    }
}

// MARK: - Fan Control Mode
enum FanControlMode: String, CaseIterable, Identifiable, Codable {
    case macosDefault = "macOS Default"
    case silent = "Silent"
    case normal = "Pro-Active"
    case maxFans = "Max Fans"
    case custom = "Custom"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .macosDefault:
            return "Let macOS control fan speeds automatically"
        case .silent:
            return "Minimal fan noise - fans only activate when thermal throttling occurs"
        case .normal:
            return "Pro-Active control - ramps fan speed up near thermal limits and backs off with headroom"
        case .maxFans:
            return "Maximum cooling - fans at full speed for best performance"
        case .custom:
            return "Manual fan speed control - set your own speed"
        }
    }
    
    var icon: String {
        switch self {
        case .macosDefault:
            return "cpu"
        case .silent:
            return "speaker.slash"
        case .normal:
            return "fan"
        case .maxFans:
            return "speedometer"
        case .custom:
            return "slider.horizontal.3"
        }
    }
    
    var color: Color {
        switch self {
        case .macosDefault:
            return .green
        case .silent:
            return .blue
        case .normal:
            return .orange
        case .maxFans:
            return .red
        case .custom:
            return .purple
        }
    }
    
    // Fan speed percentage based on thermal pressure
    func fanSpeed(for pressureLevel: ThermalPressureLevel) -> Double {
        switch self {
        case .macosDefault:
            return 0 // System controlled
        case .silent:
            // Only activate fans when throttling (heavy or above)
            switch pressureLevel {
            case .nominal, .moderate:
                return 0
            case .heavy:
                return 60
            case .trapping:
                return 85
            case .sleeping:
                return 100
            }
        case .normal:
            // Proactive thermal management
            switch pressureLevel {
            case .nominal:
                return 25
            case .moderate:
                return 45
            case .heavy:
                return 75
            case .trapping:
                return 95
            case .sleeping:
                return 100
            }
        case .maxFans:
            return 100 // Always full blast
        case .custom:
            return 0 // User controlled
        }
    }
}

// MARK: - Fan Profile
struct FanProfile: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String
    let mode: FanControlMode
    let customSpeed: Double? // For custom mode
    let pressureCurve: [ThermalPressureLevel: Double]
    let temperatureCurve: [ComponentType: Double]
    let maxFanSpeed: Double
    let safetyLimits: SafetyLimits
    let isActive: Bool
    
    init(name: String, description: String, mode: FanControlMode, customSpeed: Double?, pressureCurve: [ThermalPressureLevel: Double], temperatureCurve: [ComponentType: Double], maxFanSpeed: Double, safetyLimits: SafetyLimits, isActive: Bool) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.mode = mode
        self.customSpeed = customSpeed
        self.pressureCurve = pressureCurve
        self.temperatureCurve = temperatureCurve
        self.maxFanSpeed = maxFanSpeed
        self.safetyLimits = safetyLimits
        self.isActive = isActive
    }
    
    static let `default` = FanProfile(
        name: "Pro-Active",
        description: "Dynamic cooling to avoid throttling",
        mode: .normal,
        customSpeed: nil,
        pressureCurve: [
            .nominal: 25.0,
            .moderate: 45.0,
            .heavy: 75.0,
            .trapping: 95.0,
            .sleeping: 100.0
        ],
        temperatureCurve: [:],
        maxFanSpeed: 100.0,
        safetyLimits: SafetyLimits.default,
        isActive: true
    )
    
    static let silent = FanProfile(
        name: "Silent",
        description: "Minimal fan noise",
        mode: .silent,
        customSpeed: nil,
        pressureCurve: [
            .nominal: 0.0,
            .moderate: 0.0,
            .heavy: 60.0,
            .trapping: 85.0,
            .sleeping: 100.0
        ],
        temperatureCurve: [:],
        maxFanSpeed: 100.0,
        safetyLimits: SafetyLimits.default,
        isActive: false
    )
    
    static let maxFans = FanProfile(
        name: "Max Fans",
        description: "Maximum cooling",
        mode: .maxFans,
        customSpeed: nil,
        pressureCurve: [
            .nominal: 100.0,
            .moderate: 100.0,
            .heavy: 100.0,
            .trapping: 100.0,
            .sleeping: 100.0
        ],
        temperatureCurve: [:],
        maxFanSpeed: 100.0,
        safetyLimits: SafetyLimits.default,
        isActive: false
    )
    
    static let macosDefault = FanProfile(
        name: "macOS Default",
        description: "System controlled",
        mode: .macosDefault,
        customSpeed: nil,
        pressureCurve: [:],
        temperatureCurve: [:],
        maxFanSpeed: 100.0,
        safetyLimits: SafetyLimits.default,
        isActive: false
    )
    
    static func custom(speed: Double) -> FanProfile {
        return FanProfile(
            name: "Custom",
            description: "Manual speed: \(speed.safeInt)%",
            mode: .custom,
            customSpeed: speed,
            pressureCurve: [
                .nominal: speed,
                .moderate: speed,
                .heavy: speed,
                .trapping: speed,
                .sleeping: speed
            ],
            temperatureCurve: [:],
            maxFanSpeed: 100.0,
            safetyLimits: SafetyLimits.default,
            isActive: false
        )
    }
}

// MARK: - Safety Limits
struct SafetyLimits: Codable {
    let maxCPUTemperature: Double
    let maxGPUTemperature: Double
    let maxANETemperature: Double
    let maxFanRPMChange: Double
    let emergencyShutdownTemp: Double
    let minFanSpeed: Double
    let maxFanSpeed: Double
    
    static let `default` = SafetyLimits(
        maxCPUTemperature: 105.0,
        maxGPUTemperature: 100.0,
        maxANETemperature: 95.0,
        maxFanRPMChange: 500.0,
        emergencyShutdownTemp: 110.0,
        minFanSpeed: 1000.0,
        maxFanSpeed: 6000.0
    )
}

// MARK: - Thermal Analysis
struct ThermalAnalysis: Codable {
    let period: TimePeriod
    let averageTemperature: Double
    let maxTemperature: Double
    let minTemperature: Double
    let throttlingEvents: Int
    let averageFanSpeed: Double
    let thermalPressureDistribution: [ThermalPressureLevel: TimeInterval]
    
    var riskLevel: RiskLevel {
        if throttlingEvents > 10 {
            return .high
        } else if throttlingEvents > 3 {
            return .medium
        } else {
            return .low
        }
    }
}

enum RiskLevel: String, CaseIterable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}

enum TimePeriod: String, CaseIterable, Codable {
    case last5Min = "5 min"
    case last15Min = "15 min"
    case lastHour = "1 hour"
    case last6Hours = "6 hours"
    case all = "All"
    
    var timeInterval: TimeInterval {
        switch self {
        case .last5Min: return 300
        case .last15Min: return 900
        case .lastHour: return 3600
        case .last6Hours: return 21600
        case .all: return .infinity
        }
    }
}

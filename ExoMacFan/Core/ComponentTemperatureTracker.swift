// ============================================================
// File: ComponentTemperatureTracker.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Description: Component-specific temperature monitoring and throttling detection
// ============================================================

import Foundation
import Combine
import IOKit

@MainActor
class ComponentTemperatureTracker: ObservableObject {
    // MARK: - Published Properties
    @Published var temperatures: [ComponentType: Double] = [:]
    @Published var isThrottling: Bool = false
    @Published var throttlingComponents: Set<ComponentType> = []
    @Published var error: Error?
    
    // MARK: - Private Properties
    private let ioKitInterface = IOKitInterface.shared
    private var updateTimer: Timer?
    private var updateInterval: TimeInterval = 2.0
    private var isMonitoring = false
    // Track per-key readings to detect static threshold registers
    private var lastKeyValues: [String: Double] = [:]
    private var staticKeyCount: [String: Int] = [:]
    
    // Component-specific sensor mappings (Apple Silicon + Intel fallbacks)
    private let componentSensorMappings: [ComponentType: [String]] = [
        .cpuPerformance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X",
                          "TC0P", "TC1P", "TC2P", "TCHP", "TCMb"],
        .cpuEfficiency: ["Tp0T", "Tp0j", "Tp0r", "TC0E", "TC1E"],
        .gpu: ["Tg0f", "Tg0n", "Tg0b", "Tg0g", "TG0B", "TG0V", "TG1B", "TG2B"],
        .ane: ["TaP0", "TaP1", "TaP2"],
        .soc: ["Tp0P", "Tm0P", "Tm1P", "Tc0P", "Tc1P", "TDTC", "TDTP", "TH0a", "TH0b", "Th0H"],
        .ambient: ["TA0P", "TAOL"],
        .battery: ["TB0T", "TB1T", "TB2T"]
    ]
    
    // Throttling thresholds by component
    private let throttlingThresholds: [ComponentType: Double] = [
        .cpuPerformance: 95.0,
        .cpuEfficiency: 95.0,
        .gpu: 90.0,
        .ane: 85.0,
        .soc: 85.0,
        .ambient: 45.0,
        .battery: 45.0
    ]
    
    // MARK: - Public Methods
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        
        // Start update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
            Task { @MainActor in
                await self.updateTemperatures()
            }
        }
        
        // Initial update
        Task { @MainActor in
            await updateTemperatures()
        }
        
        print("🌡️ Component temperature monitoring started")
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        
        updateTimer?.invalidate()
        updateTimer = nil
        
        print("🌡️ Component temperature monitoring stopped")
    }

    func setPollingInterval(_ interval: TimeInterval) {
        updateInterval = interval
        if isMonitoring {
            updateTimer?.invalidate()
            updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
                Task { @MainActor in
                    await self.updateTemperatures()
                }
            }
        }
    }
    
    func getTemperature(for component: ComponentType) -> Double? {
        return temperatures[component]
    }
    
    func isComponentThrottling(_ component: ComponentType) -> Bool {
        guard let temperature = temperatures[component],
              let threshold = throttlingThresholds[component] else {
            return false
        }
        
        return temperature >= threshold
    }
    
    func getThrottlingStatus(for component: ComponentType) -> ThrottlingStatus {
        guard let temperature = temperatures[component],
              let threshold = throttlingThresholds[component] else {
            return .unknown
        }
        
        let percentage = (temperature / threshold) * 100
        
        if percentage < 80 {
            return .normal
        } else if percentage < 95 {
            return .moderate
        } else if percentage < 105 {
            return .heavy
        } else {
            return .critical
        }
    }
    
    // MARK: - Private Methods
    private func updateTemperatures() async {
        var newTemperatures: [ComponentType: Double] = [:]
        var newThrottlingComponents: Set<ComponentType> = []
        
        // Capture previous state BEFORE updating
        let previousTemperatures = temperatures
        let previousThrottlingComponents = throttlingComponents
        
        for (component, sensorKeys) in componentSensorMappings {
            var componentTemperatures: [Double] = []

            for sensorKey in sensorKeys {
                if let temperature = try? await ioKitInterface.readTemperature(key: sensorKey) {
                    // Skip readings outside realistic range for a running Mac
                    // No real component reads below 10°C; such values are
                    // threshold registers or config data, not live sensors.
                    guard temperature > 10.0 && temperature < 110.0 else { continue }

                    // Detect static threshold registers: if value is identical
                    // across 3+ reads it's a config register, not a live sensor
                    if let prev = lastKeyValues[sensorKey],
                       abs(temperature - prev) < 0.01 {
                        staticKeyCount[sensorKey, default: 0] += 1
                    } else {
                        staticKeyCount[sensorKey] = 0
                    }
                    lastKeyValues[sensorKey] = temperature

                    if (staticKeyCount[sensorKey] ?? 0) >= 3 {
                        continue // skip static threshold value
                    }

                    componentTemperatures.append(temperature)
                }
            }

            if !componentTemperatures.isEmpty {
                let maxTemperature = componentTemperatures.max() ?? 0
                newTemperatures[component] = maxTemperature

                if let threshold = throttlingThresholds[component],
                   maxTemperature >= threshold {
                    newThrottlingComponents.insert(component)
                }
            } else if let prev = previousTemperatures[component], prev > 10.0 {
                // Keep previous valid reading if current read failed
                newTemperatures[component] = prev
            }
        }
        
        // Log significant changes BEFORE updating published properties
        logSignificantChanges(
            oldTemperatures: previousTemperatures,
            newTemperatures: newTemperatures,
            oldThrottling: previousThrottlingComponents,
            newThrottling: newThrottlingComponents
        )
        
        // Update published properties
        temperatures = newTemperatures
        throttlingComponents = newThrottlingComponents
        isThrottling = !newThrottlingComponents.isEmpty
    }
    
    private func logSignificantChanges(
        oldTemperatures: [ComponentType: Double],
        newTemperatures: [ComponentType: Double],
        oldThrottling: Set<ComponentType>,
        newThrottling: Set<ComponentType>
    ) {
        for (component, newTemp) in newTemperatures {
            let oldTemp = oldTemperatures[component] ?? 0
            
            // Log significant temperature changes (>10°C)
            if abs(newTemp - oldTemp) > 10 {
                print("🌡️ \(component.rawValue): \(oldTemp.safeInt)°C → \(newTemp.safeInt)°C")
            }
            
            // Log throttling events
            let wasThrottling = oldThrottling.contains(component)
            let isNowThrottling = newThrottling.contains(component)
            
            if !wasThrottling && isNowThrottling {
                print("⚠️ \(component.rawValue) started throttling at \(newTemp.safeInt)°C")
            } else if wasThrottling && !isNowThrottling {
                print("✅ \(component.rawValue) stopped throttling at \(newTemp.safeInt)°C")
            }
        }
    }
}

// MARK: - Throttling Status
enum ThrottlingStatus: String, CaseIterable {
    case normal = "Normal"
    case moderate = "Moderate"
    case heavy = "Heavy"
    case critical = "Critical"
    case unknown = "Unknown"
    
    var icon: String {
        switch self {
        case .normal: return "checkmark.circle"
        case .moderate: return "exclamationmark.triangle"
        case .heavy: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

// ============================================================
// File: ThermalHistoryLogger.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Thermal history logging and analytics
// ============================================================

import Foundation
import Combine

@MainActor
class ThermalHistoryLogger: ObservableObject {
    // MARK: - Properties
    private var thermalHistory: [ThermalState] = []
    private let maxHistoryCount = 10000 // Keep last 10,000 entries
    private let saveInterval: TimeInterval = 300 // Save every 5 minutes
    private var saveTimer: Timer?
    
    private let documentsURL: URL
    private let historyFileURL: URL
    
    // MARK: - Initialization
    init() {
        // Get documents directory
        documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        historyFileURL = documentsURL.appendingPathComponent("ExoMacFan_thermal_history.json")
        
        // Load existing history
        loadHistory()
        
        // Start save timer
        startSaveTimer()
    }
    
    deinit {
        saveTimer?.invalidate()
    }
    
    // MARK: - Public Methods
    func logState(_ state: ThermalState) {
        thermalHistory.append(state)
        
        // Trim history if too large
        if thermalHistory.count > maxHistoryCount {
            thermalHistory.removeFirst(thermalHistory.count - maxHistoryCount)
        }
        
        // Log significant events
        logSignificantEvents(state)
    }
    
    func getHistory(for period: TimePeriod) -> [ThermalState] {
        if period == .all { return thermalHistory }
        let cutoffDate = Date().addingTimeInterval(-period.timeInterval)
        return thermalHistory.filter { $0.timestamp >= cutoffDate }
    }
    
    func getAnalysis(for period: TimePeriod) -> ThermalAnalysis? {
        let history = getHistory(for: period)
        guard !history.isEmpty else { return nil }
        
        let temperatures = history.flatMap { $0.componentTemperatures.values }
        let averageTemperature = temperatures.isEmpty ? 0 : temperatures.reduce(0, +) / Double(temperatures.count)
        let maxTemperature = temperatures.max() ?? 0
        let minTemperature = temperatures.min() ?? 0
        
        let throttlingEvents = history.filter { $0.isThrottling }.count
        
        let fanSpeeds = history.compactMap { $0.fanSpeed }
        let averageFanSpeed = fanSpeeds.isEmpty ? 0 : fanSpeeds.reduce(0, +) / Double(fanSpeeds.count)
        
        // Calculate pressure distribution
        var pressureDistribution: [ThermalPressureLevel: TimeInterval] = [:]
        var previousTime: Date?
        
        for state in history {
            if let previousTime = previousTime {
                let duration = state.timestamp.timeIntervalSince(previousTime)
                pressureDistribution[state.pressureLevel, default: 0] += duration
            }
            previousTime = state.timestamp
        }
        
        return ThermalAnalysis(
            period: period,
            averageTemperature: averageTemperature,
            maxTemperature: maxTemperature,
            minTemperature: minTemperature,
            throttlingEvents: throttlingEvents,
            averageFanSpeed: averageFanSpeed,
            thermalPressureDistribution: pressureDistribution
        )
    }
    
    func exportHistory() -> Data? {
        do {
            return try JSONEncoder().encode(thermalHistory)
        } catch {
            print("Failed to export history: \(error)")
            return nil
        }
    }
    
    func clearHistory() {
        thermalHistory.removeAll()
        saveHistory()
        print("📊 Thermal history cleared")
    }
    
    func getStatistics() -> ThermalStatistics? {
        guard !thermalHistory.isEmpty else { return nil }
        
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let oneDayAgo = now.addingTimeInterval(-86400)
        let oneWeekAgo = now.addingTimeInterval(-604800)
        
        let recentHour = thermalHistory.filter { $0.timestamp >= oneHourAgo }
        let recentDay = thermalHistory.filter { $0.timestamp >= oneDayAgo }
        let recentWeek = thermalHistory.filter { $0.timestamp >= oneWeekAgo }
        
        return ThermalStatistics(
            lastHour: calculateStats(for: recentHour),
            lastDay: calculateStats(for: recentDay),
            lastWeek: calculateStats(for: recentWeek),
            allTime: calculateStats(for: thermalHistory)
        )
    }
    
    // MARK: - Private Methods
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: historyFileURL)
            thermalHistory = try JSONDecoder().decode([ThermalState].self, from: data)
            print("📊 Loaded \(thermalHistory.count) thermal history entries")
        } catch {
            print("📊 Failed to load thermal history: \(error)")
            thermalHistory = []
        }
    }
    
    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(thermalHistory)
            try data.write(to: historyFileURL)
        } catch {
            print("📊 Failed to save thermal history: \(error)")
        }
    }
    
    private func startSaveTimer() {
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveHistory()
            }
        }
    }
    
    private func logSignificantEvents(_ state: ThermalState) {
        // Log throttling events
        if state.isThrottling {
            let components = state.throttlingComponents.map(\.rawValue).joined(separator: ", ")
            print("⚠️ THROTTLING: \(components) at \(state.maxTemperature.safeInt)°C")
        }
        
        // Log critical pressure levels
        if state.pressureLevel == .trapping || state.pressureLevel == .sleeping {
            print("🚨 CRITICAL: Thermal pressure \(state.pressureLevel.displayName)")
        }
        
        // Log high temperatures
        for (component, temperature) in state.componentTemperatures {
            let threshold: Double
            switch component {
            case .cpuPerformance, .cpuEfficiency:
                threshold = 100.0
            case .gpu:
                threshold = 95.0
            case .ane:
                threshold = 90.0
            case .soc:
                threshold = 95.0 // includes heatsink sensors which run 60-80°C normally
            case .battery:
                threshold = 45.0
            default:
                threshold = 95.0
            }
            
            if temperature >= threshold {
                print("🔥 HIGH TEMP: \(component.rawValue) \(temperature.safeInt)°C")
            }
        }
    }
    
    private func calculateStats(for history: [ThermalState]) -> PeriodStatistics {
        guard !history.isEmpty else {
            return PeriodStatistics(
                averageTemperature: 0,
                maxTemperature: 0,
                minTemperature: 0,
                throttlingEvents: 0,
                averageFanSpeed: 0,
                dominantPressureLevel: .nominal,
                dataPoints: 0
            )
        }
        
        let temperatures = history.flatMap { $0.componentTemperatures.values }
        let averageTemperature = temperatures.isEmpty ? 0 : temperatures.reduce(0, +) / Double(temperatures.count)
        let maxTemperature = temperatures.max() ?? 0
        let minTemperature = temperatures.min() ?? 0
        
        let throttlingEvents = history.filter { $0.isThrottling }.count
        
        let fanSpeeds = history.compactMap { $0.fanSpeed }
        let averageFanSpeed = fanSpeeds.isEmpty ? 0 : fanSpeeds.reduce(0, +) / Double(fanSpeeds.count)
        
        // Find dominant pressure level
        let pressureCounts = Dictionary(grouping: history, by: { $0.pressureLevel })
        let dominantPressureLevel = pressureCounts.max { $0.value.count < $1.value.count }?.key ?? .nominal
        
        return PeriodStatistics(
            averageTemperature: averageTemperature,
            maxTemperature: maxTemperature,
            minTemperature: minTemperature,
            throttlingEvents: throttlingEvents,
            averageFanSpeed: averageFanSpeed,
            dominantPressureLevel: dominantPressureLevel,
            dataPoints: history.count
        )
    }
}

// MARK: - Supporting Types
struct ThermalStatistics {
    let lastHour: PeriodStatistics
    let lastDay: PeriodStatistics
    let lastWeek: PeriodStatistics
    let allTime: PeriodStatistics
}

struct PeriodStatistics {
    let averageTemperature: Double
    let maxTemperature: Double
    let minTemperature: Double
    let throttlingEvents: Int
    let averageFanSpeed: Double
    let dominantPressureLevel: ThermalPressureLevel
    let dataPoints: Int
    
    var formattedAverageTemp: String {
        return "\(averageTemperature.safeInt)°C"
    }
    
    var formattedMaxTemp: String {
        return "\(maxTemperature.safeInt)°C"
    }
    
    var formattedMinTemp: String {
        return "\(minTemperature.safeInt)°C"
    }
    
    var formattedFanSpeed: String {
        return "\(averageFanSpeed.safeInt) RPM"
    }
    
    var throttlingPercentage: Double {
        guard dataPoints > 0 else { return 0 }
        return (Double(throttlingEvents) / Double(dataPoints)) * 100
    }
    
    var formattedThrottlingPercentage: String {
        return String(format: "%.1f%%", throttlingPercentage)
    }
}

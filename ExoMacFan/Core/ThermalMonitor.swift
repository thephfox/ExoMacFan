// ============================================================
// File: ThermalMonitor.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Central thermal monitoring coordinator
// ============================================================

import Foundation
import SwiftUI
import Combine

@MainActor
class ThermalMonitor: ObservableObject {
    // MARK: - Published Properties
    @Published var currentPressureLevel: ThermalPressureLevel = .nominal
    @Published var componentTemperatures: [ComponentType: Double] = [:]
    @Published var isThrottling: Bool = false
    @Published var throttlingComponents: Set<ComponentType> = []
    @Published var fanSpeeds: [FanInfo] = []
    @Published var currentThermalState: ThermalState?
    @Published var isMonitoring: Bool = false
    @Published var lastError: Error?
    @Published var fanControlError: String?
    @Published var currentFanMode: FanControlMode = .macosDefault
    @Published var isControllingFans: Bool = false
    
    // MARK: - Private Properties
    private let pressureDetector = PressureLevelDetector()
    private let temperatureTracker = ComponentTemperatureTracker()
    private let fanController = FanController()
    private let historyLogger = ThermalHistoryLogger()
    
    private var cancellables = Set<AnyCancellable>()
    private var updateTimer: Timer?
    private var foregroundInterval: TimeInterval = 2.0
    private let backgroundInterval: TimeInterval = 15.0
    private var currentInterval: TimeInterval = 2.0
    private var isAppActive: Bool = true

    // MARK: - Initialization
    init() {
        setupBindings()
        observeAppLifecycle()
    }
    
    // MARK: - Public Methods

    /// Called once on app launch to clean up stale Ftst from a previous crash.
    func ensureSystemControlOnStartup() {
        fanController.ensureSystemControlOnStartup()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        
        // Start individual monitoring systems
        pressureDetector.startMonitoring()
        temperatureTracker.startMonitoring()
        fanController.startMonitoring()
        
        // Start update timer
        startUpdateTimer()
        
        // Log initial state
        logCurrentState()
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        
        // Stop individual monitoring systems
        pressureDetector.stopMonitoring()
        temperatureTracker.stopMonitoring()
        fanController.stopMonitoring()
        
        // Stop update timer
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    func setFanProfile(_ profile: FanProfile) {
        fanController.setFanProfile(profile)
    }
    
    func getCurrentFanProfile() -> FanProfile? {
        return fanController.getCurrentProfile()
    }
    
    func returnToSystemControl() {
        fanController.returnToSystemControl()
    }

    func startFanControl() async {
        await fanController.startFanControl()
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let newInterval = max(1.0, interval)
        foregroundInterval = newInterval
        if isAppActive {
            currentInterval = newInterval
            temperatureTracker.setPollingInterval(newInterval)
            fanController.setPollingInterval(newInterval)
            if isMonitoring { startUpdateTimer() }
        }
    }
    
    func getThermalHistory(for period: TimePeriod) -> [ThermalState] {
        return historyLogger.getHistory(for: period)
    }
    
    func getThermalAnalysis(for period: TimePeriod) -> ThermalAnalysis? {
        return historyLogger.getAnalysis(for: period)
    }
    
    func exportHistory() -> Data? {
        return historyLogger.exportHistory()
    }
    
    func clearHistory() {
        historyLogger.clearHistory()
    }
    
    // MARK: - Private Methods
    private func setupBindings() {
        // Pressure level changes
        pressureDetector.$currentPressureLevel
            .receive(on: DispatchQueue.main)
            .assign(to: \.currentPressureLevel, on: self)
            .store(in: &cancellables)
        
        // Temperature changes
        temperatureTracker.$temperatures
            .receive(on: DispatchQueue.main)
            .assign(to: \.componentTemperatures, on: self)
            .store(in: &cancellables)
        
        // Throttling detection
        temperatureTracker.$isThrottling
            .receive(on: DispatchQueue.main)
            .assign(to: \.isThrottling, on: self)
            .store(in: &cancellables)
        
        temperatureTracker.$throttlingComponents
            .receive(on: DispatchQueue.main)
            .assign(to: \.throttlingComponents, on: self)
            .store(in: &cancellables)
        
        // Fan speed changes
        fanController.$fanSpeeds
            .receive(on: DispatchQueue.main)
            .assign(to: \.fanSpeeds, on: self)
            .store(in: &cancellables)

        // Fan control state
        fanController.$currentProfile
            .receive(on: DispatchQueue.main)
            .map { $0.mode }
            .assign(to: \.currentFanMode, on: self)
            .store(in: &cancellables)

        fanController.$isControllingFans
            .receive(on: DispatchQueue.main)
            .assign(to: \.isControllingFans, on: self)
            .store(in: &cancellables)

        // Feed live thermal context to fan controller for Pro-Active decisions.
        Publishers.CombineLatest(
            pressureDetector.$currentPressureLevel,
            temperatureTracker.$temperatures
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] pressureLevel, temperatures in
            self?.fanController.updateThermalContext(
                pressureLevel: pressureLevel,
                componentTemperatures: temperatures
            )
        }
        .store(in: &cancellables)
        
        // Error handling
        pressureDetector.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: \.lastError, on: self)
            .store(in: &cancellables)
        
        temperatureTracker.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: \.lastError, on: self)
            .store(in: &cancellables)
        
        fanController.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.lastError = error
                self?.fanControlError = error.localizedDescription
            }
            .store(in: &cancellables)
    }
    
    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { _ in
            Task { @MainActor in
                self.updateThermalState()
            }
        }
    }

    /// Watch for app activation/deactivation to throttle background polling.
    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setActive(true) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setActive(false) }
            .store(in: &cancellables)
    }

    private func setActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        let newInterval = active ? foregroundInterval : backgroundInterval
        guard newInterval != currentInterval else { return }
        currentInterval = newInterval
        temperatureTracker.setPollingInterval(newInterval)
        fanController.setPollingInterval(newInterval)
        if isMonitoring {
            startUpdateTimer() // restart with new interval
        }
    }
    
    private func updateThermalState() {
        // Collect all fan speeds into a dictionary keyed by fan index
        var allFanSpeeds: [Int: Double] = [:]
        for fan in fanSpeeds {
            allFanSpeeds[fan.fanIndex] = fan.currentSpeed
        }

        let state = ThermalState(
            timestamp: Date(),
            pressureLevel: currentPressureLevel,
            componentTemperatures: componentTemperatures,
            fanSpeed: fanSpeeds.first?.currentSpeed,
            isThrottling: isThrottling,
            throttlingComponents: throttlingComponents,
            fanSpeeds: allFanSpeeds
        )
        
        currentThermalState = state
        
        // Log state
        historyLogger.logState(state)
        
        // Post notification
        NotificationCenter.default.post(
            name: .thermalStateChanged,
            object: state
        )
        
        // Check for critical conditions
        checkCriticalConditions(state)
    }
    
    private func checkCriticalConditions(_ state: ThermalState) {
        // Check for emergency temperatures
        for (component, temperature) in state.componentTemperatures {
            let limit: Double
            
            switch component {
            case .cpuPerformance, .cpuEfficiency:
                limit = SafetyLimits.default.maxCPUTemperature
            case .gpu:
                limit = SafetyLimits.default.maxGPUTemperature
            case .ane:
                limit = SafetyLimits.default.maxANETemperature
            default:
                continue
            }
            
            if temperature >= limit {
                handleCriticalTemperature(component, temperature)
            }
        }
        
        // Check for emergency pressure level
        if state.pressureLevel == .sleeping {
            handleEmergencyPressure()
        }
    }
    
    private func handleCriticalTemperature(_ component: ComponentType, _ temperature: Double) {
        // Force maximum fan speed
        fanController.setMaximumFanSpeed()
        
        // Send notification
        let notification = Notification(
            name: .thermalError,
            object: ThermalError.criticalTemperature(component: component, temperature: temperature)
        )
        NotificationCenter.default.post(notification)
        
        // Log emergency
        print("🚨 CRITICAL: \(component.rawValue) temperature: \(temperature)°C")
    }
    
    private func handleEmergencyPressure() {
        // Force maximum cooling
        fanController.setMaximumFanSpeed()
        
        // Send notification
        let notification = Notification(
            name: .thermalError,
            object: ThermalError.emergencyPressure
        )
        NotificationCenter.default.post(notification)
        
        // Log emergency
        print("🚨 EMERGENCY: Thermal pressure level is SLEEPING")
    }
    
    private func logCurrentState() {
        print("🌡️ Thermal monitoring started")
        print("   Pressure Level: \(currentPressureLevel.displayName)")
        print("   Components: \(componentTemperatures.count)")
        print("   Fans: \(fanSpeeds.count)")
    }
}

// MARK: - Thermal Errors
enum ThermalError: LocalizedError {
    case criticalTemperature(component: ComponentType, temperature: Double)
    case emergencyPressure
    case sensorUnavailable(sensor: String)
    case fanControlUnavailable
    
    var errorDescription: String? {
        switch self {
        case .criticalTemperature(let component, let temperature):
            return "Critical temperature detected for \(component.rawValue): \(temperature)°C"
        case .emergencyPressure:
            return "Emergency thermal pressure level detected"
        case .sensorUnavailable(let sensor):
            return "Sensor unavailable: \(sensor)"
        case .fanControlUnavailable:
            return "Fan control unavailable - insufficient privileges"
        }
    }
}

// ============================================================
// File: PressureLevelDetector.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Thermal pressure level detection using Darwin notifications
// ============================================================

import Foundation
import Combine

@MainActor
class PressureLevelDetector: ObservableObject {
    // MARK: - Published Properties
    @Published var currentPressureLevel: ThermalPressureLevel = .nominal
    @Published var error: Error?
    
    // MARK: - Private Properties
    private var isMonitoring = false
    private var timer: Timer?
    
    // MARK: - Public Methods
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        
        // Use ProcessInfo.thermalState as fallback
        updateCurrentPressureLevel()
        
        // Poll thermal state every 2 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentPressureLevel()
            }
        }
        
        print("🔥 Thermal pressure monitoring started (using ProcessInfo.thermalState)")
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        
        print("🔥 Thermal pressure monitoring stopped")
    }
    
    func getCurrentPressureLevel() -> ThermalPressureLevel {
        updateCurrentPressureLevel()
        return currentPressureLevel
    }
    
    // MARK: - Private Methods
    private func updateCurrentPressureLevel() {
        let thermalState = ProcessInfo.processInfo.thermalState
        
        let newLevel: ThermalPressureLevel
        switch thermalState {
        case .nominal:
            newLevel = .nominal
        case .fair:
            newLevel = .moderate
        case .serious:
            newLevel = .heavy
        case .critical:
            newLevel = .trapping
        @unknown default:
            newLevel = .nominal
        }
        
        if newLevel != currentPressureLevel {
            currentPressureLevel = newLevel
            
            // Log pressure level changes
            print("🔥 Thermal pressure changed to: \(currentPressureLevel.displayName)")
            
            // Post notification for other components
            NotificationCenter.default.post(
                name: .thermalPressureChanged,
                object: currentPressureLevel
            )
        }
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let thermalPressureChanged = Notification.Name("thermalPressureChanged")
}

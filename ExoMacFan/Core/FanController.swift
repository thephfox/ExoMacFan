// ============================================================
// File: FanController.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-20
// Description: Safe fan control with safety limits and profiles
// ============================================================

import Foundation
import Combine
import IOKit
import AppKit

@MainActor
class FanController: ObservableObject {
    // MARK: - Published Properties
    @Published var fanSpeeds: [FanInfo] = []
    @Published var currentProfile: FanProfile = .default
    @Published var isControllingFans: Bool = false
    @Published var error: Error?
    
    // MARK: - Private Properties
    private let ioKitInterface = IOKitInterface.shared
    private var updateTimer: Timer?
    private var updateInterval: TimeInterval = 2.0
    private var isMonitoring = false
    private var cancellables = Set<AnyCancellable>()
    
    // Safety tracking
    private var lastFanSpeeds: [Int: Double] = [:]
    private var lastSpeedChange: Date = Date()
    private let maxSpeedChangePerSecond: Double = 500.0
    private var isApplyingProfile = false
    private var latestPressureLevel: ThermalPressureLevel = .nominal
    private var latestComponentTemperatures: [ComponentType: Double] = [:]
    private var lastProactiveRampUpAt: [Int: Date] = [:]
    private let proactiveDownRampHoldSeconds: TimeInterval = 10.0
    private let proactiveMaxStepDownRPM: Double = 180.0
    
    // MARK: - Initialization
    init() {
        observeSleepWake()
    }

    /// Re-establish Ftst fan control after system wake (Apple Silicon resets Ftst on sleep).
    private func observeSleepWake() {
        NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isControllingFans else { return }
                Task { @MainActor in
                    // Re-unlock and re-apply after wake (Ftst resets on sleep)
                    let (ok, _) = await SMCHelper.shared.sendCommand("unlock")
                    if ok {
                        await self.applyFanProfile()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    /// Called once on app launch. Cleans up stale Ftst from a previous crash
    /// and ensures fans start under macOS system control.
    func ensureSystemControlOnStartup() {
        ioKitInterface.ensureSystemControl()
        // Keep profile state aligned with actual system-controlled startup state.
        currentProfile = .macosDefault
        isControllingFans = false
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        
        // Start update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
            Task { @MainActor in
                await self.updateFanSpeeds()
            }
        }
        
        // Initial update
        Task { @MainActor in
            await updateFanSpeeds()
        }
        
        print("🌀 Fan monitoring started")
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        
        updateTimer?.invalidate()
        updateTimer = nil
        
        // Return control to system if we were controlling fans
        if isControllingFans {
            returnToSystemControl()
        }
        
        print("🌀 Fan monitoring stopped")
    }

    func setPollingInterval(_ interval: TimeInterval) {
        updateInterval = interval
        if isMonitoring {
            updateTimer?.invalidate()
            updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
                Task { @MainActor in
                    await self.updateFanSpeeds()
                }
            }
        }
    }
    
    func setFanProfile(_ profile: FanProfile) {
        if profile.mode != .normal {
            lastProactiveRampUpAt.removeAll()
        }

        currentProfile = profile
        
        // Apply new profile if currently controlling
        if isControllingFans {
            Task {
                await applyFanProfile()
            }
        }
        
        print("🌀 Fan profile changed to: \(profile.name)")
    }

    /// Receive live thermal context from ThermalMonitor so Pro-Active mode can
    /// ramp fans before macOS reaches throttling pressure states.
    func updateThermalContext(
        pressureLevel: ThermalPressureLevel,
        componentTemperatures: [ComponentType: Double]
    ) {
        latestPressureLevel = pressureLevel
        latestComponentTemperatures = componentTemperatures
    }
    
    func getCurrentProfile() -> FanProfile? {
        return currentProfile
    }
    
    func startFanControl() async {
        guard !isControllingFans else {
            // Already controlling — just re-apply the current profile
            await applyFanProfile()
            return
        }

        // Unlock via privileged helper (prompts for admin password once per session)
        print("🌀 Unlocking fan control via helper...")
        let (ok, output) = await SMCHelper.shared.sendCommand("unlock")
        if !ok {
            print("🌀 ❌ Unlock FAILED: \(output)")
            self.error = ThermalError.fanControlUnavailable
            return
        }
        print("🌀 ✅ Unlock succeeded: \(output)")

        isControllingFans = true
        
        // Apply current profile via helper
        await applyFanProfile()
        
        print("🌀 Fan control started with profile: \(currentProfile.name)")
    }
    
    func stopFanControl() {
        guard isControllingFans else { return }
        
        returnToSystemControl()
        
        print("🌀 Fan control stopped")
    }
    
    func returnToSystemControl() {
        isControllingFans = false
        currentProfile = .macosDefault
        
        // Release via helper (non-blocking fire-and-forget)
        Task {
            let (ok, output) = await SMCHelper.shared.sendCommand("release")
            if ok {
                print("🌀 ✅ Fan control released: \(output)")
            } else {
                print("🌀 ⚠️ releaseFanControl failed: \(output)")
            }
        }
        
        print("🌀 Returned fan control to system")
    }
    
    func setMaximumFanSpeed() {
        Task {
            let (ok, output) = await SMCHelper.shared.sendCommand("maxfans")
            if ok {
                // Emergency max command is now the active profile source-of-truth.
                currentProfile = .maxFans
                isControllingFans = true
                print("🌀 ✅ Max fans set: \(output)")
            } else {
                print("🌀 ❌ Max fans failed: \(output)")
                self.error = ThermalError.fanControlUnavailable
            }
        }
        print("🌀 Set maximum fan speed for emergency cooling")
    }
    
    // MARK: - Private Methods
    private func updateFanSpeeds() async {
        var newFanSpeeds: [FanInfo] = []
        
        let fanCount = (try? await ioKitInterface.getFanCount()) ?? 0
        
        for fanIndex in 0..<fanCount {
            if let currentSpeed = try? await ioKitInterface.getCurrentFanSpeed(fanIndex: fanIndex),
               let maxSpeed = try? await ioKitInterface.getMaxFanSpeed(fanIndex: fanIndex) {
                let minSpeed = (try? await ioKitInterface.getMinFanSpeed(fanIndex: fanIndex)) ?? 1200.0

                var fanInfo = FanInfo(
                    fanIndex: fanIndex,
                    currentSpeed: currentSpeed,
                    maxSpeed: maxSpeed,
                    minSpeed: minSpeed,
                    targetSpeed: 0,
                    isControlled: isControllingFans,
                    lastUpdated: Date()
                )

                // Calculate target RPM for display.
                if isControllingFans {
                    let targetRPM = calculateTargetRPM(for: fanInfo)
                    fanInfo = FanInfo(
                        fanIndex: fanIndex,
                        currentSpeed: currentSpeed,
                        maxSpeed: maxSpeed,
                        minSpeed: minSpeed,
                        targetSpeed: targetRPM,
                        isControlled: true,
                        lastUpdated: Date()
                    )
                }

                newFanSpeeds.append(fanInfo)
            }
        }

        fanSpeeds = newFanSpeeds

        // Keep dynamic profiles (especially Pro-Active) continuously adjusted.
        if isControllingFans {
            await applyFanProfile()
        }
    }
    
    private func applyFanProfile() async {
        guard isControllingFans else {
            print("🌀 ⚠️ applyFanProfile skipped — isControllingFans=false")
            return
        }

        guard !isApplyingProfile else { return }
        isApplyingProfile = true
        defer { isApplyingProfile = false }

        // If fanSpeeds is empty (monitoring hasn't populated it yet), read from hardware now
        if fanSpeeds.isEmpty {
            print("🌀 fanSpeeds empty — fetching fan info from hardware")
            await updateFanSpeeds()
        }

        if fanSpeeds.isEmpty {
            print("🌀 ❌ fanSpeeds STILL empty after hardware fetch — no fans found")
            self.error = ThermalError.fanControlUnavailable
            return
        }

        print("🌀 Applying profile '\(currentProfile.name)' (mode=\(currentProfile.mode.rawValue)) to \(fanSpeeds.count) fan(s)")

        // Apply fan speeds via privileged helper
        for fan in fanSpeeds {
            let calculatedTargetRPM = calculateTargetRPM(for: fan)
            let lastApplied = lastFanSpeeds[fan.fanIndex] ?? fan.currentSpeed
            var targetRPM = calculatedTargetRPM

            // Pro-Active tune: keep higher fan speed a bit longer and reduce in smaller steps
            // to avoid frequent oscillation around thermal boundaries.
            if currentProfile.mode == .normal {
                if targetRPM > lastApplied + 50 {
                    lastProactiveRampUpAt[fan.fanIndex] = Date()
                } else if targetRPM < lastApplied {
                    let rampReference = lastProactiveRampUpAt[fan.fanIndex] ?? .distantPast
                    let elapsed = Date().timeIntervalSince(rampReference)

                    if elapsed < proactiveDownRampHoldSeconds {
                        targetRPM = lastApplied
                    } else {
                        targetRPM = max(targetRPM, lastApplied - proactiveMaxStepDownRPM)
                    }
                }
            }

            // Avoid noisy helper traffic when target change is tiny.
            if abs(targetRPM - lastApplied) < 75 {
                continue
            }

            print("🌀 Fan \(fan.fanIndex): target \(Int(targetRPM)) RPM")
            let (ok, output) = await SMCHelper.shared.sendCommand("setfan \(fan.fanIndex) \(Int(targetRPM))")
            if ok {
                lastFanSpeeds[fan.fanIndex] = targetRPM
            } else {
                print("🌀 ❌ Fan \(fan.fanIndex) failed: \(output)")
                self.error = ThermalError.fanControlUnavailable
            }
        }
    }

    /// Convert profile percentage to actual RPM using the fan's hardware max speed.
    /// Uses current thermal pressure to pick the right curve point.
    private func calculateTargetRPM(for fan: FanInfo) -> Double {
        let profile = currentProfile

        // For macOS default — shouldn't reach here, but safety
        if profile.mode == .macosDefault { return fan.currentSpeed }

        // Custom mode uses the custom speed percentage directly
        if profile.mode == .custom, let pct = profile.customSpeed {
            return fan.minSpeed + (pct / 100.0) * (fan.maxSpeed - fan.minSpeed)
        }

        // Max fans — full blast at hardware max
        if profile.mode == .maxFans {
            return fan.maxSpeed
        }

        // Pro-Active mode combines pressure + thermal headroom to prevent throttling.
        if profile.mode == .normal {
            let pressurePct = profile.pressureCurve[latestPressureLevel] ?? 40.0
            let headroomPct = proactiveHeadroomFanPercentage()
            let pct = max(pressurePct, headroomPct)
            return fan.minSpeed + (pct / 100.0) * (fan.maxSpeed - fan.minSpeed)
        }

        // Other dynamic profiles use pressure curve directly.
        let pct = profile.pressureCurve[latestPressureLevel] ?? 40.0

        // Convert percentage to RPM in the fan's min..max range
        return fan.minSpeed + (pct / 100.0) * (fan.maxSpeed - fan.minSpeed)
    }

    /// Convert live temperatures into a proactive fan target.
    /// Ratio represents "how close to thermal limit" for each component.
    private func proactiveHeadroomFanPercentage() -> Double {
        guard !latestComponentTemperatures.isEmpty else { return 40.0 }

        var maxRatio: Double = 0
        for (component, temp) in latestComponentTemperatures {
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
            maxRatio = max(maxRatio, temp / limit)
        }

        switch maxRatio {
        case ..<0.65: return 25.0
        case ..<0.75: return 40.0
        case ..<0.85: return 55.0
        case ..<0.92: return 75.0
        case ..<0.98: return 90.0
        default:      return 100.0
        }
    }

    private func hasAdminPrivileges() async -> Bool {
        // Check if running with admin privileges
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        task.arguments = ["-u"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            
            return output == "0" // Root user
        } catch {
            return false
        }
    }
    
    // MARK: - Safety Methods
    private func checkSafetyLimits() -> Bool {
        // Check if any fan speeds exceed safety limits
        for fan in fanSpeeds {
            if fan.currentSpeed > currentProfile.safetyLimits.maxFanSpeed {
                print("🚨 SAFETY: Fan \(fan.fanIndex) speed exceeds limit: \(fan.currentSpeed) RPM")
                return false
            }
        }
        
        return true
    }
    
    private func emergencyShutdown() {
        print("🚨 EMERGENCY: Shutting down fan control")
        
        // Return control to system
        returnToSystemControl()
        
        // Send notification
        let notification = Notification(
            name: .thermalError,
            object: ThermalError.emergencyPressure
        )
        NotificationCenter.default.post(notification)
    }
}

// Fan profiles are now defined in Models.swift

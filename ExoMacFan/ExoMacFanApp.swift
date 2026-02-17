// ============================================================
// File: ExoMacFanApp.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Main application entry point for ExoMacFan thermal management
// ============================================================

import SwiftUI
import AppKit

@main
struct ExoMacFanApp: App {
    @StateObject private var thermalMonitor = ThermalMonitor()
    @StateObject private var sensorDiscovery = SensorDiscovery()

    init() {
        // Enforce single instance — multiple copies fighting over Ftst would be dangerous
        ExoMacFanApp.terminateIfAlreadyRunning()

        // Install signal & atexit handlers FIRST, before any fan control happens.
        // If the process is killed or crashes, these ensure Ftst is cleared so
        // macOS thermalmonitord resumes system fan control immediately.
        installSafetyHandlers()
    }

    /// Terminate immediately if another instance of ExoMacFan is already running.
    /// Two instances competing for SMC Ftst lock would cause unpredictable fan behavior.
    private static func terminateIfAlreadyRunning() {
        let dominated = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if dominated.count > 1 {
            // Another instance is already running — bring it to front and exit
            if let existing = dominated.first(where: { $0 != NSRunningApplication.current }) {
                existing.activate()
            }
            print("⚠️ ExoMacFan is already running. Exiting duplicate instance.")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(thermalMonitor)
                .environmentObject(sensorDiscovery)
                .frame(minWidth: 720, idealWidth: 960, minHeight: 520, idealHeight: 680)
                .onAppear {
                    setupApplication()
                }
        }
        .windowResizability(.contentMinSize)
        
        MenuBarExtra {
            MenuBarView()
                .environmentObject(thermalMonitor)
                .environmentObject(sensorDiscovery)
        } label: {
            Image(systemName: thermalMonitor.currentPressureLevel.icon)
        }
        .menuBarExtraStyle(.window)
    }
    
    private func setupApplication() {
        // Clean up stale Ftst from a previous crash before doing anything else.
        // This ensures the app always starts with macOS in full control of fans.
        thermalMonitor.ensureSystemControlOnStartup()
        
        // Initialize monitoring (read-only; fan control is NOT active yet)
        thermalMonitor.startMonitoring()
        sensorDiscovery.discoverSensors()
        
        // Setup global error handling
        setupErrorHandling()

        // Connect to the privileged helper daemon at startup.
        // First launch: installs LaunchDaemon + prompts admin password once.
        // Subsequent launches (including after reboot): connects instantly, no prompt.
        Task {
            let ok = await SMCHelper.shared.ensureDaemon()
            if ok {
                print("🔐 Helper daemon ready at startup")
            } else {
                print("🔐 ⚠️ Helper daemon not available — fan control will prompt when needed")
            }
        }
    }

    /// Install process-level safety nets so fan control is ALWAYS released,
    /// even if the app is force-quit, killed, or crashes.
    private func installSafetyHandlers() {
        // atexit: runs on normal exit and some abnormal exits
        atexit { IOKitInterface.emergencyCleanup() }

        // SIGTERM (kill), SIGINT (Ctrl-C), SIGHUP (terminal closed)
        for sig: Int32 in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in
                IOKitInterface.emergencyCleanup()
                exit(0)
            }
        }

        // Also handle normal app termination via NSApplication
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            IOKitInterface.emergencyCleanup()
            SMCHelper.shared.cleanup()
        }
    }
    
    
    private func setupErrorHandling() {
        // Global error handling for thermal monitoring
        NotificationCenter.default.addObserver(
            forName: .thermalError,
            object: nil,
            queue: .main
        ) { notification in
            if let error = notification.object as? Error {
                handleThermalError(error)
            }
        }
    }
    
    private func handleThermalError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Thermal Monitoring Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let thermalError = Notification.Name("thermalError")
    static let thermalStateChanged = Notification.Name("thermalStateChanged")
    static let sensorDiscovered = Notification.Name("sensorDiscovered")
}

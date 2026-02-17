// ============================================================
// File: FansView.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-17
// Description: Fan control interface with 4 standard modes and custom slider
// ============================================================

import SwiftUI

struct FansView: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @State private var selectedMode: FanControlMode = .macosDefault
    @State private var customSpeed: Double = 50.0
    @State private var isApplying = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Source-of-truth status shown separately from selection UI.
                ActiveModeBadge()

                // Show fan control errors prominently
                if let error = thermalMonitor.fanControlError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") { thermalMonitor.fanControlError = nil }
                            .font(.caption2)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }

                FanModeSelector(
                    selectedMode: $selectedMode,
                    customSpeed: $customSpeed,
                    isApplying: $isApplying
                )

                if selectedMode == .custom {
                    CustomSpeedSlider(speed: $customSpeed, isApplying: $isApplying)
                }

                if !thermalMonitor.fanSpeeds.isEmpty {
                    CurrentFanStatusCard()
                } else {
                    NoFansCard()
                }

                ModeInformationCard(mode: selectedMode)
                SafetyInfoCard()
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Sync UI with actual fan mode state
            selectedMode = thermalMonitor.currentFanMode
        }
        .onChange(of: thermalMonitor.currentFanMode) { _, mode in
            // Keep UI in sync when mode changes outside this view (menu bar, safety fallback)
            selectedMode = mode
        }
        .onChange(of: selectedMode) { _, newMode in
            // Ignore sync updates; only apply when user selected a different mode
            guard newMode != thermalMonitor.currentFanMode else { return }
            applyMode(newMode)
        }
        .onChange(of: customSpeed) { _, newSpeed in
            if selectedMode == .custom && !isApplying { applyCustomSpeed(newSpeed) }
        }
    }

    private func applyMode(_ mode: FanControlMode) {
        isApplying = true
        Task {
            switch mode {
            case .macosDefault:
                thermalMonitor.returnToSystemControl()
            case .silent:
                thermalMonitor.setFanProfile(.silent)
                await thermalMonitor.startFanControl()
            case .normal:
                thermalMonitor.setFanProfile(.default)
                await thermalMonitor.startFanControl()
            case .maxFans:
                thermalMonitor.setFanProfile(.maxFans)
                await thermalMonitor.startFanControl()
            case .custom:
                thermalMonitor.setFanProfile(.custom(speed: customSpeed))
                await thermalMonitor.startFanControl()
            }
            await MainActor.run { isApplying = false }
        }
    }

    private func applyCustomSpeed(_ speed: Double) {
        thermalMonitor.setFanProfile(.custom(speed: speed))
    }
}

// MARK: - Active Mode Badge
struct ActiveModeBadge: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    private var modeText: String {
        thermalMonitor.currentFanMode.rawValue
    }

    private var statusText: String {
        thermalMonitor.isControllingFans ? "Manual control active" : "macOS system control"
    }

    private var statusColor: Color {
        thermalMonitor.isControllingFans ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: thermalMonitor.currentFanMode.icon)
                .foregroundStyle(thermalMonitor.currentFanMode.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Current active mode: \(modeText)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - No Fans Card
struct NoFansCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "fan.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No Fans Detected")
                .font(.headline)
            Text("This Mac appears to be fanless. Fan control is not available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Safety Info Card
struct SafetyInfoCard: View {
    var body: some View {
        CardView(title: "Safety", icon: "shield.checkered") {
            VStack(alignment: .leading, spacing: 8) {
                SafetyRow(icon: "thermometer.high", title: "Temperature Limits",
                          description: "Fans return to system control if temps exceed safe limits")
                SafetyRow(icon: "speedometer", title: "Gradual Changes",
                          description: "Fan speeds change gradually to prevent hardware stress")
                SafetyRow(icon: "arrow.clockwise", title: "Auto Fallback",
                          description: "Control returns to macOS if issues are detected")
                SafetyRow(icon: "exclamationmark.triangle", title: "Emergency Protection",
                          description: "Maximum cooling during critical thermal events")
            }
        }
    }
}

// MARK: - Safety Row
struct SafetyRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.green)
                .frame(width: 16)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    FansView()
        .environmentObject(ThermalMonitor())
}

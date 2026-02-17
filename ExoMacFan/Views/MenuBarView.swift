// ============================================================
// File: MenuBarView.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Description: Menu bar integration for quick access
// ============================================================

import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @EnvironmentObject var sensorDiscovery: SensorDiscovery

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — shows current fan mode + thermal health
            HStack(spacing: 10) {
                Image(systemName: thermalMonitor.currentPressureLevel.icon)
                    .font(.title3)
                    .foregroundStyle(thermalMonitor.currentPressureLevel.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ExoMacFan")
                        .font(.subheadline.weight(.semibold))
                    Text(thermalStatusLabel)
                        .font(.caption)
                        .foregroundStyle(thermalMonitor.currentPressureLevel.color)
                }
                Spacer()
                Circle()
                    .fill(thermalMonitor.isMonitoring ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            MenuDivider()

            // Quick Status
            VStack(alignment: .leading, spacing: 4) {
                if !thermalMonitor.componentTemperatures.isEmpty {
                    StatusRow(label: "Temperatures", value: temperatureSummary)
                }
                if !thermalMonitor.fanSpeeds.isEmpty {
                    StatusRow(label: "Fans", value: fanSummary)
                }
                StatusRow(label: "Fan Mode", value: thermalMonitor.currentFanMode.rawValue)
                if thermalMonitor.isThrottling {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("Throttling Active")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            MenuDivider()

            // Quick Fan Controls
            VStack(spacing: 1) {
                MenuRow(
                    icon: "cpu",
                    label: "System Default",
                    trailing: thermalMonitor.currentFanMode == .macosDefault ? "checkmark" : nil
                ) {
                    thermalMonitor.returnToSystemControl()
                }
                MenuRow(
                    icon: "speedometer",
                    label: "Max Fans",
                    trailing: thermalMonitor.currentFanMode == .maxFans ? "checkmark" : nil
                ) {
                    thermalMonitor.setFanProfile(.maxFans)
                    Task { await thermalMonitor.startFanControl() }
                }
            }
            .padding(.vertical, 4)

            MenuDivider()

            // Actions
            VStack(spacing: 1) {
                MenuRow(icon: "macwindow", label: "Open Dashboard") {
                    openMainWindow()
                }
                MenuRow(icon: "xmark.circle", label: "Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 4)
        }
        .frame(width: 260)
    }

    // MARK: - Helpers

    private var thermalStatusLabel: String {
        switch thermalMonitor.currentPressureLevel {
        case .nominal:  return "Running Cool"
        case .moderate: return "Slightly Warm"
        case .heavy:    return "Getting Hot"
        case .trapping: return "Critical Heat"
        case .sleeping: return "Emergency!"
        }
    }

    private var temperatureSummary: String {
        let temps = thermalMonitor.componentTemperatures.values
        guard !temps.isEmpty else { return "—" }
        let mx = temps.max() ?? 0
        let avg = temps.reduce(0, +) / Double(temps.count)
        return "\(mx.safeInt)°C max · \(avg.safeInt)°C avg"
    }

    private var fanSummary: String {
        guard !thermalMonitor.fanSpeeds.isEmpty else { return "—" }
        let rpms = thermalMonitor.fanSpeeds.map { "\($0.currentSpeed.safeInt)" }
        return rpms.joined(separator: " / ") + " RPM"
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

// MARK: - Subviews

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 8)
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
        }
    }
}

private struct MenuRow: View {
    let icon: String
    let label: String
    var trailing: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .frame(width: 16, alignment: .center)
                Text(label)
                    .font(.subheadline)
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.primary.opacity(0.1) : Color.clear)
                    .padding(.horizontal, 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(ThermalMonitor())
        .environmentObject(SensorDiscovery())
}

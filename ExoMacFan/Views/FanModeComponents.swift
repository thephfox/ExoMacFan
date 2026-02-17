// ============================================================
// File: FanModeComponents.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-17
// Description: UI components for fan mode selection and control
// ============================================================

import SwiftUI

// MARK: - Fan Mode Selector
struct FanModeSelector: View {
    @Binding var selectedMode: FanControlMode
    @Binding var customSpeed: Double
    @Binding var isApplying: Bool
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "Fan Control Mode", icon: "fan") {
            if isApplying {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            }
            let cols = [GridItem(.adaptive(minimum: 140), spacing: 10)]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(FanControlMode.allCases, id: \.self) { mode in
                    FanModeCard(mode: mode, isSelected: selectedMode == mode, customSpeed: customSpeed) {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedMode = mode }
                    }
                }
            }
        }
    }
}

// MARK: - Fan Mode Card
struct FanModeCard: View {
    let mode: FanControlMode
    let isSelected: Bool
    let customSpeed: Double
    let action: () -> Void

    private var shortDescription: String {
        switch mode {
        case .macosDefault: return "Apple controls fans"
        case .silent:       return "Off until throttling"
        case .normal:       return "Avoid throttling early"
        case .maxFans:      return "100% always"
        case .custom:       return "\(customSpeed.safeInt)% manual"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? mode.color : .secondary)
                    .frame(height: 24)
                Text(mode.rawValue)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .bold : .medium)
                    .foregroundStyle(isSelected ? mode.color : .primary)
                Text(shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(isSelected ? mode.color.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? mode.color : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom Speed Slider
struct CustomSpeedSlider: View {
    @Binding var speed: Double
    @Binding var isApplying: Bool

    var body: some View {
        CardView(title: "Custom Speed", icon: "slider.horizontal.3") {
            HStack {
                Slider(value: $speed, in: 0...100, step: 5).tint(.purple)
                Text("\(speed.safeInt)%")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.purple)
                    .frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text("Presets:").font(.caption2).foregroundStyle(.secondary)
                ForEach([25, 50, 75, 100], id: \.self) { p in
                    Button {
                        withAnimation { speed = Double(p) }
                    } label: {
                        Text("\(p)%")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(speed == Double(p) ? Color.purple.opacity(0.2) : .clear, in: Capsule())
                            .foregroundStyle(speed == Double(p) ? .purple : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if speed < 20 {
                Label("Low speed may cause higher temperatures", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            } else if speed > 80 {
                Label("High speed is noisy but gives maximum cooling", systemImage: "speaker.wave.3.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Current Fan Status Card
struct CurrentFanStatusCard: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "Current Status", icon: "fan") {
            ForEach(thermalMonitor.fanSpeeds) { fan in
                HStack(spacing: 8) {
                    Image(systemName: "fan")
                        .foregroundStyle(fanSpeedColor(fan.speedPercentage))
                        .font(.body)
                    Text("Fan \(fan.fanIndex + 1)")
                        .font(.caption)
                        .frame(width: 44, alignment: .leading)

                    ProgressView(value: min(fan.speedPercentage / 100, 1))
                        .tint(fanSpeedColor(fan.speedPercentage))
                        .frame(maxWidth: .infinity)

                    Text("\(fan.currentSpeed.safeInt) RPM")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)

                    Text("\(fan.speedPercentage.safeInt)%")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundStyle(fanSpeedColor(fan.speedPercentage))
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

}

// MARK: - Mode Information Card
struct ModeInformationCard: View {
    let mode: FanControlMode
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "\(mode.rawValue) Mode", icon: mode.icon) {
            Text(mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                switch mode {
                case .macosDefault:
                    InfoRow(icon: "cpu", title: "System Controlled", description: "macOS manages fan speeds automatically")
                    InfoRow(icon: "checkmark.shield", title: "Safe & Reliable", description: "Apple's default thermal management")
                case .silent:
                    InfoRow(icon: "speaker.slash", title: "Minimal Noise", description: "Fans stay off until throttling detected")
                    InfoRow(icon: "thermometer", title: "Higher Temps", description: "May reach 95-100\u{00B0}C under load")
                case .normal:
                    InfoRow(icon: "waveform.path.ecg", title: "Pro-Active Ramping", description: "Increases fan speed as temps approach limits")
                    InfoRow(icon: "thermometer.medium", title: "Headroom Recovery", description: "Reduces fan speed when temps move away from limits")
                case .maxFans:
                    InfoRow(icon: "speedometer", title: "Maximum Cooling", description: "100% fan speed at all times")
                    InfoRow(icon: "speaker.wave.3", title: "Very Loud", description: "For heavy workloads only")
                case .custom:
                    InfoRow(icon: "slider.horizontal.3", title: "Manual Control", description: "You set exact fan speed")
                    InfoRow(icon: "hand.raised", title: "Your Responsibility", description: "Monitor temps to avoid issues")
                }
            }

            if mode != .macosDefault {
                Divider()
                HStack(spacing: 6) {
                    Circle().fill(thermalMonitor.currentPressureLevel.color).frame(width: 7, height: 7)
                    Text("Thermal: \(thermalMonitor.currentPressureLevel.displayName)")
                        .font(.caption)
                        .foregroundStyle(thermalMonitor.currentPressureLevel.color)
                    Spacer()
                    if thermalMonitor.isThrottling {
                        Label("Throttling", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

// MARK: - Info Row
struct InfoRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 16).font(.caption)
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

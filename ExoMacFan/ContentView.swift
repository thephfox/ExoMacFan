// ============================================================
// File: ContentView.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-09
// Description: Main SwiftUI interface for ExoMacFan
// ============================================================

import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @EnvironmentObject var sensorDiscovery: SensorDiscovery
    @State private var selectedTab: TabSelection = .dashboard

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selectedTab {
                case .dashboard: DashboardView()
                case .sensors:   SensorsView()
                case .fans:      FansView()
                case .history:   HistoryView()
                case .settings:  SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if !thermalMonitor.isMonitoring {
                thermalMonitor.startMonitoring()
            }
        }
    }
}

// MARK: - Tab Selection
enum TabSelection: String, CaseIterable {
    case dashboard, sensors, fans, history, settings

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .sensors:   return "Sensors"
        case .fans:      return "Fans"
        case .history:   return "History"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "speedometer"
        case .sensors:   return "thermometer"
        case .fans:      return "fan"
        case .history:   return "clock"
        case .settings:  return "gear"
        }
    }
}

// MARK: - Sidebar
struct SidebarView: View {
    @Binding var selectedTab: TabSelection
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        List(TabSelection.allCases, id: \.self, selection: $selectedTab) { tab in
            Label(tab.title, systemImage: tab.icon)
                .badge(tab == .dashboard ? badgeText : nil)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Circle()
                        .fill(thermalMonitor.isMonitoring ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(thermalMonitor.isMonitoring ? "Monitoring" : "Stopped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 4) {
                    Image(systemName: thermalMonitor.currentFanMode.icon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(thermalMonitor.currentFanMode.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)
            Text("Code PhFox — www.phfox.com")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
        }
    }

    private var badgeText: Text? {
        thermalMonitor.isThrottling ? Text("!") : nil
    }
}

// MARK: - Dashboard
struct DashboardView: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @EnvironmentObject var sensorDiscovery: SensorDiscovery
    @State private var selectedTimePeriod: TimePeriod = .last5Min

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status row
                HStack(spacing: 12) {
                    ThermalStatusCard()
                    ThrottlingStatusCard()
                }

                // Temperatures
                if !thermalMonitor.componentTemperatures.isEmpty {
                    TemperatureOverviewCard()
                }

                // Fans
                if !thermalMonitor.fanSpeeds.isEmpty {
                    FanStatusCard()
                }

                // Chart
                ThermalHistoryChart(selectedTimePeriod: $selectedTimePeriod)

                // Hardware
                if let hw = sensorDiscovery.hardwareInfo {
                    HardwareInfoCard(hardwareInfo: hw)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cards

struct CardView<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ThermalStatusCard: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "Thermal Pressure", icon: "flame") {
            HStack(spacing: 6) {
                Image(systemName: thermalMonitor.currentPressureLevel.icon)
                    .foregroundStyle(thermalMonitor.currentPressureLevel.color)
                Text(thermalMonitor.currentPressureLevel.displayName)
                    .fontWeight(.semibold)
                    .foregroundStyle(thermalMonitor.currentPressureLevel.color)
            }
            .font(.body)

            Text(thermalMonitor.currentPressureLevel.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ThrottlingStatusCard: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "Throttling", icon: thermalMonitor.isThrottling ? "exclamationmark.triangle.fill" : "checkmark.circle") {
            HStack(spacing: 6) {
                Circle()
                    .fill(thermalMonitor.isThrottling ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(thermalMonitor.isThrottling ? "Active" : "None")
                    .font(.body)
                    .fontWeight(.medium)
            }

            if thermalMonitor.isThrottling {
                Text(thermalMonitor.throttlingComponents.map(\.rawValue).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("All components operating normally")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Temperature Overview
struct TemperatureOverviewCard: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    private var sorted: [(ComponentType, Double)] {
        thermalMonitor.componentTemperatures
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        CardView(title: "Temperatures", icon: "thermometer.medium") {
            let cols = [GridItem(.adaptive(minimum: 200), spacing: 10)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                ForEach(sorted, id: \.0) { component, temp in
                    TemperatureRow(component: component, temperature: temp)
                }
            }
        }
    }
}

struct TemperatureRow: View {
    let component: ComponentType
    let temperature: Double

    private var maxTemp: Double {
        switch component {
        case .cpuPerformance, .cpuEfficiency: return 105
        case .gpu: return 100
        case .ane: return 95
        default: return 100
        }
    }

    private var fraction: Double { min(max(temperature / maxTemp, 0), 1) }
    private var barColor: Color { fraction < 0.7 ? .green : fraction < 0.9 ? .orange : .red }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: component.icon)
                .foregroundStyle(component.color)
                .frame(width: 16, alignment: .center)
                .font(.caption)

            Text(component.rawValue)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            ProgressView(value: fraction)
                .tint(barColor)
                .frame(maxWidth: .infinity)

            Text(String(format: "%.1f\u{00B0}C", temperature))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Fan Status
struct FanStatusCard: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "Fans", icon: "fan") {
            ForEach(thermalMonitor.fanSpeeds) { fan in
                HStack(spacing: 8) {
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
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Fan Speed Color
/// Green at 0% → yellow at 50% → orange at 75% → red at 100%
func fanSpeedColor(_ percentage: Double) -> Color {
    let p = min(max(percentage / 100, 0), 1)
    if p < 0.5 {
        // green → yellow
        return Color(red: p * 2, green: 0.85, blue: 0)
    } else {
        // yellow → red
        let t = (p - 0.5) * 2
        return Color(red: 1.0, green: 0.85 * (1 - t), blue: 0)
    }
}

// MARK: - Fan Speed Indicator (kept for FanModeComponents compatibility)
struct FanSpeedIndicator: View {
    let percentage: Double
    var body: some View {
        Capsule().fill(fanSpeedColor(percentage)).frame(width: 4, height: 16)
    }
}

// MARK: - Hardware Info
struct HardwareInfoCard: View {
    let hardwareInfo: HardwareInfo

    var body: some View {
        CardView(title: "Hardware", icon: "cpu") {
            let cols = [GridItem(.adaptive(minimum: 140), spacing: 8)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                InfoCell("Generation", hardwareInfo.macGeneration.displayName)
                InfoCell("Chip", hardwareInfo.chipType)
                InfoCell("P-Cores", "\(hardwareInfo.performanceCores)")
                InfoCell("E-Cores", "\(hardwareInfo.efficiencyCores)")
                InfoCell("GPU Cores", "\(hardwareInfo.gpuCores)")
                InfoCell("Fans", hardwareInfo.hasFans ? "\(hardwareInfo.fanCount)" : "None")
                InfoCell("Model", hardwareInfo.modelIdentifier)
            }
        }
    }

    private func InfoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// kept for backward compatibility with other views
struct HardwareInfoRowView: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
        .environmentObject(ThermalMonitor())
        .environmentObject(SensorDiscovery())
}

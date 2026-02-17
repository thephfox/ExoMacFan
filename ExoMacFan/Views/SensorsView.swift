// ============================================================
// File: SensorsView.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-09
// Description: Comprehensive sensor dashboard view
// ============================================================

import SwiftUI
import Charts

struct SensorsView: View {
    @EnvironmentObject var sensorDiscovery: SensorDiscovery
    @State private var selectedComponent: ComponentType? = nil
    @State private var searchText = ""
    @State private var showingInactiveSensors = false

    var filteredSensors: [SensorInfo] {
        var sensors = sensorDiscovery.discoveredSensors
        if let component = selectedComponent {
            sensors = sensors.filter { $0.component == component }
        }
        if !searchText.isEmpty {
            sensors = sensors.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.key.localizedCaseInsensitiveContains(searchText)
            }
        }
        if !showingInactiveSensors {
            sensors = sensors.filter { $0.isActive }
        }
        return sensors.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if sensorDiscovery.isDiscovering {
                discoveryProgressView
            } else if filteredSensors.isEmpty {
                emptyStateView
            } else {
                sensorTableView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sensorDiscovery.refreshSensors()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(sensorDiscovery.isDiscovering)
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search sensors...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(label: "All", icon: "square.grid.2x2", isSelected: selectedComponent == nil) {
                        selectedComponent = nil
                    }
                    ForEach(ComponentType.allCases, id: \.self) { comp in
                        let n = sensorDiscovery.discoveredSensors.filter { $0.component == comp }.count
                        if n > 0 {
                            FilterChip(label: comp.rawValue, icon: comp.icon, count: n, isSelected: selectedComponent == comp) {
                                selectedComponent = comp
                            }
                        }
                    }
                }
            }

            HStack {
                Toggle("Show inactive", isOn: $showingInactiveSensors)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
                Spacer()
                Text("\(filteredSensors.count) sensors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Discovery Progress
    private var discoveryProgressView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView(value: sensorDiscovery.discoveryProgress)
                .frame(maxWidth: 240)
            Text("Discovering Sensors…")
                .font(.body)
            Text("\((sensorDiscovery.discoveryProgress * 100).safeInt)%")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "thermometer.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No sensors found")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table View
    private var sensorTableView: some View {
        List(filteredSensors) { sensor in
            SensorRow(sensor: sensor)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let label: String
    let icon: String
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption)
                if let c = count {
                    Text("\(c)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : .clear, in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sensor Row
struct SensorRow: View {
    let sensor: SensorInfo

    private var fraction: Double { sensor.percentageOfMax }
    private var barColor: Color { fraction < 0.6 ? .green : fraction < 0.8 ? .orange : .red }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sensor.component.icon)
                .foregroundStyle(sensor.component.color)
                .frame(width: 16)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.name)
                    .font(.body)
                    .lineLimit(1)
                Text(sensor.key)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 8)

            ProgressView(value: fraction)
                .tint(barColor)
                .frame(maxWidth: 120)

            Text(String(format: "%.1f %@", sensor.currentValue, sensor.unit))
                .font(.system(.body, design: .monospaced))
                .frame(width: 72, alignment: .trailing)

            Text("\((fraction * 100).safeInt)%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Circle()
                .fill(sensor.isActive ? Color.green : Color.red)
                .frame(width: 6, height: 6)
        }
        .padding(.vertical, 2)
    }
}

// kept for backward compatibility
struct ComponentFilterButton: View {
    let component: ComponentType?
    @Binding var selectedComponent: ComponentType?
    let title: String
    let icon: String
    let count: Int?
    init(component: ComponentType?, selectedComponent: Binding<ComponentType?>, title: String, icon: String, count: Int? = nil) {
        self.component = component; self._selectedComponent = selectedComponent; self.title = title; self.icon = icon; self.count = count
    }
    var body: some View {
        FilterChip(label: title, icon: icon, count: count, isSelected: component == selectedComponent) {
            selectedComponent = component
        }
    }
}

// MARK: - Sensor Detail View
struct SensorDetailView: View {
    let sensor: SensorInfo
    @Environment(\.dismiss) private var dismiss

    private var fraction: Double { sensor.percentageOfMax }
    private var barColor: Color { fraction < 0.6 ? .green : fraction < 0.8 ? .orange : .red }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(sensor.name).font(.title2).fontWeight(.semibold)
                    Text(sensor.key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }

                // Value card
                HStack {
                    Text(sensor.formattedValue)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\((fraction * 100).safeInt)%")
                            .font(.body).fontWeight(.medium)
                        ProgressView(value: fraction)
                            .tint(barColor)
                            .frame(width: 80)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                // Details
                VStack(spacing: 6) {
                    DetailRow(title: "Sensor Key", value: sensor.key)
                    DetailRow(title: "Component", value: sensor.component.rawValue)
                    DetailRow(title: "Unit", value: sensor.unit)
                    DetailRow(title: "Min Value", value: "\(sensor.minValue.safeInt)")
                    DetailRow(title: "Max Value", value: "\(sensor.maxValue.safeInt)")
                    DetailRow(title: "Status", value: sensor.isActive ? "Active" : "Inactive")
                    DetailRow(title: "Last Updated", value: sensor.lastUpdated.formatted())
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - Detail Row
struct DetailRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}

#Preview {
    SensorsView()
        .environmentObject(SensorDiscovery())
}

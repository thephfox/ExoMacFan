// ============================================================
// File: ThermalHistoryChart.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Real-time thermal visualization with charts
// ============================================================

import SwiftUI
import Charts

struct ThermalHistoryChart: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @Binding var selectedTimePeriod: TimePeriod
    @State private var chartType: ChartType = .temperature
    @State private var selectedComponents: Set<ComponentType> = []

    /// Raw history filtered by period.
    private var rawHistory: [ThermalState] {
        thermalMonitor.getThermalHistory(for: selectedTimePeriod)
    }

    /// Downsampled for chart performance (max ~150 points).
    private var thermalHistory: [ThermalState] {
        downsample(rawHistory, maxPoints: 150)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Thermal History")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Picker("Period", selection: $selectedTimePeriod) {
                    ForEach(TimePeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }

            // Chart type selector
            Picker("Chart Type", selection: $chartType) {
                ForEach(ChartType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // Component filters (only for temperature chart)
            if chartType == .temperature,
               !thermalHistory.isEmpty,
               let lastState = thermalHistory.last {
                ComponentFilterView(
                    availableComponents: Array(lastState.componentTemperatures.keys).sorted { $0.rawValue < $1.rawValue },
                    selectedComponents: $selectedComponents
                )
            }

            // Chart
            if thermalHistory.isEmpty {
                EmptyChartView()
            } else {
                switch chartType {
                case .temperature:
                    TemperatureChart(
                        history: thermalHistory,
                        selectedComponents: selectedComponents
                    )
                case .pressure:
                    PressureChart(history: thermalHistory)
                case .fan:
                    FanSpeedChart(history: thermalHistory)
                }
            }

            // Statistics
            if !thermalHistory.isEmpty {
                StatisticsView(history: thermalHistory)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            if selectedComponents.isEmpty, let lastState = rawHistory.last {
                selectedComponents = Set(lastState.componentTemperatures.keys)
            }
        }
    }

    /// Reduce data points to at most `maxPoints` by taking evenly-spaced samples.
    private func downsample(_ data: [ThermalState], maxPoints: Int) -> [ThermalState] {
        guard data.count > maxPoints else { return data }
        let step = Double(data.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in data[min(Int(Double(i) * step), data.count - 1)] }
    }
}

// MARK: - Chart Types
enum ChartType: String, CaseIterable {
    case temperature = "temperature"
    case pressure = "pressure"
    case fan = "fan"
    
    var displayName: String {
        switch self {
        case .temperature: return "Temperature"
        case .pressure: return "Pressure"
        case .fan: return "Fan Speed"
        }
    }
    
    var icon: String {
        switch self {
        case .temperature: return "thermometer"
        case .pressure: return "gauge"
        case .fan: return "fan"
        }
    }
}

// MARK: - Component Filter View
struct ComponentFilterView: View {
    let availableComponents: [ComponentType]
    @Binding var selectedComponents: Set<ComponentType>
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableComponents, id: \.self) { component in
                    ComponentChip(
                        component: component,
                        isSelected: selectedComponents.contains(component)
                    ) {
                        if selectedComponents.contains(component) {
                            selectedComponents.remove(component)
                        } else {
                            selectedComponents.insert(component)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Component Chip
struct ComponentChip: View {
    let component: ComponentType
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: component.icon)
                    .font(.caption)
                
                Text(component.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? component.color : Color(.controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Temperature Chart
struct TemperatureChart: View {
    let history: [ThermalState]
    let selectedComponents: Set<ComponentType>

    var body: some View {
        Chart {
            ForEach(Array(selectedComponents), id: \.self) { component in
                ForEach(history, id: \.id) { state in
                    if let temperature = state.componentTemperatures[component],
                       temperature > 0 {
                        LineMark(
                            x: .value("Time", state.timestamp),
                            y: .value("Temperature", temperature),
                            series: .value("Component", component.rawValue)
                        )
                        .foregroundStyle(by: .value("Component", component.rawValue))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: timeFormat)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel("\(value.as(Int.self) ?? 0)°C")
            }
        }
        .chartLegend(position: .bottom, spacing: 4)
        .frame(height: 200)
    }

    private var xDomain: ClosedRange<Date> {
        chartTimeDomain(history)
    }

    private var timeFormat: Date.FormatStyle {
        chartTimeFormat(history)
    }
}

// MARK: - Pressure Chart
struct PressureChart: View {
    let history: [ThermalState]

    var body: some View {
        Chart {
            ForEach(history, id: \.id) { state in
                AreaMark(
                    x: .value("Time", state.timestamp),
                    y: .value("Pressure Level", state.pressureLevel.rawValue)
                )
                .foregroundStyle(.green.opacity(0.15))

                LineMark(
                    x: .value("Time", state.timestamp),
                    y: .value("Pressure Level", state.pressureLevel.rawValue)
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)
            }
        }
        .chartXScale(domain: chartTimeDomain(history))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: chartTimeFormat(history))
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 1, 2, 3, 4]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text(ThermalPressureLevel(rawValue: intValue)?.displayName ?? "")
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 200)
    }
}

// MARK: - Fan Speed Chart
struct FanSpeedChart: View {
    let history: [ThermalState]

    /// Discover all fan indices present in the history.
    private var fanIndices: [Int] {
        var indices = Set<Int>()
        for state in history {
            for key in state.fanSpeeds.keys { indices.insert(key) }
        }
        // Fallback: if fanSpeeds dict is empty (old data), use fanSpeed
        if indices.isEmpty && history.contains(where: { $0.fanSpeed != nil }) {
            indices.insert(0)
        }
        return indices.sorted()
    }

    private let fanColors: [Color] = [.blue, .cyan, .teal, .indigo]

    var body: some View {
        Chart {
            ForEach(fanIndices, id: \.self) { fanIdx in
                let label = "Fan \(fanIdx + 1)"
                let color = fanColors[fanIdx % fanColors.count]
                ForEach(history, id: \.id) { state in
                    let rpm = state.fanSpeeds[fanIdx] ?? (fanIdx == 0 ? state.fanSpeed : nil)
                    if let rpm, rpm > 0 {
                        LineMark(
                            x: .value("Time", state.timestamp),
                            y: .value("RPM", rpm),
                            series: .value("Fan", label)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
        }
        .chartXScale(domain: chartTimeDomain(history))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: chartTimeFormat(history))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel("\(value.as(Int.self) ?? 0)")
            }
        }
        .chartLegend(position: .bottom, spacing: 4)
        .frame(height: 200)
    }
}

// MARK: - Chart Helpers

/// Compute a tight time domain for the X axis based on actual data.
private func chartTimeDomain(_ history: [ThermalState]) -> ClosedRange<Date> {
    guard let first = history.first?.timestamp,
          let last = history.last?.timestamp else {
        let now = Date()
        return now.addingTimeInterval(-60)...now
    }
    // Ensure at least 30s range so chart isn't a single point
    let span = max(last.timeIntervalSince(first), 30)
    return first...first.addingTimeInterval(span)
}

/// Pick time format based on the data span.
private func chartTimeFormat(_ history: [ThermalState]) -> Date.FormatStyle {
    guard let first = history.first?.timestamp,
          let last = history.last?.timestamp else {
        return .dateTime.hour().minute()
    }
    let span = last.timeIntervalSince(first)
    if span < 600 {       // < 10 min: show mm:ss
        return .dateTime.minute().second()
    } else {              // > 10 min: show hh:mm
        return .dateTime.hour().minute()
    }
}

// MARK: - Empty Chart View
struct EmptyChartView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No thermal data yet")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Start monitoring to see history")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Statistics View
struct StatisticsView: View {
    let history: [ThermalState]
    
    var averageTemperature: Double {
        guard !history.isEmpty else { return 0 }
        let allTemps = history.flatMap { $0.componentTemperatures.values }
        guard !allTemps.isEmpty else { return 0 }
        return allTemps.reduce(0, +) / Double(allTemps.count)
    }
    
    var maxTemperature: Double {
        guard !history.isEmpty else { return 0 }
        return history.flatMap { $0.componentTemperatures.values }.max() ?? 0
    }
    
    var throttlingEvents: Int {
        history.filter { $0.isThrottling }.count
    }
    
    var pressureDistribution: [ThermalPressureLevel: Int] {
        var distribution: [ThermalPressureLevel: Int] = [:]
        for state in history {
            distribution[state.pressureLevel, default: 0] += 1
        }
        return distribution
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics").font(.caption).fontWeight(.medium)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                StatItem(title: "Avg", value: "\(averageTemperature.safeInt)°C")
                StatItem(title: "Max", value: "\(maxTemperature.safeInt)°C")
                StatItem(title: "Throttle", value: "\(throttlingEvents)")
                StatItem(title: "Points", value: "\(history.count)")
            }
        }
    }
}

// MARK: - Stat Item
struct StatItem: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.system(.caption, design: .monospaced)).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ThermalHistoryChart(selectedTimePeriod: .constant(.lastHour))
        .environmentObject(ThermalMonitor())
}

// ============================================================
// File: HistoryView.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-01-23
// Last Modified by: Douglas M.
// Last Modified: 2026-02-09
// Description: Thermal history and analytics view
// ============================================================

import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject var thermalMonitor: ThermalMonitor
    @State private var selectedTimePeriod: TimePeriod = .last5Min
    @State private var showingExportOptions = false

    var thermalAnalysis: ThermalAnalysis? {
        thermalMonitor.getThermalAnalysis(for: selectedTimePeriod)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let analysis = thermalAnalysis {
                    AnalysisOverviewCard(analysis: analysis)
                }

                ThermalHistoryChart(selectedTimePeriod: $selectedTimePeriod)

                if let analysis = thermalAnalysis {
                    DetailedStatisticsCard(analysis: analysis)
                }

                ExportOptionsCard(showingExportOptions: $showingExportOptions)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingExportOptions.toggle() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingExportOptions) { ExportOptionsView() }
    }
}

// MARK: - Time Period Selector
struct TimePeriodSelector: View {
    @Binding var selectedPeriod: TimePeriod

    var body: some View {
        Picker("Period", selection: $selectedPeriod) {
            ForEach(TimePeriod.allCases, id: \.self) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }
}

// MARK: - Analysis Overview
struct AnalysisOverviewCard: View {
    let analysis: ThermalAnalysis

    var body: some View {
        CardView(title: "Analysis", icon: "chart.xyaxis.line") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature").font(.caption2).foregroundStyle(.tertiary)
                    StatRow(label: "Avg", value: "\(analysis.averageTemperature.safeInt)\u{00B0}C")
                    StatRow(label: "Max", value: "\(analysis.maxTemperature.safeInt)\u{00B0}C")
                    StatRow(label: "Min", value: "\(analysis.minTemperature.safeInt)\u{00B0}C")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Performance").font(.caption2).foregroundStyle(.tertiary)
                    StatRow(label: "Throttle", value: "\(analysis.throttlingEvents) events")
                    StatRow(label: "Fan", value: "\(analysis.averageFanSpeed.safeInt) RPM")
                    StatRow(label: "Risk", value: analysis.riskLevel.rawValue)
                }
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: riskIcon).foregroundStyle(analysis.riskLevel.color)
                Text(analysis.riskLevel.rawValue)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(analysis.riskLevel.color)
                Spacer()
                Text(riskDescription).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var riskIcon: String {
        switch analysis.riskLevel {
        case .low: return "checkmark.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "xmark.circle.fill"
        }
    }

    private var riskDescription: String {
        switch analysis.riskLevel {
        case .low: return "Optimal"
        case .medium: return "Thermal stress detected"
        case .high: return "Frequent throttling"
        }
    }
}

// MARK: - Stat Row
struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Detailed Statistics
struct DetailedStatisticsCard: View {
    let analysis: ThermalAnalysis

    var body: some View {
        CardView(title: "Detailed Stats", icon: "chart.bar.xaxis") {
            // Pressure distribution
            if !analysis.thermalPressureDistribution.isEmpty,
               let maxVal = analysis.thermalPressureDistribution.values.max(), maxVal > 0 {
                Text("Pressure Distribution").font(.caption).fontWeight(.medium)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(ThermalPressureLevel.allCases, id: \.self) { level in
                        if let dur = analysis.thermalPressureDistribution[level], dur > 0 {
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(level.color)
                                    .frame(width: 28, height: max(4, CGFloat(dur / maxVal) * 50))
                                Text(formatDuration(dur)).font(.system(size: 8)).foregroundStyle(.secondary)
                                Text(level.displayName).font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .frame(height: 80)
            }

            // Metrics grid
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                MetricCell("Throttle Freq", getThrottlingFrequency(), "events/hr")
                MetricCell("Fan Usage", getFanUsagePercentage(), "%")
                MetricCell("Temp Variance", String(format: "%.1f", (analysis.maxTemperature - analysis.minTemperature).isFinite ? analysis.maxTemperature - analysis.minTemperature : 0), "\u{00B0}C")
                MetricCell("Stability", getStabilityScore(), "%")
            }
        }
    }

    private func MetricCell(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let h = d.safeInt / 3600; let m = d.safeInt % 3600 / 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    private func getThrottlingFrequency() -> String {
        let h = analysis.period.timeInterval / 3600
        guard h > 0 else { return "0.0" }
        let f = Double(analysis.throttlingEvents) / h
        return String(format: "%.1f", f.isFinite ? f : 0)
    }

    private func getFanUsagePercentage() -> String {
        let pct = (analysis.averageFanSpeed / 6000) * 100
        return String(format: "%.1f", pct.isFinite ? pct : 0)
    }

    private func getStabilityScore() -> String {
        let v = analysis.maxTemperature - analysis.minTemperature
        let s = max(0, 100 - (v * 2))
        return String(format: "%.0f", s.isFinite ? s : 0)
    }
}

// MARK: - Metric Card (kept for compatibility)
struct MetricCard: View {
    let title: String; let value: String; let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Export Options Card
struct ExportOptionsCard: View {
    @Binding var showingExportOptions: Bool
    @EnvironmentObject var thermalMonitor: ThermalMonitor

    var body: some View {
        CardView(title: "Export", icon: "square.and.arrow.up") {
            VStack(spacing: 6) {
                ExportOptionButton(icon: "doc.text", title: "JSON", description: "Complete thermal data") {
                    exportJSON()
                }
                ExportOptionButton(icon: "doc.plaintext", title: "CSV", description: "Summary data") {
                    exportCSV()
                }
            }
        }
    }

    private func exportJSON() {
        guard let data = thermalMonitor.exportHistory() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ExoMacFan_ThermalData.json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func exportCSV() {
        // Build CSV from current analysis
        var csv = "Timestamp,PressureLevel,MaxTemp,FanSpeed\n"
        let history = thermalMonitor.getThermalHistory(for: .all)
        for state in history {
            let maxT = state.componentTemperatures.values.max() ?? 0
            let fan = state.fanSpeed ?? 0
            csv += "\(state.timestamp.ISO8601Format()),\(state.pressureLevel.displayName),\(String(format: "%.1f", maxT)),\(String(format: "%.0f", fan))\n"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ExoMacFan_Summary.csv"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct ExportOptionButton: View {
    let icon: String; let title: String; let description: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.blue).frame(width: 16).font(.caption)
                Text(title).font(.caption).fontWeight(.medium)
                Text(description).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct ExportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hammer.fill").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Export coming in a future update.").font(.body).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 300, minHeight: 200)
    }
}

#Preview {
    HistoryView()
        .environmentObject(ThermalMonitor())
}

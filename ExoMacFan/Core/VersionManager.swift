// ============================================================
// File: VersionManager.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Description: Version and build number management
// ============================================================

import Foundation
import SwiftUI

@MainActor
class VersionManager: ObservableObject {
    // MARK: - Published Properties
    @Published var currentVersion: String
    @Published var buildNumber: Int
    @Published var fullVersionString: String
    
    // MARK: - Initialization
    init() {
        // Get version from Info.plist
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.currentVersion = version
        
        // Get build number from Info.plist
        let buildString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let build = Int(buildString) ?? 1
        self.buildNumber = build
        
        // Create full version string
        self.fullVersionString = "\(version) (\(build))"
    }
    
    // MARK: - Version Information
    var versionInfo: VersionInfo {
        return VersionInfo(
            version: currentVersion,
            build: buildNumber,
            fullString: fullVersionString,
            buildDate: getBuildDate(),
            gitCommit: getGitCommit(),
            isRelease: isReleaseBuild()
        )
    }
    
    private func getBuildDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: Bundle.main.buildDate ?? Date())
    }
    
    private func getGitCommit() -> String {
        // This would typically be set during build process
        return Bundle.main.infoDictionary?["GitCommit"] as? String ?? "unknown"
    }
    
    private func isReleaseBuild() -> Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

// MARK: - Version Info Model
struct VersionInfo {
    let version: String
    let build: Int
    let fullString: String
    let buildDate: String
    let gitCommit: String
    let isRelease: Bool
    
    var buildType: String {
        return isRelease ? "Release" : "Debug"
    }
    
    var versionDisplay: String {
        return "Version \(version) Build \(build) (\(buildType))"
    }
}

// MARK: - Bundle Extension
extension Bundle {
    var buildDate: Date? {
        if let infoDictionary = self.infoDictionary,
           let buildDate = infoDictionary["BuildDate"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            return formatter.date(from: buildDate)
        }
        return nil
    }
}

// MARK: - Version View
struct VersionView: View {
    @StateObject private var versionManager = VersionManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                
                Text("Version Information")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                VersionInfoRow(title: "Version", value: versionManager.currentVersion)
                VersionInfoRow(title: "Build", value: "\(versionManager.buildNumber)")
                VersionInfoRow(title: "Type", value: versionManager.versionInfo.buildType)
                VersionInfoRow(title: "Build Date", value: versionManager.versionInfo.buildDate)
                
                if versionManager.versionInfo.gitCommit != "unknown" {
                    VersionInfoRow(title: "Git Commit", value: String(versionManager.versionInfo.gitCommit.prefix(8)))
                }
            }
        }
    }
}

// MARK: - Version Info Row
struct VersionInfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

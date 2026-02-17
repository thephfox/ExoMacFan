// ============================================================
// File: SMCHelper.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-02-10
// Last Modified by: Douglas Meirelles (thephfox)
// Last Modified: 2026-02-10
// Description: Privileged SMC write helper — installs a LaunchDaemon
//              that runs at boot as root. First launch prompts for
//              admin password to install; after that, no prompts ever.
// ============================================================

import Foundation
import Combine

/// Manages a persistent privileged helper daemon for SMC fan control.
///
/// **First launch**: Prompts for admin password to install the helper
/// binary and LaunchDaemon plist. The daemon starts immediately.
///
/// **Every subsequent launch** (including after reboot): The daemon is
/// already running via launchd — the app just connects to its socket.
/// No password prompt needed.
class SMCHelper: ObservableObject {
    static let shared = SMCHelper()

    @Published var progressMessage: String = ""
    @Published var isBusy: Bool = false
    @Published var isConnected: Bool = false

    private let lock = NSLock()
    private var socketFD: Int32 = -1

    // Fixed paths — daemon runs as root, socket is shared
    private let socketPath = "/tmp/exomacfan.sock"
    private let installedHelperPath = "/Library/PrivilegedHelperTools/ExoMacFanHelper"
    private let launchDaemonPlist = "/Library/LaunchDaemons/com.exomacfan.helper.plist"

    private init() {}

    // MARK: - Installation Check

    /// Whether the LaunchDaemon is installed (helper + plist in system dirs).
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedHelperPath) &&
        FileManager.default.fileExists(atPath: launchDaemonPlist)
    }

    /// Whether the installed helper is outdated (different from the bundled one).
    private var needsUpdate: Bool {
        let bundledPath = Bundle.main.bundlePath + "/Contents/MacOS/ExoMacFanHelper"
        guard let bundledAttrs = try? FileManager.default.attributesOfItem(atPath: bundledPath),
              let installedAttrs = try? FileManager.default.attributesOfItem(atPath: installedHelperPath),
              let bundledSize = bundledAttrs[.size] as? Int,
              let installedSize = installedAttrs[.size] as? Int,
              let bundledMod = bundledAttrs[.modificationDate] as? Date,
              let installedMod = installedAttrs[.modificationDate] as? Date else {
            return true
        }
        return bundledSize != installedSize || bundledMod > installedMod
    }

    // MARK: - Daemon Lifecycle

    /// Connect to the daemon at app startup. Installs if needed (one-time admin prompt).
    func ensureDaemon() async -> Bool {
        if isConnected { return true }

        // 1. Try connecting to an already-running daemon (no prompt)
        if connectAndVerify() {
            print("🔐 ✅ Connected to helper daemon (already running)")
            await MainActor.run { isConnected = true }
            return true
        }

        // 2. If installed but not running, try loading the daemon
        if isInstalled && !needsUpdate {
            print("🔐 LaunchDaemon installed but not running, loading...")
            await installAndLoad(reason: "load")
            if connectAndVerify() {
                print("🔐 ✅ Connected to helper daemon (loaded)")
                await MainActor.run { isConnected = true }
                return true
            }
        }

        // 3. Not installed or needs update — install (prompts for admin password)
        print("🔐 Helper not installed or outdated, installing...")
        await MainActor.run {
            isBusy = true
            progressMessage = "Setting up fan control (one-time setup)…"
        }

        let installed = await installAndLoad(reason: "install")

        await MainActor.run {
            isBusy = false
            progressMessage = ""
        }

        guard installed else {
            print("🔐 ❌ Installation failed")
            return false
        }

        // Wait for daemon to start and connect
        let connected = await waitForConnection(timeout: 10.0)
        if connected {
            print("🔐 ✅ Connected to helper daemon (freshly installed)")
            await MainActor.run { isConnected = true }
        } else {
            print("🔐 ❌ Could not connect after install")
        }
        return connected
    }

    // MARK: - Install / Load

    /// Install helper binary + LaunchDaemon plist, or just load if already installed.
    @discardableResult
    private func installAndLoad(reason: String) async -> Bool {
        let bundledHelper = Bundle.main.bundlePath + "/Contents/MacOS/ExoMacFanHelper"
        guard FileManager.default.fileExists(atPath: bundledHelper) else {
            print("🔐 ❌ Bundled helper not found")
            return false
        }

        // Build the shell script that runs as root
        var cmds: [String] = []

        if reason == "install" || needsUpdate {
            // Create directory, copy helper, set permissions
            cmds.append("mkdir -p /Library/PrivilegedHelperTools")
            cmds.append("cp '\(bundledHelper)' '\(installedHelperPath)'")
            cmds.append("chmod 755 '\(installedHelperPath)'")
            cmds.append("chown root:wheel '\(installedHelperPath)'")

            // Write LaunchDaemon plist
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.exomacfan.helper</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(installedHelperPath)</string>
                    <string>daemon</string>
                    <string>\(socketPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardErrorPath</key>
                <string>/tmp/exomacfan-helper.log</string>
            </dict>
            </plist>
            """
            // Escape for shell
            let escaped = plistContent.replacingOccurrences(of: "'", with: "'\\''")
            cmds.append("echo '\(escaped)' > '\(launchDaemonPlist)'")
            cmds.append("chmod 644 '\(launchDaemonPlist)'")
            cmds.append("chown root:wheel '\(launchDaemonPlist)'")
        }

        // Unload old daemon if running, then load
        cmds.append("launchctl bootout system/com.exomacfan.helper 2>/dev/null || true")
        cmds.append("sleep 1")
        cmds.append("rm -f '\(socketPath)'")
        cmds.append("launchctl bootstrap system '\(launchDaemonPlist)'")

        let script = cmds.joined(separator: " && ")
        let appleScript = "do shell script \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", appleScript]
                let errPipe = Pipe()
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errPipe

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if proc.terminationStatus != 0 {
                        let errStr = String(data: errData, encoding: .utf8) ?? ""
                        print("🔐 ❌ Install script failed (\(proc.terminationStatus)): \(errStr)")
                        cont.resume(returning: false)
                    } else {
                        print("🔐 ✅ Install/load completed")
                        cont.resume(returning: true)
                    }
                } catch {
                    print("🔐 ❌ osascript failed: \(error)")
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Connection

    /// Try to connect to the socket and verify the daemon is alive.
    private func connectAndVerify() -> Bool {
        guard tryConnect() else { return false }

        // Send a test command to verify the daemon is alive
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let msg = "status\n"
        msg.withCString { ptr in _ = Darwin.send(socketFD, ptr, msg.utf8.count, 0) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.recv(socketFD, &buf, buf.count, 0)
        if n > 0, let resp = String(bytes: buf.prefix(n), encoding: .utf8), resp.hasPrefix("OK") {
            return true
        }

        // Dead connection
        close(socketFD)
        socketFD = -1
        return false
    }

    /// Low-level socket connect.
    private func tryConnect() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strcpy(dest, ptr)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result == 0 {
            socketFD = fd
            return true
        } else {
            close(fd)
            return false
        }
    }

    /// Wait for the daemon socket to appear and connect.
    private func waitForConnection(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { cont.resume(returning: false); return }
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if self.connectAndVerify() {
                        cont.resume(returning: true)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                cont.resume(returning: false)
            }
        }
    }

    // MARK: - Command Execution

    /// Send a command to the daemon via Unix socket. No password prompt.
    func sendCommand(_ command: String) async -> (success: Bool, output: String) {
        guard await ensureDaemon() else {
            return (false, "Helper not available")
        }

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, self.socketFD >= 0 else {
                    cont.resume(returning: (false, "Not connected"))
                    return
                }

                self.lock.lock()
                defer { self.lock.unlock() }

                // Set socket recv timeout (5s)
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(self.socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                // Send command
                let msg = command + "\n"
                let sent = msg.withCString { ptr in
                    Darwin.send(self.socketFD, ptr, msg.utf8.count, 0)
                }

                if sent <= 0 {
                    // Connection broken — try to reconnect once
                    close(self.socketFD)
                    self.socketFD = -1
                    DispatchQueue.main.async { self.isConnected = false }
                    cont.resume(returning: (false, "Connection lost"))
                    return
                }

                // Read response (blocking with timeout)
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.recv(self.socketFD, &buf, buf.count, 0)
                var response = ""
                if n > 0 {
                    response = String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
                }

                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🔐 [\(command)] → \(trimmed)")
                cont.resume(returning: (trimmed.hasPrefix("OK"), trimmed))
            }
        }
    }

    // MARK: - Cleanup

    /// Disconnect from daemon (does NOT stop it — it keeps running via launchd).
    func cleanup() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        isConnected = false
        print("🔐 Disconnected from helper daemon")
    }

    /// Fully uninstall the LaunchDaemon and helper (requires admin).
    func uninstall() async -> Bool {
        let script = """
        launchctl bootout system/com.exomacfan.helper 2>/dev/null || true; \
        rm -f '\(installedHelperPath)' '\(launchDaemonPlist)' '\(socketPath)'
        """
        let appleScript = "do shell script \"\(script)\" with administrator privileges"

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", appleScript]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    cont.resume(returning: proc.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }
}

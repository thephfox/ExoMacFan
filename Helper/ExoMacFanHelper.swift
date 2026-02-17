// ============================================================
// File: ExoMacFanHelper.swift
// Created by: Douglas M. — Code PhFox (www.phfox.com)
// Date: 2026-02-10
// Description: Privileged helper CLI for SMC fan control.
//              Runs as root via osascript "with administrator privileges".
//              Accepts commands: unlock, setfan <index> <rpm>, release, status
// ============================================================

import Foundation
import IOKit

// MARK: - SMC Data Structures (must match IOKitInterface.swift)

/// SMC key data struct — must match the kernel's SMCParamStruct exactly (80 bytes).
/// Layout verified against macos-smc-fan research: key@0, vers@4, pLimitData@8,
/// padding@24, keyInfo.dataSize@28, keyInfo.dataType@32, keyInfo.dataAttributes@36,
/// result@40, status@41, data8@42, data32@44, bytes@48.
private struct SMCKeyData {
    struct KeyInfo {
        var dataSize: UInt32 = 0       // offset 28 (relative to parent: +0)
        var dataType: UInt32 = 0       // offset 32 (+4)
        var dataAttributes: UInt8 = 0  // offset 36 (+8)
    }

    var key: UInt32 = 0                                    // 0-3
    var vers: (UInt8, UInt8, UInt8, UInt8) = (0,0,0,0)     // 4-7
    var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)                // 8-23
    var padding0: (UInt8, UInt8, UInt8, UInt8) = (0,0,0,0) // 24-27
    var keyInfo = KeyInfo()                                 // 28-36 (9 bytes)
    var keyInfoPad: (UInt8, UInt8, UInt8) = (0,0,0)         // 37-39 (explicit pad to align result)
    var result: UInt8 = 0                                   // 40
    var status: UInt8 = 0                                   // 41
    var data8: UInt8 = 0                                    // 42 (command byte)
    var padding1: UInt8 = 0                                 // 43
    var data32: UInt32 = 0                                  // 44-47
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) // 48-79
}

// MARK: - SMC Connection

class SMCConnection {
    private var connection: io_connect_t = 0
    private var isAppleSilicon: Bool = false

    init?() {
        // Detect architecture
        var size = 0
        if sysctlbyname("hw.optional.arm64", nil, &size, nil, 0) == 0 {
            var value: Int32 = 0
            sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
            isAppleSilicon = value == 1
        }

        // Helper uses AppleSMC for writes (AppleSMCKeysEndpoint is read-only).
        // On Intel, AppleSMC is the only service. On Apple Silicon, both exist
        // but only AppleSMC allows writes (requires root + code signing).
        let serviceNames = ["AppleSMC", "AppleSMCKeysEndpoint"]
        var connected = false

        for serviceName in serviceNames {
            let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching(serviceName))
            guard service != 0 else {
                printErr("Service \(serviceName) not found, trying next...")
                continue
            }

            let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
            IOObjectRelease(service)

            if result == kIOReturnSuccess {
                printErr("SMC connected via \(serviceName)")
                connected = true
                break
            } else {
                printErr("Failed to open \(serviceName): 0x\(String(format: "%08x", result))")
                connection = 0
            }
        }

        guard connected else {
            printErr("ERROR: No SMC service available")
            return nil
        }

        print("OK: SMC connected (AS=\(isAppleSilicon))")
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    // MARK: - Low-Level SMC

    private func callSMC(inputData: inout SMCKeyData) throws -> SMCKeyData {
        var outputData = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            connection, UInt32(2),
            &inputData, inputSize,
            &outputData, &outputSize
        )

        if result != kIOReturnSuccess {
            throw NSError(domain: "SMC", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "IOKit error 0x\(String(format: "%08x", result))"])
        }

        if outputData.result != 0 {
            throw NSError(domain: "SMC", code: Int(outputData.result),
                          userInfo: [NSLocalizedDescriptionKey: "SMC result 0x\(String(format: "%02x", outputData.result))"])
        }

        return outputData
    }

    private func readKeyInfo(key: UInt32) throws -> SMCKeyData.KeyInfo {
        var input = SMCKeyData()
        input.key = key
        input.data8 = 9 // getKeyInfo
        let output = try callSMC(inputData: &input)
        return output.keyInfo
    }

    func readKeyBytes(key: UInt32) throws -> [UInt8] {
        let info = try readKeyInfo(key: key)
        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // readKey
        var output = try callSMC(inputData: &input)
        let count = Int(info.dataSize)
        return withUnsafeBytes(of: &output.bytes) { ptr in
            Array(ptr.prefix(count))
        }
    }

    private func writeKeyBytes(key: UInt32, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key: key)
        try writeKeyDirect(key: key, dataType: info.dataType, dataSize: info.dataSize, bytes: bytes)
    }

    /// Write SMC key directly without querying key info first.
    /// Needed for keys like Ftst where getKeyInfo returns 0x84.
    private func writeKeyDirect(key: UInt32, dataType: UInt32, dataSize: UInt32, bytes: [UInt8]) throws {
        var input = SMCKeyData()
        input.key = key
        input.data8 = 6 // writeKey
        input.keyInfo.dataSize = dataSize
        input.keyInfo.dataType = dataType

        var tuple = input.bytes
        withUnsafeMutableBytes(of: &tuple) { ptr in
            for (i, byte) in bytes.prefix(Int(dataSize)).enumerated() {
                ptr[i] = byte
            }
        }
        input.bytes = tuple

        _ = try callSMC(inputData: &input)
    }

    func decodeFloat(bytes: [UInt8]) -> Double {
        guard bytes.count >= 4 else { return 0 }
        // Little-endian IEEE 754 float (Apple Silicon)
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) |
                   (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    private func encodeFloatLE(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }

    private func encodeFPE2(_ value: Double) -> [UInt8] {
        let raw = UInt16(min(max(value * 4.0, 0), 65535))
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    // MARK: - Fan Control Commands

    func unlock() -> Bool {
        guard isAppleSilicon else {
            print("OK: Intel — no Ftst unlock needed")
            return true
        }

        // Try Ftst=1 to unlock fan control. On some Apple Silicon Macs,
        // Ftst doesn't exist (SMC returns 0x84). That's OK — F0Md writes
        // work directly without Ftst on those machines.
        let ftstKey = fourCC("Ftst")
        let ui8Type: UInt32 = 0x75693820 // "ui8 "
        do {
            try writeKeyDirect(key: ftstKey, dataType: ui8Type, dataSize: 1, bytes: [1])
            printErr("Ftst=1 written OK")
        } catch {
            printErr("Ftst write skipped (not available on this Mac): \(error)")
            // Not fatal — proceed without Ftst
        }

        // Wait briefly for thermalmonitord to yield (up to 2s)
        let fanCount = getFanCount()
        if fanCount > 0 {
            for attempt in 0..<20 { // 20 × 100ms = 2s
                let modeKey = fourCC("F0Md")
                if let bytes = try? readKeyBytes(key: modeKey),
                   !bytes.isEmpty, bytes[0] != 3 {
                    printErr("thermalmonitord yielded after \((attempt + 1) * 100)ms (mode=\(bytes[0]))")
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        print("OK: Unlocked")
        return true
    }

    func setFanSpeed(fanIndex: Int, rpm: Double) -> Bool {
        // Set forced mode (F%dMd = 1)
        let modeKey = fourCC(String(format: "F%dMd", fanIndex))
        do {
            try writeKeyBytes(key: modeKey, bytes: [1])
        } catch {
            printErr("F\(fanIndex)Md write failed: \(error)")
        }

        // Write target speed
        let targetKey = fourCC(String(format: "F%dTg", fanIndex))
        let encoded = isAppleSilicon ? encodeFloatLE(rpm) : encodeFPE2(rpm)
        do {
            try writeKeyBytes(key: targetKey, bytes: encoded)
            print("OK: F\(fanIndex)Tg=\(Int(rpm)) RPM")
        } catch {
            printErr("F\(fanIndex)Tg write failed: \(error)")
            return false
        }

        return true
    }

    func release() -> Bool {
        // Clear Ftst (may not exist on all Macs)
        if isAppleSilicon {
            let ftstKey = fourCC("Ftst")
            let ui8Type: UInt32 = 0x75693820
            do {
                try writeKeyDirect(key: ftstKey, dataType: ui8Type, dataSize: 1, bytes: [0])
                printErr("Ftst=0 written")
            } catch {
                printErr("Ftst release skipped (not available): \(error)")
            }
        }

        // Reset all fan modes to 0 (system control)
        let count = getFanCount()
        for i in 0..<count {
            let modeKey = fourCC(String(format: "F%dMd", i))
            do {
                try writeKeyBytes(key: modeKey, bytes: [0])
                print("OK: F\(i)Md=0")
            } catch {
                printErr("WARN: F\(i)Md release failed: \(error)")
            }
        }

        return true
    }

    func status() {
        let count = getFanCount()
        print("FANS: \(count)")
        for i in 0..<count {
            let acKey = fourCC(String(format: "F%dAc", i))
            let mxKey = fourCC(String(format: "F%dMx", i))
            let mnKey = fourCC(String(format: "F%dMn", i))
            let mdKey = fourCC(String(format: "F%dMd", i))
            let tgKey = fourCC(String(format: "F%dTg", i))

            let ac = (try? readKeyBytes(key: acKey)).map { decodeFloat(bytes: $0) } ?? 0
            let mx = (try? readKeyBytes(key: mxKey)).map { decodeFloat(bytes: $0) } ?? 0
            let mn = (try? readKeyBytes(key: mnKey)).map { decodeFloat(bytes: $0) } ?? 0
            let md = (try? readKeyBytes(key: mdKey))?.first ?? 0
            let tg = (try? readKeyBytes(key: tgKey)).map { decodeFloat(bytes: $0) } ?? 0

            print("FAN\(i): actual=\(Int(ac)) target=\(Int(tg)) min=\(Int(mn)) max=\(Int(mx)) mode=\(md)")
        }
    }

    func getFanCount() -> Int {
        let key = fourCC("FNum")
        guard let bytes = try? readKeyBytes(key: key) else { return 0 }
        return Int(bytes[0])
    }

    func getMaxSpeed(fanIndex: Int) -> Double {
        let key = fourCC(String(format: "F%dMx", fanIndex))
        guard let bytes = try? readKeyBytes(key: key) else { return 0 }
        return decodeFloat(bytes: bytes)
    }

    // MARK: - Diagnostics

    func diagFtst() -> String {
        var lines: [String] = []
        let ftstKey = fourCC("Ftst")
        lines.append("Ftst=0x\(String(format: "%08x", ftstKey))")

        // Test 1: readKeyInfo
        do {
            let info = try readKeyInfo(key: ftstKey)
            lines.append("keyInfo: size=\(info.dataSize) type=0x\(String(format: "%08x", info.dataType))")
        } catch {
            lines.append("keyInfo FAILED: \(error.localizedDescription)")
        }

        // Test 2: raw read (hardcode size=1, skip readKeyInfo)
        do {
            var input = SMCKeyData()
            input.key = ftstKey
            input.keyInfo.dataSize = 1
            input.data8 = 5 // readKey
            let output = try callSMC(inputData: &input)
            var byte: UInt8 = 0
            withUnsafeBytes(of: output.bytes) { ptr in byte = ptr[0] }
            lines.append("rawRead: \(byte)")
        } catch {
            lines.append("rawRead FAILED: \(error.localizedDescription)")
        }

        // Test 3: raw write ui8
        do {
            var input = SMCKeyData()
            input.key = ftstKey
            input.data8 = 6 // writeKey
            input.keyInfo.dataSize = 1
            input.keyInfo.dataType = 0x75693820 // "ui8 "
            var tuple = input.bytes
            withUnsafeMutableBytes(of: &tuple) { $0[0] = 1 }
            input.bytes = tuple
            _ = try callSMC(inputData: &input)
            lines.append("rawWrite(ui8) OK")
        } catch {
            lines.append("rawWrite(ui8) FAILED: \(error.localizedDescription)")
        }

        // Test 4: raw write with NO result check (ignore SMC result byte)
        do {
            var input = SMCKeyData()
            input.key = ftstKey
            input.data8 = 6
            input.keyInfo.dataSize = 1
            input.keyInfo.dataType = 0x75693820
            var tuple = input.bytes
            withUnsafeMutableBytes(of: &tuple) { $0[0] = 1 }
            input.bytes = tuple

            var outputData = SMCKeyData()
            let inputSize = MemoryLayout<SMCKeyData>.stride
            var outputSize = MemoryLayout<SMCKeyData>.stride
            let result = IOConnectCallStructMethod(connection, UInt32(2),
                                                    &input, inputSize,
                                                    &outputData, &outputSize)
            lines.append("IOKit=0x\(String(format: "%08x", result)) smcResult=0x\(String(format: "%02x", outputData.result))")
        }

        return lines.joined(separator: " | ")
    }

    // MARK: - Helpers

    func fourCC(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.prefix(4) {
            result = (result << 8) + UInt32(char.asciiValue ?? 0)
        }
        return result
    }
}

func printErr(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

// MARK: - Main Entry Point

var globalSocketPath: String?

guard let smc = SMCConnection() else {
    printErr("FATAL: Cannot connect to SMC")
    // Print to stdout so the app can read it
    print("ERROR:Cannot connect to SMC")
    exit(2)
}

let args = CommandLine.arguments

if args.count >= 2 && args[1].lowercased() == "daemon" {
    // DAEMON MODE: listen on a Unix domain socket for commands from the app.
    // The app launches this once via osascript with admin privileges.
    let socketPath: String
    if args.count >= 3 {
        socketPath = args[2]
    } else {
        socketPath = "/tmp/exomacfan_\(getuid()).sock"
    }

    // Clean up stale socket
    unlink(socketPath)

    // Create Unix domain socket
    let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
        printErr("FATAL: Cannot create socket")
        exit(3)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = strcpy(dest, ptr)
            }
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        printErr("FATAL: Cannot bind socket: errno=\(errno)")
        exit(3)
    }

    // Make socket accessible by non-root app
    chmod(socketPath, 0o777)

    guard listen(serverFD, 5) == 0 else {
        printErr("FATAL: Cannot listen on socket")
        exit(3)
    }

    printErr("Helper daemon listening on \(socketPath)")

    // Store socket path globally for cleanup
    globalSocketPath = socketPath

    // Handle cleanup on exit
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }
    atexit {
        if let p = globalSocketPath { unlink(p) }
    }

    // Accept connections in a loop (one at a time)
    while true {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { continue }

        printErr("Client connected")

        // Read commands from this client until it disconnects
        var buffer = [UInt8](repeating: 0, count: 4096)
        var leftover = ""

        while true {
            let n = recv(clientFD, &buffer, buffer.count, 0)
            if n <= 0 { break } // Client disconnected

            leftover += String(bytes: buffer.prefix(n), encoding: .utf8) ?? ""

            // Process complete lines
            while let newlineRange = leftover.range(of: "\n") {
                let line = String(leftover[leftover.startIndex..<newlineRange.lowerBound])
                leftover = String(leftover[newlineRange.upperBound...])

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if trimmed.lowercased() == "quit" {
                    _ = smc.release()
                    let resp = "OK:Quit\n"
                    _ = resp.withCString { Darwin.send(clientFD, $0, resp.utf8.count, 0) }
                    close(clientFD)
                    close(serverFD)
                    exit(0)
                }

                let parts = trimmed.split(separator: " ").map(String.init)
                let response = processCommand(smc: smc, parts: parts) + "\n"
                _ = response.withCString { Darwin.send(clientFD, $0, response.utf8.count, 0) }
            }
        }

        close(clientFD)
        printErr("Client disconnected")
    }

} else if args.count >= 2 {
    // ONE-SHOT MODE: run a single command and exit
    let parts = Array(args.dropFirst()).map { $0.lowercased() }
    let response = processCommand(smc: smc, parts: parts)
    print(response)
    exit(response.hasPrefix("OK") ? 0 : 1)

} else {
    print("Usage: ExoMacFanHelper daemon | <command> [args...]")
    print("Commands: unlock, setfan <idx> <rpm>, maxfans, release, status, quit")
    exit(1)
}

func processCommand(smc: SMCConnection, parts: [String]) -> String {
    guard !parts.isEmpty else { return "ERROR:Empty command" }

    switch parts[0].lowercased() {
    case "unlock":
        return smc.unlock() ? "OK:Unlocked" : "ERROR:Unlock failed"

    case "setfan":
        guard parts.count >= 3,
              let idx = Int(parts[1]),
              let rpm = Double(parts[2]) else {
            return "ERROR:Usage: setfan <index> <rpm>"
        }
        return smc.setFanSpeed(fanIndex: idx, rpm: rpm) ? "OK:Fan \(idx) set to \(Int(rpm)) RPM" : "ERROR:setfan failed"

    case "maxfans":
        guard smc.unlock() else { return "ERROR:Unlock failed for maxfans" }
        let count = smc.getFanCount()
        var results: [String] = []
        for i in 0..<count {
            let maxRPM = smc.getMaxSpeed(fanIndex: i)
            if smc.setFanSpeed(fanIndex: i, rpm: maxRPM) {
                results.append("Fan\(i)=\(Int(maxRPM))")
            } else {
                results.append("Fan\(i)=FAILED")
            }
        }
        return "OK:MaxFans \(results.joined(separator: " "))"

    case "release":
        return smc.release() ? "OK:Released" : "ERROR:Release failed"

    case "status":
        let count = smc.getFanCount()
        var info: [String] = []
        for i in 0..<count {
            let acKey = smc.fourCC(String(format: "F%dAc", i))
            let mxKey = smc.fourCC(String(format: "F%dMx", i))
            let ac = (try? smc.readKeyBytes(key: acKey)).map { smc.decodeFloat(bytes: $0) } ?? 0
            let mx = (try? smc.readKeyBytes(key: mxKey)).map { smc.decodeFloat(bytes: $0) } ?? 0
            info.append("Fan\(i):\(Int(ac))/\(Int(mx))")
        }
        return "OK:Status \(info.joined(separator: " "))"

    case "diag":
        return "OK:Diag \(smc.diagFtst())"

    case "quit":
        _ = smc.release()
        exit(0)

    default:
        return "ERROR:Unknown command '\(parts[0])'"
    }
}

// ============================================================
// File: IOKitInterface.swift
// Created by: Douglas Meirelles (thephfox)
// Date: 2026-01-23
// Last Modified by: Douglas Meirelles (thephfox)
// Last Modified: 2026-02-09
// Description: Low-level IOKit interface for SMC and sensor access
// ============================================================

import Foundation
import IOKit
import Darwin

// MARK: - SMC Data Structures

/// SMC key data input/output structure used by IOConnectCallStructMethod.
/// Layout must match the kernel's SMCParamStruct exactly (80 bytes).
/// Verified against macos-smc-fan research: key@0, vers@4, pLimitData@8,
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

/// SMC selector commands
private enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

/// Known SMC data type FourCC codes
private enum SMCDataType: UInt32 {
    case fpe2 = 0x66706532  // "fpe2" - fixed point 14.2
    case sp78 = 0x73703738  // "sp78" - signed fixed point 8.8
    case ui8  = 0x75693820  // "ui8 "
    case ui16 = 0x75693136  // "ui16"
    case ui32 = 0x75693332  // "ui32"
    case si16 = 0x73693136  // "si16"
    case flt  = 0x666C7420  // "flt " - IEEE 754 float (little-endian on Apple Silicon)
    case ioft = 0x696F6674  // "ioft" - IOFloat64 (little-endian 8-byte double)
    case flag = 0x666C6167  // "flag" - boolean byte
}

// MARK: - IOKit Interface

class IOKitInterface {
    // MARK: - Shared Instance
    /// Single shared instance — avoids opening duplicate SMC connections.
    static let shared = IOKitInterface()

    // MARK: - Properties
    /// Primary connection for reads (AppleSMCKeysEndpoint on AS, AppleSMC on Intel).
    private var smcConnection: io_connect_t = 0
    /// Secondary connection for writes (AppleSMC on AS — AppleSMCKeysEndpoint is read-only).
    private var smcWriteConnection: io_connect_t = 0
    private var isConnected: Bool { smcConnection != 0 }
    private var canWrite: Bool { smcWriteConnection != 0 }
    /// True when running on Apple Silicon.
    private(set) var isAppleSilicon: Bool = false
    /// Whether the Ftst diagnostic flag has been set to unlock fan control.
    private var isFanUnlocked: Bool = false

    // MARK: - Initialization
    init() {
        detectArchitecture()
        openSMCConnection()
    }

    deinit {
        // Return fan control to system on teardown
        if isFanUnlocked { try? releaseFanControl() }
        closeSMCConnection()
    }

    /// Emergency cleanup callable from signal handlers / atexit.
    static func emergencyCleanup() {
        if shared.isFanUnlocked {
            try? shared.releaseFanControl()
        }
    }

    /// On startup, ensure macOS has full fan control.
    /// Cleans up stale Ftst=1 left by a previous crash.
    func ensureSystemControl() {
        guard isConnected, isAppleSilicon else { return }
        let ftstKey = "Ftst".fourCharCode
        guard let (bytes, _) = try? readKeyBytes(key: ftstKey),
              !bytes.isEmpty, bytes[0] != 0 else { return }
        // Stale Ftst detected — previous instance crashed without cleanup
        print("⚠️ Stale Ftst=1 detected from previous run, resetting to system control")
        try? releaseFanControl()
    }

    /// Detect Apple Silicon vs Intel via sysctl.
    private func detectArchitecture() {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // hw.optional.arm64 exists and is 1 on Apple Silicon
        if sysctlbyname("hw.optional.arm64", &ret, &size, nil, 0) == 0 {
            isAppleSilicon = ret == 1
        }
    }

    // MARK: - SMC Connection
    private func openSMCConnection() {
        // Try Apple Silicon service name first, then Intel
        let serviceNames = ["AppleSMCKeysEndpoint", "AppleSMC"]

        for serviceName in serviceNames {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))

            guard service != 0 else {
                continue
            }

            let result = IOServiceOpen(service, mach_task_self_, 0, &smcConnection)
            IOObjectRelease(service)

            if result == kIOReturnSuccess {
                print("✅ SMC connection opened via \(serviceName)")
                break
            } else {
                print("⚠️ Failed to open \(serviceName): \(String(format: "0x%08x", result))")
                smcConnection = 0
            }
        }

        if smcConnection == 0 {
            print("⚠️ No SMC service available")
            return
        }

        // On Apple Silicon, open a second connection to AppleSMC for writes.
        // AppleSMCKeysEndpoint is read-only (returns kIOReturnNotWritable).
        if isAppleSilicon {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            if service != 0 {
                let result = IOServiceOpen(service, mach_task_self_, 0, &smcWriteConnection)
                IOObjectRelease(service)
                if result == kIOReturnSuccess {
                    print("✅ SMC write connection opened via AppleSMC")
                } else {
                    print("⚠️ AppleSMC write connection failed: \(String(format: "0x%08x", result))")
                    smcWriteConnection = 0
                }
            }
        } else {
            // Intel: same connection for reads and writes
            smcWriteConnection = smcConnection
        }
    }

    private func closeSMCConnection() {
        if smcWriteConnection != 0 && smcWriteConnection != smcConnection {
            IOServiceClose(smcWriteConnection)
            smcWriteConnection = 0
        }
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
    }

    // MARK: - Low-Level SMC Access

    /// Call SMC with an input struct and receive an output struct.
    /// Checks both the IOKit return code AND the SMC firmware result byte.
    /// - Parameter connection: Override the default read connection (e.g. for writes via AppleSMC).
    private func callSMC(inputData: inout SMCKeyData, connection: io_connect_t? = nil) throws -> SMCKeyData {
        let conn = connection ?? smcConnection
        var outputData = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            conn,
            UInt32(2), // kSMCHandleYPCEvent
            &inputData,
            inputSize,
            &outputData,
            &outputSize
        )

        if result != kIOReturnSuccess {
            throw ThermalError.sensorUnavailable(sensor: "IOKit failed: \(String(format: "0x%08x", result))")
        }

        // Check SMC firmware result byte (0 = success, non-zero = SMC-level error)
        if outputData.result != 0 {
            let op = inputData.data8
            let keyStr = fourCCToString(inputData.key)
            throw ThermalError.sensorUnavailable(
                sensor: "SMC rejected [\(keyStr)] op=\(op) result=0x\(String(format: "%02x", outputData.result))")
        }
        return outputData
    }

    /// Read the info (type + size) for a given SMC key.
    private func readKeyInfo(key: UInt32) throws -> SMCKeyData.KeyInfo {
        var inputData = SMCKeyData()
        inputData.key = key
        inputData.data8 = SMCSelector.getKeyInfo.rawValue

        let outputData = try callSMC(inputData: &inputData)
        return outputData.keyInfo
    }

    /// Read raw bytes for an SMC key.
    private func readKeyBytes(key: UInt32) throws -> (bytes: [UInt8], dataType: UInt32) {
        let keyInfo = try readKeyInfo(key: key)

        var inputData = SMCKeyData()
        inputData.key = key
        inputData.keyInfo.dataSize = keyInfo.dataSize
        inputData.data8 = SMCSelector.readKey.rawValue

        var outputData = try callSMC(inputData: &inputData)

        // Extract bytes efficiently using withUnsafeBytes (no Mirror overhead)
        let count = Int(keyInfo.dataSize)
        let bytes: [UInt8] = withUnsafeBytes(of: &outputData.bytes) { ptr in
            Array(ptr.prefix(count))
        }

        return (bytes, keyInfo.dataType)
    }

    /// Extract hex digit value from an ASCII character (0-9 → 0-9, a-f/A-F → 10-15).
    private func hexDigitValue(_ char: UInt8) -> Int? {
        switch char {
        case 0x30...0x39: return Int(char - 0x30)       // '0'-'9'
        case 0x41...0x46: return Int(char - 0x41 + 10)  // 'A'-'F'
        case 0x61...0x66: return Int(char - 0x61 + 10)  // 'a'-'f'
        default: return nil
        }
    }

    /// Convert raw SMC bytes to a Double based on the data type FourCC.
    ///
    /// Apple SMC fixed-point naming convention:
    ///   spXY = signed,   X hex integer bits, Y hex fractional bits (16-bit total)
    ///   fpXY = unsigned, X hex integer bits, Y hex fractional bits (16-bit total)
    /// Examples: sp78 → signed 7.8, fpe2 → unsigned 14.2, sp87 → signed 8.7
    private func decodeValue(bytes: [UInt8], dataType: UInt32) -> Double? {
        guard !bytes.isEmpty else { return nil }

        // Decompose FourCC into 4 ASCII bytes
        let c0 = UInt8((dataType >> 24) & 0xFF)
        let c1 = UInt8((dataType >> 16) & 0xFF)
        let _ = UInt8((dataType >> 8) & 0xFF) // c2: integer bits (used implicitly via total=16)
        let c3 = UInt8(dataType & 0xFF)

        // --- Generic spXY (signed fixed-point) ---
        if c0 == 0x73 /* 's' */ && c1 == 0x70 /* 'p' */,
           let fracBits = hexDigitValue(c3), bytes.count >= 2 {
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / Double(1 << fracBits)
        }

        // --- Generic fpXY (unsigned fixed-point) ---
        if c0 == 0x66 /* 'f' */ && c1 == 0x70 /* 'p' */,
           let fracBits = hexDigitValue(c3), bytes.count >= 2 {
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / Double(1 << fracBits)
        }

        // --- Explicit scalar types ---
        switch dataType {
        case SMCDataType.ui8.rawValue:
            return Double(bytes[0])

        case SMCDataType.ui16.rawValue:
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))

        case SMCDataType.ui32.rawValue:
            guard bytes.count >= 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) |
                      (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return Double(raw)

        case SMCDataType.si16.rawValue:
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1])))

        case SMCDataType.flt.rawValue:
            // Apple Silicon SMC outputs IEEE 754 floats in little-endian byte order
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) |
                       (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))

        case SMCDataType.ioft.rawValue:
            // IOFloat64: 8-byte double, little-endian
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(bytes[i]) << (i * 8) }
            return Double(bitPattern: raw)

        case SMCDataType.flag.rawValue:
            return Double(bytes[0])

        default:
            // Unknown type — try interpreting as signed 16-bit / 256 (sp78-like)
            if bytes.count >= 2 {
                let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
                return Double(raw) / 256.0
            }
            return bytes.count == 1 ? Double(bytes[0]) : nil
        }
    }

    /// Write raw bytes for an SMC key.
    private func writeKeyBytes(key: UInt32, dataType: UInt32, size: UInt32, bytes: [UInt8]) throws {
        var inputData = SMCKeyData()
        inputData.key = key
        inputData.data8 = SMCSelector.writeKey.rawValue
        inputData.keyInfo.dataSize = size
        inputData.keyInfo.dataType = dataType

        // Copy bytes into the tuple
        var tuple = inputData.bytes
        withUnsafeMutableBytes(of: &tuple) { ptr in
            for (i, byte) in bytes.prefix(Int(size)).enumerated() {
                ptr[i] = byte
            }
        }
        inputData.bytes = tuple

        _ = try callSMC(inputData: &inputData, connection: smcWriteConnection)
    }

    // MARK: - Temperature Reading

    /// Read temperature for a given SMC key. Returns nil if the key doesn't exist.
    func readTemperature(key: String) async throws -> Double? {
        guard isConnected else {
            throw ThermalError.sensorUnavailable(sensor: "SMC Connection")
        }

        do {
            let fourCC = key.fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            guard let value = decodeValue(bytes: bytes, dataType: dataType) else {
                return nil
            }
            // Sanity check: temperature should be in a reasonable range.
            // No real Mac sensor reads below 10°C while running; low values
            // are threshold registers or config data, not live temperatures.
            if value > 10 && value < 150 {
                return value
            }
            return nil
        } catch {
            // Key doesn't exist or can't be read — return nil (not an error)
            return nil
        }
    }

    /// Read any SMC key as a decoded Double, without temperature sanity checks.
    /// Returns nil only if the key doesn't exist or can't be decoded.
    func readRawValue(key: String) async throws -> Double? {
        guard isConnected else { return nil }
        do {
            let fourCC = key.fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            return decodeValue(bytes: bytes, dataType: dataType)
        } catch {
            return nil
        }
    }

    // MARK: - Fan Control

    /// Check if this Mac has fans by reading the "FNum" key.
    func hasFans() async throws -> Bool {
        let count = try await getFanCount()
        return count > 0
    }

    /// Synchronous fan count reader (for unlock/release which can't be async).
    private func getFanCountSync() -> Int {
        guard isConnected else { return 0 }
        do {
            let fourCC = "FNum".fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            guard let value = decodeValue(bytes: bytes, dataType: dataType) else { return 0 }
            return Int(value)
        } catch { return 0 }
    }

    /// Get the number of fans from the "FNum" SMC key.
    func getFanCount() async throws -> Int {
        guard isConnected else {
            print("🌀 getFanCount: not connected")
            return 0
        }
        do {
            let fourCC = "FNum".fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            guard let value = decodeValue(bytes: bytes, dataType: dataType) else {
                print("🌀 getFanCount: decode failed, bytes=\(bytes), type=0x\(String(format: "%08x", dataType))")
                return 0
            }
            print("🌀 getFanCount: \(Int(value)) fans")
            return Int(value)
        } catch {
            print("🌀 getFanCount error: \(error)")
            return 0
        }
    }

    /// Get the maximum fan speed (RPM) for a given fan index.
    func getMaxFanSpeed(fanIndex: Int = 0) async throws -> Double {
        guard isConnected else { return 0 }
        let key = String(format: "F%dMx", fanIndex)
        do {
            let fourCC = key.fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            return decodeValue(bytes: bytes, dataType: dataType) ?? 0
        } catch {
            return 0
        }
    }

    /// Convenience overload without parameters for backward compatibility.
    func getMaxFanSpeed() async throws -> Double {
        return try await getMaxFanSpeed(fanIndex: 0)
    }

    /// Get the minimum fan speed (RPM) for a given fan index.
    func getMinFanSpeed(fanIndex: Int = 0) async throws -> Double {
        guard isConnected else { return 0 }
        let key = String(format: "F%dMn", fanIndex)
        do {
            let fourCC = key.fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            return decodeValue(bytes: bytes, dataType: dataType) ?? 0
        } catch {
            return 0
        }
    }

    /// Get the current fan speed (RPM) for a given fan index.
    func getCurrentFanSpeed(fanIndex: Int = 0) async throws -> Double? {
        guard isConnected else { return nil }
        let key = String(format: "F%dAc", fanIndex)
        do {
            let fourCC = key.fourCharCode
            let (bytes, dataType) = try readKeyBytes(key: fourCC)
            return decodeValue(bytes: bytes, dataType: dataType)
        } catch {
            return nil
        }
    }

    // MARK: - Fan Control (Apple Silicon M1-M4 + Intel)

    /// Unlock fan control on Apple Silicon by setting the Ftst diagnostic flag.
    /// On Intel Macs this is a no-op (direct writes work without unlock).
    func unlockFanControl() throws {
        guard isConnected else { throw ThermalError.fanControlUnavailable }
        if !isAppleSilicon {
            print("🔓 Intel — no Ftst unlock needed")
            return
        }
        guard canWrite else {
            print("🔓 ❌ No AppleSMC write connection — cannot unlock Ftst")
            throw ThermalError.fanControlUnavailable
        }

        // Try Ftst=1 via AppleSMC. On some Apple Silicon Macs, Ftst doesn't exist
        // (SMC returns 0x84 SmcNotFound). In that case, skip it — F0Md writes
        // work directly without Ftst unlock on those machines.
        let ftstKey = "Ftst".fourCharCode
        do {
            var inputData = SMCKeyData()
            inputData.key = ftstKey
            inputData.data8 = SMCSelector.writeKey.rawValue
            inputData.keyInfo.dataSize = 1
            inputData.keyInfo.dataType = SMCDataType.ui8.rawValue
            var tuple = inputData.bytes
            withUnsafeMutableBytes(of: &tuple) { $0[0] = 1 }
            inputData.bytes = tuple
            _ = try callSMC(inputData: &inputData, connection: smcWriteConnection)
            print("🔓 ✅ Ftst=1 written via AppleSMC")
        } catch {
            // Ftst may not exist on this Mac — that's OK, proceed without it
            print("🔓 ⚠️ Ftst write skipped (not available on this Mac): \(error)")
        }

        isFanUnlocked = true

        // Wait for thermalmonitord to yield control (up to 2s, poll every 100ms)
        let fanCount = getFanCountSync()
        if fanCount > 0 {
            var yielded = false
            for attempt in 0..<20 {
                let modeKey = String(format: "F%dMd", 0)
                if let (bytes, _) = try? readKeyBytes(key: modeKey.fourCharCode),
                   !bytes.isEmpty {
                    if bytes[0] != 3 {
                        print("🔓 thermalmonitord yielded after \((attempt + 1) * 100)ms (mode=\(bytes[0]))")
                        yielded = true
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !yielded {
                print("🔓 ⚠️ thermalmonitord did NOT yield after 2s — forcing writes anyway")
            }
        }
    }

    /// Release fan control back to the system (clear Ftst, reset all modes).
    func releaseFanControl() throws {
        guard isConnected else { return }

        if isAppleSilicon && canWrite {
            // Write Ftst=0 directly via AppleSMC (hardcoded ui8)
            let ftstKey = "Ftst".fourCharCode
            var inputData = SMCKeyData()
            inputData.key = ftstKey
            inputData.data8 = SMCSelector.writeKey.rawValue
            inputData.keyInfo.dataSize = 1
            inputData.keyInfo.dataType = SMCDataType.ui8.rawValue
            // bytes already zeroed
            _ = try? callSMC(inputData: &inputData, connection: smcWriteConnection)
            isFanUnlocked = false
            print("🔓 Ftst=0 written (released)")
        }

        // Reset all fan modes to auto
        let fanCount = getFanCountSync()
        for i in 0..<fanCount {
            let modeKey = String(format: "F%dMd", i)
            if let info = try? readKeyInfo(key: modeKey.fourCharCode) {
                try? writeKeyBytes(key: modeKey.fourCharCode, dataType: info.dataType, size: info.dataSize, bytes: [0])
            }
        }
    }

    /// Encode a Double as a 4-byte little-endian IEEE 754 float.
    private func encodeFloatLE(_ value: Double) -> [UInt8] {
        var f = Float(value)
        return withUnsafeBytes(of: &f) { Array($0) } // native LE on ARM/x86
    }

    /// Encode a Double as a 2-byte big-endian fpe2 (14.2 fixed-point, for Intel).
    private func encodeFPE2(_ value: Double) -> [UInt8] {
        let raw = UInt16(min(max(value, 0), 16383) * 4.0)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    /// Set the target fan speed (RPM) for a given fan index.
    /// On Apple Silicon, Ftst must be unlocked first via unlockFanControl().
    func setFanSpeed(_ speed: Double, fanIndex: Int = 0) async throws {
        guard isConnected else {
            print("🔧 setFanSpeed: NOT CONNECTED")
            throw ThermalError.fanControlUnavailable
        }

        print("🔧 setFanSpeed: Fan \(fanIndex) → \(Int(speed)) RPM (AS=\(isAppleSilicon), unlocked=\(isFanUnlocked))")

        // Ensure unlock on Apple Silicon
        if isAppleSilicon && !isFanUnlocked {
            print("🔧 setFanSpeed: Ftst not unlocked, unlocking now...")
            try unlockFanControl()
        }

        // Set forced mode (F%dMd = 1)
        let modeKey = String(format: "F%dMd", fanIndex)
        let modeFourCC = modeKey.fourCharCode
        do {
            let modeInfo = try readKeyInfo(key: modeFourCC)
            print("🔧 \(modeKey) keyInfo: size=\(modeInfo.dataSize), type=\(fourCCToString(modeInfo.dataType))")
            try writeKeyBytes(key: modeFourCC, dataType: modeInfo.dataType, size: modeInfo.dataSize, bytes: [1])

            // Read-back to verify mode actually changed
            if let (modeBytes, _) = try? readKeyBytes(key: modeFourCC) {
                print("🔧 \(modeKey) read-back: \(modeBytes) (expected [1])")
            }
        } catch {
            print("🔧 \(modeKey) write FAILED: \(error)")
            // Intel fallback: "FS! " bitmask
            if !isAppleSilicon {
                let fsKey = "FS! ".fourCharCode
                if let fsInfo = try? readKeyInfo(key: fsKey) {
                    let mask: UInt16 = 1 << UInt16(fanIndex)
                    try? writeKeyBytes(key: fsKey, dataType: fsInfo.dataType, size: fsInfo.dataSize,
                                       bytes: [UInt8(mask >> 8), UInt8(mask & 0xFF)])
                    print("🔧 Intel FS! fallback attempted")
                }
            } else {
                print("🔧 ⚠️ Mode write rejected on Apple Silicon — SMC denied the write")
            }
        }

        // Write target speed — LE float on Apple Silicon, fpe2 on Intel
        let targetKey = String(format: "F%dTg", fanIndex)
        let targetFourCC = targetKey.fourCharCode
        let targetInfo = try readKeyInfo(key: targetFourCC)
        let encoded = isAppleSilicon ? encodeFloatLE(speed) : encodeFPE2(speed)
        print("🔧 \(targetKey) writing \(encoded.map { String(format: "%02x", $0) }.joined()) (\(Int(speed)) RPM)")
        try writeKeyBytes(key: targetFourCC, dataType: targetInfo.dataType,
                          size: targetInfo.dataSize, bytes: encoded)

        // Read-back to verify target speed was accepted
        if let readBackValue = try? await readRawValue(key: targetKey) {
            print("🔧 \(targetKey) read-back: \(Int(readBackValue)) RPM (wrote \(Int(speed)) RPM)")
            if abs(readBackValue - speed) > 100 {
                print("🔧 ⚠️ TARGET MISMATCH — SMC may have rejected or clamped the value")
            }
        }

        // Also read actual current speed for comparison
        let actualKey = String(format: "F%dAc", fanIndex)
        if let actual = try? await readRawValue(key: actualKey) {
            print("🔧 \(actualKey) (actual now): \(Int(actual)) RPM")
        }
    }

    /// Return fan control to the system (disable forced mode).
    func resetFanControl(fanIndex: Int = 0) async throws {
        guard isConnected else { return }
        try releaseFanControl()
    }

    // MARK: - Sensor Discovery

    /// Get the total number of SMC keys available.
    func getTotalKeyCount() throws -> UInt32 {
        guard isConnected else { return 0 }
        let fourCC = "#KEY".fourCharCode
        let (bytes, dataType) = try readKeyBytes(key: fourCC)
        return UInt32(decodeValue(bytes: bytes, dataType: dataType) ?? 0)
    }

    /// Convert a UInt32 FourCC code back to a String.
    private func fourCCToString(_ code: UInt32) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!)
        ]
        return String(chars)
    }

    /// Get the SMC key at a given index using getKeyFromIndex command.
    private func getKeyAtIndex(_ index: UInt32) throws -> UInt32 {
        var inputData = SMCKeyData()
        inputData.data8 = SMCSelector.getKeyFromIndex.rawValue
        inputData.data32 = index

        let outputData = try callSMC(inputData: &inputData)
        return outputData.key
    }

    /// Discover all temperature sensor keys by enumerating SMC keys.
    func discoverAllSensorKeys() async throws -> [String] {
        guard isConnected else { return [] }

        let totalKeys = (try? getTotalKeyCount()) ?? 0
        guard totalKeys > 0 else { return [] }

        var sensorKeys: [String] = []

        for i in 0..<totalKeys {
            guard let keyCode = try? getKeyAtIndex(i) else { continue }
            let keyStr = fourCCToString(keyCode)

            // Temperature sensors start with 'T'
            guard keyStr.hasPrefix("T") else { continue }

            // Verify it's actually readable and decodes to a number
            if let _ = try? await readRawValue(key: keyStr) {
                sensorKeys.append(keyStr)
            }
        }

        // SMC enumeration complete

        return sensorKeys.sorted()
    }

    // MARK: - Hardware Information
    func getHardwareInfo() async throws -> [String: String] {
        var info: [String: String] = [:]

        let infoKeys = [
            "RBr": "Boot ROM Version",
            "RVF": "Firmware Version",
            "RVW": "Firmware Wrapper",
        ]

        for (key, description) in infoKeys {
            if let value = try await readRawValue(key: key) {
                info[description] = String(format: "%.0f", value)
            }
        }

        return info
    }
}

// MARK: - Safe Double to Int Conversion
extension Double {
    /// Safely convert to Int, returning 0 for NaN, Infinity, or overflow values.
    var safeInt: Int {
        guard self.isFinite else { return 0 }
        guard self >= Double(Int.min) && self <= Double(Int.max) else { return 0 }
        return Int(self)
    }
}

// MARK: - String Extension for FourCharCode
extension String {
    var fourCharCode: UInt32 {
        var result: UInt32 = 0
        for char in self.prefix(4) {
            result = (result << 8) + UInt32(char.asciiValue ?? 0)
        }
        // Pad with spaces if less than 4 characters
        let padding = 4 - min(self.count, 4)
        for _ in 0..<padding {
            result = (result << 8) + UInt32(Character(" ").asciiValue ?? 0x20)
        }
        return result
    }
}

# ExoMacFan Architecture

**Created by:** Douglas M. — Code PhFox ([www.phfox.com](https://www.phfox.com))  
**Date:** 2026-01-23  
**Last Updated:** 2026-02-17  
**Purpose:** System architecture for ExoMacFan thermal monitoring and fan control

---

## System Overview

ExoMacFan is a native macOS SwiftUI app that reads thermal sensors and controls fans via the System Management Controller (SMC). It uses a coordinator pattern — `ThermalMonitor` binds four subsystems together and exposes their state to the UI via `@Published` properties. The app enforces single-instance execution to prevent SMC write conflicts.

## Data Flow

```text
ExoMacFanApp
├── Signal handlers (SIGTERM/SIGINT/SIGHUP + atexit)
│   └── IOKitInterface.emergencyCleanup()
│
├── ContentView (NavigationSplitView)
│   ├── DashboardView  ─┐
│   ├── SensorsView     │
│   ├── FansView        ├── @EnvironmentObject ThermalMonitor
│   ├── HistoryView     │
│   └── SettingsView   ─┘
│
└── MenuBarView (MenuBarExtra, .window style)

ThermalMonitor (Coordinator)
├── PressureLevelDetector    → @Published currentPressureLevel
├── ComponentTemperatureTracker → @Published componentTemperatures
│   └── Uses SensorDiscovery for key mappings
├── FanController            → @Published fanSpeeds, isControllingFans
│   ├── Sleep/wake observer (re-establish Ftst)
│   └── Profile-to-RPM conversion
├── ThermalHistoryLogger     → State persistence + analytics
└── IOKitInterface (shared)  → SMC read/write layer
```

## Core Components

### IOKitInterface — SMC Communication Layer

The lowest-level component. Handles all direct hardware interaction.

**Key responsibilities:**

- Open SMC connection via `IOServiceOpen` (`AppleSMCKeysEndpoint` on Apple Silicon, `AppleSMC` on Intel)
- Detect architecture via `sysctl hw.optional.arm64`
- Read/write SMC keys via `IOConnectCallStructMethod` using current AppleSMC ABI-compatible command paths
- Decode values: `flt` (LE float), `ioft` (LE double), generic `spXY`/`fpXY` fixed-point, `ui8`/`ui16`/`ui32`/`si16`/`flag`
- **Two read modes**: `readTemperature()` (sanity-filtered 10–150°C) and `readRawValue()` (unfiltered, for sensor discovery)
- **Fan control**: `Ftst` unlock, `F%dMd` mode write, `F%dTg` target RPM write, with diagnostic logging
- **Emergency cleanup**: Static method callable from signal handlers; releases `Ftst` on the shared IOKit instance
- **Startup cleanup**: `ensureSystemControl()` detects stale `Ftst=1` from previous crashes

**SMC key encoding (Apple Silicon vs Intel):**

| Operation | Apple Silicon | Intel |
| --- | --- | --- |
| Read temperature | `flt` → LE IEEE 754 float | `sp78` → BE signed 8.8 fixed |
| Read fan speed | `flt` → LE float | `fpe2` → BE unsigned 14.2 fixed |
| Write fan target | LE float bytes | `fpe2` bytes |
| Unlock fan control | `Ftst=1` | Direct write / `FS!` bitmask |

### ThermalMonitor — Coordinator

Binds subsystems together using Combine publishers. Manages:

- **Update timer**: 2-second foreground, 15-second background (lifecycle-aware)
- **State logging**: Every tick creates a `ThermalState` and passes it to `ThermalHistoryLogger`
- **Critical condition checks**: Triggers emergency fan control if temps exceed safety limits
- **Startup**: Calls `ensureSystemControlOnStartup()` to clean stale `Ftst`
- **Error surfacing**: Bridges `FanController.error` to `fanControlError` string for UI display

### FanController — Fan Profile & RPM Management

Converts user-selected profiles into actual SMC fan writes.

**RPM calculation:**

```text
targetRPM = fan.minSpeed + (profilePercentage / 100) × (fan.maxSpeed − fan.minSpeed)
```

Where `fan.minSpeed` and `fan.maxSpeed` are read from SMC keys `F%dMn` and `F%dMx`.

**Special cases:**

- **macOS Default**: No writes. `Ftst` cleared. System control.
- **Max Fans**: Writes `fan.maxSpeed` directly (e.g. 5779 RPM).
- **Silent**: Uses pressure curve (low fan preference until thermal pressure rises).
- **Pro-Active**: Uses pressure + component-temperature headroom to increase fan speed before throttling, and reduce speed as headroom returns.
- **Custom**: Uses user slider % directly.

**Sleep/wake**: Observes `NSWorkspace.didWakeNotification` to re-establish `Ftst` (Apple firmware resets it on sleep).

### ComponentTemperatureTracker — Sensor Monitoring

Reads temperature sensors via IOKitInterface every polling interval. Maps raw SMC keys to `ComponentType`:

- **CPU Performance**: `Tp01`, `Tp09`, `Tp0f`, `Tp0n`, `TC0P`, `TC1P`, `TC2P`, `TC3P`
- **CPU Efficiency**: `Tp05`, `Tp0D`, `Tp0j`, `Tp0r`
- **GPU**: `Tg0f`, `Tg0n`, `Tg0b`, `Tg0g`
- **SoC**: `Ts0S`, `Ts1S`, `TH0a`, `TH0b`
- **Ambient**: `TA0P`, `TAOL`
- **Battery**: `TB0T`, `TB1T`, `TB2T`
- **ANE**: `TaP0`, `TaP1`

Detects throttling per component when temperature exceeds configurable thresholds (e.g. SoC > 95°C, Ambient > 45°C).

### SensorDiscovery — Key Enumeration & Classification

Enumerates all SMC ‘T’ keys and classifies them:

- **Active** (value 10–150°C): Live temperature sensors with component-based names
- **Inactive** (≤10°C): Threshold registers, config data, powered-down sensors — named with descriptive suffixes
- **Known keys**: Dictionary maps keys like `TCHP`, `TCXC`, `TCTD` to human-readable names
- **Unknown keys**: Auto-named by component prefix + value range (e.g., "GPU Tg0x (Threshold/Config)")
- Inactive sensors appear in the UI under the "Show inactive" toggle, sorted after active sensors

### ThermalHistoryLogger — Persistence & Analytics

- Stores up to 10,000 `ThermalState` entries in memory
- Saves to `~/Documents/ExoMacFan_thermal_history.json` every 5 minutes
- Provides filtered history by `TimePeriod` (5min, 15min, 1hr, 6hr, All)
- Generates `ThermalAnalysis` with averages, peaks, throttle counts, risk levels

## Data Models

### ThermalState

```swift
struct ThermalState: Identifiable, Codable {
    let timestamp: Date
    let pressureLevel: ThermalPressureLevel     // 0–4
    let componentTemperatures: [ComponentType: Double]
    let fanSpeed: Double?                        // Primary fan RPM
    let fanSpeeds: [Int: Double]                 // All fans keyed by index
    let isThrottling: Bool
    let throttlingComponents: Set<ComponentType>
}
```

### FanProfile

```swift
struct FanProfile {
    let mode: FanControlMode        // macosDefault, silent, pro-active, maxFans, custom
    let pressureCurve: [ThermalPressureLevel: Double]  // % per pressure level
    let customSpeed: Double?        // For custom mode only
}
```

Profile percentages are converted to RPM at write time using actual hardware min/max.

### FanInfo

```swift
struct FanInfo {
    let fanIndex: Int
    let currentSpeed: Double    // Actual RPM from F%dAc
    let maxSpeed: Double        // Hardware max from F%dMx
    let minSpeed: Double        // Hardware min from F%dMn
    let targetSpeed: Double     // Calculated target RPM
    let isControlled: Bool
}
```

## Safety Architecture

### Process-Level Safety (ExoMacFanApp.swift)

1. **Single-instance**: `NSRunningApplication.runningApplications(withBundleIdentifier:)` check at init — duplicate exits immediately
2. **`atexit`**: Calls `IOKitInterface.emergencyCleanup()` on normal exit
3. **Signal handlers**: `SIGTERM`, `SIGINT`, `SIGHUP` → cleanup + `exit(0)`
4. **`willTerminateNotification`**: NSApplication termination → cleanup
5. **Startup cleanup**: Reads `Ftst`, clears stale `=1` from previous crashes
6. **Sleep/wake**: `didWakeNotification` re-establishes control if active

### Component-Level Safety (FanController)

- Fan writes only happen when `isControllingFans == true`
- Mode always starts as `macosDefault` (no writes)
- `returnToSystemControl()` clears `Ftst` and resets all `F%dMd` to 0
- `deinit` releases fan control automatically

### Thermal Safety

- **HIGH TEMP alerts**: SoC > 95°C, Ambient > 45°C, Battery > 45°C
- **Emergency max fans**: Triggered by critical thermal state
- **Automatic fallback**: Returns to system control if issues detected

## Performance

| Context | Polling Interval | Notes |
| --- | --- | --- |
| Foreground (app active) | 2 seconds | Full sensor + fan reads |
| Background (minimized) | 15 seconds | Reduced CPU/energy usage |
| Chart rendering | Downsampled to 150 points | Prevents UI stutter |
| History storage | Max 10,000 entries (~5.5 hours) | Auto-trimmed FIFO |

## Build System

`compile-swift.sh` compiles all Swift sources directly via `swiftc` (no Xcode project required):

- Auto-increments build number in `.build_number`
- Injects `CFBundleVersion`, `BuildDate`, `GitCommit` into `Info.plist` via `PlistBuddy`
- Builds universal binaries by default (`arm64` + `x86_64`)
- Signs with auto-detected Apple Development identity when available, otherwise ad-hoc
- Outputs to `build/ExoMacFan.app`

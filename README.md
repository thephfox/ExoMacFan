# ExoMacFan — Apple Silicon Thermal & Fan Control

**Created by:** Douglas Meirelles (thephfox) — [phfox.com](https://phfox.com)  
**Version:** 1.0.0  
**Date:** 2026-01-23  
**Last Updated:** 2026-02-17  
**License:** MIT License with Attribution and Hardware Disclaimer

> **DISCLAIMER:** This software interacts directly with your Mac's hardware (fans, SMC, thermal sensors). **Use at your own risk.** The author is not responsible for any damage to your hardware. See [LICENSE](LICENSE) for full terms.
>
> **ATTRIBUTION:** If you fork, modify, or incorporate this code into your own project, you must credit the original author — Douglas Meirelles (thephfox) — in your README or documentation.

---

## Overview

ExoMacFan is a native macOS app for Apple Silicon (M1–M5) and Intel Macs that provides real-time thermal monitoring and direct fan control via the System Management Controller (SMC). It reads hardware temperatures, detects thermal throttling, and lets you override macOS fan management when you need more cooling — or less noise.

### How Fan Control Works on Apple Silicon

On Apple Silicon, a system daemon called `thermalmonitord` actively manages fans and blocks direct SMC writes. ExoMacFan installs a **privileged helper daemon** (LaunchDaemon) that runs as root and communicates with the app via a Unix domain socket. The helper connects to `AppleSMC` to write fan targets as **IEEE 754 little-endian floats** — the native Apple Silicon SMC format.

**First launch**: The app prompts for your admin password **once** to install the helper daemon. After that, the daemon runs automatically at boot — no more password prompts, even after restarts.

For Intel Macs, the traditional `fpe2` (big-endian 14.2 fixed-point) encoding and `FS!` bitmask are used instead. Architecture is detected automatically via `sysctl hw.optional.arm64`.

## Key Features

### Thermal Monitoring

- **Component temperatures**: CPU P-cores, E-cores, GPU, ANE, SoC, heatsink, ambient, battery
- **Thermal pressure detection** via `ProcessInfo.thermalState` (Nominal → Moderate → Heavy → Critical)
- **Throttling alerts** per component with real-time status
- **History charts** with auto-scaling time axis, downsampling, and multi-fan display

### Fan Control

- **5 modes**: macOS Default, Silent, Pro-Active, Max Fans, Custom (slider)
- **Real RPM targeting**: Profile percentages are mapped to actual hardware min/max RPM
- **Privileged helper daemon** on Apple Silicon — one-time admin password, persists across reboots
- **Sleep/wake recovery**: Re-establishes fan control after wake (Apple firmware resets `Ftst` on sleep)
- **Signal handlers**: `SIGTERM`, `SIGINT`, `SIGHUP`, `atexit`, and `willTerminateNotification` all release fan control
- **Pro-Active control loop**: Uses thermal pressure + live component temperature headroom to ramp up before throttling, then reduce fan speed as temps recover

### Background Optimization

- **Foreground**: 2-second polling interval
- **Background/minimized**: 15-second polling — reduces CPU and energy usage
- **Lifecycle-aware**: Detects `NSApplication.didBecomeActive` / `didResignActive`

### SMC Data Decoding

- **Apple Silicon**: IEEE 754 float, little-endian (`flt` type)
- **Intel**: Big-endian fixed-point (`fpe2`, `sp78`)
- **Generic decoder**: Handles all `spXY`/`fpXY` fixed-point types by parsing fractional bits from the FourCC name
- **Additional types**: `ioft` (IOFloat64), `flag`, `ui8`, `ui16`, `ui32`, `si16`

### Sensor Classification

- **Active sensors** (10–150°C): Live temperature readings shown by default
- **Inactive sensors** (≤10°C or ≥150°C): Threshold registers, config data, powered-down sensors — visible via "Show inactive" toggle
- **Known non-temperature keys**: `TCHP` (CPU Hot Protection), `TCXC` (CPU Critical Threshold), `TCTD` (CPU Throttle Delta), etc. — identified with descriptive names
- **Auto-classification**: Unknown keys labeled by component and value range (e.g., "CPU TC2b (Threshold/Config)")

### Interface

- **SwiftUI** with NavigationSplitView, sidebar, and tab navigation
- **Dashboard**: Live thermal status, temperature cards, fan speeds with green→red gradient bars
- **Sensors**: Searchable/filterable sensor list with component classification and inactive toggle
- **Charts**: Temperature, pressure, and per-fan RPM history with 5min/15min/1hr/6hr/All periods
- **Menu bar popover**: Quick status and controls (`.menuBarExtraStyle(.window)` for proper button interaction)
- **Fan control error banner**: Shows SMC write errors directly in the Fans tab
- **Settings**: Monitoring interval, export, storage management, versioning info
- **Single-instance enforcement**: Prevents duplicate app instances that could conflict on SMC writes

## App Lifecycle & Safety

| Scenario | Behavior |
| --- | --- |
| **App starts** | Always in **macOS Default** (read-only). Cleans up stale `Ftst`. Enforces single instance. |
| **User selects Max Fans** | Writes `Ftst=1`, waits for `thermalmonitord` to yield, sets `F%dMd=1` + target RPM |
| **User quits normally** | `deinit` + `willTerminateNotification` clear `Ftst=0`, reset all fan modes |
| **App killed (SIGTERM)** | Signal handler runs `emergencyCleanup()` → `Ftst=0` → macOS resumes |
| **App crashes (SIGKILL)** | Next startup detects stale `Ftst=1` and clears it. Sleeping the Mac also resets `Ftst`. |
| **Mac sleeps/wakes** | `Ftst` auto-resets by firmware. `didWakeNotification` re-establishes control if active. |

## Supported Hardware

| Platform | SMC Service | Data Format | Fan Unlock |
| --- | --- | --- | --- |
| **Apple Silicon** (M1–M5) | `AppleSMCKeysEndpoint` (reads) / `AppleSMC` (writes) | IEEE 754 float (LE) | Helper daemon via LaunchDaemon |
| **Intel** | `AppleSMC` | `fpe2` / `sp78` (BE) | Direct write / `FS!` bitmask |
| **Fanless** (MacBook Air etc.) | Same as above | Same | N/A — monitoring only |

## Requirements

- **macOS 14.0+** (Sonoma)
- **Apple Silicon** (M1/M2/M3/M4/M5) or **Intel** Mac
- **Admin privileges** for fan control (monitoring works without)
- **Xcode 15+** or `swiftc` for building from source

## Installation

```bash
git clone https://github.com/thephfox/ExoMacFan.git
cd ExoMacFan
./compile-swift.sh
open build/ExoMacFan.app
```

The compile script auto-increments the build number (stored in `.build_number`) and injects version, build date, and git commit into `Info.plist`.

By default, `compile-swift.sh` builds a **universal app bundle** (`arm64` + `x86_64`), so the generated app can run on both Apple Silicon and Intel Macs.

> **Note:** Fan control requires running with admin privileges (`sudo`). Temperature monitoring works without elevated permissions.

## Fan Control Modes

| Mode | Behavior | RPM Targeting |
| --- | --- | --- |
| **macOS Default** | System-managed. No `Ftst`, no writes. | N/A |
| **Silent** | Fans off until throttling (Heavy+). | `minRPM + (pct/100) × (maxRPM - minRPM)` |
| **Pro-Active** | Dynamic anti-throttling control based on pressure + thermal headroom to safety limits. | Same min→max formula with adaptive % |
| **Max Fans** | Full blast at hardware maximum. | `fan.maxSpeed` directly (e.g. 5779 RPM) |
| **Custom** | User slider 0–100%. | Same min→max formula |

Profile percentages are converted to **actual RPM** using each fan's hardware-reported `F%dMn` (min) and `F%dMx` (max).

## Architecture

```text
┌──────────────────────────────────────────────────────────────┐
│                     ExoMacFanApp                             │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │  ContentView │  │ MenuBarView  │  │ Signal/atexit      │  │
│  │  (SwiftUI)   │  │ (MenuBarExtra)│  │ handlers           │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬───────────┘  │
│         │                 │                    │              │
│         ▼                 ▼                    ▼              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              ThermalMonitor (Coordinator)               │  │
│  │  - Binds Published properties from subsystems           │  │
│  │  - Manages update timer (2s fg / 15s bg)                │  │
│  │  - Observes app lifecycle for background throttling     │  │
│  └──┬──────────┬──────────────┬──────────────┬────────────┘  │
│     ▼          ▼              ▼              ▼               │
│ Pressure   Component     FanController   ThermalHistory     │
│  Level     Temperature   - Ftst unlock   Logger             │
│ Detector    Tracker      - RPM targeting - JSON persistence  │
│             - Sensor     - Sleep/wake    - Analytics          │
│               mappings   - Profiles                          │
│     │          │              │                               │
│     ▼          ▼              ▼                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │           IOKitInterface (SMC Communication)            │  │
│  │  - Architecture detection (sysctl hw.optional.arm64)    │  │
│  │  - Generic spXY/fpXY + flt(LE) + ioft decoder          │  │
│  │  - Ftst unlock/release + emergency cleanup              │  │
│  │  - Read: FNum, F%dAc, F%dMx, F%dMn, temp keys          │  │
│  │  - Write: Ftst, F%dMd, F%dTg (LE float / fpe2)         │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Core Files

| File | Purpose |
| --- | --- |
| `ExoMacFanApp.swift` | Entry point, signal handlers, startup cleanup, single-instance enforcement |
| `ThermalMonitor.swift` | Coordinator, lifecycle observer, timer management |
| `IOKitInterface.swift` | SMC read/write, Ftst unlock, architecture detection, value decoding |
| `FanController.swift` | Fan profiles, RPM calculation, sleep/wake recovery |
| `ComponentTemperatureTracker.swift` | Sensor key mappings, throttling detection |
| `PressureLevelDetector.swift` | `ProcessInfo.thermalState` monitoring |
| `SensorDiscovery.swift` | SMC key enumeration, sensor classification, inactive sensor identification |
| `ThermalHistoryLogger.swift` | State logging, JSON persistence, analytics |
| `Models.swift` | Data types: ThermalState, FanInfo, FanProfile, ComponentType, etc. |
| `VersionManager.swift` | Build version display from Info.plist metadata |

### Versioning

Build numbers auto-increment via `compile-swift.sh`. Each build injects:

- `CFBundleShortVersionString` — semantic version (e.g. `1.0.0`)
- `CFBundleVersion` — auto-incremented build number
- `BuildDate` — ISO 8601 UTC timestamp
- `GitCommit` — short hash from `git rev-parse --short HEAD`

## Privacy & Security

- **No network access** — All processing is local
- **No telemetry** — Zero data collection or transmission
- **No serial numbers** — Hardware ID uses model info only
- **Local storage** — Thermal history in `~/Documents/ExoMacFan_thermal_history.json`
- **Open source** — Full transparency

## Troubleshooting

| Issue | Solution |
| --- | --- |
| **Fan control unavailable** | Ensure the helper daemon is installed (Settings → Fan Control Daemon). Check that your Mac has fans (MacBook Air is fanless). |
| **No sensors detected** | Refresh sensor discovery; verify SMC access permissions |
| **Fans stuck after crash** | Relaunch the app (it auto-cleans stale `Ftst`), or sleep/wake the Mac |
| **Wrong temperature values** | Ensure you're on the latest build — older versions had big-endian float bugs |
| **High CPU in background** | Update to latest build — background polling is now 15s instead of 2s |
| **Multiple instances** | The app enforces single-instance. If a second copy opens, it activates the existing window and exits. |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test across different Mac generations (M1/M2/M3/M4/M5 + Intel)
4. Submit a pull request

### Areas for Contribution

- Sensor mappings for future Mac models
- Fan control profiles for specific workloads
- UI/UX improvements and accessibility
- Intel Mac testing and validation

## Acknowledgments

- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) — Apple Silicon `Ftst` unlock research (M1–M5 compatible approach)
- [Stats](https://github.com/exelban/stats) — SMC sensor integration reference
- [SMCKit](https://github.com/beltex/SMCKit) — SMC library foundation
- [Asahi Linux macsmc-hwmon](https://github.com/AsahiLinux/linux) — SMC key schema documentation
- Apple Developer Documentation — IOKit and thermal API references

## License

MIT License with Attribution and Hardware Disclaimer

- You **must credit** the original author (Douglas Meirelles / thephfox / [phfox.com](https://phfox.com)) in any derivative work.
- You use this software **at your own risk** — the author is not liable for hardware damage.

See the [LICENSE](LICENSE) file for full terms.

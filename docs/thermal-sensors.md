# Apple Silicon Thermal Sensor Reference

**Created by:** Douglas Meirelles (thephfox)  
**Date:** 2026-01-23  
**Last Updated:** 2026-02-17  
**Purpose:** SMC sensor key mappings, data formats, and fan control details for ExoMacFan

---

## How ExoMacFan Reads Sensors

ExoMacFan enumerates SMC keys via `IOConnectCallStructMethod` (selector 8 for key-at-index, selector 9 for key info, selector 5 for read). Each key is a 4-character ASCII code (FourCC) with a data type that determines decoding.

### Data Types

| Type | Size | Format | Used For |
| ---- | ---- | ------ | -------- |
| `flt` | 4 bytes | IEEE 754 float, **little-endian** | Apple Silicon temps, fan RPM |
| `ioft` | 8 bytes | IEEE 754 double, **little-endian** | Some Apple Silicon sensors |
| `sp78` | 2 bytes | Signed 8-bit int + 8-bit fraction, **big-endian** | Intel temperatures |
| `fpe2` | 2 bytes | Unsigned 14-bit int + 2-bit fraction, **big-endian** | Intel fan RPM |
| `spXY` | 2 bytes | Signed, X integer + Y fractional bits, BE | Generic signed fixed-point |
| `fpXY` | 2 bytes | Unsigned, X integer + Y fractional bits, BE | Generic unsigned fixed-point |
| `ui8` | 1 byte | Unsigned integer | Flags, modes |
| `ui16` | 2 bytes | Unsigned 16-bit, BE | Counters |
| `ui32` | 4 bytes | Unsigned 32-bit, BE | Identifiers |
| `si16` | 2 bytes | Signed 16-bit, BE | Signed values |
| `flag` | 1 byte | Boolean (0 or 1) | Feature flags |

**Note on `spXY`/`fpXY`**: The X and Y characters are hex digits encoding the number of integer and fractional bits. For example, `sp78` = signed with 7 integer bits + 8 fractional bits. `fpe2` = unsigned with 14 integer bits + 2 fractional bits.

## Sensor Key Classification

ExoMacFan classifies all SMC ‘T’ keys into **active** or **inactive** categories:

- **Active** (value 10–150°C): Live temperature sensors, shown by default
- **Inactive** (≤10°C or ≥150°C): Threshold registers, config data, powered-down sensors — visible via "Show inactive" toggle

Inactive keys are identified using a known-key dictionary (`TCHP` → "CPU Hot Protection Threshold", etc.) or auto-named by component and value range.

### Active Temperature Sensors

| Component | Key Patterns | Typical Range | HIGH TEMP Alert |
| --------- | ------------ | ------------- | --------------- |
| **CPU Performance** | `Tp01`, `Tp09`, `Tp0f`, `Tp0n`, `TC0P`–`TC5P` | 40–95°C | 105°C |
| **CPU Efficiency** | `Tp05`, `Tp0D`, `Tp0j`, `Tp0r` | 35–80°C | 105°C |
| **GPU** | `Tg0f`, `Tg0n`, `Tg0b`, `Tg0g` | 35–90°C | 100°C |
| **SoC / Heatsink** | `Ts0S`, `Ts1S`, `TH0a`, `TH0b` | 40–80°C | 95°C |
| **Ambient** | `TA0P`, `TAOL` | 22–35°C | 45°C |
| **Battery** | `TB0T`, `TB1T`, `TB2T` | 25–40°C | 45°C |
| **ANE** | `TaP0`, `TaP1`, `TaP2` | 30–70°C | 95°C |

**Important**: `TH0a`/`TH0b` are **heatsink** temperatures (60–80°C under load), not ambient. They are classified as SoC, not Ambient.

### Fan Keys

| Key | Purpose | Format |
| --- | ------- | ------ |
| `FNum` | Number of fans | `ui8` |
| `F%dAc` | Current fan speed (RPM) | `flt` (AS) / `fpe2` (Intel) |
| `F%dMx` | Maximum fan speed (RPM) | `flt` / `fpe2` |
| `F%dMn` | Minimum fan speed (RPM) | `flt` / `fpe2` |
| `F%dTg` | Target fan speed (write) | `flt` / `fpe2` |
| `F%dMd` | Fan mode (0=auto, 1=forced) | `ui8` |
| `Ftst` | Diagnostic unlock flag | `ui8` (Apple Silicon only) |

Where `%d` is the fan index (0-based).

### Typical Fan Hardware Values (MacBook Pro M-series)

| Fan | Min RPM | Max RPM |
| --- | ------- | ------- |
| Fan 0 (left) | 1200 | ~5779 |
| Fan 1 (right) | 1200 | ~6241 |

Values vary by model. Fanless models (MacBook Air) report `FNum=0`.

## Fan Control Protocol

### Apple Silicon (M1–M5)

1. **Unlock**: Write `Ftst=1` via keyInfo + write call
2. **Wait**: Poll `F0Md` every 100ms until it changes from 3 (system-managed), max 2 seconds
3. **Set mode**: Write `F%dMd=1` (forced mode) for each fan
4. **Set target**: Write `F%dTg=<RPM>` as 4-byte LE float for each fan
5. **Release**: Write `Ftst=0`, write `F%dMd=0` for all fans

`thermalmonitord` blocks direct fan mode writes when `Ftst=0`. The unlock must be done first.

**Sleep/wake behavior**: Apple firmware resets `Ftst=0` during sleep. ExoMacFan observes `NSWorkspace.didWakeNotification` to re-establish control.

### Intel

1. **Set mode**: Write `F%dMd=1` directly (no `Ftst` needed)
2. **Set target**: Write `F%dTg=<RPM>` as 2-byte big-endian `fpe2`
3. **Release**: Write `F%dMd=0` for all fans

Some Intel models use an `FS!` bitmask instead of per-fan mode writes.

## Generation-Specific Notes

### M1 Series

- **CPU Performance cores**: `Tp01`, `Tp05`, `Tp09`, `Tp0D`, `Tp0H`, `Tp0L`, `Tp0P`, `Tp0X`
- **CPU Efficiency cores**: `Tp0T` (limited)
- **GPU**: `Tg0f`, `Tg0n`
- **ANE**: `TaP0`

### M2 Series

- **CPU Efficiency**: `Tp05`, `Tp0D`, `Tp0j`, `Tp0r`
- **CPU Performance**: `Tp01`, `Tp09`, `Tp0f`, `Tp0n`
- **GPU**: `Tg0f`, `Tg0n`
- **ANE**: `TaP0`
- **Note**: `Tp05` = efficiency core on M2, but performance core on M1 Pro/Max

### M3 Series

- Expanded GPU sensors: `Tg0b`, `Tg0g`
- GPU sensors may power down at low usage (dynamic activation)
- Enhanced ANE: `TaP0`, `TaP1`
- Separate thermal zones for P-core and E-core clusters

### M4/M5 Series

- Enhanced M3 mappings plus:
- Additional ANE: `TaP2`
- Memory controllers: `Tm0P`, `Tm1P`
- Cache sensors: `Tc0P`, `Tc1P`
- Current M5 support reuses M4 mapping paths until model-specific deltas are identified

## Non-Temperature Keys (Inactive)

SMC keys that start with ‘T’ but are NOT live temperature sensors. These are discovered via `readRawValue()` (no sanity filter) and classified as inactive.

### Known Non-Temperature Keys

| Key | Description | Typical Value |
| --- | ----------- | ------------- |
| `TCHP` | CPU Hot Protection Threshold | 0–8°C |
| `TCXC` | CPU Critical Threshold | 0–5°C |
| `TCTD` | CPU Throttle Delta | 0–3°C |
| `TCSA` | CPU System Agent Threshold | 0–8°C |
| `TCGP` | CPU/GPU Package Threshold | 0–8°C |
| `TGVP` | GPU VRAM Protection Threshold | 0–5°C |
| `TMTP` | Memory Thermal Protection | 0–5°C |
| `TDTC` | Die Thermal Cutoff | 0–5°C |
| `TDTP` | Die Thermal Protection | 0–5°C |

### Auto-Classification of Unknown Keys

Keys not in the known dictionary are named by component prefix and value range:

| Value Range | Classification | Unit Label | Example Name |
| ----------- | -------------- | ---------- | ------------ |
| ≤ 0 | Powered Down | `(off)` | "GPU Tg0x (Powered Down)" |
| 0–10 | Threshold/Config | `°C (thr)` | "CPU TC2b (Threshold/Config)" |
| ≥ 150 | Non-Temperature Data | `(raw)` | "SoC Ts0x (Non-Temperature Data)" |

## Key Reuse Warning

The same SMC key can represent different components across generations:

- `Tp05` = M1 Pro/Max **Performance** Core 2 = M2 **Efficiency** Core 1

ExoMacFan uses `SensorDiscovery` with generation-specific mapping tables to handle this. The app detects the chip model via `sysctl` and selects the correct mapping.

## References

- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) — `Ftst` unlock research for M1–M4
- [Stats App](https://github.com/exelban/stats) — Sensor key enumeration and classification
- [Asahi Linux macsmc-hwmon](https://github.com/AsahiLinux/linux) — SMC key schema docs
- [Apple Sensors](https://github.com/freedomtan/sensors) — IOKit sensor access patterns
- [SMCKit](https://github.com/beltex/SMCKit) — SMC communication library

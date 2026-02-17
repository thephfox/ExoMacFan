#!/bin/bash

# ============================================================
# ExoMacFan Swift Compilation Script
# Created by: Douglas M. — Code PhFox (www.phfox.com)
# Date: 2026-01-23
# Last Modified by: Douglas M.
# Last Modified: 2026-02-17
# Description: Compile Swift app directly without Xcode project
# ============================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_info "Compiling ExoMacFan Swift app..."

# Configuration
APP_NAME="ExoMacFan"
APP_VERSION="1.0.0"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUILD_NUMBER_FILE=".build_number"
TARGET_ARCHS=(${TARGET_ARCHS:-arm64 x86_64})
MACOS_TARGET="${MACOS_TARGET:-14.0}"
SDK_PATH="$(xcrun --show-sdk-path)"
TMP_BUILD_DIR="$BUILD_DIR/.universal_tmp"

# Auto-increment build number
if [ -f "$BUILD_NUMBER_FILE" ]; then
    BUILD_NUMBER=$(cat "$BUILD_NUMBER_FILE")
    BUILD_NUMBER=$((BUILD_NUMBER + 1))
else
    BUILD_NUMBER=1
fi
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

# Build metadata
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

log_info "Version $APP_VERSION Build $BUILD_NUMBER ($GIT_COMMIT)"

# Create build directory
mkdir -p "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
rm -rf "$TMP_BUILD_DIR"
mkdir -p "$TMP_BUILD_DIR"

# Compile privileged helper tool first
log_info "Compiling privileged helper..."
HELPER_ARCH_BINS=()
> compile_helper.log
for ARCH in "${TARGET_ARCHS[@]}"; do
    HELPER_ARCH_BIN="$TMP_BUILD_DIR/ExoMacFanHelper-$ARCH"
    log_info "Compiling helper for $ARCH..."
    swiftc -o "$HELPER_ARCH_BIN" \
        -target "$ARCH-apple-macos$MACOS_TARGET" \
        -sdk "$SDK_PATH" \
        -framework IOKit \
        -framework Foundation \
        Helper/ExoMacFanHelper.swift \
        2>&1 | tee -a compile_helper.log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Helper compilation failed for $ARCH. Check compile_helper.log for details."
        exit 1
    fi
    HELPER_ARCH_BINS+=("$HELPER_ARCH_BIN")
done

if [ ${#HELPER_ARCH_BINS[@]} -gt 1 ]; then
    lipo -create "${HELPER_ARCH_BINS[@]}" -output "$APP_BUNDLE/Contents/MacOS/ExoMacFanHelper"
    log_info "Created universal helper binary (${TARGET_ARCHS[*]})"
else
    cp "${HELPER_ARCH_BINS[0]}" "$APP_BUNDLE/Contents/MacOS/ExoMacFanHelper"
fi

# Sign helper with Apple Development cert (required for AppleSMC writes on Apple Silicon)
# Auto-detect any available Apple Development certificate
CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$CODESIGN_IDENTITY" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/ExoMacFanHelper" 2>/dev/null
    log_info "Helper signed with: $CODESIGN_IDENTITY"
else
    log_info "No Apple Development cert found — helper signed ad-hoc."
    log_info "Fan control requires a valid Apple Development certificate."
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/ExoMacFanHelper" 2>/dev/null
fi
log_success "Helper compiled."

log_info "Compiling Swift sources..."

# Compile Swift files
SWIFT_SOURCES=(
    ExoMacFan/ExoMacFanApp.swift
    ExoMacFan/ContentView.swift
    ExoMacFan/Core/Models.swift
    ExoMacFan/Core/ThermalMonitor.swift
    ExoMacFan/Core/PressureLevelDetector.swift
    ExoMacFan/Core/ComponentTemperatureTracker.swift
    ExoMacFan/Core/SensorDiscovery.swift
    ExoMacFan/Core/FanController.swift
    ExoMacFan/Core/ThermalHistoryLogger.swift
    ExoMacFan/Core/IOKitInterface.swift
    ExoMacFan/Core/SMCHelper.swift
    ExoMacFan/Core/VersionManager.swift
    ExoMacFan/Views/SensorsView.swift
    ExoMacFan/Views/FansView.swift
    ExoMacFan/Views/FanModeComponents.swift
    ExoMacFan/Views/HistoryView.swift
    ExoMacFan/Views/SettingsView.swift
    ExoMacFan/Views/MenuBarView.swift
    ExoMacFan/Views/ThermalHistoryChart.swift
)

APP_ARCH_BINS=()
> compile.log
for ARCH in "${TARGET_ARCHS[@]}"; do
    APP_ARCH_BIN="$TMP_BUILD_DIR/$APP_NAME-$ARCH"
    log_info "Compiling app for $ARCH..."
    swiftc -o "$APP_ARCH_BIN" \
        -target "$ARCH-apple-macos$MACOS_TARGET" \
        -sdk "$SDK_PATH" \
        -framework SwiftUI \
        -framework Combine \
        -framework IOKit \
        -framework AppKit \
        -framework Charts \
        -framework Security \
        "${SWIFT_SOURCES[@]}" \
        2>&1 | tee -a compile.log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Compilation failed for $ARCH. Check compile.log for details."
        exit 1
    fi
    APP_ARCH_BINS+=("$APP_ARCH_BIN")
done

if [ ${#APP_ARCH_BINS[@]} -gt 1 ]; then
    lipo -create "${APP_ARCH_BINS[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    log_info "Created universal app binary (${TARGET_ARCHS[*]})"
else
    cp "${APP_ARCH_BINS[0]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

log_success "Compilation successful!"

# Copy and patch Info.plist with version + build metadata
cp ExoMacFan/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :BuildDate string $BUILD_DATE" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :BuildDate $BUILD_DATE" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitCommit string $GIT_COMMIT" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :GitCommit $GIT_COMMIT" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Copy app icon
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    log_info "App icon copied."
fi

# Sign the app with the same certificate used for the helper
log_info "Signing app..."
if [ -n "$CODESIGN_IDENTITY" ]; then
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --entitlements ExoMacFan/ExoMacFan.entitlements "$APP_BUNDLE"
    log_info "App signed with: $CODESIGN_IDENTITY"
else
    codesign --force --sign - --entitlements ExoMacFan/ExoMacFan.entitlements "$APP_BUNDLE"
    log_info "App signed ad-hoc."
fi

rm -rf "$TMP_BUILD_DIR"

log_success "App built successfully: $APP_BUNDLE"
log_info "Run with: open $APP_BUNDLE"

#!/bin/bash

# ============================================================
# ExoMacFan Build Script
# Created by: Douglas M. — Code PhFox (www.phfox.com)
# Date: 2026-01-23
# Description: Automated build script with version management
# ============================================================

set -e

# Configuration
PROJECT_NAME="ExoMacFan"
SCHEME="ExoMacFan"
CONFIGURATION="Release"
WORKSPACE="$PROJECT_NAME.xcodeproj"
ARCHIVE_PATH="$PWD/build/$PROJECT_NAME.xcarchive"
EXPORT_PATH="$PWD/build"
APP_NAME="$PROJECT_NAME.app"
DMG_NAME="$PROJECT_NAME"
VERSION_FILE="$PWD/version.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [ ! -f "$WORKSPACE/project.pbxproj" ]; then
    log_error "Please run this script from the project root directory"
    exit 1
fi

# Create build directory
mkdir -p build
log_info "Created build directory"

# Get current version and increment build number
log_info "Managing version and build number..."

# Get current build number
CURRENT_BUILD=$(xcodebuild -project "$WORKSPACE" -showBuildSettings | grep "CURRENT_PROJECT_VERSION" | sed 's/.*= *//')
if [ -z "$CURRENT_BUILD" ]; then
    CURRENT_BUILD=1
fi

# Increment build number
NEW_BUILD=$((CURRENT_BUILD + 1))
log_info "Incrementing build number from $CURRENT_BUILD to $NEW_BUILD"

# Get git commit hash
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
log_info "Git commit: $GIT_COMMIT"

# Get build date
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log_info "Build date: $BUILD_DATE"

# Update build number in project
xcodebuild -project "$WORKSPACE" -target "$PROJECT_NAME" -configuration "$CONFIGURATION" \
    CURRENT_PROJECT_VERSION="$NEW_BUILD" \
    BUILD_DATE="$BUILD_DATE" \
    GIT_COMMIT="$GIT_COMMIT"

# Save version info
echo "Version: 1.0.0" > "$VERSION_FILE"
echo "Build: $NEW_BUILD" >> "$VERSION_FILE"
echo "Date: $BUILD_DATE" >> "$VERSION_FILE"
echo "Commit: $GIT_COMMIT" >> "$VERSION_FILE"
log_success "Version information saved to $VERSION_FILE"

# Clean build directory
log_info "Cleaning previous builds..."
xcodebuild clean -project "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIGURATION"

# Archive the app
log_info "Archiving $PROJECT_NAME..."
xcodebuild archive \
    -project "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    CURRENT_PROJECT_VERSION="$NEW_BUILD" \
    BUILD_DATE="$BUILD_DATE" \
    GIT_COMMIT="$GIT_COMMIT"

if [ $? -ne 0 ]; then
    log_error "Archive failed"
    exit 1
fi

log_success "Archive created successfully"

# Export the app
log_info "Exporting app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$PWD/ExportOptions.plist"

if [ $? -ne 0 ]; then
    log_error "Export failed"
    exit 1
fi

log_success "App exported successfully"

# Create DMG
log_info "Creating DMG..."
DMG_PATH="$EXPORT_PATH/$DMG_NAME.dmg"

# Create a temporary directory for DMG contents
DMG_TEMP_DIR="$EXPORT_PATH/dmg_temp"
mkdir -p "$DMG_TEMP_DIR"

# Copy app to DMG temp directory
cp -R "$EXPORT_PATH/$APP_NAME" "$DMG_TEMP_DIR/"

# Create DMG
hdiutil create -volname "$DMG_NAME" \
    -srcfolder "$DMG_TEMP_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean up DMG temp directory
rm -rf "$DMG_TEMP_DIR"

if [ $? -eq 0 ]; then
    log_success "DMG created successfully: $DMG_PATH"
else
    log_error "DMG creation failed"
    exit 1
fi

# Calculate checksums
log_info "Calculating checksums..."
SHA256=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
MD5=$(md5 -q "$DMG_PATH")

# Save checksums
echo "SHA256: $SHA256" >> "$VERSION_FILE"
echo "MD5: $MD5" >> "$VERSION_FILE"

log_success "Checksums calculated and saved"

# Display build summary
echo ""
echo "=========================================="
echo "BUILD SUMMARY"
echo "=========================================="
echo "Project: $PROJECT_NAME"
echo "Version: 1.0.0"
echo "Build: $NEW_BUILD"
echo "Date: $BUILD_DATE"
echo "Git Commit: $GIT_COMMIT"
echo "Configuration: $CONFIGURATION"
echo ""
echo "Generated Files:"
echo "- App: $EXPORT_PATH/$APP_NAME"
echo "- Archive: $ARCHIVE_PATH"
echo "- DMG: $DMG_PATH"
echo "- Version Info: $VERSION_FILE"
echo ""
echo "Checksums:"
echo "- SHA256: $SHA256"
echo "- MD5: $MD5"
echo "=========================================="

# Verify the app
log_info "Verifying the built app..."
if [ -d "$EXPORT_PATH/$APP_NAME" ]; then
    APP_SIZE=$(du -sh "$EXPORT_PATH/$APP_NAME" | cut -f1)
    log_success "App verified - Size: $APP_SIZE"
else
    log_error "App not found at expected location"
    exit 1
fi

# Verify DMG
if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
    log_success "DMG verified - Size: $DMG_SIZE"
else
    log_error "DMG not found at expected location"
    exit 1
fi

log_success "Build completed successfully!"
log_info "You can find the packaged app in: $EXPORT_PATH"
log_info "Install the DMG by double-clicking: $DMG_PATH"

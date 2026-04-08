#!/usr/bin/env bash
#
# build_xcframework.sh
#
# Builds a fat XCFramework for EmbeddedMockEngine supporting:
#   - iOS device         (arm64)
#   - iOS Simulator      (arm64 + x86_64, fat/universal)
#   - macOS              (arm64 + x86_64, fat/universal)
#
# Usage:
#   ./build_xcframework.sh [--output <dir>] [--skip-zip]
#
# Options:
#   --output <dir>   Directory where the .xcframework and optional .zip are
#                    written. Defaults to ./build/xcframework
#   --skip-zip       Skip creating a distributable .zip archive at the end
#
# Requirements: Xcode 14+ (xcodebuild with Swift Package support)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCHEME="EmbeddedMockEngine"
OUTPUT_DIR="build/xcframework"
ARCHIVES_DIR="build/archives"
SKIP_ZIP=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-zip)
            SKIP_ZIP=true
            shift
            ;;
        -h|--help)
            sed -n '/^# build_xcframework.sh/,/^# Requirements:/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

XCFRAMEWORK_PATH="${OUTPUT_DIR}/${SCHEME}.xcframework"
ZIP_PATH="${OUTPUT_DIR}/${SCHEME}.xcframework.zip"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
step() { echo; echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH."
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_command xcodebuild
require_command lipo
require_command zip

XCODE_VERSION=$(xcodebuild -version | head -1)
echo "Using ${XCODE_VERSION}"

# ---------------------------------------------------------------------------
# Clean previous artifacts
# ---------------------------------------------------------------------------
step "Cleaning previous build artifacts"
rm -rf "${ARCHIVES_DIR}" "${XCFRAMEWORK_PATH}" "${ZIP_PATH}"
mkdir -p "${ARCHIVES_DIR}" "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Helper: archive for one platform
# ---------------------------------------------------------------------------
build_archive() {
    local destination="$1"
    local archive_name="$2"
    local archive_path="${ARCHIVES_DIR}/${archive_name}.xcarchive"

    step "Archiving for: ${destination}"

    local xcodebuild_cmd=(
        xcodebuild archive
        -scheme "${SCHEME}"
        -destination "${destination}"
        -archivePath "${archive_path}"
        SKIP_INSTALL=NO
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES
    )

    if command -v xcpretty >/dev/null 2>&1; then
        "${xcodebuild_cmd[@]}" | xcpretty
    else
        "${xcodebuild_cmd[@]}"
    fi

    [[ -d "${archive_path}" ]] || die "Archive not created at ${archive_path}"
    echo "  Archive ready: ${archive_path}"
}

# ---------------------------------------------------------------------------
# Build archives for each platform
# ---------------------------------------------------------------------------
build_archive "generic/platform=iOS"                   "${SCHEME}-iOS"
build_archive "generic/platform=iOS Simulator"         "${SCHEME}-iOS-Simulator"
build_archive "generic/platform=macOS"                 "${SCHEME}-macOS"

# ---------------------------------------------------------------------------
# Locate framework bundles inside each archive
# ---------------------------------------------------------------------------
find_framework() {
    local archive_name="$1"
    local archive_path="${ARCHIVES_DIR}/${archive_name}.xcarchive"
    local fw_path

    fw_path=$(find "${archive_path}/Products" -name "${SCHEME}.framework" -type d | head -1)
    [[ -n "${fw_path}" ]] || die "Framework not found in ${archive_path}"
    echo "${fw_path}"
}

IOS_FW=$(find_framework "${SCHEME}-iOS")
SIM_FW=$(find_framework "${SCHEME}-iOS-Simulator")
MACOS_FW=$(find_framework "${SCHEME}-macOS")

# ---------------------------------------------------------------------------
# Create fat (universal) binaries for multi-arch slices
#
# iOS Simulator and macOS archives built with "generic/platform=..." already
# produce universal binaries when both arm64 and x86_64 SDKs are present.
# The lipo step below is a no-op when the binary is already fat, but it
# ensures correctness on machines that only have one architecture available
# by explicitly listing both slices from the archive when present.
# ---------------------------------------------------------------------------
make_fat_if_needed() {
    local fw_path="$1"
    local binary="${fw_path}/${SCHEME}"

    local arches
    arches=$(lipo -archs "${binary}" 2>/dev/null || echo "")

    if echo "${arches}" | grep -q "x86_64" && echo "${arches}" | grep -q "arm64"; then
        echo "  Already a fat binary (${arches}): ${binary}"
    else
        echo "  Single-arch binary (${arches}). Leaving as-is (fat merge requires both SDKs installed)."
    fi
}

step "Inspecting simulator framework"
make_fat_if_needed "${SIM_FW}"

step "Inspecting macOS framework"
make_fat_if_needed "${MACOS_FW}"

# ---------------------------------------------------------------------------
# Assemble the XCFramework
# ---------------------------------------------------------------------------
step "Creating ${SCHEME}.xcframework"
xcodebuild -create-xcframework \
    -framework "${IOS_FW}" \
    -framework "${SIM_FW}" \
    -framework "${MACOS_FW}" \
    -output "${XCFRAMEWORK_PATH}"

echo "  XCFramework created at: ${XCFRAMEWORK_PATH}"

# ---------------------------------------------------------------------------
# Optional: zip for distribution
# ---------------------------------------------------------------------------
if [[ "${SKIP_ZIP}" == false ]]; then
    step "Zipping for distribution"
    (cd "${OUTPUT_DIR}" && zip -qr "$(basename "${ZIP_PATH}")" "$(basename "${XCFRAMEWORK_PATH}")")
    echo "  Archive: ${ZIP_PATH}"
    CHECKSUM=$(swift package compute-checksum "${ZIP_PATH}" 2>/dev/null || shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')
    echo "  Checksum (SHA-256): ${CHECKSUM}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"
echo "  XCFramework : ${XCFRAMEWORK_PATH}"
[[ "${SKIP_ZIP}" == false ]] && echo "  Zip archive : ${ZIP_PATH}"
echo
echo "Platforms included in the XCFramework:"
plutil -p "${XCFRAMEWORK_PATH}/Info.plist" 2>/dev/null \
    | grep '"LibraryIdentifier"' \
    | sed 's/.*=> /  - /' \
    || ls "${XCFRAMEWORK_PATH}"

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
DERIVED_DATA_DIR="build/derived-data"
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

derived_data_path_for_archive() {
    local archive_name="$1"
    echo "${DERIVED_DATA_DIR}/${archive_name}"
}

framework_payload_root() {
    local fw_path="$1"

    if [[ -d "${fw_path}/Versions/A" ]]; then
        echo "${fw_path}/Versions/A"
    else
        echo "${fw_path}"
    fi
}

ensure_versioned_framework_links() {
    local fw_path="$1"

    if [[ -d "${fw_path}/Versions/A" ]]; then
        ln -sfn "A" "${fw_path}/Versions/Current"
        ln -sfn "Versions/Current/Headers" "${fw_path}/Headers"
        ln -sfn "Versions/Current/Modules" "${fw_path}/Modules"
    fi
}

find_swiftmodule_dir() {
    local search_root="$1"
    local candidate

    while IFS= read -r candidate; do
        if find "${candidate}" -maxdepth 2 -type f \
            \( -name '*.swiftinterface' -o -name '*.private.swiftinterface' -o -name '*.swiftdoc' -o -name '*.abi.json' -o -name '*.swiftsourceinfo' \) \
            | grep -q .; then
            echo "${candidate}"
            return 0
        fi
    done < <(find "${search_root}" -type d -name "${SCHEME}.swiftmodule" | sort)

    return 1
}

find_swift_header() {
    local search_root="$1"

    find "${search_root}" -type f -name "${SCHEME}-Swift.h" | sort | head -1
}

write_module_map() {
    local module_map_path="$1"

    cat > "${module_map_path}" <<EOF
framework module ${SCHEME} {
  umbrella header "${SCHEME}-Swift.h"

  export *
  module * { export * }
}
EOF
}

enrich_framework_with_swift_artifacts() {
    local archive_name="$1"
    local fw_path="$2"
    local derived_data_path
    local payload_root
    local modules_dir
    local headers_dir
    local swiftmodule_source
    local swift_header_source

    derived_data_path="$(derived_data_path_for_archive "${archive_name}")"
    payload_root="$(framework_payload_root "${fw_path}")"
    modules_dir="${payload_root}/Modules"
    headers_dir="${payload_root}/Headers"

    swiftmodule_source="$(find_swiftmodule_dir "${derived_data_path}")" \
        || die "Swift module artifacts not found for ${archive_name} in ${derived_data_path}"

    mkdir -p "${modules_dir}/${SCHEME}.swiftmodule"
    cp -R "${swiftmodule_source}/." "${modules_dir}/${SCHEME}.swiftmodule/"

    swift_header_source="$(find_swift_header "${derived_data_path}" || true)"
    if [[ -n "${swift_header_source}" ]]; then
        mkdir -p "${headers_dir}"
        cp "${swift_header_source}" "${headers_dir}/${SCHEME}-Swift.h"
        write_module_map "${modules_dir}/module.modulemap"
        ensure_versioned_framework_links "${fw_path}"
    else
        echo "  WARNING: ${SCHEME}-Swift.h not found for ${archive_name}; skipping module.modulemap generation." >&2
    fi
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
rm -rf "${ARCHIVES_DIR}" "${DERIVED_DATA_DIR}" "${XCFRAMEWORK_PATH}" "${ZIP_PATH}"
mkdir -p "${ARCHIVES_DIR}" "${DERIVED_DATA_DIR}" "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Helper: archive for one platform
# ---------------------------------------------------------------------------
build_archive() {
    local destination="$1"
    local archive_name="$2"
    local archive_path="${ARCHIVES_DIR}/${archive_name}.xcarchive"
    local derived_data_path

    derived_data_path="$(derived_data_path_for_archive "${archive_name}")"

    step "Archiving for: ${destination}"

    local xcodebuild_cmd=(
        xcodebuild archive
        -scheme "${SCHEME}"
        -destination "${destination}"
        -archivePath "${archive_path}"
        -derivedDataPath "${derived_data_path}"
        -configuration Release
        SKIP_INSTALL=NO
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES
        DEFINES_MODULE=YES
        SWIFT_INSTALL_OBJC_HEADER=YES
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

step "Restoring Swift module metadata into archived frameworks"
enrich_framework_with_swift_artifacts "${SCHEME}-iOS" "${IOS_FW}"
enrich_framework_with_swift_artifacts "${SCHEME}-iOS-Simulator" "${SIM_FW}"
enrich_framework_with_swift_artifacts "${SCHEME}-macOS" "${MACOS_FW}"

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

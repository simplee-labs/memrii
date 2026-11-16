#!/usr/bin/env bash
# Usage: ./package_firmware.sh [output_name] [input_zip]
# Copies the build's DFU zip to <output_name>.zip in the same directory and makes
# sure it carries exactly one version.txt, equal to CONFIG_BT_DIS_FW_REV_STR in
# omi.conf. The build already stamps version.txt; this checks that stamp rather
# than appending a second one, and fails if the zip was built from another version.
#
# Defaults:
#   input_zip   build/omi/dfu_application.zip (the build directory BUILD_AND_OTA_FLASH.md uses)
#   output_name dfu_application_release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/omi.conf"

OUTPUT_NAME="${1:-dfu_application_release}"
BUILD_ZIP="${2:-$SCRIPT_DIR/build/omi/dfu_application.zip}"

if [[ ! -f "$BUILD_ZIP" ]]; then
  echo "Error: $BUILD_ZIP not found. Build the firmware first (or pass the zip path as \$2)." >&2
  exit 1
fi

# Only the active setting line, never a commented-out one; tolerate a CRLF checkout.
VERSION=$(tr -d '\r' < "$CONF" | sed -n 's/^CONFIG_BT_DIS_FW_REV_STR="\(.*\)"$/\1/p')
if [[ -z "$VERSION" ]]; then
  echo "Error: Could not read CONFIG_BT_DIS_FW_REV_STR from $CONF" >&2
  exit 1
fi
if [[ "$VERSION" == *$'\n'* ]]; then
  echo "Error: $CONF sets CONFIG_BT_DIS_FW_REV_STR more than once" >&2
  exit 1
fi

OUTPUT_ZIP="$(cd "$(dirname "$BUILD_ZIP")" && pwd)/${OUTPUT_NAME}.zip"
if [[ "$OUTPUT_ZIP" -ef "$BUILD_ZIP" ]]; then
  echo "Error: output name '$OUTPUT_NAME' would overwrite the input zip" >&2
  exit 1
fi

cp "$BUILD_ZIP" "$OUTPUT_ZIP"
if ! python3 "$SCRIPT_DIR/scripts/add_version_to_zip.py" "$OUTPUT_ZIP" "$VERSION"; then
  rm -f "$OUTPUT_ZIP"
  exit 1
fi
echo "Packaged: $OUTPUT_ZIP (version: $VERSION)"

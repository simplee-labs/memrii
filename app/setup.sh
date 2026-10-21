#!/bin/bash
#
# Set up the memrii app (Android).
#
# Prerequisites (stable versions, use these or higher):
#
# Common for all developers:
# - Flutter SDK (v3.41.7)
# - Opus Codec: https://opus-codec.org
#
# For Android Developers:
# - Android Studio (Iguana | 2024.3)
# - Android SDK Platform (API 36)
# - JDK (v21)
# - Gradle (v8.10)
# - NDK (28.2.13676358)
#
# Usages:
# - $bash setup.sh android
#
# iOS is unsupported. Restoring it requires the handwritten native platform code,
# signing configuration and all iOS code generators together.

set -euo pipefail

echo "Setting up the memrii app (Android)."
echo "Prerequisites (stable versions, use these or higher):"
echo ""
echo "Common for all developers:"
echo "- Flutter SDK (v3.41.7)"
echo "- Opus Codec: https://opus-codec.org"
echo ""
echo "For Android Developers:"
echo "- Android Studio (Iguana | 2024.3)"
echo "- Android SDK Platform (API 36)"
echo "- JDK (v21)"
echo "- Gradle (v8.10)"
echo "- NDK (28.2.13676358)"
echo ""
echo "Usages:"
echo "- bash setup.sh android"
echo ""


# #####
# Build
# #####
function run_build_android() {
  echo "🚀 Building and running Android (dev flavor)..."
  flutter pub get \
    && dart run build_runner build --delete-conflicting-outputs \
    && flutter run --flavor dev
}

case "${1}" in
  android)
    run_build_android
    ;;
  *)
    echo "Error: unexpected platform '${1}'. Only 'android' is supported (iOS support was removed)." >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "📦 Ensuring dependencies and generated files are up to date..."
flutter pub get
dart run build_runner build --delete-conflicting-outputs

echo "🧪 Running unit tests..."
flutter test test/unit/

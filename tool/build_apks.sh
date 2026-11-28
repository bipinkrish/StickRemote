#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build apk --release --split-per-abi "$@"
mkdir -p build/releases
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "build/app/outputs/flutter-apk/app-${abi}-release.apk" "build/releases/StickRemote-${abi}.apk"
done

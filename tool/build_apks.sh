#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build apk --release --split-per-abi "$@"
version=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["elements"][0]["versionName"])' < build/app/outputs/apk/release/output-metadata.json)
release_dir="build/releases/$version"
mkdir -p "$release_dir"
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "build/app/outputs/flutter-apk/app-${abi}-release.apk" "$release_dir/StickRemote-${version}-${abi}.apk"
done
echo "Release APKs are in $release_dir/"

#!/usr/bin/env bash
# Verifies that an OpenClaw .xcarchive (or .app/.ipa payload) embeds only the
# App Store-safe device build of TailscaleKit: arm64, platform IOS, no simulator
# slices or load commands.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <OpenClaw.xcarchive|OpenClaw.app>" >&2
  exit 2
fi

input="$1"
if [[ -d "$input/Products/Applications" ]]; then
  app="$(find "$input/Products/Applications" -maxdepth 1 -name "*.app" -print -quit)"
else
  app="$input"
fi
binary="$app/Frameworks/TailscaleKit.framework/TailscaleKit"
if [[ ! -f "$binary" ]]; then
  echo "verify: TailscaleKit.framework not embedded in $app" >&2
  exit 1
fi

archs="$(lipo -archs "$binary")"
platforms="$(vtool -show-build "$binary" | awk '/platform/ {print $2}' | sort -u | tr '\n' ' ')"
echo "verify: $binary"
echo "verify: archs=$archs platforms=$platforms"
if [[ "$archs" != "arm64" ]]; then
  echo "verify: expected arm64 only" >&2
  exit 1
fi
if [[ "$platforms" != "IOS " ]]; then
  echo "verify: expected platform IOS only (found: $platforms)" >&2
  exit 1
fi
echo "verify: OK (device-only TailscaleKit)"

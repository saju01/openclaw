#!/usr/bin/env bash
# Builds the pinned TailscaleKit (libtailscale tsnet) xcframework used by the
# embedded tailnet transport. Output is git-ignored under apps/ios/build/.
#
# The xcframework carries one iphoneos slice (arm64, device-only) and one
# iphonesimulator slice (arm64 + x86_64). Xcode embeds only the slice matching
# the destination SDK, so Release/App Store archives never contain simulator
# code; verify with scripts/tailscalekit-verify-archive.sh after archiving.
set -euo pipefail

readonly LIBTAILSCALE_REPO="https://github.com/tailscale/libtailscale.git"
# Pinned exact commit. Bump deliberately and re-audit Resources/Licenses.
readonly LIBTAILSCALE_COMMIT="59d4bb82744915815178e0f0776d60026a397ee7"
# Keep aligned with project.yml options.deploymentTarget.iOS.
readonly IOS_DEPLOYMENT_TARGET="18.0"
# libtailscale's go.mod pins go 1.25.5. Newer host toolchains (Go 1.27) break its
# go-json-experiment dependency, so always build with the exact pinned toolchain.
export GOTOOLCHAIN="go1.25.5"
# ts_omit_logtail compiles out tsnet's upload of diagnostic logs to
# log.tailscale.com. iOS cannot set TS_NO_LOGS_NO_SUPPORT early enough for the
# Go runtime to observe it, so the build tag is the only reliable opt-out.
readonly GO_TAGS="ios,ts_omit_logtail"
# Bump when build inputs other than the commit change so stale outputs rebuild.
readonly BUILD_RECIPE="2"

ios_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_dir="$ios_root/build/vendor/libtailscale"
out_dir="$ios_root/build/TailscaleKit"
xcframework="$out_dir/TailscaleKit.xcframework"
stamp="$out_dir/.commit"
readonly stamp_value="$LIBTAILSCALE_COMMIT recipe=$BUILD_RECIPE tags=$GO_TAGS"

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

if [[ -d "$xcframework" && -f "$stamp" && "$(cat "$stamp")" == "$stamp_value" ]]; then
  echo "tailscalekit: up to date ($stamp_value)"
  exit 0
fi
if [[ "${1:-}" == "--check" ]]; then
  echo "error: TailscaleKit.xcframework missing or stale; run apps/ios/scripts/tailscalekit-build.sh" >&2
  exit 1
fi
# Never inherit an enclosing Xcode build's SDK/arch settings.
unset SDKROOT ARCHS PLATFORM_NAME EFFECTIVE_PLATFORM_NAME IPHONEOS_DEPLOYMENT_TARGET TARGET_BUILD_DIR BUILT_PRODUCTS_DIR CONFIGURATION

if ! command -v go >/dev/null 2>&1; then
  echo "tailscalekit: Go is required to build libtailscale (brew install go)" >&2
  exit 1
fi

if [[ ! -d "$vendor_dir/.git" ]]; then
  mkdir -p "$(dirname "$vendor_dir")"
  git clone --quiet "$LIBTAILSCALE_REPO" "$vendor_dir"
fi
if ! git -C "$vendor_dir" cat-file -e "$LIBTAILSCALE_COMMIT^{commit}" 2>/dev/null; then
  git -C "$vendor_dir" fetch --quiet origin
fi
git -C "$vendor_dir" -c advice.detachedHead=false checkout --quiet --force "$LIBTAILSCALE_COMMIT"
test "$(git -C "$vendor_dir" rev-parse HEAD)" == "$LIBTAILSCALE_COMMIT"

cd "$vendor_dir"
rm -f libtailscale_ios*.a libtailscale_ios*.h

build_archive() {
  local clang_wrapper="$1" goarch="$2" output="$3"
  GOOS=ios GOARCH="$goarch" CGO_ENABLED=1 CC="$vendor_dir/swift/script/$clang_wrapper" \
    go build -trimpath -ldflags=-w -tags "$GO_TAGS" -buildmode=c-archive -o "$output" .
}

# Device archive: arm64 iphoneos only (App Store safe).
build_archive clangwrap-ios.sh arm64 libtailscale_ios.a
# Simulator archive: the TailscaleKit project links libtailscale_ios_sim.a.
build_archive clangwrap-ios-sim-arm.sh arm64 libtailscale_ios_sim_arm64.a
build_archive clangwrap-ios-sim-x86.sh amd64 libtailscale_ios_sim_x86_64.a
lipo -create -output libtailscale_ios_sim.a libtailscale_ios_sim_arm64.a libtailscale_ios_sim_x86_64.a

derived="$vendor_dir/swift/build"
rm -rf "$derived"
cd "$vendor_dir/swift"
common_settings=(
  -derivedDataPath "$derived"
  -configuration Release
  CODE_SIGNING_ALLOWED=NO
  IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
  ONLY_ACTIVE_ARCH=NO
)
xcodebuild build -quiet -scheme "TailscaleKit (iOS)" -destination "generic/platform=iOS" \
  "${common_settings[@]}" ARCHS=arm64
xcodebuild build -quiet -scheme "TailscaleKit (Simulator)" -destination "generic/platform=iOS Simulator" \
  "${common_settings[@]}" ARCHS="arm64 x86_64"

rm -rf "$out_dir"
mkdir -p "$out_dir"
xcodebuild -create-xcframework \
  -framework "$derived/Build/Products/Release-iphoneos/TailscaleKit.framework" \
  -framework "$derived/Build/Products/Release-iphonesimulator/TailscaleKit.framework" \
  -output "$xcframework"

device_binary="$xcframework/ios-arm64/TailscaleKit.framework/TailscaleKit"
if [[ "$(lipo -archs "$device_binary")" != "arm64" ]] ||
  ! vtool -show-build "$device_binary" | grep -q "platform IOS$"; then
  echo "tailscalekit: device slice is not a pure iphoneos arm64 binary" >&2
  exit 1
fi
sim_binary="$(find "$xcframework" -path "*simulator/TailscaleKit.framework/TailscaleKit" -print -quit)"
if [[ -z "$sim_binary" ]] || ! vtool -show-build "$sim_binary" | grep -q "platform IOSSIMULATOR$"; then
  echo "tailscalekit: simulator slice missing" >&2
  exit 1
fi
echo "$stamp_value" >"$stamp"
echo "tailscalekit: built $xcframework ($stamp_value)"

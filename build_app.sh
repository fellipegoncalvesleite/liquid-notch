#!/bin/zsh
# Builds dist/Liquid Notch.app from the SwiftPM target and ad-hoc signs it.
#   ./build_app.sh            release build
#   CONFIG=debug ./build_app.sh
#   LN_SIGN_IDENTITY="Developer ID Application: …" ./build_app.sh   (hardened runtime)
#   LN_ADHOC=1 ./build_app.sh                (ad-hoc, for public release zips)
set -euo pipefail
cd "$(dirname "$0")"
CONFIG=${CONFIG:-release}

# Release builds are universal (Apple silicon + Intel); debug builds only this Mac's architecture, for speed.
ARCH_FLAGS=()
[[ $CONFIG == release ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/LiquidNotch

APP="dist/Liquid Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiquidNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Compiled at launch by LiquidRenderer (no Metal Toolchain needed to build).
cp Sources/LiquidNotch/Render/LiquidShape.metal "$APP/Contents/Resources/"
# The app icon (drawn by tools/make_icon.swift).
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The AirPods buds for the AirPods activity: the 3D model (AirPods 4 by Falah3D, CC BY 4.0) and AirPane's studio
# light (Poly Haven, CC0) for BudsStage, and the 2D cutout that stands in until the model has loaded.
cp Resources/airpods-4.usdz Resources/studio.hdr Resources/airpods-buds.png "$APP/Contents/Resources/"
# Now Playing: the mediaremote-adapter framework (built by tools/build_adapter.sh) runs in perl.
# Without it the app falls back to Music's and Spotify's notifications.
ADAPTER=.build/adapter/MediaRemoteAdapter.framework
if [[ -d $ADAPTER ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R $ADAPTER "$APP/Contents/Frameworks/"
  cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
else
  echo "note: no Now Playing adapter (run tools/build_adapter.sh); using the notification fallback"
fi
# Updates (1.1): Sparkle's framework (universal), symlinks kept.
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
[[ -d $SPARKLE ]] || swift package resolve
mkdir -p "$APP/Contents/Frameworks"
ditto $SPARKLE "$APP/Contents/Frameworks/Sparkle.framework"

# Signing. An ad-hoc signature changes with every build, so macOS treats each build as a new app
# and forgets the permissions given to the last one; a real identity keeps them. LN_SIGN_IDENTITY
# wins (Developer ID: hardened runtime + timestamp); else a local "Apple Development" identity is
# used if there is one; else ad-hoc.
ENT=Resources/LiquidNotch.entitlements
# Sparkle's helpers are signed one by one, innermost first, the way Sparkle's docs ask (never --deep), then each
# framework. Takes the codesign flags of the branch below.
sign_frameworks() {
  local S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force "$@" "$S/XPCServices/Installer.xpc"
  codesign --force "$@" --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
  codesign --force "$@" "$S/Autoupdate"
  codesign --force "$@" "$S/Updater.app"
  codesign --force "$@" "$APP"/Contents/Frameworks/*
}
DEV_ID=$(security find-identity -p codesigning -v 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
if [[ -n "${LN_ADHOC:-}" ]]; then
  # Public release builds: ad-hoc, so no personal certificate (name, team ID) ships inside the app.
  sign_frameworks --sign -
  codesign --force --sign - "$APP"
elif [[ -n "${LN_SIGN_IDENTITY:-}" ]]; then
  sign_frameworks --options runtime --timestamp --sign "$LN_SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --entitlements $ENT --sign "$LN_SIGN_IDENTITY" "$APP"
elif [[ -n "$DEV_ID" ]]; then
  sign_frameworks --options runtime --sign "$DEV_ID"
  codesign --force --options runtime --entitlements $ENT --sign "$DEV_ID" "$APP"
else
  sign_frameworks --sign -
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

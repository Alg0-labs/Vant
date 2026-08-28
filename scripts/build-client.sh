#!/usr/bin/env bash
# Builds the Swift client and assembles it into a proper Vant.app
# bundle (Contents/MacOS + Info.plist + entitlements), then ad-hoc
# codesigns it. A real .app bundle — not the bare `swift build` binary — is
# required for LSUIElement, the bundle identifier, and TCC (microphone /
# Accessibility) prompts to behave correctly.
#
# Note on code signing: ad-hoc signing (-s -) is fine for local development,
# but macOS ties TCC (Accessibility/microphone) grants to the binary's path
# + code signature. Every rebuild re-signs with a fresh ad-hoc signature,
# which can invalidate a previously granted Accessibility toggle — see
# PLAN.md §3. Sign with a stable Apple Development certificate
# (CODESIGN_IDENTITY=<your identity> ./scripts/build-client.sh) to keep the
# grant sticky across rebuilds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/client/Vant"
APP_NAME="Vant"
CONFIGURATION="release"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" # "-" = ad-hoc

cd "$CLIENT_DIR"
echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
APP_BUNDLE="$CLIENT_DIR/$APP_NAME.app"

echo "Assembling $APP_BUNDLE …"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$CLIENT_DIR/$APP_NAME/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Code signing (identity: $CODESIGN_IDENTITY)…"
codesign --force --options runtime \
  --entitlements "$CLIENT_DIR/$APP_NAME/$APP_NAME.entitlements" \
  --sign "$CODESIGN_IDENTITY" \
  "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Launch with: open \"$APP_BUNDLE\""

#!/usr/bin/env bash
# Build HyperWhisper macOS from source for local development.
#
# The committed project is pinned to the release provisioning profile, so a plain
# `xcodebuild` (or Cmd+R in Xcode) fails with:
#   "Signing for hyperwhisper requires a development team."
#
# This script supplies local signing settings on the command line and leaves the
# checked-in project untouched, so it keeps working across upstream changes.
#
# See dev-docs/building-from-source.md for the full explanation.
#
# Usage:
#   ./scripts/build-local.sh            # build
#   ./scripts/build-local.sh --run      # build, then launch
#   ./scripts/build-local.sh --clean    # clean build (after deleting/renaming files)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$PROJECT_DIR/hyperwhisper/hyperwhisper-local.entitlements"

DO_RUN=0
BUILD_ACTION="build"
for arg in "$@"; do
    case "$arg" in
        --run)   DO_RUN=1 ;;
        --clean) BUILD_ACTION="clean build" ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

[ -f "$ENTITLEMENTS" ] || { echo "ERROR: missing entitlements file: $ENTITLEMENTS" >&2; exit 1; }

# Prefer a real "Apple Development" certificate over ad-hoc signing.
#
# This matters beyond signing: macOS TCC ties a permission grant to the app's
# code identity. With a certificate that identity is (bundle id + certificate),
# which is stable across rebuilds, so Accessibility and Microphone grants
# survive. Ad-hoc signing derives identity from the binary hash, so every
# rebuild silently revokes the grants and the app appears to lose permissions
# even though Settings still shows it enabled.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Apple Development' | head -1 | sed 's/.*"\(.*\)"/\1/')"

if [ -z "$IDENTITY" ]; then
    echo "ERROR: no 'Apple Development' codesigning identity found." >&2
    echo "       Create one in Xcode > Settings > Accounts > Manage Certificates > +" >&2
    echo "       A free Apple ID is sufficient." >&2
    exit 1
fi

# The team id is the certificate's OU field. It is NOT the value shown in
# parentheses in the certificate name — that is the local certificate
# identifier, and using it fails with "No certificate for team ... found".
CERT_CN="${IDENTITY%% (*}"
TEAM_ID="$(security find-certificate -c "$CERT_CN" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | tr ',/' '\n\n' | sed -n 's/^ *OU=//p' | head -1)"

[ -n "$TEAM_ID" ] || { echo "ERROR: could not read team id (OU) from certificate: $CERT_CN" >&2; exit 1; }

echo "identity : $IDENTITY"
echo "team     : $TEAM_ID"
echo "action   : $BUILD_ACTION"
echo

cd "$PROJECT_DIR"
# shellcheck disable=SC2086
xcodebuild -project hyperwhisper.xcodeproj -scheme hyperwhisper -configuration Debug \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
    $BUILD_ACTION 2>&1 | tail -25

# Resolve the built app by matching WorkspacePath rather than taking the newest
# bundle by mtime, which picks the wrong DerivedData directory when several
# checkouts of the project exist.
APP=""
for d in "$HOME/Library/Developer/Xcode/DerivedData/hyperwhisper-"*; do
    wp="$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null || true)"
    if [ "$wp" = "$PROJECT_DIR/hyperwhisper.xcodeproj" ]; then
        APP="$d/Build/Products/Debug/HyperWhisper.app"
        break
    fi
done

[ -n "$APP" ] && [ -d "$APP" ] || { echo "ERROR: built app not found for $PROJECT_DIR" >&2; exit 1; }

echo
echo "app      : $APP"
echo "built    : $(stat -f '%Sm' "$APP/Contents/MacOS/HyperWhisper")"
codesign -dv "$APP" 2>&1 | grep -E 'Signature|TeamIdentifier' | sed 's/^/signing  : /'

if [ "$DO_RUN" -eq 1 ]; then
    pkill -f "DerivedData.*HyperWhisper" 2>/dev/null || true
    sleep 1
    open "$APP"
    echo "launched."
fi

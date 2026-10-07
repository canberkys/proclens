#!/usr/bin/env bash
# ProcLens release packaging: xcodegen -> xcodebuild (Release, universal)
# -> codesign (nested code inside-out, hardened runtime, timestamp)
# -> notarize (keychain profile) -> staple -> Gatekeeper check
# -> DMG (drag-to-Applications layout) -> sign + notarize + staple the DMG.
#
# Usage:
#   scripts/release.sh                  full release
#   scripts/release.sh --skip-notarize  sign + DMG only, no Apple submission
#   scripts/release.sh --dry-run        resolve version/identity/paths, print plan, change nothing
#
# Environment (no secrets are stored in this file):
#   VERSION         override the version (default: exact git tag at HEAD, else project.yml)
#   SIGN_IDENTITY   full "Developer ID Application: Name (TEAMID)" or SHA-1 hash
#                   (default: first Developer ID Application identity in the keychain)
#   TEAM_ID         override the team id (default: parsed from SIGN_IDENTITY's parentheses)
#   NOTARY_PROFILE  notarytool keychain profile (default: proclens-notary)
#
# Helper signing (Phase 2+): if the bundle contains a privileged helper
# (Contents/MacOS/ProcLensHelper or Contents/Library/LaunchServices/*), it is
# signed before the outer app. If ProcLensHelper/Requirement.txt exists, every
# TEAMID_PLACEHOLDER token in the built bundle's plists is replaced with the
# team id BEFORE signing (so the signature covers the final text). The
# rendered requirement is also written to build/release/Requirement.resolved.txt.

set -euo pipefail

APP_NAME="ProcLens"
SCHEME="ProcLens"
BUNDLE_ID="com.canberkki.ProcLens"
DEFAULT_NOTARY_PROFILE="proclens-notary"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/ProcLens.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
RELEASE_DIR="$ROOT_DIR/build/release"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
STAGING_DIR="$RELEASE_DIR/dmg-staging"
NOTARIZE_ZIP="$RELEASE_DIR/$APP_NAME-notarize.zip"
DMG_TEMP="$RELEASE_DIR/$APP_NAME-temp.dmg"

SKIP_NOTARIZE=0
DRY_RUN=0

# ---------- logging ----------
if [ -t 1 ]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi
step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s    ok:%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s    warn:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) die "unknown argument: $arg (see --help)" ;;
    esac
done

# ---------- retry wrapper (Apple's timestamp and notary servers are flaky) ----------
retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        warn "attempt $attempt failed: $1 ..., retrying in 3s"
        sleep 3
    done
    return 1
}

# ---------- 1. version ----------
step "Resolving version"
if [ -n "${VERSION:-}" ]; then
    ok "VERSION from environment: $VERSION"
else
    PROJECT_VERSION="$(grep -E '^[[:space:]]*MARKETING_VERSION:' "$ROOT_DIR/project.yml" | head -1 \
        | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')"
    [ -n "$PROJECT_VERSION" ] || die "could not read MARKETING_VERSION from project.yml"
    TAG_VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
    if [ -n "$TAG_VERSION" ]; then
        VERSION="$TAG_VERSION"
        ok "VERSION from git tag at HEAD: $VERSION"
        if [ "$TAG_VERSION" != "$PROJECT_VERSION" ]; then
            warn "project.yml MARKETING_VERSION is $PROJECT_VERSION; using tag $TAG_VERSION (build setting overridden)"
        fi
    else
        VERSION="$PROJECT_VERSION"
        ok "VERSION from project.yml: $VERSION"
    fi
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "version '$VERSION' is not numeric dotted (x.y.z)"

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
SHA_PATH="$DMG_PATH.sha256"

if [ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]; then
    warn "working tree has uncommitted changes; the release build will include them"
fi

# ---------- 2. signing identity ----------
step "Resolving signing identity"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
    MSG="no 'Developer ID Application' identity found in the keychain.
    Set one up: download the Developer ID Application certificate from developer.apple.com
    (Certificates, Identifiers & Profiles), double-click to install it, then confirm with:
        security find-identity -v -p codesigning
    Or point at an identity explicitly:  SIGN_IDENTITY=\"Developer ID Application: Name (TEAMID)\" scripts/release.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "$MSG"
        SIGN_IDENTITY="<unresolved>"
    else
        die "$MSG"
    fi
else
    ok "identity: $SIGN_IDENTITY"
fi

if [ -z "${TEAM_ID:-}" ]; then
    TEAM_ID="$(printf '%s' "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)[^()]*$/\1/p')"
fi
if [ -z "${TEAM_ID:-}" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        TEAM_ID="<unresolved>"
        warn "could not derive TEAM_ID from identity; set TEAM_ID=XXXXXXXXXX"
    else
        die "could not derive TEAM_ID from identity; set TEAM_ID=XXXXXXXXXX explicitly"
    fi
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-$DEFAULT_NOTARY_PROFILE}"
ok "team id: $TEAM_ID, notary profile: $NOTARY_PROFILE"

# ---------- plan ----------
step "Plan"
cat <<EOF
    project        $PROJECT_FILE
    scheme         $SCHEME ($BUNDLE_ID)
    version        $VERSION
    app bundle     $APP_BUNDLE
    release dir    $RELEASE_DIR
    dmg            $DMG_PATH
    notarize       $([ "$SKIP_NOTARIZE" -eq 1 ] && echo "skipped (--skip-notarize)" || echo "yes, profile $NOTARY_PROFILE")
EOF

if [ "$DRY_RUN" -eq 1 ]; then
    step "Dry run: no commands that build, sign or submit were executed"
    for tool in xcodegen xcodebuild codesign ditto xcrun hdiutil spctl shasum; do
        if command -v "$tool" >/dev/null 2>&1 || [ -x "/usr/bin/$tool" ]; then
            ok "tool present: $tool"
        else
            warn "tool missing: $tool"
        fi
    done
    exit 0
fi

# ---------- preflight ----------
[ -d "$PROJECT_FILE" ] || step "ProcLens.xcodeproj not present yet; xcodegen will create it"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        die "notarytool keychain profile '$NOTARY_PROFILE' is missing or invalid.
    Store it once (you type the password yourself; it goes to the keychain, not the repo):
        xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <apple-id> --team-id $TEAM_ID
    Or run with --skip-notarize to build an unnotarized DMG."
    fi
fi
mkdir -p "$RELEASE_DIR"

# ---------- 3. generate + build ----------
step "Generating Xcode project"
(cd "$ROOT_DIR" && xcodegen generate)

step "Building Release (universal arm64 + x86_64)"
rm -rf "$DERIVED_DATA"
xcodebuild -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    build
[ -d "$APP_BUNDLE" ] || die "build did not produce $APP_BUNDLE"
ok "built $APP_BUNDLE"

# ---------- 3b. helper: placeholder substitution, then nested signing ----------
step "Checking for privileged helper"
HELPER_BIN="$APP_BUNDLE/Contents/MacOS/ProcLensHelper"
HELPER_LS_DIR="$APP_BUNDLE/Contents/Library/LaunchServices"
REQ_TEMPLATE="$ROOT_DIR/ProcLensHelper/Requirement.txt"

HELPER_ITEMS=()
[ -f "$HELPER_BIN" ] && HELPER_ITEMS+=("$HELPER_BIN")
if [ -d "$HELPER_LS_DIR" ]; then
    while IFS= read -r -d '' f; do HELPER_ITEMS+=("$f"); done \
        < <(find "$HELPER_LS_DIR" -mindepth 1 -maxdepth 1 -type f -print0)
fi

if [ "${#HELPER_ITEMS[@]}" -eq 0 ]; then
    ok "no helper in bundle (nothing to sign separately)"
else
    if [ -f "$REQ_TEMPLATE" ]; then
        mkdir -p "$RELEASE_DIR"
        sed "s/TEAMID_PLACEHOLDER/$TEAM_ID/g" "$REQ_TEMPLATE" > "$RELEASE_DIR/Requirement.resolved.txt"
        ok "rendered requirement -> $RELEASE_DIR/Requirement.resolved.txt"
        # Replace the placeholder in the built bundle's plists (SMAuthorizedClients
        # etc.) so the outer signature covers the final text.
        # Xcode writes Info.plists in binary form, so convert a temp XML copy
        # first to check for the token, then rewrite the real file as XML.
        PLIST_TMP="$RELEASE_DIR/plist-check.xml"
        while IFS= read -r -d '' plist; do
            if plutil -convert xml1 -o "$PLIST_TMP" "$plist" 2>/dev/null \
                && grep -q 'TEAMID_PLACEHOLDER' "$PLIST_TMP"; then
                sed -i '' "s/TEAMID_PLACEHOLDER/$TEAM_ID/g" "$PLIST_TMP"
                cp "$PLIST_TMP" "$plist"
                ok "substituted TEAMID_PLACEHOLDER in ${plist#"$APP_BUNDLE/"}"
            fi
        done < <(find "$APP_BUNDLE" -name '*.plist' -print0)
        rm -f "$PLIST_TMP"
        if grep -rq 'TEAMID_PLACEHOLDER' "$APP_BUNDLE" 2>/dev/null; then
            die "TEAMID_PLACEHOLDER still present in the bundle after substitution"
        fi
    else
        ok "no ProcLensHelper/Requirement.txt; placeholder substitution skipped"
    fi
    for item in "${HELPER_ITEMS[@]}"; do
        step "Signing helper: ${item#"$APP_BUNDLE/"}"
        retry codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item" \
            || die "codesign failed for $item after 3 attempts"
    done
fi

# ---------- 4. sign outer app, verify ----------
step "Signing app bundle"
retry codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE" \
    || die "codesign failed for $APP_BUNDLE after 3 attempts"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
ok "signature valid"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "Notarizing app (this can take a few minutes)"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
    notarize_with_retry() {
        local rc=0 attempt
        for attempt in 1 2 3; do
            rc=0; notarize "$1" || rc=$?
            [ "$rc" -ne 1 ] && return "$rc"
            warn "notarytool returned no verdict (attempt $attempt), retrying in 5s" >&2
            sleep 5
        done
        return "$rc"
    }
    # Not retried blindly on "Invalid": a rejected submission will not pass on retry.
    notarize() {
        local out
        out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
        printf '%s\n' "$out"
        if printf '%s' "$out" | grep -q 'status: Accepted'; then
            return 0
        fi
        if printf '%s' "$out" | grep -q 'status: Invalid'; then
            local id
            id="$(printf '%s' "$out" | sed -nE 's/^[[:space:]]*id: ([0-9a-f-]+).*/\1/p' | head -1)"
            [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
            return 2
        fi
        return 1
    }
    notarize_with_retry "$NOTARIZE_ZIP" || die "app notarization failed; see the log above"
    rm -f "$NOTARIZE_ZIP"
    ok "app notarized"

    step "Stapling app"
    retry xcrun stapler staple "$APP_BUNDLE" || die "stapler failed for app"
    xcrun stapler validate "$APP_BUNDLE" >/dev/null
fi

step "Gatekeeper check (app)"
spctl -a -vvv --type exec "$APP_BUNDLE" \
    || { [ "$SKIP_NOTARIZE" -eq 1 ] && warn "spctl rejects unnotarized app (expected with --skip-notarize)" || die "Gatekeeper rejected the app"; }

# ---------- 5. DMG ----------
step "Building DMG"
rm -rf "$STAGING_DIR" "$DMG_TEMP" "$DMG_PATH" "$SHA_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

if [ -e "/Volumes/$APP_NAME" ]; then
    die "/Volumes/$APP_NAME is already mounted; eject it (hdiutil detach) and re-run"
fi

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -fs HFS+ -format UDRW -ov "$DMG_TEMP" >/dev/null
hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen >/dev/null
MOUNT_POINT="/Volumes/$APP_NAME"

# Finder needs the volume at its default /Volumes path to script it as a disk.
osascript <<OSA || warn "Finder layout script failed; the DMG will work but the window layout will be default"
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 740, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "$APP_NAME.app" of container window to {150, 170}
        set position of item "Applications" of container window to {390, 170}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
OSA

sync
detached=0
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then detached=1; break; fi
    sleep 2
done
if [ "$detached" -eq 0 ]; then
    warn "normal detach failed; forcing"
    hdiutil detach -force "$MOUNT_POINT" >/dev/null
fi

hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
rm -f "$DMG_TEMP"
rm -rf "$STAGING_DIR"

step "Signing DMG"
retry codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH" \
    || die "codesign failed for DMG after 3 attempts"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "Notarizing DMG"
    notarize_with_retry "$DMG_PATH" || die "DMG notarization failed; see the log above"
    ok "DMG notarized"
    retry xcrun stapler staple "$DMG_PATH" || die "stapler failed for DMG"
    xcrun stapler validate "$DMG_PATH" >/dev/null
    step "Gatekeeper check (DMG)"
    spctl -a -vvv --type open --context context:primary-signature "$DMG_PATH"
else
    warn "DMG not notarized (--skip-notarize); Gatekeeper will warn on other Macs"
fi

# ---------- 6. summary ----------
step "Artifacts"
APP_SIZE="$(du -sh "$APP_BUNDLE" | cut -f1)"
DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1)"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s\n' "$DMG_SHA  $(basename "$DMG_PATH")" > "$SHA_PATH"
printf '    app bundle : %s (%s)\n' "$APP_BUNDLE" "$APP_SIZE"
printf '    dmg        : %s (%s)\n' "$DMG_PATH" "$DMG_SIZE"
printf '    sha256     : %s\n' "$DMG_SHA"
printf '    sha file   : %s\n' "$SHA_PATH"
echo
echo "Next: create the GitHub release v$VERSION with the DMG, then put sha256 into Casks/proclens.rb."
echo "See docs/RELEASING.md."

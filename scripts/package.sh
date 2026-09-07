#!/usr/bin/env bash
#
# scripts/package.sh - build, sign, notarize and package Scope.app into dist/Scope-<version>.dmg.
#
# Env-driven; every secret is OPTIONAL and the script degrades gracefully:
#   Developer ID certificate present -> `xcodebuild archive` + `-exportArchive` (method developer-id), which re-signs
#                                       the app, scope-hook AND Sparkle's nested helpers (Autoupdate, Updater.app,
#                                       XPCServices/*.xpc) with the certificate, hardened runtime + secure timestamp
#   no certificate                   -> ad-hoc signing (CODE_SIGN_IDENTITY=-), the .app is copied out of the .xcarchive
#   notarization credentials present -> notarize + staple the .app, then the .dmg (only when Developer ID signed)
#   create-dmg on PATH               -> DMG with an /Applications drop link; otherwise plain `hdiutil create`
#
# Inputs (env):
#   VERSION                      required  1.2.3 (a leading "v" is stripped) -> MARKETING_VERSION / CFBundleShortVersionString
#   BUILD_NUMBER                 optional  default `git rev-list --count HEAD` -> CURRENT_PROJECT_VERSION / CFBundleVersion,
#                                          the number Sparkle compares (must strictly increase from release to release)
#   APP_NAME / SCHEME / PROJECT  optional  default Scope / $APP_NAME / $APP_NAME.xcodeproj (generated from project.yml if missing)
#   BUILD_DIR / OUT_DIR          optional  default build / dist
#   SOURCE_PACKAGES              optional  default SourcePackages (xcodebuild -clonedSourcePackagesDirPath; cached by CI)
#   MACOS_CERTIFICATE_P12_BASE64 optional  "Developer ID Application" certificate + private key, .p12 encoded in base64
#   MACOS_CERTIFICATE_PASSWORD   optional  password of that .p12
#   APPLE_TEAM_ID                required when signing or notarizing (10 characters)
#   SIGNING_CERTIFICATE          optional  default "Developer ID Application" (automatic selector; SHA-1 or full name also work)
#   EXPORT_METHOD                optional  default developer-id (only change for local experiments)
#   KEYCHAIN_PASSWORD            optional  random when unset
#   APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD (+ APPLE_TEAM_ID)                               notarytool, Apple ID flavour
#   APP_STORE_CONNECT_API_KEY_P8 + APP_STORE_CONNECT_KEY_ID + APP_STORE_CONNECT_ISSUER_ID notarytool, API key flavour
#   SKIP_NOTARIZE=1              optional  force-skip notarization
#   DMG_SKIP_JENKINS=1           optional  create-dmg --skip-jenkins (no Finder/AppleScript icon layout)
#   DMG_BACKGROUND / DMG_VOLICON optional  create-dmg artwork (default assets/dmg-background.png, assets/dmg-volume.icns when present)
#
# Outputs:
#   $OUT_DIR/$APP_NAME-$VERSION.dmg and .dmg.sha256, $BUILD_DIR/export/$APP_NAME.app (stapled when notarized), build logs in $BUILD_DIR
#   $GITHUB_OUTPUT (when set): dmg_path, dmg_name, sha256, build_number, signed, notarized, identity, sparkle_key, sparkle_framework
#
# Compatible with macOS bash 3.2. Runs on GitHub Actions (RUNNER_TEMP) and on a developer machine.
set -euo pipefail

# ---------------------------------------------------------------- configuration
: "${VERSION:?VERSION is required (e.g. 1.2.3)}"
VERSION="${VERSION#v}"
APP_NAME="${APP_NAME:-Scope}"
SCHEME="${SCHEME:-$APP_NAME}"
PROJECT="${PROJECT:-$APP_NAME.xcodeproj}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
SOURCE_PACKAGES="${SOURCE_PACKAGES:-$PWD/SourcePackages}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Developer ID Application}"
EXPORT_METHOD="${EXPORT_METHOD:-developer-id}"
RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d -t scope-package)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT_OPTIONS_TEMPLATE="${EXPORT_OPTIONS_TEMPLATE:-$REPO_ROOT/ExportOptions.plist}"
DMG_BACKGROUND="${DMG_BACKGROUND:-$REPO_ROOT/assets/dmg-background.png}"
DMG_VOLICON="${DMG_VOLICON:-$REPO_ROOT/assets/dmg-volume.icns}"

ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
DERIVED="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
ARTIFACT="$APP_NAME-$VERSION"
DMG="$OUT_DIR/$ARTIFACT.dmg"

SIGNED=false        # true when a real (non ad-hoc) identity is used
NOTARIZED=false
IDENTITY="ad-hoc"
SPARKLE_KEY="absent"
KEYCHAIN_PATH=""
ORIGINAL_KEYCHAINS=""
API_KEY_FILE=""
NOTARY_ARGS=()

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$*"; return 0; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$*"; exit 1; }
# codesign -dvv writes to stderr; capture it (never pipe it into `grep -q`: with pipefail the early EOF becomes SIGPIPE).
sig_info()         { codesign -dvv "$1" 2>&1; }
has_runtime_flag() { [[ "$(sig_info "$1")" == *"flags="*"runtime"* ]]; }
has_timestamp()    { [[ "$(sig_info "$1")" == *$'\n'"Timestamp="* ]]; }
team_of()          { sig_info "$1" | sed -n 's/^TeamIdentifier=//p'; }
pretty()           { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else grep -E --line-buffered 'error:|warning:|\*\* ' || true; fi; }

cleanup() {
  # Always remove the temporary keychain and the secrets written to disk, even on failure.
  if [[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]]; then
    if [[ -n "$ORIGINAL_KEYCHAINS" ]]; then
      # shellcheck disable=SC2086
      security list-keychains -d user -s $ORIGINAL_KEYCHAINS || true
    fi
    security delete-keychain "$KEYCHAIN_PATH" || true
  fi
  rm -f "$RUNNER_TEMP/certificate.p12" 2>/dev/null || true
  [[ -n "$API_KEY_FILE" ]] && rm -f "$API_KEY_FILE" 2>/dev/null
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- 0. preflight
log "Toolchain"
xcodebuild -version
mkdir -p "$BUILD_DIR" "$OUT_DIR" "$RUNNER_TEMP"
if [[ ! -d "$PROJECT" && -f project.yml ]]; then
  command -v xcodegen >/dev/null || die "xcodegen not installed (brew install xcodegen)"
  log "Generating $PROJECT from project.yml"
  xcodegen generate --spec project.yml --quiet
fi
[[ -d "$PROJECT" ]] || die "Project $PROJECT not found"

if [[ -z "${BUILD_NUMBER:-}" ]]; then
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" == "true" ]]; then
    die "Shallow clone: CURRENT_PROJECT_VERSION = git rev-list --count HEAD needs the full history (actions/checkout fetch-depth: 0) or an explicit BUILD_NUMBER"
  fi
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ && "$BUILD_NUMBER" -gt 0 ]] || die "BUILD_NUMBER must be a positive integer (got '${BUILD_NUMBER:-}')"

# ---------------------------------------------------------------- 1. keychain (optional)
if [[ -n "${MACOS_CERTIFICATE_P12_BASE64:-}" ]]; then
  log "Importing the Developer ID certificate into a temporary keychain"
  [[ -n "${APPLE_TEAM_ID:-}" ]] || die "APPLE_TEAM_ID is required together with MACOS_CERTIFICATE_P12_BASE64"
  KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(uuidgen)}"
  KEYCHAIN_PATH="$RUNNER_TEMP/app-signing.keychain-db"
  CERTIFICATE_PATH="$RUNNER_TEMP/certificate.p12"
  printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode -o "$CERTIFICATE_PATH"

  # Sequence from GitHub Docs "Installing an Apple certificate on macOS runners for Xcode development".
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$CERTIFICATE_PATH" -P "${MACOS_CERTIFICATE_PASSWORD:-}" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
  # Let Apple's tools (codesign, xcodebuild, productbuild...) use the private key without a UI prompt.
  security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  # Prepend the keychain to the user search list, keeping the existing ones (safe on a developer machine too).
  ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_KEYCHAINS
  rm -f "$CERTIFICATE_PATH"
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" || true
fi

# A valid identity may also live in the login keychain (local runs).
VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$VALID_IDENTITIES" == *"$SIGNING_CERTIFICATE"* ]]; then
  SIGNED=true
  IDENTITY="$SIGNING_CERTIFICATE"
  [[ -n "${APPLE_TEAM_ID:-}" ]] || die "APPLE_TEAM_ID is required when a signing identity is present"
  log "Signing identity found: $SIGNING_CERTIFICATE (team $APPLE_TEAM_ID)"
else
  warn "No valid '$SIGNING_CERTIFICATE' identity: ad-hoc signing. Gatekeeper will refuse the downloaded app until the user runs: xattr -d com.apple.quarantine /Applications/$APP_NAME.app"
fi

# ---------------------------------------------------------------- 2. archive (universal, Release)
log "xcodebuild archive: $SCHEME, Release, $VERSION ($BUILD_NUMBER)"
if $SIGNED; then
  SIGN_SETTINGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_CERTIFICATE" "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp)
else
  SIGN_SETTINGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=)
fi
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -skipPackagePluginValidation -skipMacroValidation \
  ONLY_ACTIVE_ARCH=NO \
  "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
  "${SIGN_SETTINGS[@]}" \
  | tee "$BUILD_DIR/xcodebuild-archive.log" | pretty
[[ -d "$ARCHIVE/Products/Applications/$APP_NAME.app" ]] || die "The archive did not produce $APP_NAME.app"

# ---------------------------------------------------------------- 3. export (re-signs every nested code item) or copy
rm -rf "$EXPORT_DIR"; mkdir -p "$EXPORT_DIR"

resign_inside_out() {
  # Fallback only (exported app without a secure timestamp): manual inside-out signing, never --deep.
  local app="$1" id="$2" ent="$3" sp item
  sp="$app/Contents/Frameworks/Sparkle.framework"
  for item in "$sp/Versions/B/XPCServices/Installer.xpc" "$sp/Versions/B/XPCServices/Downloader.xpc" \
              "$sp/Versions/B/Autoupdate" "$sp/Versions/B/Updater.app" "$sp"; do
    [[ -e "$item" ]] && codesign -f -s "$id" -o runtime --timestamp "$item"
  done
  for item in "$app"/Contents/Helpers/* "$app"/Contents/MacOS/*; do
    [[ -f "$item" && "$item" != "$app/Contents/MacOS/$APP_NAME" ]] && codesign -f -s "$id" -o runtime --timestamp "$item"
  done
  if [[ -n "$ent" ]]; then
    codesign -f -s "$id" -o runtime --timestamp --entitlements "$ent" "$app"
  else
    codesign -f -s "$id" -o runtime --timestamp "$app"
  fi
}

if $SIGNED; then
  log "xcodebuild -exportArchive (method $EXPORT_METHOD)"
  EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
  cp "$EXPORT_OPTIONS_TEMPLATE" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Set :method $EXPORT_METHOD" \
                          -c "Set :teamID $APPLE_TEAM_ID" \
                          -c "Set :signingCertificate $SIGNING_CERTIFICATE" "$EXPORT_OPTIONS"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$EXPORT_DIR" \
    | tee "$BUILD_DIR/xcodebuild-export.log" | pretty
  [[ -d "$APP" ]] || die "The export did not produce $APP"
  # Notarization requires a secure timestamp. Xcode's developer-id export adds one; other methods may not.
  if ! has_timestamp "$APP"; then
    warn "Exported app has no secure timestamp: re-signing inside-out with --timestamp"
    ENT_FILE="$BUILD_DIR/entitlements.plist"
    codesign -d --entitlements - --xml "$APP" > "$ENT_FILE" 2>/dev/null || ENT_FILE=""
    resign_inside_out "$APP" "$SIGNING_CERTIFICATE" "$ENT_FILE"
  fi
else
  log "Ad-hoc build: copying $APP_NAME.app out of the archive (-exportArchive needs a certificate)"
  ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"
fi

# ---------------------------------------------------------------- 4. verify the app
log "Verifying $APP"
codesign --verify --deep --strict --verbose=2 "$APP"
sig_info "$APP" | grep -E '^(Identifier|Format|Authority|TeamIdentifier|Timestamp|Signed Time)=|flags=' || true
has_runtime_flag "$APP" || die "Hardened runtime flag missing on $APP"
if [[ -d "$APP/Contents/Helpers" ]]; then
  for h in "$APP"/Contents/Helpers/*; do
    [[ -f "$h" ]] || continue
    has_runtime_flag "$h" || die "Hardened runtime flag missing on $h"
  done
else
  warn "No Contents/Helpers directory: scope-hook is not embedded in this build"
fi
if $SIGNED; then
  has_timestamp "$APP" || die "Secure timestamp missing on $APP"
  # Every nested Sparkle helper must carry the same TeamIdentifier (notarization + Sparkle's own checks).
  team_main="$(team_of "$APP")"
  for nested in "$APP"/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc \
                "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
                "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
                "$APP"/Contents/Helpers/*; do
    [[ -e "$nested" ]] || continue
    t="$(team_of "$nested")"
    [[ "$t" == "$team_main" ]] || die "TeamIdentifier mismatch on $nested ($t != $team_main)"
  done
fi

# Version stamps that end up in the appcast (sparkle:shortVersionString / sparkle:version).
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$short" == "$VERSION" && "$build" == "$BUILD_NUMBER" ]] \
  || die "Info.plist has $short ($build), expected $VERSION ($BUILD_NUMBER): map CFBundleShortVersionString/CFBundleVersion to \$(MARKETING_VERSION)/\$(CURRENT_PROJECT_VERSION) in project.yml"
SPARKLE_FRAMEWORK="$( /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" 2>/dev/null || echo "not embedded")"
echo "Sparkle.framework: $SPARKLE_FRAMEWORK"

# Sparkle public key: absent = warn (this build can never validate an update), invalid = refuse (error alert at every launch).
set +e
"$SCRIPT_DIR/sparkle-key-check.sh" "$APP/Contents/Info.plist"; key_rc=$?
set -e
case "$key_rc" in
  0) SPARKLE_KEY="valid" ;;
  2) SPARKLE_KEY="absent"; warn "SUPublicEDKey is absent: this build cannot auto-update. Generate the keys before the first public release (README > Releasing)." ;;
  *) die "SUPublicEDKey in project.yml is invalid; Sparkle would show 'Unable to Check For Updates' at every launch. Paste the output of generate_keys (README > Releasing > One-time setup)." ;;
esac

# ---------------------------------------------------------------- 5. notarization credentials
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]] && $SIGNED; then
  if [[ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" && -n "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    API_KEY_FILE="$RUNNER_TEMP/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
    printf '%s\n' "$APP_STORE_CONNECT_API_KEY_P8" > "$API_KEY_FILE"
    NOTARY_ARGS=(--key "$API_KEY_FILE" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
  else
    warn "No notarization credentials (APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD or APP_STORE_CONNECT_*): skipping notarization"
  fi
elif ! $SIGNED; then
  echo "Notarization skipped (requires a Developer ID signature)"
fi
NOTARIZE_ENABLED=false; [[ ${#NOTARY_ARGS[@]} -gt 0 ]] && NOTARIZE_ENABLED=true

notarize() {
  # $1 = .zip, .dmg or .pkg. --wait returns on Accepted / Invalid / Rejected: never trust the exit code, read the status.
  local file="$1" result id status
  result="$BUILD_DIR/notarytool-$(basename "$file").plist"
  xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --timeout 30m --output-format plist --no-progress > "$result"
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  echo "notarytool: $file -> $status (submission $id)"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" "$BUILD_DIR/notarytool-log-$id.json" && cat "$BUILD_DIR/notarytool-log-$id.json"
    die "Notarization of $file failed with status '${status:-unknown}'"
  fi
}

# ---------------------------------------------------------------- 6. notarize + staple the app
if $NOTARIZE_ENABLED; then
  log "Notarizing $APP_NAME.app"
  APP_ZIP="$BUILD_DIR/$ARTIFACT-notarize.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"      # Apple's recommended packaging for notarizing a bare .app
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP"                     # a .zip cannot be stapled: staple the .app itself
  xcrun stapler validate "$APP"
  NOTARIZED=true
  spctl -a -t exec -vv "$APP" || warn "spctl did not accept $APP (expected: accepted, source=Notarized Developer ID)"
fi

# ---------------------------------------------------------------- 7. DMG
log "Building $DMG"
DMG_ROOT="$BUILD_DIR/dmg-root"
rm -rf "$DMG_ROOT" "$DMG" "$OUT_DIR"/rw.*.dmg; mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/$APP_NAME.app"

CREATE_DMG="${CREATE_DMG:-$(command -v create-dmg || true)}"
build_dmg_pretty() {
  local extra=()
  [[ "${DMG_SKIP_JENKINS:-0}" == "1" ]] && extra+=(--skip-jenkins)
  [[ -f "$DMG_BACKGROUND" ]] && extra+=(--background "$DMG_BACKGROUND")
  [[ -f "$DMG_VOLICON" ]] && extra+=(--volicon "$DMG_VOLICON")
  "$CREATE_DMG" \
    --volname "$APP_NAME $VERSION" \
    --window-pos 200 120 --window-size 660 400 --icon-size 128 --text-size 14 \
    --icon "$APP_NAME.app" 180 170 --hide-extension "$APP_NAME.app" \
    --app-drop-link 480 170 \
    --format UDZO --hdiutil-quiet --no-internet-enable \
    ${extra[@]+"${extra[@]}"} \
    "$DMG" "$DMG_ROOT/"
}
build_dmg_plain() {
  ln -sfn /Applications "$DMG_ROOT/Applications"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
}
if [[ -n "$CREATE_DMG" ]] && build_dmg_pretty; then
  echo "DMG built with create-dmg"
else
  [[ -n "$CREATE_DMG" ]] && warn "create-dmg failed: falling back to hdiutil"
  rm -f "$DMG" "$OUT_DIR"/rw.*.dmg
  build_dmg_plain
fi
hdiutil verify "$DMG" >/dev/null && echo "hdiutil verify: OK"

log "Signing the DMG"
if $SIGNED; then
  codesign --sign "$SIGNING_CERTIFICATE" --timestamp --verbose=2 "$DMG"
else
  codesign --sign - --verbose=2 "$DMG"
fi
codesign --verify --verbose=2 "$DMG"

if $NOTARIZE_ENABLED; then
  log "Notarizing the DMG"
  notarize "$DMG"                                   # the notary service accepts UDIF disk images directly
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || warn "spctl did not accept $DMG"
fi

# ---------------------------------------------------------------- 8. checksum + outputs
log "Checksum"
( cd "$OUT_DIR" && shasum -a 256 "$ARTIFACT.dmg" | tee "$ARTIFACT.dmg.sha256" )
SHA256="$(cut -d' ' -f1 "$DMG.sha256")"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "dmg_path=$DMG"
    echo "dmg_name=$ARTIFACT.dmg"
    echo "sha256=$SHA256"
    echo "build_number=$BUILD_NUMBER"
    echo "signed=$SIGNED"
    echo "notarized=$NOTARIZED"
    echo "identity=$IDENTITY"
    echo "sparkle_key=$SPARKLE_KEY"
    echo "sparkle_framework=$SPARKLE_FRAMEWORK"
  } >> "$GITHUB_OUTPUT"
fi
log "Done: $DMG ($VERSION build $BUILD_NUMBER, signed=$SIGNED notarized=$NOTARIZED sparkle_key=$SPARKLE_KEY)"

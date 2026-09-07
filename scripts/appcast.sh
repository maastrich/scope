#!/usr/bin/env bash
#
# scripts/appcast.sh - sign one release DMG with the Sparkle EdDSA key and produce dist/appcast.xml.
#
#   scripts/appcast.sh dist/Scope-1.2.3.dmg
#
# Skips (exit 0, nothing written) when SPARKLE_PRIVATE_KEY is empty: an unsigned feed would make Sparkle offer an
# update and then reject it with an error dialog, whereas no feed at all (HTTP 404) is a silent retry later.
#
# The previous appcast.xml is downloaded from the LATEST published release and handed to generate_appcast, which
# keeps its items verbatim and prepends the new one (previous DMGs are NOT downloaded: that would create binary
# deltas and rewrite the old items' URLs to this tag's --download-url-prefix). Each item therefore keeps the
# per-tag URL https://github.com/<repo>/releases/download/<tag>/<dmg> and stays valid after newer releases.
#
# Inputs (env):
#   SPARKLE_PRIVATE_KEY     single-line output of `generate_keys -x` (base64 of the 32-byte seed); optional
#   TAG                     git tag of this release, e.g. v1.2.3 (required)
#   REPO                    owner/repo (default $GITHUB_REPOSITORY, then maastrich/scope)
#   NOTES_FILE              markdown release notes embedded in the item (optional)
#   APP                     the exported app, to validate its SUPublicEDKey first (default build/export/Scope.app)
#   SPARKLE_BIN             directory containing generate_appcast + sign_update (default: the SwiftPM artifact under
#                           $SOURCE_PACKAGES, then a download of Sparkle-$SPARKLE_VERSION.tar.xz)
#   SOURCE_PACKAGES         default SourcePackages;  SPARKLE_VERSION default 2.9.6;  SPARKLE_TARBALL_SHA256 optional
#   FEED_URL                previous feed (default https://github.com/$REPO/releases/latest/download/appcast.xml)
#   NO_PREVIOUS=1           start a fresh feed (ignore the previous appcast)
#   DOWNLOAD_URL_PREFIX     default https://github.com/$REPO/releases/download/$TAG/
#   LINK                    default https://github.com/$REPO
#   SPARKLE_MAX_VERSIONS    items kept per branch point (default 5)
#   OUT_DIR / WORK_DIR      default dist / build/appcast
#
# Outputs: $OUT_DIR/appcast.xml and, when $GITHUB_OUTPUT is set: appcast (generated|skipped), appcast_reason,
#          appcast_path, appcast_items, appcast_signature
set -euo pipefail

DMG="${1:-}"
[ -n "$DMG" ] || { echo "usage: $0 <path/to/Scope-x.y.z.dmg>" >&2; exit 2; }
[ -f "$DMG" ] || { echo "error: $DMG not found" >&2; exit 1; }
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
DMG_NAME="$(basename "$DMG")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-${GITHUB_REPOSITORY:-maastrich/scope}}"
APP="${APP:-$PWD/build/export/Scope.app}"
SOURCE_PACKAGES="${SOURCE_PACKAGES:-$PWD/SourcePackages}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.6}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
WORK_DIR="${WORK_DIR:-$PWD/build/appcast}"
RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d -t scope-appcast)}"
LINK="${LINK:-https://github.com/$REPO}"
FEED_URL="${FEED_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}"
SPARKLE_MAX_VERSIONS="${SPARKLE_MAX_VERSIONS:-5}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$*"; return 0; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$*"; exit 1; }
output() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; return 0; }
skip() { warn "Sparkle appcast skipped: $1"; output "appcast=skipped" "appcast_reason=$1"; exit 0; }

[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || skip "SPARKLE_PRIVATE_KEY secret not set (no auto-update feed for this release)"
[ -n "${TAG:-}" ] || die "TAG is required (e.g. v1.2.3)"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$REPO/releases/download/$TAG/}"
case "$DOWNLOAD_URL_PREFIX" in */) ;; *) DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX/" ;; esac
ENCLOSURE_URL="$DOWNLOAD_URL_PREFIX$DMG_NAME"

# ---------------------------------------------------------------- 1. the app must carry a valid SUPublicEDKey
if [ -d "$APP" ]; then
  set +e
  "$SCRIPT_DIR/sparkle-key-check.sh" "$APP/Contents/Info.plist"; key_rc=$?
  set -e
  case "$key_rc" in
    0) ;;
    2) die "$APP has no SUPublicEDKey: a feed pointing at it could never be validated by installed copies (Sparkle refuses key removal). Add the public key to project.yml." ;;
    *) die "$APP has an invalid SUPublicEDKey" ;;
  esac
else
  warn "$APP not found: skipping the SUPublicEDKey pre-check (generate_appcast still detects a key mismatch)"
fi

# ---------------------------------------------------------------- 2. Sparkle tools (same version as the embedded framework)
find_tools() {
  local candidate
  if [ -n "${SPARKLE_BIN:-}" ]; then
    [ -x "$SPARKLE_BIN/generate_appcast" ] || die "SPARKLE_BIN=$SPARKLE_BIN has no generate_appcast"
    return 0
  fi
  candidate="$(find "$SOURCE_PACKAGES/artifacts" -type f -path '*/Sparkle/bin/generate_appcast' 2>/dev/null | head -n 1 || true)"
  if [ -n "$candidate" ]; then
    SPARKLE_BIN="$(dirname "$candidate")"
    echo "Sparkle tools: SwiftPM artifact $SPARKLE_BIN"
    return 0
  fi
  local tarball="$RUNNER_TEMP/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "Sparkle tools: downloading Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL --retry 3 -o "$tarball" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  if [ -n "${SPARKLE_TARBALL_SHA256:-}" ]; then
    echo "$SPARKLE_TARBALL_SHA256  $tarball" | shasum -a 256 -c - || die "Sparkle tarball checksum mismatch"
  fi
  mkdir -p "$RUNNER_TEMP/sparkle"
  tar -xJf "$tarball" -C "$RUNNER_TEMP/sparkle" ./bin
  SPARKLE_BIN="$RUNNER_TEMP/sparkle/bin"
}
find_tools
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[ -x "$GENERATE_APPCAST" ] && [ -x "$SIGN_UPDATE" ] || die "generate_appcast / sign_update not found in $SPARKLE_BIN"
if [ -d "$APP" ]; then
  embedded="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" 2>/dev/null || true)"
  [ -z "$embedded" ] || [ "$embedded" = "$SPARKLE_VERSION" ] || warn "Embedded Sparkle.framework is $embedded but the tools are $SPARKLE_VERSION (keep SPARKLE_VERSION in sync with project.yml)"
fi

# ---------------------------------------------------------------- 3. working directory: new DMG + notes + previous feed
log "Preparing $WORK_DIR"
rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR" "$OUT_DIR"
cp "$DMG" "$WORK_DIR/$DMG_NAME"
if [ -n "${NOTES_FILE:-}" ] && [ -s "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$WORK_DIR/${DMG_NAME%.dmg}.md"   # same basename as the archive => embedded as markdown release notes
fi
if [ "${NO_PREVIOUS:-0}" != "1" ]; then
  if curl -fsSL --retry 3 -o "$WORK_DIR/appcast.xml" "$FEED_URL"; then
    echo "Previous feed: $FEED_URL ($(grep -c '<item>' "$WORK_DIR/appcast.xml" || true) items) - its items are kept"
  else
    rm -f "$WORK_DIR/appcast.xml"
    echo "No previous feed at $FEED_URL (first release, or the latest release has no appcast): starting a new feed"
  fi
fi

# ---------------------------------------------------------------- 4. generate_appcast (key from stdin, never on disk)
log "generate_appcast"
LOG="$WORK_DIR/generate_appcast.log"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$LINK" \
  --embed-release-notes \
  --maximum-versions "$SPARKLE_MAX_VERSIONS" \
  "$WORK_DIR" 2>&1 | tee "$LOG"

# generate_appcast only WARNS on a key mismatch and writes the item without a signature: treat it as fatal.
if grep -q "does not match key" "$LOG"; then
  die "SPARKLE_PRIVATE_KEY does not match the SUPublicEDKey embedded in the app. Export the key that matches project.yml (generate_keys -x) and update the secret."
fi
grep -q "could not sign" "$LOG" && die "generate_appcast could not sign $DMG_NAME"

APPCAST="$WORK_DIR/appcast.xml"
[ -f "$APPCAST" ] || die "generate_appcast produced no appcast.xml"
ITEM_LINE="$(grep -F "url=\"$ENCLOSURE_URL\"" "$APPCAST" || true)"
if [ -z "$ITEM_LINE" ]; then
  if grep -q "Wrote 0 new" "$LOG"; then
    skip "the previous feed already lists a newer version than $DMG_NAME (re-building an older tag?); dist/appcast.xml not written"
  fi
  die "no <enclosure> for $ENCLOSURE_URL in the generated appcast"
fi
SIGNATURE="$(printf '%s\n' "$ITEM_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] || die "the enclosure for $DMG_NAME has no sparkle:edSignature (see $LOG)"

# ---------------------------------------------------------------- 5. independent verification of the signature
log "sign_update --verify"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$DMG" "$SIGNATURE" \
  || die "sign_update could not verify the signature of $DMG"
echo "EdDSA signature verified: $SIGNATURE"

cp "$APPCAST" "$OUT_DIR/appcast.xml"
ITEMS="$(grep -c '<item>' "$OUT_DIR/appcast.xml" || true)"
log "Appcast written: $OUT_DIR/appcast.xml ($ITEMS items, newest: $ENCLOSURE_URL)"
sed -n '/<item>/,/<\/item>/p' "$OUT_DIR/appcast.xml" | head -n 40
output "appcast=generated" "appcast_reason=signed with SPARKLE_PRIVATE_KEY" "appcast_path=$OUT_DIR/appcast.xml" "appcast_items=$ITEMS" "appcast_signature=$SIGNATURE"

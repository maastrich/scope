#!/usr/bin/env bash
# scripts/install.sh — install Scope from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/maastrich/scope/main/scripts/install.sh | bash
#
# Downloads the release DMG, checks it against the SHA-256 published next to it, copies Scope.app into
# /Applications and removes the quarantine attribute Gatekeeper sets on anything downloaded.
#
# That last step is the point of this script. Scope's DMG is ad-hoc signed: cutting a Developer ID
# signature costs an Apple Developer Program membership, so macOS refuses to open the app until the
# quarantine flag is cleared. The checksum is what stands in for Apple's blessing here — the script
# refuses to install anything whose hash does not match the one on the release.
#
# Environment:
#   SCOPE_VERSION   version to install ("0.2.0", "v0.2.0"); default: the latest release
#   SCOPE_DEST      install directory; default: /Applications
#   SCOPE_REPO      owner/name of the GitHub repository; default: maastrich/scope
set -euo pipefail

REPO="${SCOPE_REPO:-maastrich/scope}"
DEST="${SCOPE_DEST:-/Applications}"
APP="Scope.app"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
[ -t 1 ] || { BOLD=""; DIM=""; RED=""; GREEN=""; RESET=""; }

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Scope is a macOS app; this is $(uname -s)."
for tool in curl shasum hdiutil ditto xattr; do
    command -v "$tool" >/dev/null 2>&1 || die "\`$tool\` is missing from PATH."
done

# --- Which version -----------------------------------------------------------------------------

version="${SCOPE_VERSION:-}"
if [ -z "$version" ]; then
    step "Looking up the latest release of $REPO"
    # The redirect of /releases/latest carries the tag, so no API token and no jq are needed.
    location=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
        || die "could not reach github.com."
    version="${location##*/tag/}"
    [ "$version" != "$location" ] || die "no published release yet on $REPO."
fi
tag="$version"
case "$tag" in v*) ;; *) tag="v$tag" ;; esac
version="${tag#v}"

dmg="Scope-$version.dmg"
base="https://github.com/$REPO/releases/download/$tag"

# --- Download and verify -----------------------------------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/scope-install.XXXXXX")
mount=""
cleanup() {
    [ -n "$mount" ] && hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

step "Downloading $dmg"
curl -fL# -o "$work/$dmg" "$base/$dmg" || die "$tag has no $dmg asset."
curl -fsSL -o "$work/$dmg.sha256" "$base/$dmg.sha256" \
    || die "$tag publishes no checksum for $dmg; refusing to install unverified."

step "Checking SHA-256"
( cd "$work" && shasum -a 256 -c "$dmg.sha256" >/dev/null 2>&1 ) \
    || die "checksum mismatch — the download is corrupt or has been tampered with. Nothing was installed."
say "${DIM}$(awk '{print $1}' "$work/$dmg.sha256")${RESET}"

# --- Install -------------------------------------------------------------------------------------

if pgrep -x Scope >/dev/null 2>&1; then
    step "Quitting the running Scope"
    osascript -e 'tell application "Scope" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Scope >/dev/null 2>&1 || break
        sleep 0.5
    done
    pgrep -x Scope >/dev/null 2>&1 && die "Scope is still running; quit it and run this again."
fi

step "Mounting $dmg"
mount="$work/mnt"
mkdir -p "$mount"
hdiutil attach "$work/$dmg" -nobrowse -readonly -mountpoint "$mount" -quiet \
    || die "could not mount $dmg."
[ -d "$mount/$APP" ] || die "$dmg does not contain $APP."

sudo=""
if [ ! -w "$DEST" ]; then
    say "${DIM}$DEST is not writable; asking for your password.${RESET}"
    sudo="sudo"
fi

step "Installing into $DEST"
$sudo rm -rf "$DEST/$APP"
$sudo ditto "$mount/$APP" "$DEST/$APP" || die "could not copy $APP into $DEST."

# Gatekeeper refuses an ad-hoc signed app that carries the quarantine flag; this is what makes the
# app openable with a double-click instead of a trip through System Settings.
step "Removing the quarantine flag"
$sudo xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

installed=$(defaults read "$DEST/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$version")
say ""
say "${GREEN}Scope $installed is installed in $DEST.${RESET}"
say "  open -a Scope"
say ""
say "${DIM}Updates come from Scope itself (Scope ▸ Check for Updates…), signed with the project's Sparkle key.${RESET}"

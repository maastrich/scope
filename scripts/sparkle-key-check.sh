#!/usr/bin/env bash
#
# scripts/sparkle-key-check.sh - validate the Sparkle public key (SUPublicEDKey) of a built app.
#
#   scripts/sparkle-key-check.sh Scope.app/Contents/Info.plist
#
# Exit codes:
#   0  valid key (base64 of 32 bytes)  -> Sparkle can verify EdDSA-signed updates
#   2  key absent                      -> Sparkle starts (HTTPS feed + code-signed app) but no update can ever be
#                                         validated by this build; the appcast step refuses to sign for it
#   1  key present but invalid         -> Sparkle's updater refuses to start and shows "Unable to Check For Updates"
#                                         at EVERY launch (SPUStandardUpdaterController); never ship this
set -euo pipefail

PLIST="${1:-}"
[ -f "$PLIST" ] || { echo "usage: $0 <Info.plist>" >&2; exit 2; }

if ! key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null)"; then
  echo "SUPublicEDKey: absent from $PLIST (auto-update disabled for this build; run generate_keys and add it to project.yml)" >&2
  exit 2
fi

# Sparkle decodes the value with NSData(base64Encoded:) and requires exactly 32 bytes.
decoded_len="$(printf '%s' "$key" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')"
if printf '%s' "$key" | grep -Eq '^[A-Za-z0-9+/]{43}=$' && [ "$decoded_len" = 32 ]; then
  echo "SUPublicEDKey: $key (valid)"
  exit 0
fi

echo "SUPublicEDKey: '$key' is not a valid Ed25519 public key (expected 44 base64 characters decoding to 32 bytes)." >&2
echo "Run Sparkle's generate_keys and paste its output into project.yml (README > Releasing > One-time setup)." >&2
exit 1

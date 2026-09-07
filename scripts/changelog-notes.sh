#!/usr/bin/env bash
#
# scripts/changelog-notes.sh - print the body of one release section of CHANGELOG.md.
#
#   scripts/changelog-notes.sh 1.2.3 [CHANGELOG.md]
#
# Prints everything between "## [1.2.3]..." and the next "## " heading, without the heading itself and
# without leading/trailing blank lines. Exit 0 when found, 1 when the section is missing or empty
# (the release workflow then falls back to git-cliff). Portable: bash 3.2, BSD awk, mawk, gawk.
set -euo pipefail

VERSION="${1:-}"
FILE="${2:-CHANGELOG.md}"
[ -n "$VERSION" ] || { echo "usage: $0 <version> [CHANGELOG.md]" >&2; exit 2; }
[ -f "$FILE" ] || { echo "error: $FILE not found" >&2; exit 1; }
VERSION="${VERSION#v}"

# Exact prefix comparison (no regex): "## [1.2.3]" matches "## [1.2.3](https://...) - 2026-09-07" but not "## [1.2.3-beta.1]".
if awk -v prefix="## [$VERSION]" '
  found && /^## / { exit }
  found { lines[++n] = $0 }
  substr($0, 1, length(prefix)) == prefix { found = 1 }
  END {
    first = 1; last = n
    while (first <= last && lines[first] ~ /^[ \t]*$/) first++
    while (last >= first && lines[last] ~ /^[ \t]*$/) last--
    for (i = first; i <= last; i++) print lines[i]
    exit (found && last >= first) ? 0 : 1
  }
' "$FILE"; then
  exit 0
fi
echo "error: no '## [$VERSION]' section with content in $FILE" >&2
exit 1

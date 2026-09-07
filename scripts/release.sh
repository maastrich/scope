#!/usr/bin/env bash
#
# scripts/release.sh - cut a Scope release from a clean, up-to-date `main`.
#
#   scripts/release.sh 0.4.0            release exactly this version
#   scripts/release.sh                  suggest the next version from Conventional Commits (git cliff --bumped-version)
#   scripts/release.sh 0.4.0 --dry-run  print the notes and the plan, change nothing
#
# Steps:
#   1. checks: on main, clean tree, in sync with origin/main, version format, tag unused, version > last tag
#   2. inserts the "## [X.Y.Z]" section into CHANGELOG.md (git-cliff; GitHub usernames when a token is available)
#   3. commits "chore(release): vX.Y.Z" and creates the annotated tag vX.Y.Z (release notes as the tag message)
#   4. pushes main + tag atomically -> .github/workflows/release.yml builds the DMG and publishes the GitHub release
#
# The version lives ONLY in the tag: release.yml derives MARKETING_VERSION from it and CURRENT_PROJECT_VERSION
# from `git rev-list --count HEAD`. Nothing else in the tree is bumped.
#
# Options:
#   --dry-run   preview only
#   --edit      open CHANGELOG.md in $EDITOR before committing
#   --offline   never call the GitHub API (no "@username" in the notes)
#   -y, --yes   no confirmation prompt
#
# Requires git and git-cliff (brew install git-cliff). Optional: gh (its token enables GitHub enrichment).
# Compatible with macOS bash 3.2 and BSD sed/sort.

set -euo pipefail

MAIN_BRANCH="main"
REMOTE="origin"
CHANGELOG="CHANGELOG.md"
APP_NAME="Scope"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required ($2)"; }
usage() { sed -n '3,/^# Compatible/p' "$0" | sed -e 's/^# \{0,1\}//'; }

# --- arguments ---------------------------------------------------------------
VERSION=""; DRY_RUN=0; EDIT=0; OFFLINE=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --edit)    EDIT=1 ;;
    --offline) OFFLINE=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1 (see --help)" ;;
    *)         [ -z "$VERSION" ] || die "unexpected argument: $1"; VERSION="$1" ;;
  esac
  shift
done

need git "https://git-scm.com"
need git-cliff "brew install git-cliff"
[ -f cliff.toml ] || die "cliff.toml not found at the repository root"
[ -f "$CHANGELOG" ] || die "$CHANGELOG not found (seed it with the Keep a Changelog header and a '## [Unreleased]' section)"

# --- repository state --------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "$MAIN_BRANCH" ] || die "not on '$MAIN_BRANCH' (currently on '$BRANCH')"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes"
say "Fetching $REMOTE/$MAIN_BRANCH and tags"
git fetch --quiet --tags "$REMOTE" "$MAIN_BRANCH"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$REMOTE/$MAIN_BRANCH")" ] \
  || die "'$MAIN_BRANCH' is not in sync with '$REMOTE/$MAIN_BRANCH' (pull or push first)"

# Highest existing release tag (versionsort.suffix=- ranks v1.0.0-rc.1 below v1.0.0).
LAST_TAG="$(git -c versionsort.suffix=- tag --list 'v[0-9]*' --sort=-version:refname | head -n 1)"

# --- git-cliff: GitHub enrichment, with an offline fallback ------------------
# git-cliff aborts (exit 101) when the GitHub API is unreachable, the repo does not exist yet or the
# unauthenticated rate limit is hit. A release must never depend on that: probe once, fall back to --offline.
CLIFF_OPTS=""
if [ "$OFFLINE" = 1 ]; then
  CLIFF_OPTS="--offline"
elif [ -z "${GITHUB_TOKEN:-}" ]; then
  if command -v gh >/dev/null 2>&1 && GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && [ -n "$GITHUB_TOKEN" ]; then
    export GITHUB_TOKEN
  else
    warn "no GITHUB_TOKEN and no 'gh auth login' session: generating offline (no @usernames in the notes)"
    CLIFF_OPTS="--offline"
  fi
fi
if [ -z "$CLIFF_OPTS" ]; then
  probe_err="$(mktemp)"
  if ! git cliff --unreleased --strip all >/dev/null 2>"$probe_err"; then
    reason="$(grep -o 'Status([0-9]*' "$probe_err" | head -n 1 | sed 's/Status(/HTTP /')"
    warn "GitHub API unavailable (${reason:-network error}) - generating offline (no @usernames in the notes)"
    CLIFF_OPTS="--offline"
  fi
  rm -f "$probe_err"
fi
cliff() {
  local err
  err="$(mktemp)"
  # shellcheck disable=SC2086 # CLIFF_OPTS is intentionally word-split
  if git cliff $CLIFF_OPTS "$@" 2>"$err"; then
    grep -i 'WARN' "$err" >&2 || true
    rm -f "$err"
    return 0
  fi
  cat "$err" >&2
  rm -f "$err"
  return 1
}

# --- version -----------------------------------------------------------------
if [ -z "$VERSION" ]; then
  SUGGESTED="$(cliff --bumped-version)" || die "could not compute the next version"
  say "Next version from Conventional Commits since ${LAST_TAG:-the first commit}: $SUGGESTED"
  if [ "$ASSUME_YES" = 1 ]; then
    VERSION="${SUGGESTED#v}"
  else
    printf 'Version to release [%s]: ' "${SUGGESTED#v}"
    read -r answer
    VERSION="${answer:-${SUGGESTED#v}}"
  fi
fi
VERSION="${VERSION#v}"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || die "invalid version '$VERSION' (expected X.Y.Z or X.Y.Z-pre.N)"
TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists locally"; fi
[ -z "$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG")" ] || die "tag $TAG already exists on $REMOTE"
! grep -q "^## \[$VERSION\]" "$CHANGELOG" || die "$CHANGELOG already has a '## [$VERSION]' section"

if [ -n "$LAST_TAG" ]; then
  last_core="${LAST_TAG#v}"; last_core="${last_core%%-*}"
  new_core="${VERSION%%-*}"
  highest="$(printf '%s\n%s\n' "$last_core" "$new_core" | sort -V | tail -n 1)"
  [ "$highest" = "$new_core" ] || die "$VERSION is lower than the last release $LAST_TAG"
  if [ "$last_core" = "$new_core" ] && [ "${LAST_TAG#v}" = "$last_core" ]; then
    die "$VERSION is not newer than $LAST_TAG"
  fi
  [ "$(git rev-list --count "$LAST_TAG..HEAD")" -gt 0 ] || die "no commits since $LAST_TAG, nothing to release"
fi

# --- preview -----------------------------------------------------------------
say "Release notes for $TAG (${LAST_TAG:-first commit}..HEAD):"
NOTES="$(export CLIFF_NO_HEADING=1; cliff --unreleased --tag "$TAG" --strip all)" || die "git-cliff failed"
[ -n "$NOTES" ] || die "no releasable Conventional Commits since ${LAST_TAG:-the first commit} (feat/fix/perf/refactor/docs/...)"
printf '%s\n\n' "$NOTES"
say "Plan:"
printf '    %s: new section "## [%s]" (inserted above the previous release, below "## [Unreleased]")\n' "$CHANGELOG" "$VERSION"
printf '    commit "chore(release): %s", annotated tag %s, push %s + %s to %s\n' "$TAG" "$TAG" "$MAIN_BRANCH" "$TAG" "$REMOTE"
printf '    CI: MARKETING_VERSION=%s, CURRENT_PROJECT_VERSION=%s (commit count at the tag)\n' "$VERSION" "$(( $(git rev-list --count HEAD) + 1 ))"
if [ "$DRY_RUN" = 1 ]; then say "--dry-run: nothing changed"; exit 0; fi
if [ "$ASSUME_YES" = 0 ]; then
  printf 'Proceed? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
fi

# --- CHANGELOG.md ------------------------------------------------------------
# The full section, with its "## [x.y.z](url) - date" heading.
SECTION="$(cliff --unreleased --tag "$TAG" --strip all)" || die "git-cliff failed"
section_file="$(mktemp)"
printf '%s\n' "$SECTION" > "$section_file"
tmp="$(mktemp)"
# Insert before the first released section ("## [x.y.z]" that is not "## [Unreleased]"); append when none exists.
awk -v section_file="$section_file" '
  function emit_section(   line) {
    while ((getline line < section_file) > 0) print line
    close(section_file)
    print ""
  }
  !done && /^## \[/ && !/^## \[Unreleased\]/ { emit_section(); done = 1 }
  { print }
  END { if (!done) { print ""; emit_section() } }
' "$CHANGELOG" > "$tmp"
mv "$tmp" "$CHANGELOG"
rm -f "$section_file"
grep -q "^## \[$VERSION\]" "$CHANGELOG" || die "failed to add the '## [$VERSION]' section to $CHANGELOG"
[ "$(grep -c "^## \[$VERSION\]" "$CHANGELOG")" -eq 1 ] || die "$CHANGELOG now has several '## [$VERSION]' sections"

if [ "$EDIT" = 1 ]; then "${EDITOR:-vi}" "$CHANGELOG"; fi

# --- commit, tag, push -------------------------------------------------------
git add "$CHANGELOG"
git commit --quiet -m "chore(release): $TAG"
# --cleanup=verbatim keeps the markdown "###" lines that git would otherwise treat as comments.
git tag -a --cleanup=verbatim "$TAG" -m "$APP_NAME $VERSION" -m "$NOTES"
say "Pushing $MAIN_BRANCH and $TAG to $REMOTE (atomic)"
if ! git push --atomic "$REMOTE" "$MAIN_BRANCH" "$TAG"; then
  die "push failed, nothing was published. Undo locally with: git tag -d $TAG && git reset --hard $REMOTE/$MAIN_BRANCH"
fi
say "$TAG pushed. The Release workflow now builds the DMG and publishes the GitHub release."
remote_url="$(git remote get-url "$REMOTE" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
case "$remote_url" in https://github.com/*) say "  $remote_url/actions/workflows/release.yml" ;; esac

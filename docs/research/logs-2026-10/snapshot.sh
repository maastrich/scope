#!/bin/sh
# Copies every source the analysis reads into SNAP (default: a fresh temp dir), read-only on the sources.
# Usage: snapshot.sh [SNAP] [DAYS]   then   python3 -I analyze.py SNAP
# Never point SNAP inside the repository: the copies hold prompts, paths and terminal text.
set -eu
SNAP=${1:-$(mktemp -d -t scope-logs)}
DAYS=${2:-7}
HOME_DIR=${SCOPE_HOME:-$HOME/.scope}
mkdir -p "$SNAP/tasks" "$SNAP/threads" "$SNAP/crash"

cp -p "$HOME_DIR/history.jsonl" "$HOME_DIR/assist.json" "$SNAP/" 2>/dev/null || true
cp -p "$HOME_DIR"/usage/usage-*.jsonl "$HOME_DIR/usage/registry.json" "$SNAP/"
cp -p "$HOME_DIR"/tasks/*.json "$SNAP/tasks/"
cp -p "$HOME_DIR"/threads/*.json "$SNAP/threads/"
for d in "$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports/Retired" /Library/Logs/DiagnosticReports; do
    find "$d" -maxdepth 1 \( -iname 'scope*.ips' -o -iname 'scope*.diag' -o -iname 'pnpm-*.ips' \) -exec cp -p {} "$SNAP/crash/" \; 2>/dev/null || true
done

# `log` is shadowed in some shells: call the binary.
/usr/bin/log show --info --debug --style ndjson --predicate 'subsystem == "dev.scope.app"' --last "${DAYS}d" > "$SNAP/scope-log.ndjson"
# Everything the Scope process emitted, Apple frameworks included: the only record of app sessions (pids).
/usr/bin/log show --info --debug --style ndjson --predicate 'process == "Scope"' --last "${DAYS}d" > "$SNAP/process-log.ndjson"
echo "$SNAP"

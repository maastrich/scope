"""Reads Scope's event journal: the raw lines of logs/events-YYYY-MM.jsonl and the daily lines of logs/summary.jsonl.

    python3 -I journal.py [LOGS] [--days N] [section ...]

LOGS defaults to $SCOPE_HOME/logs, else ~/.scope/logs; a snapshot.sh copy works too (SNAP/logs). The journal holds no
names, paths or prompts, so it can be read in place. Sections: sessions, problems, recoveries, hooks, control, tasks,
gh, journal (all by default).

The raw lines are kept 30 days; older days survive only as summaries, which carry counts and per-day percentiles.
Counts below add both. Durations come from the raw lines when the window has any, and otherwise from the summaries,
as the median of the daily p50 and the highest daily p90 (marked ≈).
"""
import collections
import datetime as dt
import glob
import json
import math
import os
import sys

UTC = dt.timezone.utc


def iso(text):
    # Journal stamps are UTC without a zone: 2026-10-27T09:08:07.438
    stamp = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    return stamp.replace(tzinfo=UTC) if stamp.tzinfo is None else stamp.astimezone(UTC)


def ndjson(path):
    if not os.path.exists(path):
        return
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def pct(values, q):
    """Nearest rank, as JournalDaySummary computes it."""
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, max(0, math.ceil(q * len(values)) - 1))]


def secs(value, approx=False):
    if value is None:
        return "-"
    mark = "≈" if approx else ""
    if value < 90:
        return f"{mark}{value:.2f} s" if value < 10 else f"{mark}{value:.1f} s"
    if value < 5400:
        return f"{mark}{value / 60:.1f} min"
    return f"{mark}{value / 3600:.1f} h"


def table(rows, header):
    if not rows:
        print("(none)\n")
        return
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for row in rows:
        print("| " + " | ".join("-" if c is None else str(c) for c in row) + " |")
    print()


class Journal:
    def __init__(self, folder, days):
        self.folder = folder
        now = dt.datetime.now(UTC)
        self.since = now - dt.timedelta(days=days)
        self.events = []
        for path in sorted(glob.glob(os.path.join(folder, "events-*.jsonl"))):
            for event in ndjson(path):
                event["t"] = iso(event["at"])
                if event["t"] >= self.since:
                    self.events.append(event)
        raw_days = {e["t"].strftime("%Y-%m-%d") for e in self.events}
        start = self.since.strftime("%Y-%m-%d")
        # Summaries stand in only for the days the raw lines no longer cover.
        self.summaries = [s for s in ndjson(os.path.join(folder, "summary.jsonl"))
                          if s["day"] >= start and s["day"] not in raw_days]

    def of(self, *kinds):
        return [e for e in self.events if e["kind"] in kinds]

    def summary_counts(self, field, prefix):
        """`outcomes` / `causes` / `kinds` of the summarized days, keys starting with `prefix`."""
        counter = collections.Counter()
        for summary in self.summaries:
            for key, n in summary.get(field, {}).items():
                if key.startswith(prefix):
                    counter[key[len(prefix):]] += n
        return counter

    def summarized_names(self, kind):
        """The `name`s of `kind` the summaries timed (`control task.new` → `task.new`)."""
        return {key[len(kind) + 1:] for s in self.summaries for key in s.get("durations", {}) if key.startswith(kind + " ")}

    def durations(self, events, key):
        values = [e["seconds"] for e in events if e.get("seconds") is not None]
        if values:
            return len(values), secs(pct(values, .5)), secs(pct(values, .9))
        daily = [s["durations"][key] for s in self.summaries if key in s.get("durations", {})]
        if not daily:
            return 0, None, None
        p50 = sorted(d["p50"] for d in daily)[len(daily) // 2]
        return sum(d["count"] for d in daily), secs(p50, approx=True), secs(max(d["p90"] for d in daily), approx=True)

    def span(self):
        days = sorted({e["t"].strftime("%Y-%m-%d") for e in self.events} | {s["day"] for s in self.summaries})
        return f"{days[0]} → {days[-1]}, {len(days)} days ({len(self.summaries)} from summaries)" if days else "nothing"


def counted(journal, kind, field):
    """`field` values of `kind`, raw and summarized together."""
    counter = collections.Counter(e.get(field) or "-" for e in journal.of(kind))
    counter.update(journal.summary_counts(field + "s", kind + " "))
    return counter


# MARK: sections

def sessions(journal):
    starts = journal.of("app.start")
    stops = journal.of("app.stop")
    total = len(starts) + sum(s.get("kinds", {}).get("app.start", 0) for s in journal.summaries)
    print(f"## Launches: {total}\n")
    print("How the previous session ended: " + ", ".join(f"{k} {n}" for k, n in counted(journal, "app.start", "outcome").most_common()) + "\n")
    print("Why the app stopped: " + ", ".join(f"{k} {n}" for k, n in counted(journal, "app.stop", "cause").most_common()) + "\n")
    versions = collections.Counter(e.get("version") for e in starts)
    for summary in journal.summaries:
        versions.update(summary.get("versions", []))
    print("Versions started: " + ", ".join(f"{v} {n}" for v, n in sorted(versions.items())) + "\n")
    upgrades = [e for e in starts if e.get("previous") and e.get("previous") != e.get("version")]
    print(f"Upgrades seen at launch: {len(upgrades)} "
          f"({', '.join(sorted({e['previous'] + '→' + e['version'] for e in upgrades}))})\n")
    ended = [e for e in starts if e.get("outcome") in ("crashed", "unclean")]
    table([(e["t"].strftime("%m-%d %H:%M"), e["outcome"], e.get("previous"), secs(e.get("seconds"))) for e in ended],
          ["at", "previous session", "its version", "lasted"])
    n, p50, p90 = journal.durations(stops, "app.stop")
    print(f"Session length (clean quits): n {n}, p50 {p50}, p90 {p90}\n")


def problems(journal):
    events = journal.of("problem")
    by_site = collections.Counter((e.get("name"), e.get("template"), e.get("severity")) for e in events)
    for summary in journal.summaries:
        for top in summary.get("problems", []):
            by_site[(top["name"], top.get("template"), top.get("severity"))] += top["count"]
    print(f"## Problems: {sum(by_site.values())}\n")
    print("By severity: " + ", ".join(f"{k} {n}" for k, n in counted(journal, "problem", "severity").most_common()) + "\n")
    print("By cause: " + ", ".join(f"{k} {n}" for k, n in counted(journal, "problem", "cause").most_common()) + "\n")
    errors = sum(1 for e in events if e.get("severity") == "error")
    toasts = sum(1 for e in events if e.get("outcome") == "toast")
    print(f"Errors {errors}, of which shown as toasts {toasts} (raw days only)\n")
    table([(n, s, t, site) for (site, t, s), n in by_site.most_common(25)], ["n", "severity", "title", "site"])


def recoveries(journal):
    print("## Recoveries\n")
    for kind in ("turn.interrupted", "turn.settled"):
        print(f"{kind} by cause: " + ", ".join(f"{k} {n}" for k, n in counted(journal, kind, "cause").most_common()) + "\n")
    print("turn.resume: " + ", ".join(f"{k} {n}" for k, n in counted(journal, "turn.resume", "outcome").most_common()) + "\n")
    elsewhere = len(journal.of("permission.decided-elsewhere")) + sum(
        s.get("kinds", {}).get("permission.decided-elsewhere", 0) for s in journal.summaries)
    relaunched = sum(e.get("count") or 0 for e in journal.of("threads.relaunch"))
    print(f"Permissions decided elsewhere: {elsewhere}; threads auto-relaunched (raw days): {relaunched}\n")
    n, p50, p90 = journal.durations(journal.of("turn.interrupted"), "turn.interrupted")
    print(f"Length of interrupted turns: n {n}, p50 {p50}, p90 {p90}\n")


def hooks(journal):
    causes = counted(journal, "hook.dropped", "cause")
    print(f"## Hook messages dropped: {sum(causes.values())}\n")
    print("By cause: " + ", ".join(f"{k} {n}" for k, n in causes.most_common()) + "\n")
    print(f"Turns settled without their Stop (lost hooks): {sum(counted(journal, 'turn.settled', 'cause').values())}\n")


def control(journal):
    events = journal.of("control")
    outcomes = counted(journal, "control", "outcome")
    print(f"## Control calls: {sum(outcomes.values())}\n")
    print("Outcomes: " + ", ".join(f"{k} {n}" for k, n in outcomes.most_common()) + "\n")
    print("Refusals and errors by cause: " + ", ".join(
        f"{k} {n}" for k, n in counted(journal, "control", "cause").most_common() if k != "-") + "\n")
    rows = []
    for method in sorted({e.get("name") for e in events if e.get("name")} | journal.summarized_names("control")):
        mine = [e for e in events if e.get("name") == method]
        status = collections.Counter(e.get("outcome") for e in mine)
        n, p50, p90 = journal.durations(mine, f"control {method}")
        agents = sum(1 for e in mine if e.get("source") == "agent")
        # Per-method refusals exist only in the raw lines; a summarized day counts them by rule above.
        rate = f"{100 * status['refused'] / len(mine):.0f} %" if mine else None
        rows.append((method, n, agents if mine else None, status["refused"] if mine else None,
                     status["error"] if mine else None, rate, p50, p90))
    table(sorted(rows, key=lambda r: -r[1]), ["method", "n", "by agents", "refused", "errors", "refusal rate", "p50", "p90"])


def tasks(journal):
    print("## Task operations\n")
    rows = []
    for kind in ("task.create", "task.setup", "task.archive", "task.close", "task.gc"):
        outcomes = counted(journal, kind, "outcome")
        n, p50, p90 = journal.durations(journal.of(kind), kind)
        rows.append((kind, sum(outcomes.values()), ", ".join(f"{k} {v}" for k, v in outcomes.most_common()), p50, p90))
    table(rows, ["operation", "n", "outcomes", "p50", "p90"])
    print("Setup failures by cause: " + ", ".join(
        f"{k} {n}" for k, n in counted(journal, "task.setup", "cause").most_common() if k != "-") + "\n")


def gh(journal):
    events = journal.of("gh")
    outcomes = counted(journal, "gh", "outcome")
    print(f"## gh calls: {sum(outcomes.values())}\n")
    print("Outcomes: " + ", ".join(f"{k} {n}" for k, n in outcomes.most_common()) + "\n")
    rows = []
    for name in sorted({e.get("name") for e in events if e.get("name")} | journal.summarized_names("gh")):
        mine = [e for e in events if e.get("name") == name]
        n, p50, p90 = journal.durations(mine, f"gh {name}")
        failed = sum(1 for e in mine if e.get("outcome") != "ok") if mine else None
        rows.append((name, n, failed, p50, p90))
    table(sorted(rows, key=lambda r: -r[1]), ["command", "n", "not ok", "p50", "p90"])


def journal_section(journal):
    print(f"## The journal itself: {journal.span()}\n")
    dropped = collections.Counter()
    for e in journal.of("journal.dropped"):
        dropped[e.get("name")] += e.get("count") or 0
    print("Events dropped past the daily cap: " + (", ".join(f"{k} {n}" for k, n in dropped.items()) or "none") + "\n")
    sizes = [(os.path.basename(p), os.path.getsize(p)) for p in sorted(glob.glob(os.path.join(journal.folder, "*.jsonl")))]
    table([(name, f"{size / 1024:.0f} KB") for name, size in sizes], ["file", "size"])


SECTIONS = dict(sessions=sessions, problems=problems, recoveries=recoveries, hooks=hooks, control=control,
                tasks=tasks, gh=gh, journal=journal_section)

if __name__ == "__main__":
    args = sys.argv[1:]
    days = 7
    if "--days" in args:
        i = args.index("--days")
        days = int(args[i + 1])
        del args[i:i + 2]
    folder = args.pop(0) if args and args[0] not in SECTIONS else os.path.join(
        os.environ.get("SCOPE_HOME") or os.path.expanduser("~/.scope"), "logs")
    journal = Journal(folder, days)
    for name in args or SECTIONS:
        print(f"\n# {name}\n")
        SECTIONS[name](journal)

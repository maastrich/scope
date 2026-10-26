"""Aggregates a snapshot taken by snapshot.sh into the numbers behind docs/research/logs-2026-10.md.

    python3 -I analyze.py SNAP [section ...]

Sections: unified, sessions, crashes, tasks, threads, usage, agents (all by default).
Reads SNAP only and prints aggregates: no task or repo names, titles, prompts, paths or terminal text.
Every timestamp is normalized to UTC before it is compared.
"""
import collections
import datetime as dt
import glob
import json
import os
import re
import statistics
import sys

UTC = dt.timezone.utc


def iso(text):
    """Task/thread/history stamps end in Z; usage stamps are naive UTC; the unified log carries an offset."""
    if text is None:
        return None
    text = text.replace("Z", "+00:00")
    stamp = dt.datetime.fromisoformat(text)
    return stamp.replace(tzinfo=UTC) if stamp.tzinfo is None else stamp.astimezone(UTC)


def logtime(text):
    # 2026-10-25 22:35:13.220550+0100
    return dt.datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f%z").astimezone(UTC)


def pct(values, q):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def secs(value):
    if value is None:
        return "-"
    if value < 90:
        return f"{value:.1f} s"
    if value < 5400:
        return f"{value / 60:.1f} min"
    return f"{value / 3600:.1f} h"


def table(rows, header):
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for row in rows:
        print("| " + " | ".join(str(c) for c in row) + " |")
    print()


def ndjson(path):
    if not os.path.exists(path):
        return
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def shape(message):
    """A message with its ids, numbers and quoted parts folded, so lines of one cause count together."""
    message = re.sub(r'"[^"]*"', '"…"', message)
    message = re.sub(r"\b[0-9a-f]{12}\b", "<id>", message)
    message = re.sub(r"[0-9A-F-]{36}", "<uuid>", message)
    message = re.sub(r"\d+(\.\d+)?", "#", message)
    return message[:110]


def redact(message):
    """Scope's own lines name tasks, repositories and prompts: keep the shape of the sentence only."""
    message = re.sub(r"^(thread \S+ started pid \S+):.*", r"\1: <command>", message, flags=re.S)
    message = re.sub(r"The setup of .+? failed:.*", "The setup of <task> failed: <log tail>", message, flags=re.S)
    message = re.sub(r"\[[^\]]+\]", "[<repo>]", message)
    return shape(message)


# MARK: unified log

def unified(snap):
    print("## Unified log, subsystem dev.scope.app\n")
    rows = [e for e in ndjson(f"{snap}/scope-log.ndjson") if e.get("subsystem") == "dev.scope.app"]
    if rows:
        stamps = [logtime(e["timestamp"]) for e in rows]
        print(f"{len(rows)} entries, {min(stamps):%Y-%m-%d %H:%M}Z → {max(stamps):%Y-%m-%d %H:%M}Z\n")
    by = collections.Counter((e.get("category"), e.get("messageType"), redact(e.get("eventMessage", ""))) for e in rows)
    table([(n, c, t, m.replace("|", "/")) for (c, t, m), n in by.most_common()], ["n", "category", "level", "message"])

    print("## Everything the Scope process logged (Apple frameworks)\n")
    counts = collections.Counter()
    first = last = None
    for e in ndjson(f"{snap}/process-log.ndjson"):
        if "timestamp" not in e:
            continue
        stamp = logtime(e["timestamp"])
        first = first or stamp
        last = stamp
        counts[(e.get("subsystem") or "(none)", e.get("category") or "", e.get("messageType"))] += 1
    total = sum(counts.values())
    print(f"{total} entries, {first:%Y-%m-%d %H:%M}Z → {last:%Y-%m-%d %H:%M}Z\n")
    table([(n, f"{100 * n / total:.1f} %", s, c, t) for (s, c, t), n in counts.most_common(15)],
          ["n", "share", "subsystem", "category", "level"])

    print("### What the store kept, per level and day (local dates): the older the day, the thinner\n")
    per_day = collections.Counter()
    shapes = collections.Counter()
    cursor_hours = collections.Counter()
    for e in ndjson(f"{snap}/process-log.ndjson"):
        if "timestamp" not in e:
            continue
        per_day[(str(e.get("messageType")), e["timestamp"][5:10])] += 1
        subsystem = e.get("subsystem") or ""
        if subsystem in ("com.apple.TextInputUI", "com.apple.donotdisturb", "com.apple.GenerativeModels", "com.apple.network"):
            shapes[(subsystem, e.get("messageType"), shape(e.get("eventMessage", ""))[:90])] += 1
        if e.get("category") == "CursorUI":
            cursor_hours[logtime(e["timestamp"]).strftime("%m-%d %H:00Z")] += 1
    days = sorted({d for _, d in per_day})
    table([(level, *(per_day[(level, d)] for d in days)) for level in ("Default", "Info", "Debug", "Error", "Fault")],
          ["level", *days])
    print("### Apple framework lines the Scope process causes most\n")
    table([(n, s, t, m.replace("|", "/")) for (s, t, m), n in shapes.most_common(14)], ["n", "subsystem", "level", "message"])
    if cursor_hours:
        hour, n = cursor_hours.most_common(1)[0]
        print(f"CursorUI peak: {n} lines in the hour of {hour}\n")


# MARK: app sessions

def sessions(snap):
    print("## Scope app sessions (one pid each), from the process log\n")
    spans = {}
    for e in ndjson(f"{snap}/process-log.ndjson"):
        if "timestamp" not in e or "processID" not in e:
            continue
        stamp = logtime(e["timestamp"])
        span = spans.setdefault(e["processID"], [stamp, stamp, 0, os.path.basename(e.get("processImagePath", "")),
                                                 "/Applications/" in e.get("processImagePath", "")])
        span[0] = min(span[0], stamp)
        span[1] = max(span[1], stamp)
        span[2] += 1
    ordered = sorted(spans.items(), key=lambda kv: kv[1][0])
    # A crash belongs to the last session that started before it: the process may stay silent for minutes first.
    crashed = {}
    for stamp in sorted(t for t, name, *_ in crash_list(snap) if name == "Scope"):
        before = [pid for pid, span in ordered if span[0] <= stamp]
        if before:
            crashed[before[-1]] = stamp
    rows = []
    previous_end = None
    for pid, (start, end, n, image, installed) in ordered:
        gap = (start - previous_end).total_seconds() if previous_end else None
        ended = ""
        if pid in crashed:
            ended = f"crash {secs((crashed[pid] - end).total_seconds())} after its last line"
        elif previous_end and start < previous_end:
            ended = "second instance"
        rows.append((pid, image + ("" if installed else " (not /Applications)"), f"{start:%m-%d %H:%M:%S}",
                     f"{end:%m-%d %H:%M:%S}", secs((end - start).total_seconds()), secs(gap) if gap and gap > 0 else "-", ended))
        if not previous_end or end > previous_end:
            previous_end = end
    table(rows, ["pid", "binary", "first line (UTC)", "last line (UTC)", "lifetime", "gap since previous", "note"])


# MARK: crashes

def crash_list(snap):
    out = []
    for path in sorted(glob.glob(f"{snap}/crash/*.ips")):
        head, _, body = open(path, errors="replace").read().partition("\n")
        header = json.loads(head)
        try:
            report = json.loads(body)
        except ValueError:
            report = {}
        stamp = dt.datetime.strptime(header["timestamp"], "%Y-%m-%d %H:%M:%S.%f %z").astimezone(UTC)
        name = os.path.basename(path).rsplit("-2026", 1)[0]
        images = report.get("usedImages", [])
        frames = []
        for thread in report.get("threads", []):
            if thread.get("triggered"):
                for frame in thread.get("frames", [])[:10]:
                    symbol = frame.get("symbol")
                    index = frame.get("imageIndex")
                    image = images[index].get("name") if index is not None and index < len(images) else "?"
                    if symbol:
                        where = f"{frame['sourceFile']}:{frame['sourceLine']}" if frame.get("sourceLine") else ""
                        frames.append(f"{image}`{symbol[:70]}` {where}".strip())
        out.append((stamp, name, header.get("app_version") or "-", report.get("exception", {}).get("type"),
                    report.get("responsibleProc") or "-", frames[:3]))
    return out


def crashes(snap):
    print("## Crash reports (.ips)\n")
    rows = crash_list(snap)
    table([(f"{t:%m-%d %H:%M:%S}Z", n, v, x, r, "<br>".join(f).replace("|", "/")) for t, n, v, x, r, f in rows],
          ["when", "process", "version", "exception", "responsible", "top symbolicated frames"])
    print("## Resource reports (.diag)\n")
    rows = []
    for path in sorted(glob.glob(f"{snap}/crash/*.diag")):
        text = open(path, errors="replace").read()
        field = lambda key: (re.search(rf"^{key}:\s+(.*)$", text, re.M) or [None, "-"])[1]
        # The heaviest stack: Scope's own frames are stripped (`??? (Scope + offset)`), the system frames under them
        # still say what the work was.
        heaviest = text.split("Heaviest stack for the target process:", 1)[-1].split("Powerstats", 1)[0]
        frames = [re.sub(r"\s*\[0x[0-9a-f]+\]|\s*\+ \d+ \(.*?\)", "", line).strip()
                  for line in heaviest.splitlines() if line.strip() and "???" not in line]
        frames = [f.split(None, 1)[-1][:60] for f in frames if not f.split(None, 1)[-1].startswith(("start", "completeTask"))]
        rows.append((field("Date/Time")[:16], field("Version").split()[0], field("Event"),
                     (field("CPU") if "cpu" in field("Event") else field("Writes"))[:60],
                     " → ".join(frames[-3:]).replace("|", "/")))
    table(rows, ["when (local)", "version", "event", "detail", "deepest system frames of the heaviest stack"])


# MARK: tasks

SETUP_CAUSES = [
    ("Scope quit mid-setup", r"interrupted: Scope quit"),
    ("`uv sync` in a repo without a [project] table", r"No `project` table found"),
    ("private package index refused (401)", r"401 Unauthorized"),
    ("Node engine mismatch", r"Node version is incompatible|Unsupported engine|EBADENGINE"),
    ("package manager install", r"ERR_PNPM|npm ERR|yarn error|ELIFECYCLE"),
    ("timed out", r"timed out"),
    ("command not found", r"command not found"),
]


def tasks_list(snap):
    files = [f for f in glob.glob(f"{snap}/tasks/*.json") if os.path.basename(f).count(".") == 1]
    return [json.load(open(f)) for f in files]


def tasks(snap):
    records = tasks_list(snap)
    print(f"## Tasks: {len(records)} records, created "
          f"{min(r['createdAt'] for r in records)[:10]} → {max(r['createdAt'] for r in records)[:10]}\n")
    by_client = collections.Counter(r["createdBy"].split("/")[0] for r in records)
    print("Created by: " + ", ".join(f"{k} {v}" for k, v in by_client.most_common()))
    print("Origin author: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(
        (r.get("origin") or {}).get("author", "(none)") for r in records).most_common()))
    print("Origin depth: " + ", ".join(f"{k} {v}" for k, v in sorted(collections.Counter(
        (r.get("origin") or {}).get("depth", 0) for r in records).items())))
    print(f"With a parent task: {sum(1 for r in records if r.get('parentTask'))}")
    print("Repos per task: " + ", ".join(f"{k}: {v}" for k, v in sorted(collections.Counter(len(r['repos']) for r in records).items())))
    secondary = sum(len(repo.get("worktrees") or []) for r in records for repo in r["repos"])
    print(f"Secondary worktrees: {secondary}")
    print(f"Archived: {sum(1 for r in records if r.get('archivedAt'))}, open: {sum(1 for r in records if not r.get('archivedAt'))}")
    print(f"With pull requests: {sum(1 for r in records if r.get('pullRequests') or r.get('pullRequest'))}\n")

    print("### Setup\n")
    states = collections.Counter(r["setup"]["state"] for r in records)
    print("States: " + ", ".join(f"{k} {v}" for k, v in states.most_common()) + "\n")
    rows = []
    for state in ("succeeded", "failed"):
        durations = [(iso(r["setup"]["finishedAt"]) - iso(r["setup"]["startedAt"])).total_seconds()
                     for r in records if r["setup"]["state"] == state and r["setup"].get("finishedAt")]
        if durations:
            rows.append((state, len(durations), secs(pct(durations, .5)), secs(pct(durations, .9)), secs(max(durations))))
    table(rows, ["state", "n", "p50", "p90", "max"])
    causes = collections.Counter()
    for r in records:
        if r["setup"]["state"] != "failed":
            continue
        # The failing repository's lines are not always at the tail: a multi-repo setup goes on with the others.
        log = r["setup"].get("log", "")
        cause = next((name for name, pattern in SETUP_CAUSES if re.search(pattern, log, re.I)), "other")
        causes[(cause, r["scopeSlug"] if r["scopeSlug"] == "maastrich" else "client scope", r["createdBy"].split("/")[1])] += 1
    table([(n, c, s, v) for (c, s, v), n in causes.most_common()], ["n", "cause (from the setup log)", "scope", "client version"])
    failing_tail = sum(1 for r in records if r["setup"]["state"] == "failed"
                       and "failed: exit" not in "\n".join(r["setup"].get("log", "").splitlines()[-60:]))
    print(f"Failed setups whose last 60 lines (the problem's detail) do not hold the `failed: exit` line: {failing_tail}")
    copies = sum(1 for r in records if "did not copy" in r["setup"].get("log", ""))
    print(f"Setups that logged `did not copy` (any state): {copies}")
    unfinished = [r for r in records if not r["setup"].get("finishedAt")]
    print(f"Setups with no finishedAt: {len(unfinished)} ({', '.join(r['setup']['state'] for r in unfinished)})\n")

    print("### Lifetime (created → archived)\n")
    lifetimes = [(iso(r["archivedAt"]) - iso(r["createdAt"])).total_seconds() for r in records if r.get("archivedAt")]
    print(f"p50 {secs(pct(lifetimes, .5))}, p90 {secs(pct(lifetimes, .9))}, max {secs(max(lifetimes))}\n")
    per_day = collections.Counter(r["createdAt"][:10] for r in records)
    print("Created per day: " + ", ".join(f"{d[5:]} {n}" for d, n in sorted(per_day.items())) + "\n")

    print("### Timelines (CI checks seen by Scope)\n")
    checks = collections.Counter()
    lanes = 0
    for path in glob.glob(f"{snap}/tasks/*.timeline.json"):
        data = json.load(open(path))
        lanes += len(data.get("lanes", []))
        for check in data.get("checks", []):
            checks[check.get("state")] += 1
    print(f"{lanes} lanes; check states: " + ", ".join(f"{k} {v}" for k, v in checks.most_common()) + "\n")


# MARK: threads

def threads(snap):
    history = list(ndjson(f"{snap}/history.jsonl"))
    print(f"## History: {len(history)} entries, {history[0]['at'][:16]} → {history[-1]['at'][:16]}\n")
    print("Kinds: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(h["kind"] for h in history).items()))
    closed = [h["thread"] for h in history if h["kind"] == "thread.closed"]
    print("Closed threads by driver: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(t["driverID"] for t in closed).most_common()))
    print(f"Opened by an agent: {sum(1 for t in closed if t.get('openedByAgent'))} / {len(closed)}; in a task: "
          f"{sum(1 for t in closed if t.get('taskID'))}")
    launches = [t.get("launchCount", 0) for t in closed]
    print(f"launchCount p50 {pct(launches, .5)}, p90 {pct(launches, .9)}, max {max(launches)}; "
          f"relaunched at least once: {sum(1 for n in launches if n > 1)}")
    lifetimes = [(iso(h['at']) - iso(h['thread']['createdAt'])).total_seconds() for h in history if h["kind"] == "thread.closed"]
    print(f"Lifetime (created → closed) p50 {secs(pct(lifetimes, .5))}, p90 {secs(pct(lifetimes, .9))}\n")

    records = [json.load(open(f)) for f in glob.glob(f"{snap}/threads/*.json") if os.path.basename(f).count(".") == 1]
    print(f"## Live thread records: {len(records)}\n")
    print("lastState: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(
        json.dumps(r.get("lastState"))[:40] for r in records).most_common()))
    print("processAlive: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(r.get("processAlive") for r in records).items()))
    print("lastExit: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(
        json.dumps(r.get("lastExit"), sort_keys=True)[:60] for r in records if r.get("lastExit")).most_common()))
    print("launchCount: " + ", ".join(str(r["launchCount"]) for r in sorted(records, key=lambda r: -r["launchCount"])[:10]) + "\n")

    print("## Tool calls in activity files (last turns kept per thread)\n")
    durations = collections.defaultdict(list)
    turns = []
    for path in glob.glob(f"{snap}/threads/*.activity.json"):
        data = json.load(open(path))
        for turn in data.get("turns", []):
            if turn.get("startedAt") and turn.get("endedAt"):
                turns.append((iso(turn["endedAt"]) - iso(turn["startedAt"])).total_seconds())
            for call in turn.get("calls", []):
                if call.get("durationMs") is not None:
                    durations[call["name"] if not call["name"].startswith("mcp__") else "mcp:" + call["name"].split("__")[-1]].append(call["durationMs"] / 1000)
    rows = [(name, len(v), secs(pct(v, .5)), secs(pct(v, .9)), secs(max(v)))
            for name, v in sorted(durations.items(), key=lambda kv: -len(kv[1]))[:20]]
    table(rows, ["tool", "calls", "p50", "p90", "max"])
    waits = durations.get("mcp:scope_thread_wait", [])
    at_cap = sum(1 for v in waits if 119 <= v <= 121)
    print(f"scope_thread_wait calls ending at 120 s (± 1 s), a caller's timeout rather than a thread done: {at_cap} / {len(waits)}\n")
    outcomes = collections.Counter()
    gaps = collections.Counter()
    for path in glob.glob(f"{snap}/threads/*.activity.json"):
        kept = json.load(open(path)).get("turns", [])
        outcomes.update(t.get("outcome") for t in kept)
        # An interrupted turn is one a new prompt closed: Esc, a message queued mid-turn, or a Stop hook never seen.
        # The longer the silence before that prompt, the likelier the last.
        for turn, following in zip(kept, kept[1:]):
            if turn.get("outcome") == "interrupted":
                gap = (iso(following["startedAt"]) - iso(turn["endedAt"])).total_seconds()
                gaps["< 10 s" if gap < 10 else "< 1 min" if gap < 60 else "< 5 min" if gap < 300 else "≥ 5 min"] += 1
    print("Turn outcomes: " + ", ".join(f"{k} {v}" for k, v in outcomes.most_common()))
    print("Interrupted turn → next prompt: " + ", ".join(f"{k} {gaps[k]}" for k in ("< 10 s", "< 1 min", "< 5 min", "≥ 5 min")) + "\n")
    if turns:
        print(f"Turns: {len(turns)}, p50 {secs(pct(turns, .5))}, p90 {secs(pct(turns, .9))}, max {secs(max(turns))}\n")


# MARK: usage

def usage_events(snap):
    events = []
    for path in sorted(glob.glob(f"{snap}/usage-*.jsonl")):
        events.extend(ndjson(path))
    for event in events:
        event["t"] = iso(event["at"])
    return sorted(events, key=lambda e: e["t"])


def usage(snap):
    events = usage_events(snap)
    days = sorted({e["t"].date() for e in events})
    print(f"## Usage: {len(events)} events, {days[0]} → {days[-1]} ({len(days)} days with events)\n")
    print("Kinds: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(e["kind"] for e in events).most_common()) + "\n")

    human = [e for e in events if e["kind"] in ("click", "shortcut", "menu", "palette", "notification", "setting")]
    by_area = collections.Counter(e["id"].split(".")[0] for e in human)
    print("Human gestures by area: " + ", ".join(f"{k} {v}" for k, v in by_area.most_common()) + "\n")
    print("### Top gestures\n")
    table([(n, k, i) for (k, i), n in collections.Counter((e["kind"], e["id"]) for e in human).most_common(30)],
          ["n", "kind", "id"])

    registry = json.load(open(f"{snap}/registry.json"))["elements"]
    used = {e["id"] for e in events}
    never = collections.defaultdict(list)
    for element_id, element in registry.items():
        if element_id not in used:
            never[element["area"]].append(element_id)
    print(f"### Registered but never used: {sum(len(v) for v in never.values())} of {len(registry)}\n")
    for area, ids in sorted(never.items(), key=lambda kv: -len(kv[1])):
        print(f"- **{area}** ({len(ids)}): " + ", ".join(f"`{i}`" for i in sorted(ids)))
    print()

    print("### Views (on-screen time, active + resumed)\n")
    time_on = collections.defaultdict(float)
    opens = collections.Counter()
    for e in events:
        if e["kind"] == "view":
            time_on[e["id"]] += e.get("duration") or 0
            if e.get("context") == "active":
                opens[e["id"]] += 1
    table([(i, secs(s), opens[i]) for i, s in sorted(time_on.items(), key=lambda kv: -kv[1])[:30]],
          ["view", "time on screen", "active segments"])

    print("### Undo, cancel, close\n")
    pattern = re.compile(r"undo|cancel|dismiss|close|discard|revert", re.I)
    table([(n, k, i) for (k, i), n in collections.Counter((e["kind"], e["id"]) for e in human if pattern.search(e["id"])).most_common()],
          ["n", "kind", "id"])

    print("### Repeated paths: gesture pairs less than 5 s apart\n")
    pairs = collections.Counter()
    for a, b in zip(human, human[1:]):
        if (b["t"] - a["t"]).total_seconds() < 5:
            pairs[(a["id"], b["id"])] += 1
    table([(n, a, b) for (a, b), n in pairs.most_common(15)], ["n", "first", "then"])

    print("### Runs: the same gesture repeated within 3 s of the previous one\n")
    runs = collections.Counter()
    run = 1
    for a, b in zip(human, human[1:]):
        if a["id"] == b["id"] and (b["t"] - a["t"]).total_seconds() < 3:
            run += 1
        else:
            if run >= 3:
                runs[a["id"]] += 1
            run = 1
    print(", ".join(f"`{k}` ×{v}" for k, v in runs.most_common(10)) + "\n")

    print("### Assist (on-device model jobs)\n")
    table([(n, i, c) for (i, c), n in collections.Counter((e["id"], e.get("context")) for e in events if e["kind"] == "assist").most_common()],
          ["n", "job", "tier"])
    per_day = collections.Counter(e["t"].date() for e in events if e["kind"] == "assist")
    print("Per day: " + ", ".join(f"{d:%m-%d} {n}" for d, n in sorted(per_day.items())) + "\n")
    bursts = collections.Counter(e["t"].replace(second=0, microsecond=0) for e in events if e["kind"] == "assist")
    print(f"Busiest minute: {max(bursts.values())} assist jobs; minutes with ≥10: {sum(1 for v in bursts.values() if v >= 10)}\n")


# MARK: agents

def agents(snap):
    events = usage_events(snap)
    control = [e for e in events if e["kind"] == "control"]
    print(f"## Control calls: {len(control)}\n")
    print("By source/context: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(
        (e.get("source"), e.get("context")) for e in control).most_common()) + "\n")
    table([(n, i, s, c) for (i, s, c), n in collections.Counter(
        (e["id"], e.get("source"), e.get("context")) for e in control).most_common(40)], ["n", "method", "source", "via"])
    per_day = collections.Counter(e["t"].date() for e in control)
    print("Per day: " + ", ".join(f"{d:%m-%d} {n}" for d, n in sorted(per_day.items())) + "\n")
    # A read right after a send to poll for the answer, instead of a wait.
    reads = [e for e in control if e["id"] == "control.thread.read"]
    gaps = [(b["t"] - a["t"]).total_seconds() for a, b in zip(reads, reads[1:]) if (b["t"] - a["t"]).total_seconds() < 120]
    print(f"thread.read calls less than 2 min after the previous read: {len(gaps)} (median gap {secs(pct(gaps, .5))})\n")
    ratio = collections.Counter(e["id"] for e in control)
    print(f"send/wait/read: {ratio['control.thread.send']}/{ratio['control.thread.wait']}/{ratio['control.thread.read']}; "
          f"task.new/task.archive: {ratio['control.task.new']}/{ratio['control.task.archive']}\n")
    records = tasks_list(snap)
    mcp = [r for r in records if r["createdBy"].startswith("scope-mcp")]
    print(f"Tasks created by agents through MCP: {len(mcp)}; still open: {sum(1 for r in mcp if not r.get('archivedAt'))}\n")


SECTIONS = dict(unified=unified, sessions=sessions, crashes=crashes, tasks=tasks, threads=threads, usage=usage, agents=agents)

if __name__ == "__main__":
    snap = sys.argv[1]
    for name in sys.argv[2:] or SECTIONS:
        print(f"\n# {name}\n")
        SECTIONS[name](snap)

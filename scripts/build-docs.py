#!/usr/bin/env python3
"""Builds the GitHub Pages site in docs/ from the page bodies below.

    python3 scripts/build-docs.py

Everything the site needs is committed: docs/ is served as-is by GitHub Pages
("Deploy from a branch" → main → /docs). Only the HTML is generated; the CSS,
the JS and the screenshots under docs/assets/ are checked in by hand.
"""

from __future__ import annotations

import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs"
REPO = "https://github.com/maastrich/scope"
SITE = "https://maastrich.github.io/scope"

NAV = [
    ("Start", [
        ("index.html", "Overview"),
        ("getting-started.html", "Getting started"),
    ]),
    ("Working in Scope", [
        ("concepts.html", "Scopes, threads, drivers"),
        ("tasks.html", "Tasks and sandboxes"),
        ("review.html", "Delta, Base, pull requests"),
        ("graph.html", "The repository graph"),
    ]),
    ("Reference", [
        ("drivers.html", "Driver profiles"),
        ("cli.html", "Command line and MCP"),
        ("adapters.html", "Hooks and thread states"),
        ("reference.html", "Files, keys, updates"),
    ]),
]


# --------------------------------------------------------------------------- shell

def toc(body: str) -> str:
    items = re.findall(r'<h([23]) id="([^"]+)">(.*?)</h[23]>', body, re.S)
    if len(items) < 2:
        return ""
    links = "".join(
        '<a class="lvl{lvl}" href="#{anchor}">{label}</a>'.format(
            lvl=level, anchor=anchor, label=re.sub(r"<[^>]+>", "", label))
        for level, anchor, label in items
    )
    return f'<aside class="toc"><strong>On this page</strong>{links}</aside>'


def sidebar(current: str) -> str:
    out = []
    for group, pages in NAV:
        out.append(f"<h4>{group}</h4>")
        for href, label in pages:
            cls = ' class="active"' if href == current else ""
            out.append(f'<a{cls} href="{href}">{label}</a>')
    return '<aside class="sidebar" id="sidebar">' + "".join(out) + "</aside>"


SUN = ('<svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" '
       'stroke-linecap="round"><circle cx="12" cy="12" r="4.2"/><path d="M12 2.6v2M12 19.4v2M2.6 12h2M19.4 12h2'
       'M5.4 5.4l1.4 1.4M17.2 17.2l1.4 1.4M18.6 5.4l-1.4 1.4M6.8 17.2l-1.4 1.4"/></svg>')
MOON = ('<svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" '
        'stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.2A8.2 8.2 0 0 1 9.8 4 8.2 8.2 0 1 0 20 14.2z"/></svg>')
BURGER = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">'
          '<path d="M4 7h16M4 12h16M4 17h16"/></svg>')

TOPBAR = f"""<header class="topbar">
  <button class="icon-btn" id="menu-toggle" aria-label="Menu">{BURGER}</button>
  <a class="brand" href="index.html"><img src="assets/img/icon.png" alt=""> Scope <span class="ver">macOS 15+</span></a>
  <nav>
    <a href="getting-started.html">Docs</a>
    <a class="hide-sm" href="{REPO}/releases/latest">Download</a>
    <a class="hide-sm" href="{REPO}">GitHub</a>
    <button class="icon-btn" id="theme-toggle" aria-label="Toggle theme">{SUN}{MOON}</button>
  </nav>
</header>"""

FOOTER = f"""<footer class="footer"><div class="footer-inner">
  <span>Scope — a control room for CLI code agents.</span>
  <a href="{REPO}">Source</a>
  <a href="{REPO}/blob/main/SPEC.md">Specification</a>
  <a href="{REPO}/blob/main/LICENSE">MIT licence</a>
  <span>Every screenshot uses a throwaway demo workspace.</span>
</div></footer>"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Scope">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{site}/{slug}">
<meta property="og:image" content="{site}/assets/img/hero.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="assets/img/icon.png">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
{topbar}
{content}
{footer}
<script src="assets/docs.js"></script>
</body>
</html>
"""


def render(slug: str, title: str, description: str, body: str, wide: bool) -> str:
    if wide:
        content = body
    else:
        content = ('<div class="layout">' + sidebar(slug) + "<main>" + body + "</main>" + toc(body) + "</div>")
    return PAGE.format(title=html.escape(title), description=html.escape(description),
                       site=SITE, slug=slug, topbar=TOPBAR, content=content, footer=FOOTER)


def figure(name: str, caption: str, classes: str = "shot") -> str:
    return (f'<figure class="{classes}"><img src="assets/img/{name}.png" alt="{html.escape(caption)}" loading="lazy">'
            f"<figcaption>{caption}</figcaption></figure>")


# --------------------------------------------------------------------------- pages

HOME = """<div class="home-wrap">
<section class="hero">
  <h1>A control room for<br>CLI code agents</h1>
  <p class="lede">Scope is a native macOS workspace for running Claude Code, Codex, Cursor or a plain shell
  against your repositories — many agents at once, each in its own terminal, each on its own git worktree,
  with the diff, the history and the pull request one panel away.</p>
  <div class="btn-row">
    <a class="btn" href="REPO/releases/latest">Download for macOS</a>
    <a class="btn ghost" href="getting-started.html">Getting started</a>
  </div>
  <div class="hero-shot"><img src="assets/img/hero.png" alt="The Scope window: sidebar with threads and tasks, an embedded terminal, and the task's diff in the inspector"></div>
</section>

<h2>What it does</h2>
<p>Declare a folder as a <b>scope</b> — a cloned GitHub org, a folder of side projects, a single repository.
Scope discovers the repos inside it, and everything else hangs off that: threads, tasks, diffs, graph.
It reads your folders and writes nothing inside them.</p>

<div class="grid">
  <a class="card" href="concepts.html"><h3>Threads</h3><p>A driver running in a real PTY, with <code>SCOPE_*</code> in its environment and a live state dot on its sidebar row.</p></a>
  <a class="card" href="tasks.html"><h3>Tasks</h3><p>Describe the work in a prompt; the driver proposes the branch, and each repo gets a worktree sandbox.</p></a>
  <a class="card" href="review.html"><h3>Delta</h3><p>The diff of the task against its base, per repo — read it, commit it, push it, open the PR.</p></a>
  <a class="card" href="graph.html"><h3>Graph</h3><p>One card per repo: purpose, stack, entry points, setup and test commands, and who depends on whom.</p></a>
  <a class="card" href="adapters.html"><h3>States</h3><p>Hooks report back over a unix socket, so you can see which agent is waiting for you without looking.</p></a>
  <a class="card" href="drivers.html"><h3>Drivers</h3><p>Every tool is one JSON file. Edit the bundled ones or add your own; no rebuild.</p></a>
</div>

<h2>Run an agent where the work is</h2>
<div class="split">
  <div>
    <h3>Say what you want, not what to call it</h3>
    <p>A task starts as a prompt. The selected driver reads the repository's existing branch names, follows
    that convention and proposes a title, a branch and a folder — all three editable before you commit to them.
    No imposed <code>scope/</code> prefix.</p>
    <p><a href="tasks.html">How tasks work →</a></p>
  </div>
  FIG_NEWTASK
</div>
<div class="split rev">
  <div>
    <h3>Every task is a sandbox</h3>
    <p>One git worktree per repository, on the task branch, under <code>~/.scope/sandboxes/</code>. Your
    checkouts stay on whatever branch you left them on. The agent gets an <code>AGENTS.md</code> describing the
    goal and the repos it can touch.</p>
    <p><a href="tasks.html#sandboxes">Sandboxes →</a></p>
  </div>
  FIG_AGENT
</div>
<div class="split">
  <div>
    <h3>Read the diff without leaving</h3>
    <p>Delta shows the task branch against its merge-base, the uncommitted changes, or the branch against
    <code>origin</code> — grouped by repository, with per-file counts. Commit, push and open the pull request
    from the same panel.</p>
    <p><a href="review.html">Reviewing changes →</a></p>
  </div>
  FIG_DELTA
</div>

<h2>Install</h2>
<pre><code>curl -fsSL https://raw.githubusercontent.com/maastrich/scope/main/scripts/install.sh | bash</code></pre>
<p>Checks the DMG against its published SHA-256, installs it and clears the quarantine flag the ad-hoc
signature would otherwise trip over. Or build it yourself:</p>
<pre><code>git clone REPO.git &amp;&amp; cd scope
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   <span class="c"># once per machine</span>
make run</code></pre>
<p>Scope updates itself through Sparkle once installed. <a href="getting-started.html">Full instructions →</a></p>
</div>"""

GETTING_STARTED = """
<div class="eyebrow">Start here</div>
<h1>Getting started</h1>
<p class="lede">Install Scope, declare your first scope and open a thread. Five minutes, no configuration
file to write.</p>

<h2 id="requirements">Requirements</h2>
<ul>
  <li><b>macOS 15</b> or later, Apple silicon or Intel.</li>
  <li>The agent CLIs you intend to use, on your login shell's <code>PATH</code> —
      <code>claude</code>, <code>codex</code>, <code>cursor-agent</code>. A plain shell always works.</li>
  <li><code>git</code>. <code>gh</code> only if you want the pull request panel.</li>
</ul>

<h2 id="install">Install</h2>
<pre><code>curl -fsSL https://raw.githubusercontent.com/maastrich/scope/main/scripts/install.sh | bash</code></pre>
<p>The script takes the latest release's DMG, checks it against the SHA-256 published beside it, copies
<code>Scope.app</code> into <code>/Applications</code> and clears the quarantine flag. <code>SCOPE_VERSION</code>
and <code>SCOPE_DEST</code> change which version it installs and where.</p>
<div class="note warn"><p><b>Ad-hoc signed builds.</b> A Developer ID signature needs a paid Apple Developer
Program membership, so Gatekeeper refuses the first launch until the quarantine flag is gone — which is what
the script does for you. By hand: download <code>Scope-X.Y.Z.dmg</code> from the
<a href="REPO/releases/latest">latest release</a>, check it against the published <code>.sha256</code>, drag
Scope into <code>/Applications</code>, then run
<code>xattr -dr com.apple.quarantine /Applications/Scope.app</code> once. Read
<a href="REPO/blob/main/scripts/install.sh">the script</a> before piping it into a shell, as you would with any
such one-liner.</p></div>
<p>Later versions install themselves: Scope checks a signed Sparkle appcast and offers the update in place
(<b>Scope → Check for Updates…</b>).</p>

<h3 id="from-source">From source</h3>
<pre><code>git clone REPO.git &amp;&amp; cd scope
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   <span class="c"># SwiftTerm ships a Metal shader</span>
make run                                       <span class="c"># build + open the .app</span></code></pre>
<p><code>make build</code> leaves <code>Scope Debug.app</code> in
<code>DerivedData/Build/Products/Debug/</code> — a Debug build is a separate app with its own bundle id and its
own data in <code>~/.scope-debug</code>, so it never disturbs an installed copy. The app is
ad-hoc signed and not sandboxed — it forks PTYs and runs arbitrary binaries.</p>

<h2 id="first-scope">Declare your first scope</h2>
<p>A scope is any folder you want Scope to look after. <kbd>⌘O</kbd>, or <b>File → Declare a Scope…</b>, then
pick one of:</p>
<ul>
  <li>a folder holding several clones (a cloned GitHub org, your <code>~/Developer</code>);</li>
  <li>a single repository — Scope treats the scope itself as the repo;</li>
  <li>a monorepo — same thing, one repo, many packages.</li>
</ul>
<p>Scope walks the folder up to the discovery depth (1 by default, 0–4) and lists what it found. Nothing is
written inside your folders.</p>

FIG_SIDEBAR

<h2 id="first-thread">Open a thread</h2>
<p><kbd>⌘T</kbd> opens a thread in whatever is selected — the scope root, a repository, a task sandbox. The
default driver is the plain shell; the split button next to it picks another. The thread is a real terminal:
your shell, your prompt, your colours, plus a handful of <code>SCOPE_*</code> variables so hooks can report
back.</p>
<p>Threads survive a restart. The ones that were running when Scope quit, updated or crashed start again on
their own when it reopens — picking the driver's previous session back up when a hook captured its id, in the
same directory otherwise. The thread the window opens on goes first; the others follow a moment apart. Hold
<kbd>⇧</kbd> while Scope opens to skip that once, turn it off in Settings → Threads, or untick <b>Relaunch When
Scope Opens</b> in one thread's menu. A thread whose task was closed or whose folder is gone stays stopped, and
its banner says why. <b>Relaunch</b> brings any stopped thread back; <b>Start Fresh</b> opens a new session
instead.</p>
<p>An agent that was in the middle of a turn when Scope went down does not sit at its prompt afterwards: once
it is back and ready, Scope tells it — in a message signed as Scope's own — when it was interrupted and asks it
to continue from where the worktree stands, check <code>git status</code> and <code>git log</code>, re-read its
plan and finish. Once per interruption, never for a shell, and not if you type into the thread first; the
sidebar caption says <i>Resuming after restart…</i> meanwhile. <b>Ask agents to continue after a restart</b> in
Settings → Threads turns it off; <kbd>⇧</kbd> at launch skips it along with the relaunch.</p>

<h2 id="first-task">Create your first task</h2>
<p><kbd>⇧⌘T</kbd>. Describe the work in a sentence, pick the repositories it touches, press <b>Continue</b>.
The driver proposes a branch that matches the conventions already in the repo; <b>Create</b> makes one worktree
per repository and opens the first thread with your prompt already sent.</p>
FIG_NEWTASK
<p>From there, <a href="review.html">Delta</a> shows what the agent changed, and <b>Commit… → Push → Create PR</b>
finishes the job.</p>

<h2 id="whats-next">What next</h2>
<div class="grid">
  <a class="card" href="concepts.html"><h3>The vocabulary</h3><p>Scopes, repositories, threads, drivers and the state dots.</p></a>
  <a class="card" href="tasks.html"><h3>Tasks</h3><p>Prompt-driven branches, sandboxes, AGENTS.md, archiving.</p></a>
  <a class="card" href="drivers.html"><h3>Add a driver</h3><p>Any CLI becomes a driver with one JSON file.</p></a>
</div>
"""

CONCEPTS = """
<div class="eyebrow">Concepts</div>
<h1>Scopes, threads, drivers</h1>
<p class="lede">Five nouns carry the whole app. Learn them once and every panel makes sense.</p>

<h2 id="scope">Scope</h2>
<p>A folder you declared. It is the unit of everything: the sidebar shows one scope at a time, tasks belong to
a scope, the graph is cached per scope. A scope has a <b>name</b>, a <b>slug</b> (unique, used for file names)
and a <b>discovery depth</b>.</p>
<p>Scopes may nest — declaring <code>~/Developer</code> and <code>~/Developer/acme</code> both is allowed; each
keeps its own tasks and graph.</p>

<h2 id="repository">Repository</h2>
<p>A git repository found inside the scope. Scope reads it — HEAD, default branch, remotes, status — and never
writes to it, except when you explicitly commit, push or pull from a panel. A repository row shows the repo
name; the owner appears in the tooltip.</p>

<h2 id="thread">Thread</h2>
<p>A driver running in an embedded terminal (a real PTY, via SwiftTerm), with a working directory, a title and a
persisted record. Threads are listed in the sidebar and switched from there; <kbd>⌘1</kbd>–<kbd>⌘9</kbd> jump to one
in sidebar order, <kbd>⇧⌘[</kbd>/<kbd>⇧⌘]</kbd> cycle.</p>
<p>Each thread receives:</p>
<table>
  <tr><th>Variable</th><th>Value</th></tr>
  <tr><td><code>SCOPE_THREAD</code></td><td>12-hex thread id, also the record file name</td></tr>
  <tr><td><code>SCOPE_SCOPE</code></td><td>the scope's slug</td></tr>
  <tr><td><code>SCOPE_SCOPE_ROOT</code></td><td>absolute path of the scope folder</td></tr>
  <tr><td><code>SCOPE_HOME</code></td><td><code>~/.scope</code>, or wherever you pointed it</td></tr>
  <tr><td><code>SCOPE_SOCK</code></td><td>unix socket the hooks report to</td></tr>
  <tr><td><code>SCOPE_TASK</code>, <code>SCOPE_TASK_ROOT</code></td><td>only in a task thread: its slug and root</td></tr>
  <tr><td><code>SCOPE_PORT</code></td><td>only in a task thread: the first of the task's ten ports</td></tr>
</table>
<p>Stopping a thread (<kbd>⌘.</kbd>) leaves its row greyed with an exit toast for ten seconds — long enough to
relaunch or read the status. Turn on <b>Close exited threads</b> in Settings to have them disappear instead;
<kbd>⌘Z</kbd> or <kbd>⇧⌘T</kbd> undoes a close for thirty seconds, Edit ▸ Undo for five minutes. A stopped thread stays stopped across a restart; only the ones still running
when Scope went down come back on their own (<b>Relaunch running threads when Scope opens</b>, same section),
and an agent brought back mid-turn is asked to continue its work (<b>Ask agents to continue after a restart</b>).</p>

<h3 id="closing">Closing a thread, without regret</h3>
<p>Nothing destructive sits under the pointer in the sidebar: a row's hover controls are <b>Open in Editor</b>
(tasks) and a <b>…</b> menu, and <b>Close Thread</b>, <b>Archive</b> and <b>Close Task</b> live in that menu, in
the context menu, in the menu bar (<kbd>⌘W</kbd>, Thread ▸ Task) and in the palette. Scope asks before closing
or archiving only when something would be lost — an agent in the middle of a turn, a shell with a process still
running, uncommitted changes, an open pull request (<b>Ask before closing a thread mid-turn or archiving a task
with work in progress</b> in Settings, one switch for both) — and <b>Cancel</b> is the default button, so a
Return typed for the terminal confirms nothing. A quiet thread or a finished, merged task goes in one click.</p>
<p>Either way it can be taken back for five minutes: a toast says <i>“Title” closed — Reopen</i> or <i>“Name”
archived — Undo</i> for ten seconds (naming the agent when one asked over <code>scope thread close</code> or
<code>scope_task_archive</code>), and <b>Edit ▸ Undo</b> or the palette do the same afterwards. <kbd>⌘Z</kbd> and
<kbd>⇧⌘T</kbd> (the last thread) work for thirty seconds after a close or archive of your own; an agent's is
never on a shortcut, so a <kbd>⌘Z</kbd> typed in a text field stays a text undo. A reopened thread picks its driver session back up when the profile knows how; a restored task comes
back with its sandboxes and its changes. Closing a task for good has no undo, which is why it stands behind the
same question.</p>

<h3 id="residents">Orchestrator and terminal</h3>
<p>Every scope keeps two threads at its root that you never open yourself: an <b>Orchestrator</b> — an agent to
drive the scope from, open tasks and talk to the other threads — and a <b>Terminal</b>, a shell to check or try
something by hand. They sit at the top of the sidebar (<kbd>⌘1</kbd> and <kbd>⌘2</kbd>), outside
<b>Loose threads</b>, in both arrangements.</p>
<ul>
  <li>They cannot be closed — no close button, <kbd>⌘W</kbd> only beeps, <code>scope thread close</code> refuses.
  They go only when their scope is removed.</li>
  <li><kbd>⌘.</kbd> stops one, and it stays stopped until <b>Relaunch</b> or until Scope opens again; hold
  <kbd>⇧</kbd> while Scope opens to keep it stopped then too.</li>
  <li>A process that ends on its own starts again within a second: a crash resumes the driver session, an
  <code>exit</code> gets a new one. Three exits in a row within ten seconds of starting, or a command that cannot
  run, and Scope stops trying and says so.</li>
  <li>They start when their scope is first shown, not all at launch; a message sent to one starts it too.
  <kbd>⇧</kbd> held while Scope opens leaves them stopped.</li>
  <li>The orchestrator's driver is <b>Settings ▸ General ▸ Threads ▸ Orchestrator driver</b>: automatic picks your default
  driver, else the first agent installed.</li>
</ul>

<h3 id="topics">Topics</h3>
<p>Tasks that belong to one piece of work can share a <b>topic</b>: in the tree arrangement they sit under one
row named after it, where the first of them stands, with the count and the most urgent state of their threads.
Agents set it — <code>scope task new --topic</code>, and a task created from inside a task inherits its topic —
and so can you: <b>Topic</b> in a task's menu files it under a topic in use, a new one, or none, at any point in
its life — branch, worktrees and running threads are left alone. The tasks it started come along while they still
share its old topic; one filed elsewhere stays. The topic's own menu renames it, ungroups its tasks or archives them
all. By state, tasks sit with what they are doing and the
topic shows in the hover card, with the task an agent created it from.</p>

<h3 id="attempts">Several attempts at one brief</h3>
<p>When the best approach is uncertain, run the brief more than once. The <b>Attempts</b> stepper of the New Task
sheet, <code>scope task new … --attempts 3</code> or the MCP argument <code>attempts</code> create that many sibling
tasks under one topic named after the title — <i>Refresh tokens · attempt 1</i>, <i>2</i>, <i>3</i> — with the same
brief, a branch each (<code>feat/refresh-a1</code>…), a thread each, and a model or driver of their own when
<code>--models</code> / <code>--drivers</code> say so (one value applies to all, or one per attempt). An agent's
attempts all count against its task budget: the call is refused with the number when N exceeds what is left.</p>
<p><b>Compare attempts…</b> in the topic's menu (or the palette) opens one column per attempt: status, tokens, agent
time, files changed (+N −M), what the last reply says about tests, and the opening of its deliverable — the report
file, or the last answer. Under the columns, the diff of one attempt against another (their branches, as
committed) or against the base (the task delta, uncommitted work included), drawn by the same renderer as the Delta
column. <kbd>1</kbd>…<kbd>N</kbd> put an attempt on the left, <kbd>⇧1</kbd>…<kbd>⇧N</kbd> on the right,
<kbd>0</kbd> the base; a click or a ⇧click on a column does the same. The diff's file list can copy a file from one
attempt into another (<b>Copy into…</b>): the target is checkpointed first, so
nothing is lost to the copy.</p>
<p><b>Keep this one</b> is the end of it: the chosen task takes the brief's name and the plain branch back
(<code>feat/refresh</code>, its upstream dropped so the next push names where it goes), leaves the topic, and the
other attempts are archived — branches kept, answers kept, a restore away. The Inbox says so once, naming the branches
that were kept. Attempts are worth their cost for high-uncertainty briefs; the skill says as much to the orchestrators.</p>

<h3 id="delegation">Tasks started from a task</h3>
<p>A task an agent creates from inside another task is not nested under it — the two usually share a topic, which
already keeps them together. In the tree, with detailed rows, a quiet child's second line starts with <b>from</b> and
the parent's name: click it to select the parent. While one of its agents works or waits, that line is the agent's. The parent's hover card lists the tasks started from it, and the context menu
goes either way (<b>Go to Parent Task</b>, <b>Tasks Started From Here</b>).</p>

<h3 id="activity">What each agent is doing</h3>
<p>With detailed rows, a thread's second line says what its agent is doing as soon as its driver reports it:</p>
<ul>
  <li>while it works, the tool it just ran, in words — <i>Editing TaskTopic.swift</i>, <i>Running swift test</i>,
  <i>Searching "topic"</i>, <i>Fetching docs.github.com</i>. A path is cut to its file name; hover the row for the
  whole of it.</li>
  <li>while it waits, what it asks: the question itself, or <i>Asks to run swift test</i> for a permission when the driver names the tool. Claude Code's permission notification names none, so its permission waits read <i>Waiting for your permission</i>.</li>
  <li>once its turn is over, how and when: <i>Finished · 3m ago</i>, <i>Failed (rate_limit) · 1h ago</i>,
  <i>Interrupted</i>. <b>Settings ▸ Sidebar ▸ Finished threads</b> can show the first line of its reply instead.</li>
</ul>
<p>A task with a single thread says the same while its agent works, waits or has a result you have not read; after
that its own status (its pull request, its checks) takes the line back. The toolbar under the thread's path says what
the agent is doing while it works or waits. Compact rows — the default — stay one line, except a task that is waiting
for you or working: it takes the second line for as long as that lasts.</p>

<h2 id="states">States</h2>
<p>The dot on a sidebar row, the pill in the toolbar and the Dock badge all say the same thing:</p>
<ul>
  <li><span class="dot running"></span><b>Running</b> — the agent is working.</li>
  <li><span class="dot waiting"></span><b>Waiting</b> — it asked you something: a prompt, a permission.</li>
  <li><span class="dot idle"></span><b>Idle</b> — alive, nothing in flight.</li>
  <li><span class="dot done"></span><b>Done</b> — the turn ended.</li>
</ul>
<p>A task row carries the same dot — the most urgent of its threads — and nothing in front of its name: no driver
icon on a thread row, no status glyph on a task row, since the terminal on the right says which driver runs and the
group the row sits in says what state it is in. The task's status glyph lives on in its hover card: the most pressing
thing about the task, picked in this order — waiting on you, running, setup running, setup failed, done, conflicts,
checks failing, checks running, checks passed, draft pull request, pull request open, changed, clean. The end of the
row is one mark: the state dot of its threads, or a <code>merged</code> chip once its pull requests have landed. The <code>+N −M</code> counts live in the hover card and
the inspector, not in the row, so the name keeps the width; rest the pointer on the row for the branch, the
repositories, the pull request and its checks, the counts, the age and the prompt. A task with a single thread is a
single row — selecting it shows that thread's terminal — and its threads only appear nested from the second one on,
along a thin rule hanging from the task's chevron.</p>
<p>Rows are arranged <b>by state</b> by default — <i>Needs you</i>, <i>Working</i>, <i>Finished, not read</i>,
<i>Quiet</i>, <i>Dormant</i>, each header with its count, empty groups skipped — so what wants you is at the top.
<kbd>⌃⌘G</kbd> (or <b>Settings ▸ Sidebar ▸ Arrange</b>) switches to the tree, where tasks keep their order and sit
under their topic; <kbd>⌃⌘L</kbd> switches between compact and detailed rows. A choice already saved is kept
across updates: only a fresh install starts by state with compact rows.</p>
<p><b>Mark as Read</b> (<kbd>⇧⌘U</kbd>, or the thread's context menu) clears a waiting thread's attention once
you have seen it: the mark, the badge and the notification go. The next question it asks brings them back.</p>
<p><b>Since your last visit.</b> Coming back to a scope — switching to it, or bringing the app back after 20
minutes away — shows a line under the scope's header when something moved while you looked elsewhere:
<i>Since 11:40 — 1 question for you · checks failing on api-cache · PR merged on token-refresh · 2 turns
finished</i>. What waits on you comes first, at most four items. Each one shows the thread or task it names (an
archived task opens its pull request); the line goes at your first click, after ten seconds on screen, or with its
×. Nothing moved, nothing shown. Settings ▸ General turns it off and sets the delay.</p>
<p>States come from the driver's own hooks, not from guessing at terminal output. See
<a href="adapters.html">hooks and thread states</a>.</p>

<h2 id="driver">Driver</h2>
<p>How Scope starts a tool: a JSON profile with a command, arguments, environment and optional argv templates
for resuming a session, running headless, or passing an initial prompt. Four are bundled — Shell, Claude Code,
Codex CLI, Cursor CLI — and copied into <code>~/.scope/drivers/</code> on first run, where you can edit them.</p>
FIG_SETTINGS
<p><a href="drivers.html">The full profile format →</a></p>

<h2 id="task">Task</h2>
<p>A named unit of work with a branch and one git worktree per repository it touches. Threads opened inside a
task run in its sandbox. <a href="tasks.html">Tasks and sandboxes →</a></p>

<h2 id="inspector">The inspector</h2>
<p>The right-hand panel, all about the selection. A band at the top names the task and carries the <b>pane
strip</b> — Overview, Details, Changes (badge: changed files), Shell, Browser, Pull requests (badge: failing checks),
Files, and <code>⋮</code> for the Cards menu — then a column of cards, one header each: closed, a card costs one line and its header still says
the essential at its right; open, it shows the rest. Each card answers one question and says one thing per line: a
glyph, a name, a value. Several can be open at once — the lists share the height, and you drag the gap between two of
them (double-click it to even them out). The cards hold lists only: a diff or a base file opens in a reading column
between the terminal and the inspector, the height of the window and half the terminal's width by default (drag its
edge, double-click it to go back to half; ✕ or Esc closes it). A button of the strip opens its card <i>and</i> its
pane when it has one, turning to the page the card is on; Overview goes back to its page and closes the pane.</p>
<p>The cards sit on two pages. <b>Overview</b> says what is happening: Plan, Changes, Pull requests, Subagents,
Background and Artifacts, each only while it has something to say — a plan, changed files, a linked pull request, a
sub-agent at work, a background command or a cron, a report, a file written or a page published (checkpoints alone do
not count) — always in that order. <b>Details</b> (<kbd>⇧⌘D</kbd>, the ⓘ button) holds what you go and look up:
Environment, Context, Connectors, the Overview cards while they are empty, then Repository, Files, Search and History.
A card coming up or going down fades in place (no motion under Reduce Motion). One that goes quiet stays on Overview
for three minutes with its final state — <i>finished 2m ago</i>, <code>4 done</code> — before it goes down, and one you
left open stays until you fold it or change task. When a card went down while you were elsewhere, the Details button
carries a small dot until you open it. Alone on Overview, Changes takes the whole height; a quiet task says <i>Nothing
happening yet</i> with a link to Details.</p>
<p>The same column holds the task's <b>Shell</b> pane (<kbd>⌃`</kbd>, or <i>Shell</i> in the Task menu and the
palette): your login shell in the task's working directory, with the <code>SCOPE_*</code> variables a thread gets —
<code>SCOPE_TASK</code>, <code>SCOPE_TASK_ROOT</code>, <code>SCOPE_PORT</code>, <code>SCOPE_HOME</code>, <code>SCOPE_SOCK</code> — so
<code>scope</code> and your scripts see the task. It is not a thread: nothing in the sidebar, nothing on disk. Tabs hold
several shells (<b>+</b> opens one, ✕ closes it; a tab says the running command when the terminal reports it, else
the shell's name) and the footer says what was injected. <kbd>⌃`</kbd> shows and hides the pane; <kbd>⌘D</kbd> puts the
diff over it and <kbd>⌃`</kbd> brings it back. Hiding the pane leaves its shells running; closing a tab, archiving or
closing the task hangs them up.</p>
<p>Beside it, the task's <b>Browser</b> pane (<kbd>⌃⇧B</kbd>, the globe of the strip, or <i>Browser</i> in the Task
menu and the palette) shows what the task serves: a web view on the dev server of the sandbox, next to its terminal.
A port chip opens it, and so does a <kbd>⌘</kbd>-click on <code>http://localhost:$SCOPE_PORT</code> in a thread or a
shell, or a link in a reply. One tab per server — a link to a server a tab already shows navigates that tab; a page
that opens a window opens a tab. The address bar takes a URL, <code>localhost:3000</code> or just <code>:41001</code>;
back, forward and reload sit beside it, and <kbd>⌘L</kbd>, <kbd>⌘R</kbd>, <kbd>⌘[</kbd> and <kbd>⌘]</kbd> work while
the page has the keyboard. The pages are inspectable: Safari ▸ Develop ▸ this Mac lists them, with the Web Inspector's
console and network. Their cookies and storage go to a data store of the scope's own, kept between launches, apart
from Safari's and from anything an agent uses. Which links come here is <i>Settings › General › Browser</i>: any
<code>localhost</code> by default, while the rest of the web goes to your default browser, where you are signed in;
<kbd>⌥</kbd>-click sends a link to the other one. Hiding the pane keeps the pages; closing a tab, archiving or closing
the task tears them down. The footer's <b>Console</b> shows what the page logged, errors counted in red.</p>
<p>The task's agents have a browser of their own: <code>scope_browser_open</code>, <code>_read</code>,
<code>_screenshot</code> and <code>_console</code> (or <code>scope browser …</code> from a thread) drive an <b>agent tab</b> on a
data store of the task's own — none of your cookies, none of your tabs — removed with the task. It works behind your
back: nothing changes on screen until you open the pane, where the agent's tab sits beside yours, outlined in violet
under a band naming the thread and its last action. An agent drives the browser of its own task only. <i>Open</i>
without a URL goes to the task's first server: a port of its block something listens on, else another port its
processes serve (5173 without <code>--port $SCOPE_PORT</code>), else what <code>.claude/launch.json</code> declares.
<i>Read</i> hands back the page's text and its interactive elements with refs, read where the page's scripts cannot
interfere, framed as <code>&lt;untrusted-page&gt;</code> with hidden text marked; <i>screenshot</i> writes a JPEG
(1280 px wide at most) under <code>SCOPE_HOME/browser/shots/</code> and the agent gets the image itself;
<i>console</i> gives what was logged since its last look.</p>
<p>They act too: <code>scope_browser_click</code> on a ref, <code>scope_browser_type</code> into a field (and
<code>submit</code> its form), <code>scope_browser_wait</code> for a selector, a text or a quiet page,
<code>scope_browser_network</code> for the requests (with a status for fetch and XHR only — WebKit gives none for the
rest). Clicks go through the page's DOM, so what needs a real gesture of yours — a popup, a file picker, the
clipboard — does not happen. <b>Settings ▸ Automation ▸ Browser</b> says whether acting needs your approval (reading
never does), where agents may browse — the task's ports, localhost, or anywhere, the default — and which sites are
blocked; WebKit enforces it on every page and every request of the agent's tab. When an agent's page goes outside
localhost, a card says so, with <i>Block … for This Task</i>; nothing waits on you. <b>Stop</b> in the agent's band
(<kbd>Esc</kbd> while it works) ends its running call and refuses the next ones until you let it continue; the
footer's <i>Actions</i> lists everything it did. Downloads land under <code>SCOPE_HOME/browser/downloads/</code>.</p>
<p><b>Before and after.</b> Add the base branch beside the task (<code>scope task branch add base-main --from main</code>)
and start its dev server on another port of the block; the pane's <b>Compare</b> button — or
<code>scope_browser_compare</code> for the agent — captures the same route on both servers at one 1280×800 viewport and
shows them side by side, the regions that differ outlined, with how many and what share of the page. Scope tells which
worktree serves which port from the directory of the process listening on it.</p>
<table>
  <tr><th>Card</th><th>Closed, the header says</th><th>Open, it shows</th><th>Key</th></tr>
  <tr><td><b>Environment</b></td><td>the branch, commits ahead, the base's lag, a setup running or failed</td><td>where the branch forked, one row per worktree with its state and <code>+N −M</code>, the setup command with its state as a chip (running with the seconds ticking, ✓ or ✗ with the duration; click for the log), the task's port block with the ports something listens on and one line per listening process (command line, the thread it came from or its pid), then the disk and the agent time; Add Branch, Copy name, Open in Editor and Reveal on hover</td><td></td></tr>
  <tr><td><b>Plan</b></td><td><code>3/7 steps</code> and the step the agent is on, or <i>no plan yet</i></td><td>what the agent means to do, live: one block per thread that has a plan, its title, then one row per step — an empty circle pending, a dotted one in the accent colour with the agent's <i>Running the tests</i> while it runs, a green check once done, struck; long lists fold after eight rows. A mission task lists its milestones first, the current one open on the steps of the thread doing it. Read from the hooks (<a href="adapters.html#claude">Claude Code hooks</a>); the sidebar caption ends with <i>· 3/7 steps</i> while steps remain</td><td></td></tr>
  <tr><td><b>Changes</b></td><td><code>+N −M</code></td><td>the changed files of the task, the working tree, or the branch vs <code>origin</code></td><td><kbd>⌘D</kbd></td></tr>
  <tr><td><b>Pull requests</b></td><td>its number and the checks — or <i>2 PRs · 1 merged · 1 checks failing</i> when the task has several</td><td>one compact row per pull request — state glyph, title, then <code>repo #n · +a −d · ✗ 1 / 4 · review</code> — the one you pick in full with every one of its checks, and at the foot what it asks of you (<i>Ready to merge</i>, <i>2 checks failing</i>, <i>Conflicts with the base</i>) with <b>Ask the agent</b>: the conflicts, the failing log or the merge go to the thread as a sentence</td><td></td></tr>
  <tr><td><b>Artifacts</b></td><td><code>REPORT.md · 3 files · 1 page</code>, else how many checkpoints, else <i>nothing yet</i></td><td>the <b>Report</b> (<code>REPORT.md</code> or the declared deliverable: age, <code>+N</code> since the last checkpoint, a Markdown preview of its opening, <b>Read</b>); <b>Files written this task · outside the repo diff</b> (every <code>Write</code>/<code>Edit</code> target and <code>&gt;</code> redirection the hooks reported that git does not track: outside the worktrees, in an ignored folder, or a binary — newest first, with turn and size, the newest image as a thumbnail, a vanished file dimmed as <i>gone</i>; a click opens it in the reading column); <b>Published</b> (the <code>https://</code> links in the threads' answers: claude.ai artifacts, GitHub PRs, issues and commits, other pages — a click opens the browser); the <b>Checkpoints</b>: time, thread, first words, <code>+N −M</code>, with <b>Show diff</b>, <b>Restore files</b> and <b>Branch from here</b> on hover. The card reads: it never copies, moves or deletes a file</td><td></td></tr>
  <tr><td><b>Context</b></td><td>the model of the task's thread and how full its context window is (<code>Fable 5.1 · 38 %</code>), else how long the brief is</td><td>the brief (four lines, <b>Read in full</b> for the rest, the topic as a chip), the mission checklist; <b>Given to the agent</b>: one line per context file where the threads start — the ones Scope wrote under each name the installed drivers read, and the repository's own — with its size, a click reading it in the reading column, then the skills the sandboxes hold (<code>.claude/skills</code>) as chips; <b>Model</b>: the model and the driver's version, a context gauge with its percentage when the driver reports one (Claude Code's status line does, relayed by <code>scope-hook statusline</code>), and under it what the task's threads consumed — tokens read, written, share from the cache; and the task's timeline: agent time, time waiting on you and elapsed time, then one lane per thread with its turns as bars, the waits between them tinted (answer, permission, unread result), failed turns in red, and the task's events as ticks (created, PR opened, checks red or green, merged, archived); quiet hours fold into a labelled break; hover a bar for when, how long, how it ended and the first words of the reply; a turn that left a checkpoint has a dot under its bar</td><td></td></tr>
  <tr><td><b>Connectors</b></td><td>how many MCP servers and how many are in trouble (<code>3 · 1 needs auth</code>, <code>4 · 2 failed</code>), else <i>none</i></td><td>hidden by default — the <b>Cards</b> menu brings it in. The MCP servers of the task's live Claude Code threads, trouble first: name, source and transport, tool and call counts, and the state — connected when its tools were listed or called, connecting, failed with its error code (the message on hover), <i>not reported</i> when Claude Code said nothing, or a <b>re-authenticate</b> chip that sends nothing and brings the thread forward for <code>/mcp</code>. One group per thread when the threads disagree, folded past ten rows behind <b>Show all N</b>. Read from Claude Code's transcript and configuration, never edited by Scope; other drivers report no servers</td><td></td></tr>
  <tr><td><b>Repository</b></td><td>the branch and how far behind it is</td><td>the HEAD commit of the untouched checkout</td><td><kbd>⇧⌘B</kbd></td></tr>
  <tr><td><b>Files</b>, <b>Search</b>, <b>History</b></td><td>the file count, the last query, the HEAD commit</td><td>the base's tree, a search across it, its recent commits</td><td></td></tr>
</table>
<p>The Cards menu sets, card by card, <b>When it has something</b> (<b>In Details</b> for the reference cards),
<b>Always in Overview</b> — pinned, even empty; a pinned Environment goes first — or <b>Hidden</b>. The inspector
remembers that choice and which cards are open per scope, the open ones with and without a task (the last visible card
cannot be hidden; <b>Reset to defaults</b> brings them all back, and <kbd>⌘D</kbd> on a hidden Changes shows it again).
Without a task there is one page, the base checkout's cards, and Repository follows the selected repository. Drag the panel's left edge to resize — every divider in the window catches the pointer a few points on
either side of the line, and a double-click puts the column back at its default width; <kbd>⌥⌘I</kbd> hides it.</p>

<h2 id="global-views">Inbox, Pull Requests and Graph</h2>
<p>The views of the whole scope open from the buttons under the scope name in the sidebar, as a sheet over
the window: <b>Inbox</b> (<kbd>⇧⌘I</kbd>) lists what needs you, in every scope; <b>Pull Requests</b>
(<kbd>⇧⌘P</kbd>) lists the open pull requests of a repository through <code>gh</code>; <b>Graph</b>
(<kbd>⌥⌘G</kbd>) shows one card per repository.</p>

<h2 id="inbox">Inbox</h2>
<p>One list of what needs the owner, across every scope: threads waiting for an answer or a permission (with the
question), turns that finished while you were not looking (the first line of the reply), turns that failed (the
error), tasks whose pull request is ready to merge or has a failing check, and tasks archived when their pull
request merged (kept three days, with <b>Restore</b>), and the runs of <a href="cli.html#schedules">scheduled
prompts</a> — <i>Schedule &lt;name&gt; ran</i>, with the first line of the reply (kept three days, or until marked
read). Items are grouped by scope, the scope with the newest news
first, each with its state, its task and its age. The sidebar button carries the count; it turns to the waiting
colour while a thread is blocked on you.</p>
<p>Every action is in place, without moving the selection or the terminal on screen: <b>Reply</b> opens a field
under the item and sends the way the sidebar's reply does; <b>Open</b> reveals the thread or the task;
<b>Mark as Read</b> clears a thread item, and dismisses a pull request item until the pull request changes;
<b>Archive Task</b>, <b>Open Pull Request in Browser</b> and <b>Send the failing checks to the thread</b> do what
the inspector does. Keys: <kbd>j</kbd>/<kbd>k</kbd> move, <kbd>↩</kbd> open, <kbd>r</kbd> reply, <kbd>e</kbd> mark
read, <kbd>a</kbd> archive, <kbd>o</kbd> open the pull request, <kbd>s</kbd> send the checks, <kbd>v</kbd> read a
schedule's reply; the foot of the sheet shows the keys of the selected item.</p>
<p>The menu bar item is the same list, compact, with Reply and Open on each item — so an answer can go out
without bringing the window up. Its <b>Ask Orchestrator…</b> entry opens the <a href="#quick-panel">quick panel</a>.</p>

<h2 id="quick-panel">The quick panel, from anywhere</h2>
<p>A system-wide shortcut — <kbd>⌥Space</kbd> by default, changed with the recorder in Settings › General ›
Anywhere — opens a small floating panel over whatever app is in front, without activating Scope, centred on the
screen the pointer is on. It has two tabs. <b>Ask</b> is a field addressed to a scope's orchestrator — the current
scope unless a tile or <kbd>⌃1</kbd>…<kbd>⌃9</kbd> picks another — sent the way <b>Ask Orchestrator…</b> sends:
<kbd>↩</kbd> sends, <kbd>⇧↩</kbd> starts a new line, <kbd>Esc</kbd> closes. <b>Inbox</b> is the same list as the
sheet, questions and permissions first, with Reply and Open in place and <kbd>j</kbd>/<kbd>k</kbd>, <kbd>r</kbd>,
<kbd>e</kbd>, <kbd>↩</kbd>; <kbd>⇧⌘I</kbd> opens the full sheet. The panel opens on Inbox while a thread waits for
you and on Ask otherwise (a setting pins one or the other). A click anywhere else closes it.</p>
<p>A second shortcut, <kbd>⌥⇧Space</kbd> by default, brings the window up — or hides Scope when it is already
what you are looking at. Both shortcuts need no permission: they are registered with the system, not read from
other apps. macOS does not say when another app holds the same chord; if a press never reaches Scope, pick another
one in Settings.</p>

<h2 id="island">The island under the notch</h2>
<p>At the top of the screen the island says what the Claude Code threads are doing. It is black in light and dark
alike: on a screen without a notch, a small capsule hanging from the top edge, a little shorter than the menu bar —
a coloured dot per thread (green running, orange waiting for you, blue finished unread, red failed; waiting is a
square and failed a diamond, so the dots read without their colour), the count (<i>3 threads</i>) and a ring for the
5-hour limit, orange from 80&nbsp;%. Around a notch nothing is drawn under the notch itself: the dots sit in a black wing
on its left, the count and the ring in one on its right, and the black runs on from the notch. It shows only while a
thread works, waits or finished unread. Rest the pointer on it (or click it, a setting) and a card opens under it:
the requests waiting for you first, then the threads by task, each with what it is doing and for how long — with its
todo list under the row you rest on, or under the thread selected in Scope — and the 5-hour and weekly limits with
their reset at the foot. A thread that says it is running but has not been heard from for ten minutes says so, rather
than look busy.</p>
<p>From there, <b>Allow</b> or <b>Deny</b> a permission, pick a question's option, or <b>Open</b> the thread in Scope.
Allow is offered only when the island shows the whole command; a plan, a form or a multiple choice opens the thread.
The answer is typed only if the terminal shows that very dialog, as from the request card. Nothing on the island
stops, closes or archives anything.</p>
<p>When a thread asks something — a permission, a question, a plan — the island widens on its own (around a notch, it
grows down from it) to show which thread, the command and its buttons, and stays so until the request is answered,
from the island or anywhere else; then it folds back. A turn that ends or fails widens it for five seconds. Either can
play a system sound — never for the thread you are looking at in Scope, and never during a Focus or while the screen
is locked. With Reduce Motion, it fades instead of springing open.</p>
<p>The island sits on the screen of the window you are working in — the frontmost window of the active app, whatever
the app, on the screen that holds most of it — and moves there when you switch apps or drag the window to the other
screen, never while it is open or under the pointer. With no window in front (Finder over the desktop), it goes to the
screen with the pointer.</p>
<p>It stays out of your way while you work: as long as you are typing or moving the pointer, a finished or failed turn
only changes its thread's dot; only an agent waiting on you — a question, a permission, a plan — makes it grow
(<b>Interrupt while I work</b>: never, only when an agent is waiting, or always). Over an app in full screen it
disappears unless an agent is waiting. Settings › General › Island turns it off, picks the screen (the active window's, the main one,
the one with the pointer, or a named one), how it opens and which events it shows. It is on by default, and off in a
Debug build.</p>
"""

TASKS = """
<div class="eyebrow">Guide</div>
<h1>Tasks and sandboxes</h1>
<p class="lede">A task is a prompt, a branch and one worktree per repository. You write the prompt; the driver
names the branch the way your repository already names branches.</p>

<h2 id="create">Creating a task</h2>
<p><kbd>⇧⌘T</kbd>, or <b>New Task…</b> in the palette. The first step asks for two things: what
you want done, and which driver should do it. Nothing else — the repositories, the branch and the folder come
from the prompt.</p>
FIG_PROMPT
<p>The prompt is not a throwaway: it opens the first thread of the task, and it is written into
<code>AGENTS.md</code> as the goal, so a later thread — or a different agent — still knows what this branch is
for.</p>

<h2 id="reading">What Scope reads out of the prompt</h2>
<p><b>Continue</b> reads the request before anything is created:</p>
<table>
  <tr><th>In the prompt</th><th>What it becomes</th></tr>
  <tr><td>a pull request it asks to work on — <code>…/pull/6613</code>, <code>owner/repo#6613</code>, or <code>#6613</code> in a single-repository scope</td><td>its repository, its head branch checked out, and the task bound to it</td></tr>
  <tr><td>a repository of the scope, by folder name, path or <code>owner/repo</code></td><td>the repositories the task sandboxes</td></tr>
  <tr><td>a branch that already exists</td><td>a start point that continues it instead of branching</td></tr>
</table>
<p>Repositories are matched on their <code>origin</code> remote, not on the folder name — a pull request of
<code>acme-devops/acme-front</code> finds the clone you keep in a folder called <code>front</code>.</p>
<p>Naming a pull request is not asking to work on it. A pull request becomes the start point when the prompt is
little more than the reference — <code>#6613</code>, a pasted URL, or a first line that is just one — or when a sentence opens on a verb of working on
it: <i>review #6613</i>, <i>fix the CI on #6613</i>, <i>take over …/pull/6613</i>, <i>rebase la pr …</i>. One cited
as context in a longer brief — <i>follows #37</i>, <i>(context: #37)</i> — stays context, and the task gets a new
branch.</p>
<div class="note"><p>Everything Scope worked out is shown on the second step and stays editable. A wrong
branch name is a typo; a wrong repository is a worktree in the wrong place, so nothing is created from a
guess you were not shown.</p></div>

<h2 id="branch">The driver proposes the branch</h2>
<p>Press <b>Continue</b> and the selected driver answers one short question — a <b>microsession</b>: its light
model, run once, with the repository's recent branch names and commit subjects as evidence, and the scope's
repositories as the list it may choose from:</p>
FIG_LOADING
<p>It answers with a title, a branch and a folder name that follow the convention already in use — if the repo
lives on <code>feat/…</code> and <code>fix/…</code>, so will the task; if it prefixes branches with a
username, so will the task. Scope validates the answer with <code>git check-ref-format</code>, sanitises it and
makes it unique.</p>
<p>It also says <b>which repositories</b> the work touches, and whether the request is about a pull request that
already exists. A microsession has read-only tools, so a request that only alludes to one — "rebase the auth PR
on front" — is enough: it finds the number with <code>gh pr list</code> and answers with the reference. Scope
then resolves that reference itself with <code>gh pr view</code>, exactly as it does for a pasted URL: the head
that gets checked out never comes from the model's own words, and an invented repository path is dropped rather
than corrected.</p>
FIG_PROPOSAL
<p>All three fields stay editable. What you type wins: a proposal that arrives after you started typing only
updates the caption, never your text.</p>
<div class="note"><p><b>No headless driver, no network, driver too slow?</b> Scope derives the branch itself:
the title from the first line of the prompt, the prefix from the dominant prefix among the existing branches, or
<code>feat/</code> / <code>fix/</code> inferred from the wording. The caption says which one you got and why.
There is no imposed <code>scope/</code> prefix — a branch Scope creates looks like a branch you would have
created. The prefix is reserved: asking for <code>scope/x</code> is refused with the way
out — leave the branch to Scope, or pick another prefix such as <code>feat/</code>.</p></div>

<h2 id="continue">Continuing existing work</h2>
<p>The <b>Start from</b> row decides what the sandbox is based on:</p>
<table>
  <tr><th>Start from</th><th>Effect</th></tr>
  <tr><td><b>A new branch</b></td><td>the proposed branch, off <code>origin/&lt;default&gt;</code> — the usual case</td></tr>
  <tr><td><b>#6613 …</b></td><td>the pull request's head is checked out; a fork's head becomes <code>pr/6613</code></td></tr>
  <tr><td><b>an existing branch</b></td><td>that branch is checked out, local copy first, <code>origin/</code> otherwise</td></tr>
</table>
<p>In the last two the branch <i>is</i> the start point, so the Branch field goes read-only: nothing is
created, the work continues where it was. A pull request lives in one repository, so a task on one sandboxes
that repository alone. Starting a task on a pull request Scope already has a task for offers that task
instead of a second sandbox.</p>
<div class="note warn"><p>A branch can only live in one working tree. If the branch you start from is already
checked out — in the base clone, or in another task — Scope says so, and names the checkout holding it (the
task, when it is one of its sandboxes), rather than letting git fail. <b>Create on a New Branch Instead</b>
leaves that branch where it is and bases the task on a fresh one.</p></div>

<h2 id="sandboxes">Sandboxes</h2>
<p><b>Create</b> makes, for every selected repository, a git worktree on the task branch:</p>
<pre><code>~/.scope/sandboxes/&lt;scope-slug&gt;/&lt;task-slug&gt;/
├── AGENTS.md                 <span class="c"># goal + one section per repository</span>
├── &lt;task-slug&gt;.code-workspace
├── checkout-api/             <span class="c"># worktree on feat/redis-product-catalogue-cache</span>
└── web-storefront/           <span class="c"># same branch, second repository</span></code></pre>
<p>Your own checkouts are untouched: they stay on whatever branch you left them on, and the task branch exists
in the worktree. A single-repository scope puts the worktree at the task root itself. The one exception is yours
to turn on and to trigger: <a href="review.html#try-in-checkout">trying a task in your checkout</a>, which
stashes, detaches and puts everything back.</p>
<p>The <code>sandboxes</code> folder carries a <code>.metadata_never_index</code> marker, so Spotlight leaves it
alone: no indexing of every worktree's <code>node_modules</code>, and no second copy of your files in search
results.</p>
<p>The branch starts from the repository's base — <code>origin/&lt;default&gt;</code> when it can be resolved,
the local default branch otherwise.</p>
<p>Git runs with the environment a thread gets: the <code>PATH</code> of your login shell, so the tools your git
config calls — <code>git-lfs</code> for a repository with <code>filter.lfs.required</code>, a credential helper
— are found even when Scope was opened from the Finder. Until the shell has answered, Homebrew's folders are
added to the system <code>PATH</code>. The same goes for <code>gh</code>, the setup commands and every other
helper Scope starts.</p>
<p>A worktree that fails half-way is undone: the folder it created goes, git's record of it is pruned, and the
branch goes too when this attempt created it and it holds no commit of its own. Retrying starts from the same
place. The failure shows as a toast, with the cause in plain words when it is a missing tool — <i>git-lfs is
installed but not on Scope's PATH</i>, or <i>git-lfs is not installed</i>.</p>

<h2 id="branches">Several branches in one task</h2>
<p>A task is one branch, but its work may not be: the next pull request of a stack, a docs change beside the
prototype, a second fix on the same repository. Rather than switching branches in the sandbox, or improvising a
<code>git worktree add</code> Scope would neither track nor clean up, a task can hold a second worktree of a
repository, on a branch of its own, beside the first:</p>
<pre><code>~/.scope/sandboxes/&lt;scope-slug&gt;/&lt;task-slug&gt;/
├── api/                      <span class="c"># the task branch, feat/catalogue-cache</span>
└── api@invalidation/         <span class="c"># a second worktree of api, on fix/invalidation</span></code></pre>
<p>The folder is <code>&lt;repo&gt;@&lt;short branch&gt;</code> — <code>@</code> never appears in a slug or a
repository name, so it reads as <i>repo at branch</i> and collides with nothing. On a single-repository scope,
whose task root is the worktree itself, the second one sits beside the root under the scope's folder
(<code>&lt;task-slug&gt;@invalidation</code>).</p>
<p><b>Add Branch…</b> in a task's context menu, the command palette or the Task section asks for the branch (and
the repository, on a task of several). From a thread, <code>scope task branch add &lt;branch&gt; [--repo R]
[--from &lt;ref&gt;|--pr &lt;ref&gt;]</code> (<code>scope_task_branch_add</code>) does the same, starting the
branch from the repository's base, from an existing branch or on a pull request's head, under the same approval
as creating a task. <code>scope thread new --task &lt;slug&gt; --branch &lt;branch&gt;</code> opens a thread in
that worktree; the Task section's row has <b>New Thread</b> too.</p>
<p>Scope treats the added worktree like the task's own: it gets the <code>.env</code> files and the setup command,
the task's context file, a row in the Task section with its branch, its own group in the Delta, its own checkpoint
in every snapshot, its own measure against main, and its pull requests are found explicitly — every branch of the
task is asked about, not only the ones the primary sandbox's reflog remembers — so the task's auto-archive waits
for all of them. Archive removes every worktree and saves each one's uncommitted changes; Restore rebuilds them
all; Close with the branches deletes every branch of the task. <b>Remove Branch</b> (or <code>scope task branch
remove</code>) takes one worktree out of a live task the way an archive would: changes saved, folder gone, branch
kept. The task's own branch is not removable that way; archive or close the task.</p>

<h2 id="setup">Setup and teardown</h2>
<p>A fresh worktree has the committed tree and nothing else: no <code>node_modules</code>, no <code>.env</code>.
Right after <b>Create</b>, in the background, Scope prepares each sandbox — and the task's first thread waits for
it before it starts:</p>
<ol>
  <li>It copies the files your base checkout keeps out of git, <code>.env*</code> by default. A file already in the
  sandbox is never overwritten, and nothing is followed out of the repository: <code>..</code>, a symlink leading
  outside, a sandbox folder that is a symlink are all refused. A copied file the repository does not ignore is
  added to <code>.git/info/exclude</code>, so it cannot end up in a commit. The skills, commands and agents under
  <code>.claude/skills</code>, <code>.claude/commands</code> and <code>.claude/agents</code> that the sandbox lacks
  (a repository that ignores <code>.claude/</code>) are copied too, each whole, with no setting needed. They are
  copies, not links, so an agent editing a skill never edits your checkout; <code>settings.local.json</code> is
  left behind unless <code>copyFiles</code> names it.</li>
  <li>It runs the repository's <b>setup</b> command — <code>pnpm install</code>, <code>bundle</code>,
  <code>make deps</code> — in the sandbox, with your login-shell environment.</li>
</ol>
<p>The command is the <b>Setup</b> field of the repository's <a href="graph.html">graph card</a>. To override it for
one scope, or to change the copied files, edit the scope in <code>~/.scope/config.json</code>:</p>
<pre><code>"repoCommands": {
  "api": { "setup": "pnpm install --frozen-lockfile", "teardown": "docker compose down",
           "copyFiles": [".env*", "config/local.json"] }
}</code></pre>
<p>An empty string turns the card's command off. Commands see these variables:</p>
<table>
  <tr><th>Variable</th><th>Value</th></tr>
  <tr><td><code>SCOPE_TASK</code>, <code>SCOPE_SCOPE</code></td><td>the task's and the scope's slugs</td></tr>
  <tr><td><code>SCOPE_SANDBOX</code></td><td>the worktree the command runs in</td></tr>
  <tr><td><code>SCOPE_BASE_PATH</code></td><td>your own checkout of the repository</td></tr>
  <tr><td><code>SCOPE_DEFAULT_BRANCH</code></td><td>its default branch</td></tr>
  <tr><td><code>SCOPE_PORT</code></td><td>the first of ten ports that belong to this task alone</td></tr>
</table>
<p>Every task gets its own block of ten ports, kept across restarts and never shared by two live tasks, so two
sandboxes can run the same dev server side by side. Its threads get <code>SCOPE_PORT</code> too. While a thread of
the task is alive, Scope looks every twenty seconds at which ports of the block its processes listen on, and the
Task section and the task's hover card show each as a <code>localhost:41003 ↗</code> chip: a click opens it
in the task's <a href="concepts.html#inspector">Browser pane</a> (<kbd>⌥</kbd>-click: the system browser).</p>
<p>The same places say what the task's sandboxes take on disk, measured after each setup and every ten minutes;
the scope's settings sheet adds the total over its open tasks and the three heaviest, and <code>scope gc
--dry-run</code> prints the same figures. Archiving a task is what frees the space.</p>
<p>The task row shows a gear while the setup runs and a warning triangle if it failed; the failure lands in the
Problem Center with the end of the log and <b>Run Setup Again</b>. Untick <b>Run setup</b> in the New Task
sheet — or pass <code>--no-setup</code> to <code>scope task new</code>, <code>run_setup: false</code> over MCP —
to skip the command; the files are copied anyway.</p>
<p>The <b>Teardown</b> field is the other end: it runs in each sandbox before Archive or Close removes it, with
the same variables and a ten-minute limit. If it fails, the failure is shown and the sandbox goes anyway:
whatever the command was meant to stop is stopped by the process sweep that follows.</p>

<h2 id="threads">Threads inside a task</h2>
<p>Creating the task opens the first thread on the spot, in the sandbox, with your prompt already sent to the
driver.</p>
FIG_THREAD
<p><kbd>⌘T</kbd> inside a task opens more threads in the same sandbox — a shell to run the tests next to the
agent doing the work, a second agent on the same branch.</p>

<h2 id="guardrails">Git guardrails</h2>
<p>The threads of a task run git with Scope's own hooks, passed through their environment — nothing is written
into any repository, and git run from your own terminal or editor never sees them. Two checks:</p>
<ul>
  <li><b>pre-commit</b> refuses a commit in your base checkout, or in another task's sandbox, of a repository
  this task works on. A repository the task has nothing to do with is left alone.</li>
  <li><b>pre-push</b> refuses a push from the sandbox onto the remote's default branch: the work goes through the
  task's branch and a pull request. A push of tags alone (<code>refs/tags/v1.2.3</code>, no branch) goes through —
  that is how a release is cut — but the branch beside a tag is still refused, so a repository's
  <code>scripts/release.sh</code>, which pushes <code>main</code> and the tag together, fails from a sandbox as a
  whole. <code>scope release</code> is the way (below).</li>
</ul>
<p>Every hook then hands over to the repository's own — husky, lefthook and pre-commit keep working. It is a
guardrail, not a lock: <code>--no-verify</code> still walks past it.</p>

<h2 id="release">Cutting a release from a thread</h2>
<p><code>scope release [X.Y.Z] [--repo R] [--dry-run] [--force]</code> (MCP: <code>scope_release</code>) cuts a
release the way you would from a clean, up-to-date <code>main</code> — but it is Scope that does it, not the thread.
Scope reads the remote's default branch (and refuses when there is none), clones it into
<code>~/.scope/releases/&lt;owner-repo&gt;/</code> (reused, fetched and reset, from one release to the next), asks
<code>gh</code> that no release workflow is already running and that CI on the head is green
(<code>--force</code> overrides the CI check; without <code>gh</code>, the check is skipped and the answer says so),
then runs the repository's <code>scripts/release.sh [X.Y.Z] --yes</code> there — or, without one, what the script does:
the next version from <code>git cliff --bumped-version</code>, an annotated tag, the tag pushed — with your login
shell's environment, your git identity and credentials, no <code>SCOPE_*</code> and no sandbox hook. The script's
output streams back while it runs and comes with the answer, its end kept when it is long. Without a version, the
next one from the Conventional Commits since the last tag; <code>--dry-run</code> clones, checks and prints the notes
and the plan without pushing anything, and asks nobody.</p>
<p>For agents it follows <b>Settings ▸ Automation ▸ Releases</b>, <i>after asking</i> by default — the one place
Scope's autonomy default flips, because a pushed tag is a shipped version. Your own terminal is never asked.</p>

<h2 id="context">AGENTS.md</h2>
<p>Scope writes a context file generated from the prompt and the <a href="graph.html">graph</a>: the goal, and
one section per repository with its purpose, stack, setup and test commands.</p>
<p>It lands where the task's threads start — the sandbox when the task has one repository, the task root when
it has several — because a file anywhere else is a file the driver never opens. It is written under every name
the installed drivers read (<code>AGENTS.md</code>, and <code>CLAUDE.md</code> for Claude Code; the profile's
<code>context</code> says which), with the same content in each. Inside a sandbox each file is added to
<code>.git/info/exclude</code>, so it never shows up in your delta.</p>
<p>A file Scope did not generate is never overwritten: a repository's own <code>AGENTS.md</code> or
<code>CLAUDE.md</code> stays exactly as it is. For Claude Code the task context then goes to
<code>CLAUDE.local.md</code>, which Claude reads alongside the repository's file (excluded from git like the
others); other drivers start from the repository's file and their prompt.</p>
<h3 id="skills">Every repository's skills</h3>
<p>A thread at the root of a task of several repositories would see none of their skills, slash commands or
subagents: Claude Code looks for <code>.claude/</code> in its own folder, and the repositories sit one level down.
So Scope hands it each sandbox with <code>--add-dir</code> (the profile's <code>addDir</code>), and sets
<code>CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1</code> so each repository's <code>CLAUDE.md</code> is read
from the start rather than only when the agent opens a file there. A thread already running when you add a
repository sees it the next time it is relaunched or resumed.</p>
<h3 id="memory">Claude Code memory, per repository</h3>
<p>Claude Code keeps its <a href="https://code.claude.com/docs/en/memory">auto memory</a> in
<code>~/.claude/projects/&lt;project&gt;/memory/</code>, the project being the git repository's main checkout — so
every worktree of a repository shares it — or the working directory outside a repository. A thread in a sandbox
already lands on its repository's memory; a thread at the root of a task of several repositories did not: the
task root is no repository, so it got a memory of its own, unread once the task was archived.</p>
<p>Scope now picks the folder for every Claude Code thread of a task, with <code>autoMemoryDirectory</code> in the
thread's own <code>--settings</code> file:</p>
<ul>
<li>a thread inside a sandbox (a second branch's included) uses the memory of the repository's base checkout — the
one a session started in your checkout uses;</li>
<li>a thread anywhere else in the task — the root of a task of several repositories — uses the scope's, the memory
a thread at the scope root has always had, for what holds across repositories.</li>
</ul>
<p>The task's other memories are readable without a prompt (<code>permissions.additionalDirectories</code>), and
the context file gains a <b>Memory</b> section naming them, with the scope's index quoted, so a rule you taught at
the scope level reaches a repository's thread. The inspector's Context card lists them, with their note counts.
Scope leaves the folder alone when you chose one yourself (<code>autoMemoryDirectory</code> in your settings,
<code>CLAUDE_CODE_PROJECT_DIR_NAME</code>) or turned auto memory off; <b>Settings ▸ General ▸ Terminal ▸ Claude Code memory
follows the repository</b> turns the whole thing off.</p>
<p>Memories left behind by earlier tasks, and by other clones of a scope's repository, are gathered with
<code>scope memory</code>. It reports by default: each stray folder, where it would go, and what happens to each
file. <code>scope memory --apply</code> copies. Nothing is deleted or overwritten: a file identical to one already
there, or with the same <code>name</code>, is left out (a same-name file with other text is listed so you can
compare); a file whose name is taken by another memory is a conflict, listed and not copied. The index
(<code>MEMORY.md</code>) gains a line per copied file, and the report warns when it grows past the 200 lines or
25 kB Claude Code loads.</p>

<h2 id="missions">Missions</h2>
<p>A <b>mission</b> is a task whose prompt is a goal too big for one task: <code>scope task new --mission</code>,
<code>mission: true</code> in the MCP tool, or the <b>Mission</b> box of the New Task sheet. Its context file tells
the agent the protocol: split the goal into milestones, each one task's worth and each with a <b>validation</b> — a
shell command that proves it, the test suite, a build, <code>gh pr checks &lt;branch&gt;</code> — open one milestone
at a time as a child task, mark it done when the child reports, and open the next only once the previous one is
validated. Scope stores and validates; the orchestrator plans.</p>
<pre><code>scope task milestone add rework-auth "Token model" --validate "pnpm test"
scope task milestone done rework-auth 1 --child token-model</code></pre>
<p>Marking a milestone done runs its command in the child task's sandbox (the mission's without a child), with the
task's variables, and records the verdict on the mission: <i>validated</i> on exit 0, <i>failed</i> otherwise with
the end of the log, which also goes to the milestone's thread so it can fix and mark done again. A milestone
without a command is reached when marked done. An agent may add or mark milestones from inside the mission or
any of its tasks, without approval — nothing is opened or removed. The Task section shows the checklist (state,
command, child task, the log of a failure on hover) and the sidebar row the progress (<code>2/5</code>); the
context file lists the milestones as they stand.</p>

<h2 id="lifecycle">Archiving and closing</h2>
<table>
  <tr><th>Action</th><th>Effect</th></tr>
  <tr><td><b>Archive</b></td><td>removes every worktree (the <a href="#branches">added branches</a> included), keeps the branches and the record</td></tr>
  <tr><td><b>Close</b></td><td>the same, then the record goes; optionally every branch of the task too</td></tr>
</table>
<p>No question unless something would be lost (<a href="#closing">above</a>): an agent mid-turn, uncommitted
changes, an open pull request. An archive can be undone for five minutes (the toast, Edit ▸ Undo, the palette).
In order: the task's threads are hung up, its teardown runs, every process still
running under its folder (or started with its <code>SCOPE_TASK_ROOT</code>) gets SIGTERM, then SIGKILL three
seconds later, the uncommitted changes are saved, and the worktrees are moved out of the way in an instant and
deleted in the background. The row leaves the sidebar as soon as you click; a second click joins the archive in
progress.</p>
<p>Nothing is lost. Uncommitted changes — tracked and untracked, ignored files aside — are committed to
<code>refs/scope/salvage/&lt;slug&gt;-&lt;id&gt;/changes-&lt;time&gt;</code> in the repository, and the notice
that says so has <b>Restore</b>, which brings the archived task back with its sandboxes and those changes. A
branch deleted on close that git calls unmerged (a squash merge looks like that) keeps its last commit the same
way. Saved changes no task points to are deleted after 30 days.</p>
<p>If a step fails, the task stays out of the sidebar, the Problem Center says why with <b>Retry</b>, and the
next launch finishes the job.</p>

<h3 id="checkpoints">Every turn leaves a checkpoint</h3>
<p>Each time a turn ends in one of a task's threads and a file changed, Scope snapshots every sandbox of the task —
tracked and untracked files, ignored ones aside, the same private-index commit as the saved changes above — under
<code>refs/scope/checkpoints/&lt;task&gt;/&lt;n&gt;</code> in the repository. The branch does not move, the sandbox's
index is not touched, and a turn that changed nothing leaves nothing. Turns ending seconds apart share one
checkpoint. Fifty are kept on an open task, five with an archived one, none after a close.</p>
<p>In the Task section, a turn that left a checkpoint has a dot under its bar in the timeline, and the
<b>Checkpoints</b> list under it says when, which thread and turn, the first words of the reply and
<code>+N −M</code> against the checkpoint before. Hover one for three actions, none of which asks:
<b>Show diff</b> opens the checkpoint against the sandbox as it is now in the reading column; <b>Restore files</b>
writes the checkpoint's files back into every sandbox (files it had restored, files that appeared since removed) —
never a branch reset, never a commit touched — after taking a checkpoint of the files as they are, which the notice
names as the undo; <b>Branch from here</b> creates <code>&lt;branch&gt;-cp&lt;n&gt;</code> at the checkpoint's commit
without checking it out. <code>scope task checkpoints &lt;task&gt;</code> lists them and
<code>scope task restore-checkpoint &lt;task&gt; &lt;n&gt;</code> restores one; an agent may restore within its own
task only.</p>

<h2 id="cleanup">Automatic cleanup</h2>
<p>Scope tidies up after tasks on its own: when it opens, every 30 minutes, and after each archive or close. It
stops the processes left by archived or closed tasks, moves to the trash the sandbox folders no task owns (their
uncommitted work saved first), drops git's records of sandboxes that no longer exist, and deletes expired saved
changes. A folder younger than ten minutes is left alone — a task being created. Only what lives under Scope's
own home is cleaned: a worktree of yours that git calls stale is not Scope's to prune. Large untracked files
(over 50 MB) are not saved into your repository; the notice names them. One quiet line in the Problem Center says what was cleaned. <b>Settings ▸ General ▸
Tasks</b> turns it off; <code>scope gc --dry-run</code> shows what it would do.</p>

<h2 id="from-pr">Starting from a pull request</h2>
<p>Two ways in, one result. Name the pull request in the prompt, or open it from the <b>Pull Requests</b> sheet
(<kbd>⇧⌘P</kbd>), which lists the open pull requests of a repository through <code>gh</code>. Either way the sandbox sits on the PR's
head branch — including a fork's head — the task is bound to the pull request, and you review and push back
without touching your own checkout.</p>
<p>From the command line, <code>scope task new --pr &lt;ref&gt;</code> (<code>start_pr</code> over MCP) names it
outright — a number, <code>#123</code>, <code>owner/repo#123</code> or its URL — and fails when it cannot be found.
A pull request Scope only read off the prompt is a guess: when it is not one of the scope's (another repository, a
number that does not exist), the task is created on a new branch all the same and the answer says, in one line,
which reference it ignored.</p>

<h2 id="from-issue">Starting from an issue</h2>
<p>A GitHub issue opens a task the same way, minus the branch: <code>scope task new --issue 123</code>
(<code>issue</code> over MCP; also <code>#123</code>, <code>owner/repo#123</code> or the issue's URL) reads it with
<code>gh issue view</code> and puts its title, body and labels at the top of the brief, so the first thread reads
the issue before anything else. The task records the issue, the Pull Request section shows it, and the task's
context file asks the agent to reference it from the pull request (<code>Closes #123</code>). Without the flag,
an issue the prompt asks to work on counts — an issue URL, or <code>fix #123</code>, which is tried as a pull
request first and then as an issue — while one the brief merely cites stays context. The microsession that names a
task may read issues too (<code>gh issue view</code> is on its allowlist), so "fix the flaky login issue" finds
it without a number.</p>

<h2 id="mentions">Mentioning a past task</h2>
<p><code>@task:&lt;slug-or-id&gt;</code> anywhere in a prompt — a new task, a new thread, a message sent to a thread,
from the command line, over MCP, from the palette's <b>Ask Orchestrator…</b> or the sidebar's reply field — is
replaced, before it reaches the agent, by a compact block between <code>[Scope: context of task … — begin]</code>
and <code>… — end]</code>: the task's name, brief, branch, pull request and its state, topic, and the opening of the
answer kept when it was archived (or its report file). Archived and closed tasks count, so a study feeds the task
that implements it without anyone pasting. <code>@thread:&lt;id&gt;</code> does the same for a thread: title, task,
last answer. In the app, typing <code>@</code> in a message field offers the tasks of the scope, recent first; Tab
or ↩ completes one. A mention nothing answers to stays as typed, with a note.</p>
"""

REVIEW = """
<div class="eyebrow">Guide</div>
<h1>Delta, Base, pull requests</h1>
<p class="lede">Everything you would otherwise leave the app for: what changed, what it changed from, and
where it is going.</p>

FIG_AGENT_DELTA

<h2 id="delta">Delta</h2>
<p><kbd>⌘D</kbd>. Three modes over the same selection:</p>
<table>
  <tr><th>Mode</th><th>Compares</th></tr>
  <tr><td><b>Task</b></td><td>the task branch against its merge-base with the default branch — the whole change</td></tr>
  <tr><td><b>Uncommitted</b></td><td>the working tree against HEAD — what the agent has not committed yet</td></tr>
  <tr><td><b>Base vs origin</b></td><td>the local branch against its remote — what is not pushed</td></tr>
</table>
FIG_DELTA_FILES
<p>Files are grouped by repository, with an add/modify/delete filter, a fuzzy filter field and per-file line
counts. The mode is the menu in the section's header. Click a file to read its diff in the reading column beside
the inspector; <kbd>j</kbd>/<kbd>k</kbd> move between files, <kbd>[</kbd>/<kbd>]</kbd> between hunks.</p>
<h3 id="reply">The agent's reply, as a page</h3>
<p>An answer with headings, a table and a code block reads badly in a terminal, where lines wrap and tables
break. <kbd>⇧⌘R</kbd>, the speech-bubble button in the toolbar, <b>Read Reply</b> in a thread's menu, or a click
on the <i>Finished</i> caption of its sidebar row open the thread's last reply in the reading column, rendered
as Markdown: headings, lists, tables, fenced code with a copy button, quotes. Web links open in the browser; a
path — a link, or a code span such as <code>Sources/App.swift:12</code> — opens the file as a terminal link
would. Nothing in the text is ever fetched or run: images are shown as their text, HTML stays text, and a
<code>javascript:</code> or <code>data:</code> link is not a link. <b>Copy as Markdown</b> sits in the header;
<kbd>Esc</kbd> closes.</p>

<h3 id="links">Files an agent mentions</h3>
<p><kbd>⌘</kbd>-click a path, or a <code>file://</code> link, in a thread's terminal and the file opens in the same
column, at the line it names: the task's copy while the thread belongs to a task, the base checkout's otherwise,
the file itself when it lies elsewhere. A relative path is looked for from the thread's folder, then at the root of
every repository of the task — agents often leave the repository's name out — and when several files match, the
header lists them. A file the task changed has a button for its diff. Web links still open in the browser.</p>

<h3 id="diff">The diff</h3>
FIG_HUNK
<p>Native text: selectable, searchable with <kbd>⌘F</kbd>, with both line numbers, and a copy / reveal /
open-in-editor row for the file.</p>

<h3 id="publish">Commit, push, open the PR</h3>
<p>That is the agent's work in its thread, so the buttons are off by default. With Settings ▸ Git ▸ Show commit
and push buttons, <b>Commit…</b> and <b>Push</b> appear when the pointer is on the Delta header, and <b>Create
PR</b> on the Pull Request header. Create PR shells out to <code>gh</code> and links the resulting pull request to
the task, so the Pull Request section keeps showing it and its checks.</p>

<p>The box at the end of each file row marks it as <b>viewed</b>: the row dims, so what is left to read stands
out. The mark lasts while the file's diff stays the one you looked at; as soon as the agent changes that file
again, it clears itself.</p>

<h2 id="comments">Commenting on lines</h2>
<p>Review the agent's work where you read it. In the diff, a <b>+</b> appears in the line-number gutter under
the pointer: click it to comment on that line, or drag down the gutter to comment on a range. The comment
editor opens under the lines (<kbd>⌘↩</kbd> adds it). Comments show as tinted rows under the lines they cover;
click one to edit or delete it, or open the list from the review strip at the foot of the inspector.</p>
<p>Comments are kept per task, under <code>~/.scope/reviews/</code> — never in the sandbox. Each remembers the
exact text of its first line and three lines around it, so it follows the code as the agent keeps editing: a
comment whose lines are gone is listed at the top of the file instead of pointing at the wrong place.</p>
<p><b>Send Review</b> turns them into one message — per comment the file, the line numbers the file has
<i>now</i>, the code around them and your text — and pastes it into the task's thread as a single input. With
several threads running, pick one. If the thread is in the middle of a turn, the review waits and goes out as
soon as its hooks say the turn ended. Sent comments are cleared.</p>

<h2 id="base">Base</h2>
<p><kbd>⇧⌘B</kbd>. The repository as it is on disk, outside any sandbox — the reference the agent is working
from.</p>
FIG_BASE_VIEWER
<ul>
  <li><b>Files</b> — the tree of the checkout, every folder closed until you open it; a file opens read-only, with
  line numbers, in the reading column.</li>
  <li><b>Search</b> — <code>git grep</code> across the checkout, with case, regex, whole-word and folder filters. A
  result opens in the reading column and opens just the folders above it in Files.</li>
  <li><b>History</b> — recent commits of the branch.</li>
</ul>
FIG_BASE_SEARCH
<p><b>Pull</b> sits in the Base header as soon as origin is ahead; it is fast-forward only and refuses on a dirty
tree. Fetch, Open in Editor, Shell and Reveal come on hover. <b>Shell</b> opens a thread rooted at the base
checkout — useful when you want to run something against the real branch rather than a sandbox.</p>
<h3 id="try-in-checkout">Trying a task in your checkout</h3>
<p>A heavy dev server — one database, one port, one <code>node_modules</code> — runs in your checkout, and you want
to see a task's result there without a second install. That is the one time Scope moves a base, and it is off until
you turn it on: <b>Settings ▸ General ▸ Tasks ▸ Allow trying a task in my checkout</b> (or <code>allowTryInCheckout</code>
on a scope in <code>config.json</code>). On, a task's context menu offers <b>Try in My Checkout</b>, and so does
<code>scope task try &lt;task&gt;</code> from your own terminal. Agents are refused, always: the base is yours.</p>
<p>In the base of each repository of the task, Scope stashes whatever is not committed (untracked files included,
as <code>scope-try-&lt;task&gt;-&lt;time&gt;</code>), remembers the branch and commit you were on, and detaches
<code>HEAD</code> onto the task branch — detached, so your branch itself never moves, and never a
<code>reset --hard</code>. It refuses a checkout in the middle of a rebase or merge, one with conflicted paths, and
one already on another task; a repository that fails after others moved puts them back, so the task is tried whole
or not at all. Your own git hooks apply, not the sandbox's.</p>
<p>While it lasts, a banner on the task and on the Base panel of the repository says <i>Your checkout is on
&lt;task&gt; since 12:04</i>, the Dock badge reads <code>try</code> and the menu bar shows it. The task's threads
keep working in the sandbox; the base is a mirror you run. <b>Refresh</b> moves the detached checkout to the
branch's current head once the sandbox commits more.</p>
<p><b>Put back</b> — from the banner, the context menu or <code>scope task try &lt;task&gt; --end</code> — switches
back to your branch and applies the stash, then drops it. It also runs on its own, without asking, when the task is
archived or closed and when Scope quits; a put back cut short by a quit is finished at the next launch. Changes you
made in the base while trying are stashed aside and kept. A stash that no longer applies cleanly is kept too, the
Base panel opens on the repository and a notice says which stash it is — nothing of yours is ever dropped.</p>

<h2 id="prs">Pull requests</h2>
<p><kbd>⇧⌘P</kbd>. Open pull requests of the selected repository, through the <code>gh</code> CLI and your
existing GitHub authentication: title, number, author, branch, checks and review state. Open one in the
browser, or turn it into a task whose sandbox sits on the PR's head.</p>
<div class="note"><p>The panel needs <code>gh auth login</code> and a GitHub remote. A repository without one
simply shows nothing to list.</p></div>

<h2 id="pr-lifecycle">A task's pull requests, to the merge</h2>
<p>Once a task has a pull request — opened from its thread, or the one it was opened on — the Pull Request section
lists its checks, refreshed every minute: state, name, and a link to each check's page.</p>
<p>A task can have several: one per repository, two on the same branch, a stack, a docs pull request next to the
prototype's. Scope finds them on every branch a sandbox has been on (<code>gh pr list --head</code>, the reflog
says which) and keeps them all, in a fixed order — the task's repositories, then the numbers — that never moves
with their states. The sidebar row speaks for the most pressing <i>open</i> one (a conflict before red checks before
running checks), and says <i>PR merged</i> once every one is merged or closed. The section's header, the hover card
and <code>scope list tasks</code> sum them up (<i>2 PRs · 1 merged · 1 checks failing</i>); the section lists them
with the repository in front, and the one you pick is the one <b>Open on GitHub</b>, <b>Merge</b>, <b>Fix Conflicts</b>
and <b>Send to Thread</b> act on. The context menu and the palette offer one <b>Open Pull Request</b> per pull
request, named by repository; the Inbox lists one item per pull request. A task is archived on merge only once none
of its pull requests is still open.</p>
<ul>
  <li><b>Send to Thread</b> on a failed check fetches the failed steps' log with <code>gh run view --log-failed</code>
  and pastes its end, with a sentence naming the check, into the task's thread — the same delivery as a review, so
  a thread mid-turn gets it when the turn ends. A check that is not a GitHub Actions job has no log to fetch; the
  thread gets its link.</li>
  <li><b>Merge</b> appears on the Pull Request header (with the commit and push buttons turned on) when GitHub says the pull request merges cleanly. It uses the method
  the repository allows (merge commit, else squash, else rebase), asks first, and then offers to close the task,
  which removes its sandboxes and deletes the branch the task created — never a branch name it would have to guess.</li>
  <li><b>Fix Conflicts</b> stays on the header when the pull request conflicts with its base: the thread is asked to merge
  the base into the branch, resolve, run the tests and push.</li>
</ul>

<h3 id="pr-background">Every task, not only the one on screen</h3>
<p>The task on screen is refreshed every minute; every other open task is read from GitHub every 5 minutes in the
background, two <code>gh</code> calls at a time and spread over the interval. A task with nothing committed yet is
skipped until it has a commit; one whose fetch fails is asked less and less often, up to once an hour; a merged or
closed pull request every half hour. Nothing runs in Low Power Mode. The checks say how old they are —
<code>✓ checks passed · 4 min ago</code> — on the Pull Request header and in the task's hover card, and turn grey
once older than 15 minutes: a green that old may no longer be true.</p>
<p>When a refresh sees the pull request <b>merged</b>, Scope archives the task the way the sidebar's Archive does
and leaves one quiet notice, <i>Archived &lt;task&gt;: pull request merged</i>, with <b>Restore</b>, and the
undo toast — once nothing
holds it any more. A merge says one branch landed, not that the task is over, so the archive waits while:</p>
<ul>
  <li>a thread of the task is mid-turn, waiting for an answer or a permission, failed on an error, still launching,
  was cut off mid-turn by a quit, or has sub-agents running;</li>
  <li>a task launched from it — or from one of those, all the way down — is still open: an orchestrator stays while
  its children work;</li>
  <li>a sandbox has uncommitted changes, or commits past the head of the merged pull request that no remote has;</li>
  <li>Scope has not measured a sandbox yet.</li>
</ul>
<p>And a thread that started a turn after the merge — a new message, a follow-up — means the work went on: the task
stays open until you or its agent archive it, or another of its pull requests merges. A pull request closed without merging
never archives anything, and a task with a pull request that you restore stays open. Turn it off in <b>Settings ▸ General ▸
Tasks ▸ Archive a task when its pull request merges</b>. A task with a pull request therefore stays open until the
merge: agents no longer poll GitHub for it, and only archive themselves work that has no pull request.</p>
<h3 id="follow-main">A task follows main</h3>
<p>Thirteen tasks on one repository, and every pull request rebased by hand once a sibling merged: that is what this
replaces. After each background refresh Scope fetches the task's sandbox and measures its branch against
<code>origin/&lt;default&gt;</code> — how many commits behind, and whether bringing main in would conflict, with a dry
merge (<code>git merge-tree --write-tree</code>) that touches nothing. The Pull Request section and the task's hover
card say <i>behind main by 4 · conflicts in 2 files</i>; <code>scope list tasks</code> has a MAIN column. Then,
per <b>Settings ▸ General ▸ Tasks ▸ When main moves</b>:</p>
<ul>
  <li><b>Ask the agent</b> (default): when the branch conflicts with main, or GitHub reports the pull request as
  conflicting, the task's thread — the first live Claude Code or Codex thread, or a new one when none runs — is
  told what moved (<i>main moved (4 commits, merged: #12, #15)</i>, the conflicting files) and asked to rebase on
  <code>origin/main</code>, keep both sides, regenerate, re-run the suites it touched one at a time, rebuild, push
  with lease and reply when mergeable. Once per move of main: no repeat until main moves again. A branch behind
  without conflicts is left to the agent, which rebases when it pushes.</li>
  <li><b>Rebase when clean</b>: behind without conflicts and no thread at work in the task, Scope runs
  <code>git rebase origin/&lt;default&gt;</code> in the sandbox itself and pushes with
  <code>--force-with-lease</code> when the branch is published and its pull request open. A rebase that stops is
  aborted, the branch left exactly where it was, and the agent asked instead. The base checkout is never touched.</li>
  <li><b>Never</b>: the lag is measured and shown, nothing more.</li>
</ul>
<p>A task's context menu holds its branch out of all of this — <b>Don't Rebase Automatically</b> — and offers
<b>Rebase on Main Now</b>, the same as <code>scope task rebase &lt;task&gt;</code> (<code>scope_task_rebase</code>):
the clean rebase, or the message to the thread, on demand. A scope may set its own choice in <code>config.json</code>
(<code>followMain</code> on the scope's declaration).</p>
<p>A task left open with no thread activity for 3 days (<b>Settings ▸ General ▸ Tasks ▸ Idle after</b>), or whose
pull request was closed without merging, says so in its row — <code>idle 4d</code>, <code>PR closed</code>, ahead of
what its agent last did, or after the name on a compact row — and, arranged by state, goes under <b>Dormant</b>, unless it is waiting for you or working.</p>
"""

GRAPH = """
<div class="eyebrow">Guide</div>
<h1>The repository graph</h1>
<p class="lede">One card per repository: what it is for, what it is built with, how to set it up and test it,
and which repositories it talks to. It is what Scope hands to an agent when a task starts.</p>

FIG_GRAPH_CARD

<h2 id="generation">Two levels of generation</h2>
<table>
  <tr><th>Level</th><th>Source</th><th>Fills</th></tr>
  <tr><td><b>Level 0</b></td><td>README, manifests (<code>package.json</code>, <code>go.mod</code>, <code>Cargo.toml</code>…), git log</td><td>name, remote, default branch, stack, entry points, setup and test commands, last activity</td></tr>
  <tr><td><b>Level 1</b></td><td>the default driver, run headless once per repository</td><td>the purpose sentence, the domain, the relations between repositories, tags</td></tr>
</table>
<p><b>Analyze</b> in the sheet's header runs level 0, which needs no agent and no network; its menu runs the
default driver too. Results are cached per repository, keyed by HEAD plus the hashes of the README and manifests, so
re-analysing an unchanged repository costs nothing.</p>

<h2 id="views">Cards, list and graph</h2>
<p>The sheet shows a scope three ways, picked in its header and remembered per scope:</p>
<ul>
  <li><b>Cards</b>, grouped by domain (front, back, libs, infra &amp; CI, data…; domains with a single repository share
  a last group, and every group folds). A card says the name, <code>owner/repo</code>, two lines of description and
  one row of tags — the stack and the tags merged, <code>+N</code> for the rest. <b>Details</b> unfolds the entry
  points, the whole setup and test commands, ready to select, and which repositories it uses and is used by.
  Hovering or focusing a card shows its actions; right-click gives the same ones.</li>
  <li><b>List</b>, a dense table sorted by any column: name, domain, stack, last activity, branch, relations.</li>
  <li><b>Graph</b>, the relations drawn in layers, dependents above what they depend on. Hover a repository to light
  its neighbours, click it to read its card beside the drawing; pinch or <kbd>⌘</kbd><kbd>+</kbd> /
  <kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌘</kbd><kbd>0</kbd> to zoom, scroll or drag to move. Repositories with no relation
  are listed apart, under the drawing.</li>
</ul>
FIG_GRAPH_PANEL

<h2 id="descriptions">Where a description comes from</h2>
<p>The first that exists: what you wrote on the card, the repository's description on GitHub (read with
<code>gh</code>, which keeps its own login), the manifest's <code>description</code>, the AI analysis's purpose, then
the README's first sentence of prose — headings, badges, code, lists, notices and install instructions skipped.
Opening the sheet refreshes these without an analysis; it writes only the graph file, never in the repositories.</p>

<h2 id="editing">Editing a card</h2>
<p><b>Edit Card…</b> in a card's menu opens the fields for hand-editing. An edited card is marked and generation
never overwrites it again — the graph is a document you own, not a cache the app owns.</p>
<p>Cards are stored as one JSON file per scope in <code>~/.scope/graph/&lt;scope-slug&gt;.json</code>. Editing
that file by hand works too; <b>Refresh Scope</b> (<kbd>⌘R</kbd>) picks it up.</p>

<h2 id="projection">How agents see it</h2>
<p>When a task is created, the cards of the repositories it touches are projected into the task's
<code>AGENTS.md</code>, under the goal. The agent starts knowing what each repository is for, how to install
it and how to run its tests, instead of spending its first minutes rediscovering that.</p>
<p>A setup command is checked against the repository's files before anything runs it: <code>uv sync</code> without a
<code>[project]</code> table, <code>make install</code> without that target or <code>npm install</code> without a
<code>package.json</code> is never proposed by the analysis, and a task's setup reports it instead of failing on it.</p>

<h2 id="filter">Finding things</h2>
<p>The filter bar applies to the three views. Type to match names, paths, descriptions and tags; click a domain or a
tag to keep only those. Domains add up (Front <i>or</i> Back), tags too, and a domain and a tag narrow each other.</p>
"""

DRIVERS = """
<div class="eyebrow">Reference</div>
<h1>Driver profiles</h1>
<p class="lede">A driver is one JSON file in <code>~/.scope/drivers/&lt;id&gt;.json</code>. Four are bundled;
adding a fifth is a text edit, not a rebuild.</p>

<h2 id="example">A complete profile</h2>
<pre><code>{
  "id": "claude-code",
  "name": "Claude Code",
  "command": "claude",
  "args": [],
  "env": { "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1" },
  "context": { "file": "CLAUDE.md", "mode": "generate" },
  "resume": ["claude", "--resume", "{resume_id}"],
  "headless": ["claude", "-p", "{prompt}", "--output-format", "json"],
  "headlessLight": ["claude", "-p", "{prompt}", "--output-format", "json", "--model", "haiku",
                    "--tools", "Bash", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
                    "--allowedTools", "Bash(gh pr view:*),Bash(gh pr list:*),Bash(gh repo view:*),Bash(git branch:*),Bash(git log:*)"],
  "prompt": ["{prompt}"],
  "addDir": ["--add-dir", "{dir}"],
  "modelArgs": ["--model", "{model}"],
  "models": ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
  "adapter": { "kind": "claude-hooks" },
  "icon": "sparkles"
}</code></pre>

<h2 id="fields">Fields</h2>
<table>
  <tr><th>Field</th><th>Meaning</th></tr>
  <tr><td><code>id</code></td><td><code>^[a-z0-9][a-z0-9-]*$</code>; the file is named after it</td></tr>
  <tr><td><code>name</code></td><td>what the menus show</td></tr>
  <tr><td><code>command</code></td><td><code>"$SHELL"</code>, a bare name resolved on the login-shell PATH, an absolute path, or <code>~/…</code></td></tr>
  <tr><td><code>args</code>, <code>env</code></td><td>appended arguments and extra environment; both accept placeholders</td></tr>
  <tr><td><code>loginShell</code></td><td><code>true</code> starts the command as a login shell (Terminal.app style)</td></tr>
  <tr><td><code>context</code></td><td>the project file the tool reads (<code>CLAUDE.md</code>, <code>AGENTS.md</code>). Every task writes its projection under this name, next to the names the other profiles declare, where the task's threads start. <code>mode: none</code> opts the driver out; the other modes (<code>generate</code>, <code>file</code>, <code>flag</code>) all write the generated file today</td></tr>
  <tr><td><code>resume</code></td><td>full argv to resume a captured session</td></tr>
  <tr><td><code>headless</code></td><td>full argv for one-shot runs: graph level 1, task branch proposals</td></tr>
  <tr><td><code>headlessLight</code></td><td>full argv for a <b>microsession</b>: the one short question the New Task sheet asks (branch, folder, repositories, pull request). Meant for the driver's light model and a read-only tool allowlist, so it can look a mentioned pull request up with <code>gh</code>. Falls back to <code>headless</code> when absent. The flags that trim the run matter as much as the model: loading one tool, no settings sources, no MCP and no session file roughly halves both the wall clock and the cost. Keep <code>{prompt}</code> ahead of a variadic flag like <code>--tools</code> or <code>--allowedTools</code>, which would otherwise swallow it</td></tr>
  <tr><td><code>prompt</code></td><td>arguments appended when a thread starts with an initial prompt, e.g. <code>["{prompt}"]</code></td></tr>
  <tr><td><code>addDir</code></td><td>arguments repeated for every other directory the thread should see, <code>{dir}</code> standing for it: each sandbox of a task of several repositories, whose threads start at the task root. <code>["--add-dir", "{dir}"]</code> for Claude Code. They come after the prompt, on a launch and a resume alike, since a variadic flag before the prompt would take it for a directory. Absent, the thread sees its working directory only</td></tr>
  <tr><td><code>modelArgs</code></td><td>arguments appended when a thread is opened with a model, <code>{model}</code> standing for it: <code>["--model", "{model}"]</code> for Claude Code, Codex and Cursor. After <code>args</code> on a launch and after the <code>resume</code> argv on a resume, before the prompt. Absent, the driver takes no model: <code>--model</code> is refused and the menus offer none</td></tr>
  <tr><td><code>models</code></td><td>the models the New Thread menus, the palette and Settings offer for this driver; any other name still goes through <i>Other Model…</i> or <code>--model</code></td></tr>
  <tr><td><code>adapter</code></td><td>which event adapter turns the tool's hooks into thread states</td></tr>
  <tr><td><code>icon</code></td><td>SF Symbol shown on sidebar rows and in menus</td></tr>
  <tr><td><code>builtin</code>, <code>version</code></td><td>present on the bundled copies; drop them once you edit the file and Scope will never touch it again</td></tr>
</table>

<h2 id="placeholders">Placeholders</h2>
<table>
  <tr><th>Placeholder</th><th>Replaced by</th></tr>
  <tr><td><code>{thread_id}</code></td><td>the thread id</td></tr>
  <tr><td><code>{resume_id}</code></td><td>the captured session id (<code>resume</code> only)</td></tr>
  <tr><td><code>{prompt}</code></td><td>the initial prompt, or the meta-prompt for a headless run</td></tr>
  <tr><td><code>{cwd}</code>, <code>{scope}</code>, <code>{task}</code>, <code>{home}</code></td><td>working directory, scope root, task slug, <code>SCOPE_HOME</code></td></tr>
  <tr><td><code>{scope_hook}</code></td><td>path of the bundled <code>scope-hook</code> helper</td></tr>
  <tr><td><code>{dir}</code></td><td>one additional directory (<code>addDir</code> only)</td></tr>
  <tr><td><code>{model}</code></td><td>the model the thread was opened with (<code>modelArgs</code> only)</td></tr>
</table>
<p>A profile that uses a placeholder Scope cannot fill is refused at load time rather than at launch time.</p>

<h2 id="resolution">How the command is resolved</h2>
<p>Scope probes your login shell once at launch (<code>$SHELL -ilc</code> by default) and resolves every
<code>command</code> against that <code>PATH</code>. That is why a driver installed through nvm, mise or a
shell function works here exactly as it does in your terminal. The mode is a setting: interactive login,
login only, or no probe at all.</p>
<p><b>Settings → Drivers</b> lists every profile with the binary it resolves to, and flags the ones it cannot
find. <b>Reload</b> picks up edits without restarting. Under the list, <b>Default model</b> sets, per driver that
takes one, what its threads run on when neither the request nor the scope names a model.</p>

<h2 id="adding">Adding your own</h2>
<pre><code>cat &gt; ~/.scope/drivers/aider.json &lt;&lt;'JSON'
{
  "id": "aider",
  "name": "Aider",
  "command": "aider",
  "args": ["--no-auto-commits"],
  "icon": "wand.and.stars"
}
JSON</code></pre>
<p>Then <b>Settings → Drivers → Reload</b>. The minimum is <code>id</code>, <code>name</code> and
<code>command</code>; everything else is optional and degrades gracefully — a driver without
<code>headless</code> nor <code>headlessLight</code> simply never proposes branch names, and one without <code>adapter</code> shows no live
state.</p>
"""

CLI = """
<div class="eyebrow">Reference</div>
<h1>Command line and MCP</h1>
<p class="lede">Scope answers on the same socket its driver hooks use. <code>scope</code> is the command line
into a running app; <code>scope mcp</code> is the same commands, spoken as MCP, so an agent can open a thread
or sandbox a task on its own.</p>

<h2 id="install">Getting <code>scope</code></h2>
<p>Inside a thread there is nothing to do: Scope puts its own <code>Contents/Helpers</code> first on the
<code>PATH</code> it hands the driver, so <code>scope</code> and <code>scope-hook</code> are already there.</p>
<p>For your own terminal, <b>Settings ▸ Automation ▸ Install</b> links the tool into
<code>/usr/local/bin</code> when that folder is writable, otherwise into <code>~/.scope/bin</code> (it then
tells you the line to add to your shell). The link points inside the app bundle, so an update moves with the
app.</p>

<h2 id="commands">Commands</h2>
<pre><code>scope list [scopes|threads|tasks]   <span class="c"># what Scope is holding right now</span>
scope thread new [options]          <span class="c"># open a thread, print its id (--task, --branch, --repo, --driver, --model, -p)</span>
scope thread send &lt;id&gt; &lt;text&gt;       <span class="c"># type into it and press ↩ (--no-enter, --command, --wait)</span>
scope thread read &lt;id&gt;              <span class="c"># the last lines of its terminal (-n, --cursor), or --reply</span>
scope thread wait &lt;id&gt;...           <span class="c"># until they finish their turn; prints each last reply (--any)</span>
scope thread stop &lt;id&gt;              <span class="c"># stop its process; the row stays</span>
scope thread close &lt;id&gt;             <span class="c"># hang it up and remove it</span>
scope task new &lt;prompt&gt; [options]   <span class="c"># branch + worktrees + first thread (--pr, --issue, --topic, --deliverable, --attempts)</span>
scope task show &lt;id|slug&gt;           <span class="c"># its brief, and what was kept at archive: last answers, REPORT.md</span>
scope task archive &lt;id|slug&gt;        <span class="c"># put it away: processes stopped, work saved, branch kept</span>
scope task close &lt;id|slug&gt;          <span class="c"># archive it and forget it (--delete-branch)</span>
scope task restore &lt;id|slug&gt;        <span class="c"># bring an archived task back, with the changes saved at archive</span>
scope task rebase [&lt;id|slug&gt;]        <span class="c"># bring it up to date with main now: rebase when clean, ask its thread when not</span>
scope task branch add [&lt;id|slug&gt;] &lt;branch&gt; <span class="c"># a second worktree of a repository, on that branch (--repo, --from, --pr)</span>
scope task branch list|remove [&lt;id|slug&gt;] … <span class="c"># every worktree of the task; take one out, its changes saved, branch kept</span>
scope task checkpoints [&lt;id|slug&gt;]   <span class="c"># its checkpoints: one snapshot of the sandboxes per turn that changed a file</span>
scope task restore-checkpoint [&lt;id|slug&gt;] &lt;n&gt;
                                    <span class="c"># put checkpoint n's files back; the files as they are become a checkpoint first</span>
scope task topic [&lt;id|slug&gt;] &lt;topic&gt; <span class="c"># file it under a topic later (--clear, --no-children)</span>
scope browser open [url]            <span class="c"># open a page in the task's browser and wait for it (:41001, /checkout, --port)</span>
scope browser read|screenshot|console <span class="c"># the page as text, a JPEG of it, what it logged (--all)</span>
scope browser click &lt;ref&gt;           <span class="c"># click what read called e12</span>
scope browser type &lt;ref&gt; &lt;text&gt;     <span class="c"># type into a field (--clear, --submit)</span>
scope browser wait|network          <span class="c"># until a --selector or --text shows, or the page is quiet; its requests</span>
scope browser compare [/route]      <span class="c"># the route on the base branch's server and the task's, diffed (--before, --after)</span>
scope task milestone add|done [&lt;id|slug&gt;] … <span class="c"># a mission's milestones (--validate, --child); see <a href="tasks.html#missions">missions</a></span>
scope schedule list|run [&lt;name&gt;]      <span class="c"># the scheduled prompts: next fire and last run; or fire one now</span>
scope gc [--dry-run]                <span class="c"># run the automatic cleanup now; --dry-run also weighs the sandboxes</span>
scope memory [--apply]              <span class="c"># stray Claude Code memories, and where they belong; --apply copies them</span>
scope release [X.Y.Z]               <span class="c"># cut a release from a clone of main in Scope's home (--repo, --dry-run, --force)</span>
scope config get|set &lt;key&gt; [value] <span class="c"># agents' budgets, applied live; your terminal only</span>
scope summary [period]              <span class="c"># what was done over a period, scope by scope (--scope, --task)</span>
scope usage [period]                <span class="c"># how Scope itself was used: controls, commands, what never is</span>
scope mcp                           <span class="c"># speak MCP on stdio</span>
scope ping                          <span class="c"># is Scope listening, and what may agents do</span></code></pre>
<p>Every command takes <code>--json</code>. <code>--scope</code> accepts a slug, a name, an id or a path;
omitted, it is the caller's own scope, then the scope holding the working directory, then the only scope
there is. <code>--sock</code> and <code>--home</code> say which Scope to talk to — a Debug build listens on
<code>~/.scope-debug/scope.sock</code>.</p>
<pre><code>$ scope thread new --scope acme --driver claude-code --model claude-fable-5-1 -p "why is CI red?"
thread 3f9a2c17be04 — acme [claude-code · claude-fable-5-1] in acme
/Users/me/work/acme

$ scope task new "fix the flaky login test" --repo api --dry-run
would create the task “Fix the flaky login test”
branch      fix/flaky-login-test
slug        fix-flaky-login-test
sandbox     ~/.scope/sandboxes/acme/fix-flaky-login-test
repo        api → ~/.scope/sandboxes/acme/fix-flaky-login-test/api (branch created)</code></pre>
<p><code>scope list threads</code> ends each row with what its agent did last, and when: the last tool it ran and
on what — a file (relative to the thread's folder), the first line of a command, a search pattern, a URL — or how
its turn ended. <code>--json</code> and the MCP tool carry it as <code>activity</code>; a thread whose driver
reports nothing (a shell) has none. <code>TOKENS</code> is what a Claude Code thread consumed over the last five
hours (<code>tokens</code> in JSON), read from its transcripts. For a Claude Code thread, <code>MODEL</code> is the
model its session runs on now (after any <code>/model</code>), <code>MODE</code> its permission mode when it is not the default
(<code>plan</code>, <code>auto</code>, <code>bypass</code>, <code>accept edits</code>), and the activity ends with
<code>compacting</code>, the number of compactions and the MCP servers that failed or wait for authentication. JSON carries
all of it under <code>session</code>: <code>permissionMode</code>, <code>model</code>, <code>effort</code>,
<code>compacting</code>, <code>compactions</code>, <code>lastCompaction</code> (trigger, tokens before and after, duration)
and <code>mcpServers</code>.</p>
<pre><code>$ scope list threads
THREAD        TITLE  DRIVER       MODEL             MODE  STATE    SCOPE  TASK  TOKENS     BY    ACTIVITY
3f9a2c17be04  acme   claude-code  claude-fable-5-1  plan  running  acme         1.2M · 5h  user  Edit Sources/Login/Session.swift · 2m ago
8a18d7476063  ci     claude-code  claude-opus-5-5         done     acme         310k · 5h  user  finished · 1h ago · 1 compaction · MCP failed: github</code></pre>
<p><code>--model</code> on <code>thread new</code> and <code>task new</code> (<code>model</code> in MCP) picks what the driver
runs on, through the profile's <code>modelArgs</code>; the thread keeps it across relaunches and resumes, and the window
subtitle shows it. Left out, an agent's thread inherits the agent's own model when it runs the same driver, else the
scope's default (its settings sheet), else the driver's default (<b>Settings ▸ Drivers</b>), else the driver decides.
A driver whose profile has no <code>modelArgs</code> — the shell — refuses one.</p>
<p><code>scope thread read</code> prints the last 200 lines of a thread's terminal — scrollback included, up to
2000 with <code>-n</code> — between two markers, under a line saying the text is untrusted terminal output. Line
numbers stay put as the scrollback grows: the last line tells you the <code>--cursor</code> that reads the page
before. It is how an agent finds out what another thread said, without typing into it — its own child, or a
thread in another task or scope. <code>--reply</code> prints only the agent's last answer, as Claude Code and
Codex report it at the end of a turn: what it concluded, without the spinners and redraws of its terminal. While a
Claude Code thread waits, both say what it waits on (<code>pendingRequest</code> in JSON): the permission with its
command, file, URL or MCP tool and server, the question with its options, the plan, the MCP server's form.</p>
<p><code>scope thread wait</code> takes one thread id or more and returns once each has finished its turn, needs an
answer or a permission, or exited — then prints every thread's state and last reply. <code>--any</code> returns at
the first one, <code>--timeout</code> (600 s by default) answers anyway and names those still at work. A thread
just handed a prompt counts as at work until its driver reports on it, so a wait right after
<code>thread send</code> or <code>task new</code> does not return before the work starts. An answer that lands
during the wait ends it, and a thread that still reads running although its last answer is newer than anything
that started a turn counts as done. A Claude Code turn that ends with sub-agents still running in the background
does not end the wait: the thread is still at work until they report and it answers — a sub-agent whose end the
session's transcript already shows no longer counts, nor does one launched by a process that is gone. The answer
lists each thread's sub-agents still running and the last five that finished (<code>subagents</code>: type,
description, state, duration, tokens, tool calls); <code>scope thread read</code> lists them all with the start of
each one's report, and <code>scope list threads</code> counts them in a SUBAGENTS column. Shell commands and Monitors
it left running in the background — a dev server, a watcher — never hold it: the answer lists them (id, state,
command, exit code, output file, and any <code>/loop</code> wake-up or cron), as do <code>scope list threads</code>
and <code>scope thread read</code>; read the output file rather than waiting. For a thread in a task, the
answer carries the task's pull request as GitHub reports it (state, checks, mergeability, review), refreshed as the
wait ends — the same line <code>scope list tasks</code> shows in its PR column — so no <code>gh pr view</code> is
needed to know where the work stands. A shell reports no turns and never settles.
<code>scope thread send --wait</code> (MCP <code>wait: true</code>) types the message, then waits for the answer the
same way: one call instead of a send and a wait.</p>
<p><code>scope thread send</code> from a thread is a message: it lands in the other terminal under a line
naming its sender (thread id, title, task), so the receiving agent knows whom to answer and that the request
is not yours. <code>--no-enter</code> sends keystrokes and carries no such line. A thread may not type into
itself. <code>scope thread new --task</code> finds a task in any scope; <code>--scope</code> settles a slug two
scopes share.</p>
<p><code>--command</code> (<code>command: true</code>) is for the driver's own slash commands — <code>/model
claude-opus-5-5</code>, <code>/clear</code>, <code>/compact</code> — which a sender line would turn into prose: the
text is typed verbatim, with no line saying who sent it, and submitted. From your terminal it reaches any thread;
an agent may command only the threads it opened and theirs, unless <b>Settings ▸ Automation ▸ Driver commands</b>
opens every thread.</p>
<p>Whatever Scope types into a Claude Code thread — <code>thread send</code>, a message from another thread, the
nudge after a restart, a notification reply, the palette, a schedule — leaves the prompt you were writing alone.
Scope reads the input field first; when it holds a draft, it stashes it with Claude Code's own <kbd>Ctrl</kbd>+<kbd>S</kbd>,
submits the message, and Claude Code puts the draft back (<i>Draft restored</i>) with its line breaks, pasted blocks
and cursor, whether the agent was idle or the message was queued behind a running turn. An empty field, a permission
or a menu on screen, or a driver other than Claude Code gets the message as before. Keys you press during the second
or so it takes wait and follow in order. Claude Code keeps one stash: with <code>› stashed</code> already showing and
a new draft in the field, the message waits up to 20 seconds for the field to clear, then the new draft takes the
stash.</p>
<p><code>scope task new --issue 123</code> (<code>issue</code> over MCP) works on a GitHub issue: its title, body
and labels open the brief, the task records it, and the context file asks for <code>Closes #123</code> in the pull
request. <code>@task:&lt;slug&gt;</code> and <code>@thread:&lt;id&gt;</code> in any prompt or message are replaced by
that task's or thread's context — brief, branch, pull request, last answer kept — between markers; see
<a href="tasks.html#mentions">Mentioning a past task</a>.</p>
<p><code>scope task new --topic &lt;text&gt;</code> files the task under a topic: tasks sharing one sit together in
the sidebar, under one row. A task created from inside a task gets that task's topic unless another is named — and
when that task has none, both are filed under its name — so what an agent splits off lands next to it. An
orchestrator at the scope root has no task to inherit from: it names the topic of the tasks it fans out.
<code>scope list tasks</code> shows each task's topic.</p>
<p><code>scope task new --attempts &lt;n&gt;</code> runs the brief <i>n</i> ways: <i>n</i> sibling tasks under a topic
named after the title, on <code>&lt;branch&gt;-a1</code>…<code>-an</code>, each with its own thread;
<code>--models a,b,c</code> and <code>--drivers x,y,z</code> give each attempt its model or driver (one value for all,
or one per attempt). The answer lists every attempt with its task, branch and thread; <code>--dry-run</code> lists
what would be created. An agent's attempts all count against its task budget, and the refusal says how many would
fit. Comparing and keeping one happens in the app: <b>Compare attempts…</b> in the topic's menu.</p>
<p><code>scope task topic &lt;id|slug&gt; &lt;topic&gt;</code> files a task that already runs, and <code>--clear</code>
takes it out of its topic; without a task, it is the caller's own. Only the label changes. The tasks it started, and
theirs, follow while they still share its old topic — they got it from it, so they are the same piece of work — and
<code>--no-children</code> moves it alone. The MCP tool is <code>scope_task_topic</code>.</p>
<p><code>scope summary last week</code> lists, scope by scope, every task created, archived, closed or worked on
in the period — finished or dropped alike — with an outcome (<i>merged</i>, <i>delivered</i>, <i>abandoned</i>,
<i>archived</i>, <i>active</i>), its pull request, its topic, the opening of its brief, and how long its agents
worked and how long it waited on you (a question, a permission, a result not yet followed by a prompt), then the
threads opened outside tasks. The period reads <code>today</code>, <code>yesterday</code>, <code>this week</code>, <code>last
week</code> (the previous calendar week, Monday to Sunday), <code>last month</code>, <code>last 14 days</code>,
<code>2026-10-01..2026-10-14</code>, <code>since 2026-10-01</code>; the default is the last seven days.
<code>--task &lt;slug&gt;</code> prints one task's whole brief, and the last answers its threads gave before
it was put away; each task's line carries the opening of that answer. Each task and thread carries the tokens its
Claude Code threads consumed, all told. The installed <code>/scope-summary</code> skill has
an agent turn it into an account.</p>
<h3 id="deliverable">What a task leaves behind</h3>
<p>About half of the tasks are studies with no pull request: their deliverable is the agent's final answer,
which used to go with the thread when the task was archived. Now archiving or closing a task keeps the last
reply of each of its threads (its end, 64 KB), and the task's report file when it wrote one: <code>REPORT.md</code>
in the task root or a sandbox, or the file named with <code>scope task new --deliverable docs/study.md</code>
(<code>deliverable</code> in the MCP tool), 1 MB at most. They live in <code>~/.scope/tasks/deliverables/</code>
and outlive a close. <code>scope task show &lt;slug&gt;</code> (<code>scope_task_show</code>) prints the brief
and everything kept, for an open, archived or closed task; in the app, <b>Read deliverable</b> — in the Task
section of a restored task, or from the palette for an archived one — opens it in the reading column.</p>
<p>It is built from records, not conversations: of what was said in a thread, Scope keeps only that last answer. Closing a task
or a thread deletes its record, so a closed one now leaves a line in <code>~/.scope/history.jsonl</code>;
work closed before this version left nothing. A pull request's state is the last one Scope saw while its task was open.</p>
<p><code>scope usage last week</code> reads the log Scope keeps of its own interface — on this Mac only, in
<code>~/.scope/usage/</code>, never sent anywhere: the controls, commands, sheets and inspector sections used most,
per area; those never used in the period; for each command, how often it came from its shortcut, the menu, the
palette or a click; the CLI and MCP calls made by you and by agents; the time spent in each sheet and section; and
what rose or fell against the period before. Time on screen counts only while Scope is frontmost, one of its windows
is visible, the session is unlocked and you touched the keyboard or the mouse in the last two minutes; the report
says since when it is measured that way, and ignores the durations logged before. It holds ids, never what you type,
a path or a name. Settings ▸ General ▸ Usage turns it off or clears it. The MCP tool is <code>scope_usage</code>.</p>
<h3 id="schedules">Scheduled prompts</h3>
<p>Scope can send a prompt on its own — every hour at a minute, every day, on weekdays or once a week at a time —
to a scope's orchestrator, or into a new task with a driver and model of its own. Schedules live on the scope
(<b>Settings ▸ Automation ▸ Schedules</b>, or the scope's settings sheet): name, rule, prompt, target, paused or
not, and the last run. Two examples are offered at creation, paused: a morning look at the pull requests whose
checks are red, an evening <code>scope summary today</code>. Occurrences come from the calendar, so a daily 09:00
stays 09:00 across the clock change; at launch a daily, weekday or weekly prompt missed in the last day fires once
(<b>Catch up at launch</b>, on by default). The reply lands in the <a href="concepts.html#inbox">Inbox</a> as
<i>Schedule &lt;name&gt; ran — &lt;first line&gt;</i>, with <b>Read reply</b>. <code>scope schedule list</code>
(<code>scope_schedule_list</code>) shows every schedule with its next fire and last run; <code>scope schedule run
&lt;name&gt;</code> (<code>scope_schedule_run</code>) fires one now, paused or not — from an agent, with the
approval set for creating a task.</p>
<p>Exit codes: <code>0</code>, <code>64</code> for a usage error, <code>77</code> when Scope refused,
<code>1</code> for anything else.</p>

<h2 id="links">Links</h2>
<p>A <code>scope://</code> link asks for a task — from a README, an issue template, a bookmark:</p>
<pre><code>scope://task/new?scope=acme&amp;repo=api&amp;prompt=Fix%20the%20flaky%20login%20test</code></pre>
<p>It takes <code>prompt</code> (required), <code>scope</code> (default: the scope in the sidebar),
<code>repo</code> (repeatable), <code>branch</code>, <code>title</code>, <code>slug</code>, <code>driver</code>,
and <code>setup=0</code> to skip the setup commands. Scope shows what the link asks for and creates nothing until
you confirm — a link can come from any web page — then takes the same path as <code>scope task new</code>. A
Debug build answers <code>scope-debug://</code> instead.</p>

<h2 id="mcp">The MCP server</h2>
<p><code>scope mcp</code> speaks MCP on stdio with the same commands as tools — <code>scope_list</code>,
<code>scope_thread_new</code>, <code>scope_thread_send</code>, <code>scope_thread_read</code>, <code>scope_thread_wait</code>, <code>scope_thread_stop</code>,
<code>scope_thread_close</code>, <code>scope_task_new</code>, <code>scope_task_archive</code>,
<code>scope_task_close</code>, <code>scope_task_restore</code>, <code>scope_task_rebase</code>, <code>scope_task_branch_add</code>,
<code>scope_task_branch_list</code>, <code>scope_task_branch_remove</code>, <code>scope_task_checkpoints</code>,
<code>scope_task_restore_checkpoint</code>, <code>scope_browser_open</code>, <code>scope_browser_read</code>,
<code>scope_browser_screenshot</code>, <code>scope_browser_console</code>, <code>scope_browser_click</code>,
<code>scope_browser_type</code>, <code>scope_browser_wait</code>, <code>scope_browser_network</code>,
<code>scope_browser_compare</code>, <code>scope_gc</code>, <code>scope_release</code>,
<code>scope_ping</code>. Arguments are snake_case, and the
spellings an agent guesses from the command line are understood as meant — <code>dryRun</code>,
<code>no_thread</code> for <code>open_thread: false</code>, <code>message</code> for <code>text</code>, a single
<code>repo</code>. Anything else is refused rather than ignored, with the list of what the tool takes. They are the same
commands: the server holds no logic of its own, so the terminal and the agent can never drift apart.</p>
<p><b>Settings ▸ Automation ▸ MCP server</b> registers it with Claude Code, Codex and Cursor for your user, so
every session you start — in Scope or in any other terminal — has it: Claude Code through its own
<code>claude mcp add --scope user</code>, Codex in <code>~/.codex/config.toml</code>, Cursor in
<code>~/.cursor/mcp.json</code>, touching only the <code>scope</code> entry. The command is the helper inside the app
bundle, so an update keeps it working. By hand, the same thing:</p>
<pre><code>{"mcpServers": {"scope": {"command": "/Applications/Scope.app/Contents/Helpers/scope", "args": ["mcp"]}}}</code></pre>
<p><code>scope_task_new</code> is marked destructive. With <code>dry_run</code> the answer is the title, branch,
sandbox and worktrees it would create (and, with <code>attempts</code>, every attempt), with nothing written; the description keeps it for when the agent cannot
tell which repositories the work needs, so a task the agent can describe costs one call.</p>

<h3 id="skill">The Scope skill</h3>
<p><b>Settings ▸ Automation ▸ Skills</b> installs a <code>scope</code> skill for your user — one
<code>SKILL.md</code> under <code>~/.claude/skills</code>, <code>~/.codex/skills</code> or
<code>~/.cursor/skills</code> — so every session of those agents knows when to put work in a task, how to
refer to one by name or slug, how to brief a thread so it finishes alone, wait for it and read its answer, and
close the task — with both spellings of every command, since a session Scope did not launch has the MCP tools
and no <code>scope</code> on its PATH. When an
update changes the text, Scope rewrites the copies it installed at its next launch, and only those — a copy under the skill's
former name, <code>scope-tasks</code>, moves to the new one; a folder of the same name that Scope did
not write is never touched. A task's name and slug are one right-click away in the sidebar (<i>Copy Task
Name</i>, <i>Copy Task Slug</i>) and a click on the copy button next to the name in the inspector.</p>

<h2 id="automation">What an agent is allowed to do</h2>
<p>The <code>scope</code> command line in your own terminal is you, and is never filtered. A request from
inside a thread — or through <code>scope mcp</code> from anywhere, since a globally registered server is reached
from sessions Scope never launched — is an agent, and goes through <b>Settings ▸ Automation</b>:</p>
<table>
  <tr><th>Setting</th><th>Default</th><th>What it does</th></tr>
  <tr><td>Let agents drive Scope</td><td>on</td><td>Off refuses every write from a thread.</td></tr>
  <tr><td>Open tasks</td><td>12</td><td>How many tasks agents may keep open at once, every scope together. Archived tasks and yours do not count.</td></tr>
  <tr><td>Running threads</td><td>24</td><td>How many threads agents may keep running at once, every scope together. Stopped threads and yours do not count.</td></tr>
  <tr><td>Depth</td><td>no limit</td><td>A thread you opened is at depth 0; what an agent opens from it is one deeper. Set a limit to fence agents to a few generations; 0 keeps them from opening anything.</td></tr>
  <tr><td>Talking to threads</td><td>any thread</td><td>Which threads an agent may read, type into, stop or close: any, in every task and scope, or only the ones it opened.</td></tr>
  <tr><td>Driver commands</td><td>only the ones it opened</td><td>Which threads an agent may hand a driver command to (<code>thread send --command</code>: <code>/model</code>, <code>/clear</code>…), typed verbatim with no sender line. Never wider than <i>Talking to threads</i>.</td></tr>
  <tr><td>Opening a thread</td><td>without asking</td><td>Also available: after asking, never.</td></tr>
  <tr><td>Creating a task</td><td>without asking</td><td>A task writes a branch and a worktree per repository, all of it undone by closing the task. Set it to after asking to confirm each one.</td></tr>
  <tr><td>Releases</td><td><b>after asking</b></td><td><code>scope release</code> from an agent. The one place the autonomy default flips: a tag pushed is a version shipped, and nothing takes it back. A dry run never asks.</td></tr>
</table>
<p>Threads talk to each other: by default an agent may read and type into any thread Scope runs — another
task's, another scope's, yours — and every message it sends is signed with its thread id, so the receiver
knows who is asking and can answer back. Only its own terminal is off limits. <i>Only the ones it opened</i>
is the fence for whoever wants each agent confined to the threads it started; an agent outside Scope is then
confined to the threads agents outside Scope opened. Closing a task — worktrees removed, branch deleted when
asked — follows the same approval as creating one.</p>
<p>Any task may create tasks: an orchestrator splits a change across tasks, and a task splits its own work
further. What stops a loop of agents starting agents is not how deep the chain goes but how much it holds: each
task is a worktree per repository, each thread a process. So the budgets count what agents keep open right now,
across every scope, and refuse the request that would go past them — with the way out in the answer: archive the
tasks that are done, close the threads that are. Requests still being carried out hold their share, so five
sent at once cannot all take the last slot. A depth limit remains for whoever wants one.
<code>config.json</code> is read at launch and rewritten by the app, so raise a budget from a terminal with
<code>scope config set automation.maxAgentTasks 20</code> (or <code>automation.maxAgentThreads</code>;
<code>scope config get</code> lists them): it takes effect at once, as the Settings window would. Agents are
refused it — from a thread or through <code>scope mcp</code> — and it is not an MCP tool. With approvals set to
<i>after asking</i>, Scope shows one question at a time; a question left past the approval timeout is refused,
and so is a request that finds three already waiting.</p>
<p>Every thread records who opened it, the line of threads above it and its depth, so the chain survives a
restart — <code>scope list threads</code> shows it. <i>Only the ones it opened</i> reaches everything an agent
set in motion: the threads it opened, the ones those opened, and so on down. A <code>SCOPE_THREAD</code> that names no thread the app is
running is refused outright.</p>

<div class="note warn"><p><b>The socket is your account.</b> <code>~/.scope/scope.sock</code> is a unix socket
with mode 0600, so only your user can connect — but <i>everything</i> running as you can: any program, any
script, any agent in any terminal. The automation settings shape what a request from a Scope thread may do;
they are not a defence against software you chose to run. It is the posture the driver hooks have always
had, now with answers coming back.</p></div>

<h2 id="protocol">The protocol</h2>
<p>One exchange per connection. The client writes a frame, the app answers with newline-separated JSON lines
and closes; the last line is always the result. The header is what tells a control request apart from a hook
message.</p>
<pre><code>→ scope-rpc/1
→ {"caller":{"client":"scope-cli/0.4.0"},"id":"7f2a","method":"thread.new","params":{"scope":"acme"},"rpc":1}
← {"id":"7f2a","kind":"pending","message":"waiting for you to approve: …","rpc":1}
← {"id":"7f2a","kind":"result","ok":true,"result":{"thread":"3f9a2c17be04",…},"rpc":1}</code></pre>
<p>Methods: <code>ping</code>, <code>list</code>, <code>thread.new</code>, <code>task.new</code>. An unknown
method or a newer <code>rpc</code> answers <code>unsupported</code> rather than failing to parse, so a
<code>scope</code> binary that outlives its app says so instead of hanging. Error codes:
<code>bad_request</code>, <code>unsupported</code>, <code>denied</code>, <code>not_found</code>,
<code>failed</code>, <code>timeout</code>.</p>
"""

ADAPTERS = """
<div class="eyebrow">Reference</div>
<h1>Hooks and thread states</h1>
<p class="lede">Scope does not parse terminal output to guess what an agent is doing. The agent tells it,
through its own hook mechanism, over a unix socket.</p>

<h2 id="pipeline">The pipeline</h2>
<pre><code>agent hook  →  scope-hook (stdin: JSON)  →  $SCOPE_SOCK  →  adapter  →  thread state</code></pre>
<p><code>scope-hook</code> is a tiny helper shipped inside the app bundle
(<code>Scope.app/Contents/Helpers/scope-hook</code>). It reads the hook payload on stdin, adds
<code>SCOPE_THREAD</code> and writes one line to the socket named by <code>SCOPE_SOCK</code>. It never blocks
the agent: if Scope is not listening, it exits quietly.</p>

<h2 id="claude">Claude Code</h2>
<p>For a driver with <code>"adapter": { "kind": "claude-hooks" }</code>, Scope writes a settings file per
thread and starts the CLI with <code>--settings</code>. The events it subscribes to:</p>
<table>
  <tr><th>Hook</th><th>Becomes</th></tr>
  <tr><td><code>SessionStart</code></td><td>no change; the session id is captured, which is what lets <b>Relaunch</b> pick the session back up</td></tr>
  <tr><td><code>UserPromptSubmit</code>, <code>PostToolUse</code></td><td>running — after a <code>Stop</code>, only a new prompt starts the next turn: a background command or sub-agent still reporting, or a hook delivered late, leaves the thread done</td></tr>
  <tr><td><code>PreToolUse</code> on <code>AskUserQuestion</code> / <code>ExitPlanMode</code></td><td><span class="dot waiting"></span>waiting — <b>question</b></td></tr>
  <tr><td><code>Notification</code></td><td><span class="dot waiting"></span>waiting — <b>permission</b> once a permission dialog has sat unanswered for about six seconds (an elicitation dialog is a question) — and a macOS notification when Scope is in the background. A permission that auto mode, <code>bypassPermissions</code> or another <code>PermissionRequest</code> hook grants never shows as waiting</td></tr>
  <tr><td><code>PermissionRequest</code>, <code>Elicitation</code>, <code>ElicitationResult</code>, <code>PermissionDenied</code>, <code>PostToolUseFailure</code></td><td>no change by themselves: they say <i>what</i> is asked — the command, the file, the MCP tool, the form — and when it was decided. A permission nobody decided within a second makes Scope ask <code>claude agents --json</code> whether the dialog is up; if it is, the thread shows as waiting right away (the macOS notification still waits for <code>permission_prompt</code>), and goes back to running as soon as another hook answers</td></tr>
  <tr><td><code>Stop</code>, <code>SessionEnd</code></td><td><span class="dot done"></span>done</td></tr>
  <tr><td><code>SubagentStart</code>, <code>SubagentStop</code></td><td>no change; the sub-agents still running are counted, and <code>scope thread wait</code> holds while one of them runs in the background after a <code>Stop</code></td></tr>
  <tr><td><code>StopFailure</code></td><td>failed, with the reason (rate limit, billing, overloaded)</td></tr>
  <tr><td><code>TaskCreated</code>, <code>TaskCompleted</code></td><td>no change; the task goes into the thread's plan (the <b>Plan</b> card)</td></tr>
</table>
<p>What a waiting thread asks shows in its sidebar line, its Inbox item, its notification and a card over its
terminal: the command, file, URL or MCP tool of a permission and the rules Claude Code offers to remember, a
question with its options, a plan, a form. <b>Allow</b>, <b>Deny</b> and a question's options answer from Scope,
from the card, the Inbox or the notification: Scope types the keys you would (<kbd>1</kbd> for Yes, <kbd>Esc</kbd>
for No, the option's digit), and only after reading the terminal and finding that very dialog on it. A plan and a
form are answered in the terminal.</p>
<p>Two moments have no hook at all, and come from what you type into the thread instead: <b>Esc</b> or
<b>Ctrl-C</b> during a turn ends it (idle), and <b>Return</b> on a permission prompt resumes it (running).
Claude Code's <code>idle_prompt</code> notification, sent a minute after any answer you have not replied to, is
deliberately ignored: the turn is already done, nobody is asking anything.</p>
<p>Scope also keeps what the hooks say about the work itself: the tool each <code>PostToolUse</code> reports
and what it was about, when each turn started and how it ended, the last answer, and where Claude Code writes the
session's transcript, and the agent's plan: the todo list of <code>TodoWrite</code>, the tasks of
<code>TaskCreate</code>, <code>TaskUpdate</code> and <code>TaskList</code>, the plan <code>ExitPlanMode</code> writes out
of plan mode — what the <b>Plan</b> card shows. Recent versions of Claude Code no longer offer the todo and task tools
to recent models unless <code>CLAUDE_CODE_ENABLE_TODO_TOOLS</code> is set, so the bundled Claude Code profiles set it:
without it the agent keeps its list in prose and the card stays empty. It lives beside the thread's record, in <code>~/.scope/threads/&lt;id&gt;.activity.json</code>,
survives a restart, and goes when the thread is closed.</p>
<h3 id="limits">Your plan's limits</h3>
<p>A Claude subscription (Pro, Max) is not a budget of tokens: it is a rolling five-hour window and a weekly one,
sometimes a weekly one per model, each a percentage that resets. That is what the meter at the bottom of the sidebar
leads with — the window nearest its ceiling, as <i>31% · 35 min</i>, a bar coloured as it tightens — and clicking it
lists every window with its percentage and when it resets, the tokens under them.</p>
<p>The figures are Claude Code's own. The JSON Claude Code hands its status line on every answer carries
<code>rate_limits</code>: one object per window with <code>used_percentage</code> and <code>resets_at</code>, for
claude.ai subscribers only, after the session's first answer. The per-thread settings file Scope passes on the
command line sets the status line to <code>scope-hook statusline</code>, which forwards that object to the app and
then runs the status line your own settings name — the project's, then <code>~/.claude/settings.json</code>, in
Claude Code's order — on the same input, printing what it prints. So the bottom of the terminal keeps showing what
it showed, and nothing in <code>~/.claude</code> is modified. The plan's name comes from the account Claude Code
keeps in <code>~/.claude.json</code>, read only.</p>
<p>Scope never guesses a percentage. Until a thread has answered, or on an API key where Claude Code reports no
limits, the meter says the limits are unknown and shows tokens as before. The last report is kept in
<code>~/.scope/limits.json</code> so it shows at launch, with its age; after thirty minutes without a newer one it is
marked stale, since usage from claude.ai or another machine would not be in it. <code>scope ping</code> and
<code>scope list</code> carry the same windows (<code>limits</code>, with each window's level and seconds to its
reset), as do the <code>scope_ping</code> and <code>scope_list</code> MCP tools, so an agent near a ceiling can slow
down rather than open more threads. Turning the meter off in Settings also stops installing the relay; a thread
opened while it was off needs a relaunch to report.</p>
<h3 id="tokens">Tokens consumed</h3>
<p>Every 30 seconds Scope reads what each Claude Code thread's transcript gained since the last look — only the
bytes appended, off the main thread — and sums the <code>usage</code> of each model call: input, output, cache
writes and cache reads, with the model and the time. A response is written as several lines carrying the same
message id; it counts once. The transcripts of the subagents a session runs (the Task tool) count towards its
thread, since they spend the same quota. The transcripts are only read, never written.</p>
<p>Without reported limits the band shows the last five hours across every scope; its popover adds today, the last seven days,
each scope and the threads that spent most, with what the five hours are made of. A task's total sits beside its
name in the inspector band and in its hover card. The figures include cache reads, which are most of any total.
The tokens say who spent the limits above; where Claude Code reports no limits they are the meter's main figure,
consumption rather than what is left — unless you type a budget of your own per five hours (Settings ▸ General ▸
Usage), which turns it into a gauge. The same pane can
add what the tokens would have cost at API list prices, labelled as such; it is off by default, since a subscription
is not billed per token.</p>
<p>The counts live in <code>~/.scope/tokens.json</code>, with where each transcript was read up to: the
minute-by-minute detail for eight days, each thread's total for 90 days after its last call, closed threads
included. Other drivers report no tokens.</p>
<p>Your own <code>~/.claude/settings.json</code> is not modified: the per-thread file lives under
<code>~/.scope/threads/</code> and is passed on the command line.</p>

<h2 id="states">What the dot says</h2>
<table>
  <tr><th>Dot</th><th>Meaning</th></tr>
  <tr><td>green, breathing</td><td>running: the agent says it is working</td></tr>
  <tr><td>square</td><td>waiting for you — a question or a permission; counted in the badge until you answer or <b>Mark as Read</b></td></tr>
  <tr><td>diamond</td><td>failed: the turn stopped on an API error</td></tr>
  <tr><td>blue</td><td>done: finished while you were not looking; showing the thread clears it</td></tr>
  <tr><td>grey</td><td>idle: seen, ready for the next prompt</td></tr>
  <tr><td>ring</td><td>exited: the process is gone</td></tr>
</table>
<p>The toolbar pill and the row's tooltip say which it is in words — <i>Needs your answer</i>, <i>Needs
permission</i>, <i>Failed: rate limit</i>. A task row's glyph tells a question from a permission too, and a
collapsed group shows the most urgent dot of its threads: waiting, then failed, running, done, idle.</p>

<h2 id="others">Codex and Cursor</h2>
<p>Codex is wired through its <code>notify</code> configuration, with the same helper and the same socket.
<code>notify</code> only reports the end of a turn, so a prompt you type into a Codex thread is what marks it
running. Cursor's profile declares its hooks adapter, but it is not wired yet: like a shell, a Cursor thread
only knows it is alive. A tool without an adapter still runs perfectly — its row simply shows no live
state.</p>

<h2 id="notifications">Notifications and the badge</h2>
<p>When a thread starts waiting while Scope is not frontmost, you get a macOS notification with <b>Reply</b>,
<b>Go to thread</b> and <b>See delta</b> actions. The Dock badge counts the waiting threads, and the optional menu bar
item shows the <a href="concepts.html#inbox">Inbox</a>, so you can leave the window behind and answer from there
when an agent needs you.</p>
<p>The notification quotes the agent: the question it asks (Claude Code's <code>AskUserQuestion</code>, the plan
of <code>ExitPlanMode</code>, a dialog's message), else the end of the answer it just gave; for a finished turn,
the start of its answer. Markdown is stripped and the quote cut to about 180 characters, so you can tell from the
banner whether it is worth opening. A failed turn still says its error. <b>Reply</b> types your answer into the
thread and presses <kbd>↩</kbd>, exactly as <code>scope thread send</code> does, without bringing Scope up; the
notification goes once it is sent. <b>Settings › General › Notifications › Show what the agent said</b> (on by
default) turns the quote off, for when your screen is shared.</p>

<h2 id="assist">The assistant</h2>
<p>On events only — a turn that ends, a thread running for more than four minutes, a task being
created — Scope can hand the end of the terminal to a small model and get <i>labels</i> back: what the agent is
doing, whether it seems stuck and why, whether a finished turn is worth a notification, whether a task without a
pull request looks done, which of the scope's topics a new task belongs with. It never acts on any of it, and it
never reads the same words twice: a thread whose terminal has not moved keeps its last digest (asked again every
eight minutes at most), a finished turn is triaged only when a notification could be quieted by it, and the same
answer reported twice gets one verdict and one notification.</p>
<p>The first model is Apple's on-device one (macOS 26, Apple Intelligence on): free, local, about a second per
answer, good at exactly this kind of structured classification. <b>Settings › Assist › On-device + Haiku</b> adds
Claude Code's light model as a second opinion on a stuck verdict, and as the fallback when the on-device model is
unavailable — through <code>claude -p</code> with <b>no tools at all</b>, since what it reads is untrusted terminal
output, under a daily cap you set (40 by default). Each call counts against your subscription like any other.</p>
<p>What you see: the activity line under a running thread takes the model's words; a thread read as stuck says
<i>Seems stuck — reason</i> in the sidebar, in the Inbox and as a notification, with a <b>Not stuck</b> answer that
is remembered as a false positive; a finished turn the model reads as informational stays silent (a question or a
failure always notifies), and one it reads as blocking notifies with a <b>Not Blocking</b> action that is remembered
the same way; a task whose last reply reads as a deliverable shows <i>Looks finished — archive?</i> in
its band, a proposal with its own ✕; a task created without a topic is filed under one of the scope's topics when
one fits. Every decision goes to the <a href="cli.html#commands">usage log</a> by its id and tier only.</p>

<h2 id="socket">The socket</h2>
<p><code>$SCOPE_SOCK</code> points at <code>~/.scope/scope.sock</code> — or, when <code>SCOPE_HOME</code> is too
deep for a unix socket path, at <code>$TMPDIR/scope-&lt;uid&gt;-&lt;hash of the home&gt;.sock</code>. One JSON object per
line:</p>
<pre><code>{"thread":"3f9a2c17be04","kind":"Notification","session_id":"…","payload":{…}}</code></pre>
<p>Anything that can write a line to a unix socket can drive the state of a thread — a wrapper script, a CI
watcher, your own tool. <code>scope-hook</code> is only the convenient way to do it.</p>
"""

REFERENCE = """
<div class="eyebrow">Reference</div>
<h1>Files, keys, updates</h1>

<h2 id="layout">On disk</h2>
<pre><code>~/.scope/                 <span class="c"># SCOPE_HOME; override it with launchctl setenv SCOPE_HOME …</span>
├── config.json           <span class="c"># declared scopes + preferences</span>
├── drivers/*.json        <span class="c"># driver profiles</span>
├── threads/&lt;id&gt;.json     <span class="c"># one record per thread</span>
├── tasks/&lt;id&gt;.json       <span class="c"># one record per task</span>
├── graph/&lt;scope&gt;.json    <span class="c"># the repository cards</span>
├── sandboxes/            <span class="c"># the task worktrees</span>
├── ui-state.json         <span class="c"># selection, expansion, panel widths</span>
├── scope-visits.json     <span class="c"># when each scope was last looked at</span>
├── assist.json           <span class="c"># the assistant's calls today, per tier</span>
└── scope.sock            <span class="c"># hook events</span></code></pre>
<p>Every store writes atomically. A file with a newer schema version than the running build is reported and
left alone, never overwritten; a corrupt file is quarantined next to it rather than deleted.</p>
<p>The disk is the state. <code>config.json</code>, <code>tasks/*.json</code> and <code>threads/*.json</code> are
watched: edit one in an editor &mdash; rename a topic, fix a field, remove a record &mdash; and the sidebar, the
inspector, the CLI and the MCP tools follow without a restart. Scope tells its own writes from yours by the bytes
(it keeps a fingerprint of what it last wrote or read), never writes anything back on a reload, and leaves a file
that does not parse alone until it does, keeping what it had. A thread that is running keeps what its process
knows (state, exits, session id) and takes the rest from the file.</p>

<h2 id="palette">The command palette</h2>
<p><kbd>⌘K</kbd> opens one field over everything: the actions of the current context, the files of the
selection, the repositories of the scope and the open threads. <kbd>⌘P</kbd> opens it straight in file mode.</p>
FIG_PALETTE
<p><b>Ask Orchestrator…</b> (<kbd>⇧⌘K</kbd>) turns the palette into a message field addressed to the scope's
orchestrator: <kbd>↩</kbd> sends, <kbd>⇧↩</kbd> starts a new line. <b>Send to Thread…</b> does the same for any
thread, picked from the Go to Thread list. The message is typed into the thread as if you had typed it there; a
stopped thread is started for it. Nothing moves on screen: a toast says where the message went, and <b>Show</b>
goes there. A search that matches nothing, or reads as a sentence, offers <b>Ask Orchestrator: …</b> as its last
row, so <kbd>⌘K</kbd>, type, <kbd>↩</kbd> is enough.</p>
<p>To answer a waiting thread without switching to it, right-click its row in the sidebar and pick
<b>Reply…</b> (or press <kbd>⌥↩</kbd> while the sidebar list has the keyboard). A field opens under the row with
the end of the agent's last answer above it; <kbd>↩</kbd> sends, <kbd>Esc</kbd> closes.</p>
<div class="note warn"><p>While a terminal has keyboard focus it keeps <kbd>⌘K</kbd> for itself. Click outside
the terminal, or use <b>Go → Command Palette…</b>, until that is fixed.</p></div>

<h2 id="shortcuts">Keyboard</h2>
<table>
  <tr><th>Key</th><th>Action</th></tr>
  <tr><td><kbd>⌘O</kbd></td><td>Declare a scope…</td></tr>
  <tr><td><kbd>⌘R</kbd></td><td>Refresh scope</td></tr>
  <tr><td><kbd>⌘T</kbd></td><td>New thread in the current context</td></tr>
  <tr><td><kbd>⇧⌘T</kbd></td><td>New task… (or reopen the last closed thread)</td></tr>
  <tr><td><kbd>⌘Z</kbd></td><td>Undo your last close or archive (for 30 s; Edit ▸ Undo for 5 min)</td></tr>
  <tr><td><kbd>⌘W</kbd> / <kbd>⇧⌘W</kbd></td><td>Close thread / close window</td></tr>
  <tr><td><kbd>⌘.</kbd></td><td>Stop the thread</td></tr>
  <tr><td><kbd>⌥⌘R</kbd></td><td>Relaunch the thread, picking the driver's session back up when it can</td></tr>
  <tr><td><kbd>⇧⌘R</kbd></td><td>Read the agent's last reply as Markdown, in the reading column</td></tr>
  <tr><td><kbd>⌘1</kbd>–<kbd>⌘9</kbd>, <kbd>⇧⌘[</kbd> / <kbd>⇧⌘]</kbd></td><td>Switch threads</td></tr>
  <tr><td><kbd>⌃1</kbd>–<kbd>⌃9</kbd>, <kbd>⌥⌘←</kbd> / <kbd>⌥⌘→</kbd></td><td>Switch scopes, back to where you were in each</td></tr>
  <tr><td><kbd>⌃⌘L</kbd> / <kbd>⌃⌘G</kbd></td><td>Sidebar rows detailed or compact / arranged by state or as a tree</td></tr>
  <tr><td><kbd>⌘↩</kbd></td><td>Newline in the terminal (sent as meta <kbd>↩</kbd>)</td></tr>
  <tr><td><kbd>⌘←</kbd> / <kbd>⌘→</kbd>, <kbd>⌘⌫</kbd> / <kbd>⌘⌦</kbd></td><td>Start / end of the line, delete back to its start / to its end (sent as <code>^A</code> <code>^E</code> <code>^U</code> <code>^K</code>)</td></tr>
  <tr><td><kbd>⌥←</kbd> / <kbd>⌥→</kbd>, <kbd>⌥⌫</kbd> / <kbd>⌥⌦</kbd></td><td>Move and delete by word; every other <kbd>⌥</kbd> key types your layout's character</td></tr>
  <tr><td><kbd>⌘K</kbd></td><td>Command palette</td></tr>
  <tr><td><kbd>⇧⌘K</kbd></td><td>Ask the scope's orchestrator, without leaving the thread on screen</td></tr>
  <tr><td><kbd>⌥↩</kbd></td><td>In the sidebar: reply to the selected row's thread in place</td></tr>
  <tr><td><kbd>⌘P</kbd> / <kbd>⇧⌘O</kbd></td><td>Go to file</td></tr>
  <tr><td><kbd>⌥⌘F</kbd></td><td>Filter the sidebar</td></tr>
  <tr><td><kbd>⇧⌘I</kbd></td><td>Inbox: what needs you, in every scope (<kbd>j</kbd>/<kbd>k</kbd>, <kbd>↩</kbd>, <kbd>r</kbd>, <kbd>e</kbd> inside)</td></tr>
  <tr><td><kbd>⌥Space</kbd></td><td>From any app: the <a href="concepts.html#quick-panel">quick panel</a> — Ask a scope's orchestrator (<kbd>⌃1</kbd>–<kbd>⌃9</kbd> picks the scope) or the Inbox; configurable</td></tr>
  <tr><td><kbd>⌥⇧Space</kbd></td><td>From any app: show the window, or hide Scope when it is in front; configurable</td></tr>
  <tr><td><kbd>⌘D</kbd> / <kbd>⇧⌘B</kbd> / <kbd>⇧⌘P</kbd></td><td>Changes / Repository / Pull requests</td></tr>
  <tr><td><kbd>⇧⌘D</kbd></td><td>The inspector's Details page, and back to Overview</td></tr>
  <tr><td><kbd>⌃`</kbd></td><td>The task's shell pane: show, or hide it again</td></tr>
  <tr><td><kbd>⌃⇧B</kbd></td><td>The task's browser pane: show, or hide it again</td></tr>
  <tr><td><kbd>⌥⌘I</kbd></td><td>Toggle the inspector</td></tr>
  <tr><td><kbd>⌃⌘S</kbd></td><td>Show / hide the sidebar</td></tr>
  <tr><td><kbd>⌘M</kbd></td><td>Maximize the thread: it fills the window, <kbd>⌘M</kbd> again restores (minimize is <kbd>⌥⌘M</kbd>)</td></tr>
  <tr><td><kbd>⇧⌘U</kbd></td><td>Mark a waiting thread as read: its attention clears until it asks again</td></tr>
  <tr><td><kbd>⌘E</kbd> / <kbd>⇧⌘E</kbd></td><td>Open the selection / the task in your editor</td></tr>
  <tr><td><kbd>⌘F</kbd>, <kbd>⌘G</kbd></td><td>Find in the terminal or the diff</td></tr>
  <tr><td><kbd>⌥⌘K</kbd></td><td>Clear the terminal scrollback</td></tr>
  <tr><td><kbd>⌘/</kbd></td><td>This list, in the app</td></tr>
  <tr><td><kbd>⌘</kbd> held alone</td><td>After half a second, every control with a shortcut shows it in a keycap beside itself; let go and they vanish. Settings › General › Appearance turns it off</td></tr>
</table>

<h2 id="settings">Settings</h2>
FIG_SETTINGS
<ul>
  <li><b>General</b> — config folder, default driver, editor command, terminal font size, appearance
  (follow the system, or always dark, which is what agent TUIs assume) and cursor shape — underline, bar or
  block, steady or blinking; a blinking caret fades in and out rather than switching on and off, and a program
  can still ask for its own shape — whether <kbd>⌥</kbd> types the character your layout puts there (the
  default, so a French keyboard still gets its braces) or acts as Meta, plus notification status and whether notifications quote the agent,
  and under <b>Anywhere</b> the two system-wide shortcuts (click the field, press the keys; <kbd>⌫</kbd> removes one) and
  which tab the quick panel opens on, and under <b>Island</b> whether <a href="concepts.html#island">the island under
  the notch</a> shows, on which screen, how it opens and what it reveals.</li>
  <li><b>Shell Environment</b> — how the login shell is probed, and the resulting <code>PATH</code>.</li>
  <li><b>Drivers</b> — every profile, the binary it resolves to, and <b>Reload</b>.</li>
  <li><b>Automation</b> — install the <code>scope</code> command line on your PATH, whether agents may drive
  Scope, how deep agents may open agents, and whether opening a thread or creating a task asks you first; the
  <a href="cli.html#schedules">scheduled prompts</a> of each scope, and whether a missed one fires at launch. See
  <a href="cli.html">Command line and MCP</a>.</li>
  <li><b>Assist</b> — off, the on-device model only, or that model with Haiku as a capped second opinion; what the
  assistant may decide, and what it did today. See <a href="adapters.html#assist">the assistant</a>.</li>
</ul>
<p>The editor command is a template: <code>["code", "-g", "{file}:{line}"]</code>. <code>{path}</code>,
<code>{file}</code> and <code>{line}</code> are filled in; unused parts are dropped rather than left dangling.</p>

<h2 id="updates">Updates</h2>
<p>Scope ships with Sparkle and keeps itself current on its own: it checks the signed appcast attached to the
latest GitHub release every hour, and again when you come back to the app or wake the Mac, then downloads and
verifies the release (EdDSA signature) in the background. A ready release is installed when you quit Scope. To
have it sooner, a band across the top of the window and <b>Scope → Restart to Update</b> relaunch the app —
never on their own, since a relaunch hangs up every running thread. <b>Scope → Check for Updates…</b> still
checks on demand. Prereleases (<code>v1.0.0-rc.1</code>) are excluded from the stable feed.</p>

<h2 id="privacy">What Scope touches</h2>
<ul>
  <li>It <b>reads</b> your declared folders — files, git metadata, README and manifests.</li>
  <li>It <b>writes</b> only under <code>~/.scope/</code> and its own Application Support folder — with two
  exceptions you ask for: git operations you trigger from a panel, and the worktrees it creates for tasks.</li>
  <li>It sends nothing anywhere. Network traffic comes from the agents you launch, from <code>git</code>,
  <code>gh</code>, and from the update check.</li>
</ul>

<h2 id="building">Building and releasing</h2>
<pre><code>make generate            <span class="c"># Scope.xcodeproj from project.yml</span>
make build               <span class="c"># Debug .app (CONFIG=Release for release)</span>
make run                 <span class="c"># build + open</span>
make test-one FILE=SlugTests
swift build              <span class="c"># the ScopeKit package alone</span></code></pre>
<p>Releases are driven by tags: pushing <code>vX.Y.Z</code> builds a universal DMG, attaches it to a GitHub
release with its checksum and the Sparkle appcast, and publishes it. The version <i>is</i> the tag; nothing in
the tree is bumped. See the <a href="REPO/blob/main/README.md#releasing">README</a> for the full pipeline and
its optional signing secrets.</p>
"""

# --------------------------------------------------------------------------- build

FIGURES = {
    "FIG_NEWTASK": figure("newtask-proposal", "The driver’s proposal, all three fields editable."),
    "FIG_AGENT": figure("agent-thread-full", "Claude Code running in a task sandbox, prompt already sent."),
    "FIG_PALETTE": figure("palette", "The command palette: actions, files, repositories and threads in one field."),
    "FIG_AGENT_DELTA": figure("agent-delta", "The whole window: a task's thread on the left, the task's diff in the inspector on the right."),
    "FIG_DELTA": figure("delta-files", "Delta groups the changed files by repository."),
    "FIG_DELTA_PANEL": figure("delta-panel", "Delta: files by repository, the diff, and commit / push / create PR."),
    "FIG_SIDEBAR": figure("sidebar", "The sidebar: what needs you first, then what is working, finished, quiet; each task with its threads under it; repositories on demand."),
    "FIG_SETTINGS": figure("settings", "Settings → General.", "shot narrow"),
    "FIG_PROMPT": figure("newtask-prompt", "Step one: the request, the driver, the repositories."),
    "FIG_LOADING": figure("newtask-loading", "The driver runs headless while the derived name stands in."),
    "FIG_PROPOSAL": figure("newtask-proposal", "The proposal follows the repository’s own convention."),
    "FIG_THREAD": figure("claude-thread", "The first thread starts with the task's prompt.", "plain"),
    "FIG_DELTA_FILES": figure("delta-panel", "Ten files changed across the task’s repositories, with the diff below."),
    "FIG_HUNK": figure("delta-hunk", "A hunk, with both line numbers and selectable text."),
    "FIG_BASE_VIEWER": figure("base-viewer", "Base: the tree and the read-only viewer."),
    "FIG_BASE_SEARCH": figure("base-search", "Search runs git grep across the checkout."),
    "FIG_GRAPH_CARD": figure("graph-card", "A repository card with its details open: commands in full, and the repositories it uses and is used by."),
    "FIG_GRAPH_PANEL": figure("graph-panel", "The Graph view: dependents above their dependencies, the hovered repository's links lit, its card beside the drawing."),
}

PAGES = [
    ("index.html", "Scope — a control room for CLI code agents",
     "Scope is a native macOS workspace for running Claude Code, Codex, Cursor or a shell against your "
     "repositories: threads, git-worktree sandboxes, diffs and pull requests in one window.", HOME, True),
    ("getting-started.html", "Getting started — Scope",
     "Install Scope, declare a scope, open a thread and create your first task.", GETTING_STARTED, False),
    ("concepts.html", "Scopes, threads, drivers — Scope",
     "The vocabulary behind the app: scopes, repositories, threads, drivers, states, tasks and the inspector.",
     CONCEPTS, False),
    ("tasks.html", "Tasks and sandboxes — Scope",
     "A task is a prompt, a branch proposed by the driver, and one git worktree per repository.", TASKS, False),
    ("review.html", "Delta, Base, pull requests — Scope",
     "Read the diff, browse and search the base checkout, and open the pull request without leaving Scope.",
     REVIEW, False),
    ("graph.html", "The repository graph — Scope",
     "One card per repository — purpose, stack, entry points, setup and test commands — projected into every task.",
     GRAPH, False),
    ("drivers.html", "Driver profiles — Scope",
     "Every tool Scope can launch is one JSON file: fields, placeholders, resolution, and how to add your own.",
     DRIVERS, False),
    ("cli.html", "Command line and MCP — Scope",
     "Drive Scope from your terminal with `scope`, or let an agent drive it over MCP: the same commands, "
     "one socket, with a budget for agents and an approval for anything that writes.", CLI, False),
    ("adapters.html", "Hooks and thread states — Scope",
     "How agent hooks reach Scope through scope-hook and a unix socket, and become live thread states.",
     ADAPTERS, False),
    ("reference.html", "Files, keys, updates — Scope",
     "Where Scope stores things, every keyboard shortcut, the settings, updates and what it touches on disk.",
     REFERENCE, False),
]


def slugify(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text).lower()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    (OUT / ".nojekyll").write_text("")
    for slug, title, description, body, wide in PAGES:
        for key in sorted(FIGURES, key=len, reverse=True):  # FIG_AGENT_DELTA before FIG_AGENT
            markup = FIGURES[key]
            body = body.replace(key, markup)
        body = body.replace("REPO", REPO)
        # Give every heading an id so the table of contents can link to it.
        body = re.sub(r"<h([23])>(.*?)</h\1>",
                      lambda m: f'<h{m.group(1)} id="{slugify(m.group(2))}">{m.group(2)}</h{m.group(1)}>',
                      body, flags=re.S)
        (OUT / slug).write_text(render(slug, title, description, body, wide))
        print(f"docs/{slug}")


if __name__ == "__main__":
    main()

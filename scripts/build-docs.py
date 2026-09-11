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
<p>Threads survive a restart: Scope keeps a record per thread, and <b>Relaunch</b> picks the driver's previous
session back up when a hook captured its id. <b>Start Fresh</b> opens a new session instead.</p>

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
<kbd>⇧⌘T</kbd> undoes a close.</p>

<h2 id="states">States</h2>
<p>The dot on a sidebar row, the pill in the toolbar and the Dock badge all say the same thing:</p>
<ul>
  <li><span class="dot running"></span><b>Running</b> — the agent is working.</li>
  <li><span class="dot waiting"></span><b>Waiting</b> — it asked you something: a prompt, a permission.</li>
  <li><span class="dot idle"></span><b>Idle</b> — alive, nothing in flight.</li>
  <li><span class="dot done"></span><b>Done</b> — the turn ended.</li>
</ul>
<p>A task row carries one glyph instead: the most pressing thing about the task, picked in this order —
waiting on you, running, setup running, setup failed, done, conflicts, checks failing, checks running, checks
passed, draft pull request, pull request open, changed, clean. Each has its own symbol shape, so it reads without
colour and on the selection highlight. The row's other side is the task's <code>+N −M</code>; rest the pointer on
it for the branch, the repositories, the pull request and its checks, the age and the prompt. A task with a
single thread is a single row — selecting it shows that thread's terminal — and its threads only appear nested
from the second one on.</p>
<p><b>Mark as Read</b> (<kbd>⇧⌘U</kbd>, or the thread's context menu) clears a waiting thread's attention once
you have seen it: the mark, the badge and the notification go. The next question it asks brings them back.</p>
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
<p>The right-hand panel, four tabs, always about the current selection:</p>
<table>
  <tr><th>Tab</th><th>Shows</th><th>Key</th></tr>
  <tr><td><b>Graph</b></td><td>one card per repository of the scope</td><td></td></tr>
  <tr><td><b>Delta</b></td><td>the diff of the task, the working tree, or the branch vs <code>origin</code></td><td><kbd>⌘D</kbd></td></tr>
  <tr><td><b>Base</b></td><td>the untouched checkout: files, search, history</td><td><kbd>⇧⌘B</kbd></td></tr>
  <tr><td><b>PRs</b></td><td>open pull requests of the repository</td><td><kbd>⇧⌘P</kbd></td></tr>
</table>
<p>Drag its left edge to resize; <kbd>⌥⌘I</kbd> hides it.</p>
"""

TASKS = """
<div class="eyebrow">Guide</div>
<h1>Tasks and sandboxes</h1>
<p class="lede">A task is a prompt, a branch and one worktree per repository. You write the prompt; the driver
names the branch the way your repository already names branches.</p>

<h2 id="create">Creating a task</h2>
<p><kbd>⇧⌘T</kbd>, or <b>New Task</b> at the bottom of the sidebar. The first step asks for two things: what
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
  <tr><td>a pull request — <code>…/pull/6613</code>, <code>owner/repo#6613</code>, or <code>#6613</code> in a single-repository scope</td><td>its repository, its head branch checked out, and the task bound to it</td></tr>
  <tr><td>a repository of the scope, by folder name, path or <code>owner/repo</code></td><td>the repositories the task sandboxes</td></tr>
  <tr><td>a branch that already exists</td><td>a start point that continues it instead of branching</td></tr>
</table>
<p>Repositories are matched on their <code>origin</code> remote, not on the folder name — a pull request of
<code>acme-devops/acme-front</code> finds the clone you keep in a folder called <code>front</code>.</p>
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
created.</p></div>

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
in the worktree. A single-repository scope puts the worktree at the task root itself.</p>
<p>The <code>sandboxes</code> folder carries a <code>.metadata_never_index</code> marker, so Spotlight leaves it
alone: no indexing of every worktree's <code>node_modules</code>, and no second copy of your files in search
results.</p>
<p>The branch starts from the repository's base — <code>origin/&lt;default&gt;</code> when it can be resolved,
the local default branch otherwise.</p>

<h2 id="setup">Setup and teardown</h2>
<p>A fresh worktree has the committed tree and nothing else: no <code>node_modules</code>, no <code>.env</code>.
Right after <b>Create</b>, in the background, Scope prepares each sandbox — and the task's first thread waits for
it before it starts:</p>
<ol>
  <li>It copies the files your base checkout keeps out of git, <code>.env*</code> by default. A file already in the
  sandbox is never overwritten, and nothing is followed out of the repository: <code>..</code>, a symlink leading
  outside, a sandbox folder that is a symlink are all refused. A copied file the repository does not ignore is
  added to <code>.git/info/exclude</code>, so it cannot end up in a commit.</li>
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
sandboxes can run the same dev server side by side. Its threads get <code>SCOPE_PORT</code> too.</p>
<p>The task row shows a gear while the setup runs and a warning triangle if it failed; the failure lands in the
Problem Center with the end of the log and <b>Run Setup Again</b>. Untick <b>Run setup</b> in the New Task
sheet — or pass <code>--no-setup</code> to <code>scope task new</code>, <code>run_setup: false</code> over MCP —
to skip the command; the files are copied anyway.</p>
<p>The <b>Teardown</b> field is the other end: it runs in each sandbox before Archive or Close removes it, with
the same variables and a ten-minute limit. If it fails, the sandbox stays, the failure is shown, and you choose
whether to remove it anyway.</p>

<h2 id="threads">Threads inside a task</h2>
<p>Creating the task opens the first thread on the spot, in the sandbox, with your prompt already sent to the
driver.</p>
FIG_THREAD
<p><kbd>⌘T</kbd> inside a task opens more threads in the same sandbox — a shell to run the tests next to the
agent doing the work, a second agent on the same branch.</p>

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

<h2 id="lifecycle">Archiving and closing</h2>
<table>
  <tr><th>Action</th><th>Effect</th></tr>
  <tr><td><b>Archive</b></td><td>removes every worktree, keeps the branches and the record</td></tr>
  <tr><td><b>Close…</b></td><td>removes the worktrees and the record; optionally deletes the branches</td></tr>
</table>
<p>Both refuse to run on a dirty sandbox unless you force them, and closing refuses to delete a branch that is
not merged. Scope prunes stale worktrees on every launch.</p>

<h2 id="from-pr">Starting from a pull request</h2>
<p>Two ways in, one result. Name the pull request in the prompt, or open it from the <b>PRs</b> tab, which
lists the open pull requests of a repository through <code>gh</code>. Either way the sandbox sits on the PR's
head branch — including a fork's head — the task is bound to the pull request, and you review and push back
without touching your own checkout.</p>
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
counts. <kbd>j</kbd>/<kbd>k</kbd> move between files, <kbd>[</kbd>/<kbd>]</kbd> between hunks.</p>

<h3 id="diff">The diff</h3>
FIG_HUNK
<p>Native text: selectable, searchable with <kbd>⌘F</kbd>, with both line numbers, and a copy / reveal /
open-in-editor row for the file.</p>

<h3 id="publish">Commit, push, open the PR</h3>
<p>The footer of the panel carries the three actions, per repository, with the state next to them
(<i>10 uncommitted</i>, <i>clean</i>, <i>3 ahead</i>). <b>Create PR</b> shells out to <code>gh</code> and links
the resulting pull request to the task, so the PRs tab keeps showing it.</p>

<p>The box at the end of each file row marks it as <b>viewed</b>: the row dims, so what is left to read stands
out. The mark lasts while the file's diff stays the one you looked at; as soon as the agent changes that file
again, it clears itself.</p>

<h2 id="comments">Commenting on lines</h2>
<p>Review the agent's work where you read it. In the diff, a <b>+</b> appears in the line-number gutter under
the pointer: click it to comment on that line, or drag down the gutter to comment on a range. The comment
editor opens under the lines (<kbd>⌘↩</kbd> adds it). Comments show as tinted rows under the lines they cover;
click one to edit or delete it, or open the list from the review strip above the action bar.</p>
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
  <li><b>Files</b> — a tree and a read-only viewer with line numbers.</li>
  <li><b>Search</b> — <code>git grep</code> across the checkout, with case, regex, whole-word and folder filters.</li>
  <li><b>History</b> — recent commits of the branch.</li>
</ul>
FIG_BASE_SEARCH
<p><b>Pull</b> is fast-forward only and refuses on a dirty tree. <b>Shell</b> opens a thread rooted at the base
checkout — useful when you want to run something against the real branch rather than a sandbox.</p>

<h2 id="prs">Pull requests</h2>
<p><kbd>⇧⌘P</kbd>. Open pull requests of the selected repository, through the <code>gh</code> CLI and your
existing GitHub authentication: title, number, author, branch, checks and review state. Open one in the
browser, or turn it into a task whose sandbox sits on the PR's head.</p>
<div class="note"><p>The panel needs <code>gh auth login</code> and a GitHub remote. A repository without one
simply shows nothing to list.</p></div>

<h2 id="pr-lifecycle">A task's pull request, to the merge</h2>
<p>Once a task has a pull request — created from the Delta panel, or the one it was opened on — the summary band
lists its checks, refreshed every minute: state, name, and a link to each check's page.</p>
<ul>
  <li><b>Send to Thread</b> on a failed check fetches the failed steps' log with <code>gh run view --log-failed</code>
  and pastes its end, with a sentence naming the check, into the task's thread — the same delivery as a review, so
  a thread mid-turn gets it when the turn ends. A check that is not a GitHub Actions job has no log to fetch; the
  thread gets its link.</li>
  <li><b>Merge</b> appears in the action bar when GitHub says the pull request merges cleanly. It uses the method
  the repository allows (merge commit, else squash, else rebase), asks first, and then offers to close the task,
  which removes its sandboxes and deletes the branch the task created — never a branch name it would have to guess.</li>
  <li><b>Fix Conflicts</b> replaces it when the pull request conflicts with its base: the thread is asked to merge
  the base into the branch, resolve, run the tests and push.</li>
</ul>
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
  <tr><td><b>Level 1</b></td><td>the default driver, run headless once per repository</td><td>the purpose sentence, the relations between repositories, tags</td></tr>
</table>
<p><b>Analyze</b> in the panel header runs both; the split button runs level 0 alone, which needs no agent and
no network. Results are cached per repository, keyed by HEAD plus the hashes of the README and manifests, so
re-analysing an unchanged repository costs nothing.</p>

<h2 id="editing">Editing a card</h2>
<p><b>Edit</b> on any card opens the fields for hand-editing. An edited card is marked and generation never
overwrites it again — the graph is a document you own, not a cache the app owns.</p>
FIG_GRAPH_PANEL
<p>Cards are stored as one JSON file per scope in <code>~/.scope/graph/&lt;scope-slug&gt;.json</code>. Editing
that file by hand works too; <b>Refresh Scope</b> (<kbd>⌘R</kbd>) picks it up.</p>

<h2 id="projection">How agents see it</h2>
<p>When a task is created, the cards of the repositories it touches are projected into the task's
<code>AGENTS.md</code>, under the goal. The agent starts knowing what each repository is for, how to install
it and how to run its tests, instead of spending its first minutes rediscovering that.</p>

<h2 id="filter">Finding things</h2>
<p>The filter field above the cards matches path and stack at once: type <code>go</code> to get the Go
services, <code>api</code> to get everything whose path says so.</p>
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
  "env": {},
  "context": { "file": "CLAUDE.md", "mode": "generate" },
  "resume": ["claude", "--resume", "{resume_id}"],
  "headless": ["claude", "-p", "{prompt}", "--output-format", "json"],
  "headlessLight": ["claude", "-p", "{prompt}", "--output-format", "json", "--model", "haiku",
                    "--tools", "Bash", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
                    "--allowedTools", "Bash(gh pr view:*),Bash(gh pr list:*),Bash(gh repo view:*),Bash(git branch:*),Bash(git log:*)"],
  "prompt": ["{prompt}"],
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
</table>
<p>A profile that uses a placeholder Scope cannot fill is refused at load time rather than at launch time.</p>

<h2 id="resolution">How the command is resolved</h2>
<p>Scope probes your login shell once at launch (<code>$SHELL -ilc</code> by default) and resolves every
<code>command</code> against that <code>PATH</code>. That is why a driver installed through nvm, mise or a
shell function works here exactly as it does in your terminal. The mode is a setting: interactive login,
login only, or no probe at all.</p>
<p><b>Settings → Drivers</b> lists every profile with the binary it resolves to, and flags the ones it cannot
find. <b>Reload</b> picks up edits without restarting.</p>

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
scope thread new [options]          <span class="c"># open a thread, print its id</span>
scope thread send &lt;id&gt; &lt;text&gt;       <span class="c"># type into it and press ↩ (--no-enter)</span>
scope thread read &lt;id&gt;              <span class="c"># the last lines of its terminal (-n, --cursor)</span>
scope thread stop &lt;id&gt;              <span class="c"># stop its process; the row stays</span>
scope thread close &lt;id&gt;             <span class="c"># hang it up and remove it</span>
scope task new &lt;prompt&gt; [options]   <span class="c"># branch + worktrees + first thread</span>
scope task close &lt;id|slug&gt;          <span class="c"># undo a task (--delete-branch, --force)</span>
scope mcp                           <span class="c"># speak MCP on stdio</span>
scope ping                          <span class="c"># is Scope listening, and what may agents do</span></code></pre>
<p>Every command takes <code>--json</code>. <code>--scope</code> accepts a slug, a name, an id or a path;
omitted, it is the caller's own scope, then the scope holding the working directory, then the only scope
there is. <code>--sock</code> and <code>--home</code> say which Scope to talk to — a Debug build listens on
<code>~/.scope-debug/scope.sock</code>.</p>
<pre><code>$ scope thread new --scope acme --driver claude-code -p "why is CI red?"
thread 3f9a2c17be04 — acme [claude-code] in acme
/Users/me/work/acme

$ scope task new "fix the flaky login test" --repo api --dry-run
would create the task “Fix the flaky login test”
branch      fix/flaky-login-test
slug        fix-flaky-login-test
sandbox     ~/.scope/sandboxes/acme/fix-flaky-login-test
repo        api → ~/.scope/sandboxes/acme/fix-flaky-login-test/api (branch created)</code></pre>
<p><code>scope thread read</code> prints the last 200 lines of a thread's terminal — scrollback included, up to
2000 with <code>-n</code> — between two markers, under a line saying the text is untrusted terminal output. Line
numbers stay put as the scrollback grows: the last line tells you the <code>--cursor</code> that reads the page
before. It is how an agent that opened a thread finds out what that thread said, without typing into it; like
<code>thread send</code>, an agent may only read the threads it opened.</p>
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
<code>scope_thread_new</code>, <code>scope_thread_send</code>, <code>scope_thread_read</code>, <code>scope_thread_stop</code>,
<code>scope_thread_close</code>, <code>scope_task_new</code>, <code>scope_task_close</code>,
<code>scope_ping</code>. They are the same
commands: the server holds no logic of its own, so the terminal and the agent can never drift apart.</p>
<p><b>Settings ▸ Automation ▸ MCP server</b> registers it with Claude Code, Codex and Cursor for your user, so
every session you start — in Scope or in any other terminal — has it: Claude Code through its own
<code>claude mcp add --scope user</code>, Codex in <code>~/.codex/config.toml</code>, Cursor in
<code>~/.cursor/mcp.json</code>, touching only the <code>scope</code> entry. The command is the helper inside the app
bundle, so an update keeps it working. By hand, the same thing:</p>
<pre><code>{"mcpServers": {"scope": {"command": "/Applications/Scope.app/Contents/Helpers/scope", "args": ["mcp"]}}}</code></pre>
<p><code>scope_task_new</code> is marked destructive and its description tells the agent to call it with
<code>dry_run</code> first: the answer is then the title, branch, sandbox and worktrees it would create,
with nothing written.</p>

<h2 id="automation">What an agent is allowed to do</h2>
<p>The <code>scope</code> command line in your own terminal is you, and is never filtered. A request from
inside a thread — or through <code>scope mcp</code> from anywhere, since a globally registered server is reached
from sessions Scope never launched — is an agent, and goes through <b>Settings ▸ Automation</b>:</p>
<table>
  <tr><th>Setting</th><th>Default</th><th>What it does</th></tr>
  <tr><td>Let agents drive Scope</td><td>on</td><td>Off refuses every write from a thread.</td></tr>
  <tr><td>Depth ceiling</td><td>1</td><td>A thread you opened is at depth 0. At 1, it may open a thread and that thread may not open another.</td></tr>
  <tr><td>Opening a thread</td><td>without asking</td><td>Also available: after asking, never.</td></tr>
  <tr><td>Creating a task</td><td>without asking</td><td>A task writes a branch and a worktree per repository, all of it undone by closing the task. Set it to after asking to confirm each one.</td></tr>
</table>
<p>An agent may type into, stop or close only the threads it opened itself; an agent outside Scope, only the
threads agents outside Scope opened. Typing into someone else's agent is a prompt it never agreed to. Closing a
task — worktrees removed, branch deleted when asked — follows the same approval as creating one.</p>
<p>Every thread records who opened it and at what depth, so the chain survives a restart —
<code>scope list threads</code> shows it. A <code>SCOPE_THREAD</code> that names no thread the app is
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
  <tr><td><code>SessionStart</code></td><td>running; the session id is captured, which is what lets <b>Relaunch</b> pick the session back up</td></tr>
  <tr><td><code>UserPromptSubmit</code>, <code>PostToolUse</code></td><td>running</td></tr>
  <tr><td><code>Notification</code>, <code>PermissionRequest</code></td><td><span class="dot waiting"></span>waiting — and a macOS notification when Scope is in the background</td></tr>
  <tr><td><code>Stop</code></td><td><span class="dot done"></span>done</td></tr>
  <tr><td><code>SessionEnd</code></td><td>idle</td></tr>
</table>
<p>Your own <code>~/.claude/settings.json</code> is not modified: the per-thread file lives under
<code>~/.scope/threads/</code> and is passed on the command line.</p>

<h2 id="others">Codex and Cursor</h2>
<p>Codex is wired through its <code>notify</code> configuration and Cursor through its hooks, with the same
helper and the same socket. Both profiles ship with <code>adapter</code> set; a tool without one still runs
perfectly — its row simply shows no live state.</p>

<h2 id="notifications">Notifications and the badge</h2>
<p>When a thread starts waiting while Scope is not frontmost, you get a macOS notification with <b>Go to
thread</b> and <b>See delta</b> actions. The Dock badge counts the waiting threads, and the optional menu bar
item lists them, so you can leave the window behind and come back exactly when an agent needs you.</p>

<h2 id="socket">The socket</h2>
<p><code>$SCOPE_SOCK</code> points at <code>~/.scope/scope.sock</code>. One JSON object per line:</p>
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
└── scope.sock            <span class="c"># hook events</span>

~/Library/Application Support/Scope/ui-state.json   <span class="c"># selection, expansion, panel widths</span></code></pre>
<p>Every store writes atomically. A file with a newer schema version than the running build is reported and
left alone, never overwritten; a corrupt file is quarantined next to it rather than deleted.</p>

<h2 id="palette">The command palette</h2>
<p><kbd>⌘K</kbd> opens one field over everything: the actions of the current context, the files of the
selection, the repositories of the scope and the open threads. <kbd>⌘P</kbd> opens it straight in file mode.</p>
FIG_PALETTE
<div class="note warn"><p>While a terminal has keyboard focus it keeps <kbd>⌘K</kbd> for itself. Click outside
the terminal, or use <b>Go → Command Palette…</b>, until that is fixed.</p></div>

<h2 id="shortcuts">Keyboard</h2>
<table>
  <tr><th>Key</th><th>Action</th></tr>
  <tr><td><kbd>⌘O</kbd></td><td>Declare a scope…</td></tr>
  <tr><td><kbd>⌘R</kbd></td><td>Refresh scope</td></tr>
  <tr><td><kbd>⌘T</kbd></td><td>New thread in the current context</td></tr>
  <tr><td><kbd>⇧⌘T</kbd></td><td>New task… (or undo the last close)</td></tr>
  <tr><td><kbd>⌘W</kbd> / <kbd>⇧⌘W</kbd></td><td>Close thread / close window</td></tr>
  <tr><td><kbd>⌘.</kbd></td><td>Stop the thread</td></tr>
  <tr><td><kbd>⌥⌘R</kbd></td><td>Relaunch the thread, picking the driver's session back up when it can</td></tr>
  <tr><td><kbd>⌘1</kbd>–<kbd>⌘9</kbd>, <kbd>⇧⌘[</kbd> / <kbd>⇧⌘]</kbd></td><td>Switch threads</td></tr>
  <tr><td><kbd>⌘↩</kbd></td><td>Newline in the terminal (sent as meta <kbd>↩</kbd>)</td></tr>
  <tr><td><kbd>⌘←</kbd> / <kbd>⌘→</kbd>, <kbd>⌘⌫</kbd> / <kbd>⌘⌦</kbd></td><td>Start / end of the line, delete back to its start / to its end (sent as <code>^A</code> <code>^E</code> <code>^U</code> <code>^K</code>)</td></tr>
  <tr><td><kbd>⌥←</kbd> / <kbd>⌥→</kbd>, <kbd>⌥⌫</kbd> / <kbd>⌥⌦</kbd></td><td>Move and delete by word; every other <kbd>⌥</kbd> key types your layout's character</td></tr>
  <tr><td><kbd>⌘K</kbd></td><td>Command palette</td></tr>
  <tr><td><kbd>⌘P</kbd> / <kbd>⇧⌘O</kbd></td><td>Go to file</td></tr>
  <tr><td><kbd>⌥⌘F</kbd></td><td>Filter the sidebar</td></tr>
  <tr><td><kbd>⌘D</kbd> / <kbd>⇧⌘B</kbd> / <kbd>⇧⌘P</kbd></td><td>Delta / Base / Pull requests</td></tr>
  <tr><td><kbd>⌥⌘I</kbd></td><td>Toggle the inspector</td></tr>
  <tr><td><kbd>⌃⌘S</kbd></td><td>Show / hide the sidebar</td></tr>
  <tr><td><kbd>⌘M</kbd></td><td>Maximize the thread: it fills the window, <kbd>⌘M</kbd> again restores (minimize is <kbd>⌥⌘M</kbd>)</td></tr>
  <tr><td><kbd>⇧⌘U</kbd></td><td>Mark a waiting thread as read: its attention clears until it asks again</td></tr>
  <tr><td><kbd>⌘E</kbd> / <kbd>⇧⌘E</kbd></td><td>Open the selection / the task in your editor</td></tr>
  <tr><td><kbd>⌘F</kbd>, <kbd>⌘G</kbd></td><td>Find in the terminal or the diff</td></tr>
  <tr><td><kbd>⌥⌘K</kbd></td><td>Clear the terminal scrollback</td></tr>
  <tr><td><kbd>⌘/</kbd></td><td>This list, in the app</td></tr>
</table>

<h2 id="settings">Settings</h2>
FIG_SETTINGS
<ul>
  <li><b>General</b> — config folder, default driver, editor command, terminal font size, appearance
  (follow the system, or always dark, which is what agent TUIs assume) and cursor shape — underline, bar or
  block, steady or blinking; a blinking caret fades in and out rather than switching on and off, and a program
  can still ask for its own shape — whether <kbd>⌥</kbd> types the character your layout puts there (the
  default, so a French keyboard still gets its braces) or acts as Meta, plus notification status.</li>
  <li><b>Shell Environment</b> — how the login shell is probed, and the resulting <code>PATH</code>.</li>
  <li><b>Drivers</b> — every profile, the binary it resolves to, and <b>Reload</b>.</li>
  <li><b>Automation</b> — install the <code>scope</code> command line on your PATH, whether agents may drive
  Scope, how deep agents may open agents, and whether opening a thread or creating a task asks you first. See
  <a href="cli.html">Command line and MCP</a>.</li>
</ul>
<p>The editor command is a template: <code>["code", "-g", "{file}:{line}"]</code>. <code>{path}</code>,
<code>{file}</code> and <code>{line}</code> are filled in; unused parts are dropped rather than left dangling.</p>

<h2 id="updates">Updates</h2>
<p>Scope ships with Sparkle. <b>Scope → Check for Updates…</b> reads a signed appcast attached to the latest
GitHub release; updates are verified with an EdDSA signature before they are applied. Prereleases
(<code>v1.0.0-rc.1</code>) are excluded from the stable feed.</p>

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
    "FIG_SIDEBAR": figure("sidebar", "The sidebar: loose threads, then each task with its threads; repositories on demand."),
    "FIG_SETTINGS": figure("settings", "Settings → General.", "shot narrow"),
    "FIG_PROMPT": figure("newtask-prompt", "Step one: the request, the driver, the repositories."),
    "FIG_LOADING": figure("newtask-loading", "The driver runs headless while the derived name stands in."),
    "FIG_PROPOSAL": figure("newtask-proposal", "The proposal follows the repository’s own convention."),
    "FIG_THREAD": figure("claude-thread", "The first thread starts with the task's prompt.", "plain"),
    "FIG_DELTA_FILES": figure("delta-panel", "Ten files changed across the task’s repositories, with the diff below."),
    "FIG_HUNK": figure("delta-hunk", "A hunk, with both line numbers and selectable text."),
    "FIG_BASE_VIEWER": figure("base-viewer", "Base: the tree and the read-only viewer."),
    "FIG_BASE_SEARCH": figure("base-search", "Search runs git grep across the checkout."),
    "FIG_GRAPH_CARD": figure("graph-card", "A repository card: purpose, stack, entry points, relations."),
    "FIG_GRAPH_PANEL": figure("graph-panel", "The graph of a scope; “edited” marks a card generation will not touch."),
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
     "one socket, with a depth ceiling and an approval for anything that writes.", CLI, False),
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

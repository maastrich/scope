# Information architecture — the inspector's subject, findability, and scope switching

Design research only. No view code was modified. Line numbers refer to `main` at `986ffd5` (v0.13.0).

Builds on [`RESEARCH.md`](RESEARCH.md) (the no-glass directions), [`OPAQUE_AQUA.md`](OPAQUE_AQUA.md) (direction A,
shipped) and [`BRAND.md`](BRAND.md) (palette and guard-rails). Nothing here reopens those decisions; two of them
constrain §4 directly.

The three complaints this answers, verbatim:

1. *« l'ensemble ne me va pas, j'ai du mal à avoir les infos que je veux voir quand je veux les voir »*
2. *« sur le panneau de droite l'onglet Base est souvent focus sur le mauvais repo/workspace »*
3. *« je voudrais pouvoir naviguer entre les scopes comme je navigue entre les profils dans Arc Browser »*

**The short version.** The three are one problem seen from three sides: the app has one global piece of "where am
I" state, and several panels that each derive their own subject from it by a different rule. Base is wrong because
an explicit pick outlives the context it was made in. Information is hard to reach because most answers require the
selection to already be on the right row. Switching scope feels heavy because it resets that selection instead of
restoring it — the memory is even written (`lastThreadByScope`) and never read. The recommendation is to make a
scope a remembered *place* (Arc's Space), give the inspector one visible subject, and add an Arc-style rail and
shortcuts on top.

---

## 1. Pain 1 — the Base tab shows the wrong repository

### 1.1 The rule as built

`AppModel.baseRepo`, `App/Scope/Model/BaseModel.swift:259-272`, first match wins:

| # | Source | Code |
|---|---|---|
| 1 | The header pick for the current scope, `base.pickedRepo[scope.id]` | `:261` |
| 2 | The selected sidebar row, if it is a repo row | `:262` |
| 3 | The shown thread's cwd, if it is a base checkout (`cwdKind == .repoBase`) | `:263-266` |
| 4 | The first repository of the selected task, `task.activeRepos.first` | `:267-270` |
| 5 | The first repository of the scope, `scope.repos.first` (sorted by relative path) | `:271` |

The header comment of `InspectorView.swift:7-10` states the intent — *Base follows the task's repositories, or the
selected repo when no task is selected* — which is rules 4 and 2. Rule 1 is not in that sentence, and rule 1 is the
one that runs first.

`pickedRepo` is written in three places and cleared in none:

- the picker in the Base header — `BaseView.swift:28-31`;
- `showBase(repo:in:)` — `BaseModel.swift:276-280` — called by the repo row's **See Base** (`RepoRow.swift:66`), by a
  graph card (`Graph/RepoCardView.swift:171`), and by opening a base file from ⌘P (`AppModel+Search.swift:135-140`).

It is keyed by scope alone, lives in memory only (it is not in `UIState`, `UIStateStore.swift:7-22`), and nothing
on screen says a pick is in force.

Two neighbours matter because they decide *when* the user lands on Base at all:

- **The forced tab.** `InspectorView.swift:51-53` moves the inspector to Base whenever no task is selected and the
  tab needs one. `inspectorTab` is a single global (`AppModel.swift:97-99`) and nothing moves it back. Select a loose
  thread or a scope row once and every task you return to opens on Base instead of Delta.
- **The scope switch.** `selectScope` sets `selection = .scope(id)` (`AppModel.swift:176-179`), which clears the shown
  thread (`syncThreadFromSelection`, `:595-597`), which means no task, which forces the Base tab.

### 1.2 Where it yields the wrong repository

| # | Scenario | What happens | Why |
|---|---|---|---|
| W1 | **Switching tasks or threads after any pick.** Pick `hashup` once (picker, See Base, a graph card, or ⌘P on a base file), then select a task on `logger`. | Base stays on `hashup`. The band above it names the `logger` task. | Rule 1 outranks rule 4 and the pick is never cleared. |
| W2 | **The stale pick looks legitimate.** Same state as W1. | The picker lists `logger` *and* `hashup`, with the tooltip "The repositories of the task". | `baseRepoCandidates` appends whatever is shown to the task's own list (`BaseModel.swift:289`). |
| W3 | **Clicking a repo row.** With a pick in force, click another repository in the sidebar. | The sidebar highlights the row you clicked; Base and its band keep showing the picked one. | Rule 1 outranks rule 2. |
| W4 | **Multi-repo task.** Task on `api` + `web`, thread working in `web`, or Delta focused on a `web` file. | Base shows `api`. | Rule 4 is `activeRepos.first`. It reads neither the thread's directory nor `delta.focusedRepo` (`DeltaModel.swift:84-87`). |
| W5 | **Loose thread at the scope root.** A thread opened in the scope folder, `cd`'d into `vite-plugin-marp`. | Base shows the alphabetically first repository of the scope. In `@maastrich`, with ~35 repositories, that is `ascension`. | Rule 3 only matches a thread *created* in a base checkout. The live directory is known (`ThreadSession.reportedDirectory`, already used for the window subtitle) and unused here. |
| W6 | **Scope row selected.** | Same as W5: the first repository, for no reason the user gave. | Rule 5. |
| W7 | **Scope switch.** Switch to another scope from the header menu or ⌘K. | Terminal gone, inspector flipped to Base, on that scope's stale pick or its first repository. | §1.1: `selectScope` → no thread → no task → forced tab → rule 1 or 5. |
| W8 | **Returning to a task after W5–W7.** | The task opens on Base, not on the Delta you left it on. | The forced tab is never restored. This is why Base is seen "often": the app chooses it more than the user does. |
| W9 | **Relaunch.** Quit with a pick in force. | The selection is restored, the pick is not: Base shows a different repository than before the quit. | `pickedRepo` is not persisted; `selection`, `inspectorTab` are. |
| W10 | **Selection vs. the terminal on screen.** A task row is selected, its thread is live. | Consistent today — `currentTask` and `currentThread` agree (`AppModel.swift:599-604`) — but Base still ignores *where that thread is* (W4). | — |
| W11 | **Lost place inside Base.** Open a file or run a search, glance at another task, come back. | Tree collapsed, file closed, query and results gone. | One `BaseModel` for the app; `show(repo:)` resets everything on any repo change (`BaseModel.swift:68-85`). |
| W12 | **The Pull Requests sheet.** | Lists the Base repository unless it has its own pick, and the sidebar button's count is that one repository's, under a label that reads scope-wide. | `pullRequestsRepo` falls back to `baseRepo` (`PullRequestsModel.swift:138-142`); `GlobalViewsRow.swift:59-64`. |
| W13 | **"Workspace".** In a task thread, the user expects the files the agent sees. | Base shows the *base checkout* — `main`, not the task's worktree — and only the grey caption "base checkout" says so. | By design (spec §4.5), but the tab never says why you would want it instead of the sandbox. |

W1–W3 are a bug by any reading. W4–W6 are a rule that is too weak. W7–W9 are state that is global where it should
be per place. W13 is wording.

### 1.3 Options

| Option | What | Cost |
|---|---|---|
| **P1 — delete the pick.** Base strictly follows the selection. | Removes W1–W3, W9. | A multi-repo task can then only ever show its first repository, and See Base / a graph card can no longer open a repo without changing the sidebar selection — which closes the terminal. |
| **P2 — clear the pick on every selection change.** | Removes W1–W3. | The pick dies when you glance at another thread of the *same* task; W4–W6 untouched. |
| **P3 — key the pick by context, show it, and follow the thread's directory.** | Removes W1–W6, W9. | A resolver to write and a chip to draw. |

### 1.4 Proposed rule — P3

**One subject, stated on screen.** The Base panel shows, in order:

1. **the pin of the current context**, if there is one;
2. the **selected repo row**;
3. the repository **containing the shown thread's directory** — `reportedDirectory ?? record.cwd`; a path inside a
   task sandbox maps to that task repo's base, a path inside a base checkout maps to that repository;
4. the **Delta panel's focused repository**, when Delta is on the selected task;
5. the task's first repository;
6. the repository this scope **last showed** in Base, else its first.

where:

- a **context** is the task (`.task(TaskID)`), or the loose thread (`.thread(ThreadID)`), or the scope row
  (`.scope(ScopeID)`). A repo row needs no pin — it *is* the repository.
- a **pin** is made by the picker, See Base, a graph card or ⌘P, and belongs to the context it was made in. Leaving
  the context leaves the pin behind; coming back finds it. It is persisted with the per-scope UI state (§4.3) and
  dropped when its task or thread is.
- a pin is **visible**: the band reads `hashup · pinned ✕`; without a pin it reads `hashup · follows the thread`
  (or `the task`, `the selection`). ✕, or picking **Follow selection** at the top of the picker, removes it.
- the picker lists the context's repositories — the task's own for a task — and offers the rest of the scope under
  a divider instead of silently appending the stale one (W2).

**The tab.** The inspector remembers the tab *of tasks* separately from the fallback. With no task it shows Base
without overwriting that memory, so returning to a task returns to Delta (W8).

**The wording** (W13). The band says `base checkout · main` in a task context, and the empty/first-use hint of the
tab says what Base is for: *the repository as it is on `main`, next to the task's sandbox*. Whether Base should also
browse the sandbox's files is a feature question left open in §7.

File-level changes:

| File | Change |
|---|---|
| `Sources/ScopeTasks/BaseSubject.swift` *(new)* | The resolver as a pure function over plain values: pins, selection kind, thread directory, task repos (relative path + sandbox path), scope repos (relative path + URL), Delta focus, last shown. Returns the repository and the *reason* (`pinned`, `selection`, `thread`, `delta`, `task`, `recent`, `first`). In the package because the app target has no tests. |
| `Tests/ScopeKitTests/BaseSubjectTests.swift` *(new)* | One case per row of §1.2. |
| `App/Scope/Model/BaseModel.swift` | `pickedRepo: [ScopeID: String]` → `pins: [BaseContext: String]`; `baseRepo` calls the resolver and exposes `baseSubjectReason`; `showBase` pins the *current context*; `baseRepoCandidates` stops appending (`:289`). |
| `App/Scope/Views/Inspector/Base/BaseView.swift` | Picker gains **Follow selection** and the divider; binding writes a pin. |
| `App/Scope/Views/Inspector/InspectorView.swift` | Delete the forced tab (`:51-53`); the band shows the Base subject and its reason whenever the Base tab is up, task or not. |
| `App/Scope/Model/AppModel.swift` | `inspectorTab` becomes a computed view over a stored `taskInspectorTab`. |
| `App/Scope/Model/PullRequestsModel.swift` | `pullRequestsRepo` falls back to the resolver *without* the Base pin (`:138-142`). |
| `App/Scope/Environment/UIStateStore.swift` | Persist pins and `taskInspectorTab`. |

---

## 2. Pain 2 — findability

### 2.1 Questions against surfaces

"Needs selection" means the answer is only on screen if the sidebar selection is already on the right row.
Changing the selection is not free: selecting a repo or scope row replaces the terminal with an empty view
(`AppModel.swift:595-597`), and selecting another thread moves the keyboard.

| # | Question | Surface today | Cost | Needs selection | Verdict |
|---|---|---|---|---|---|
| Q1 | **What needs me — in this scope?** | `AttentionBanner` + ⌥⌘↩ (`Shared/AttentionCounter.swift`), square state dot on the row, task glyph (`TaskStatus.resolve`) | 0 | no | **Good**, unless the counter preference is *toolbar* or *off*. |
| Q2 | **What needs me — in another scope?** | Dock badge, menu bar extra, notifications. Nothing in the window: the banner counts `waitingThreadsInCurrentScope` (`AppModel+Attention.swift:14-17`). | leave the window | no | **Gap.** ⌥⌘↩ does cross scopes, but nothing tells you it will. |
| Q3 | **What is this agent doing right now?** | The terminal; the state pill in the toolbar (`SceneView.swift:39-43`). | 0 | yes — the shown thread only | OK for one thread. |
| Q4 | **What are the *other* agents doing?** | A state dot per row: running / waiting / done / failed / exited. No activity text, no last line. | 1 click per thread, and each click moves the terminal and the keyboard | yes | **Gap.** State is visible, activity is not. |
| Q5 | **Which repository is dirty?** | A dot on `RepoRow` (`RepoRow.swift:37-42`), in the Repositories section — **collapsed by default** (`ScopeState.reposShown`, ⌃⌘R). The Graph sheet's checkout picker mentions `dirty`. | 1 (expand), then scroll 35 rows | no | **Hidden.** The collapsed header shows a count of repositories, not of dirty ones. |
| Q6 | **Is a task's sandbox dirty?** | `TaskHoverCard` ("N uncommitted") after a **700 ms** rest (`TaskRow.swift:26`); `TaskSummaryBand` in the inspector. | hover + wait, or select + inspector open | band: yes | Slow. |
| Q7 | **What changed on this branch?** | `+N −M` on the task row (total); per repo in the hover card; the diff in Delta (⌘D). | 0 for the size, 1 for the diff | Delta: yes, and a *task* must be selected | **Good** for a task. No answer for a loose thread working in a base checkout. |
| Q8 | **Which task owns this thread?** | The sidebar nesting; `TaskSummaryBand` if the inspector is open. The window subtitle is `scope · cwd` (`ThreadToolbar.swift:16-18`) — the task is absent. | 0 if the sidebar is visible | no | **Gap under ⌘M** (thread maximised: sidebar and inspector both hidden) and in the palette, whose thread rows hint the state, not the task (`PaletteModel.swift:148-150`). |
| Q9 | **Is my base behind `origin`?** | The `behind N` badge of the Base tab (`BaseView.swift:159-170`), one repository at a time, after a fetch. | ⇧⌘B + the right repository | **yes, and on the rule of §1** | **Gap**, and the surface most exposed to pain 1. |
| Q10 | **Where is the pull request, are the checks green?** | Task glyph, band chip, Pull Request tab, hover card. Scope-wide: the Pull Requests sheet, one repository at a time. | 0–1 | tab: yes | Good per task. The sheet's button count is one repository's under a scope-wide label (W12). |
| Q11 | **Which scope am I in, what is in the others?** | The header name; a plain folder icon for every scope (`ScopeRow.swift:20`). Other scopes: the header menu (name + repo count), ⌘K. | 1 to see the list | — | **Gap.** No identity, no state, no shortcut — §3. |
| Q12 | **What is the inspector showing, and why that?** | `TaskSummaryBand` names the task; for Base, a small picker label. | 0 | — | **Gap.** The panel never says *why* it is on this repository (§1). |

### 2.2 The pattern

- **Answers are behind selection.** Q3, Q4, Q6, Q9, Q12 are only reachable by moving the one global selection, and
  moving it has side effects (terminal swapped, keyboard moved, inspector tab flipped). The earlier redesign
  (`c7b7d0f`, *keep the inspector on the task, open the graph and pull requests from the sidebar*) fixed the
  two-subjects-in-one-header problem for Graph and PRs; Base kept a second subject through the pick.
- **Repository health is the least reachable thing in the app.** Dirty and behind are both per-repository, both
  behind a collapsed section or a single-repository tab, in a scope that has 35.
- **Nothing aggregates across scopes** inside the window.

### 2.3 What to add

Small, each tied to a row above; none needs a new screen.

| For | Change | Where |
|---|---|---|
| Q12, Q9 | The **subject line** of §1.4: the band always names what the visible panel is about and why. | `InspectorView.swift`, `TaskSummaryBand.swift` |
| Q5, Q9 | The collapsed **Repositories** header carries the exceptions: `Repositories 35 · 2 dirty`. Behind-count joins it once it is known without opening Base (it needs a throttled fetch per repository; open question in §7). | `SidebarView.swift:194-196, 279` |
| Q8 | The window subtitle becomes `scope · task · cwd` when the thread has a task; the palette's thread rows hint `task · state`. | `ThreadToolbar.swift:16-18`, `PaletteModel.swift:148-150` |
| Q2, Q11 | Per-scope attention marks on the scope rail (§4.4). | new `ScopeRail.swift` |
| Q10 | The Pull Requests button either counts the scope or names its repository. | `GlobalViewsRow.swift:59-64` |
| Q6 | The hover card also opens at once on ⌥-hover or from the row's context menu (**Show Details**), keeping the 700 ms rest for a plain hover. | `TaskRow.swift` |
| Q4 | **Not designed here.** A one-line "last activity" per thread needs hook data this research did not audit. Listed in §7. | — |

---

## 3. Pain 3 — what Arc actually does

Sources are Arc's own help center and release notes unless marked. Items no source confirms are marked
**unverified** and nothing below depends on them.

### 3.1 Spaces and Profiles are two things

- A **Space** is a browsing area: *"Each Space has its own Pinned section, Unpinned section, Theme, and Icon."*
  [[Spaces]](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas)
- A **Profile** is an isolation container — logins, cookies, history, extensions, Favorites, archive timing — that
  *one or several* Spaces use.
  [[Profiles]](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing)

The switcher, the swipe, the colour and the icon all belong to **Spaces**. What the user calls "profiles" is, by
its UI, the Space. That is the thing to map.

### 3.2 The model

| Aspect | Arc | Source |
|---|---|---|
| Switcher | A row of Space icons at the **bottom of the sidebar**; click to switch; `+` creates one. | Spaces |
| Sidebar, top to bottom | Favorites grid (max 12) → Space title → pinned tabs and folders → a line → unpinned ("Today") tabs → Library at bottom-left. | [Favorites](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space), [Pinned Tabs](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around) |
| Gesture | Two-finger swipe left/right **in the sidebar only**. | Spaces |
| Shortcuts | ⌃1, ⌃2, … focus Space N. ⌥⌘← / ⌥⌘→ previous / next Space. ⌘1… is *tab* N. All remappable. | [Keyboard Shortcuts](https://resources.arc.net/hc/en-us/articles/20595231349911-Keyboard-Shortcuts) |
| Command bar | ⌘T, type the Space's name. | Spaces |
| Identity | Name, icon (emoji allowed), theme colour — per Space. Light / Dark is global. | Spaces, [release notes](https://resources.arc.net/hc/en-us/articles/20498293324823-Arc-for-macOS-2024-2026-Release-Notes) |
| Per Space | Pinned tabs, folders, unpinned tabs, theme, icon. | Spaces, Pinned Tabs |
| Per Profile | Favorites, history, cookies, logins, extensions, auto-archive timing. | Profiles |
| Global | Library (downloads, archive, media), Light/Dark, Little Arc. | [Library](https://resources.arc.net/hc/en-us/articles/19230634389911-Library-A-home-for-your-downloads-archived-tabs-easels-and-more) |
| Tabs you leave | Unpinned tabs auto-archive after 12 h idle by default; cannot be turned off; pinned tabs are exempt. | [Auto Archive](https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go) |
| Background activity | A tab left playing audio gets a mini controller at the bottom of the sidebar. | [Mini Player](https://resources.arc.net/hc/en-us/articles/19234766331799-Mini-Player-Watch-or-Listen-as-you-Browse) |
| Windows | A Space's tabs are the same in every window; a "Blank Window" opts out. | [Multiple windows](https://resources.arc.net/hc/en-us/articles/25590417429783-Why-Are-the-Same-Tabs-Appearing-Across-Multiple-Arc-Windows) |

**Unverified:** that the sidebar content slides horizontally on a switch; that returning to a Space restores the
tab you were on; how exactly a theme tints the window chrome (third-party descriptions only); whether each window
holds its own Space; whether the audio controller survives a *Space* switch.

### 3.3 What went wrong for Arc

- *"Only 5.52% of DAUs use more than one Space regularly"*; the product was *"too different, with too many new
  things to learn"*. [[Letter to Arc members, May 2025]](https://browsercompany.substack.com/p/letter-to-arc-members-2025)
- The Profile boundary leaked: release notes carry fixes for Little Arc *"opening in the wrong Space or suggesting
  the wrong Profile"* and for suggestions crossing Profiles. Favorites change silently with the Profile.
- Multi-window: *"I consistently had to keep mental track of which window actually had any given tab open."*
  [[K. J. Grant]](https://notes.keithjgrant.com/notes/2023/05/why-im-giving-up-on-arc/)
- Arc has been in maintenance since May 2025 and its maker was acquired by Atlassian in October 2025. The Space
  switcher is a finished, stable reference, not a moving one.

---

## 4. Mapping Arc onto Scope

### 4.1 Where Scope is today

- **One switcher, three entry points, no shortcut.** The header `Menu` (`ScopeRow.swift:16-39`), the *Scopes* section
  of ⌘K (`PaletteModel.swift:214-217`), ⌘O to declare. No key jumps to a scope; no gesture.
- **Switching resets instead of restoring.** Both entry points set `selection = .scope(id)`: the terminal is
  replaced by the scope's empty view and the inspector flips to Base (W7).
- **The memory is written and never read.** `lastThreadByScope` (`AppModel.swift:125`) is set on every thread
  selection (`:76`) and cleared on close (`:942-943`). No code reads it.
- **No identity.** Every scope is a `folder` glyph and a name. `ScopeDeclaration` (`ScopeCore/Models/ScopeConfig.swift:165`)
  has no icon or colour field.
- **No order control.** `moveScopes` exists (`AppModel.swift:730`) and has no caller.
- **State that is global and should not be:** `selection`, `selectedThreadID`, `inspectorTab`
  (`UIStateStore.swift:8-17`), the sidebar filter (`AppModel+Search.swift:36` — a filter typed in one scope hides
  rows in the next), the Base pick's lifetime.
- **State that is already per scope:** `reposShown`, `looseThreadsShown`, `lastDrivers`, a task's `isExpanded`.

### 4.2 Options

| Option | What | For | Against |
|---|---|---|---|
| **S1 — shortcuts and memory only.** Keep the header menu; add ⌃1…9, ⌥⌘←/→; restore each scope's place. | The smallest change that makes switching cheap. | Fixes the reset, which is most of the pain. | No identity, no cross-scope state (Q2, Q11). The switcher stays one click deep. |
| **S2 — scope as Space.** S1 + an icon rail at the bottom of the sidebar + per-scope identity + attention marks on the rail. | Arc's model, minus Profiles and theming. | Answers Q2 and Q11 with no new screen; every scope is one click or one key away; reuses the sidebar. | A new always-visible strip (26 pt) in a dense sidebar; two fields added to the config. |
| **S3 — one window (or native tab) per scope.** | The macOS-native answer. | Free ⌘\` and tab-bar switching; two scopes side by side. | `AppModel` is one-window by construction (one `selection`, one `focusedSceneValue`); it is the multi-window confusion of §3.3; and it makes Q2 *worse* — a waiting thread hides in another window. |
| **S4 — all scopes in one tree.** | No switching at all. | — | Already tried and replaced by `6192c48` (*show the current scope's tasks and threads*): 35 repositories and their tasks per scope do not fit one list. |

### 4.3 Recommendation — S2, built on S1

**A scope becomes a place you return to, not a filter you reapply.**

Per-scope state — a `ScopeUIState` record per scope, persisted in `ui-state.json`:

| State | Today | Proposed |
|---|---|---|
| Selected sidebar item | global | **per scope** — switching back restores the row |
| Shown thread | global (`lastThreadByScope` unread) | **per scope**, restored; this replaces `lastThreadByScope` |
| Inspector tab (the task tab of §1.4) | global | **per scope** |
| Base pins, last repository shown in Base | per scope, in memory, immortal | **per context within the scope**, persisted (§1.4) |
| Sidebar filter | global | **cleared on switch** — a filter is a glance, not a setting |
| Scroll position of the sidebar | lost | the restored selection is scrolled into view; exact offset is not worth its cost in a SwiftUI `List` |
| Repositories / Loose threads / task expansion | per scope | unchanged |
| Last driver | per scope | unchanged |
| Open sheet (Graph, Pull Requests) | global | **closed on switch** — it is about the scope you left |
| Inspector shown, inspector width, sidebar width, ⌘M | global | **global** — the layout is the window's, as Light/Dark is global in Arc |
| Command palette, Problem Center, Settings | global | global |

**Threads of a scope you leave keep running.** They already do — `threads` is one app-wide array and each
`ThreadSession` owns its terminal view, so scrollback and the PTY survive — and that must stay true: an agent is
work in progress, not a tab. What changes is that you can see them from elsewhere:

- each rail tile carries the scope's **most urgent state** (`ThreadState.mostUrgent`, the function
  `LooseThreadsRow` already uses): the square *waiting* mark, or the *done / failed* mark for an unread result.
  *Running* is deliberately not shown on the rail — a row of pulsing tiles would be the loudest thing in the window
  for the least urgent fact;
- ⌥⌘↩ keeps crossing scopes (`AppModel+Attention.swift:29-41`), and now lands on a scope whose tile said so;
- notifications, the Dock badge and the menu bar extra are unchanged.

**Identity.** Two optional fields on `ScopeDeclaration`, decoded leniently like the rest
(`ScopeConfig.swift:233-241`): `icon` (an SF Symbol name or one emoji) and `tint` (one of a **fixed set of eight
swatches**, not a free colour). With neither set, a scope still has an identity: the first letter of its name
(skipping a leading `@`) on a swatch derived from its slug, so the rail is useful the day it ships. Set from the
header's context menu → **Icon and Colour…**.

Constraints inherited from earlier research:

- **The tint marks, it does not paint.** Direction A spends the brand on exactly one thing, the accent, and its
  grounds are fixed `Surface.*` tokens ([`OPAQUE_AQUA.md`](OPAQUE_AQUA.md), thesis and §1); [`BRAND.md`](BRAND.md)
  keeps gradients off dense UI. A scope's colour
  appears on its 20 pt rail tile and on the header tile, nowhere else. No tinted sidebar, no tinted toolbar.
- **Swatches stay out of the state colours.** A tile is a rounded square with a glyph, a state mark is an 8 pt
  dot/square — shape already separates them ([`RESEARCH.md`](RESEARCH.md) §2) — but the set still excludes Pumpkin
  and the failure red, which must remain the loudest hues in the sidebar.
- **Each swatch is contrast-checked** the way `OPAQUE_AQUA.md` §5 did: tile on `Surface.surface` ≥ 3:1, glyph on
  tile ≥ 4.5:1, in both appearances. Values are chosen in the step that adds the colorsets, not here.

**Shortcuts and gestures.**

| Action | Keys | Notes |
|---|---|---|
| Scope 1…9, in rail order | **⌃1 … ⌃9** | Arc's own. ⌘1…9 stays threads, exactly as ⌘1… is tabs in Arc. |
| Previous / next scope | **⌥⌘← / ⌥⌘→** | Arc's own. The terminal monitor already lets ⌥⌘ chords through (`TerminalKeyBindings.swift:53-55`). |
| Switch by name | ⌘K, type the name | Exists; it must restore the place too (`PaletteModel.swift:216`). |
| Swipe | Two-finger horizontal swipe **over the sidebar** | Last step, optional. Over the terminal a swipe is scroll and stays scroll. |
| Reorder | Drag a tile | Wires up the unused `moveScopes`. |

Two risks to verify when building, not to assume away: ⌃1…9 is also macOS's *Switch to Desktop N* when the user has
enabled it in Keyboard settings (off by default; the system takes the key first), and a menu key equivalent on ⌃digit
takes those chords from the PTY (a few are control codes almost nobody types). If either bites, ⌥⌘1…9 is free.

### 4.4 Mockups

The window, a task thread shown, Base tab up. Changes are marked `◀`.

```
┌──────────────────────────┬──────────────────────────────────────────┬──────────────────────────────────┐
│ [M] @maastrich      ⌄    │  Claude Code            ● running        │  Delta   Pull Request  [Base]    │
│        35 repos          │  @maastrich · ia-research · …/scope  ◀   ├──────────────────────────────────┤
│ [⎇ Pull Requests] [Graph]│                                          │ ⎇ ia-research        @maastrich  │
│ [ Filter           ⌥⌘F ] ├──────────────────────────────────────────┤ scope/ia-research ← main  +412 −9│
│ ■ 1 thread waiting  ⌥⌘↩  │                                          ├──────────────────────────────────┤
├──────────────────────────┤  $ claude                                │ Base · scope · follows the thread│◀
│ ▾ Loose threads        2 │  …                                       │ base checkout · main  [pinned ✕] │◀
│     ⌘ shell   scope root │                                          ├──────────────────────────────────┤
│     ✳ claude     hashup ●│                                          │ [ scope ⌄ ]            ⟳         │
│ ▶ ia-research    +412 −9 │                                          │ ⎇ main   behind 3        [Pull]  │
│ ? fix-default-branch  +8 │                                          │ [Editor] [Shell] [▢]             │
│ ✓ sidebar-v3    +120 −44 │                                          │  Files   Search   History        │
│                          │                                          │ ▸ App                            │
│ ▸ REPOSITORIES 35 · 2 dirty ◀                                       │ ▸ Sources                        │
├──────────────────────────┤                                          │ ▸ Tests                          │
│ [+ New Thread][⎇ New Task]│                                         │   CLAUDE.md                      │
├──────────────────────────┤                                          │                                  │
│ [M] [A]■ [W] [S]●   +    │ ◀ scope rail                             │                                  │
└──────────────────────────┴──────────────────────────────────────────┴──────────────────────────────────┘
```

The rail, enlarged — one 26 pt band under the footer, tiles 20 pt on a 4 pt radius, 6 pt apart:

```
   active                 waiting              unread result
  ┌─────┐   ┌─────┐■     ┌─────┐   ┌─────┐●
  │  M  │   │  A  │      │  W  │   │ 🧪  │        ＋
  └─────┘   └─────┘      └─────┘   └─────┘
  ▔▔▔▔▔▔▔
   ⌃1         ⌃2           ⌃3        ⌃4          Declare a Scope… (⌘O)
```

- **Active**: a 2 pt bar in the scope's tint under the tile; the other tiles sit at 70 % opacity. No Electric fill —
  Electric means *selected row*, and the rail is not a selection.
- **Marks**: the same square (waiting) and dot (done / failed) as `StateDot`, at the tile's top-right corner.
- **Hover**: the name, repo count and what is waiting — `@acme — 12 repos — 1 thread waiting (⌃2)`.
- **Right-click**: the scope's existing context menu (`ScopeRow.swift:117-167`), unchanged.
- **Overflow**: past what fits, the last slot is `⋯`, opening the existing menu. The rail is hidden with one scope.
- **Missing scope**: tile drawn as an outline with the existing `folder.badge.questionmark`.

The header keeps its name and menu — the rail is the fast path, the menu is still where a scope is declared,
renamed and removed — and gains the tile in place of the generic folder:

```
  before   ▢ @maastrich ⌄                35 repos
  after   [M] @maastrich ⌄               35 repos
```

Switching, as a sequence:

```
  ⌃2 / click [A] / ⌥⌘→ / swipe
      1. save @maastrich:   selection, shown thread, task tab            (ScopeUIState)
      2. clear the sidebar filter, close any Graph / Pull Requests sheet
      3. restore @acme:     selection → its thread → its tab → its Base pins
      4. sidebar content swaps (120 ms slide, opacity only under Reduce Motion); the header never moves
      5. the keyboard goes to the restored terminal
  first visit to a scope: its first thread, else the scope's empty view — today's behaviour
```

### 4.5 What not to copy from Arc

| Arc feature | Why not |
|---|---|
| **Profiles as a second layer** | It is what Arc's own numbers and bug fixes point at (§3.3). Scope already has its isolation boundary — `SCOPE_HOME` — and it is deliberately not a UI concept. One level: a scope. |
| **Theming the chrome per Space** | Reverses direction A and breaks `BRAND.md`'s guard-rail. Worse here than in a browser: the sidebar's whole job is that one Pumpkin mark in forty rows is unmissable, which needs a ground that never changes hue. |
| **Free colours and gradients** | A fixed swatch set can be contrast-checked once; a colour picker cannot. |
| **Auto-archive** | A tab is disposable; a thread holds an agent's session and a task holds uncommitted work. Nothing closes on a timer. |
| **Favorites — a global strip above every space** | It is a second, cross-cutting place for the same objects. The sidebar redesign removed exactly that kind of duplication (`LooseThreadsRow.swift` header comment). ⌘K already reaches any thread in any scope. |
| **Swipe as a primary affordance** | Invisible, sidebar-only, and one more gesture competing with scroll. Fine as a bonus on top of a visible rail and two shortcuts; never the only way. |
| **Shared tabs across windows** | The confusion quoted in §3.3. Scope stays one window. |
| **Little Arc, Air Traffic Control** | `scope://` links already name their scope; there is nothing to route. |

---

## 5. Recommended direction, in one paragraph

Keep the three-column window and the one-tree sidebar. Make the **scope a remembered place** — selection, thread,
tab and Base pins restored on return — reachable from a **rail of identity tiles** at the bottom of the sidebar,
⌃1…9, ⌥⌘←/→ and ⌘K, with the rail carrying each scope's most urgent state. Make the **inspector state its
subject**: one band that says what the panel is about and why, a Base rule that follows the thread's actual
directory, and a pin that is visible, scoped to its context and removable. Surface **repository exceptions** on the
collapsed Repositories header. No theming, no profiles, no new screens.

---

## 6. Implementation plan

Each step ships alone and leaves the app better than it found it. Steps 1–3 are the bug; 4–5 make switching cheap;
6–8 are the Arc layer; 9 is independent. App-target changes are verified by building and running a Debug instance
(`CLAUDE.md`, *Running a throwaway instance*); package changes by one named suite.

| # | Step | Files | Verify |
|---|---|---|---|
| 1 | **Stop the tab flip.** Store `taskInspectorTab`; `inspectorTab` reads it when a task is selected and is `.base` otherwise, without writing. Remove the `onChange`. Fixes W8. | `App/Scope/Model/AppModel.swift:97-99`, `App/Scope/Views/Inspector/InspectorView.swift:51-53`, `App/Scope/Environment/UIStateStore.swift` | Task on Delta → loose thread → back: Delta. |
| 2 | **Scope the pick to its context.** `pickedRepo` → `pins: [BaseContext: String]`; `showBase` pins the current context; `baseRepoCandidates` stops appending; the picker gets **Follow selection**; the band shows `pinned ✕`. Fixes W1–W3. | `App/Scope/Model/BaseModel.swift:28, 259-292`, `App/Scope/Views/Inspector/Base/BaseView.swift:26-36`, `App/Scope/Views/Inspector/InspectorView.swift` | Pick a repo in task A, select task B: B's repo. Back to A: the pick. |
| 3 | **The resolver.** Pure `BaseSubject.resolve` with the thread-directory and Delta-focus rules and a reason; `baseRepo` delegates; the band shows the reason; `pullRequestsRepo` stops inheriting the pin. Fixes W4–W6, W12. | `Sources/ScopeTasks/BaseSubject.swift` *(new)*, `Tests/ScopeKitTests/BaseSubjectTests.swift` *(new)*, `App/Scope/Model/BaseModel.swift`, `App/Scope/Model/PullRequestsModel.swift:138-142`, `App/Scope/Views/Inspector/InspectorView.swift` | `swift test --filter BaseSubjectTests` |
| 4 | **Remember each scope's place.** `ScopeUIState` (selection, thread, task tab, pins, last Base repo) per scope in `UIState`, lenient decode, old files still load; `selectScope` restores instead of selecting the scope row; the palette calls `selectScope`; filter cleared and sheet closed on switch; delete `lastThreadByScope`. Fixes W7, W9. | `App/Scope/Environment/UIStateStore.swift`, `App/Scope/Model/AppModel.swift:52-83, 125, 176-179, 529-584`, `App/Scope/Model/PaletteModel.swift:216` | Switch away and back: same thread, same tab. Relaunch: same. |
| 5 | **Shortcuts.** *Go ▸ Scope 1…9* (⌃1…9), *Previous / Next Scope* (⌥⌘← / ⌥⌘→); list them in the shortcuts window and the docs generator. | `App/Scope/Commands/ScopeCommands.swift:237`, `App/Scope/Views/Help/ShortcutsWindow.swift`, `scripts/build-docs.py` (then regenerate) | With the terminal focused, each chord switches; ⌘← still goes to line start. |
| 6 | **Identity.** `icon` and `tint` on `ScopeDeclaration` with `decodeIfPresent`; `ScopeTint` (eight cases) and the derived default in the package; eight colorsets; `ScopeTile` view; the header shows the tile; **Icon and Colour…** in the context menu. | `Sources/ScopeCore/Models/ScopeConfig.swift:165-241`, `Tests/ScopeKitTests/ConfigStoreTests.swift`, `App/Scope/Assets.xcassets`, `App/Scope/Views/Shared/Theme.swift`, `App/Scope/Views/Sidebar/ScopeTile.swift` *(new)*, `App/Scope/Views/Sidebar/ScopeRow.swift:20-22, 117-167` | `swift test --filter ConfigStoreTests`; a config without the fields loads. |
| 7 | **The rail.** Tiles in config order under the footer, active bar, attention marks from `waitingThreads` grouped by scope, tooltip, context menu, `＋`, overflow, drag to reorder through `moveScopes`. Hidden with one scope. | `App/Scope/Views/Sidebar/ScopeRail.swift` *(new)*, `App/Scope/Views/Sidebar/SidebarView.swift:320-337`, `App/Scope/Model/AppModel+Attention.swift` | A thread waiting in another scope marks its tile; the click lands on that scope's restored place. |
| 8 | **Slide and swipe** *(optional)*. Sidebar content transitions on scope change (120 ms, opacity only under Reduce Motion — add the row to `OPAQUE_AQUA.md` §4 *Motion*); a horizontal two-finger swipe over the sidebar steps one scope. | `App/Scope/Views/Sidebar/SidebarView.swift:31-60`, a scroll-wheel monitor beside `App/Scope/Terminal/TerminalKeyBindings.swift` | Swipe over the terminal still scrolls it. |
| 9 | **Findability small wins.** Subtitle `scope · task · cwd`; palette thread hint `task · state`; `Repositories N · k dirty`; the Pull Requests count named or scope-wide; **Show Details** on the task menu. | `App/Scope/Views/Scene/ThreadToolbar.swift:16-18`, `App/Scope/Model/PaletteModel.swift:148-150`, `App/Scope/Views/Sidebar/SidebarView.swift:194-196, 279`, `App/Scope/Views/Sidebar/GlobalViewsRow.swift:59-64`, `App/Scope/Views/Sidebar/TaskRow.swift` | Read each off a running Debug build. |

`docs/DEBUG_ISOLATION.md` needs no new row: every new piece of state lives in `ui-state.json` or `config.json`,
both already under `SCOPE_HOME`. `SPEC.md` §7 should gain the rail and the two shortcuts when step 7 lands.

---

## 7. Open questions

- **Should Base browse the sandbox too?** In a task, "the files" most often means the worktree the agent is
  editing. A source switch (`Base | Sandbox`) on the tab would answer W13 properly; it is a feature, not a fix, and
  spec §4.5 defines Base as the base checkout. Recommendation: ship the wording first, decide after living with it.
- **Base's own state per repository** (W11): keeping the open file, the search and the tree expansion per
  repository means one `BaseModel` state per repo URL instead of a reset. Worth doing once steps 2–4 make returning
  to a repository a normal thing; not required by them.
- **"Behind origin" without opening Base** (Q9): needs a background `git fetch` per repository. With 35
  repositories that is a network policy decision — how often, and whether at all on a metered connection.
- **What the other agents are doing** (Q4): a last-activity line per thread depends on what the adapters report.
  Needs an audit of `ScopeAdapters` events before any design.
- **⌃1…9 against Mission Control** on the owner's machine — check before committing the default (§4.3).
- **Which eight swatches.** To be picked against `Surface.surface` in both appearances in step 6, from the brand
  families that are not already state colours.

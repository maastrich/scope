# UI research — Scope without liquid glass

Design research only. No view code was modified. Companion artifact (side-by-side mockups of the real chrome,
dark and light, per direction, plus the reference gallery): see the link at the end of this file.

Reference palette: [`BRAND.md`](BRAND.md), which is authoritative including its guard-rails.

---

## 1. Where the glass actually is

The brief named two `.regularMaterial` sites. They are the small ones. The largest translucent surface in the
app is the sidebar, and nobody asked for it — it comes from one list style.

| Site | What it does | Kind | Replace with |
|---|---|---|---|
| `App/Scope/Views/Sidebar/SidebarView.swift:35` | `.listStyle(.sidebar)` hands the whole list to AppKit's sidebar `NSVisualEffectView`. Biggest translucent surface in the window. | vibrancy | Opaque `surface` token behind the list; row selection drawn by Scope, not the system |
| `App/Scope/Views/Sidebar/SidebarView.swift:337` | `.background(.bar)` on the New Thread / New Task footer — a second blurred material stacked on the first | material | `surface` + 1px `stroke` on the top edge |
| `App/Scope/Views/Scene/ThreadBanner.swift:48` | `.regularMaterial` behind the exited / launching / failed banner over the terminal | material | `surface-elevated`, opaque, stroked. It forces its own colour scheme to the terminal's at line 50 — an opaque token removes that hack's reason to exist |
| `App/Scope/Views/Scene/ExitToastStack.swift:64-66` | `.regularMaterial` + 10pt black shadow at 18% | material | `surface-elevated` + stroke; much shorter shadow |
| `App/Scope/Views/Palette/CommandPalette.swift:36-38` | Already opaque (`windowBackgroundColor`), but sits on `PaletteDim` — a full-window black scrim at 28% light / 45% dark — under a 35pt shadow | scrim | Keep the scrim (a modal dim is not a material) but tint it from `ground`; cut the shadow to ~18pt |
| `App/Scope/Views/Sidebar/TaskHoverCard.swift` (via `.popover`) | System-drawn popover, vibrant by default on macOS | vibrancy | Opaque `surface-elevated` painted inside the popover content |
| ~25 sites across `App/Scope/Views/` | `Color.primary.opacity(0.03…0.14)` as row hover, chip fill, pressed state — alpha on an unknown ground, hand-tuned per file | alpha | Opaque `row-hover` / `fill-quiet` / `fill-pressed` tokens |

Representative alpha sites: `Sidebar/RepoRow.swift:38`, `Sidebar/GlobalViewsRow.swift:29`,
`Inspector/TaskSummaryBand.swift:82,162,193,251`, `Inspector/Base/BaseView.swift:161-162`,
`Inspector/Graph/GraphView.swift:120`, `Shared/StateDot.swift:106`, `Shared/IconButtonStyle.swift:43-44`,
`Palette/CommandPalette.swift:239`.

### Correction to the brief: a token layer already exists

> "Il n'existe aucun fichier de thème/tokens central"

Not quite. `App/Scope/Assets.xcassets` holds **19 populated colorsets with light/dark pairs** (the 20th, `AccentColor`, is empty — see below) — `StateRunning`,
`StateIdle`, `StateWaiting`, `StateDone`, `ExitedRing`, `ChecksPassing/Failing/Pending`, `PanelBackground`,
`PaletteDim`, `WarningText`, `DiffAdded/Removed`, `HunkBackground/Text`, `TerminalSelectionDark/Light` — and
three token enums already exist: `ThreadStateStyle` (`Shared/StateDot.swift:61`), `PullRequestStyle`
(`Inspector/PullRequests/PullRequestRow.swift:133`) and `SidebarMetrics` (`Sidebar/TaskStatusStyle.swift`).

The **semantic** layer is present and disciplined. What is missing is the **tier below it**: ground / surface /
surface-elevated / stroke / fill. That absence is exactly why 25 sites hand-write `Color.primary.opacity(0.06)`.
The work is to name and complete a layer, not to build one.

### Correction: the accent is not Scope's yet

`App/Scope/Assets.xcassets/AccentColor.colorset/Contents.json` has **one entry with no colour components** — it
is empty. Scope renders in *the user's macOS system accent*. `Shared/StateDot.swift:59-60` documents the
consequence: *"`done` is pinned to blue rather than the accent so it keeps its meaning under a graphite or red
system accent."*

Making Electric `#0E55FB` the accent means **overriding the system accent** — a deliberate break with a macOS
convention Scope currently honours. All three directions below take that break; it is the price of a brand
palette, and it is the owner's call, not a detail.

### Unspent signal: `ThreadRecord.origin`

`Sources/ScopeCore/Models/ThreadOrigin.swift` records `author` (`.user` / `.control`), `parent`, `depth` and
`client` on every thread. **No view reads it** — the only consumer is `App/Scope/Model/AppControlService.swift:26`,
for the automation depth ceiling. User-launched vs agent-launched is therefore shippable with zero model work,
and it is the second place where colour earns its slot in a dense list.

---

## 2. Colour roles

Scope is a dense utility. Colour has to earn its slot, and the slot where it earns most is the 8pt mark at the
end of a 28pt thread row.

| Role | Midnight (dark) | Daylight (light) | Notes |
|---|---|---|---|
| `ground` — terminal, content pane | Onyx `#101010` | Ivory `#FFFFF9` | Darkest/lightest thing in the window; carries no chrome text |
| `surface` — sidebar, toolbar, footer | Ink `#141826` | `#EDEFF6` / Butter 8% `#FDFBEE` | One step *up* from ground in dark, one step *down* in light |
| `surface-elevated` — palette, popover, banner, toast | `#1C2133` | `#FFFFFF` | Opaque, stroked, short shadow. Never blurred |
| `stroke` / hairline | `#262C40` | `#DADEEA` | Deliberately below 3:1 — a divider is decoration under WCAG 1.4.11; the row it separates is not |
| `field` — filter, search inputs | `#0E1220` | `#FFFFFF` | Replaces `textBackgroundColor.opacity(0.6)` at `SidebarView.swift:156` |
| `accent-fill` — selection, primary button | Electric `#0E55FB` | Electric `#0E55FB` | Fill and stroke only. White on it = 5.66:1 |
| `text` | `#EDEEF2` | `#141826` | |
| `text-secondary` — captions, `+N −M`, paths | `#9AA1B8` | `#565B70` | Blue-biased grey, not neutral |
| `text-tertiary` — group headers, placeholder, toolbar subtitle | `#868DA6` | `#666C85` | Real text at 9.5–10.5pt, so it needs 4.5:1, not 3:1. The obvious `#6E7691` only reaches 3.9:1 |
| state `running` | `#34C759` | `#1F9D3F` | Unchanged from today's `StateRunning` |
| state `idle` | `#B8B8BD` | `#85858A` | Unchanged from today's `StateIdle` |
| state `waiting` | **Pumpkin `#F96B1A`** | **`#B44905`** (Pumpkin −28% L) | Brand's most urgent hue on the app's most urgent fact |
| state `failed` | `#FF5A52` | `#C9221A` | Stays system red; the brand has none |
| state `exited` | ring `#707891` | ring `#8E8E93` | 1.5pt ring, never filled |
| state `done` | `#5C93FF` | `#0E55FB` | |
| `origin: agent` | Lavender `#DFCEFF` | Periwinkle `#6B5FBF` | New role for `ThreadRecord.origin == .control` |
| Lavender / Butter / Mist | — | — | Surface/fill only per `BRAND.md`. Direction C spends them; A and B hold them back |

Shape carries every state as well as colour — circle, rounded square, rotated square, 1.5pt ring, pulse on
running — because `Shared/StateDot.swift:4-14` already decided that for greyscale and colour-vision deficiency.
**None of the three directions touches the shape legend.**

### Contrast check (WCAG 2.1 AA)

| Pair | Ratio | Needs | Verdict |
|---|---|---|---|
| `#FFFFFF` on Electric `#0E55FB` — selected row label | 5.66:1 | 4.5:1 text | ✅ |
| Electric `#0E55FB` on Onyx `#101010` — as text | 3.36:1 | 4.5:1 text | ❌ fill/stroke only (matches `BRAND.md`) |
| Electric on Onyx — selection fill / focus ring | 3.36:1 | 3:1 UI (1.4.11) | ✅ |
| Electric on Ink `#141826` — selection fill | 3.12:1 | 3:1 UI | ✅ (thin margin) |
| Electric `#0E55FB` on Ivory `#FFFFF9` | 5.64:1 | 4.5:1 text | ✅ usable as a link in light |
| Pumpkin `#F96B1A` on Onyx — waiting mark | 6.47:1 | 3:1 UI | ✅ |
| Pumpkin `#F96B1A` on Ivory | **2.93:1** | 3:1 UI | ❌ darken to `#B44905` (5.37:1) |
| Periwinkle `#9789E6` on Ivory | **2.97:1** | 3:1 UI | ❌ surface only, as the brand says |
| Lavender `#DFCEFF` on Ink | 12.13:1 | 4.5:1 | ✅ but brand forbids it as text — keep it a fill/mark |
| Onyx `#101010` on Butter `#FAF6B9` — direction C selection | 17.17:1 | 4.5:1 | ✅ strongest pair in the palette |
| `#9AA1B8` secondary on Ink — captions, counts | 6.87:1 | 4.5:1 | ✅ |
| `#565B70` secondary on `#EDEFF6` | 5.85:1 | 4.5:1 | ✅ |
| Idle `#85858A` on Ivory | 3.66:1 | 3:1 UI | ✅ (today's value) |
| Exited ring `#707891` on Ink — 1.5pt stroke | 4.03:1 | 3:1 UI | ✅ |
| Exited ring `#5E6478` on Ink (first pick) | 3.004:1 | 3:1 UI | ⚠️ passes only unrounded — lifted to `#707891` |
| Tertiary text `#868DA6` on Ink — group headers, captions | 5.36:1 | 4.5:1 text | ✅ |
| Tertiary text `#666C85` on `#EDEFF6` | 4.52:1 | 4.5:1 text | ✅ |
| Tertiary text `#726D5E` on Butter 8% `#FDFBEE` — direction C | 4.97:1 | 4.5:1 text | ✅ |
| `#34C759` running on Ink | 7.96:1 | 3:1 UI | ✅ |
| `#1F9D3F` running on Ivory | 3.51:1 | 3:1 UI | ✅ |

Hairlines (`#262C40` on Ink = 1.36:1, `#DADEEA` on `#EDEFF6` = 1.24:1) are intentionally below 3:1: WCAG 1.4.11
applies to graphics needed to identify a control, not to decorative separators. The rows themselves are
identified by their selection fill and their state mark, both of which pass.

---

## 3. Three directions

They differ on one axis: **how much system-native chrome Scope gives up.** Three palettes would not be three
directions.

### A — Opaque Aqua *(gives up the least)* — **chosen 2026-09-20; full spec in [`OPAQUE_AQUA.md`](OPAQUE_AQUA.md)**

Keep every macOS convention Scope already follows, delete the blur, and spend the brand on exactly one thing:
the accent.

- Grounds stay the system greys, opaque: `#1E1E21` dark / `#FFFFF9` light for both sidebar and terminal.
- `.listStyle(.sidebar)` → `.inset` on an opaque `surface`; the four material sites → `surface-elevated`.
- Thread states unchanged (system green / amber / red / blue / grey).
- Electric only as selection fill, focus ring and primary button.

**Sacrifices:** almost no brand presence in the densest part of the UI — the palette lives only in selection and
focus. The thread list looks exactly as it does today, minus the blur. And it still overrides the user's system
accent, the one convention it does break.

### B — Ink Console *(owns the ground)*

Scope owns its ground: an Ink `#141826` sidebar against an Onyx `#101010` terminal, Electric selection with a
white label, 1px hairlines everywhere, Pumpkin reserved for the one state that wants you, Lavender for
agent-opened threads.

- Register: Raycast / Linear / Zed — flat opaque panels, hairline separation, one saturated accent.
- Light mode inverts the relation rather than the hue: a `#EDEFF6` slate sidebar against an Ivory ground.
- Origin becomes visible: a Lavender marker on `origin.author == .control` rows.

**Sacrifices:** macOS citizenship. The sidebar no longer matches Finder, Mail or Xcode beside it, and the window
stops inheriting the user's accent and appearance tinting. The terminal ground must be repainted with it —
`App/Scope/Terminal/TerminalAppearance.swift:30-33` derives the whole ANSI palette from `.windowBackgroundColor`
precisely so the terminal reads as part of the app, and `mix(background, .black, 0.45)` (ANSI black) needs
re-checking on a near-black ground. Note this cuts against the recorded preference that the terminal follow the
system theme: under B it follows *Scope's* theme instead, which is a change worth stating out loud.

### C — Daylight Paper *(rebuilds the surface tier)*

Light-first, built out of the brand's surface colours: an Ivory ground with a Butter-tinted `#FDFBEE` sidebar, a
Lavender `#F4EFFF` hover, and selection as a Butter `#FAF6B9` highlighter stripe with ink on it — 17.17:1, the
strongest pair in the palette.

- Register: Things 3 — warm paper ground, near-black type, colour only on the thing that is due.
- Electric survives as the link/action colour, not as selection.
- Dark mode is a warm-neutral counterpart (`#16150F` ground, `#1E1C14` surface) with the same Butter selection.

**Sacrifices:** density, and a colour. Tinted tiers want more breathing room than a 28pt row gives, so C is the
one direction that would push rows to ~32pt and shorten the visible list. And once Butter is the selection,
yellow is gone from the semantic set — `waiting` moves to Pumpkin permanently, and `StateWaiting`'s current
amber/red cannot come back. The dark mode is also an invention: Midnight has no warm ground, so `#16150F` is
derived, not brand.

---

## 4. References — six apps, six moves

One specific stealable mechanic each. Reproductions are in the artifact so they can be judged without opening
anything. Notion Calendar / Cron was dropped: its signature move is month-grid chrome, which has no surface in
Scope.

| App | The move | How it maps |
|---|---|---|
| **Linear** | One accent, zero decoration. Every surface flat and opaque; the only saturated pixels are the selected row and the focused control. Hierarchy from two greys and a hairline, never a shadow. | Direction A's whole thesis, and the discipline B needs: with an Ink sidebar *and* Electric selection *and* Pumpkin states, Electric must not leak into icons, links or chips, or the waiting mark stops being loudest. |
| **Raycast** | Dense rows that still breathe: ~28pt rows, a 16pt icon column, a right-aligned dim caption, 1px dividers only *between groups*, solid (not tinted) selection, no blur. | Scope's rows are already 28pt with a 16pt icon slot (`SidebarMetrics.indent`). Missing half is the group divider and the solid selection — which is why `.listStyle(.sidebar)` must go rather than just be recoloured. Applies to all three directions. |
| **Zed** | The panel ground matches the editor ground; sidebar, tab bar and buffer share one near-black, separated only by a hairline a shade lighter. One surface with regions, not panels bolted together. | Direction B, with Ink one step off Onyx instead of identical. Also the direct argument for making the terminal follow `Surface.ground` — `TerminalAppearance.build` already derives its palette from the window background for exactly this reason. |
| **Things 3** | A warm paper ground with colour only on what is due — one saturated mark in an otherwise entirely uncoloured list. | Direction C's ground, and the model for Pumpkin as `waiting`. The strongest argument against colouring the chrome: on a quiet warm ground, one orange mark in a 40-row list is impossible to miss. Costs density — Things rows are ~34pt. |
| **Warp** | Blocks, not a scroll: each command and its output is a bounded block with a quiet background and a status edge (success / running / failed). | Scope's terminal is a raw PTY and should stay one — but `ThreadBanner` and `ExitToastStack` *are* this. Give the banner a 2pt leading edge in the state colour instead of a uniform stroke and the exited / failed / launching cases separate at a glance. |
| **GitHub Desktop** | A two-colour `+N −M` always in the same place: right-aligned, tabular figures, green and red and nothing else. | Scope already draws this (`DeltaCounts` on every task row) but at `.secondary`, so it reads as grey noise. Colouring the two numbers costs nothing, works in every direction, and makes the task list scannable by size of change — the second most useful fact after state. |

---

## 5. Token structure recommendation

Not a new colour system — the missing tier under the one that exists. Values stay in the asset catalogue (that
is what gives light/dark pairs for free); Swift only names them.

**New file: `App/Scope/Views/Shared/Theme.swift`** (~90 lines, no logic). Not in `ScopeKit`: these are AppKit /
SwiftUI colours and the package builds without AppKit (`swift build` is the fast path, per `CLAUDE.md`). The app
target has no tests, which is fine — a file of `static let Color("…")` has nothing to test; what is worth
testing stays in the package.

```swift
enum Surface {
    static let ground   = Color("Ground")          // terminal + content pane
    static let surface  = Color("Surface")         // sidebar, toolbar, footer
    static let elevated = Color("SurfaceElevated")  // palette, popover, banner, toast
    static let stroke   = Color("Stroke")          // 1px hairline
    static let field    = Color("Field")           // filter + search inputs
}

enum Fill {                       // replaces ~25 × Color.primary.opacity(0.0x)
    static let quiet    = Color("FillQuiet")       // chips, counts, pills
    static let hover    = Color("FillHover")
    static let pressed  = Color("FillPressed")
    static let selected = Color("Accent")          // label = Color("OnAccent")
}

enum Origin {                     // new: ThreadRecord.origin is recorded and unread by every view
    static let agent = Color("OriginAgent")        // Lavender in dark, Periwinkle in light
}

// ThreadStateStyle / PullRequestStyle / TaskStatusStyle already exist and are correct.
// Move them here as-is — same names, same colorsets. The state legend does not change.
```

Order of work:

1. **Fill `AccentColor.colorset`** with Electric `#0E55FB` (both appearances). One file, and every
   `Color.accentColor` in the app — selection, focus rings, primary buttons — turns brand at once. Highest
   leverage edit in the list, and the one that breaks the system-accent convention.
2. **Add 9 colorsets** for the `Surface` and `Fill` tiers, light/dark pairs. Still no Swift logic.
3. **Kill `.listStyle(.sidebar)`** at `SidebarView.swift:35` — `.listStyle(.inset)` +
   `.scrollContentBackground(.hidden)` + `.background(Surface.surface)`, with row selection drawn from
   `Fill.selected`. This is the whole de-glassing, in one view.
4. **Swap the four material sites** (footer, banner, toast, popover content) for `Surface.elevated` + a stroke.
5. **Sweep the ~25 `opacity()` sites** onto `Fill.*`. Mechanical, reviewable in one pass, and it is what stops
   the next surface being invented by hand.
6. **Decide the terminal** (see direction B's sacrifice). A and C keep `TerminalAppearance`'s derivation intact.
7. **Spend `ThreadRecord.origin`** — a Lavender marker on agent-opened rows, zero model work.

### What not to do

No mesh gradient behind the sidebar or the tree. It is the brand's signature and it belongs on the marketing
site, the About window and the **empty states** — surfaces with five words on them, not surfaces with forty rows.
`Scene/ScopeEmptyView.swift`, `Scene/SceneEmptyView.swift` and `Tasks/TaskEmptyView.swift` are exactly where it
pays: they already draw a large blank ground and currently show a symbol at 12% opacity on it.

---

## Artifact

Side-by-side mockups of the real chrome (sidebar + thread list with all five states + terminal pane), one panel
per direction in dark and light, plus the reference gallery:

https://claude.ai/artifact/GM3ZwDo96rDxZyb6EFW2m7

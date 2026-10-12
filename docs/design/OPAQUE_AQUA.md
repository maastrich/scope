# Opaque Aqua — direction A, full spec

Chosen direction, 2026-09-20. The *why* — the glass inventory, the three directions, the app references — is in
[`RESEARCH.md`](RESEARCH.md); this file is the handoff. Palette guard-rails: [`BRAND.md`](BRAND.md).

**The thesis:** keep every macOS convention Scope already follows, delete the blur, and spend the brand on
exactly one thing — the accent. No view code was modified to write this.

Companion artifact (three-column window in both appearances, component boards, generated contrast tables):
https://claude.ai/artifact/JfuUCkYqVE3PeLB6rjy61A

---

## 1. Colour tokens

Two tiers. The **surface tier** is new — the layer whose absence makes ~25 views hand-write
`Color.primary.opacity(0.06)`. The **semantic tier** already exists in the asset catalogue and is kept: same
names, same hues, same shapes.

### Surface tier — new colorsets

| Token | Dark | Light | Used by |
|---|---|---|---|
| `Ground` | `#1E1E21` | `#FFFFF9` | Terminal, content pane, list wells, empty states. Light is Ivory — the brand's own near-white, and indistinguishable from `#FFFFFF` in use |
| `Surface` | `#232326` | `#EDECE5` | **Chrome only**: sidebar, window toolbar, sidebar footer. In light it sits one step *below* the ground — the macOS convention is grey chrome around near-white content |
| `SurfacePanel` | `#232326` | `#F6F5EE` | Panels inside the content well: inspector header, summary bands, delta/review action bars, list group headers. This is what `PanelBackground` does today, and it must stay *lighter* than the chrome or a band comes out darker than the list it heads. Identical to `Surface` in dark, where macOS flattens the distinction too |
| `SurfaceElevated` | `#2C2C31` | `#FFFFFF` | Command palette, popovers, thread banner, exit toasts. Replaces the two `.regularMaterial` sites and the vibrant popover |
| `Stroke` | `#3A3A40` | `#DBD9CE` | Every 1px hairline: column dividers, footer top edge, elevated-surface borders |
| `Field` | `#1A1A1D` | `#FFFFFF` | Filter and search fields. Replaces `textBackgroundColor.opacity(0.6)` (`SidebarView.swift:156`) |
| `FillQuiet` | `#2B2B30` | `#E4E3DB` | Chips, state pill, segment rest, count badges. Replaces `Color.primary.opacity(0.05–0.07)` × ~14 |
| `FillHover` | `#2E2E35` | `#E4E3DB` | Row hover, icon-button hover. Replaces `.opacity(0.03–0.075)` × ~7 |
| `FillPressed` | `#3A3A40` | `#DCDBD2` | Icon button while pressed. Replaces `.opacity(0.14)` (`IconButtonStyle.swift:43`) |

### Accent

| Token | Dark | Light | Used by |
|---|---|---|---|
| `AccentColor` | `#2465FB` | `#0E55FB` | Selected row fill, focus ring, primary button, checkbox on |
| `OnAccent` | `#FFFFFF` | `#FFFFFF` | Every glyph, label, caption and count on a selected row |
| `SelectionInactive` | `#3A3A40` | `#D9D7CC` | Selected row while the window is not key |
| `SelectionTint` | `#1F2840` | `#DDE7F9` | Selected row in secondary lists (delta files, palette, base search), **opaque** — replaces `accentColor.opacity(0.12)` × 3 |

**Why the dark accent is not Electric.** Electric `#0E55FB` against the dark surface `#232326` is **2.77:1** —
under the 3:1 a selection fill owes WCAG 1.4.11. The dark slot is **Electric Lift `#2465FB`**: same hue (222°),
same saturation (97%), lightness 52% → 56.5%. That is the only window available, because the fill needs ≥3:1 on
the surface while the white label needs ≥4.5:1 on the fill — the two bound it from opposite sides. Light mode
keeps Electric exactly (`#0E55FB` on `#EDECE5` = 4.78:1, white on it = 5.66:1).

**`AccentColor.colorset` is empty today**, and filling it is *not enough on its own*: the project never set
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, without which `Color.accentColor` resolves to the user's
System Settings accent and the catalogue entry is never read. Both together are what make Scope stop following
the system accent. That is a deliberate break with a convention the app currently honours — see `RESEARCH.md §1`.

### Semantic tier — existing colorsets

Kept as-is, except five light values darkened by ≤3% lightness: today's sidebar is vibrancy-composited and
therefore lighter than an opaque surface, and three marks fell under 3:1 once the surface stopped being
translucent.

| Token | Dark | Light | Change |
|---|---|---|---|
| `StateRunning` | `#34C759` | `#1E9A3E` | light −1% L (2.98 → 3.09) |
| `StateIdle` | `#B8B8BD` | `#84848A` | light −1% L |
| `StateWaiting` | `#FF9F0A` | `#C93400` | unchanged |
| `StateDone` | `#4C8FF7` | `#0A5FD6` | unchanged |
| `ExitedRing` | `#AEAEB2` | `#86868C` | light −3% L (2.75 → 3.06) |
| `ChecksFailing` | `#F85149` | `#B3261E` | unchanged |
| `ChecksPassing` | `#3FB950` | `#1F7A3A` | unchanged |
| `ChecksPending` | `#D29922` | `#A84C00` | unchanged |
| `WarningText` | `#FF9F0A` | `#AE4E00` | light −2% L (4.39 → 4.56) |
| `HunkText` | `#8AB4F8` | `#396AA8` | light −2% L (4.57 → 4.66) |
| `DiffAdded` / `DiffAddedSign` | `#1B3524` / `#3FB950` | `#E6F4EA` / `#116329` | unchanged |
| `DiffRemoved` / `DiffRemovedSign` | `#3B2220` / `#FF7B72` | `#FBE9E7` / `#A40E26` | unchanged |
| `TextPrimary` | `#E8E8EA` | `#1D1D1F` | new name for the label colour |
| `TextSecondary` | `#9B9BA3` | `#62626A` | **new** — replaces `.secondary`, which is alpha over an unknown ground |
| `TextTertiary` | `#8E8E96` | `#696972` | **new** — `.tertiary` renders at 4.26:1 on the light surface and fails AA |
| `PaletteDim` | `#000000 @45%` | `#000000 @28%` | unchanged — a modal scrim is not a material |
| `PanelBackground` | — | — | **renamed** to `SurfacePanel`; its light value moves `#F7F7F9` → `#F6F5EE` to sit with an Ivory ground |

**What A spends the brand on, honestly:** one colour, in one role. The legend keeps its meaning, the diff stays
reviewable in an afternoon, and the app still looks like a macOS app — but the brand palette appears in exactly
one place. Swapping `StateWaiting`'s amber for Pumpkin `#F96B1A` is a **documented variant**, not the default;
take it only to lean one step toward direction B.

---

## 2. Type scale

The views use **17 distinct sizes** today — 8, 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 16, 17, 20, 28, 36,
44 — with weights applied case by case. Six roles cover all of them.

| Role | Size / weight | Used for | Replaces |
|---|---|---|---|
| `.scopeTitle` | 13 semibold | Task name in the band, banner title, sheet headings | 20, 17, 16, 14, 13 semibold |
| `.scopeBody` | 13 regular | Sidebar row titles, palette results, settings labels | 13 |
| `.scopeRow` | 11.5 regular | Dense list rows: thread/task titles, delta file paths | 12.5, 12, 11.5 |
| `.scopeCaption` | 11 regular | Captions, paths, prompts, helper text — 114 sites today | 11 |
| `.scopeMicro` | 9.5 semibold | Group headers, uppercase labels, badge digits | 10.5, 10, 9.5, 9, 8 |
| `.scopeValue` | 11 monospaced | Anything that *is* a value: `+N −M`, branches, hashes | 11 mono, 10.5 mono |

The three display sizes (28, 36, 44 `.thin`) are empty-state symbols, not text, and stay as they are.

---

## 3. Metrics

| Token | Value | Applies to | Today |
|---|---|---|---|
| `row-height` | 28 pt | Every sidebar row — task, thread, loose group, repo | 28, unchanged |
| `row-height-dense` | 24 pt | Delta file rows, palette results, base file lists | 26 — **changed**, to match the sidebar rhythm |
| `band-height` | 22 pt | State pill, PR chip, band title line, footer buttons | 22, unchanged |
| `header-height` | 30 pt | Inspector tab header, level with the window toolbar | 30, unchanged |
| `field-height` | 24 pt | Sidebar filter (48 pt for the palette input alone) | 24 / 48, unchanged — but its **radius** moves 6 → 5 with `radius-md` |
| `indent` | 19 pt | One nesting level | 19, unchanged (`SidebarMetrics.indent`) |
| `gutter` | 6 / 8 / 12 / 14 pt | Row / sidebar / band / list insets | 6, 8, 9, 10, 12, 14, 16 — **collapsed to four** |
| `radius-sm` | 4 pt | Chips, badges, status letters | 4, unchanged |
| `radius-md` | 5 pt | Rows, buttons, fields, segment ends | 5 and 6 — **merged**; the filter field and the sidebar search drop from 6 |
| `radius-lg` | 10 pt | Elevated surfaces: palette, banner, toasts | 10 and 12 — **merged** |
| `shadow-elevated` | 0 1 4 · black 14% | Banner, toasts | 10pt @18% — **shortened** |
| `shadow-modal` | 0 12 24 · black 28% | Command palette only | 35pt @35% y24 — **shortened** |
| `hairline` | 1 px | Every divider | 1, unchanged |

---

## 4. Components and states

Dropping `.listStyle(.sidebar)` hands back four things AppKit was drawing. All four are specified; everything
else in the de-glassing is a one-line swap.

| Element | State | Appearance |
|---|---|---|
| Sidebar row | Rest | No fill. Title `TextPrimary`, caption `TextTertiary`, count `TextSecondary` |
| Sidebar row | Hover | `FillHover`, radius-md. Trailing controls fade in over the caption (existing `trailingFade`) |
| Sidebar row | Selected, window key | `AccentColor` fill. **Everything** on the row → `OnAccent`: title, caption, glyph, state mark, and both diff counts. Shape carries the state, colour cannot |
| Sidebar row | Selected, window not key | `SelectionInactive` fill + 3pt `AccentColor` leading bar; text back to `TextPrimary`. Driven by `@Environment(\.controlActiveState)` |
| Sidebar row | Keyboard focus | 2pt `AccentColor` outline, inset −1, drawn over whatever fill is present |
| Group header | — | `.scopeMicro`, `TextTertiary`, 22 pt, uppercase. A hairline above the group, never between rows |
| Secondary list row | Selected | `SelectionTint` (opaque) + 2pt `AccentColor` leading rule |
| Status chip (A/M/D) | On | Fill = status colour, label = ink on light fills, white on dark fills. **Never white on green** — 2.22:1 |
| Status chip | Off | `FillQuiet` fill, label = status colour |
| Button | Secondary / primary / disabled / focused | `FillQuiet` + stroke / `AccentColor` + `OnAccent` / 40% opacity / 2pt accent outline offset +1 |
| Field | Rest / focused | `Field` + `Stroke` / `AccentColor` border + 2pt inset outline |
| Repo row | Rest | Same 28 pt row as a thread. Branch chip is `.scopeValue` on `FillQuiet`, radius-sm; the dirty dot is an 8 pt **circle** in `StateWaiting` — note it reuses the waiting *colour* without the waiting *shape*, which is the one place the legend is ambiguous today (`RepoRow.swift:44`) |
| Elevated surface | — | `SurfaceElevated`, 1px `Stroke`, radius-lg, `shadow-elevated`. Shadow says elevation; blur is gone |

### Motion

| Element | Trigger | Behaviour | Duration / easing |
|---|---|---|---|
| Sidebar row | Hover | Fill appears, trailing controls fade in | 120 ms ease-out (existing) |
| Running dot | Driver working | 1pt ring scales 1 → 2.1 and fades | 1.4 s ease-out, repeating; off under Reduce Motion |
| Command palette | ⌘K | Opacity + scale 0.98 → 1, top anchor, over `PaletteDim` | 120 ms ease-out; opacity only under Reduce Motion |
| Inspector | ⌘D / ⇧⌘B | Panel swap, no cross-fade; the 30pt header never moves | none |

### Edge cases

- **Long name** — truncates tail; the row never grows. Full text in the existing tooltip.
- **Narrow sidebar (220 pt min)** — caption truncates first, then the title. The state mark keeps its 8pt slot
  at a fixed inset and is never pushed off.
- **Footer under 230 pt** — buttons drop their titles (existing `footerTitleThreshold`).
- **Selected row with coloured counts** — `+N −M` lose green/red and go `OnAccent`; green on Electric is 1.9:1.
- **Empty scope / no thread** — empty states keep `Ground`, not `Surface`. This is the one place the mesh
  gradient is allowed: five words on a large blank, never behind a list.

---

## 5. Contrast (WCAG 2.1 AA)

Computed from the token values above, not picked by hand. Hairlines and inert fills are marked decorative:
1.4.11 covers graphics needed to identify a control, not separators. Full generated tables for both appearances
are in the artifact.

| Pair | Dark | Light | Needs |
|---|---|---|---|
| Row title on surface | 12.81:1 | 14.21:1 | 4.5:1 ✅ |
| Secondary — captions, paths | 5.68:1 | 5.10:1 | 4.5:1 ✅ |
| Tertiary — group headers, placeholder | 4.82:1 | 4.59:1 | 4.5:1 ✅ |
| Label on selected row | 4.85:1 | 5.66:1 | 4.5:1 ✅ |
| Selected fill vs surface | 3.23:1 | 4.78:1 | 3:1 ✅ |
| Focus ring vs field | 3.58:1 | 5.66:1 | 3:1 ✅ |
| Text on inactive selection | 9.23:1 | 11.65:1 | 4.5:1 ✅ |
| Mark: running | 7.06:1 | 3.09:1 | 3:1 ✅ |
| Mark: exited ring | 7.09:1 | 3.06:1 | 3:1 ✅ |
| Mark: waiting | 7.62:1 | 4.46:1 | 3:1 ✅ |
| Mark: failed | 4.68:1 | 5.52:1 | 3:1 ✅ |
| Counts `+N` / `−M` on surface | 6.17 / 6.22:1 | 6.24 / 6.64:1 | 4.5:1 ✅ |
| Text on selection tint | 11.95:1 | 13.52:1 | 4.5:1 ✅ |
| Hunk header on hunk fill | 6.35:1 | 4.66:1 | 4.5:1 ✅ |

### Two deliberate deviations

**Inactive selection.** The grey fill is 1.39:1 against the surface and cannot reach 3:1 without a grey so light
it reads as selected-*and*-active; macOS has the same ratio for the same reason. The 3pt accent bar clears 3:1
against the sidebar surface it runs along (3.23:1 dark, 4.78:1 light) but only reaches **2.33:1 against the fill
on its other side in dark**. So the bar is a *redundant* cue: the row is identified by its full-contrast label
(9.23:1) and by the `isSelected` trait. If you would rather not ship a cue that clears on one side only, drop
the bar and keep the plain grey fill — Finder and Xcode do exactly that, and nothing else changes.

**Selection tint** on secondary lists is 1.14:1 against the ground, so the 2pt accent rule carries it. This is
also the fix for the three `accentColor.opacity(0.12)` sites — they were never identifiable either; the alpha
just hid the fact.

---

## 6. Order of work

| # | Where | Change | Size |
|---|---|---|---|
| 1 | `Assets.xcassets/AccentColor.colorset` | Fill **both appearance slots**: `#0E55FB` light, `#2465FB` dark. `Fill.selected` is `Color.accentColor`, which resolves to the *system* accent until this colorset overrides it — the dark slot is load-bearing, and without it the fill silently reverts to 2.77:1. Filling it is also what stops the app following the user's system accent | 1 file |
| 2 | `Assets.xcassets` | Add 14 colorsets (surface tier, text tier, selection-inactive, selection-tint, on-accent). Retune the 6 light semantic values. Rename `PanelBackground` → `Surface` | 20 files, no Swift |
| 3 | `App/Scope/Views/Shared/Theme.swift` | New. `Surface`, `Fill`, `Ink`, the `Font` extension; `ThreadStateStyle`, `PullRequestStyle`, `TaskStatusStyle` moved in unchanged | ~110 lines |
| 4 | `Sidebar/SidebarView.swift:35`, `:337` | `.listStyle(.inset)` + `.scrollContentBackground(.hidden)` + `Surface.surface`; footer `.bar` → `Surface.surface` + top hairline. **The whole de-glassing** | 2 sites + selection code |
| 5 | `Sidebar/TaskRow.swift`, `Sidebar/ThreadRow.swift` | Own the selection: `.listRowBackground` on `selection` × `controlActiveState`; all marks and text → `Ink.onAccent` when selected | 2 files |
| 6 | `Scene/ThreadBanner.swift:48`, `Scene/ExitToastStack.swift:64`, `Sidebar/TaskHoverCard.swift` | `.regularMaterial` → `Surface.elevated` + stroke; shorten both shadows; popover content painted opaque | 3 files |
| 7 | ~25 sites listed in `RESEARCH.md §1` | `Color.primary.opacity(0.0x)` → `Fill.*`; `.secondary`/`.tertiary` on a painted surface → `Ink.*`; the three `accentColor.opacity(0.12)` → `Fill.selectedTint` + 2pt rule | mechanical sweep |
| 8 | `Palette/CommandPalette.swift:36-38` | Keep `PaletteDim`; ground → `Surface.elevated`; shadow 35pt@35% → 12/24@28% | 1 file |
| 9 | Type sweep | `.font(.system(size:))` → the six roles | mechanical sweep |

Steps 1–2 are asset-catalogue only. Step 4 is the only one that is not a swap; everything in §4 exists to make
that view unambiguous. Steps 5–9 can each land as their own commit.

```swift
// App/Scope/Views/Shared/Theme.swift — new, ~110 lines, no logic.
enum Surface {
    static let ground   = Color("Ground")
    static let surface  = Color("Surface")          // was PanelBackground — same role, one name
    static let elevated = Color("SurfaceElevated")
    static let stroke   = Color("Stroke")
    static let field    = Color("Field")
}

enum Fill {
    static let quiet    = Color("FillQuiet")
    static let hover    = Color("FillHover")
    static let pressed  = Color("FillPressed")
    static let selected = Color.accentColor
    static let selectedInactive = Color("SelectionInactive")
    static let selectedTint     = Color("SelectionTint")   // opaque, not accent @ 12%
}

enum Ink {
    static let primary   = Color("TextPrimary")
    static let secondary = Color("TextSecondary")
    static let tertiary  = Color("TextTertiary")           // AA on surface — NOT .tertiary
    static let onAccent  = Color("OnAccent")
}

extension Font {
    static let scopeTitle   = Font.system(size: 13, weight: .semibold)
    static let scopeBody    = Font.system(size: 13)
    static let scopeRow     = Font.system(size: 11.5)
    static let scopeCaption = Font.system(size: 11)
    static let scopeMicro   = Font.system(size: 9.5, weight: .semibold)
    static let scopeValue   = Font.system(size: 11, design: .monospaced)
}
```

`Theme.swift` belongs in the app target, not in ScopeKit: these are AppKit/SwiftUI colours and the package
builds without AppKit. A file of `static let Color("…")` has nothing to unit-test, which is the usual reason
logic belongs in the package.

## Not in scope for A

- The terminal keeps deriving its palette from the window background (`TerminalAppearance.build`). A does not
  repaint the ground, so the derivation stays valid and the terminal keeps following the system theme.
- No mesh gradient behind any list — empty states only.
- `ThreadRecord.origin` stays unread. Showing user-vs-agent threads is a separate, cheap change that does not
  belong in a de-glassing pass.


---

## 7. As built

Implemented on this branch, one commit per step, each building green
(`xcodebuild … -configuration Debug`). Three things came out different from the spec above, and the spec is
wrong where they disagree.

| Spec said | Built | Why |
|---|---|---|
| Step 1 fills `AccentColor.colorset` | Fills it **and** adds `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor` to the `Scope` target in `project.yml` | The setting was absent, so the colorset would have been dead weight — `Color.accentColor` resolves to the System Settings accent until a target names its global accent asset |
| Step 5 draws the selection by hand with `.listRowBackground` × `controlActiveState` | The system keeps drawing it; rows publish an `isOnAccent` environment flag instead | `.listStyle(.inset)` still fills the selection with the accent and greys it on resign-key — exactly the spec. What the framework does *not* do is recolour a caption that asked for `.secondary`, a `+N −M` that asked for green, or a state dot that paints itself, so only those read the flag |
| Step 9 maps all 17 sizes onto 6 roles | 147 call sites rewritten — the **exact** equivalences only. 9, 10, 10.5, 12, 12.5 and everything from 14 up are untouched | Collapsing a 20pt sheet heading onto a 13pt title is a visual decision, not a sweep. As built the type commit renders identically; what it buys is that the next row asks for a role |

`TaskStatusStyle` also stayed in `TaskStatusStyle.swift` rather than moving to `Theme.swift`: it maps a status
to an SF Symbol *and* a token, and the file it lives in also holds `SidebarMetrics` and `trailingFade`. It is a
component, not a token table.

Two things the green build did not catch, both fixed in a follow-up commit: the step-7 sweep matched
`Color.primary.opacity` but never `foregroundStyle(.secondary)` / `.tertiary`, so the 190 sites that keep the
AA-failing hierarchy were still there; and `TerminalAppearance.swift:35` reads the bare
`NSColor.windowBackgroundColor`, which the sweep's SwiftUI pattern missed — with `Ground` now Ivory in light,
the terminal sat a shade off every pane around it and mixed its sixteen ANSI colours against a ground nothing
else used. It reads the `Ground` asset now, which also means the spec's claim that "A does not repaint the
ground, so the derivation stays valid" was wrong: A *does* repaint it, Ivory for system grey.

**Not visually verified.** A throwaway instance launches fine
(`open -n --env SCOPE_HOME=…`), but `CGWindowListCopyWindowInfo` returns empty owner names and
`screencapture -l` fails with *could not create image from window* — this machine has no Screen Recording grant
for the tooling. The build is green and every colorset name resolves
(`comm` of referenced names against the catalogue is empty), but **the pixels have not been looked at**. Run
`make run` and check the sidebar selection in both appearances, key and inactive.

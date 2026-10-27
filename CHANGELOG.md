# Changelog

All notable changes to Scope are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Entries are generated from [Conventional Commits](https://www.conventionalcommits.org) by [git-cliff](https://git-cliff.org).

## [Unreleased]

Changes merged to `main` but not released yet: `git cliff --unreleased`.
`scripts/release.sh` inserts the next version section below this one.

## [0.32.0](https://github.com/maastrich/scope/releases/tag/v0.32.0) - 2026-10-27

### Added

- a persisted event journal, and no more CursorUI flood in the unified log ([#119](https://github.com/maastrich/scope/pull/119)) by @maastrich

### Fixed

- **pr-panel:** open CI jobs in the context of their pull request ([#118](https://github.com/maastrich/scope/pull/118)) by @maastrich

### Documentation

- **research:** what a week of Scope's logs says, and what to fix first ([#117](https://github.com/maastrich/scope/pull/117)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.31.0...v0.32.0

## [0.31.0](https://github.com/maastrich/scope/releases/tag/v0.31.0) - 2026-10-23

### Added

- **island:** follow the screen of the active window ([#114](https://github.com/maastrich/scope/pull/114)) by @maastrich
- **island:** stay out of the way while you work or watch something in full screen ([#115](https://github.com/maastrich/scope/pull/115)) by @maastrich
- **island:** an always-black island — a hanging capsule, requests that widen until answered, a clearer open list ([#116](https://github.com/maastrich/scope/pull/116)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.30.0...v0.31.0

## [0.30.0](https://github.com/maastrich/scope/releases/tag/v0.30.0) - 2026-10-22

### Added

- **island:** an island under the notch with the threads' activity, answers and reveals ([#110](https://github.com/maastrich/scope/pull/110)) by @maastrich
- **graph:** cards, list and graph views of a scope's repos, and setup commands checked against the repo ([#112](https://github.com/maastrich/scope/pull/112)) by @maastrich

### Fixed

- **threads:** keep the user's half-typed prompt out of messages Scope types into Claude Code ([#111](https://github.com/maastrich/scope/pull/111)) by @maastrich
- **terminal:** hide macOS cursor accessories while the terminal cursor is hidden ([#113](https://github.com/maastrich/scope/pull/113)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.29.2...v0.30.0

## [0.29.2](https://github.com/maastrich/scope/releases/tag/v0.29.2) - 2026-10-21

### Fixed

- **browser:** initialize WebKit before listing data stores on archive ([#109](https://github.com/maastrich/scope/pull/109)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.29.1...v0.29.2

## [0.29.1](https://github.com/maastrich/scope/releases/tag/v0.29.1) - 2026-10-21

### Fixed

- **git:** run git and every helper with the login shell's PATH, so Git LFS repos can join a task ([#108](https://github.com/maastrich/scope/pull/108)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.29.0...v0.29.1

## [0.29.0](https://github.com/maastrich/scope/releases/tag/v0.29.0) - 2026-10-20

### Added

- **inspector:** a Browser pane of the task in the reading column ([#103](https://github.com/maastrich/scope/pull/103)) by @maastrich
- **inspector:** an Overview of what is happening, and a Details page for the rest ([#104](https://github.com/maastrich/scope/pull/104)) by @maastrich
- **browser:** the task's agents open, read, screenshot and read the console of its browser ([#105](https://github.com/maastrich/scope/pull/105)) by @maastrich
- **browser:** the task's agents click, type, wait and read the network, within the sites you allow ([#106](https://github.com/maastrich/scope/pull/106)) by @maastrich
- **browser:** compare a route on the base branch and the task, side by side, with what differs ([#107](https://github.com/maastrich/scope/pull/107)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.28.0...v0.29.0

## [0.28.0](https://github.com/maastrich/scope/releases/tag/v0.28.0) - 2026-10-20

### Added

- **tasks:** several branches in one task, each in its own worktree ([#81](https://github.com/maastrich/scope/pull/81)) by @maastrich
- **usage:** show the subscription's limits ahead of token counts ([#79](https://github.com/maastrich/scope/pull/79)) by @maastrich
- **inspector:** cards instead of flat sections, and a pane strip in the band ([#83](https://github.com/maastrich/scope/pull/83)) by @maastrich
- **sidebar:** compact rows grouped by state, one indicator per row ([#84](https://github.com/maastrich/scope/pull/84)) by @maastrich
- **inspector:** a Shell pane of the task in the reading column ([#85](https://github.com/maastrich/scope/pull/85)) by @maastrich
- **inspector:** compact pull request rows with check tallies, and what each one asks of you ([#86](https://github.com/maastrich/scope/pull/86)) by @maastrich
- **inspector:** the Context card shows the files given to the agent, its skills, model and context gauge ([#88](https://github.com/maastrich/scope/pull/88)) by @maastrich
- **inspector:** the Artifacts card shows the report, files outside the diff and published pages ([#89](https://github.com/maastrich/scope/pull/89)) by @maastrich
- **adapters:** keep what Claude Code reports between turns, from its hooks and its transcript ([#95](https://github.com/maastrich/scope/pull/95)) by @maastrich
- **inspector:** setup, listening processes and agent time in the Environment card ([#87](https://github.com/maastrich/scope/pull/87)) by @maastrich
- **inspector:** a Plan card with the agent's steps, live ([#93](https://github.com/maastrich/scope/pull/93)) by @maastrich
- show a Claude Code thread's MCP servers, compactions, model, mode and pull requests ([#96](https://github.com/maastrich/scope/pull/96)) by @maastrich
- show and stop a Claude Code thread's background work ([#97](https://github.com/maastrich/scope/pull/97)) by @maastrich
- show a Claude Code thread's sub-agents in the sidebar, a Subagents card and the CLI ([#100](https://github.com/maastrich/scope/pull/100)) by @maastrich
- **inspector:** a Connectors card with the MCP servers of the task's Claude Code threads ([#99](https://github.com/maastrich/scope/pull/99)) by @maastrich
- show what a waiting Claude Code thread asks, and answer it from Scope ([#102](https://github.com/maastrich/scope/pull/102)) by @maastrich

### Fixed

- **tests:** drive the debounce timers with a test clock so a slow runner cannot split a burst ([#82](https://github.com/maastrich/scope/pull/82)) by @maastrich
- **sidebar:** no destructive control under the pointer, ask only when something is lost, undo any close ([#90](https://github.com/maastrich/scope/pull/90)) by @maastrich
- **tasks:** never auto-archive a merged task that is still working ([#94](https://github.com/maastrich/scope/pull/94)) by @maastrich
- **scene:** wrap the empty scope's driver buttons instead of pushing the scene over the sidebar ([#98](https://github.com/maastrich/scope/pull/98)) by @maastrich
- **hooks:** stop losing hook events the app was slow to accept ([#101](https://github.com/maastrich/scope/pull/101)) by @maastrich

### Documentation

- **research:** what Scope can borrow from Claude Code Desktop's right panel and sidebar ([#80](https://github.com/maastrich/scope/pull/80)) by @maastrich
- **research:** an embedded browser in Scope ([#91](https://github.com/maastrich/scope/pull/91)) by @maastrich
- refocus Scope on Claude Code and inventory what it exposes ([#92](https://github.com/maastrich/scope/pull/92)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.27.0...v0.28.0

## [0.27.0](https://github.com/maastrich/scope/releases/tag/v0.27.0) - 2026-10-19

### Added

- **delta:** keep viewed marks across launches and flag files changed since viewed ([#71](https://github.com/maastrich/scope/pull/71)) by @maastrich
- **shortcuts:** hold ⌘ to see every control's shortcut beside it ([#75](https://github.com/maastrich/scope/pull/75)) by @maastrich
- **updates:** stage releases in the background and offer a restart instead of a daily check ([#73](https://github.com/maastrich/scope/pull/73)) by @maastrich
- **control:** fewer round trips for agents driving Scope ([#76](https://github.com/maastrich/scope/pull/76)) by @maastrich
- **tasks:** show every pull request of a task, and archive only once all are merged ([#78](https://github.com/maastrich/scope/pull/78)) by @maastrich

### Fixed

- **drivers:** open agent-created tasks and threads on the Settings default driver ([#74](https://github.com/maastrich/scope/pull/74)) by @maastrich
- **usage:** count time on screen only while looked at, and classify each thread state once ([#77](https://github.com/maastrich/scope/pull/77)) by @maastrich

### Documentation

- **research:** what the diff view can do for reviewing an agent's work ([#72](https://github.com/maastrich/scope/pull/72)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.26.0...v0.27.0

## [0.26.0](https://github.com/maastrich/scope/releases/tag/v0.26.0) - 2026-10-19

### Added

- **state:** reload state files changed on disk, and archive the right task for a shared slug ([#70](https://github.com/maastrich/scope/pull/70)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.25.0...v0.26.0

## [0.25.0](https://github.com/maastrich/scope/releases/tag/v0.25.0) - 2026-10-16

### Added

- **reader:** read an agent's answer as it is written, with its tools, checkpoint and earlier turns ([#69](https://github.com/maastrich/scope/pull/69)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.24.0...v0.25.0

## [0.24.0](https://github.com/maastrich/scope/releases/tag/v0.24.0) - 2026-10-16

### Added

- **tasks:** try a task's branch in your own checkout, then put it back ([#62](https://github.com/maastrich/scope/pull/62)) by @maastrich
- **control:** scope release cuts a release from a thread, the app doing the work ([#63](https://github.com/maastrich/scope/pull/63)) by @maastrich
- **tasks:** every turn leaves a checkpoint, and the owner can go back to one ([#64](https://github.com/maastrich/scope/pull/64)) by @maastrich
- **threads:** ask an agent interrupted by a restart to continue its work ([#65](https://github.com/maastrich/scope/pull/65)) by @maastrich
- **tasks:** run one brief as several attempts, compare them, keep one ([#66](https://github.com/maastrich/scope/pull/66)) by @maastrich
- scheduled prompts and milestone missions ([#67](https://github.com/maastrich/scope/pull/67)) by @maastrich

### Fixed

- **reader:** wrap table cells in their column instead of drawing rows over each other ([#61](https://github.com/maastrich/scope/pull/61)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.23.0...v0.24.0

## [0.23.0](https://github.com/maastrich/scope/releases/tag/v0.23.0) - 2026-10-16

### Added

- choose the model of a thread or task, and send driver slash commands over thread.send ([#56](https://github.com/maastrich/scope/pull/56)) by @maastrich
- **tasks:** a task follows main on its own ([#57](https://github.com/maastrich/scope/pull/57)) by @maastrich
- **assist:** on-device assist — stuck threads, notification triage, archive hint, topic pick ([#58](https://github.com/maastrich/scope/pull/58)) by @maastrich
- a system-wide hotkey opens a quick panel to ask an orchestrator or answer the Inbox ([#59](https://github.com/maastrich/scope/pull/59)) by @maastrich
- **tasks:** mention past tasks in prompts, open a task from an issue, show listening ports and disk size ([#60](https://github.com/maastrich/scope/pull/60)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.22.0...v0.23.0

## [0.22.0](https://github.com/maastrich/scope/releases/tag/v0.22.0) - 2026-10-16

### Added

- **usage:** see how many tokens the agents consumed ([#49](https://github.com/maastrich/scope/pull/49)) by @maastrich
- **inbox:** what needs you, in every scope, with the action at hand ([#52](https://github.com/maastrich/scope/pull/52)) by @maastrich
- **sidebar:** say what moved in a scope since your last visit ([#51](https://github.com/maastrich/scope/pull/51)) by @maastrich
- a timeline of the task, at a glance ([#53](https://github.com/maastrich/scope/pull/53)) by @maastrich
- **ui:** hide the sidebar footer by default, make every sash easier to grab and reset on double-click ([#55](https://github.com/maastrich/scope/pull/55)) by @maastrich
- read the agent's reply as Markdown, keep the deliverable at archive, show the brief in the inspector ([#54](https://github.com/maastrich/scope/pull/54)) by @maastrich

### Fixed

- **threads:** permissions granted by auto mode or another hook no longer show as waiting ([#48](https://github.com/maastrich/scope/pull/48)) by @maastrich
- **threads:** a finished turn stays finished, and thread wait returns when it ends ([#50](https://github.com/maastrich/scope/pull/50)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.21.0...v0.22.0

## [0.21.0](https://github.com/maastrich/scope/releases/tag/v0.21.0) - 2026-10-16

### Added

- restore archived tasks from agents, and task actions in the palette ([#38](https://github.com/maastrich/scope/pull/38)) by @maastrich
- **threads:** remember what each agent last did and said ([#39](https://github.com/maastrich/scope/pull/39)) by @maastrich
- **notifications:** quote what the agent said, and reply from the banner ([#40](https://github.com/maastrich/scope/pull/40)) by @maastrich
- **sidebar:** show what each agent is doing, and where a task came from ([#41](https://github.com/maastrich/scope/pull/41)) by @maastrich
- ask the orchestrator from ⌘K, reply to a thread from the sidebar ([#43](https://github.com/maastrich/scope/pull/43)) by @maastrich
- **tasks:** cited pull requests stay context, --pr to start from one, scope config for budgets ([#44](https://github.com/maastrich/scope/pull/44)) by @maastrich
- **usage:** a private log of how Scope is used, readable with scope usage ([#45](https://github.com/maastrich/scope/pull/45)) by @maastrich
- a task's Claude Code threads load every repository's skills ([#46](https://github.com/maastrich/scope/pull/46)) by @maastrich
- **tasks:** refresh every task's pull request in the background, archive on merge, flag forgotten tasks ([#42](https://github.com/maastrich/scope/pull/42)) by @maastrich

### Fixed

- **tasks:** emptying the trash waits for the pass already running ([#47](https://github.com/maastrich/scope/pull/47)) by @maastrich

### Documentation

- **research:** ideas to improve how Scope is used ([#37](https://github.com/maastrich/scope/pull/37)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.20.0...v0.21.0

## [0.20.0](https://github.com/maastrich/scope/releases/tag/v0.20.0) - 2026-10-16

### Added

- **agents:** file a running task under a topic, or out of one ([#36](https://github.com/maastrich/scope/pull/36)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.19.0...v0.20.0

## [0.19.0](https://github.com/maastrich/scope/releases/tag/v0.19.0) - 2026-10-15

### Added

- **agents:** let any task create tasks, and group related tasks under a topic ([#34](https://github.com/maastrich/scope/pull/34)) by @maastrich
- **agents:** summarize what was done over a period, closed work included ([#35](https://github.com/maastrich/scope/pull/35)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.18.0...v0.19.0

## [0.18.0](https://github.com/maastrich/scope/releases/tag/v0.18.0) - 2026-10-15

### Added

- **agents:** wait for threads, read their last reply, and rename the skill to scope ([#32](https://github.com/maastrich/scope/pull/32)) by @maastrich
- **threads:** keep an orchestrator and a terminal in every scope ([#33](https://github.com/maastrich/scope/pull/33)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.17.0...v0.18.0

## [0.17.0](https://github.com/maastrich/scope/releases/tag/v0.17.0) - 2026-10-14

### Added

- **inspector:** collapsible sections, a reading column, and file links from the terminal ([#31](https://github.com/maastrich/scope/pull/31)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.16.1...v0.17.0

## [0.16.1](https://github.com/maastrich/scope/releases/tag/v0.16.1) - 2026-10-14

### Fixed

- **sidebar:** loop the scope swipe, preview where it lands, and line the tiles up with it ([#29](https://github.com/maastrich/scope/pull/29)) by @maastrich
- **sidebar:** line up row columns and give every row a trailing state dot ([#30](https://github.com/maastrich/scope/pull/30)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.16.0...v0.16.1

## [0.16.0](https://github.com/maastrich/scope/releases/tag/v0.16.0) - 2026-10-14

### Added

- **tasks:** reliable archive and automatic cleanup of sandboxes and processes ([#27](https://github.com/maastrich/scope/pull/27)) by @maastrich

### Fixed

- **editor:** open a task in its own editor window, and find it again ([#26](https://github.com/maastrich/scope/pull/26)) by @maastrich
- **sidebar:** make the scope swipe follow the fingers and settle like a page ([#28](https://github.com/maastrich/scope/pull/28)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.15.0...v0.16.0

## [0.15.0](https://github.com/maastrich/scope/releases/tag/v0.15.0) - 2026-10-14

### Added

- **scopes:** keep a scope's image as a small square PNG, with a dark variant and a context by @maastrich
- **scopes:** give each scope a settings sheet, and images that always sit inside the tile by @maastrich

### Fixed

- **graph:** make the AI analysis describe each repository in one sentence drawn from its code by @maastrich
- **ui:** stop the spinner and the state pill from jumping around by @maastrich
- **scopes:** never take an image away at launch, and list the graph in the scope settings by @maastrich
- **graph:** redo with AI the cards an older prompt wrote by @maastrich

### Documentation

- describe scope images, the scope settings sheet and the one-sentence purpose by @maastrich
- say what the launch cleanup keeps and when a card is redone by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.14.0...v0.15.0

## [0.14.0](https://github.com/maastrich/scope/releases/tag/v0.14.0) - 2026-10-14

### Added

- **base:** decide which repository the Base panel shows in one tested rule by @maastrich
- **scopes:** switching scope returns to where you were in it by @maastrich
- **settings:** choose whether threads opened by agents come to the front by @maastrich
- **scopes:** switch scope from the keyboard by @maastrich
- **sidebar:** say what each row is doing, and choose how the list is arranged by @maastrich
- **scopes:** show every scope as a tile in the sidebar header by @maastrich
- **base:** follow an agent to the repository it is working in by @maastrich
- **scopes:** swipe between scopes, reorder them, and name the path on screen by @maastrich
- **ui:** flat columns, neutral colours and a quiet selection by @maastrich
- **delta:** leave committing and pushing to the agent by default by @maastrich
- **ui:** take the chrome's colours from the Mobsuccess charter by @maastrich

### Fixed

- **inspector:** keep Base on the repository you are working in by @maastrich
- **inspector:** a tab asked for without a task does not become the next task's tab by @maastrich
- **threads:** a thread or task opened by an agent no longer takes the selection by @maastrich
- **inspector:** dim the tabs that have nothing to show by @maastrich
- **ui:** keep the terminal through a colour change and the selection through a scope switch by @maastrich

### Documentation

- **design:** research the information architecture and Arc-style scope switching by @maastrich
- **design:** record that agent-opened threads and tasks take the selection by @maastrich
- **design:** record the prototype review decisions by @maastrich
- **design:** default the sidebar to detailed rows arranged as a tree by @maastrich
- **design:** add scope logos, tile state precedence and tile overflow by @maastrich
- **design:** size the tile row to the sidebar and mark working scopes by @maastrich
- **design:** order scope tiles by importance, keep the chords on declared order by @maastrich
- **spec:** describe the scope tiles, the Base rule and the flat three-column window by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.13.0...v0.14.0

## [0.13.0](https://github.com/maastrich/scope/releases/tag/v0.13.0) - 2026-10-13

### Added

- **settings:** draw the settings window's controls ourselves by @maastrich
- **sheets:** give the New Task and Commit sheets their own chrome by @maastrich
- **sidebar:** mark the threads an agent opened by @maastrich
- **ui:** replace the remaining AppKit controls in the main window by @maastrich

### Fixed

- **app:** refuse the production home in a Debug build and say so by @maastrich
- **socket:** never take over a socket somebody is listening on by @maastrich
- **cli:** let --home beat the socket inherited from a thread by @maastrich
- **cli:** keep a Debug build from taking over the installed `scope` link by @maastrich
- **updates:** compile Sparkle out of Debug builds by @maastrich
- **app:** keep UI state under the home instead of one shared file by @maastrich
- **app:** stop a Debug build from presenting itself as Scope by @maastrich
- **tasks:** give Debug builds their own SCOPE_PORT range by @maastrich
- **make:** fail `make run` when another copy of the app is running by @maastrich
- **app:** stop passing the launching thread's environment to new threads by @maastrich
- **app:** recognise the production home through a link when it does not exist yet by @maastrich
- **ui:** let a menu's value truncate, dim it when disabled, refit the card links by @maastrich
- **toolbar:** drop the glass capsule behind the trailing toolbar items by @maastrich
- **delta:** keep the image diff's mode names whole by @maastrich

### Documentation

- audit what a Debug build could share with the installed app by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.12.2...v0.13.0

## [0.12.2](https://github.com/maastrich/scope/releases/tag/v0.12.2) - 2026-10-12

### Fixed

- **release:** export with a certificate that has no team, and never report a dead build green ([#20](https://github.com/maastrich/scope/pull/20)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.12.1...v0.12.2

## [0.12.1](https://github.com/maastrich/scope/releases/tag/v0.12.1) - 2026-10-12

### Fixed

- **release:** stop the keychain trust step from hanging the build ([#19](https://github.com/maastrich/scope/pull/19)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.12.0...v0.12.1

## [0.12.0](https://github.com/maastrich/scope/releases/tag/v0.12.0) - 2026-10-12

### Fixed

- clear the release build warnings ([#16](https://github.com/maastrich/scope/pull/16)) by @maastrich
- keep Debug builds off the production home, and give releases a stable code identity ([#17](https://github.com/maastrich/scope/pull/17)) by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.11.0...v0.12.0

## [0.11.0](https://github.com/maastrich/scope/releases/tag/v0.11.0) - 2026-10-12

### Added

- **ui:** name the surface, fill and text tokens the app was missing by @maastrich
- **ui:** drop the sidebar's vibrancy for an opaque surface by @maastrich
- **ui:** switch to the Ink palette and add the app's own controls by @maastrich
- **ui:** replace the native controls with the app's own by @maastrich

### Fixed

- **sidebar:** keep a selected row readable on the accent fill by @maastrich
- **ui:** put the text hierarchy and the terminal ground on the tokens by @maastrich
- **terminal:** keep ANSI black visible on the Onyx ground by @maastrich

### Changed

- **ui:** paint the floating surfaces and retire the alpha fills by @maastrich
- **ui:** name the six type roles at their exact call sites by @maastrich
- **ui:** put the component library to work by @maastrich

### Documentation

- **design:** research an opaque, brand-coloured UI direction by @maastrich
- **design:** spec direction A, the opaque one-accent chrome by @maastrich
- **design:** record how the build diverged from the spec by @maastrich
- **design:** note the two sweeps the green build hid by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.10.2...v0.11.0

## [0.10.2](https://github.com/maastrich/scope/releases/tag/v0.10.2) - 2026-09-17

### Fixed

- **threads:** deliver multiline messages whole instead of cutting them at a line break by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.10.1...v0.10.2

## [0.10.1](https://github.com/maastrich/scope/releases/tag/v0.10.1) - 2026-09-16

### Fixed

- **terminal:** drop a file into the terminal instead of declaring a scope by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.10.0...v0.10.1

## [0.10.0](https://github.com/maastrich/scope/releases/tag/v0.10.0) - 2026-09-15

### Added

- **automation:** let threads talk to each other across tasks and scopes by @maastrich

### Fixed

- **terminal:** light-mode prompts and expanded output no longer draw on dark blocks by @maastrich
- **ui:** draw the thread state as a quiet pill, not a glass blob, in the toolbar by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.9.0...v0.10.0

## [0.9.0](https://github.com/maastrich/scope/releases/tag/v0.9.0) - 2026-09-14

### Added

- **ui:** keep the inspector on the task, open the graph and pull requests from the sidebar by @maastrich
- **terminal:** let Claude Code draw with the terminal palette by @maastrich
- **terminal:** build the palette from the system colours of the appearance by @maastrich
- **automation:** install the Scope tasks skill for your agents, copy a task's name by @maastrich

### Fixed

- **ui:** keep the thread title inside the toolbar and README tables out of the graph cards by @maastrich
- **ui:** draw the thread title as the window title, not a custom toolbar item by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.8.0...v0.9.0

## [0.8.0](https://github.com/maastrich/scope/releases/tag/v0.8.0) - 2026-09-14

### Added

- **tasks:** bind a task to the pull request its branch got outside Scope by @maastrich

### Fixed

- **inspector:** keep the PR checks list from pushing the task band off the panel by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.7.0...v0.8.0

## [0.7.0](https://github.com/maastrich/scope/releases/tag/v0.7.0) - 2026-09-14

### Added

- **inspector:** preview image files and compare image diffs by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.6.0...v0.7.0

## [0.6.0](https://github.com/maastrich/scope/releases/tag/v0.6.0) - 2026-09-11

### Added

- **threads:** tell running, finished, asking and failed threads apart by @maastrich
- **tasks:** keep agents in a task from committing outside it or pushing to main by @maastrich
- **threads:** clicking a Scope session in Vibe Island selects its thread by @maastrich
- **threads:** bring running threads back when Scope reopens by @maastrich

### Fixed

- **adapters:** stop two Scope instances with deep homes sharing one socket by @maastrich
- **control:** make thread send submit the prompt instead of pasting it by @maastrich
- **delta:** refresh a task's delta when its branch moves, not only when files change by @maastrich
- **threads:** stop the auto-relaunch when Scope quits mid-way by @maastrich

### Changed

- tighten Swift 6 concurrency in thread kill and test recorder by @maastrich

### Documentation

- describe the new thread states and the sandbox git guardrails by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.5.0...v0.6.0

## [0.5.0](https://github.com/maastrich/scope/releases/tag/v0.5.0) - 2026-09-11

### Added

- **sidebar:** one status glyph per task row, one row for a single-thread task by @maastrich
- **tasks:** run a setup command in new sandboxes and a teardown before removing them by @maastrich
- **delta:** comment on diff lines and send the review to the task's thread by @maastrich
- **prs:** see a task's checks, send a failure to its thread, merge or fix conflicts by @maastrich
- **cli:** let an agent read the terminal of a thread it opened by @maastrich
- keep sandboxes out of Spotlight, mark files as viewed, open tasks from links by @maastrich

### Fixed

- **delta:** send a review at once to a thread whose hooks never reported by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.4.5...v0.5.0

## [0.4.5](https://github.com/maastrich/scope/releases/tag/v0.4.5) - 2026-09-10

### Fixed

- **tasks:** stop warning when a repository has its own AGENTS.md or CLAUDE.md by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.4.4...v0.4.5

## [0.4.4](https://github.com/maastrich/scope/releases/tag/v0.4.4) - 2026-09-10

### Added

- **automation:** agents create and close tasks without asking by default by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.4.3...v0.4.4

## [0.4.3](https://github.com/maastrich/scope/releases/tag/v0.4.3) - 2026-09-10

### Added

- **mcp:** register `scope mcp` with Claude Code, Codex and Cursor for the user by @maastrich
- **cli:** stop, close and type into threads, and undo a task by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.4.2...v0.4.3

## [0.4.2](https://github.com/maastrich/scope/releases/tag/v0.4.2) - 2026-09-10

### Added

- **terminal:** ⌘← ⌘→ ⌘⌫ ⌘⌦ reach the ends of the line by @maastrich
- **view:** ⌘M maximizes the current thread inside the window by @maastrich
- **threads:** Relaunch picks the previous driver session back up by @maastrich
- **threads:** mark a waiting thread as read by @maastrich

### Fixed

- **terminal:** ⌥ types the character your keyboard puts there by @maastrich
- **sidebar:** the New Thread button opens a loose thread, even with a task selected by @maastrich
- **palette:** the command palette stands in front of its backdrop by @maastrich
- **terminal:** a scroll marker when there is history, nothing when there is not by @maastrich
- **view:** ⌃⌘S shows and hides the sidebar by @maastrich
- **git:** a git command can no longer hang its repository for the life of the app by @maastrich
- **settings:** code in two captions shows as code, not as backticks by @maastrich

### Documentation

- bring the site and its screenshots up to date with the app by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.4.1...v0.4.2

## [0.4.1](https://github.com/maastrich/scope/releases/tag/v0.4.1) - 2026-09-10

### Fixed

- **cli:** `scope --version` reports the version of the app it ships inside by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.4.0...v0.4.1

## [0.4.0](https://github.com/maastrich/scope/releases/tag/v0.4.0) - 2026-09-10

### Added

- **cli:** drive Scope from the terminal with `scope` by @maastrich
- **cli:** create a task from the terminal with `scope task new` by @maastrich
- **mcp:** `scope mcp` gives an agent the same commands as the terminal by @maastrich

### Documentation

- how to drive Scope from a terminal or an agent by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.3.1...v0.4.0

## [0.3.1](https://github.com/maastrich/scope/releases/tag/v0.3.1) - 2026-09-10

### Fixed

- **terminal:** ⇧↩ inserts a newline instead of submitting by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.3.0...v0.3.1

## [0.3.0](https://github.com/maastrich/scope/releases/tag/v0.3.0) - 2026-09-10

### Added

- **ui:** let the icon buttons answer the pointer by @maastrich
- **threads:** name a thread after its context, not its driver by @maastrich

### Fixed

- **sidebar:** give the terminal the keyboard whenever the selection shows one by @maastrich
- **ui:** follow the macOS pointer conventions by @maastrich
- **ui:** set the pointer from SwiftUI hover, the only thing that works here by @maastrich
- **sidebar:** a thread row can be selected again by @maastrich
- **sidebar:** open a task at its first thread, and insist on the keyboard by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.2.2...v0.3.0

## [0.2.2](https://github.com/maastrich/scope/releases/tag/v0.2.2) - 2026-09-09

### Added

- **drivers:** an opt-in Claude Code profile that skips the permission prompts by @maastrich

### Fixed

- **release:** let the ad-hoc app load its own Sparkle by @maastrich
- **dev:** a Debug build is its own app by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.2.1...v0.2.2

## [0.2.1](https://github.com/maastrich/scope/releases/tag/v0.2.1) - 2026-09-09

### Fixed

- **notifications:** post through the async notification API by @maastrich
- **tasks:** a repository whose branch is master can have tasks again by @maastrich
- **tasks:** show a failed New Task where the button is by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.2.0...v0.2.1

## [0.2.0](https://github.com/maastrich/scope/releases/tag/v0.2.0) - 2026-09-09

### Added

- **sidebar:** one tree, one selection, and a state column that holds by @maastrich
- **inspector:** a summary band that owns the task detail by @maastrich

### Fixed

- **updates:** never run Sparkle in a Debug build by @maastrich

### Documentation

- **install:** say what a missing release means by @maastrich
- a CLAUDE.md for agents working on Scope by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.1.0...v0.2.0

## [0.1.0](https://github.com/maastrich/scope/releases/tag/v0.1.0) - 2026-09-09

### Added

- **threads:** live states and resume for Claude Code via hooks (M1) by @maastrich
- **threads:** auto-close tabs of exited threads with a 10 s toast by @maastrich
- **tasks:** git worktrees, diff parser, delta queries and task manager (M2 core) by @maastrich
- **tasks:** task creation, sandbox threads and the Delta inspector (M2 UI) by @maastrich
- **graph:** repo cards, L0/L1 generation, graph cache and base operations (M3 core) by @maastrich
- **graph:** Graph cards and Base view in the inspector (M3 UI) by @maastrich
- **app:** notifications, Dock badge, command palette and menu bar extra (M4) by @maastrich
- **prs:** list open pull requests and open or switch to them as tasks by @maastrich
- **search:** terminal find, richer Base search, sidebar filter, file finder, palette scoring (audit lot 3) by @maastrich
- **sidebar:** show the current scope's tasks and threads; repositories on demand by @maastrich
- **app:** app icon and menu bar glyph by @maastrich
- **tasks:** the driver proposes the branch from an initial prompt by @maastrich
- **tasks:** a task on a pull request checks its branch out by @maastrich
- **nav:** threads are switched from the sidebar alone ([#1](https://github.com/maastrich/scope/pull/1)) by @maastrich
- **tasks:** a microsession names the task, its repositories and its pull request by @maastrich
- **terminal:** the cursor shape is a preference by @maastrich
- **threads:** the driver you want is one click, not one click inside a menu by @maastrich
- **install:** a one-liner that installs the DMG and clears the quarantine flag by @maastrich

### Fixed

- **ui:** hide inspector picker when collapsed, paint terminal dark from first frame by @maastrich
- **ui:** sidebar truncation, system-following terminal theme, inspector under toolbar by @maastrich
- **ui:** colour assets, readable captions, terminal preferences (audit lot 1) by @maastrich
- **ui:** native-text diff and viewer, selection-driven context, resizable inspector, tab strip (audit lot 2) by @maastrich
- **ui:** live thread rename, context-aware New Thread everywhere, graph filter, auto-close preference by @maastrich
- **ui:** inspector header shares the tab strip band, panels anchored at the top by @maastrich
- **tasks:** leaving a pull request start point restores the proposed branch by @maastrich
- **tasks:** the context file lands where the agent actually looks by @maastrich
- **tasks:** the New Task sheet gets the resolved driver, not the raw preference by @maastrich

### Documentation

- GitHub social preview image by @maastrich
- a GitHub Pages documentation site by @maastrich
- absolute Open Graph URLs and the command palette by @maastrich
- the prompt-first task flow by @maastrich

**Full Changelog**: https://github.com/maastrich/scope/compare/v0.1.0-rc.1...v0.1.0

## [0.1.0-rc.1](https://github.com/maastrich/scope/releases/tag/v0.1.0-rc.1) - 2026-09-07

### Added

- bootstrap Scope with the M0 skeleton by @maastrich
- add Sparkle auto-update and release docs by @maastrich

### New Contributors

- @maastrich made their first contribution


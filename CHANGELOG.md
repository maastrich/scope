# Changelog

All notable changes to Scope are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Entries are generated from [Conventional Commits](https://www.conventionalcommits.org) by [git-cliff](https://git-cliff.org).

## [Unreleased]

Changes merged to `main` but not released yet: `git cliff --unreleased`.
`scripts/release.sh` inserts the next version section below this one.

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


# Scope

Native macOS app: a control room for CLI coding agents. A *scope* is any declared folder, a *thread* is a
driver (Claude Code, Codex, Cursor, a shell) running in an embedded PTY, a *task* gets one git worktree per
repository so agents never touch your checkouts.

`SPEC.md` is the reference (French, still authoritative on intent). `README.md` covers building and releasing.
`docs/` is the published site.

## Layout

| Path | What |
|---|---|
| `App/Scope/` | the SwiftUI/AppKit app target: `Model/` (`AppModel` + extensions), `Views/`, `Terminal/`, `Commands/`, `Environment/` |
| `Sources/Scope*/` | the ScopeKit SwiftPM package: `ScopeCore` (config, ids, watching), `ScopeGit`, `ScopeDrivers` (profiles, headless runs), `ScopeTasks` (worktrees, proposals), `ScopeGraph`, `ScopeAdapters` (socket transport + hook events), `ScopeControl` (the request/response protocol, the policy, the CLI parsing, the MCP catalogue) |
| `Sources/scope-hook/`, `Sources/scope/` | the two helpers: the one drivers call on every event, and the command line (`scope mcp` included) |
| `Tests/ScopeKitTests/` | Swift Testing suites — **package only**; nothing in `App/Scope/` is reachable from them |
| `scripts/` | `release.sh`, `package.sh` (DMG), `appcast.sh` (Sparkle), `install.sh`, `build-docs.py` |

## Commands

```sh
make build                       # regenerate the project + build the Debug app
make run                         # build + open
swift build                      # the package alone (fast; no AppKit, no SwiftTerm)
swift test --filter SlugTests    # ONE suite at a time, always
python3 scripts/build-docs.py    # regenerate docs/*.html
scripts/release.sh --dry-run     # preview the next release
```

`make build` pipes through `tail -20`, which hides compiler errors. For the real output:

```sh
xcodebuild -project Scope.xcodeproj -scheme Scope -configuration Debug \
  -derivedDataPath DerivedData -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

## Things that will bite you

- **`docs/*.html` is generated** by `scripts/build-docs.py`, which holds the page content inline. Edit the
  generator, then regenerate; edits to the HTML are silently lost on the next build. The generator textually
  replaces the token `REPO`, so never write `SCOPE_REPO` in doc prose.
- **Bundled driver profiles** live in `Sources/ScopeDrivers/Builtin/*.json`. Changing one means bumping its
  `"version"`, otherwise `DriverRegistry.installBuiltins` leaves the copy already in `~/.scope/drivers/`
  alone and nobody sees the change.
- **The app target has no tests.** `AppModel`, the views and the terminal are only covered by building and by
  running the app. Logic worth testing belongs in the package.
- **SwiftTerm's `keyDown` is `public`, not `open`.** Key handling the terminal swallows goes through the local
  event monitor in `App/Scope/Terminal/TerminalKeyBindings.swift` (that is how ⌘↩ sends a newline).
- **A task's context file** (`AGENTS.md`, `CLAUDE.md`, …) is written at `TaskRecord.threadCwd` — the sandbox
  for a one-repository task, the task root otherwise — under every name the installed profiles declare, and
  excluded through `.git/info/exclude`. Writing it anywhere else means the driver never reads it. A
  repository's own file is never touched; the context then goes to a companion the driver reads *in addition*
  (`CLAUDE.local.md`), never to one it reads *instead* (`AGENTS.override.md` would shadow the repo's rules).
- **Microsession argv** (`headlessLight`): keep `{prompt}` *before* variadic flags like `--tools` or
  `--allowedTools`, which would otherwise swallow it.
- **A socket callback needs `qos: .userInitiated`.** At the default QoS macOS throttles a background app's
  dispatch queues hard: the same ping answered in 2 ms went to 5–8 s once the app had been idle a minute.
  `UnixSocketServer` and both socket clients set it explicitly.
- **The `scope` tool target is called `scope-cli` in `project.yml`.** The app target is `Scope`, and on a
  case-insensitive filesystem two targets whose names differ only in case share one `Scope.build` folder —
  the second to build wins and the first fails with *unable to open dependencies file*. `PRODUCT_NAME` keeps
  the binary named `scope`.
- **Anything an agent can ask for goes through `ControlService`.** The CLI and the MCP server are façades
  over the same `ControlCall` values; put logic in `ScopeControl` (tested) or in `AppModel` (shared with the
  UI), never in `Sources/scope/`.
- **Never `pkill -f` the Scope binary.** It matches the user's running app too. Kill by pid.
- **A Debug build is a different app.** It is `Scope Debug.app`, bundle id `dev.maastrich.scope.debug`, and its
  data lives in `~/.scope-debug` — so it never shares config, thread records or the hook socket with the copy in
  `/Applications`, and Spotlight can tell them apart. Release is untouched (`Scope.app`, `dev.maastrich.scope`).

## Running a throwaway instance

`SCOPE_HOME` picks the data directory, so a second instance can run against a scratch workspace without
touching the Debug build's own `~/.scope-debug`:

```sh
open -n --env SCOPE_HOME=/tmp/scope-demo/home "$PWD/DerivedData/Build/Products/Debug/Scope Debug.app"
```

Seed `$SCOPE_HOME/config.json` with a scope declaration to skip the onboarding. Screenshots: find the window
id with `CGWindowListCopyWindowInfo` (owner `Scope Debug`), then `screencapture -x -o -l <id> shot.png`. The
window must be on a visible Space or the capture fails with *could not create image from window*.

## Conventions

- Code, comments, commits, documentation: **English**. Conversation with the user may be French.
- Conventional Commits; the subject says what the change does for the user, not which files moved.
- Comments explain **why**, never what the line already says. Match the density of the file you are in.
- Swift 6, strict concurrency, `@MainActor` for anything touching the UI or `AppModel`.
- The app writes nothing into the user's folders. Everything it produces lives under `SCOPE_HOME`.

## Releasing

`scripts/release.sh X.Y.Z` from a clean, up-to-date `main`: inserts the `CHANGELOG.md` section, commits, tags,
pushes; the tag drives `.github/workflows/release.yml`, which builds the DMG, signs the Sparkle appcast and
publishes. A tag with a suffix (`v0.2.0-rc.1`) is a prerelease and never becomes "Latest", so the Sparkle feed
ignores it.

The DMG is ad-hoc signed (no Developer ID); `scripts/install.sh` is the one-liner that installs it and clears
the quarantine flag. **`SUPublicEDKey` in `project.yml` can never change**: installed copies only accept
updates signed with the matching private key.

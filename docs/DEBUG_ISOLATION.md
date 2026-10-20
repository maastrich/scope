# Debug / Release isolation

A Debug build is a different app from the installed one: `Scope Debug.app`, bundle id
`dev.maastrich.scope.debug`, data in `~/.scope-debug`. The two must never share state. This page is the audit
of every place they could, what keeps them apart, and the test that holds it.

The pattern behind every hole found: **a Debug-only default that an inherited environment variable, a
LaunchServices lookup or a well-known path could override.** Scope injects `SCOPE_HOME`, `SCOPE_SOCK`,
`SCOPE_PORT`, `SCOPE_THREAD`, `SCOPE_TASK`, `SCOPE_TASK_ROOT`, `SCOPE_SCOPE` and `SCOPE_SCOPE_ROOT` into every
thread, so anything a build started from a thread reads from those was not chosen by anyone.

## Audit

"Before" is the state of `main` when the audit started. Tests are suites of `Tests/ScopeKitTests/`; the app
target has none, so a row whose mechanism lives in `App/Scope/` or `project.yml` says how it was checked instead.

| # | Surface | Before | Now | Mechanism | Where | Held by |
|---|---|---|---|---|---|---|
| 1 | Data home | **no** | yes | The app resolves its home through `AppHome.resolve`: a Debug build drops a `SCOPE_HOME` inherited from a thread, and never lands on `~/.scope` by any route (falls back to `~/.scope-debug` and reports an error). Every store takes `home:`; nothing else resolves it. | `Sources/ScopeControl/AppHome.swift:59`, `App/Scope/Environment/AppEnvironment.swift:92` | `AppHomeTests` (matrix), `ScopeHomeTests` |
| 1b | UI state | **no** | yes | `ui-state.json` moved from `~/Library/Application Support/Scope/` (one file for every build and every home) to `<home>/ui-state.json`. Only the installed app on its default home reads the old file, once. | `Sources/ScopeCore/ScopeHome.swift:103`, `App/Scope/Environment/UIStateStore.swift:71` | `ScopeHomeTests.uiStateFollowsTheHome` |
| 1e | Scope visits | n/a | yes | When each scope was last looked at, and its tasks' pull requests then, for the "since your last visit" strip: `<home>/scope-visits.json`, never shared between homes. | `Sources/ScopeCore/ScopeHome.swift` (`scopeVisitsURL`), `Sources/ScopeTasks/ScopeVisits.swift` | `ReturnDigestTests.visitsRoundTripThroughTheFile` |
| 1d | Scope logos | n/a | yes | The image chosen as a scope's logo is copied to `<home>/scope-logos/` and read from there; the declaration stores the file name only. Nothing is written in the scope's folder, and two homes never share a copy. | `Sources/ScopeCore/ScopeHome.swift` (`scopeLogosURL`), `App/Scope/Model/ScopeLogoStore.swift` | `ScopeLogoTests` for the stored form; the copy itself is in the app target, checked by importing into a throwaway home. |
| 1e | Token ledger | n/a | yes | What Claude Code threads consumed is kept in `<home>/tokens.json` (beside, not inside, the usage log's `usage/`), with the byte offset each transcript was read to. The transcripts under `~/.claude/projects/` are shared by every build but only read, and each build reads only the ones its own threads report, so neither counts the other's threads. | `Sources/ScopeAdapters/TokenLedger.swift` (`TokenLedgerStore`), `App/Scope/Environment/AppEnvironment.swift` | `TokenLedgerTests` (the store writes under the home it is given) |
| 1h | Plan limits | n/a | yes | The subscription's limits Claude Code last reported to a thread's status line are kept in `<home>/limits.json`. Each build hears only the threads it launched (its own `SCOPE_SOCK`), and the account file `~/.claude.json` is shared but only read. | `Sources/ScopeAdapters/RateLimits.swift` (`RateLimitsStore`), `App/Scope/Model/AppModel+TokenUsage.swift` | `RateLimitsTests.storeRoundTrip` (the store writes under the home it is given) |
| 1f | Assist ledger | n/a | yes | What the assistant did today — calls per tier, "not stuck" presses — is kept in `<home>/assist.json`, so the Haiku daily cap holds across a relaunch and never counts another build's calls. The on-device model is a system service shared by every process and holds no state of ours. | `Sources/ScopeAssist/AssistLedger.swift` (`AssistLedgerStore`), `App/Scope/Model/AppModel+Assist.swift` | `AssistJobsTests.theLedgerCountsPerTierAndStartsOverEachDay` (the store writes under the home it is given) |
| 1g | Checkpoint refs | n/a | yes | Every turn's snapshot of a sandbox is a commit under `refs/scope/checkpoints/<task-id>/<n>` in the user's repository, which both builds share. Task ids are per home and never collide, so neither build reads the other's; and the cleanup deletes a ref whose task it does not know only once its snapshot is 30 days old, like a salvage ref — otherwise a Debug build, whose home knows none of the installed app's tasks, would wipe its live checkpoints. The log of a task's checkpoints is `<home>/tasks/<id>.checkpoints.json`. | `Sources/ScopeTasks/TaskCheckpoints.swift` (`orphanRefs`), `Sources/ScopeTasks/TaskManager.swift` (`collectGarbage`) | `TaskCheckpointTests.theOldestGoAtFiftyAtArchiveAtCloseAndWhenNoRecordNamesThem` |
| 1c | What a build passes on | **no** | yes | An app started from a thread held that thread's `SCOPE_*` and its `GIT_CONFIG_*` hooks override, and built its own threads on them: one outside a task kept the other app's `SCOPE_TASK`, `SCOPE_TASK_ROOT`, `SCOPE_PORT` and ran its git hooks. The app now drops both from its process once the home is resolved, and `TerminalEnvironment.build` strips every Scope-injected key from its base. | `App/Scope/Environment/AppEnvironment.swift:161`, `Sources/ScopeDrivers/TerminalEnvironment.swift:71`, `Sources/ScopeTasks/SandboxGitHooks.swift:110` | `TerminalEnvironmentTests.inheritedScopeVariablesAreDropped`, `SandboxGitHooksTests` (`anInheritedThreadLeavesNothingBehind`, `onlyAScopeHooksOverrideIsRemoved`) |
| 2 | Hook socket | **no** | yes | The path derives from the home (`<home>/scope.sock`, or a per-home hash in `$TMPDIR`), so two homes are two sockets. The server no longer unlinks a path somebody answers on: it throws `addressInUse`. The app checks first and refuses to start. | `Sources/ScopeAdapters/SocketPath.swift:23`, `Sources/ScopeAdapters/UnixSocketServer.swift:79`, `App/Scope/Environment/AppEnvironment.swift:99` | `SocketOwnershipTests`, `SocketPathTests`, `AppHomeTests.socketsDiffer` |
| 3 | Control socket / CLI | **no** | yes | One socket carries hooks and control. Order is now `--sock`, `--home`, `SCOPE_SOCK`, `SCOPE_HOME`, `~/.scope`: a flag beats the inherited socket. `scope` and `scope mcp` share `ControlEndpoint.resolve`. `SCOPE_PORT` is a task's dev-server port, not a control port; see 10. | `Sources/ScopeControl/ControlClient.swift:13` | `ScopeCLIParsingTests` (`anExplicitHomeBeatsTheInheritedSocket`, `aThreadTalksToTheAppThatOpenedIt`, `theCLIAndTheMCPServerResolveTheSameEndpoint`, `theDebugHintNamesTheFlag`) |
| 4 | CLI on PATH | **no** | yes | A Debug build installs only under `<home>/bin`, never `/usr/local/bin`, and refuses to repoint a link that still leads to another copy, naming it. Inside a thread nothing is installed: the build's own `Contents/Helpers` is first on `PATH`. | `Sources/ScopeControl/CLIInstaller.swift:55`, `:86` | `CLIInstallerTests` (`aDebugBuildNeverTakesOverTheInstalledLink`, `aDebugBuildReplacesADeadLink`, `aDebugBuildOnlyInstallsUnderItsOwnHome`) |
| 5 | LaunchServices | partly | yes | URL scheme is per configuration (`scope` / `scope-debug`); the Services entry reads "Open in Scope Debug"; folders are `LSHandlerRank: Alternate`, listed under each build's own name. **Hole:** `NSPortName` was `Scope` for both, so the Debug entry could be delivered to the installed app. It is now `$(PRODUCT_NAME)`. | `project.yml:123-135`, `:184-193` | Built `Info.plist` of both configurations read with `plutil -p`; `NSWorkspace.urlForApplication(toOpen:)` returns `/Applications/Scope.app` for `scope://` |
| 6 | Menu bar extra, global shortcuts | yes | **shared** | Both builds may show an icon (a preference, in each home's `config.json`). Each registers its two chords (⌥Space, ⌥⇧Space by default) with `RegisterEventHotKey`; Carbon accepts the same chord from two processes without a word and delivers the press to the one that registered last, so a Debug build started beside the installed app takes ⌥Space until it quits. Neither can detect it (`eventHotKeyExistsErr` is only raised within one process). Change a build's chords in its Settings › General › Anywhere when running both. No `addGlobalMonitorForEvents`; every other monitor is local to the app's own windows. | `App/Scope/Hotkeys/GlobalHotkeys.swift`, `App/Scope/Terminal/TerminalKeyBindings.swift:28` | A script registering ⌥Space beside the running app got `noErr` (2026-10-16) |
| 7 | Notifications | yes | yes | `UNUserNotificationCenter.current()` is keyed by bundle id: categories, actions and delivered notifications belong to the build that posted them, and macOS routes a click to that bundle id. No shared or distributed notification is used. | `App/Scope/Support/ThreadNotifier.swift:19` | Grep; see 11 for two Debug builds |
| 8 | Sparkle | **no** | yes | The updater was disabled at runtime only. Under `DEBUG` there is now no `import Sparkle` and no controller, only a stub; `SUFeedURL` is empty in the Debug `Info.plist`. | `App/Scope/Updates/UpdaterController.swift:8`, `project.yml:140`, `:190` | `nm -u` on the Debug binaries: no `SPU*` symbol. `plutil -p`: `SUFeedURL => ""` |
| 9 | UserDefaults | yes | yes | Only `UserDefaults.standard`, which is per bundle id. No `suiteName`, no `@AppStorage` with a store, no app group. | `App/Scope/Model/AppModel+Search.swift:60` | Grep; nothing to test |
| 10 | Sandboxes, worktrees, ports | partly | yes | Sandboxes are always `<home>/sandboxes/<scope>` and records hold paths under their own home. **Hole:** `SCOPE_PORT` blocks came from one range in both builds, so each gave its first task 41000. A Debug build now allocates from 31000..<39000. | `Sources/ScopeTasks/TaskManager.swift:68`, `Sources/ScopeTasks/TaskSetup.swift:127` | `SandboxSetupTests.portsComeInBlocksOfTenAndSkipTheTakenOnes`, `ScopeHomeTests.everythingFollowsTheHome` |
| 11 | Several Debug builds | **no** | loud | They are one app to macOS and share `~/.scope-debug`. The second to start on a served home refuses, with an alert naming the home, its own bundle path and pid. `make run` fails if another copy is running, listing pids. See below. | `App/Scope/Environment/AppEnvironment.swift:172`, `Makefile:26` | `SocketOwnershipTests.aLiveSocketIsNeverTakenOver`; refusal checked by launching two |
| 12 | Spotlight / Dock / switcher | partly | yes | Bundle name, display name and executable are all `Scope Debug`. **Hole:** the main window's title, and the app name in `scope ping`, said `Scope`. Both use the build's display name. | `App/Scope/Support/BuildFlavor.swift:16`, `App/Scope/ScopeApp.swift:19`, `App/Scope/Model/AppControlService.swift:50` | `plutil -p`; `scope ping --home ~/.scope-debug` answers `Scope Debug 0.0.0` |

| 13 | Shared logs and links | yes | yes | Both builds tail Vibe Island's one log; a jump is matched on the driver's session id or pid against the app's *own* threads, so only the build that owns the session reacts. The app parses `scope://` and `scope-debug://` but never writes either: LaunchServices decides who receives a link (5). | `Sources/ScopeAdapters/VibeIslandJumps.swift:42`, `Sources/ScopeCore/Models/ThreadLink.swift:13` | `VibeIslandJumpsTests`, `ThreadLinkTests` (existing) |
| 14 | Release clones | n/a | yes | `scope release` clones a repository's default branch into `<home>/releases/<owner-repo>/` and runs the release script there, so two homes never share a clone and no sandbox hook reaches it. The clone is reused (fetched and reset) by the next release from the same home. | `Sources/ScopeCore/ScopeHome.swift` (`releasesURL`), `Sources/ScopeControl/ReleaseRunner.swift` | `ScopeHomeTests.everythingFollowsTheHome`, `ReleaseRunnerTests` (the checkout is under the home it is given) |
| 15 | Browser data stores | n/a | yes | The Browser pane's cookies and storage live where WebKit puts them, `~/Library/WebKit/<bundle id>/WebsiteDataStore/<uuid>/`, outside every home: the bundle id keeps Debug and Release apart, but two Debug homes share that folder. So a store's identifier is a UUID v5 of the home *and* the scope (`BrowserStoreID.user`); two homes never open the same one. Agent stores (per task) take the home and the task the same way (`BrowserStoreID.agent`) and are removed when the task is archived, once its view is gone; their screenshots live in `<home>/browser/shots/<task>/` and go with them, their downloads in `<home>/browser/downloads/<task>/`. The compiled content rule lists that hold agents to their sites sit in WebKit's per-bundle-id store under a name that is a hash of the rules themselves, so two homes with the same rules share a list that is the same either way. | `Sources/ScopeCore/BrowserRoute.swift` (`BrowserStoreID`), `App/Scope/Browser/BrowserSession.swift` | `BrowserRouteTests.storesAreStablePerHomeAndApartPerScopeHomeAndRole` |

Also separated, and found that way: the MCP server entry (`scope` / `scope-debug`) and the agent skill
(`scope` / `scope-debug`, formerly `scope-tasks` / `scope-debug-tasks`) are named per build (`MCPRegistration.swift:53`, `SkillInstaller.swift:43`),
and so is its companion `/scope-summary` (`scope-summary` / `scope-debug-summary`, `SkillInstaller.summaryName`); the history of
closed tasks and threads that `scope summary` reads is `<home>/history.jsonl` (`ActivityHistory.url(home:)`);
the timeline a task keeps of its closed threads and its checks is `<home>/tasks/<id>.timeline.json` (`TaskTimelineStore`);
the usage log that `scope usage` reads is `<home>/usage/` (`UsageLog(home:)`), so a Debug build counts its own clicks;
driver hook settings are written per thread under `<home>/threads/`; git hooks live in `<home>/githooks` and
reach git through the thread's environment, not through a repository's config.

## The home, in one table

`AppHome.resolve(environment:debugBuild:)`, as covered row by row in `AppHomeTests`:

| Build | `SCOPE_HOME` | Result |
|---|---|---|
| Debug | absent | `~/.scope-debug` |
| Debug | inherited from a thread (`SCOPE_THREAD` set, `SCOPE_SOCK` is that home's socket or absent) | `~/.scope-debug`, with a note naming the home it ignored |
| Debug | set on purpose from a plain terminal | obeyed |
| Debug | set on purpose from inside a thread (`open --env SCOPE_HOME=…`: `SCOPE_SOCK` no longer matches) | obeyed |
| Debug | `~/.scope`, by any spelling, however it arrived | **refused**: `~/.scope-debug`, with an error naming the home |
| Release | absent | `~/.scope` |
| Release | inherited or deliberate | obeyed |

`ScopeHome.url` is unchanged: the CLI and `scope-hook` rely on inheriting `SCOPE_HOME` and `SCOPE_SOCK` from
the thread they run in. The rules above apply to an app's own startup only.

The refusal happens before a directory is created or a socket bound, and is reported through
`AppEnvironment.startupProblems`.

## Several Debug builds at once

Every worktree builds the same `dev.maastrich.scope.debug`, and each of them defaults to `~/.scope-debug`.

Not safe, and now refused:

- **Two of them on one home.** The second to start finds the socket answered and quits after an alert. Before,
  it unlinked the socket and took the first one's hook events and control requests.

Not safe, and only documented:

- **Quitting by bundle id or by name** (`osascript -e 'quit app id …'`, `killall`, `pkill -f`). macOS picks one
  of the running copies; `pkill -f` also matches the installed app. Quit by pid: `make run` lists the
  running copies, and the refusal alert gives its own.
- **`open` without `-n`.** With another worktree's copy running, it brings that one to the front and starts
  nothing. `make run` checks for this and fails with the list.
- **`scope-debug://` links and "Open in Scope Debug".** LaunchServices delivers them to whichever Debug build
  it registered last — usually the one built most recently, not necessarily the one running.
- **Notifications, UserDefaults and the MCP/skill entries** are per bundle id or per name, so all Debug builds
  share them. The MCP entry carries `--home`, so it reaches whichever build serves that home.

Safe:

- **One Debug build per home.** `SCOPE_HOME=/some/scratch/home` from a plain terminal, or
  `open -n --env SCOPE_HOME=…` from a thread, gives a build its own config, records, sandboxes, socket, UI state
  and port bookkeeping.

A per-worktree discriminator is cheap for the home and not for the identity. `make run` could export
`SCOPE_HOME=~/.scope-debug-<hash of the worktree path>` so parallel builds never meet — at the price of an
empty home, and the onboarding, in every new worktree. The bundle id cannot vary per worktree without changing
notification permissions, the URL scheme and the Services entry on every checkout. Not done; the refusal makes
the collision impossible to miss instead.

## Known limits

- **The same scope in both builds.** Each keeps its own sandboxes, but they create worktrees and branches in
  the same base repositories. Git refuses to check out a branch a worktree already holds, so a clash is an
  error, not corruption.
- **`SandboxLocation.insideScope`** (`<scope>/.scope/sandboxes`) is declared and decoded but nothing honours
  it. If it is ever implemented, that path is shared by both builds and needs a per-build name.
- **An MCP entry always reaches its own build's home.** `scope mcp --home ~/.scope` used to follow
  `SCOPE_SOCK`, so the `scope` tools of an agent running in a Debug or throwaway thread drove that thread's
  app. They now reach the installed app, which does not know the thread and denies the call. Use the
  `scope` command line inside such a thread (it follows `SCOPE_SOCK`), or the `scope-debug` entry.
- **`SCOPE_THREAD` across builds.** `scope --home ~/.scope-debug …` from a thread of the installed app reaches
  the Debug build carrying a thread id it does not know, and is denied. That is the policy working; unset
  `SCOPE_THREAD` to ask as yourself.
- **Sparkle.framework is still embedded and linked** in a Debug build, because the package dependency is per
  target. Nothing in the Debug binary references it.
- **A Release build left in DerivedData** (`make build CONFIG=Release`) is a second `dev.maastrich.scope` that
  LaunchServices may hand `scope://` links to. Delete it, or `lsregister -u` it, when done.
- **The log subsystem** is `dev.scope.app` for both; filter on the process name.

## Checking it by hand

From a thread of the installed app:

```sh
make run                                   # strips SCOPE_*, refuses if another copy is running
pid=$(pgrep -x "Scope Debug")
lsof -a -U -p "$pid" | grep scope.sock     # ~/.scope-debug/scope.sock, nothing else
scope ping                                 # Scope <version>, home ~/.scope
scope ping --home ~/.scope-debug           # Scope Debug 0.0.0, home ~/.scope-debug
stat -f %i ~/.scope/scope.sock             # same inode as before the launch
kill "$pid"                                # by pid
```

# Scope

Scope is a native macOS workspace for running coding agents (Claude Code, Codex, Cursor, or a plain shell) against your repositories.
Declare any folder as a *scope* — a cloned GitHub org, a folder of projects, a single repo — and open *threads* (PTY terminals) in it, each with `SCOPE_*` variables injected so hooks can report their state back.
Scope reads your folders and writes nothing inside them.

**Status: M0 skeleton.** Scopes, repo discovery, threads with live terminals, launch/relaunch/stop/close, persisted records, problem reporting. Tasks (sandboxes), the inspector panels and adapters arrive in M1–M4 (see `SPEC.md`).

## Requirements

- macOS 15+
- Xcode 26+ (Swift 6, strict concurrency)
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- One-time Metal toolchain download (SwiftTerm ships a Metal shader): `xcodebuild -downloadComponent MetalToolchain`

## Build

```sh
make generate            # Scope.xcodeproj from project.yml
make build               # Debug .app in DerivedData (CONFIG=Release for release)
make run                 # build + open the app
make test-one FILE=SlugTests   # one Swift Testing suite of ScopeKit
swift build              # the ScopeKit package alone (no SwiftTerm, no AppKit)
```

The app is ad-hoc signed and not sandboxed (it forks PTYs and runs arbitrary binaries).

## Layout on disk

```
~/.scope/                 # SCOPE_HOME (override with `launchctl setenv SCOPE_HOME …` for GUI launches)
├── config.json           # declared scopes + preferences
├── drivers/*.json        # driver profiles (bundled ones copied here on first run, never overwritten)
├── threads/<id>.json     # one record per thread: driver, cwd, launches, last exit
├── graph/                # M3
├── sandboxes/            # M2
└── scope.sock            # unix socket for scope-hook events
~/Library/Application Support/Scope/ui-state.json   # selection, expansion, inspector
```

## Drivers

A driver is a JSON file in `~/.scope/drivers/`, named `<id>.json`:

```json
{
  "id": "claude-code",
  "name": "Claude Code",
  "command": "claude",
  "args": [],
  "env": {},
  "resume": ["claude", "--resume", "{resume_id}"],
  "icon": "sparkles"
}
```

`command` is resolved on your login-shell PATH (Scope probes `$SHELL -ilc` once at launch; change the mode in Settings). Placeholders: `{thread_id}`, `{resume_id}`, `{cwd}`, `{scope}`, `{task}`, `{home}`. Every thread receives `SCOPE_THREAD`, `SCOPE_SCOPE`, `SCOPE_SCOPE_ROOT`, `SCOPE_SOCK`, `SCOPE_HOME`. Settings › Drivers › Reload picks up edits.

## Contributing

`Sources/` is the Foundation-only `ScopeKit` package (models, stores, git, drivers, adapters) and is unit-tested with Swift Testing; `App/Scope/` is the SwiftUI + AppKit + SwiftTerm app and is not. Keep `swift build` and the targeted test suites green; run one suite at a time (`make test-one FILE=…`).

## License

MIT — see `LICENSE`.

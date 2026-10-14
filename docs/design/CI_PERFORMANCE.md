# CI performance

Why the merge CI (`.github/workflows/ci.yml`) and the release workflow (`.github/workflows/release.yml`) take
seven minutes each, and what to do about it. Measured on 2026-10-14 against the 60 most recent CI runs and
the 27 most recent release runs.

**In one paragraph.** Nothing is waiting: runners start in 8 s. A run is as long as its app job, and 79 % of
the app job is one `xcodebuild` step that compiles every module **twice** (arm64 and x86_64) with the
optimiser on, from scratch. Another 53 s of that job resolves the package graph two more times than needed.
The fixes that needed no decision are applied on this branch and should take a pull request from about
7.2 min to about 3 min; the rest is a ranked list below.

## Measured baseline

Step durations from the Actions API (`/actions/runs/<id>/jobs`), successful runs only. Seconds.

### CI — 45 successful runs

| Job | Step | Mean | Median | Min | Max |
|---|---|---:|---:|---:|---:|
| **Run** | wall clock, created → completed | **433** | 413 | 330 | 729 |
| **Scope.app (xcodebuild)** | whole job | **403** | 394 | 321 | 530 |
| | Toolchain (`brew install xcodegen`, Metal toolchain) | 10 | 10 | 6 | 13 |
| | Cache SwiftPM clones (restore) | 7 | 6 | 1 | 9 |
| | Generate Scope.xcodeproj | 0 | 0 | 0 | 1 |
| | Resolve packages | 26 | 25 | 16 | 58 |
| | **Build (Release, ad-hoc signed)** | **319** | 312 | 240 | 423 |
| | Verify the built app | 1 | 1 | 0 | 1 |
| | App tests (decides there is no test target) | 28 | 29 | 15 | 37 |
| | checkout, set-up, post steps | 10 | | | |
| **ScopeKit (swift test)** | whole job | **168** | 166 | 105 | 248 |
| | Toolchain | 4 | 4 | 3 | 8 |
| | Cache SwiftPM build directory (restore) | 7 | 6 | 0 | 11 |
| | Build | 41 | 41 | 24 | 77 |
| | Test (Swift Testing) | 105 | 102 | 60 | 162 |
| | checkout, set-up, post steps | 8 | | | |

The two jobs run in parallel, so the run lasts as long as the app job. The 729 s outlier (12.2 min) is run
38474818362, a re-run (attempt 2): its wall clock counts from the first attempt.

### Release — 25 successful runs

| Job | Step | Mean | Median | Min | Max |
|---|---|---:|---:|---:|---:|
| **Run** | wall clock | **398** | 407 | 223 | 580 |
| Draft release (ubuntu) | whole job | 7 | 6 | 4 | 15 |
| **Build, package, publish** | whole job | **379** | 387 | 207 | 560 |
| | Toolchain (`brew install xcodegen create-dmg`, Metal) | 10 | 10 | 6 | 16 |
| | Cache SwiftPM clones (restore) | 5 | 5 | 1 | 11 |
| | Sparkle tools | 2 | 2 | 1 | 3 |
| | **`scripts/package.sh`** | **341** | 349 | 184 | 507 |
| | appcast, upload, publish, artifact, summary | 11 | | | |

Inside `scripts/package.sh`, from the timestamps of three runs:

| Phase | v0.11.0 (ad-hoc, cache miss) | v0.13.0 | v0.14.0 |
|---|---:|---:|---:|
| Keychain and certificate | – | 4 | 4 |
| `xcodebuild archive`, before the first compile (start-up, package resolution) | 74 | 26 | 64 |
| `xcodebuild archive`, compile and link (universal, optimised) | 390 | 187 | 323 |
| `-exportArchive` (fails on the self-signed certificate, falls back to a manual re-sign) | – | 5 | 6 |
| DMG (`create-dmg`, Finder AppleScript, `hdiutil verify`) | 42 | 41 | 45 |
| Notarization | 0 | 0 | 0 |
| Exit trap (keychain and trust clean-up) | 0 | 33 | 34 |

### Queue time

`created_at` → `started_at` over all 146 macOS jobs of those runs: **median 8 s, p95 11 s, max 21 s**.
Queueing is not part of the problem; a different runner label would buy nothing here.

## Where the time goes

### 1. The app build compiles everything twice, optimised, from nothing (319 s)

- **Two architectures.** `Release` defaults to `ONLY_ACTIVE_ARCH=NO` and `project.yml` does not override it,
  so the merge CI builds a universal binary: the log has `Create Universal Binary` for all 17 products and
  both `arm64-apple-macos` and `x86_64-apple-macos` modules.
- **Whole-module optimisation.** One compiler task per module, so the long modules (SwiftTerm, the app
  itself) form a serial chain no core count shortens.
- **No reuse.** Only the package clones (`SourcePackages`, 184 MB) are cached. `DerivedData` is not.

The Actions log cannot split the 319 s further: `xcbeautify` buffers its output, so the lines arrive in three
bursts and per-target timestamps mean nothing. The split below comes from cold local builds of this branch
(`-showBuildTimingSummary`, Xcode 26.6, an M-series laptop). Absolute seconds do not transfer to a runner —
compare the columns. `-jobs 3` approximates the runner's three cores.

| Variant | Compile task-seconds | Wall, 10 jobs | Wall, `-jobs 3` |
|---|---:|---:|---:|
| Release, universal — **what CI and the release run today** | 376 | 119 | 155 |
| Release, arm64 only | 157 | 105 | 117 |
| Release, arm64, `-Onone`, per-file compile — **pull requests on this branch** | 147 | 34 | 64 |
| Debug, arm64 | 148 | 33 | – |
| Release, arm64, no dSYM | 151 | 97 | – |

- The second architecture is 58 % of the compile work (376 → 157 task-seconds).
- **Dependencies vs first-party** (Release, arm64): after touching every first-party `.swift` file, the
  rebuild costs 75 of 157 task-seconds. So about **48 % is first-party** (the app target and the seven
  ScopeKit modules) and **52 % is dependencies** (SwiftTerm, swift-nio, the MCP SDK, swift-collections,
  swift-system, swift-log). Sparkle is a prebuilt xcframework and costs nothing.
- Dropping the optimiser does not reduce the work, it makes it parallel: 123 per-file tasks instead of 16
  whole-module ones. That is why the wall clock falls by 45 % at three jobs even though task-seconds barely
  move.
- The dSYM is worth 8 %.

### 2. The package graph is resolved three times per app job (about 70 s)

1. `Resolve packages` — 26 s, 20 s of it inside `Resolve Package Graph` even on a cache hit, because the
   dependencies float (below) and every resolution asks the remotes.
2. `xcodebuild build` resolves again before compiling: 17 s between its first line and the resolved list.
3. `App tests` runs `xcodebuild -list` to find out whether a test target exists. That resolves a third time:
   26 s to print *No \*Tests target*.

Steps 1 and 3 buy nothing.

### 3. The dependencies float

`.gitignore` excludes `Package.resolved` and `project.yml` pins only SwiftTerm and Sparkle; the MCP SDK is
`from: 0.9.0`. Between the CI run of 00:20 UTC and a local resolve two hours later, swift-collections moved
from 1.7.2 to 1.7.3. Consequences:

- Every run must reach the network to resolve.
- `hashFiles('**/Package.resolved')` in both cache keys hashes nothing, since the file does not exist at
  checkout. The keys only change when `Package.swift` or `project.yml` do.

### 4. The caches hit, and help less than they look

| Cache | Size | Hit rate | What it saves |
|---|---:|---|---|
| `spm-xcode-…` (`SourcePackages`) | 184 MB | hits on the primary key in every run inspected; one miss on the release right after `project.yml` changed | The clones. A miss cost the v0.11.0 release about 45 s. Worth its 7 s. |
| `spm-build-…` (`.build`) | 198 MB | hits on the primary key in every run inspected | The dependency build only. |

The `.build` cache is a **frozen snapshot**. `actions/cache` does not save on a primary-key hit, and the key
never changes, so the run restores whatever `.build` looked like the day `Package.swift` last changed. All
143 first-party compile tasks still run each time (a fresh checkout has fresh mtimes), which is fine — but
the day a floating dependency resolves to a new version, that dependency recompiles on every run and the
result is never saved. Today the snapshot still matches (no swift-nio or MCP compile lines in the log), so it
is a net win of unknown remaining lifetime.

### 5. The test step is not waiting, it is starved (105 s)

Split of the `Test` step, four runs: 7–16 s planning the package a second time, 32–56 s compiling and linking
the test bundle, then **41–56 s running 697 tests**.

- The per-test durations sum to 3 490 s for 50 s of wall clock: Swift Testing starts everything at once, on
  three cores.
- 679 of 697 tests report more than a second. Suites that take under a second alone locally take five here
  (`DebouncerSmoke` 0.9 s → 5.3 s). The reported time is mostly time spent runnable, not running.
- No sleep explains it: the longest `Task.sleep` in `Tests/` is 400 ms, there are 18 in total, and
  `Subprocess` waits on `terminationHandler`, not on a blocked thread.
- The cost is `git`. The slowest thirteen suites all build repositories with `git init` and commits, and the
  eight `.serialized` ones set the floor: `TaskManagerTests` (11 tests) takes 12.7 s alone locally and 50.1 s
  on the runner, where it is the last suite to finish in the run inspected.

`--parallel` does nothing here: it is an XCTest option, and Swift Testing is parallel in-process already.

### 6. A release pays for the same build three times

`scripts/release.sh` pushes the `chore(release)` commit and its tag together. That starts:

- a CI run on the commit — a universal Release build of a tree that differs from its parent by
  `CHANGELOG.md` only;
- the release workflow on the tag — the same universal Release build, archived;
- and it **cancels** the CI run of the commit before it, through `concurrency: cancel-in-progress`.

## Cancelled runs

13 of the last 60 CI runs are `cancelled`. Every one inspected carries the annotation *Canceling since a
higher priority waiting request for ci-refs/… exists*: that is `cancel-in-progress`, not a failure.

- 3 are pull requests superseded by a new push. Intended.
- 10 are pushes to `main`, and **9 of those were cancelled by the `chore(release)` commit that followed
  within minutes**. Run 38476302054 (`fix(delta): keep the image diff's mode names whole`) is one of them:
  cancelled by v0.13.0 while the app was still compiling, not broken. Its ScopeKit job had already passed.
- It hides nothing today: the release commit's own run builds the same sources and went green each time.
  It would hide something the day the release commit stops running CI — see proposal 1.

The two genuine failures in the window (38295236980, 34599398287) are ScopeKit test failures, reported as
`failure`. The *missing creator for mutated node* annotation on some runs is an Xcode warning about
SwiftTerm's resource bundle that every green run has too.

The 53-minute release run (38258226783, v0.12.0) was `security add-trusted-cert` waiting for a SecurityAgent
prompt nobody could answer: the log stops at *Importing the Developer ID certificate* and resumes 3 139 s
later with *The operation was canceled*. `scripts/package.sh` now caps that call (issue #18). It lasted that
long because the job allows 90 minutes.

## Fixes, ranked

Savings are per run, on the runner, estimated from the baseline and the local ratios unless marked measured.

| # | Fix | Saves | Risk | Status |
|---|---|---|---|---|
| A | Pull requests build Release for arm64 only, `-Onone`, per-file | ~190 s of the 319 s build | Low — see *Coverage* | **Applied** |
| B | Drop the `Resolve packages` step | 5–25 s: part of the resolution moves into the build | None: the build resolves anyway | **Applied** |
| C | Decide "is there a test target" from `project.yml` | ~28 s (measured step) | None | **Applied** |
| D | One `swift build --build-tests`, then `swift test --skip-build` | ~10 s, off the critical path | None | **Applied** |
| 1 | Do not run CI on the release commit | one whole macOS run (~7 min of runner) per release; ends the cancellations on `main` | Low | Proposed |
| 2 | Commit `Package.resolved`, resolve offline | ~20 s per job (what B cannot remove), and reproducible builds | Low | Proposed (outside the workflows) |
| 3 | Remove the 30 s trust clean-up wait from `package.sh` | ~33 s per release (measured) | Low | Proposed (outside the workflows) |
| 4 | Cache `DerivedData` for the pull-request build | at most ~55 % of that build, minus ~15 s of restore and save | Medium | Measure A first |
| 5 | Give the git-backed tests a shared fixture | part of the 50 s test run | Low, some work | After A–C land |
| 6 | Make the `.build` cache refresh itself | 0 today; prevents a silent regression | Low | Proposed with 2 |

### Applied on this branch (`ci.yml`)

**A. A fast build for pull requests.** Still `-configuration Release`, with
`ONLY_ACTIVE_ARCH=YES SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=incremental
ENABLE_DEBUG_DYLIB=NO` and `-destination 'platform=macOS,arch=arm64'`. A push to `main` keeps the build it
had — universal, optimised, the one `release.yml` archives.

- Local ratio at three jobs: 64 s against 155 s, so about 130 s on the runner instead of 319 s.
- `ENABLE_DEBUG_DYLIB=NO` matters: without it `-Onone` splits the executable into `Scope` +
  `Scope.debug.dylib`, and the bundle would no longer have the shipped layout.
- Why not `-configuration Debug`: it costs the same (33 s against 34 s) but builds a different app —
  `Scope Debug.app`, `dev.maastrich.scope.debug`, no update feed, `#if DEBUG` branches in, Sparkle updater
  out. The `Verify the built app` step and its Sparkle key check would be checking something nobody ships.

*Coverage given up on pull requests:* the x86_64 slice (anything architecture-specific), and what only the
optimiser sees — an optimiser crash, a whole-module-only diagnostic. Both are rare and both are still built
on the push to `main` and again at tag time. Unchanged: every source file is type-checked in the Release
configuration, the app is linked, signed and verified.

**B. No separate resolve step.** `xcodebuild build` resolves the graph itself. How much of the 26 s comes
back is the one number here that only a run can settle: the build spent 17 s re-resolving *after* that
step, and the release's `archive`, which has no such step, spent 26 s (v0.13.0) and 64 s (v0.14.0) before
its first compile. Locally the same resolution takes 3–4 s, so the cost is the runner's network. Counted as
5 s saved at worst, 25 s at best; proposal 2 is what removes the lookup itself.

**C. `project.yml` instead of `xcodebuild -list`.** The step now greps for a `bundle.unit-test` or
`bundle.ui-testing` target. It still runs `xcodebuild test` the day one exists.

**D. One package build.** `swift build --build-tests` builds the libraries, both executables and the test
bundle with one plan; `swift test --skip-build` only runs. Same coverage.

Also added: `-showBuildTimingSummary`, printed after the build, because `xcbeautify` swallows it and it is
the only per-task timing a run leaves behind.

*Checked locally:* `actionlint` on `ci.yml`; the exact pull-request `xcodebuild` line builds, and the
`Verify` commands pass on its product (`codesign --verify --deep --strict`, bundle id `dev.maastrich.scope`,
both helpers embedded, Sparkle key valid); `swift build --build-tests` then
`swift test --skip-build --parallel --filter SlugTests` pass and both executables are built.
*Not checked:* a run on GitHub. The pull request for this branch is that check — expect
`Build (Release, ad-hoc signed)` between 130 and 150 s and the app job between 160 and 180 s, then confirm
the push build is unchanged on the merge.

**Expected result.** Pull request: app job 403 s → 160–180 s, ScopeKit job 168 s → ~158 s, run **7.2 min →
about 3 min**. Push to `main`: app job 403 s → 350–370 s, run **7.2 min → about 6 min**.

### Proposed, not applied

**1. Do not run CI on the release commit.** `release.sh` commits `CHANGELOG.md` and nothing else, so:

```yaml
on:
  pull_request:
  push:
    branches: [main]
    paths-ignore: [CHANGELOG.md]
```

It has to be `paths-ignore` on the trigger. A job-level `if:` still creates a run, which still joins the
`ci-refs/heads/main` group and still cancels the feature commit's run — leaving that tree with no finished
build at all. With no run created, the feature commit's run completes and is the check on the tree being
tagged. Never put `paths-ignore` on `pull_request`: a required check that never reports blocks the merge.

Not applied because it changes what a green tick on `main` means: the tagged commit itself carries no CI
status, only its parent does.

**2. Commit `Package.resolved`.** Remove it from `.gitignore`, commit the package's, and have the workflow
copy a committed app-level one into `Scope.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` after
`xcodegen`. Then `-onlyUsePackageVersionsFromResolvedFile` and `swift build
--only-use-versions-from-resolved-file` stop the remote lookups, the cache keys start meaning something, and
a dependency update becomes a reviewed diff instead of something CI picks up silently between two runs. The
comment in `project.yml` that pins Sparkle exactly, *because* no `Package.resolved` is committed, could go.

**3. The 33 s after the DMG is done.** Both signed releases inspected spend 33–34 s between `==> Done` and
the next step; the ad-hoc v0.11.0 spends 0.07 s. The only difference in the exit trap is
`run_capped 30 sudo -n security remove-trusted-cert`, which matches a call that runs into its 30 s cap every
time. Hosted runners are discarded after the job, so skipping it under `GITHUB_ACTIONS` loses nothing.
Confirm by timing that line in one release.

**4. Cache `DerivedData`.** It can work: `actions/cache` restores `SourcePackages` with its mtimes, so the
dependency objects stay valid; first-party code rebuilds regardless, because a checkout resets mtimes. The
ceiling is the dependency share — 36 of 64 s locally for the pull-request build, about 55 %. Against it:
600 MB to restore and save (~15 s), a key that must change per run to be saved at all
(`…-${{ github.run_id }}` with a `restore-keys` prefix, saved from `main` only), invalidation on the Xcode
version and on `Package.resolved` — which needs proposal 2 first — and Xcode's incremental builds being less
trustworthy than cold ones. Worth trying only if the pull-request build is still the long pole after A.

**5. The test run.** After A–C the two jobs are about level, so this starts to count.
- Build each git fixture once and copy it, instead of `git init` + commits per test. `TaskManagerTests`
  spends 1.15 s per test alone, nearly all of it spawning `git`.
- Check which of the eight `.serialized` suites need it. Each test already works in its own temporary
  directory; a serialized suite is a guaranteed serial chain.
- Drop `--parallel` from the command line; it documents something that is not happening.

**6. The `.build` cache.** With proposal 2 the existing key becomes correct. Without it, the alternative is
`actions/cache/restore` + `actions/cache/save` with a per-run key, saved on `main` only.

### Recommended plan, cheapest first

1. Merge this branch (A–D). Read the first pull-request run: build step, app job, the timing summary.
2. Proposal 1 — one line, removes a macOS run per release and the cancelled runs on `main`.
3. Proposal 3 — one condition in `package.sh`, 33 s per release.
4. Proposal 2 — a `.gitignore` line, two committed files, three flags. Unlocks 6 and makes 4 possible.
5. Proposal 5 if the ScopeKit job is now the longer one.
6. Proposal 4 only if a pull request is still over three minutes.

The release workflow stays near six minutes after all of this: it is one universal optimised archive (about
five minutes) and a DMG (45 s), and both are the product.

## Ruled out

- **A different or self-hosted runner.** Queue time is 8 s. `macos-26` is free for a public repository;
  larger macOS runners are billed, and a self-hosted runner on a public repository runs pull-request code on
  the maintainer's machine.
- **`-downloadComponent MetalToolchain`.** Needed: SwiftTerm compiles a Metal shader (`CompileMetalFile` and
  `MetalLink` are in the timing summary) and Xcode 26 does not bundle the compiler. Costs 2.5 s.
- **`brew install xcodegen`.** 3 s with `HOMEBREW_NO_AUTO_UPDATE`. A pinned binary download would save a
  second; committing the generated project would trade it for merge conflicts in a generated file.
- **Notarization.** It does not run: `SKIP_NOTARIZE=1`, because the certificate is self-signed. Zero seconds
  today. With a Developer ID it becomes two Apple-side waits (app, then DMG), each capped at 30 minutes.
- **Reusing the CI build in the release.** The CI app is stamped `0.0.0 (0)`, ad-hoc signed, and on pull
  requests arm64-only and unoptimised. The release needs `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`
  (which Sparkle compares), the signing identity and both architectures. Re-stamping and re-signing a CI
  artifact would ship a binary that no workflow built as released.
- **`DerivedData` caching in the release.** A shipped artifact should come from a cold build.
- **An arm64-only release.** Halves the archive, drops Intel Macs. A product decision, not a CI one.
- **Debug for merge CI.** Same speed as A, different app.
- **Dropping the dSYM in CI.** 8 %, and it keeps a crash from a CI-built app symbolicated.
- **Lowering the release job's 90-minute timeout.** It bounded the v0.12.0 hang at 53 minutes rather than
  causing it, the hang is fixed, and a notarized release can legitimately wait an hour.

## Reproducing the numbers

```sh
# step durations of one run
gh api repos/maastrich/scope/actions/runs/<id>/jobs \
  --jq '.jobs[] | .name, (.steps[] | "  \(.name): \(.started_at) -> \(.completed_at)")'

# why a run was cancelled
gh api repos/maastrich/scope/check-runs/<job id>/annotations --jq '.[].message'

# cache behaviour and the slowest suites of one run
gh run view <id> --log | grep -E "Cache (restored from key|hit occurred|not found|saved)"
gh run view <id> --log | grep -E "Suite .* passed after" | sort -t' ' -k6 -n | tail -15

# cold build with the timing summary; touch App/ and Sources/ and rebuild for the first-party share
xcodebuild build -project Scope.xcodeproj -scheme Scope -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd -jobs 3 -showBuildTimingSummary \
  -skipPackagePluginValidation -skipMacroValidation ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=
```

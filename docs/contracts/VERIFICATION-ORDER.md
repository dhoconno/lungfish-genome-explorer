# Verification order

This contract sets the order in which a Lungfish Genome Explorer (LGE) session verifies its work, and says which evidence carries forward to later commits. Its purpose is that no session runs the same check twice on the same code.

The owner set it on 2026-10-07. Preview 2026.10.10 ran the 25-minute unit tier three times on one commit, and a small fix took about an hour to release. Most of that hour went to checks that had already passed on unchanged code.

## Evidence and what it covers

| Evidence | Command | Covers |
|---|---|---|
| Targeted tests | `swift test --skip-update --filter <Target or Class>` or `bash scripts/test-surface.sh <name>` | The change under test. Targeted tests never authorize a push or a release. |
| Unit tier | `bash scripts/full-suite-gate.sh --tier unit --quiet` | The exact commit it ran on, and every descendant whose changes all fall under the release-neutral paths |
| Full tier | `bash scripts/full-suite-gate.sh --tier full` | The exact commit, and the descendants the row "Stable keeps the full tier" names |
| Replay suites | `bash scripts/full-suite-gate.sh --filter ReplayTests --quiet` | The exact commit. Run them again only after a change to a recorded command, a CLI command or a replayed tool. |
| Golden outputs | `python3 scripts/golden/golden.py compare` on a Mac with the golden environment, or the `Golden` workflow on the golden runner (`docs/contracts/MACHINES.md`) | The same as the replay suites. The runner's result counts the same as a local run. |
| GUI walk | A person walks the packaged candidate from `release.py package preview` over every screen and analysis it changed, on a corpus that holds a renamed project, a copied project, a large reference and records from an older release, and compares each number on screen with the `lungfish-cli` output and the tool's own report. A walk by computer use counts while the owner is at the Mac with the screen unlocked. A lane may check its own work on the Debug app from `python3 scripts/release/release.py debug`, which never counts for a release | The build it walked. Walk again only the surfaces that changed after it. |
| XCUI smoke | The `ui` profile on the packaged candidate, in a session that does not lock | The exact build. A run with a skipped XCUI or Accessibility test covers nothing. Once backlog row MAIN-THREAD-BLOCK lands, app code that blocks the main thread for more than two seconds fails the smoke. The profile runs `scripts/release/app_smoke_gate.py` over `gates.appSmokeTests` as the console user in an unlocked session, with a fresh launch home for each test. Once a project opens, the candidate writes its preferences into the account's `~/Library/Preferences`, and the gate reports that change and fails the run. Until backlog row SMOKE-ISOLATION lands, the smoke is a diagnostic and not a release gate. |
| Release candidate | `python3 scripts/release/release.py package preview` | The exact commit. `publish` signs those bytes without rebuilding. |

Unit-tier evidence lives under `.build/gate-logs` in the checkout that ran it, and every worktree of the repository sees it, because it is bound to a clean commit and not to a folder. A unit-tier run in a program worktree therefore covers the same commit in the primary checkout. To ask whether evidence covers a commit, run this.

```bash
python3 scripts/release/gate_evidence.py unit-evidence --root . --commit HEAD
```

It prints `exact`, `inherited` (with the commit that was tested), `red` (the run that decides this code failed) or `none`. The newest canonical run on a commit decides that commit, and without one the nearest ancestor with a run whose changes since are all release-neutral decides. It exits 0 only when evidence covers every commit named, and 3 when any of them already failed. The pre-push hook then refuses the push rather than running the unit tier again on that code.

## Release-neutral paths

A release-neutral path is documentation that no test reads, so a change there cannot change a test result. `gates.releaseNeutralPaths` in `config/release-contract.json` lists them. The parser accepts only a `docs/` file or a `docs/` folder ending in `/**`.

The list holds release notes, plans, reports, contracts, the architecture docs and the release handoff. To add a path, show in the same change that no Swift test, no unit-tier input and no Python release test reads it, and update this paragraph. The pre-push hook's quick documentation checks still run on every push, so a neutral path is never unchecked.

## Order of a session

| Step | What runs | Evidence |
|---|---|---|
| Plan | Nothing. Keep the plan on disk. | None |
| Lanes | Targeted tests for the code each lane touches, in its own worktree. A lane never runs the unit tier. | Targeted only |
| Integration | After a wave of at most three lanes merges, the unit tier runs once on the merged commit. Failures between lanes show up here. | Unit tier |
| Review and fixes | Each fix runs its targeted tests. The unit tier does not run after every round. | Targeted only |
| Final candidate | The unit tier once, then the replay suites and the golden comparison once. A candidate with no change a user can see and no result fix stops here, with no Preview (`docs/contracts/SCOPE-AND-DELIVERY.md`) | Unit tier, replay, golden |
| Release notes | Commit `docs/release-notes/<version>.md`. The newest notes file names the release, so no version bump exists. Notes are release-neutral, so the final candidate's evidence still covers this commit. | Inherited |
| Package | `python3 scripts/release/release.py package preview` reuses evidence that covers HEAD, or runs the unit tier itself while the candidate compiles. | Release candidate |
| Packaged checks | The XCUI smoke, then a person's walk of the changed screens on the packaged app, in a session that does not lock. Each finding gets a severity, and an open S1 or S2 stops the publish. No walk substitute counts. | XCUI smoke, GUI walk |
| Publish | Push `main` (the pre-push hook finds the evidence and skips the unit tier), run `setup`, then `publish`. | Published release |

When a session adds only one small fix, the integration, review and final-candidate rows collapse into the package row. Commit the fix and the notes, run `package`, then push and publish.

## Rules

| Rule | What it means |
|---|---|
| Ask before running the unit tier | Run `gate_evidence.py unit-evidence` first. If it reports `exact` or `inherited`, the unit tier has already run on this code. |
| One unit-tier run at a time on the Mac | The unit tier keeps all 14 cores busy for about 23 minutes. Two runs at once both slow down. |
| Package and the pre-push hook wait for a run already going | When a unit-tier run is going on the commit, or on an ancestor whose changes since are all release-neutral, and its checkout is still at that commit, `package` and the pre-push hook wait for it and inherit its result, green or red. When another `full-suite-gate.sh` run is using this checkout's `.build` folder, they wait for it to end before running their own, because SwiftPM builds one thing at a time per folder. Both waits share one 60-minute budget, and `package` or the push stops with an error when it runs out. |
| Never move a checkout under a running gate | A commit, merge or checkout in a checkout where a gate is running ends that run with "source changed during gate", which decides nothing. For Preview 2026.10.11, `main` was fast-forwarded to the release notes commit while a unit-tier run on the parent was going in the same checkout. That run was wasted, and the second run `package` started waited 25 minutes on the SwiftPM lock. Commit the notes in another worktree, or wait for the run to finish. |
| Push after evidence exists | Push a commit only after unit-tier evidence covers it, so the pre-push hook skips the unit tier. Never push with `--no-verify` to skip a unit tier that has not run. |
| A red unit tier is diagnosed, not retried | Read the failure in the evidence folder, rerun only the failing class to tell a product fault from a test fault, fix the cause in a new commit, and run the unit tier once on that commit. `package` refuses a commit whose newest unit-tier result failed. |
| Timed-out waits | When every failure of a red unit tier is a timed-out wait in a test that checks no scientific result, the unit tier runs once more on the same commit with no lane build on the Mac. A green rerun is the newest result, so `package` accepts it, and the session files one backlog row for each test that failed. A test that fails only under load twice in a phase moves to the list `KNOWN_LOAD_FLAKES` in `scripts/full-suite-gate.sh`, and one lane a phase clears it. A listed test still runs. In the unit and full tiers, when it fails and every other test passed, the gate runs it once more alone at the end of the tier. The integration tier never reruns a listed test. A pass there leaves the tier green and names the test as a load flake in the summary and the evidence, and a second failure leaves the tier red. A new sleep in a test is a review blocker. Every wait uses a named `WaitBudget` (`Tests/Support/LungfishTestSupport/XCTestAsyncAssertions.swift`), and no lane raises the wait of one test. In Phases 2.7 to 2.13, 112 commits touched only tests to raise or fix waits, and 2.12's candidate needed four fix rounds. |
| A quiet gate | The unit tier runs with no lane build on the Mac. Gates that ran beside lane builds, at a load average of 40 to 50, turned timing tests red. |
| Stable on a clock | `docs/contracts/SCOPE-AND-DELIVERY.md` sets when a Preview is promoted and when a result fix reaches Stable. A phase never holds a Stable release. A promotion is a new package, because a candidate receipt is bound to its channel and its commit. Commit a Stable notes file with its `## Included preview releases` section, check that a green full-tier record covers the commit (row "Stable keeps the full tier"), then `python3 scripts/release/release.py package stable` and `publish stable`. The Preview's XCUI smoke and walk cover that commit when every change since the walked commit falls under `gates.appNeutralPaths` (the release-neutral paths, the SwiftPM test folders and the gate-only scripts, none of which is built into the app). A patch release runs the same steps on a branch cut from the last Stable tag. |
| The notes file is the version | `scripts/release/release_version.py` reads the newest `docs/release-notes/<YYYY.M.PATCH>.md`, and packaging stamps it into the app after compiling. A release never edits a version in Swift, the Xcode project, the help book or the managed-tools lock. |
| Package compiles while the gates run | `package` starts the Release build at once and writes the candidate receipt only after every gate has passed. A failed gate stops the build and leaves no receipt. |
| Stable keeps the full tier | The full tier, `bash scripts/full-suite-gate.sh --tier full`, runs once on the commit of each published Preview, after `publish preview` and off the release path. No `package` or `publish` waits for it. It runs as a quiet gate, with no lane build on the Mac, in a worktree held at that commit, and it finishes before the next `package`. A red full tier is diagnosed as a red unit tier is, and its fixes land before that Preview's code is promoted. `python3 scripts/release/release.py package stable` refuses a commit that no green full-tier record covers, and `python3 scripts/release/gate_evidence.py full-evidence --root . --commit HEAD` asks the same question. A record covers a commit in three cases. In the first it ran on that commit (`exact`). In the second every change since its commit falls under the release-neutral paths (`inherited`). In the third every change since falls under the release-neutral paths or under the test folders `Tests/<bundle>/` of SwiftPM test targets. Each bundle in that third case, whether its folder changed or it ran red, then needs a green rerun (rule "Rerun one bundle") on a commit whose files in that folder equal the candidate's (`composite`). A change since the record to any other path needs a new full tier, and `Sources/`, `Package.swift`, `Package.resolved`, `config/`, `scripts/`, `Tests/Support/` and `Tests/Fixtures/` are among those paths. The Stable package still needs unit-tier evidence on its own commit, as every package does. |
| Rerun one bundle | When the fix for a red full tier touches only the test folders of the bundles that failed, plus release-neutral paths, `bash scripts/full-suite-gate.sh --tier full --bundles <Bundle>[,<Bundle>] --rerun-of <gate.result.json of the red run>` runs only those bundles, in the tier's order, each as its own serial process. The full-tier record is then the red run plus the newest green rerun of each bundle. It is void when a path outside the release-neutral paths and the rerun bundles' test folders changed after the red run, when a bundle's test folder changed after its own rerun, when the red run did not finish every bundle (a watchdog, a spent budget or a changed checkout), or when a rerun was red. |

## What each step costs

Measured on the laptop (14-core M4 Pro) on 2026-10-07, except the full tier row.

| Step | Time |
|---|---|
| Unit tier | 23 to 26 minutes |
| Full tier, one serial process for each test bundle (after each Preview) | about 2 hours on the Mac Studio, from 56 minutes of the run of 2026-10-27 before LungfishAppTests and a serial scan of the rest on the same commit, and the gate stops it at 210 minutes |
| Replay suites | about 1 minute |
| Golden comparison | about 1.5 minutes |
| Release compile, cold | about 11 minutes |
| Release compile after a change to LungfishApp only | about 4 minutes (estimate from the build timing summary) |
| Candidate assembly and smoke tests | about 5 minutes |
| Publish | 3 to 10 minutes, bound by upload speed |

`release.py` writes the time of every phase to `.build/release-metrics/`. Compare against this table after changing the pipeline.

## Where the rules live in code

| Rule | Code |
|---|---|
| Evidence lookup and inheritance | `find_unit_evidence` and the `unit-evidence` command in `scripts/release/gate_evidence.py` |
| Runs already going, and waiting for them | `live_gate_runs`, `deciding_unit_gate`, `local_gate_run` and `unit-evidence --wait` in `scripts/release/gate_evidence.py` |
| Load flake list and its rerun | `KNOWN_LOAD_FLAKES` in `scripts/full-suite-gate.sh`, and `load_flake_failures` and `validate_load_flake_reruns` in `scripts/release/gate_evidence.py` |
| Release-neutral list | `gates.releaseNeutralPaths` in `config/release-contract.json`, parsed by `scripts/release/release_contract.py` |
| Full-tier evidence, bundle reruns and the Stable refusal | find_full_evidence and the full-evidence command in scripts/release/gate_evidence.py, and _ensure_full_evidence in scripts/release/release.py |
| Paths built into no app | `gates.appNeutralPaths` in `config/release-contract.json`, parsed by `scripts/release/release_contract.py`, which refuses a path under `Sources/` or under any target of `Package.swift` that is not a test target |
| Package reuses or runs the unit tier, and compiles meanwhile | `_ensure_unit_evidence`, `start_package_build` and `finish_package_build` in `scripts/release/release.py`, and `--gate-handoff-fd` in `scripts/release/build-notarized-dmg.sh` |
| Pre-push skip | the generated hook in `scripts/install-git-hooks.sh` |

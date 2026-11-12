# Verification order

This contract sets the order in which a Lungfish Genome Explorer (LGE) session verifies its work, and says which evidence carries forward to later commits. Its purpose is that no session runs the same check twice on the same code.

## Evidence and what it covers

| Evidence | Command | Covers |
|---|---|---|
| Targeted tests | `swift test --skip-update --filter <Target or Class>` or `bash scripts/test-surface.sh <name>` | The change under test. Targeted tests never authorize a push or a release. |
| Unit tier | `bash scripts/full-suite-gate.sh --tier unit --quiet` | The exact commit it ran on, and every descendant whose changes all fall under the release-neutral paths |
| Full tier | `bash scripts/full-suite-gate.sh --tier full` | The exact commit, and the descendants the row "Stable keeps the full tier" names |
| Replay suites | `bash scripts/full-suite-gate.sh --filter ReplayTests --quiet` | The exact commit. Run them again only after a change to a recorded command, a CLI command or a replayed tool. |
| Golden outputs | `python3 scripts/golden/golden.py compare` on a Mac with the golden environment, or the `Golden` workflow on the golden runner (`docs/contracts/MACHINES.md`) | The same as the replay suites. The runner's result counts the same as a local run. |
| Executor replay | `LUNGFISH_REQUIRE_TOOLS=1` with the parity slice, conda root and database root set for this one command, `bash scripts/full-suite-gate.sh --require-tools --filter ExecutorPlanReplayParityTests --quiet` | The same as the replay suites |
| GUI walk | A person, or the manager by computer use, walks the packaged candidate from `release.py package preview` over every screen and analysis it changed, on a corpus that holds a renamed project, a copied project, a large reference and records from an older release, and compares each number on screen with the `lungfish-cli` output and the tool's own report. A walk by computer use counts with or without the owner at the Mac, on an unlocked screen (O126). A row that needs a person's own senses goes on the owner check list and does not block the release. A lane may check its own work on the Debug app from `python3 scripts/release/release.py debug`, which never counts for a release | The build it walked. Walk again only the surfaces that changed after it. |
| XCUI smoke | The `ui` profile on the packaged candidate, in a session that does not lock | The exact build. Every packaged candidate, Preview or stable, gets the smoke after its package and before its publish, and a red smoke blocks the publish. A run with a skipped XCUI or Accessibility test covers nothing. Once backlog row MAIN-THREAD-BLOCK lands, app code that blocks the main thread for more than two seconds fails the smoke. The profile runs `scripts/release/app_smoke_gate.py` over `gates.appSmokeTests` as the console user in an unlocked session, with a fresh launch home for each test. The gate moves the account's Lungfish preference domains aside before the first launch and fails the run unless it restores them exactly. `package stable` also runs the real-app smoke itself (`gates.appSmokeRequired` is true), and the candidate receipt of a Stable package refuses to bind without its retained evidence. A Preview package neither runs the smoke nor binds its evidence, so the manager runs it with `--channel preview`. |
| Release candidate | `python3 scripts/release/release.py package preview` | The exact commit. `publish` signs those bytes without rebuilding. |
| Evidence read | One fresh QA expert reads the candidate's gate logs, smoke result, walk log, sends and open S1 and S2 rows, and writes `SCR/reviews/CANDIDATE-<commit>-QA.md`. A pass puts the line `EVIDENCE-READ: PASS <channel> <full 40-character commit>` among the first 20 lines of the file, and a fail puts a line that starts `EVIDENCE-READ: FAIL` there, with the findings below it | The exact candidate. No publish runs without a PASS on it (O126). `python3 scripts/release/release.py publish <channel> --evidence-read <that file>` takes the file as a required argument with no default and no skip flag. It refuses before any credential or network contact a file that is missing, a symlink, not a regular file, over 1 MB, not UTF-8, holding a FAIL line or lacking the exact PASS line for the channel and the full commit of HEAD. |

Unit-tier evidence lives under `.build/gate-logs` in the checkout that ran it, and every worktree of the repository sees it, because it is bound to a clean commit and not to a folder. A unit-tier run in a program worktree therefore covers the same commit in the primary checkout. To ask whether evidence covers a commit, run this.

```bash
python3 scripts/release/gate_evidence.py unit-evidence --root . --commit HEAD
```

It prints `exact`, `inherited` (with the commit that was tested), `red` (the run that decides this code failed) or `none`. The newest canonical run on a commit decides that commit, and without one the nearest ancestor with a run whose changes since are all release-neutral decides. It exits 0 only when evidence covers every commit named, and 3 when any of them already failed. The pre-push hook then refuses the push rather than running the unit tier again on that code.

## Release-neutral paths

A release-neutral path is documentation that no test reads, so a change there cannot change a test result. `gates.releaseNeutralPaths` in `config/release-contract.json` lists them. The parser accepts only a `docs/` file or a `docs/` folder ending in `/**`.

The list holds release notes, plans, reports, contracts, the architecture docs and the release handoff. To add a path, show in the same change that no Swift test, no unit-tier input and no Python release test reads it, and update this paragraph. The pre-push hook's quick documentation checks still run on every push.

## Order of a session

| Step | What runs | Evidence |
|---|---|---|
| Plan | Nothing. Keep the plan on disk. | None |
| Lanes | Targeted tests for the code each lane touches, in its own worktree. A lane never runs the unit tier. | Targeted only |
| Integration | After a wave of at most three lanes merges, the unit tier runs once on the merged commit. Failures between lanes show up here. | Unit tier |
| Review and fixes | Each fix runs its targeted tests. The unit tier does not run after every round. | Targeted only |
| Final candidate | The unit tier once, then `package preview` at once (row Package), then the walk of the rows the last lanes added on that package, where a finding ends the candidate. Then the replay suites and the golden comparison once. A candidate with no change a user can see and no result fix stops here, with no Preview (`docs/contracts/SCOPE-AND-DELIVERY.md`) | Unit tier, replay, golden |
| Release notes | Commit `docs/release-notes/<version>.md` and the technical record together, in the commit that is packaged, since the notes link the record at `blob/v<version>`. Give the record each publish fact as a hidden marker, and fill the markers on `main` after the publish. Notes are release-neutral, so the final candidate's evidence still covers this commit. | Inherited |
| Package | `python3 scripts/release/release.py package preview` reuses evidence that covers HEAD, or runs the unit tier itself while the candidate compiles. | Release candidate |
| Packaged checks | The walk of the new rows first, by a person or by computer use, then after the replay and golden steps the XCUI smoke and the rest of the walk of the changed screens on the same package, in a session that does not lock. The smoke and a walk never run at the same time. Each finding gets a severity, and an open S1 or S2 or a red smoke stops the publish. No walk substitute counts. | XCUI smoke, GUI walk |
| Publish | Push `main` (the pre-push hook finds the evidence and skips the unit tier), run `setup`, get the QA expert's PASS file for the exact commit (row "Evidence read"), check that `git branch --show-current` reads `main`, the only branch `publish` runs from, then `publish <channel> --evidence-read <file>`. A Preview that fixes an S1 or S2 living in the last Stable adds its known-issue line to that Stable's release page in the same step. | Published release |

When a session adds only one small fix, the integration, review and final-candidate rows collapse into the package row. Commit the fix and the notes, run `package`, then push and publish.

## Rules

| Rule | What it means |
|---|---|
| Ask before running the unit tier | Run `gate_evidence.py unit-evidence` first. If it reports `exact` or `inherited`, the unit tier has already run on this code. |
| One unit-tier run at a time on the Mac | The unit tier keeps every core busy for about 19 minutes, see the cost table. Two runs at once both slow down. |
| Package and the pre-push hook wait for a run already going | When a unit-tier run is going on the commit, or on an ancestor whose changes since are all release-neutral, and its checkout is still at that commit, `package` and the pre-push hook wait for it and inherit its result, green or red. When another `full-suite-gate.sh` run is using this checkout's `.build` folder, they wait for it to end before running their own. Both waits share one 60-minute budget, and `package` or the push stops with an error when it runs out. |
| Never move a checkout under a running gate | A commit, merge or checkout in a checkout where a gate is running ends that run with "source changed during gate". Commit release notes in another worktree, or wait for the run to finish. |
| Push after evidence exists | Push a commit only after unit-tier evidence covers it, so the pre-push hook skips the unit tier. Never push with `--no-verify` to skip a unit tier that has not run. |
| A red unit tier is diagnosed, not retried | Read the failure in the evidence folder, rerun only the failing class to tell a product fault from a test fault, fix the cause in a new commit, and run the unit tier once on that commit. `package` refuses a commit whose newest unit-tier result failed. |
| Timed-out waits | When every failure of a red unit tier is a timed-out wait in a test that checks no scientific result, the unit tier runs once more on the same commit with no lane build on the Mac. A green rerun is the newest result, so `package` accepts it, and the session files one backlog row for each test that failed. A test that fails only under load twice in a phase moves to the list `KNOWN_LOAD_FLAKES` in `scripts/full-suite-gate.sh`, and one lane a phase clears it. A listed test still runs. In the unit and full tiers, when it fails and every other test passed, the gate runs it once more alone at the end of the tier. The integration tier never reruns a listed test. A pass there leaves the tier green and names the test as a load flake in the summary and the evidence, and a second failure leaves the tier red. A new sleep in a test is a review blocker. Every wait uses a named `WaitBudget` (`Tests/Support/LungfishTestSupport/XCTestAsyncAssertions.swift`), and no lane raises the wait of one test. |
| Runner hang | A Swift Testing step of the full tier that is killed at its bound with no event in its stream is a runner fault. The gate names it `GATE RUNNER HANG` and keeps a listing of the hung process tree and the load of the Mac in the attempt folder. When every other attempt of the tier passed, the hung tree is gone and the run's budget still holds the step's bound, the gate runs that step once more alone as its next step, which is the end of the tier. A pass leaves the tier green and names the hang in the summary and the evidence (`GATE RUNNER HANG CLEARED`), and the session files one backlog row for it. A second hang or a failed rerun leaves the tier red. A hang in an XCTest bundle, a hang after the step wrote an event and a hang beside any other failure leave the tier red with no rerun, and a run that holds a hung bundle still cannot be the base of `--rerun-of`. |
| A quiet gate | The unit tier runs with no lane build on the Mac. The defaults check of the test-state observer reads a domain that all xctest processes share, so the unit tier's parallel workers run without it and the full tier runs it only in serial attempts, and the full tier refuses to start while another xctest process runs. |
| A stable release waits for the owner | `docs/contracts/SCOPE-AND-DELIVERY.md` sets it, since a stable release is built only on the owner's word in chat. A phase never holds a Stable release. The section Promoting a Preview to a stable release sets the steps. A patch release runs the same steps on a branch cut from the last Stable tag. |
| The notes file is the version | `scripts/release/release_version.py` reads the newest `docs/release-notes/<YYYY.M.PATCH>.md`, and packaging stamps it into the app after compiling. A release never edits a version in Swift, the Xcode project, the help book or the managed-tools lock. |
| Package compiles while the gates run | `package` starts the Release build at once and writes the candidate receipt only after every gate has passed. A failed gate stops the build and leaves no receipt. |
| Stable keeps the full tier | After each published Preview the gate runs the integration and conformance tiers on that commit, off the release path. The whole full tier, `bash scripts/full-suite-gate.sh --tier full`, runs in their place on a Preview that is to be promoted, and once a phase otherwise. A red made only of test-state leaks or load flakes files one backlog row and starts no lane of its own. No `package` or `publish` waits for it. It runs as a quiet gate, with no lane build on the Mac, in a worktree held at that commit, and it finishes before the next `package`. A red full tier is diagnosed as a red unit tier is, and its fixes land before that Preview's code is promoted. `python3 scripts/release/release.py package stable` refuses a commit that no green full-tier record covers, and `python3 scripts/release/gate_evidence.py full-evidence --root . --commit HEAD` asks the same question. A record covers a commit in three cases. In the first it ran on that commit (`exact`). In the second every change since its commit falls under the release-neutral paths (`inherited`). In the third every change since falls under the release-neutral paths or under the test folders `Tests/<bundle>/` of SwiftPM test targets. Each bundle in that third case, whether its folder changed or it ran red, then needs a green rerun (rule "Rerun one bundle") on a commit whose files in that folder equal the candidate's (`composite`). A change since the record to any other path needs a new full tier, and `Sources/`, `Package.swift`, `Package.resolved`, `config/`, `scripts/`, `Tests/Support/` and `Tests/Fixtures/` are among those paths. |
| Rerun one bundle | When the fix for a red full tier touches only the test folders of the bundles that failed, plus release-neutral paths, `bash scripts/full-suite-gate.sh --tier full --bundles <Bundle>[,<Bundle>] --rerun-of <gate.result.json of the red run>` runs only those bundles, in the tier's order, each as its own serial process. The full-tier record is then the red run plus the newest green rerun of each bundle. It is void when a path outside the release-neutral paths and the rerun bundles' test folders changed after the red run, when a bundle's test folder changed after its own rerun, when the red run did not finish every bundle (a watchdog, a spent budget or a changed checkout), or when a rerun was red. |
| Candidate rounds | A fix round that ends in `package preview` runs no full tier. The replay suites, the golden compare and the executor replay carry from their last green run only when the diff since holds no path under `Sources/`, `Package.swift`, `Package.resolved`, `config/`, `Tests/Fixtures/`, `Tests/Support/` or `scripts/golden/`, and no file whose name holds `Replay`. A run of `--bundles` with no `--rerun-of` is a diagnostic and covers nothing. |

## Promoting a Preview to a stable release

A stable release is a promotion and never a candidate of its own. Every fix round is a Preview round, and the stable package is built once.

| Step | What runs | Stops when |
|---|---|---|
| 1. Entry | The owner has asked for the release. A published Preview at commit P passed its walk and its XCUI smoke | An S1 or S2 is open. Fix it in a Preview round and start again |
| 2. Full tier | The whole full tier on P, started right after the Preview's publish. The Stable notes with `## Included preview releases` are written meanwhile in another worktree. A red of leaks or flakes only is closed by the rule Rerun one bundle | A product fault rated S1 or S2 goes back to step 1 |
| 3. Notes | Commit the Stable notes on P. The unit and full-tier records are inherited, and the Preview's walk covers the commit while every change since P falls under `gates.appNeutralPaths` | A change outside those paths is a new Preview round |
| 4. Preflight | Python 3.11 or newer first on `PATH`, the Xcode of the Preview's package, no `DatabaseStorageLocation` key, `release.py doctor` ready | A changed Xcode. Package and smoke the Preview again first |
| 5. Package | `release.py package stable`, once. It runs the real-app smoke itself, so the owner's console must be unlocked with no Lungfish running. Then the XCUI smoke on that package, since it is another binary with another update feed. No second walk | A red smoke on a product fault |
| 6. Publish | `release.py setup` right before the publish, the QA read with `EVIDENCE-READ: PASS stable <full commit>`, then `publish stable --evidence-read <file>` from a checkout on `main` | A FAIL line |
| 7. After | The yank dry run two minutes later (it needs `--force` without `--execute`, and a retained appcast of the release before it), the known-issue lines of the old Stable page and the technical record | Nothing |

A second stable package is built only for a changed toolchain or a failed notarization.

## What each step costs

Measured on galah (Mac Studio M1 Ultra, 20 cores, 64 GB) in Phases 3 and 4.

| Step | Time |
|---|---|
| Unit tier | about 19 minutes (2026-11-11, gate `gate-20261111-171722-a8384152d-65587`, `phase-4/events.log` 17:40) |
| Whole full tier, one serial process a bundle | 95 to 106 minutes, stopped by the gate at 210 |
| Replay suites | 17 to 22 minutes |
| Golden comparison | about 2 minutes |
| Executor replay | 9 to 10 minutes |
| `package` | 4 to 18 minutes |
| XCUI smoke | 16 to 30 minutes |
| A whole Preview chain | about 70 minutes plus the walk |
| Publish | 3 to 10 minutes, bound by upload speed |

`release.py` writes the time of every phase to `.build/release-metrics/`.

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

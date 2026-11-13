# Verification order

This contract sets the order in which a Lungfish Genome Explorer (LGE) session verifies its work and which evidence carries forward, so that no session runs the same check twice on the same code. A tag such as (E-VO-1) points to the reason of a rule in `~/lungfish-phase-records/llm/evidence/VO.md`.

## Evidence and what it covers

| Evidence | Command | Covers |
|---|---|---|
| Targeted tests | `swift test --skip-update --filter <Target or Class>` or `bash scripts/test-surface.sh <name>` | The change under test. They never authorize a push or a release |
| Unit tier | `bash scripts/full-suite-gate.sh --tier unit --quiet` | The exact commit, and every descendant whose changes all fall under the release-neutral paths |
| Full tier | `bash scripts/full-suite-gate.sh --tier full` | The exact commit, and the descendants rule "Stable keeps the full tier" names |
| Replay, golden, executor replay | `bash scripts/full-suite-gate.sh --filter ReplayTests --quiet`, `python3 scripts/golden/golden.py compare` (or the `Golden` workflow, which counts the same, `docs/contracts/MACHINES.md`), `bash scripts/full-suite-gate.sh --require-tools --filter ExecutorPlanReplayParityTests --quiet` with `LUNGFISH_REQUIRE_TOOLS=1` and the parity slice and roots set for that command | The exact commit. Run them again only after a change to a recorded command, a CLI command or a replayed tool |
| GUI walk | An `lge-walker` agent in background control walks the packaged candidate over every screen and analysis it changed, on a corpus with a renamed project, a copied project, a large reference and records from an older release, and compares each number on screen with the `lungfish-cli` output. Full-screen control waits for the owner's go in chat, and a row that needs the app in front goes on the owner list, and the Debug app (`release.py debug`) never counts (E-VO-1) | The build it walked. Walk again only what changed after it |
| XCUI smoke | `python3 scripts/release/app_smoke_gate.py` (`--help` lists the arguments) in the console user's unlocked session | The exact build. Every packaged candidate, Preview or stable, gets the smoke after its package and before its publish, and a red smoke blocks the publish. A run with a skipped XCUI or Accessibility test covers nothing. A Preview package does not run it, so `lge-release` does. `package stable` runs the real-app smoke itself (E-VO-2). The smoke opens the scale corpus in `/Users/Shared/lungfish-golden/cache/scale-corpus/`, which the gate does not build: make it once with `python3 scripts/golden/scale_corpus.py build` and check it with `verify` |
| Evidence read | One fresh QA expert reads the candidate's gate logs, smoke result, walk log, sends and open S1 and S2 rows and writes `SCR/reviews/CANDIDATE-<commit>-QA.md` with `EVIDENCE-READ: PASS <channel> <full 40-character commit>`, or `EVIDENCE-READ: FAIL`, among its first 20 lines | The exact candidate. `release.py publish <channel> --evidence-read <file>` requires it, and `verify_evidence_read` refuses a file without the exact PASS line (E-VO-3) |

Ask before running the unit tier. `python3 scripts/release/gate_evidence.py unit-evidence --root . --commit HEAD` (`find_unit_evidence`) prints `exact`, `inherited`, `red` or `none` and exits 0 only when evidence covers every commit named and 3 when one failed. `gates.releaseNeutralPaths` in `config/release-contract.json` lists the documentation that no test reads. To add a path, show that no Swift test, unit-tier input or Python release test reads it.

## Order of a session

| Step | What runs |
|---|---|
| Lanes | Targeted tests in the lane's own worktree. A lane never runs the unit tier |
| Integration | After a wave of at most three lanes merges, the unit tier runs once on the merged commit |
| Review and fixes | Each fix runs its targeted tests. The unit tier does not run after every round |
| Final candidate | The unit tier once, then `package preview` at once, then the walk of the rows the last lanes added, where a finding ends the candidate. Then the replay suites and the golden comparison once. A candidate with no change a user can see and no result fix stops here, with no Preview (`docs/contracts/SCOPE-AND-DELIVERY.md`) |
| Release notes | Commit `docs/release-notes/<version>.md` and the technical record together, in the commit that is packaged, since the notes link the record at `blob/v<version>`. Give the record each publish fact as a hidden marker and fill the markers on `main` after the publish (E-VO-4) |
| Package | `python3 scripts/release/release.py package preview` reuses evidence that covers HEAD or runs the unit tier itself while the candidate compiles (`_ensure_unit_evidence`, `start_package_build`) (E-VO-15) |
| Packaged checks | The walk of the new rows, then after the replay and golden steps the XCUI smoke and the walk of the changed screens on the same package, never at the same time. Each finding gets a severity, and an open S1 or S2 or a red smoke stops the publish. No walk substitute counts |
| Publish | Push `main`, run `release.py setup`, get the QA PASS file for the exact commit, check that `git branch --show-current` reads `main` since `publish` runs from no other branch, then `publish <channel> --evidence-read <file>`. A Preview that fixes an S1 or S2 living in the last Stable adds its known-issue line to that Stable's release page in the same step (`docs/contracts/SCOPE-AND-DELIVERY.md:29`). Run the yank dry run two minutes later (E-VO-5) |

A session with one small fix commits the fix and the notes, runs `package`, then pushes and publishes.

## Rules

| Rule | What it means |
|---|---|
| One unit-tier run at a time | It keeps every core busy for about 19 minutes, so run it alone with no lane build on the Mac (E-VO-9). `package` and the pre-push hook wait for a run on the commit or on a release-neutral ancestor and inherit its result, within one 60-minute budget (`live_gate_runs`, `deciding_unit_gate`, `local_gate_run`, `unit-evidence --wait`) (E-VO-6) |
| Never move a checkout under a running gate | A commit, merge or checkout there ends the run. Commit release notes in another worktree |
| Push after evidence exists | Push only when unit-tier evidence covers the commit, so the pre-push hook (`scripts/install-git-hooks.sh`) skips the unit tier. Never push with `--no-verify` to skip a unit tier that has not run |
| A red unit tier is diagnosed, not retried | Read the failure in the evidence folder, rerun only the failing class to tell a product fault from a test fault, fix the cause in a new commit and run the unit tier once on it |
| Timed-out waits | A red unit tier made only of timed-out waits in tests that check no scientific result runs once more on the same commit with no lane build on the Mac, and each failed test gets one backlog row. A test that fails only under load twice in a phase joins `KNOWN_LOAD_FLAKES` in `scripts/full-suite-gate.sh` and one lane a phase clears the list (`load_flake_failures`, `validate_load_flake_reruns`). A new sleep in a test is a review blocker, and every wait uses a named `WaitBudget`, and no lane raises the wait of one test (E-VO-7) |
| Runner hang | A Swift Testing step killed at its bound with no event is a runner fault. `run_bundle_attempts` names it `GATE RUNNER HANG` and reruns it once alone, and the session files one backlog row (E-VO-8) |
| A stable release | It is built only on the owner's word in chat (`docs/contracts/SCOPE-AND-DELIVERY.md`). A patch release runs the same steps on a branch cut from the last Stable tag |
| The notes file is the version | `scripts/release/release_version.py` reads the newest `docs/release-notes/<YYYY.M.PATCH>.md`. A release never edits a version in Swift, the Xcode project, the help book or the managed-tools lock |
| Stable keeps the full tier | The whole full tier runs on a Preview that is to be promoted and once a phase otherwise, quiet, in a worktree held at that commit, before the next `package`. A red of leaks or flakes only files one backlog row. `package stable` refuses a commit that no green full-tier record covers (`find_full_evidence`, `_ensure_full_evidence`), and a change since the record outside the release-neutral paths and the test folders needs a new full tier (E-VO-10) |
| Rerun one bundle | When the fix for a red full tier touches only the failed bundles' test folders and release-neutral paths, run `bash scripts/full-suite-gate.sh --tier full --bundles <Bundle>[,<Bundle>] --rerun-of <gate.result.json of the red run>`. `find_full_evidence` voids the record on any other change. A `--bundles` run with no `--rerun-of` covers nothing (E-VO-11) |
| Candidate rounds | A fix round that ends in `package preview` runs no full tier. The replay suites, the golden compare and the executor replay carry from their last green run when the diff since holds no path under `Sources/`, `Package.swift`, `Package.resolved`, `config/`, `Tests/Fixtures/`, `Tests/Support/` or `scripts/golden/` and no file whose name holds `Replay` |

## Promoting a Preview to a stable release

A stable release is a promotion and never a candidate of its own. The stable package is built once, again only for a changed toolchain or a failed notarization.

| Step | What runs | Stops when |
|---|---|---|
| 1. Entry | The owner has asked for the release in chat. A published Preview at commit P passed its walk and its XCUI smoke | An S1 or S2 is open. Fix it in a Preview round and start again |
| 2. Full tier | The whole full tier on P, started right after the Preview's publish, while the Stable notes with `## Included preview releases` are written in another worktree. A red of leaks or flakes only is closed by the rule Rerun one bundle | A product fault rated S1 or S2 goes back to step 1 |
| 3. Notes on P | Commit the Stable notes on P. The unit and full-tier records are inherited, and the Preview's walk covers the commit while every change since P falls under `gates.appNeutralPaths` (E-VO-12) | A change outside those paths is a new Preview round |
| 4. Preflight | Python 3.11 or newer first on `PATH`, the Xcode of the Preview's package, no `DatabaseStorageLocation` key, `release.py doctor` ready | A changed Xcode. Package and smoke the Preview again first |
| 5. Package | `release.py package stable`, once. It runs the real-app smoke itself, so the owner's console must be unlocked with no Lungfish running. Then the XCUI smoke on that package, since it is another binary with another update feed. No second walk (E-VO-13) | A red smoke on a product fault |
| 6. Publish | `release.py setup` right before the publish, the QA read with `EVIDENCE-READ: PASS stable <full commit>`, then `publish stable --evidence-read <file>` from a checkout on `main` | A FAIL line |
| 7. After | The yank dry run two minutes later. It needs `--force` without `--execute`, and a retained appcast of the release before it. Then the known-issue lines of the old Stable page and the technical record (E-VO-13) | Nothing |

## What each step costs

Measured on galah (Mac Studio M1 Ultra, 20 cores, 64 GB) in the Phase 4 close. Gate times are the `startedAt` and `endedAt` of the gate's `gate.result.json`. The others come from `events.log` (line numbers) and the `cand/` logs of `~/lungfish-phase-records/phase-4/`. Phase times of `release.py` are in `.build/release-metrics/` (E-VO-14).

| Step | Time, date and source |
|---|---|
| Unit tier (P2, a8384152d) | 18 min 45 s, 2026-11-11 17:17:22 to 17:36:08, gate 20261111-171722-a8384152d-65587, `events.log` 143 |
| Whole full tier | 95 min 37 s, 2026-11-11 17:39:52 to 19:15:30, gate 20261111-173952-a8384152d-55294, `events.log` 149 |
| Replay suites, golden comparison, executor replay | 17 min, 109.3 s and 9 min, 2026-11-11, `events.log` 109 and `cand/golden-2.log` |
| `package` with the unit tier inside | about 22 min, 2026-11-11 17:17:16 to 17:39:52, `events.log` 142 and 143 |
| `package` with evidence inherited | 4 min 1 s, 2026-11-11 19:51:22 to 19:55:23, `events.log` 157 |
| XCUI smoke | 33 min 3 s, 2026-11-11 19:55:24 to 20:28:27, `events.log` 157 |
| `package stable` with the real-app smoke | 46 min 57 s, 2026-11-11 21:07:00 to 21:53:57, `events.log` 170 |
| Publish of a Preview, of a stable release | 3 min 35 s and 6 min 56 s, 2026-11-11 20:47:05 to 20:50:40 and 22:06:53 to 22:13:49, `events.log` 162 and 174 |

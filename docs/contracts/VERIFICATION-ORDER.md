# Verification order

This contract sets the order in which a Lungfish Genome Explorer (LGE) session verifies its work, and says which evidence carries forward to later commits. Its purpose is that no session runs the same check twice on the same code.

The owner set it on 2026-10-07. Preview 2026.10.10 ran the 25-minute unit tier three times on one commit, and a small fix took about an hour to release. Most of that hour went to checks that had already passed on unchanged code.

## Evidence and what it covers

| Evidence | Command | Covers |
|---|---|---|
| Targeted tests | `swift test --skip-update --filter <Target or Class>` or `bash scripts/test-surface.sh <name>` | The change under test. Targeted tests never authorize a push or a release. |
| Unit tier | `bash scripts/full-suite-gate.sh --tier unit --quiet` | The exact commit it ran on, and every descendant whose changes all fall under the release-neutral paths |
| Replay suites | `bash scripts/full-suite-gate.sh --filter ReplayTests --quiet` | The exact commit. Run them again only after a change to a recorded command, a CLI command or a replayed tool. |
| Golden outputs | `python3 scripts/golden/golden.py compare` | The same as the replay suites |
| GUI walk | The Debug app from `python3 scripts/release/release.py debug` | The build it walked. Walk again only the surfaces that changed after it. |
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
| Final candidate | The unit tier once, then the replay suites and the golden comparison once, and one GUI walk on a Debug build of this commit | Unit tier, replay, golden, GUI walk |
| Release notes | Commit `docs/release-notes/<version>.md`. The newest notes file names the release, so no version bump exists. Notes are release-neutral, so the final candidate's evidence still covers this commit. | Inherited |
| Package | `python3 scripts/release/release.py package preview` reuses evidence that covers HEAD, or runs the unit tier itself while the candidate compiles. | Release candidate |
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
| The notes file is the version | `scripts/release/release_version.py` reads the newest `docs/release-notes/<YYYY.M.PATCH>.md`, and packaging stamps it into the app after compiling. A release never edits a version in Swift, the Xcode project, the help book or the managed-tools lock. |
| Package compiles while the gates run | `package` starts the Release build at once and writes the candidate receipt only after every gate has passed. A failed gate stops the build and leaves no receipt. |
| Stable keeps the full tier | A Stable release still runs `bash scripts/full-suite-gate.sh --tier full` before packaging, as AGENTS.md requires. Evidence reuse shortens Preview work only. |

## What each step costs

Measured on the release Mac (14-core M4 Pro) on 2026-10-07.

| Step | Time |
|---|---|
| Unit tier | 23 to 26 minutes |
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
| Release-neutral list | `gates.releaseNeutralPaths` in `config/release-contract.json`, parsed by `scripts/release/release_contract.py` |
| Package reuses or runs the unit tier, and compiles meanwhile | `_ensure_unit_evidence`, `start_package_build` and `finish_package_build` in `scripts/release/release.py`, and `--gate-handoff-fd` in `scripts/release/build-notarized-dmg.sh` |
| Pre-push skip | the generated hook in `scripts/install-git-hooks.sh` |

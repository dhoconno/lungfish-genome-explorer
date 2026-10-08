# Machines

This contract says what each Mac that works on Lungfish Genome Explorer (LGE) is for, where the golden comparison runs, and how a laptop takes part without holding the golden environment. The owner set it on 2026-10-08, when the Mac Studio became the golden runner and a second release Mac.

## Roles

| Machine | Role | What runs there |
|---|---|---|
| Mac Studio (M1 Ultra, 20 cores) | Golden runner and release Mac | The `Golden` workflow on every push to `main` and on demand, the release commands, and any work a person does at it |
| The laptop (M4 Pro, 14 cores) | Release Mac and development Mac | The release commands and day-to-day development |
| Any other Mac | Development Mac | Targeted tests, the unit tier and, when its owner provisions the golden environment, the golden comparison |

A release Mac holds the signing identity, the notary profile and the Sparkle key, and `python3 scripts/release/release.py setup` passes on it. The golden runner holds the golden environment and runs the GitHub Actions runner service. Neither role depends on the account name, because nothing in the goldens records a home folder.

## The golden environment

The golden captures run `lungfish-cli` against a managed storage root at `/Users/Shared/lungfish-golden/storage`. The path is the same on every Mac, so the goldens record the same tool and database paths whoever runs them. The folder holds eight conda environments (minimap2, samtools, seqkit, kraken2, esviritu, bbtools, pysam and openpyxl) and two databases (the Kraken2 Viral database and the EsViritu Viral DB), about 5 GB in all.

`Tests/Fixtures/golden-environment/lock.json` pins all of it. Each environment has an explicit conda file that lists every package by URL and MD5, so a rebuild installs the same bytes. Each database has its source archive and the size and SHA-256 of its files. The folder's own README explains each field.

| Command | What it does |
|---|---|
| `python3 scripts/golden/environment.py provision` | Builds the folder from the lock or repairs any part that differs. Nothing that already matches is downloaded again. |
| `python3 scripts/golden/environment.py verify` | Checks the folder against the lock and changes nothing |
| `python3 scripts/golden/golden.py compare` | Runs the same check first and stops with the list of differences when the folder does not match |

Rules for the folder:

1. Only `environment.py provision` writes to `storage/`. Never point the app or `LUNGFISH_STORAGE_ROOT` at it for daily work, because the app updates databases and environments it manages.
2. The folder belongs to the `staff` group and is group writable, so the runner account and a person's account on the same Mac can both run the comparison. One golden run at a time holds `cache/.lock`.
3. The goldens no longer read `~/.lungfish-stable`. Copying that folder between Macs is not part of golden work.
4. The goldens mask the macOS version and build (rule H1 in `Tests/Fixtures/golden/README.md`), so any macOS 26 build on Apple silicon gives the same result.

## How a laptop works

A laptop follows `docs/contracts/VERIFICATION-ORDER.md` for targeted tests and the unit tier. For the golden comparison it has two choices.

| Choice | When | How |
|---|---|---|
| Ask the runner | The usual case, and every time the laptop has no golden environment | Push the branch, then run `gh workflow run golden.yml --ref <branch>` and read the result with `gh run watch`. The runner compares that commit exactly as it compares `main`. |
| Compare locally | The laptop owner wants the result without a push, or is changing goldens on purpose | Run `environment.py provision` once (about 5 GB of downloads), then `golden.py compare` as usual |

Both give the same answer, because both run the locked environment at the same path. A golden recapture (`golden.py capture`) may run on any Mac whose `environment.py verify` passes, and the runner's comparison of the pushed commit confirms it. A recapture still goes in its own reviewed commit, as `Tests/Fixtures/golden/README.md` describes.

The push to `main` starts the `Golden` workflow on its own. A red run on `main` is diagnosed like a red unit tier. Read the diff in the job log, decide whether the change or the goldens are wrong, and fix it in a new commit.

## Updating the lock

A golden environment changes only through a reviewed commit that updates the lock and recaptures the goldens together.

| Change | Steps |
|---|---|
| A tool pin in `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` | `python3 scripts/golden/environment.py lock --solve --env <name>`, then `provision`, `golden.py compare`, read the diff, `golden.py capture`, and commit the manifest, the lock and the goldens together |
| A database version | Change the database's `version`, `source.url` and registry `downloadURL` in `lock.json`. `provision` installs the new archive and reports that its files differ. Then run `environment.py lock --from-storage /Users/Shared/lungfish-golden/storage --database <name>`, `provision` again, and compare and capture as above. |
| Proving the lock matches a machine's existing environments | `python3 scripts/golden/environment.py lock --from-storage <storage root>` rewrites the explicit files from that root's installed packages, and `git diff` shows any difference |

`scripts/tests/test_golden_environment.py` fails when a golden tool's pin in the manifest differs from its pin in the lock, or when the lock's databases differ from the fingerprints in `Tests/Fixtures/golden/classifiers/environment.json`. Neither can drift without a test going red.

## The runner

The `Golden` workflow in `.github/workflows/golden.yml` runs on a runner with the labels `self-hosted`, `macOS`, `ARM64` and `lge-golden`. It runs on pushes to `main` and on demand, never on pull requests, because a self-hosted runner executes whatever it checks out. Its permissions are read-only and it reads no secrets. `ci.yml` stays dispatch-only, as its header explains, and no job runs on a hosted runner because of this contract.

The owner registers the runner once on the Mac Studio. It was set up this way on 2026-10-08.

### Account and runner


1. Create a standard macOS account for the runner, `lge-runner`. The runner must not use the account that holds the signing identity and notary profile, because workflow code runs with that account's keychain. A standard account is in the `staff` group, which the golden folder is shared with.
2. Check that full Xcode 27 is installed in `/Applications`, that its license is accepted and that its first launch is complete.
3. In the repository's Settings, open Actions, then Runners, then New self-hosted runner, and pick macOS and ARM64. As `lge-runner`, download the runner into `/Users/lge-runner/actions-runner` as the page shows, then run `./config.sh` with the URL and token it gives and `--labels lge-golden --name mac-studio-golden`.

### Launch daemon

The runner runs as a launch daemon, so it starts at boot and needs nobody logged in. Do not use `./svc.sh install`, which makes a launch agent that loads only into a logged-in session of `lge-runner`. Run these from an administrator account.

1. Copy `scripts/golden/runner/actions.runner.dhoconno-lungfish-genome-explorer.mac-studio-golden.plist` to `/Library/LaunchDaemons/` with `sudo cp`. It runs `runsvc.sh` from `/Users/lge-runner/actions-runner` as `lge-runner` and logs to `/Users/lge-runner/Library/Logs`.
2. Give it to root with `sudo chown root:wheel` and `sudo chmod 644` on the copy.
3. Load it with `sudo launchctl bootstrap system /Library/LaunchDaemons/actions.runner.dhoconno-lungfish-genome-explorer.mac-studio-golden.plist`.
4. Check it with `sudo launchctl print system/actions.runner.dhoconno-lungfish-genome-explorer.mac-studio-golden`, which shows `state = running`, and in Settings, where the runner shows as Idle.

To run a command as `lge-runner` from another account, use `sudo -H -u lge-runner`. Without `-H` the command keeps the caller's home folder.

### Environment and first run

1. The golden folder is shared, so a folder another account already provisioned on the same Mac needs nothing more. Otherwise, as `lge-runner`, clone the repository and run `python3 scripts/golden/environment.py provision` once, so the first workflow run does not wait for downloads.
2. Run the workflow by hand with `gh workflow run golden.yml --ref main` and check that it passes.

Every golden run and every provision leaves what it wrote group writable (`share_tree` in `scripts/golden/environment.py`), because the next run may belong to the other account and empties `run/` first.

## Where the rules live in code

| Rule | Code |
|---|---|
| The fixed path, the lock format, verify and provision | `scripts/golden/environment.py` |
| The check before every capture and the home folder check | `main` and `portability_problems` in `scripts/golden/golden.py` |
| The storage the CLI uses during a capture | `CaptureContext.environment` in `scripts/golden/captures.py` |
| The workflow's triggers, runner and permissions | `.github/workflows/golden.yml`, pinned by `scripts/tests/test_golden_workflow.py` |
| The lock agrees with the manifest and the goldens | `scripts/tests/test_golden_environment.py` |

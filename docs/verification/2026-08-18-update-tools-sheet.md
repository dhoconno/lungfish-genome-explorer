# Update Tools sheet verification (2026-08-18)

Status: GUI verification BLOCKED. Computer Use access to the Lungfish app was requested twice and denied both times, so no screenshots were captured and no click-through was performed. Per the task rules a code audit is not a substitute, so this document records only what was actually observed, plus the isolated fixtures that are staged and ready for a later run.

## What was verified

The planner path that feeds the sheet was exercised through the CLI against the same two isolated storage roots the GUI scenarios call for. The CLI and the sheet build their plan from the same `DependencyReconciler.currentPlan()`, so this confirms the plan contents the sheet would render, but not the sheet itself, its buttons, or its gating.

### Fresh root (`/tmp/lge-fresh`, empty directory)

`lungfish-cli tools update --plan --storage-root /tmp/lge-fresh` reports 17 required installs plus a micromamba bootstrap, estimated download 2.67 GB. Every row is marked required, so `ReconciliationPlan.hasRequiredWork` is true and the sheet would show "Quit" rather than "Later". The required-only plan is identical, confirming nothing in the fresh plan is deferrable.

### Upgrade root (`/tmp/lge-upgrade`, APFS clones of conda and databases, no receipt)

`lungfish-cli tools update --plan --storage-root /tmp/lge-upgrade` reports one install (freyja), six reinstalls, and the micromamba bootstrap, estimated download 1.1 GB. The reinstalls carry the expected reasons: `specChanged` for clair3, `buildChanged` for flye, lofreq, medaka, and phasing, and `metadataMismatch` for bracken.

Critically, the removals list is empty. The seeded root contains 55 environments including user-created ones (`test-env`, `pbaa-env`, `savont`, `freyja-env`), and none of them appear as removals, which is the behavior the sheet's Removals section depends on.

## What was not verified

None of the following were observed, and all remain open:

- The sheet appearing at launch, its section layout, and its counts.
- "Later" being disabled (shown as "Quit") when required work is pending.
- A live Update run, its OperationCenter entries, and the resulting `dependency-receipt.json`.
- Plugin Manager "Check for Tool Updates..." and its up-to-date alert.
- The Welcome window re-evaluating its required-setup gate after the sheet finishes.

## Staged fixtures

Both roots are staged and can be reused directly once Computer Use access is granted:

- `/tmp/lge-fresh` is an empty directory.
- `/tmp/lge-upgrade` holds APFS clones of `~/.lungfish/conda` and `~/.lungfish/databases` with no receipt, seeded with `/bin/cp -Rc` per subdirectory. Cloning `conda/pkgs` wholesale fails because `pkgs/cache` carries a setgid bit that `cp` cannot reproduce, so `bin`, `cache`, and `envs` are cloned individually and `pkgs` is left empty.

Launch for a later run: `LUNGFISH_STORAGE_ROOT=/tmp/lge-upgrade .build/debug/Lungfish`. Never point this at the real `~/.lungfish`, because the reconciler reinstalls and removes environments.

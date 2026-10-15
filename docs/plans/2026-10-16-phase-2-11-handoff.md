# Phase 2.11 handoff for the Mac Studio

Start Phase 2.11 on October 16, 2026. This handoff records the October 15 repair and the owner's direction for Lungfish Genome Explorer (LGE).

## Sync and read

Read `AGENTS.md`, `docs/contracts/MACHINES.md`, `docs/contracts/RUNNING-A-PHASE-SESSION.md` and `docs/contracts/VERIFICATION-ORDER.md`. Follow the Mac Studio rules.

Inspect the working tree and preserve any local changes. Fetch origin and fast-forward `main` with `git pull --ff-only origin main`. Confirm that `main` includes `3c397af2fe6fccc1c9fc4da219f31681b3c22153`, "Fix SRA preparation window ownership and cancellation". Do not reset away newer work if `origin/main` has advanced.

Read these records before choosing the first changes.

- [Phase 2.11 carry-in plan](2026-10-15-phase-2-11.md)
- [Phase 2.10 record](2026-10-13-phase-2-10.md)
- [Preview 2026.10.18 release notes](../release-notes/2026.10.18.md)

The 2.11 plan is a carry-in inventory, not an instruction to implement every row. Its section "SRA launch repair and owner direction of 2026-10-15" records the latest findings and overrides. The owner intends to start October 16, replacing the older start-after-quota-reset assumption.

## SRA repair

The reported SRA hang happened before CLI launch. After metadata lookup, the browser dismissed its sheet before resolving the import-settings window. A missing window left the operation running indefinitely. Cancellation was registered only after settings confirmation. The Actions inspector also failed to refresh when cancellability changed.

Commit `3c397af2f` preserves the owning window, provides cancellation during lookup and settings, ends missing-window and closed-window paths, logs preparation and metadata fallback, and refreshes Actions when cancellation becomes available. Confirmation still uses the existing SRA CLI route. Reverting that route would not fix the original preparation defect.

## Verification on the repair commit

- All 45 targeted tests passed. They cover SRA preparation, browser confirmation into a stand-in CLI, cancellation, existing route replay, parity, signing and Operations controls.
- The laptop Debug build and bundle checks passed.
- Live Debug GUI checks used SRR36291587 in a temporary project. Import settings appeared, settings Cancel ended the first row, and Actions → Cancel in Operations ended another row and dismissed its settings. Both rows kept their preparation logs.
- The required unit gate passed with 21,270 executed tests, zero failures and 106 skips. Exact commit evidence was recorded on the laptop.
- The [Mac Studio Golden workflow](https://github.com/dhoconno/lungfish-genome-explorer/actions/runs/38801068783) passed after the push.

Pre-push checks passed and `3c397af2f` was pushed to `origin/main`. No full live SRA download was confirmed in the GUI check. The broader Phase 2.10 owner checklist remains open. No new release was published. Later on 2026-10-15, Preview 2026.10.19 shipped this repair from `c8dd6aca5`, and the SRA section of the [Phase 2.11 carry-in plan](2026-10-15-phase-2-11.md) records it.

## Dependencies before deleting legacy routes

Preserve Phase 2.10's shared CLI execution, progress bridge, output publication, provenance relocation, final payload references and signing.

| Route or work | Required before deletion or parity claims |
|---|---|
| Database browser routes and keys under K3 | Resolve K2. No-project downloads need a defined destination, recorded command and tested replacement |
| SRA preparation | Preserve coverage of metadata failure, missing or closed owner windows, cancellation during lookup and settings, and confirmation into the CLI route |
| Mapping routes under K3 | Resolve K11. Add reference-bundle mapping coverage and resolve publication under a `/private` project path |
| TaxTriage parity under U30 | Resolve R2's database identity and Q32's live per-sample comparison and cancellation evidence |
| Test retirement | Keep behavioral tests for payloads, provenance, signatures, cancellation and result delivery. Retire only tests specific to removed route mechanisms |

## TaxTriage owner direction

A temporary limitation for a day or two is acceptable. Retain the TaxTriage legacy route only if straightforward. Do not spend substantial effort maintaining it merely to satisfy the old extra-release retention rule. If the replacement is unavailable, refuse the launch clearly and document the temporary limitation. Do not claim parity without evidence or revert shared executor and provenance work.

## Start the phase

Assess the remaining 2.10 findings before choosing the first 2.11 changes. Its recorded green checks do not erase the carried integration and conformance failures or uncompleted GUI checks. Reconcile its empty "What ran" and "Expert reviews" sections from the archived evidence when completing the phase record.

Reuse valid verification evidence according to the repository contract. Do not rerun the unit gate solely because this is another machine. Run targeted checks for new changes and obtain fresh gate evidence when required. This handoff does not authorize publishing a release.

# Micromamba Update and Corrective Releases Implementation Plan

> **For agentic workers:** Use systematic debugging for the fix and the repository releasing-lungfish skill for release execution. The user authorized supervised agents, fixes, and publication of both channels.

**Goal:** Resolve open issue #34 and publish verified Preview and Stable updates.

**Architecture:** Keep the upstream dependency pin authoritative for original upstream bytes. Validate packaged micromamba using integrity evidence appropriate to the transformed, signed application; never accept an arbitrary mismatching executable. Exercise the actual reconciliation path and preserve the installed runtime on rejection.

**Tech Stack:** Swift, XCTest, Python release coordinator, macOS code signing, Sparkle.

**Spec:** GitHub issue #34 and the user request; release authority is `.codex/skills/releasing-lungfish/SKILL.md`.

## Constraints and review focus

- Preserve scientific provenance and dependency audit records.
- Reject corrupt or substituted bootstrap binaries before replacing an installed runtime.
- Support original source resources and packaged Debug/Preview/Stable resources.
- Test the real updater service, including a packaged binary with a different upstream hash.
- Retain release receipts, signing transactions, notarization evidence, and verified remote feeds.

## Task 1: Diagnose and repair bootstrap verification

- [x] Inspect all open issues; label #34 bug and accepted.
- [x] Reproduce checksum mismatch using an existing packaged micromamba.
- [x] Add failing regression coverage in dependency reconciliation tests.
- [x] Implement minimal verification and safe installation in `Sources/LungfishWorkflow/Dependencies/DependencyReconciler.swift` and a focused helper if needed.
- [x] Verify trusted-package install, untrusted replacement rejection, missing pin/wrong version rejection, and preservation of an installed runtime; obtain independent code review. Final packaged-artifact proof follows in both release coordinators.

## Task 2: Preview 2026.9.51

- [x] Check remote versions and release machine readiness.
- [x] Update the five canonical version declarations and add `docs/release-notes/2026.9.51.md` against v2026.9.50.
- [x] Run focused regression tests, release authority validator, whitespace checks, and old-version scans; commit reviewed changes.
- [x] Run `python3 scripts/release/release.py package preview` then `python3 scripts/release/release.py publish preview`.
- [x] Verify the signed artifact, GitHub release, Beta feed, and Alpha bridge.

## Task 3: Stable 2026.9.52

- [x] Recheck version collisions; update canonical declarations and add Stable notes including Preview 2026.9.51 since Stable 2026.9.50.
- [ ] Commit and run `python3 scripts/release/release.py package stable` then `python3 scripts/release/release.py publish stable`.
- [ ] Verify signed artifact, GitHub full release and Stable feed; close the resolved issue and retain concise release evidence.

## Investigation evidence

- Initial main commit: `1337dfe6d` (Stable 2026.9.50); clean checkout before this task.
- GitHub had one open issue, #34. Its checksum rejection was introduced in `49752921b` on 2026-08-18.
- Release Doctor reports package and publish readiness; Xcode 27.0, Swift 6.4, SDK 27.0.
- Source micromamba SHA-256 matches the upstream pin; sanitization and signing transform the bytes in app packages.
- Ordinary `CondaManager.ensureMicromamba` follows a separate path from the updater, explaining why installed tools can continue to work.
- Initial focused Python release smoke, identity, and note-preflight checks: 32 tests passed.
- Design decision: preserve upstream pin; accept a separately pinned deterministic ad-hoc packaging output for Debug, and verify signed release resources against their enclosing Developer ID application. Reject arbitrary mismatches and stage replacement before atomic publication.

- Signed 2026.9.48 actual CLI reproduces the exact incident checksum; retained evidence: `build/issue34-evidence/signed-bootstrap-audit.md`.
- Mandatory artifact smoke now isolates and applies bootstrap reconciliation, verifies installed bytes/version/receipt/provenance, and requires an empty subsequent plan. Independent smoke review is clean.
- Native Security API independently accepted signed Lungfish resource with its embedded CLI context and rejected unrelated executable context.
- Dependency pin/bundling tests: 60 passed. Test catalog/gate selection checks: 23 passed.

- Final independent review: no blocking findings. Signature context bound to running app, staged version check, and replacement metadata corrected during review.

- Preview package exposed the existing quick/release filter equality contract. Both profiles now include dependency reconciliation; independent one-line review approved, and all 71 focused release Python tests pass. Exact-commit unit qualification is rerun after this configuration correction.

- Preview v2026.9.51 published and independently verified at `6298619d8177a44e31955553706fc1fcb36f2643`, build 5441. Both app and DMG notarization accepted; actual final signed-app bootstrap reconciliation passes. Beta feed and legacy Alpha bridge verified by the coordinator.

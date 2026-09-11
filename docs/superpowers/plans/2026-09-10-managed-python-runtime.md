# Managed Python Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Install and positively identify a pinned native Apple Silicon PrimalScheme3 runtime through the optional pack manager.

**Architecture:** Add a typed Python-runtime manifest contract separate from source overlays. Existing conda installation supplies Python/pip/native primer3-py; a wheel-only hash-locked pip stage installs the remaining complete dependency set. A receipt binds requested identity, actual packages/files/commands/probes to readiness and reconciliation. No biological input is run by installer.

**Tech Stack:** Swift, existing CondaManager/PluginPackStatusService, CryptoKit, pip wheel installer, manifest JSON/resource lock, XCTest.

**Spec:** Approved PCR architecture and parent authorized pinned hybrid runtime on 2026-09-10; package research under .build/primalscheme-runtime-research.

## Global Constraints

- Work only .worktrees/pcr-primer-design branch codex/pcr-primer-design. No commits/pushes. Root owns GUI; sibling owns Primer3 workflow. Coordinate all Swift runs.
- Official tool is primalscheme3 version3.3.0, executable primalscheme3, GPL-3.0. Legacy Bioconda primalscheme1.4.1 must not be substituted.
- Python3.12 ARM native conda primer3-py2.3.1 supplies unavailable PyPI ARM wheel. All other wheel versions/hashes are fixed by supplied resolved requirements file. No source builds, arbitrary shell hooks, global/user pip installs or unpinned fallback.
- No biological execution/fixtures, viral patches, custom algorithm work. Smoke commands only installed version/help and pip dependency checks.
- Every recorded tool/install action must be truthful. Receipt absent/invalid means not ready; don't mark success after partial pip failure or silently preserve a stale old receipt. Do not remove a pre-existing environment on failure.

### Task 1: Typed Python overlay and readiness

**Files:**
- Modify Sources/LungfishWorkflow/Conda/PluginPack.swift (new runtime property/manifest derivation and PrimalScheme3 requirement beside frozen Primer3 entry).
- Modify Sources/LungfishWorkflow/Conda/ManagedToolLock.swift (typed optional pythonRuntime metadata).
- Modify Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift (install/status/fingerprint integration).
- Modify Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json (PrimalScheme3 identity and base conda pins).
- Create Sources/LungfishWorkflow/Resources/ManagedTools/primalscheme3-osx-arm64-py312-requirements.txt (copy verified resolver output; exact hashes, no runtime re-resolution).
- Create Sources/LungfishWorkflow/Conda/ManagedPythonRuntimeInstaller.swift and focused receipt/type file if useful.
- Modify relevant registry/status/request-spec/reconcile tests and add Tests/LungfishWorkflowTests/ManagedPythonRuntimeInstallerTests.swift.

**Interfaces:** New public Codable/Sendable Python runtime specification attached optionally to PackToolSpec and PackToolRequirement; includes distributionName/version, Python ABI/platform, basePackageSpecs, bundled requirements resource name and SHA256. Canonical per-runtime receipt stores complete requested identity, runtime conda records, installed distribution version/file inventory hashes/sizes, executed commands/exit codes/timing/stderr and version/help probe. Exact names finalized by implementer and sent before shared integration edits.

- [x] Step1: Inspect existing source overlay/status/reconciliation seams; send exact type signatures/file list. Use supplied .build/primalscheme-runtime-research/requirements.txt from successful wheel-only uv solve excluding primer3-py (fulfilled by conda). Confirm base spec pins from controller research. Write tests for manifest decode/default compatibility, invalid/missing hash/platform, requested spec roundtrip and mismatch readiness.
- [x] Step2: Coordinated RED tests use fake downloader/runner/filesystem fixtures only. Missing/tampered receipt/wheel/installed file, failed pip/version probe/cancellation must not yield ready. Test repeated evaluation cannot confuse base Python version with PrimalScheme3 version.
- [x] Step3: Add optional model property and fromManifest uses runtime basePackageSpecs; preserveExistingInstall prevents conda-only reconciler clobbering the mixed runtime; require receipt for matching identity. Status cache fingerprints receipt and inventoried files. Keep existing source overlay behavior intact.
- [x] Step4: Implement installer with exact environment bin/python and isolated invocation (`-I -m pip --isolated`), wheel-only hash-checked download then offline no-deps install of complete supplied wheel set, and dependency/version/help probes. No arbitrary build commands. Validate all receipt paths remain environment-relative and never follow user-supplied traversal. Downloaded artifact inventory and complete command record retained; publish receipt only after success. Invalidate prior receipt before mutation, retain incomplete environment for explicit repair on failure.
- [x] Step5: Add optional pack PrimalScheme3 requirement using installed executable primalscheme3 and version smoke. No claim stock3.3.0 supports custom uncovered-end modifications. Verify registry exposes both tools independently and all pins live manifest/resource files. Update exact expectations affected by new active pack.
- [x] Step6: GREEN relevant installer/status/registry/request-spec/reconcile tests under shared Swift lock. Controller independently performs native isolated installation/help-version check with no scientific input. Report exact executed evidence and limits.
- [x] Step7: Astra reviews immutable full diff/report; fix real findings, root final integration. Update plan/ledger, no commits.

## Completion evidence and plan adjustments

Completed implementation and Astra/root review on 2026-09-10 CDT. Final coordinated `.build/primer-design-integrated-10.log`: 173 XCTest cases, one intentional live-installer skip, zero failures; 65 Swift Testing cases, zero failures. The live production runtime installer passed in earlier integrated runs. Root release-contract checks: 52 Python tests passed. No source changes followed this verification.

The checkboxes record completed task outcomes, not a claim that every originally proposed command ran in its planned order. Tests were authored before implementation; early coordinated RED attempts were blocked by unrelated compilation/fixture errors. Actual behavioral failures were retained in integrated logs and fixed before final GREEN. Source freezes were coordinated with root. Primal-specific mid-run cancellation injection was not added; cancellation uses the established runner and propagated task cancellation, while Primer3/runtime cancellation tests ran.

The user subsequently authorized actual human/macaque MHC CLI verification. Twelve genuine genomic inputs were aligned through the existing CLI. Eighteen PrimalScheme3 workflows passed; final Primer3 conserved runs returned 60 pairs across twelve inputs, plus a three-template internal-oligo run with 15 pairs and 15 internal oligos. Original failure results remain preserved. See `docs/features/pcr-primer-design-validation.md` for source hashes, commands, artifacts and limits. No biological performance claim is inferred.

The previous Sol viewer worker was reassigned after spawning another thread was rejected by the four-thread limit. Astra reviewed its full output independently. Native ARM runtime uses pinned conda Python/pip/primer3-py and thirty complete hash-locked wheel distributions. Offline installation force-reinstalls pins, then checks dependencies and records all installed distributions/files. Receipt readiness validates exact pins/ABI, safe identifiers, hashes and ancestor paths; no source-overlay or legacy primalscheme substitution.

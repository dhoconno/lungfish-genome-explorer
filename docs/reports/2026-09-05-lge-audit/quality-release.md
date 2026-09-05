# Test quality, release, and dependency audit — 2026-09-05

Read-only assessment of the current checkout. This report changes no production code, tests, configuration, release assets, or installed dependencies. Release authority was read from `.codex/skills/releasing-lungfish/SKILL.md`, `config/release-contract.json`, `SKILLS.md`, `.codex/agents/release-agent.md`, current release documentation, CI, and nightly scripts. Historical reports were investigation leads, not evidence of current behavior.

## Assessment

The release architecture has substantial safeguards: local channel gates precede packaging; publication verifies the exact candidate before credentials; recovery reuses the candidate; final checks independently verify signatures, staples, Gatekeeper, immutable release identity, and remote asset digests. The most urgent defects are below those safeguards: the test gate can turn an incomplete/crashed run green, and exported Conda lockfiles do not preserve the runtime they purport to reconstruct. Neither a high test count nor an artifact receipt compensates for those defects.

Current static inventory: 1,054 Swift files under `Tests`, 462,862 lines, 14,215 `func test...(` declarations, and 18 SwiftPM test-target declarations. These are text counts, not executed test counts or coverage percentages. Parameterized Swift Testing, conditional compilation, skips, helpers, and Xcode-only tests make runtime counts different. Nine Swift files still contain explicit `source-text:` markers; this is not an exhaustive count of source-inspection tests.

## Prioritized findings

### QR-01 — P1: isolated retry can conceal an incomplete or crashed authoritative gate

**Evidence:** `scripts/full-suite-gate.sh:268–274` starts retry whenever there are parsed XCTest failures, no parsed Swift Testing failures, and 1–12 failing classes. It does not require a complete initial run or distinguish an assertion exit from a process crash. At `:319–322`, successful class retries clear both `xctest_fail` and the original runner `status`. The gate then returns success at `:329–338`.

**Reproduced:** Extracted the actual `count_xctest_failures` and `run_gate` functions without changing their bodies. A fake first runner wrote one failed XCTest case plus `Segmentation fault: 11` and returned 139. The isolated retry wrote a passing one-test summary and returned 0. The gate returned 0 and printed `GATE PASS ... flaky under load, passed isolated serial retry`. No Swift build or real test execution was involved; this validates gate control flow, not an observed production test crash.

**Scenario:** A suite fails one case and later crashes before remaining classes execute. Retrying that one class succeeds. Stable packaging can accept the gate even though the rest of the suite never completed. A deterministic test-order/shared-state regression can also disappear in isolation; the current comment that deterministic failures necessarily fail in isolation is too strong.

**Remediation:** Preserve original process outcome and completion evidence. Retry only explicitly classified assertion failures from a completed run. Crashes, signals, build failures, missing harness completion, and unexpected infrastructure exits must remain failures. Keep retry results separately from the first-pass verdict. For Stable, require a clean selected rerun under its original execution conditions or a documented, narrowly scoped quarantine policy with owner and expiry.

**Acceptance:** Fake-runner tests cover assertion-only retry, exit 139 after failure, incomplete summaries, build failure plus earlier failure text, order-dependent failure, retry failure, and interrupted execution. None of the incomplete/crash cases can authorize a candidate.

### QR-02 — P2: zero selected tests / empty runner output can pass

**Evidence:** `scripts/full-suite-gate.sh:329–337` checks exit status and failure/skip counts but never requires a positive executed-test count or completed test summary. Missing totals are rendered as the harmless-looking word `suite`.

**Reproduced:** With the same extracted functions, a fake runner returning zero with an empty log produces `GATE PASS (audit) - suite` and exit 0.

**Scenario:** A renamed suite no longer matches a conformance regex, an incorrect surface filter selects nothing, or a runner exits successfully without expected harness output. The intended verification becomes inert. This is a fail-open property of the wrapper; no claim is made that current Stable selects zero tests.

**Remediation/acceptance:** Record discovered selections and completed test counts; fail empty selections, missing expected harness completion, and missing required suite families. Test renamed/empty selections and a legitimate single-test selection. Prefer a machine-readable result over adding more loosely coupled text regexes.

### QR-03 — P1: Conda lock export/import loses environment, platform, and source-build identity

**Evidence:** `Sources/LungfishWorkflow/Conda/CondaLockfileService.swift:39` defaults to both `osx-arm64` and `linux-64`; `:157–173` copies the same parsed package/build into both platforms, serializes only `requirement.installPackages.first`, and writes empty dependencies. It does not serialize original environment names or source overlays. The parser at `:186–217` recognizes name/version/build only and deduplicates by name, ignoring platform, channel, and other lock metadata. Installation at `:93–104` uses the package name as the environment name and requests a new solver installation from the reduced spec.

**Concrete current examples:** The managed manifest at `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:50` defines Bracken through a checksummed source archive plus Python, compiler, and OpenMP toolchain packages. `Conda/PluginPack.swift:262–273` deliberately exposes all toolchain packages and the source overlay. The lock exporter records only the first package (Python), loses the compiler/OpenMP and Bracken source payload, and cannot reconstruct Bracken. The manifest's BBTools requirement uses environment `bbtools` and package `bbmap` (`:10`); the importer changes the destination environment to `bbmap`. Architecture-specific builds from one platform are repeated under another platform without solving for it.

**Test weakness:** `Tests/LungfishWorkflowTests/CondaLockfileServiceTests.swift:22–72` names its test “CondaLockCompatible” but asserts only substrings and sidecar existence. It does not prove external lockfile compatibility, installed payload parity, multi-package requirements, overlay preservation, or environment round-trip fidelity.

**Remediation:** Define and enforce the actual lock contract. Persist per-environment, per-platform resolved artifact identities, channels/URLs/hashes, all required packages and source overlays; import exactly that identity. Reject unsupported/malformed lock variants rather than silently discarding metadata. If the intended artifact is a requested-spec manifest, label it accordingly and do not present it as a reproducible resolved lock.

**Acceptance:** Round-trip BBTools with environment unchanged; reconstruct Bracken with all toolchain inputs and archive digest; reject a Linux build on arm64; select the proper platform in a multi-platform file; reject empty/malformed locks; verify installed package inventory and source-overlay payload hashes against exported identity. If compatibility with another lock consumer is advertised, exercise that consumer in a bounded integration test. No tool installation or external compatibility check was performed during this audit.

### QR-04 — P2: authoritative Stable gates omit the Xcode UI target

**Evidence:** `config/release-contract.json:70–72` defines Stable as `full` and required-tools `conformance`. `scripts/release/release.py:1524–1550` executes these via `full-suite-gate.sh`; the latter invokes `swift test`. `Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme:39–54` contains the distinct `LungfishXCUITests` target. It is absent from `Package.swift`. CI's only Xcode invocation is a manually dispatched `build`, not `test` (`.github/workflows/ci.yml:119–124`). Searches of current release scripts, contract, and gate found no XCUI execution.

**Impact:** In-process AppKit/SwiftUI tests and CLI smoke checks do not exercise actual application launch, menu wiring, document interaction, or installation identity through XCUI. A broken application-level route can pass every currently configured release tier. The historical 2026-08-21 test report's claim that Stable includes an XCUI pass is no longer true of the current authority.

**Remediation/acceptance:** Add a small, explicitly owned Stable app interaction gate on an appropriate logged-in macOS runner, with launch, representative safe document open, menu action, and channel identity checks. Store its result with the candidate. Missing graphical access must be a visible blocker or explicit scoped deferral, not a green empty run. Do not simply enable every historical UI test without measuring reliability.

### QR-05 — P2: gate evidence is not durably bound into the candidate receipt

**Evidence:** `ReleaseCoordinator.package` correctly calls gates before the builder (`scripts/release/release.py:269–275`). However, `scripts/release/release-candidate-receipt.py:496–535` records source, input hashes, toolchain, cache fingerprint, and artifact hashes but no gate command/result, counts, retries, skips, duration, dependency verification receipt digest, or log hash. Gate logs live in `.build/gate-logs` (`scripts/full-suite-gate.sh:69–75`); the coordinator's `run_local_gates` does not return structured evidence to the receipt writer.

**Impact:** A retained candidate proves its payload/source identity but does not independently explain which tests actually completed, whether it passed only after retries, or which installed runtime receipt supported testing. This is an auditability gap, not a claim that the supported coordinator skips its gates or that signatures are bypassable.

**Remediation/acceptance:** Put immutable per-gate results and hashed logs under the candidate, including exact argv, toolchain/runtime receipt hash, selected and executed counts, skips/retries, start/end/status. Bind their manifest digest into the candidate receipt. Candidate verification must reject missing/mismatched gate evidence. Keep this within the existing coordinator/receipt architecture; do not introduce a second release ledger.

### QR-06 — P2: database catalog pins labels/URLs without expected payload digests

**Evidence:** Static JSON inspection found 16 entries in the current `databases` section and zero with `sha256` or `md5`. `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:70` labels NCBI taxonomy `2025-03` while using the unversioned `.../pub/taxonomy/taxdump.tar.gz` path. `MetagenomicsDatabaseRegistry.swift:1183–1193` verifies against an expected archive checksum only when a digest exists. The implementation still checks required files and has checksummed install provenance (`MetagenomicsDatabaseInstallProvenance.swift:44`), which is valuable but different from verifying an approved input identity.

**Scenario:** Two installations using the same catalog/version can receive different bytes from the mutable taxonomy URL. Recording the received checksum can distinguish the outcomes afterward; it cannot make the original named dependency reproducible or reject a substituted but structurally valid archive.

**Remediation/acceptance:** Use immutable snapshot URLs and approved digests where available; otherwise explicitly model “live snapshot”, capture retrieval/version identity and retain a reproducible cached payload. Ensure release/conformance receipts identify the actual database hashes. A modified-but-valid archive must fail when a pinned database identity is requested. This assessment did not contact remote servers, establish current upstream contents, or allege a compromise.

### QR-07 — P2: PR/main CI offers no automatic Swift compilation or behavioral gate

**Evidence:** `.github/workflows/ci.yml:23–81` runs manifest consistency, shell syntax, and Python script tests automatically. `build-smoke`, `full`, and `toolset-conformance` are conditional on `workflow_dispatch` (`:87`, `:202`, `:255`). Release documentation expressly makes Actions advisory and local package tests authoritative.

**Impact:** A Swift compile error or behavior regression can receive a green push/PR workflow until someone runs local tests or packages. This is an intentional tradeoff, not a mismatch with the release contract. It creates delayed feedback and dependence on a release machine.

**Remediation/acceptance:** Keep local release authority; add an affordable automatic compile plus a small behavior smoke selection, or attach verifiable current-commit local results to review. Use historical timing before selecting the scope. Gate output must identify source commit and actual tests, and a deliberate Swift compile break must fail the relevant automated check. Do not return to the previous multi-hour redundant PR workflow.

### QR-08 — P2: CI's own dependencies are mutable

**Evidence:** `.github/workflows/ci.yml:37`, `:91`, and later jobs use major-version action tags; `:75–76` upgrades pip and installs unconstrained `Pillow openpyxl PyYAML`. Full/conformance install unconstrained scientific Python packages at `:243–247` and `:358–362`. Brew packages are also current rather than version-bound. In contrast, repository package locks, exact Sparkle pin, managed tool build specs, and checksummed bootstrap/source payloads are real positive controls.

**Impact:** Re-running the same commit can change test-library behavior or fail for reasons unrelated to the code. Action-tag mutability is an additional supply-chain boundary. These observations do not establish any current vulnerable version or compromise.

**Remediation/acceptance:** Pin action revisions and test-tool dependency versions/hashes with a deliberate update path. Record Python/OS/tool identities in diagnostics. Align parity dependencies with the existing managed verification runtime where practical. Prove two fresh test-environment resolutions produce the same package inventory, and retain a scheduled dependency-update verification separately from pinned regression jobs.

### QR-09 — P2: recovery handles interrupted publication, but installed-client rollback has no demonstrated drill

**Evidence:** The documented supported recovery is re-running `publish` for the same current-HEAD receipt (`docs/release/sparkle-updates.md:14–18`). Build floors intentionally require increasing versions (`:159–163`). `scripts/release/build-notarized-dmg.sh:938–953` replaces mutable feed assets with `--clobber`, then publishes the selected appcast/notes and Preview bridge sequentially (`:1016–1036`). No bad-release withdrawal/forward-fix client drill was found in current release authority.

**Impact:** Transaction resumption is well designed, but does not demonstrate what happens after users install a correctly signed regression. Simply restoring a lower-build feed is not a tested remediation for already-updated clients. Sequential mutable feed replacement also allows temporary partial state during interrupted publication; existing same-candidate recovery helps complete it.

**Remediation/acceptance:** Add an operator runbook and test-channel drill for pausing promotion, preserving evidence, publishing a higher-build corrective release, verifying channel/legacy-client behavior, and checking data/schema compatibility. Make manual reinstall guidance explicit when required. Exercise failures between feed/notes/bridge updates. Avoid adding a dangerous arbitrary downgrade switch or weakening the monotonic build checks.

## Quality and complexity: retain the useful controls, replace weak evidence

* The current tier design already separates parallel unit work from serial shared-state suites. The old claim that every test runs serially is obsolete. `full-suite-gate.sh:102–109` documents the named hazard suites, and xUnit output is already enabled. Measure first-pass failures and timing before proposing test deletion.
* Source assertions are appropriate for genuinely static contracts such as CI/contract consistency, but weak evidence for dynamic scientific output behavior. For example, `Tests/LungfishAppTests/EsVirituProvenanceSourceTests.swift:38–52` checks literal call expressions and catch-block formatting; it cannot prove an actual final bundle contains hashes for the final stored files or that failure rolls back output. `IQTreeInferenceOptionsDialogTests.swift:64–76` explicitly documents its routing seam gap, while adjacent tests already inspect real view structure. Retire specific weak assertions when a better seam exists; do not add production wrappers solely to satisfy every cosmetic assertion.
* The coordinator, receipt verifier, cache identity, strict profiles, and staged signing are justified complexity because they enforce different trust boundaries. Prefer consolidating duplicated filter definitions and gate-result parsing inside this architecture over a broad rewrite.
* Root-agent validation during this audit ran `swift test --filter 'ProvenanceFileHasherTests|ProvenanceBuilderTests|ScientificFileExportProvenanceTests|ScientificCLIProvenanceCoverageTests'` and reported 32 XCTest plus 41 Swift Testing tests passing, with a 7.97-second incremental build (`/tmp/lge-audit-provenance-fresh.log`). Root separately reproduced conversion caller defects despite those checks. Those findings belong to the main report; they illustrate why utility/policy coverage does not substitute for actual command-output failure/overwrite scenarios.
* Do not repeat old claims that 18–22% of tests are redundant or that a particular number of lines can safely be deleted. This audit did not measure duplicate behavioral coverage, mutation sensitivity, or current whole-suite timing. Highest-value next measurements are first-pass flake rate, slowest executed suites, unexecuted required scenarios, and test selection emptiness.

## Positive release controls verified in source

* Contract separates Preview/Stable/Debug wrapper names, identifiers, feeds, and publishability. Exact current-source candidate identity is verified before credentialed continuation (`release.py:269–292`).
* Candidate receipt includes app payload digest, CLI/bootstrap identities, lock/contract/builder hashes, compiler identity and path-independent cache identity (`release-candidate-receipt.py:496–535`). Cache contents are not treated as candidate authorization.
* Independent post-publication verification invokes strict codesign checks, both staple checks, Gatekeeper, and actual packaged-tool smoke, then validates GitHub release identity and remote assets (`release.py:1788–1885`). This audit inspected those paths but did not exercise signing/notary/GitHub.
* Mutable feed replacement compares remote digest and size before uploading; immutable versioned assets use a separate non-clobber path (`build-notarized-dmg.sh:888`, `:938–953`).
* Nightly routes preparation through the Python coordinator; current operator contract excludes destructive pruning from release publication. Strict profile validation and tests guard ownership, symlinks, modes, and unsupported fields.
* Managed manifest includes tool build strings and checksums for bootstrap and source overlays, and database installation records received payload hashes. The remaining catalog pinning gap should be corrected without discarding that provenance work.

## Actionable sequence

1. **Gate trust first:** QR-01/02, followed by QR-05. Add fake-runner regression cases, preserve initial outcomes, require completed selections, bind gate evidence. Owner: release/test infrastructure. Completion: incomplete or empty gates cannot authorize a candidate.
2. **Runtime reconstruction:** QR-03 and QR-06. Define resolved lock and database snapshot contracts, then cover real environment/payload round trips and failure states. Owner: dependency/runtime subsystem. Completion: exported approved identities recreate the same environment/payload or fail explicitly.
3. **User-facing release coverage:** QR-04 and QR-09. Establish a narrow logged-in UI gate and documented higher-build corrective-release drill. Owner: app/release integration. Completion: retained evidence from one successful drill and injected interrupted-feed cases.
4. **Feedback and sustainability:** QR-07/08 plus test-quality measurements. Pin CI dependencies, select a measured automatic Swift check, consolidate filter authority, and replace the highest-risk source assertions with output behavior checks. Owner: developer infrastructure with subsystem owners. Completion: current-commit evidence and measured first-pass reliability, with no unsubstantiated coverage percentage.

## Executed validation and limits

* `PYTHONDONTWRITEBYTECODE=1 python3 -B .codex/skills/releasing-lungfish/scripts/validate.py --repo-root .` — PASS, reported compatibility with the current checkout.
* `python3 -B scripts/release/release.py --help` and `doctor --help`, `package --help`, `publish --help`, `debug --help` — all exit 0. These were help-only; no release/doctor operation was invoked.
* `PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest scripts.tests.test_release_contract scripts.tests.test_release_frontdoor scripts.tests.test_release_cache_fingerprint scripts.tests.test_release_artifact_receipt scripts.tests.test_full_suite_gate_tiers scripts.tests.test_ci_workflow scripts.tests.test_releasing_lungfish_skill` — **exit 1**, 118 tests reported in 124.343 seconds: 117 passed; the `test_ci_workflow` module failed to import because the ambient Python lacked `yaml`. No dependencies were installed. This is a validation-environment limit, not a discovered assertion failure in CI configuration. The ambient interpreter was Homebrew Python 3.14.6, not the pinned release verification runtime. Follow-up checked the already-present `/Users/dho/.lungfish-verify/parity-python/bin/python3` using `-B -c 'import sys, yaml; print(sys.executable); print(sys.version); print("PyYAML", yaml.__version__)'`; it also exited 1 with `ModuleNotFoundError: No module named 'yaml'`. Therefore the isolated CI-workflow module could not be rerun in that existing runtime without provisioning, which this audit did not perform. This does not establish release-conformance failure: the release contract's focused tests do not include that CI-workflow module.
* Static inventory and manifest counting were performed using Python standard library, plus bounded `rg`, `nl`, `sed`, and file reads. A clean `git status --short` was observed before report creation. No release/build/download/install command or Swift suite was run by this agent. Root's separate Swift evidence is attributed above.
* Two fake-runner gate reproductions both produced exit 0 as described in QR-01/02. The exact harness below extracts the actual gate functions, writes only disposable temporary logs, overrides sleep to avoid a delay, and never invokes Swift. Temporary files were removed automatically.

```python
from pathlib import Path
import os, subprocess, tempfile
s = Path('scripts/full-suite-gate.sh').read_text()
functions = s[s.index('count_xctest_failures() {'):
              s.index('\nif [ "$BG" -eq 1 ]; then')]
for scenario in ('zero_tests', 'crash_then_retry'):
    with tempfile.TemporaryDirectory(prefix='lungfish-audit-gate-') as d:
        setup = '''LOG_DIR="$AUDIT_TEMP"; LOG="$LOG_DIR/main.log"
STAMP=audit; SHA=audit; TIER=full; REQUIRE_TOOLS=0; PARALLEL=0
FILTER=""; SKIP=""; SWIFT_624_DEBUG_TYPE_WORKAROUND=0
sleep() { :; }
'''
        if scenario == 'zero_tests':
            stub = 'run_swift_test() { : > "$1"; return 0; }\n'
        else:
            stub = '''run_swift_test() {
if [ "$1" = "$LOG" ]; then
printf "Test Case '-[LungfishCoreTests.ExampleTests testA]' failed (0.1 seconds).\\nSegmentation fault: 11\\n" > "$1"
return 139
fi
printf "Test Suite 'Selected tests' passed\\nExecuted 1 tests, with 0 failures\\n" > "$1"
return 0
}
'''
        p = subprocess.run(['/bin/bash', '-c', setup + stub + functions + '\nrun_gate'],
                           env={**os.environ, 'AUDIT_TEMP': d},
                           text=True, capture_output=True, timeout=10)
        print(scenario, p.returncode, p.stdout, p.stderr)
```

No live signing credentials, remote release/feed contents, GitHub branch protections, installed-app update behavior, fresh dependency reconstruction, or current upstream vulnerabilities were inspected. There is no claim of release readiness, measured line/branch coverage, whole-suite pass, byte-reproducible builds, or end-to-end rollback success.

# Build-performance architecture audit — 2026-09-05

Read-only inspection of source and the in-progress 00ca859472e08232334e9cce49321749b29cb835 preview package. No build, credentials, publication, cache deletion, or source mutation performed.

## Observed cost and build graph

Actual current run evidence is `.build/gate-logs/release-01lf_ff5/` and `.superpowers/sdd/2026-09-05-preview-release/package-preview-00ca8594.log`:

| Phase | Observed wall time | Evidence |
| --- | --- | --- |
| Python release contracts, 269 cases | 644.27 sec | python/gate.result.json |
| Swift unit gate | 312.70 sec | swift-0/gate.result.json timestamps |
| Swift integration gate | 245.18 sec | swift-1/gate.result.json timestamps |
| Xcode Release archive | ~12 min, coordinator observation; precise wall time not in inspected text | ARCHIVE SUCCEEDED at log line 16291 |
| SwiftPM Release CLI | still running when inspected | fresh production build after archive; ~590 operations |

These do not establish a six-hour single-build duration. Earlier attempts, repeated gates, packaging/signing waiting, and failures must be attributed separately. Host uses Xcode 26.6 17F113, Swift 6.3.3, SDK 26.5, arm64.

Current package graph: source/doctor → Python contracts → Swift unit → Swift integration → second doctor → Xcode Release GUI archive → SwiftPM Release CLI → bundle/portability/smoke/receipt. `release.py:run_local_gates` serializes every gate. Unit already runs parallel; integration explicitly does not. `gate_evidence.py:run_swift_gate` already discovers XCTest with a build, discovers Swift Testing using `--skip-build`, and executes tests with `--skip-build`. Do not characterize it as rebuilding once per test. It does repeat discovery/build planning for each tier.

`build-notarized-dmg.sh:1239–1274` builds GUI via Xcode, then CLI via SwiftPM in different intermediates. Both depend on Core/IO/Workflow and its large Containerization/NIO/gRPC dependency graph; shared sources cannot reuse object files across these distinct build systems/settings. The log visibly starts a new production dependency compilation after successful archive. GUI archive disables its embedded CLI shell build, so this is two builds rather than three.

`build-app.sh:155–183` uses one incremental SwiftPM Debug build that produces both executable products, then reassembles and checks a self-contained app. It cleans only final app, not compiler intermediates. Debug therefore already has a suitable single graph and -Onone; making Debug optimized would hurt iteration and debugging. Xcode project Debug has -Onone, Release -O, arm64 archive.

`release_cache_fingerprint.py:RECIPE_PATHS/build_fingerprint_document` gives secure owner-only serialized path-independent compiler namespaces, but fingerprints whole release-contract.json plus receipt, packaging, smoke, and security recipes. Thus policy-only/signing-only changes select a cold compiler namespace. Debug/gates use checkout .build; Release uses separate private SwiftPM/DerivedData. Source commit is correctly not a compiler namespace key; compiler dependency tracking owns incremental source invalidation. Receipts separately bind exact source/artifact identity.

## Recommended minimal implementation sequence

1. Add phase timing to coordinator `SubprocessRunner.run`/package orchestration: monotonic wall seconds, UTC start/end, argv, phase, cache key, logs, exit code. Include lock-wait/build/test/bundle/sign/notary durations separately. Persist metrics even on failure. Print elapsed progress with phase name. Do not infer build time from last output or summed per-task CPU durations.
2. Split compilation identity from release-policy authority. Version cache schema; hash toolchain/SDK/architecture/deployment/configuration, Package locks/manifest, project build settings, actual compile/prefix-map recipe only. Retain full contract and recipe hashes in candidate/gate receipts and validation. Keep repository key, owner validation, locking, no hidden pruning. Avoid simply removing the entire build shell hash without replacing it with an explicit versioned compile recipe, or compiler-flag changes would be missed.
3. Compile/discover tests once per package invocation, save an inventory and test-product identity, execute logical groups with `--skip-build` from that validated build. Interface `prepare_test_build(context) -> TestBuildEvidence`; `run_test_group(context, build_evidence, group) -> GateResult`. Evidence must bind source, toolchain, resolved options, executable hashes, inventory and group membership. Existing command/result integrity and nonempty selection checks stay intact.
4. Run independent Python release contracts concurrently with Swift preparation/headless gates after auditing Python tests for real checkout/.build mutations. Do not concurrently launch two SwiftPM builds using the same scratch directory; use one build followed by test execution. Keep filesystem/preferences/tool integration groups serialized until isolation is demonstrated. Unit is already parallel, so merely adding --parallel globally is not a sound fix.
5. Remove the Release GUI/CLI duplicate graph with a native Xcode CLI executable target in the same archive dependency graph. Target sources from Sources/LungfishCLI, link package products Core/IO/Workflow/ArgumentParser, arm64/macOS 26, matching optimization flags. Add target dependency and a copy-files phase into app Contents/MacOS; remove the SwiftPM-in-shell embed build and builder's separate SwiftPM CLI build. CLI remains headless and keeps entitlements at final signing. This preserves established xcarchive, asset catalog, Sparkle framework, signing, and receipt semantics. Before adopting, verify Xcode really compiles each shared package target once in Build Timeline and CLI resource lookup works inside relocated app. Native target resource accessor behavior and package target visibility are implementation checks, not assumed solved.
6. Alternative if native CLI target proves awkward: generalize existing SwiftPM Debug assembler to Release, build both products once, preserve optimized configuration, resource copying, framework embedding, archive metadata, dSYM and receipt contracts. This removes more Xcode behavior and has greater artifact-parity risk, so it is not the first minimal change. Do not run Xcode and SwiftPM builds in parallel as the final architecture: that only overlaps duplicate work and can increase memory pressure.
7. Keep operator `debug` fast/incremental/ad-hoc/self-contained with relocation checks. Release preview/stable remain optimized. A performance diagnostic build is a separate explicit profile, not an excuse to run optimized compilation or UI suites during everyday Debug. Disable indexing only for headless release/test compiler paths after confirming no consumer needs it; do not disable developer indexing globally.

## Concrete interfaces/files

- `scripts/release/release.py`: `BuildContext` with configuration, toolchain, cache namespace, job budget; timed phases; shared test preparation and bounded concurrency.
- `scripts/release/gate_evidence.py`: preparation/inventory artifact and `--prepared-build` internal option; retain exact completion/skip/failure validation.
- `scripts/release/release_cache_fingerprint.py`: versioned compiler-input recipe, independent of test/publish policy. Corresponding tests assert policy-only changes preserve compiler namespace while compile flags/locks/toolchain changes invalidate.
- `Lungfish.xcodeproj/project.pbxproj` and shared scheme: native CLI target and copy dependency, remove recursive SwiftPM script; app/CLI archive product provenance remains explicit.
- `scripts/release/build-notarized-dmg.sh`: one archive compile phase, validate embedded CLI, existing bundle/sanitize/portability/signature pipeline. Retain unsigned receipt authorization; cache never authorizes reuse.
- `scripts/build-app.sh`: retain current incremental Debug approach; share declarative compile settings and record build timing, avoid expensive tool payload recopy only if measured material and output correctness is validated.

## Benchmark acceptance plan

Use an isolated developer checkout after current release finishes; do not clear active caches or benchmark concurrently with release. Capture baseline and proposed build on same hardware/toolchain/resource payload. Scenarios: cold build with fresh private namespace, no-change warm rebuild, one leaf Swift method edit, one Core API edit, policy-only contract edit, compiler-flag edit. At least two warm repetitions; report wall time, max RSS, total compile operations, lock wait, test discovery/execution separately and resource copying time. Compare native Xcode one-graph build against current dual graph. Add -showBuildTimingSummary/result bundle for archive; optionally explicit jobs budget only after measuring memory/CPU effects. Target reductions are hypotheses, not promises.

Correctness acceptance: both executable architectures/configurations match; `--version` and representative benign CLI smoke succeed from relocated app; no checkout/.build references; resource bundles and Sparkle nested executables present; unit/integration selection coverage unchanged; provenance tests still block missing scientific provenance; receipts bind final payload; signing/notary tests remain independent. Assert shared dependencies compiled once per Release graph. Never run UI app launches in personal account for this benchmark.

## Primary-source support (reviewed 2026-09-05)

- Apple, Improving the speed of incremental builds: explicit script inputs/outputs permit dependency skipping; consistent compile options aid module reuse. https://developer.apple.com/documentation/Xcode/improving-the-speed-of-incremental-builds
- Apple, Xcode 26 release notes: compilation caching reuses compilation results for equivalent source inputs. Feature is relevant for measurement; do not assume enabled/hit merely because DerivedData persists. https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes
- SwiftPM official SwiftBuild docs: jobs controls concurrent build tasks; scratch path controls intermediates. https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftBuild.md
- SwiftPM official SwiftTest docs: --skip-build, --parallel, --num-workers and scratch/configuration options support preparation then controlled execution. Installed toolchain capability still requires checking before implementation because main documentation may be newer. https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftTest.md

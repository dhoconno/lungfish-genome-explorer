# Mapping Viewer Publication Materialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish mapping viewer bundles whose declared reference payloads materialize correctly on APFS and ExFAT and whose final result/provenance paths remain correct.

**Architecture:** Preserve secure no-follow publication, descriptor identity checks, and witness-gated rollback. Keep recursive clone materialization as the APFS fast path, but recover from its ExFAT AppleDouble `EEXIST` collision by deleting only the partial destination and retrying once with data/stat/no-follow flags. For first-time root publication only, reuse `PortableExclusiveRename` when ExFAT rejects native `RENAME_EXCL`; leave `RENAME_SWAP` replacement semantics native and unchanged. Exercise deterministic seams and the real preparer/importer/publisher/AppDelegate pipeline.

**Tech Stack:** Swift 6.2, Foundation, Darwin `copyfile`, XCTest, Lungfish bundle/provenance services.

---

### Task 1: Establish the real-service regression (RED)

**Files:**
- Modify: `Tests/LungfishAppTests/MappingViewerBundlePreparerTests.swift`
- Modify or create a focused integration test under: `Tests/LungfishAppTests/`

- [ ] Build a small source `.lungfishref`, small valid BAM/BAI fixture, analysis directory with `MappingResult`, `MappingProvenance`, and canonical provenance, then call the real preparer, real `BAMImportService`, and real publisher exactly as the app flow does.
- [ ] Assert publication succeeds; the final bundle exists; declared manifest/reference/BAM/index/import-provenance paths contain no symlink component; mapping-result and mapping-provenance link to the final viewer; final manifest opens; final reference and BAM/index can be read; and provenance descriptors contain final paths with matching checksums/sizes.
- [ ] Run the focused test before production edits. Expected: FAIL at `invalidViewerPayloadPath("genome/sequence.fa.gz")` (or an assertion exposing the preparer's top-level symlink).

Run:

```bash
swift test --filter '<new integration test name>'
```

### Task 2: Materialize referenced payloads with clone-or-copy fallback (GREEN)

**Files:**
- Modify: `Sources/LungfishApp/Services/MappingViewerBundlePreparer.swift`
- Modify: `Tests/LungfishAppTests/MappingViewerBundlePreparerTests.swift`
- Update only directly affected symlink-assumption tests in: `Tests/LungfishAppTests/MappingViewerBundleFetchTests.swift`, `Tests/LungfishAppTests/MappingViewerScaffoldSmokeTests.swift`, and `Tests/Support/LungfishTestSupport/MappingViewerScaffold.swift` if required.

- [ ] Replace symbolic-link-first behavior with recursive `copyfile` materialization using clone-best-effort plus normal-copy fallback semantics. Destination entries must be independent, non-symlink filesystem objects. Preserve source bundle data and manifest selection semantics.
- [ ] Update the preparer unit test to assert real materialized objects and byte-identical payloads. Keep the publisher's explicit symbolic-link rejection test unchanged and passing.
- [ ] Run the new integration test and affected suites. Expected: PASS.

Run:

```bash
swift test --filter 'MappingViewerBundlePreparerTests|MappingViewerBundlePublicationIntegrationTests|MappingViewerBundleFetchTests|MappingViewerScaffoldSmokeTests|MappingViewerBundleProvenanceFinalizerTests'
```

### Task 3: Independent review and end-to-end verification

**Files:**
- No production edits unless review identifies a concrete defect.

- [ ] Sol reviews the entire diff for scope, no-follow security, source/destination race handling, clone fallback behavior, large-file implications, cleanup, provenance final paths/checksums/sizes, and test realism.
- [ ] Run focused tests, relevant broader app tests, and `swift build --product Lungfish` from a clean-enough worktree state.
- [ ] Run the strongest available mapping app/integration/XCUI reproduction with a small nonduplicated reference. Verify final viewer attachment, manifest, BAM/index, and reference access. Record exact limitations if full GUI automation is unavailable.
- [ ] Commit only after review and fresh verification; do not merge or push.

### Task 4: Add deterministic ExFAT collision regressions (RED)

**Files:**
- Modify: `Tests/LungfishAppTests/MappingViewerBundlePreparerTests.swift`

- [ ] Add an injected materialization test that supplies a closure with this narrow shape:

```swift
typealias CopyFileOperation = (
    _ sourcePath: String,
    _ destinationPath: String,
    _ flags: copyfile_flags_t
) -> Int32
```

The closure must record every call. On call one it must assert `COPYFILE_RECURSIVE | COPYFILE_CLONE`, create a partial destination containing a marker, and return `EEXIST`. On call two it must first assert that the destination and partial marker are absent, assert exactly `COPYFILE_RECURSIVE | COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC`, copy/create the complete synthetic payload, and return zero. After materialization, assert exactly two calls, no marker, and the complete payload.

- [ ] Add a second injected test whose first call returns a non-`EEXIST` errno such as `EACCES`. Assert that the thrown `POSIXError` retains that code, the closure was called once, and there was no retry.

- [ ] Run only the new tests before touching production. They must fail to compile or fail because the injectable materialization seam and retry do not exist; preserve this RED output for review.

Run:

```bash
swift test --filter 'MappingViewerBundlePreparerTests/testMaterializeItemRetriesWithoutXattrsAfterCloneEEXIST|MappingViewerBundlePreparerTests/testMaterializeItemDoesNotRetryNonEEXIST'
```

### Task 5: Implement the one-shot no-xattr fallback (GREEN)

**Files:**
- Modify: `Sources/LungfishApp/Services/MappingViewerBundlePreparer.swift`
- Modify only if RED setup needs correction: `Tests/LungfishAppTests/MappingViewerBundlePreparerTests.swift`

- [ ] Introduce only an internal/testable copy-operation alias and an internal materialization seam; keep `prepareBaseBundle` and all public API unchanged. The production default must call Darwin `copyfile`, return zero on success, and capture `errno` immediately on failure.
- [ ] Keep the first flags exactly:

```swift
copyfile_flags_t(COPYFILE_RECURSIVE | COPYFILE_CLONE)
```

- [ ] If the first result is `EEXIST`, remove only `destinationURL` (including a partial directory or symlink at that exact entry) and retry exactly once with:

```swift
copyfile_flags_t(
    COPYFILE_RECURSIVE
        | COPYFILE_DATA
        | COPYFILE_STAT
        | COPYFILE_NOFOLLOW_SRC
)
```

Do not retry another errno. Do not retry a cleanup failure. Convert a nonzero fallback result to its corresponding `POSIXError` and do not leave a second recovery loop.

- [ ] Run the focused tests and confirm GREEN, then run all `MappingViewerBundlePreparerTests`.

Run:

```bash
swift test --filter MappingViewerBundlePreparerTests
```

### Task 6: ExFAT, integration, build, and app-owned verification

**Files:**
- Modify if a durable opt-in test is appropriate: `Tests/LungfishAppTests/MappingViewerBundlePreparerTests.swift`
- Modify for durable operator instructions: `docs/superpowers/plans/2026-08-17-mapping-viewer-publication-materialization.md`

- [ ] Run an isolated synthetic regression beneath a UUID-named directory created specifically under `/Volumes/AJL-T7`. Seed only synthetic files/extended attributes needed to generate the AppleDouble collision, invoke the real preparer, validate the complete copied hierarchy, and remove only that UUID-named test root with `defer`. If this depends too heavily on one mounted volume for the permanent suite, retain it as an opt-in XCTest or a documented one-line manual invocation guarded by an explicit volume-root argument.
- [ ] Run focused and prior regression suites:

```bash
swift test --filter 'MappingViewerBundlePreparerTests|MappingViewerBundlePublicationIntegrationTests|MappingViewerBundleFetchTests|MappingViewerScaffoldSmokeTests|MappingViewerBundleProvenanceFinalizerTests'
```

- [ ] Run broader relevant app tests, then build both configurations:

```bash
swift test --filter LungfishAppTests
swift build -c debug --product Lungfish
swift build -c release --product Lungfish
```

- [ ] Launch the newly built debug app and exercise the normal mapping workflow on the AJL-T7 project, or invoke the strongest safe app-owned automation that executes the same `AppDelegate` workflow. Do not alter/delete failed runs. Record the new analysis path and verify structurally: final viewer bundle exists; `mapping-result.json` has the final `viewerBundlePath`; final manifest loads; BAM/index/reference/provenance paths exist; checksums and sizes match descriptors; and the display-success event is present.
- [ ] Sol reviews the complete code/tests/docs diff for the `EEXIST` guard, exact cleanup scope, APFS clone fast path, fallback flags, `COPYFILE_NOFOLLOW_SRC`, narrow first-publication `RENAME_EXCL` delegation, unchanged native `RENAME_SWAP`, error propagation, provenance, and test behavior. Require remediation/re-review for every blocking issue.
- [ ] After APPROVE and fresh verification, remove only the two synthetic diagnostic roots `.lge-copyfile-debug.QLk6rW` and `.lge-copyfile-debug-noxattr.G3M6zZ` beneath `/Volumes/AJL-T7/32506`; never remove a failed analysis. Commit all approved changes once. Do not merge or push.

### Task 7: Preserve first-time publication semantics when ExFAT rejects `RENAME_EXCL`

**Files:**
- Modify: `Sources/LungfishApp/Services/MappingViewerBundlePublicationService.swift`
- Modify: `Tests/LungfishAppTests/MappingViewerBundleProvenanceFinalizerTests.swift`

- [ ] Add a deterministic injected-rename RED regression. The native root rename must report `ENOTSUP` for `RENAME_EXCL`; the test must prove publication delegates to the existing `PortableExclusiveRename` reservation path, finalization runs against the final root, the final bundle exists, and the candidate is absent.
- [ ] Add or retain a focused assertion that `RENAME_SWAP` does not enter the portable exclusive fallback. Existing-bundle replacement stays native and returns the original unsupported failure on filesystems without swap support.
- [ ] Change only the root `RENAME_EXCL` operation to call `PortableExclusiveRename`. Do not add a new copy/rename fallback, do not change `RENAME_SWAP`, and do not weaken candidate/payload descriptor identity checks or result/provenance snapshot rollback.
- [ ] Run deterministic publication tests, including ownership-conflict, symlink, staged DB/JSON, finalization rollback, and concurrent-sidecar regressions.
- [ ] Run the opt-in isolated full-service test on `/Volumes/AJL-T7` with the existing reference bundle and BAM. Assert preparer, BAM import, first-time publication, final paths, provenance checksums/sizes, and exact temp cleanup.
- [ ] Rebuild the app and repeat the real AJL-T7 minimap2 mapping. Wait for workflow completion before selecting the new analysis, then require the final viewer path and `mapping.display.succeeded` event. Do not delete or modify prior failed analyses.

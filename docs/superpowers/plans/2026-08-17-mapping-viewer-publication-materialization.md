# Mapping Viewer Publication Materialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish mapping viewer bundles whose declared reference payloads are real files/directories and whose final result/provenance paths remain correct.

**Architecture:** Preserve secure no-follow publication and change only candidate construction. Materialize manifest-referenced top-level payloads with clone-or-copy semantics, then exercise the real preparer/importer/publisher pipeline in an integration regression.

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

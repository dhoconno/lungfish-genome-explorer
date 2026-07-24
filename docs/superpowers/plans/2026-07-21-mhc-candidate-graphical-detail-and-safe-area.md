# MHC Candidate Graphical Detail and Safe-Area Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an immediate, bounded graphical detail pane for `_nov` and `_ext` rows and keep the full-length genotype viewport below the project title.

**Architecture:** The asynchronous result loader will retain validated named-candidate FASTA records and index closest-reference visualizations by stable cluster ID. A persistent AppKit candidate detail view will reuse the reference overview renderer, add a small reference-relative difference track, and switch among preloaded Overview, closest-reference GenBank, and exact candidate FASTA content. The controller will mount this component once, while its top-level content uses the macOS safe-area guide.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, LungfishIO typed result artifacts, XCTest.

---

## Task 1: Retain and index bounded candidate presentation data

**Files:**

- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTMHCReferenceVisualizations.swift`
- Modify: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Modify: `Tests/LungfishIOTests/ONTMHCReferenceVisualizationTests.swift`

- [ ] **Step 1: Write failing loader and index tests**

Add a bundle-loader test whose candidate FASTA contains `>cluster-a\nACGT\n` and assert:

```swift
XCTAssertEqual(result.mhcCandidateSequencesByStableClusterID["cluster-a"], "ACGT")
```

Add visualization tests that assign `cluster-a` to one closest-reference role and assert O(1) stable-ID lookup. Add an ambiguity test where two records claim `cluster-a` and expect `ONTMHCReferenceVisualizationError.ambiguousCandidateStableClusterID`.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
swift test --filter ONTMHCReferenceVisualizationTests
```

Expected: compilation fails because the sequence and stable-ID indexes do not exist.

- [ ] **Step 3: Retain only validated named-candidate sequences**

Extend `ParsedFASTA` with `sequencesByID: [String: String]`. While `StreamingFASTAParser` hashes a required record, retain its normalized uppercase bytes and materialize the string once at record completion. Return those strings through `MHCCandidateProjection` and add:

```swift
public let mhcCandidateSequencesByStableClusterID: [String: String]
```

to `ONTGenotypeResultBundleData`, with default `[:]` in compatibility initializers and normal coding support. Do not retain un-nameable sequences.

- [ ] **Step 4: Build and validate the stable-ID reference index**

Add derived `recordsByCandidateStableClusterID` to `ONTMHCReferenceVisualizationArtifact`. Build it from every role assignment's `candidateStableClusterIDs`; reject empty IDs and any ID assigned to two different raw references. Omit the derived index from encoded JSON.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the two commands from Step 2. Expected: both suites pass.

## Task 2: Correct the viewport top anchor

**Files:**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add the full-size-window regression test**

Create a titled/resizable/full-size-content `NSWindow`, attach a genotype-only controller, lay it out, and assert the search field's top edge is not above the controller safe-area top. Also assert `safeAreaInsets.top > 0` so the test proves the titlebar case.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testFullSizeContentKeepsFullLengthCandidateSearchBelowSafeAreaTop
```

Expected: the search field overlaps the safe area by the titlebar height.

- [ ] **Step 3: Anchor both top-level controls to the safe area**

In `layout()`, change only the anchor targets:

```swift
contentHostTopConstraint = contentHost.topAnchor.constraint(
    equalTo: view.safeAreaLayoutGuide.topAnchor,
    constant: isGenotypeOnlyResult ? 0 : 48
)
lensControl.topAnchor.constraint(
    equalTo: view.safeAreaLayoutGuide.topAnchor,
    constant: 8
)
```

Keep the existing genotype-only `0` and haplotyped `48` constants.

- [ ] **Step 4: Run the focused and surrounding layout tests**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testFullSizeContentKeepsFullLengthCandidateSearchBelowSafeAreaTop
swift test --filter GenotypeResultViewportTests/testGenotypeOnlyResultForcesSummaryMatrixListOverDetailViewport
swift test --filter GenotypeResultViewportTests/testOutlineLayoutLeavesViewportVisibleBelowQuickFilterBar
```

Expected: all pass.

## Task 3: Add the persistent candidate B2 detail component

**Files:**

- Create: `Sources/LungfishGenotypeUI/GenotypeCandidateAlleleDetailView.swift`
- Create: `Sources/LungfishGenotypeUI/GenotypeCandidateDifferenceTrackView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeKnownAlleleDetailView.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeCandidateAlleleDetailViewTests.swift`

- [ ] **Step 1: Write failing component tests**

Cover:

```swift
XCTAssertEqual(view.currentMode, .overview)
XCTAssertEqual(text("candidateAlleleName", in: view), "Mafa-A1*067:01_2nt_nov")
XCTAssertEqual(text("candidateStableClusterID", in: view), "cluster-a")
XCTAssertNotNil(descendant("candidateClosestReferenceOverview", in: view))
```

Switch to GenBank and assert the preloaded text is the closest-reference record. Switch to FASTA and assert the exact candidate sequence and deterministic support header. Reconfigure 100 times and assert descendant/constraint counts remain constant. Cover fallback when sequence or reference data is absent.

- [ ] **Step 2: Run the component suite and verify RED**

Run:

```bash
swift test --filter GenotypeCandidateAlleleDetailViewTests
```

Expected: compilation fails because the component does not exist.

- [ ] **Step 3: Implement bounded reference-relative difference parsing**

Parse the persisted extended CIGAR once per configuration into bounded `X`, insertion, and deletion markers using the 1-based `referenceStart`. Classify an `X` marker as exon 2/3, other exon, or intron/non-exon only from the closest reference's stored feature intervals. Draw the markers in a fixed-height track against reference coordinates and expose an accessibility summary. Never label synonymous/nonsynonymous or candidate exon/translation state from legacy data.

- [ ] **Step 4: Implement the B2 view**

Create a persistent header and `Overview / GenBank / FASTA` switcher. Overview stacks the existing `GenotypeKnownAlleleOverviewView` with the difference track and a fixed facts rail. GenBank and FASTA use read-only, selectable text views. Reuse narrowly extracted internal fact/text/comments helpers from the known view; do not expose private drawing lanes publicly.

- [ ] **Step 5: Run the component suite and verify GREEN**

Run the command from Step 2. Expected: all tests pass.

## Task 4: Wire candidate selection to indexed persistent detail

**Files:**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing viewport tests**

Add tests proving that candidate row/cell selection mounts exactly one `GenotypeCandidateAlleleDetailView`, resolves colliding provisional names by stable ID, preserves current highlight/matrix/comment selection state, and does not show one AppKit row per evidence locator. Repeatedly alternate candidates and assert the same component identity, descendant count, and active-constraint identities.

- [ ] **Step 2: Run candidate viewport tests and verify RED**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testCandidateSelectionMountsPersistentGraphicalDetail
swift test --filter GenotypeResultViewportTests/testRepeatedCandidateSelectionsReuseOneGraphicalDetail
```

Expected: no candidate graphical detail is present.

- [ ] **Step 3: Build presentation indexes at configuration time**

Index candidate observations and compact evidence facts by stable cluster ID when `configure(result:)` rebuilds result indexes. Retain only bounded display facts in the visible pane. Keep the existing bounded `GenotypeResultSelectionState.detailRows` contract for Inspector/highlight publication.

- [ ] **Step 4: Configure and mount the singleton detail view**

Resolve candidate sequence and closest reference exclusively by stable cluster ID, configure the persistent component, and mount it only when it is not already the sole arranged subview. Missing data invokes the component's bounded fallback, never the former evidence hierarchy.

- [ ] **Step 5: Run the viewport and known-detail suites**

Run:

```bash
swift test --filter GenotypeResultViewportTests
swift test --filter GenotypeKnownAlleleDetailViewTests
swift test --filter GenotypeCandidateAlleleDetailViewTests
```

Expected: all pass, including large-evidence memory regressions.

## Task 5: Build and guarded debug verification

**Files:**

- Modify only if tests reveal a scoped defect in the files above.

- [ ] **Step 1: Run focused IO and UI verification**

Run:

```bash
swift test --filter ONTGenotypeResultBundleTests
swift test --filter ONTMHCReferenceVisualizationTests
swift test --filter GenotypeResultViewportTests
swift test --filter GenotypeKnownAlleleDetailViewTests
swift test --filter GenotypeCandidateAlleleDetailViewTests
```

Expected: zero failures.

- [ ] **Step 2: Build the debug app**

Terminate the currently running worktree debug instance, then run:

```bash
scripts/build-app.sh --configuration debug
```

Verify the built bundle's display name/menu name is `Lungfish Debug` and its debug bundle identifier is distinct from the main app.

- [ ] **Step 3: Guarded real-bundle smoke test**

Launch the exact app path with `open -n`, open the 2026-07-21 four-sample result, select known and novel rows repeatedly, and monitor RSS with a hard upper bound. Verify the graphical candidate pane appears immediately, FASTA/GenBank switching is immediate, view count remains bounded, and the search field begins below the project title.

- [ ] **Step 4: Launch one clean debug instance for the user**

Terminate the instrumented process and launch exactly:

```bash
open -n -a /Users/dho/Documents/lungfish-genome-explorer/.worktrees/full-length-mhc-candidate-viewport/build/Debug/Lungfish.app
```

Report the exact app path, build commit, tests, and the intentional scientific boundary for consequence/translation projection.

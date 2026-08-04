# miSeq Synchronized Haplotype and Genotype Views Implementation Plan

> Execute this plan in the isolated `codex/zero-snp-candidate-resolution`
> worktree. Use test-driven development for every production change and commit
> each independently verifiable stage.

**Goal:** Haplotyped miSeq analyses open in Haplotype Calls, offer the same
full-length Genotype Matrix as the alternate presentation, and keep effective
haplotype calls synchronized through one atomic, audited, reproducible override
path.

**Architecture:** A result-scoped presentation policy owns the two-view state.
An immutable effective-haplotype projection resolves pipeline calls and valid
overrides once and feeds the outline, evidence, workbook snapshot, and a neutral
matrix header band. Both editors submit atomic mutation batches to the
annotation store, which publishes the sidecar and provenance together before
the controller refreshes or marks the workbook stale.

**Technology:** Swift 6, AppKit, SwiftUI hosting views, Swift Package Manager,
ArgumentParser, Lungfish annotation/provenance infrastructure, XCTest, Python
release-script tests, Xcode archive/sign/notary tooling, Sparkle.

## Task 1: Establish the result-scoped presentation policy

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeResultPresentationPolicy.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultPresentationPolicyTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`

**Red test**

Add table-driven tests for:

- typed miSeq + haplotyped mode + usable analysis => choices `Haplotype Calls`,
  `Genotype Matrix`, default `.outline`, normalized lens `.summary`;
- typed miSeq genotype-only => existing matrix-only policy;
- haplotyped non-miSeq and legacy kind-only bundles => existing policy;
- empty/duplicate-key analysis => matrix fallback with an explanation and no
  preference rewrite;
- stale Review/Audit ingress => normalized to Haplotype Calls;
- read-only bundles => session-only selection.

Run:

```bash
swift test --filter GenotypeResultPresentationPolicyTests
```

Confirm the tests fail because the policy does not exist.

**Implementation**

Create a value-semantic `GenotypeResultPresentationPolicy` with:

- applicability derived only from typed workflow kind, haplotyped workflow
  mode, manual-haplotype eligibility, and analysis usability;
- presentation choices and exact user-facing labels;
- `normalize(displayState:)`, `defaultSummaryViewMode`, and malformed fallback;
- Inspector/viewport accessibility help and read-only persistence policy.

Keep raw `outline`/`matrix` values for bundle compatibility. Do not globally
remove legacy lenses for other workflow kinds.

**Green test and commit**

```bash
swift test --filter GenotypeResultPresentationPolicyTests
git add Sources/LungfishGenotypeUI/GenotypeResultPresentationPolicy.swift \
  Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultPresentationPolicyTests.swift
git commit -m "Add miSeq result presentation policy"
```

## Task 2: Build one effective haplotype projection

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeProjection.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeProjectionTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`

**Red test**

Cover pipeline called/error/not-assayed values, zero/one/two overrides,
duplicate same-key overrides, malformed timestamps, stable tie-breaking,
ignored-but-preserved manual assignments, two samples, and two loci. Assert
per-slot value/source/status and locus reduction. Assert an
override of H1 never hides an unresolved H2.

Run:

```bash
swift test --filter GenotypeEffectiveHaplotypeProjectionTests
```

**Implementation**

Introduce immutable keys and values:

```swift
struct GenotypeEffectiveHaplotypeKey: Hashable {
    let sample: String
    let locus: String
    let slot: HaplotypeSlot
}

struct GenotypeEffectiveHaplotypeValue: Equatable {
    enum Source { case pipeline, analystOverride, staleOverride }
    let baseline: String
    let effective: String
    let status: GenotypeHaplotypeCallStatus
    let source: Source
}
```

Build indexes in O(calls + overrides), retain an ordered locus list, carry the
active analysis/definition identity, and expose sample/locus snapshots. Replace
controller helpers that repeatedly scan overrides with projection lookups.
Cache a projection generation and rebuild it only after result/definition or
successful override changes.

**Green test and commit**

```bash
swift test --filter GenotypeEffectiveHaplotypeProjectionTests
swift test --filter GenotypeResultViewportTests/testHaplotype
git add Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeProjection.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeProjectionTests.swift
git commit -m "Unify effective haplotype projection"
```

## Task 3: Add replayable atomic call-override mutations

**Files**

- Create: `Sources/LungfishIO/Bundles/GenotypeCallOverrideReplayPayload.swift`
- Create: `Sources/LungfishCLI/Commands/GenotypeReplayCallOverridesSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift`
- Modify: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeProjection.swift`
- Test: `Tests/LungfishIOTests/GenotypeCallOverrideReplayPayloadTests.swift`
- Modify: `Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift`
- Test: `Tests/LungfishCLITests/GenotypeCallOverrideReplaySubcommandTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreCallOverrideTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreReadOnlyTests.swift`

**Red tests**

Require a batch API whose one Save can change H1 and H2. Assert:

- both changes publish or neither does;
- one operation ID/timestamp, one audit per changed slot, one provenance
  envelope, and `didChange`/changed keys;
- a no-op restore publishes nothing;
- read-only rejection occurs before in-memory mutation;
- stale-revision, annotation-publication, and provenance-publication faults
  leave in-memory and durable bytes unchanged;
- replay reproduces the exact sidecar from recorded prior bytes and rejects
  mismatched prior state;
- legacy sidecars decode without identity fields, current sidecars encode an
  optional active analysis/revision/definition identity and one batch operation
  ID on related audit rows, and schema promotion does not rewrite on open;
- projections treat an identity mismatch as stale and never silently apply it;
- provenance contains the durable CLI argv, replay payload, sample/locus/slot,
  baseline/before/after/reason/rationale/author/analysis identity, resolved
  defaults, final paths, input/output checksums and sizes, runtime, status, and
  wall time.

Run:

```bash
swift test --filter GenotypeCallOverrideReplayPayloadTests
swift test --filter GenotypeAnnotationStoreCallOverrideTests
swift test --filter GenotypeAnnotationStoreReadOnlyTests
swift test --filter GenotypeReplayCallOverridesSubcommandTests
```

**Implementation**

Add `GenotypeCallOverrideReplayPayload` analogous to the manual-haplotype
payload. Add `lungfish-cli genotype replay-call-overrides`. Add store models:

```swift
struct CallOverrideMutation { /* target, baseline, after, reason, rationale */ }
struct CallOverrideMutationResult { let didChange: Bool; let changedKeys: Set<Key> }
```

Implement `mutateCallOverrides(_:author:analysisIdentity:)` by loading the
latest snapshot inside the publication coordinator, validating the entire
batch, deriving the complete next sidecar without touching observable state,
publishing annotation and provenance once, then swapping in-memory state only
after success. Keep `applyOverride`/`clearOverride` as compatibility wrappers
over one-element batches.

Extend `CallOverride` and its audit operation metadata with backward-compatible
optional analysis/revision/definition identity and batch operation ID fields.
Promote old schemas without changing their scientific meaning, then add the
identity-aware stale-override assertions to the projection tests.

**Green test and commit**

```bash
swift test --filter GenotypeCallOverrideReplayPayloadTests
swift test --filter GenotypeAnnotationStoreCallOverrideTests
swift test --filter GenotypeAnnotationStoreReadOnlyTests
swift test --filter GenotypeReplayCallOverridesSubcommandTests
git add Sources/LungfishIO/Bundles/GenotypeCallOverrideReplayPayload.swift \
  Sources/LungfishCLI/Commands/GenotypeReplayCallOverridesSubcommand.swift \
  Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift \
  Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift \
  Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift \
  Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeProjection.swift \
  Tests/LungfishIOTests/GenotypeCallOverrideReplayPayloadTests.swift \
  Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift \
  Tests/LungfishCLITests/GenotypeCallOverrideReplaySubcommandTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreCallOverrideTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreReadOnlyTests.swift
git commit -m "Make haplotype overrides atomic and replayable"
```

## Task 4: Generalize the matrix haplotype band without changing genotype-only behavior

**Files**

- Create: `Sources/LungfishGenotypeUI/GenotypeHaplotypeCallBand.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeHaplotypeCallBandTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Red tests**

Assert a neutral band supports dynamic ordered loci; separate H1/H2
value/status/source; “Haplotype Calls (N loci)” title; pipeline versus override
semantics; tooltip/accessibility labels; changed-sample invalidation; long-name
column sizing; text scaling; high contrast; click, keyboard, and AXPress target
selection. Preserve existing genotype-only manual-band snapshots and geometry.

Run:

```bash
swift test --filter GenotypeHaplotypeCallBandTests
swift test --filter GenotypeManualHaplotype
```

**Implementation**

Add band mode `none`, `manualAssignments`, or `effectiveMiSeqCalls`, plus a
neutral `setHaplotypeBand(mode:snapshot:)` seam that works both before and
after lazy matrix configuration. Reuse the
proven geometry, clipping, disclosure, and damaged-column machinery while
supplying neutral rows and hit targets. Replace hard-coded seven-row geometry,
accessibility, sizing, and test helpers with dynamic ordered loci for the
neutral mode while preserving the genotype-only seven-locus state. Add a typed
callback carrying sample, locus, and slot. Keep the existing manual editor
callback and data source only for genotype-only mode.

**Green test and commit**

```bash
swift test --filter GenotypeHaplotypeCallBandTests
swift test --filter GenotypeManualHaplotype
git add Sources/LungfishGenotypeUI/GenotypeHaplotypeCallBand.swift \
  Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeHaplotypeCallBandTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "Show effective miSeq calls in the genotype matrix"
```

## Task 5: Replace the miSeq viewport destinations and diagnostic matrix

**Files**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

**Red tests**

For an applicable result assert exactly two selector segments named Haplotype
Calls and Genotype Matrix, Haplotype Calls default, no Review/Audit/Review tab,
Inspector/viewport bidirectional selection without feedback loops, legacy
preference mapping, bundle isolation, stale-lens normalization, and matrix lazy
construction. Assert Matrix renders `GenotypeComparisonMatrixView`, raw known
and candidate rows with correct reads, and never routes to
`GenotypeHaplotypeDefinitionMatrixView`.

Also assert removed-lens functionality remains reachable from the detail pane,
Inspector, or toolbar: evidence and override editing, Confirm/flag/Skip/Next,
Needs Review cohort, Audit Timeline, workbook actions, artifacts, provenance,
AI haplotyping, and current-view export.

Add direct coverage for the old lens-dependent ingress paths: review keyboard
commands while a call is selected, the haplotype-definitions notification that
currently routes to Audit, stale lens notifications, and Inspector
`viewControls` that currently enumerates every lens.

Run:

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeq
```

**Implementation**

Use the policy to configure the existing segmented control as a presentation
selector for applicable miSeq while keeping internal lens `.summary`. Route
`.matrix` directly to `comparisonMatrix`; remove the diagnostic-definition
matrix from this route. Update the View Inspector to display the same labels and
mutate the same `summaryViewMode`. Keep Inspector audit/provenance/workbook
surfaces and selection-detail evidence actions. Rewire review keyboard commands
and definition requests around selection/presentation policy rather than a
hidden Review/Audit lens.

**Green test and commit**

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeq
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "Replace miSeq Review and Audit viewport tabs"
```

## Task 6: Synchronize editing from both presentations

**Files**

- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeHaplotypeTapeView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift`

**Red tests**

Use a two-sample/two-locus fixture for this sequence:

1. Open Calls with matrix unconfigured.
2. Save both slots from Calls.
3. Open Matrix and compare exact projection/band values.
4. Edit one band call while Calls is hidden.
5. Switch back and compare exact values/status/source.
6. Restore one call from each presentation.
7. Recreate the controller from disk.

At each step assert unaffected calls stay identical, each changed Save produces
one store publication/workbook-dirty/Inspector notification, and no manual
assignments appear. Assert read-only/fault/no-op paths produce none. Verify the
next current.xlsx publication contains the same effective values and final-path
provenance.

Record the store's returned changed keys at the controller boundary and assert
that post-mutation invalidation touches only those sample/locus keys and the
corresponding visible band columns; the broad legacy
`refreshAfterHaplotypeOverride()` path must not rebuild every row.

Run:

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeqEditsStaySynchronized
swift test --filter GenotypeCurrentWorkbookSyncCoordinatorTests
```

**Implementation**

Create one controller `commitEffectiveHaplotypeMutation` used by the outline,
Inspector, detail sheet, and matrix band. On changed success: replace the
cached projection, refresh affected outline/evidence/band content, mark workbook
dirty once, and notify Inspector once. Keep matrix lazy. On failure: preserve
projection, draft, selection, focus, and workbook state; present one plain
language error. Label clear as Restore Pipeline Call.

Add AXPress and Space/Return activation to tape and band targets with meaningful
sample/locus/slot/value/status/source labels. Preserve focus across refresh and
announce success through accessibility notification.

**Green test and commit**

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeqEditsStaySynchronized
swift test --filter GenotypeCurrentWorkbookSyncCoordinatorTests
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Sources/LungfishGenotypeUI/GenotypeHaplotypeTapeView.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift \
  Tests/LungfishAppTests/GenotypeCurrentWorkbookSyncCoordinatorTests.swift
git commit -m "Synchronize miSeq haplotype editing across views"
```

## Task 7: Enforce lazy and targeted performance

**Files**

- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `.github/workflows/ci.yml`

**Red tests**

Add deterministic counters for matrix configure, base projection, column
rebuild, band invalidation, haplotype analysis, workbook reload, and unrelated
row reload. Add retained-demultiplexing-size timing with warm switch p95 <= 16.7
ms and p99 <= 33.4 ms when `LUNGFISH_RELEASE_PERFORMANCE_TEST=1`.

Run:

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 swift test --filter GenotypeManualHaplotypePerformanceTests
```

**Implementation**

Remove broad post-override rebuilds for this policy. Refresh only returned
changed
sample/locus outline/evidence and band damage; recompute cohort membership only
when affected. Add the focused policy/projection/store/controller test filters
to normal CI. Keep the timing gate in the local release checklist unless a
dedicated CI performance job with an appropriate timeout is added explicitly.

**Green test and commit**

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 swift test --filter GenotypeManualHaplotypePerformanceTests
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift \
  .github/workflows/ci.yml
git commit -m "Keep synchronized miSeq views responsive"
```

## Task 8: Run focused and regression verification

Run in order and keep the actual logs:

```bash
swift test --filter GenotypeResultPresentationPolicyTests
swift test --filter GenotypeEffectiveHaplotypeProjectionTests
swift test --filter GenotypeAnnotationStoreCallOverrideTests
swift test --filter GenotypeCallOverrideReplayPayloadTests
swift test --filter GenotypeReplayCallOverridesSubcommandTests
swift test --filter GenotypeHaplotypeCallBandTests
swift test --filter GenotypeResultViewportTests
swift test --filter GenotypeCurrentWorkbookSyncCoordinatorTests
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 swift test --filter GenotypeManualHaplotypePerformanceTests
swift test
python3 -m unittest discover scripts/tests
./scripts/build-app.sh --configuration Debug
codesign --verify --deep --strict build/Debug/Lungfish.app
git diff --check
git status --short
```

Inspect the Debug app manually with a haplotyped miSeq fixture: default Calls,
selector labels, raw genotype/candidate matrix, effective band, edit/restore in
both views, comments/review actions, large text, keyboard access, and workbook
update. Do not advance while any regression remains.

## Task 9: Prepare narrative release beta19

**Files**

- Modify: `Sources/LungfishCore/AppVersion.swift`
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Modify: `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist`
- Modify: `Lungfish.xcodeproj/project.pbxproj`
- Create: `docs/release-notes/v0.5.0-beta19.md`

Write narrative notes covering synchronized miSeq views, the full genotype
matrix, atomic/replayable overrides, read-only safety, preservation of
Review/Audit capabilities in Inspector/detail, and all pending DRB/storage
fixes included since beta18. Use plain language and explain user-visible intent.
Set marketing version `0.5.0-beta19`; obtain the next monotonically increasing
build number from the release tooling.

Run version consistency tests and commit:

```bash
rg -n "0\.5\.0-beta(18|19)" Sources Lungfish.xcodeproj docs/release-notes
python3 -m unittest scripts.tests.test_sparkle_release_packaging
git add Sources/LungfishCore/AppVersion.swift \
  Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json \
  Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist \
  Lungfish.xcodeproj/project.pbxproj docs/release-notes/v0.5.0-beta19.md
git commit -m "Prepare v0.5.0-beta19"
```

## Task 10: Merge, sign, notarize, publish, and verify Sparkle

Before publishing, request an independent code review, resolve every blocking
finding, rerun Task 8, and verify the feature branch contains all approved
pending-fix commits.

Fast-forward `main`, preserving root-worktree untracked files:

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer fetch origin
git -C /Users/dho/Documents/lungfish-genome-explorer merge --ff-only codex/zero-snp-candidate-resolution
git -C /Users/dho/Documents/lungfish-genome-explorer push origin main
```

Use the established release wrapper/configuration from main to build the
Developer-ID signed Release app, notarized/stapled DMG, Sparkle EdDSA appcast,
GitHub prerelease, narrative notes asset, and mutable `sparkle-beta` feed. Tag
the exact clean-main commit `v0.5.0-beta19` and push it.

Verify locally and remotely:

- Debug and Release products build;
- Release app and DMG pass `codesign`, `stapler validate`, and `spctl`;
- the mounted DMG contains the same signed app and launches;
- notary JSON status is Accepted;
- tag equals `v<CFBundleShortVersionString>` and the build is monotonic;
- appcast version/build/enclosure URL/length/notes are correct;
- EdDSA verifies against the public key embedded in the shipped app;
- remote DMG/appcast/narrative bytes match local checksums;
- the published feed URL returns and validates the same entry;
- the release commit includes this plan's feature and pending-fix SHAs.

## Task 11: Remove stale worktrees and branches

Quit any app launched from a feature worktree. From clean `main`, list exact
targets, remove only merged linked worktrees, prune worktree metadata, delete
merged `codex/*` local branches and corresponding stale remote branches, and
verify no unmerged work is discarded. Preserve the root worktree's existing
untracked `.task-bundles/` and documentation files.

```bash
git worktree list --porcelain
git branch --merged main
git branch -r --merged origin/main
git worktree remove /Users/dho/Documents/lungfish-genome-explorer/.worktrees/zero-snp-candidate-resolution
git worktree prune
git branch -d codex/zero-snp-candidate-resolution
git status --short --branch
git worktree list
```

Final state: `main` equals `origin/main`, tag and release target that commit,
the published DMG and Sparkle feed validate, no stale feature worktree/branch
remains, and the user's pre-existing untracked files remain untouched.

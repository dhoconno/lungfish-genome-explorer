# 12S Flanked Exact Match Undercall Design

**Date:** 2026-05-31
**Status:** Investigation-backed design, ready for implementation planning
**Branch target:** fresh worktree off `main` after unrelated `WorkflowLibrary.swift` build breakage is resolved

## Goal

Fix the 12S amplicon matcher so reads that contain an exact reference 12S target sequence
inside retained primer/flanking sequence are counted as exact target matches, rather than
left in `unresolved-sequences.tsv`. The immediate regression case is the Hilo sample where
the primary cow and pig reads were undercalled relative to an independent analysis.

## Investigation Summary

Inputs investigated:

- Lungfish result bundle:
  `/Users/dho/Downloads/12S.lungfish/Analyses/12S amplicon results/HI_Hilo_WWTP_20260511__12S_F09_S69_L001-12s-bundle-debug-verify.lungfish12s`
- Collaborator workbook:
  `/Users/dho/Downloads/Hilo.xlsx`

Key observations:

| Species | Collaborator reads | Lungfish species total | Primary Lungfish target row | Unresolved reads containing exact collaborator core |
| --- | ---: | ---: | ---: | ---: |
| Cow / `Bos taurus` | 1513 | 57 | 0 for `domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759` | 1522 across 34 unresolved rows |
| Pig / `Sus scrofa` | 1063 | 13 | 0 for `pig (Sus scrofa)|seq_sha256=f59a31cf5675f344` | 1084 across 18 unresolved rows |

The collaborator cow and pig core sequences are exact matches to the primary Lungfish
reference target sequences:

```text
Cow core, 107 bp:
ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT

Pig core, 106 bp:
ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC
```

Those same exact cores are present inside the top unresolved Lungfish sequences, with
retained flanking bases:

```text
unresolved_1, cow, 1425 reads:
ACTGGGATTAGATACCCC
ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT
CTAGAGGAGCCTGTTCTA

unresolved_2, pig, 1057 reads:
ACTGGGATTAGATACCCC
ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC
CTAGAGGAGCCTGTTCTA
```

This is evidence of a Lungfish undercall, not strong evidence of collaborator overcalling.
The independent counts are close to the number of Lungfish unresolved reads that contain
the exact target core. The discrepancy is caused by classification of full reads with
retained flanking sequence, not by absence of cow/pig targets from the reference.

The bundle provenance shows it was produced by:

```text
lungfish-cli fastq 12s-match \
  /Users/dho/Downloads/12S.lungfish/Imports/HI_Hilo_WWTP_20260511__12S_F09_S69_L001.lungfishfastq \
  --reference /Users/dho/Downloads/12S.lungfish/Reference Sequences/MIDORI-12S.lungfish12sref \
  --output-dir /Users/dho/Downloads/12S.lungfish/Analyses/12S amplicon results \
  --output-name HI_Hilo_WWTP_20260511__12S_F09_S69_L001-12s-bundle-debug-verify \
  --threads 14 \
  --force
```

Resolved defaults included `minimumSoftClipBases = 1`, `maximumIndelBases = 3`, and
`runChimeraReview = true`.

## Required Behavior

1. A read that contains exactly one reference target sequence as an internal substring, with
   at least `minimumSoftClipBases` bases before and after the target substring, must be
   classified as `.exact(targetID: ..., indelCount: 0)`.
2. Prefix and suffix sequence must not need to match any reference. Sequencing errors in
   the retained flanking sequence must not prevent classification when the target core is
   exact.
3. If the exact core maps to exactly one Lungfish target row, count the read toward that
   target in `sample-target-counts.tsv`.
4. If the exact core maps to multiple target rows that are not already deduplicated into a
   single reference record, keep the current ambiguity semantics: count as ambiguous and
   unresolved rather than arbitrarily picking one species.
5. Indel-only alignment remains a fallback for reads that do not contain an exact reference
   target substring.
6. Existing provenance requirements remain blocking. If this change adds or changes any
   user-visible option, default, output schema field, or workflow behavior label, the
   `.lungfish-provenance.json` and per-output provenance sidecars must record it.

## Non-Goals

- Do not change the MIDORI reference bundle contents.
- Do not change cow/cattle taxonomy collapsing or alternate-match semantics.
- Do not make a GUI-only correction. The fix must live in the CLI-backed workflow so GUI
  imports, reruns, and exported `.lungfish12s` bundles are reproducible.
- Do not add a heuristic that assigns near matches with substitutions to cow or pig. This
  spec is only for exact embedded target cores and the existing indel-only behavior.

## Code Areas To Update

### `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconReadClassifier.swift`

The classifier already has an `exactMatches(in:)` path whose intended behavior is to find
exact reference targets inside soft-clipped reads. The Hilo output proves that the built
CLI used for the bundle did not apply that behavior to real cow/pig reads. Treat this as a
regression until proven otherwise.

Implementation requirements:

- Add a focused helper, or harden the existing helper, so exact embedded target matching is
  explicit and covered by Hilo-derived tests.
- Keep the match boundary condition tied to `minimumSoftClipBases`:
  - valid: `prefix.count >= minimumSoftClipBases`
  - valid: `suffix.count >= minimumSoftClipBases`
  - invalid: no prefix when `minimumSoftClipBases > 0`
  - invalid: no suffix when `minimumSoftClipBases > 0`
- Ensure the exact embedded match path runs before indel candidate search.
- Return `.exact(..., indelCount: 0)` immediately when there is exactly one exact target.
- Return `.ambiguous(targetIDs:)` when more than one target is found at the exact best tier.

If the current rolling-hash implementation passes the new Hilo-derived unit tests, keep it.
If it fails, the acceptable minimal fix is to replace the exact embedded path with a simpler
bounded exact-subsequence scan that prioritizes correctness over micro-optimization. Do not
change the indel-only fallback unless a failing test isolates an indel-specific issue.

### `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift`

No workflow-level schema change is required for the core fix. The existing classified-read
flow should automatically move these reads from `unresolvedCounts` to `countsByTarget` once
the classifier returns `.exact`.

Only modify this file if a workflow-level regression test shows that the classifier result
is not being propagated correctly into:

- `classified.exactReadsBySample`
- `classified.countsByTarget`
- `classified.unresolvedCounts`
- `sample-target-counts.tsv`
- `unresolved-sequences.tsv`
- `read-fate.json`

### `Sources/LungfishCLI/Commands/FastqTwelveSMatchSubcommand.swift`

No CLI flag is required. If implementation changes expose a new option, update:

- argument parsing
- reproducible `argv`
- resolved defaults in provenance
- CLI tests that assert command construction

The preferred fix has no new option and simply makes the documented/default behavior correct.

### GUI Files

No GUI code should be needed. The GUI should benefit automatically because it imports or
opens the `.lungfish12s` bundle produced by the CLI-backed workflow.

## Required Tests

### Unit Test: Hilo Cow/Pig Flanked Exact Reads

Add this to `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift`.

```swift
func testClassifiesHiloCowAndPigFlankedExactReads() throws {
    let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
    let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
    let prefix = "ACTGGGATTAGATACCCC"
    let suffix = "CTAGAGGAGCCTGTTCTA"

    let cow = TwelveSReferenceRecord(
        targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759",
        displayName: "domestic cattle (Bos taurus)",
        sequence: cowCore
    )
    let pig = TwelveSReferenceRecord(
        targetID: "pig (Sus scrofa)|seq_sha256=f59a31cf5675f344",
        displayName: "pig (Sus scrofa)",
        sequence: pigCore
    )
    let classifier = TwelveSAmpliconReadClassifier(
        references: [cow, pig],
        minimumSoftClipBases: 1,
        maximumIndelBases: 3
    )

    XCTAssertEqual(
        classifier.classify(readSequence: prefix + cowCore + suffix),
        .exact(targetID: cow.targetID, indelCount: 0)
    )
    XCTAssertEqual(
        classifier.classify(readSequence: prefix + pigCore + suffix),
        .exact(targetID: pig.targetID, indelCount: 0)
    )
}
```

### Unit Test: Flanking Errors Do Not Matter

```swift
func testClassifiesExactCoreWhenFlankingSequenceHasErrors() throws {
    let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
    let cow = TwelveSReferenceRecord(
        targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759",
        displayName: "domestic cattle (Bos taurus)",
        sequence: cowCore
    )
    let classifier = TwelveSAmpliconReadClassifier(
        references: [cow],
        minimumSoftClipBases: 1,
        maximumIndelBases: 3
    )

    XCTAssertEqual(
        classifier.classify(readSequence: "ACTGGGATTAGATACCCC" + cowCore + "CCAGAGGAGCCTGTTCTA"),
        .exact(targetID: cow.targetID, indelCount: 0)
    )
}
```

### Unit Test: Boundary Conditions Stay Strict

Preserve the existing soft-clip requirement and add the real Hilo core to protect the boundary:

```swift
func testHiloExactCoreStillRequiresConfiguredSoftClipAtBothEnds() throws {
    let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
    let pig = TwelveSReferenceRecord(
        targetID: "pig (Sus scrofa)|seq_sha256=f59a31cf5675f344",
        displayName: "pig (Sus scrofa)",
        sequence: pigCore
    )
    let classifier = TwelveSAmpliconReadClassifier(
        references: [pig],
        minimumSoftClipBases: 1,
        maximumIndelBases: 3
    )

    XCTAssertEqual(classifier.classify(readSequence: pigCore + "CTAGAGGAGCCTGTTCTA"), .unresolved)
    XCTAssertEqual(classifier.classify(readSequence: "ACTGGGATTAGATACCCC" + pigCore), .unresolved)
}
```

### Workflow Test: Counts Move From Unresolved To Target Matrix

Add a workflow-level test using a tiny temporary reference FASTA and FASTQ:

```swift
func testWorkflowCountsHiloFlankedCowAndPigReadsInsteadOfLeavingThemUnresolved() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TwelveSHiloRegression-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
    let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
    let prefix = "ACTGGGATTAGATACCCC"
    let suffix = "CTAGAGGAGCCTGTTCTA"

    let referenceURL = root.appendingPathComponent("reference.fa")
    try """
    >domestic cattle (Bos taurus)|locus=12S|len=107|n_refs=161|n_species=7|primer_pairs=12S_vert_F_x_12S_vert_R
    \(cowCore)
    >pig (Sus scrofa)|locus=12S|len=106|n_refs=204|n_species=1|primer_pairs=12S_vert_F_x_12S_vert_R
    \(pigCore)
    """.write(to: referenceURL, atomically: true, encoding: .utf8)

    let fastqURL = root.appendingPathComponent("hilo.fastq")
    try """
    @cow1
    \(prefix)\(cowCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + cowCore.count + suffix.count))
    @cow2
    \(prefix)\(cowCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + cowCore.count + suffix.count))
    @pig1
    \(prefix)\(pigCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
    @pig2
    \(prefix)\(pigCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
    @pig3
    \(prefix)\(pigCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
    """.write(to: fastqURL, atomically: true, encoding: .utf8)

    let result = try await TwelveSAmpliconMatchingWorkflow(
        chimeraReviewer: TwelveSNoOpChimeraReviewer()
    ).run(
        TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [fastqURL],
            referenceFASTA: referenceURL,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "hilo-regression",
            minimumSoftClipBases: 1,
            maximumIndelBases: 3,
            runChimeraReview: false
        )
    )

    let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
    let cowRow = try XCTUnwrap(loaded.targetRows.first { $0.target.displayName == "domestic cattle (Bos taurus)" })
    let pigRow = try XCTUnwrap(loaded.targetRows.first { $0.target.displayName == "pig (Sus scrofa)" })

    XCTAssertEqual(cowRow.count(forSample: "hilo"), 2)
    XCTAssertEqual(pigRow.count(forSample: "hilo"), 3)
    XCTAssertEqual(loaded.readFate.exactMatchReads, 5)
    XCTAssertEqual(loaded.readFate.unresolvedReads, 0)
    XCTAssertTrue(loaded.unresolvedSequences.isEmpty)
}
```

### Provenance Test

The existing provenance test should continue to pass. If the fix adds any new output metric
or option, extend the provenance assertions in the same test file so the resolved default
and reproducible command are recorded.

## Manual Verification Against The Hilo Bundle

After implementation, rerun the Hilo sample in a clean worktree with a rebuilt CLI. The old
bundle was produced by `Lungfish 0.5.0-alpha8 (1)`; the regenerated bundle must have a
distinct tool version/build identity in provenance so old and new results are auditable.

Expected Hilo-level effects:

- The primary cattle target row
  `domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759` should increase from `0` to
  at least `1425`, because `unresolved_1` is an exact flanked core match.
- The primary pig target row
  `pig (Sus scrofa)|seq_sha256=f59a31cf5675f344` should increase from `0` to at least
  `1057`, because `unresolved_2` is an exact flanked core match.
- `read-fate.json` exact-match reads should increase and unresolved reads should decrease
  by at least `2482` reads (`1425 + 1057`), before considering the lower-abundance flanked
  cow/pig rows.
- The exact old `unresolved_1` and `unresolved_2` sequences should no longer appear in
  `unresolved-sequences.tsv`.
- Total `Bos taurus` and `Sus scrofa` counts should be close to the collaborator workbook:
  collaborator reported 1513 cow reads and 1063 pig reads. Differences after the fix should
  be explainable by Lungfish reference variants, ambiguity semantics, or collaborator-side
  filtering, not by the primary exact core remaining unresolved.

## Acceptance Criteria

- Hilo-derived classifier unit tests pass.
- Workflow-level regression test proves target counts and read fate are updated.
- Existing tests for unresolved reads, ambiguous exact reads, and indel-only matching still pass.
- No GUI-only path is introduced.
- No scientific output is written without complete Lungfish provenance.
- A regenerated Hilo `.lungfish12s` bundle no longer undercalls primary cow/pig exact cores.

## Implementation Order

1. Create a fresh worktree after unrelated build failures in the current workspace are resolved.
2. Add the Hilo-derived classifier tests and verify at least one fails against the affected
   build/source combination.
3. Harden `TwelveSAmpliconReadClassifier.exactMatches(in:)` only as much as needed for the
   failing tests.
4. Add the workflow-level regression test.
5. Run targeted tests:

   ```bash
   swift test --filter TwelveSAmpliconMatchingWorkflowTests/testClassifiesHiloCowAndPigFlankedExactReads
   swift test --filter TwelveSAmpliconMatchingWorkflowTests/testClassifiesExactCoreWhenFlankingSequenceHasErrors
   swift test --filter TwelveSAmpliconMatchingWorkflowTests/testHiloExactCoreStillRequiresConfiguredSoftClipAtBothEnds
   swift test --filter TwelveSAmpliconMatchingWorkflowTests/testWorkflowCountsHiloFlankedCowAndPigReadsInsteadOfLeavingThemUnresolved
   ```

6. Run the broader 12S workflow tests:

   ```bash
   swift test --filter TwelveSAmpliconMatchingWorkflowTests
   swift test --filter FastqTwelveSMatchSubcommandTests
   ```

7. Rebuild the CLI, rerun the Hilo sample, and compare the new `sample-target-counts.tsv`,
   `unresolved-sequences.tsv`, `read-fate.json`, and `.lungfish-provenance.json` against
   the old bundle.

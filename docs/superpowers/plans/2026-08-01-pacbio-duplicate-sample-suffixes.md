# PacBio Duplicate Sample Suffixes Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task by task.

**Goal:** Let ONT PacBio barcode imports accept repeated sample names by giving every member of a repeated group a deterministic `_1`, `_2`, … suffix before the long-running read scan begins.

**Architecture:** Add a small, pure sample-name resolver between barcode-sheet parsing and demultiplexing. The resolver normalizes names exactly as output bundles do, groups them case-insensitively, preserves unique names, numbers repeated names in sheet order, and rejects any resulting collision immediately. The materializer then uses only resolved names while retaining the original sheet identity in the aggregate manifest and per-sample provenance.

**Tech stack:** Swift 6, Swift Package Manager, XCTest, Lungfish workflow provenance models.

## Task 1: Add the deterministic name resolver

**Files:**

- Create: `Sources/LungfishWorkflow/ONTGenotyping/ONTPacBioBarcodeSampleNameResolver.swift`
- Test: `Tests/LungfishWorkflowTests/ONTPacBioBarcodeDemuxMaterializerTests.swift`

- [ ] Add tests proving that a unique sample remains unsuffixed.
- [ ] Add tests proving that three repeated samples become `_1`, `_2`, and `_3` in source-row order.
- [ ] Add a test proving that filesystem-equivalent names are grouped after output-name normalization and without regard to case.
- [ ] Add a test proving that a generated name colliding with an explicit name (for example, repeated `Sample` plus explicit `Sample_1`) is rejected with the source rows identified.
- [ ] Run the focused test and confirm it fails because the resolver does not exist.
- [ ] Implement source-row and resolved-assignment value types plus a two-pass resolver.
- [ ] Run the focused tests and confirm they pass.

## Task 2: Resolve names before starting an import

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTPacBioBarcodeDemuxMaterializer.swift`
- Test: `Tests/LungfishWorkflowTests/ONTPacBioBarcodeDemuxMaterializerTests.swift`

- [ ] Add an end-to-end test with two barcode rows sharing one sample name and reads matching both rows; assert that two bundles named `_1` and `_2` are created with the correct reads.
- [ ] Add an early-failure test for a secondary name collision; assert that no output directory is created.
- [ ] Run the new tests and confirm they fail for the expected reasons.
- [ ] Capture physical source-row numbers while loading the barcode sheet.
- [ ] Resolve all output names immediately after parsing and before output-directory creation or FASTQ scanning.
- [ ] Feed resolved names into exact demultiplexing and remove the duplicate-key crash path.
- [ ] Keep numbering based on every sheet row, including rows receiving no reads.
- [ ] Run the focused tests and confirm they pass.

## Task 3: Preserve traceability

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTPacBioBarcodeDemuxMaterializer.swift`
- Test: `Tests/LungfishWorkflowTests/ONTPacBioBarcodeDemuxMaterializerTests.swift`

- [ ] Add assertions that the aggregate demultiplex manifest records source row, original sample ID, resolved output ID, and both barcode IDs for every sheet row.
- [ ] Add assertions that each generated sample bundle records its original sample identity, resolved identity, source row, and barcode pair in provenance.
- [ ] Implement the aggregate mapping and per-bundle provenance fields without weakening existing command, checksum, runtime, timing, or exit-status provenance.
- [ ] Run the focused tests and confirm they pass.

## Task 4: Explain behavior and verify compatibility

**Files:**

- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`
- Test: `Tests/LungfishWorkflowTests/ONTPacBioBarcodeDemuxMaterializerTests.swift`

- [ ] Update command help to state that only repeated sample names are numbered and that all members start at `_1`.
- [ ] Confirm an existing unique-name import still produces its original unsuffixed bundle name.
- [ ] Run the complete workflow and CLI test suites relevant to the change.
- [ ] Run a release build.
- [ ] If the reported barcode sheet is available, perform a read-only preflight and confirm it resolves all 272 rows to unique names, including `LN94_Mamu-E_1` and `LN94_Mamu-E_2`, without scanning the large BAM/FASTQ input.
- [ ] Review the diff for unintended recipe, matching, or provenance changes.

## Verification commands

```sh
swift test --filter ONTPacBioBarcodeDemuxMaterializerTests
swift test --filter ExactBarcodeDemuxTests
swift test --filter LungfishCLITests
swift build -c release
git diff --check
```


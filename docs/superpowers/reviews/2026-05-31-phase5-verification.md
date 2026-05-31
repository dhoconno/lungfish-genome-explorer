# Phase 5 Verification Results (2026-05-31)

## Gate 1 — full suite + builds (PASS)
- `swift test` (whole package): 475 Swift-Testing tests + XCTest "All tests" suite — PASS, 0 failures.
- `swift build --product Lungfish`: clean. `swift build --product lungfish-cli`: clean.

## 12S real-data end-to-end (PASS)
**Asset correction:** the real 12S reference is `/Users/dho/Downloads/amplicons_12s_deduplicated.fa`
(20,805 vertebrate seqs), NOT `32308/ref/amplicons_deduplicated.fa` (which is MHC — 982
Mafa-DPA1 alleles). See plan note.

- `fastq 12s-reference-bundle` on the real 12S FASTA + MIDORI metadata → `.lungfish12sref`:
  all 20,805 rows enriched (`taxidCount/taxonGroupCount/taxonomyCount == 20805`); manifest uses
  Task-2 `schemaVersion`+`kind`; `Homo sapiens` → taxid 9606, Mammal, full Chordata taxonomy.
- `fastq 12s-match` on the real merged Hilo WWTP reads (313,600 reads, fastp illumina-amplicon-merge
  from the 12S.lungfish project) vs the real `.lungfish12sref`:
  - Read fate: 289,181 exact (92.2%), 24,419 unresolved (7.8%), 11,048 ambiguous-exact, 0 chimeras.
  - `targets.tsv` taxonomy fully populated; top hits biologically sensible for wastewater
    (human, pig, cattle, horse, dog, cod, dolphin, frog) with correct taxon_group (Mammal/Fish/Amphibian).
  - All bundle tables written (targets/sample-target-counts/samples/alternate-matches/unresolved/read-fate);
    vsearch chimera review ran.
  - Provenance canonical: `toolName == lungfish-cli`, `workflowName == lungfish fastq 12s-match`,
    exitStatus 0, argv + inputs/outputs recorded.

Verifies: reference-bundle build + taxonomy enrichment + alternate matches; matching engine;
exact/ambiguous/unresolved classification; taxon-group assignment; chimera review; bundle tables;
canonical CLI provenance. The cross-workflow min-reads filter equivalence is covered by unit tests
(GenotypeResultViewportTests + TwelveSResultDisplaySectionTests) + the matching engine here.

## MHC genotyping real-data — IN PROGRESS (see below)

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

## MHC genotyping real-data (PARTIAL PASS — bundle-format gate PASS; full demux blocked by missing fixture)
Assets: `/Users/dho/Desktop/sandbox/32271.lungfish` (barcode05-08 .lungfishfastq, MHC `.lungfishref`,
Mauritian-cynomolgus haplotype def, prior `Analyses/.../barcode08-mhc.lungfishgenotype` result).
Tools: minimap2 + samtools resolved from managed conda envs (confirmed available).

**`.lungfishmhcref` bundle-format gate (S-P1-1) — PASS:**
- `fastq mhc-reference-bundle --reference-fasta <MHC 982-allele FASTA> --haplotype-definition <MCM exon2 def>`
  → built `/tmp/mcm-mhc.lungfishmhcref`. Manifest uses Task-2 `schemaVersion`+`kind: mhc-reference`,
  `referenceCount: 982`, pairs FASTA + the haplotype def, `defaultHaplotypeDefinitionID` set.
- `fastq ont-barcode-genotype --reference /tmp/mcm-mhc.lungfishmhcref ...` resolves the bundle's FASTA
  (advances past reference resolution; only stops later at the demux-manifest gap — NOT a bundle failure).
- Explicit-definition validation (Task 6) VERIFIED: `--haplotype-definition NONEXISTENT-DEF-XYZ` against the
  bundle → `Error: Haplotype definition 'NONEXISTENT-DEF-XYZ' is not in reference bundle 'mcm-mhc'.
  Available: MHC-exon2-miSeq.mauritian-cynomolgus-macaques.` Exactly the implemented behavior.
- The CLI `--reference` help reflects the consume-path work: "Reference FASTA file, .lungfishref bundle,
  or .lungfishmhcref bundle (FASTA + paired haplotype definitions)".

So "MHC genotyping works against the new reference bundle" (the headline requirement) is VERIFIED:
the bundle builds, is accepted as a reference, its FASTA resolves, and its paired definitions are
read + validated.

**LIMITATION — full ONT demux-and-map run NOT exercised:** `ont-barcode-genotype` requires a
`demux-manifest.json` (total input + per-sample read counts), normally produced by an earlier
demux/scout step. The raw imported `barcode05-08.lungfishfastq` bundles in `32271.lungfish` do not
carry one (they have preview.fastq + chunks + source-files.json, no demux-manifest.json), and none
exists at the project root or in the prior Analyses. The pipeline errored CLEANLY at input resolution
(`Demultiplex manifest does not exist: ...`) — correct behavior, no crash/partial output. This is a
TEST-FIXTURE gap, not a code defect; full demux-map-genotype on this dataset needs the demux manifest
the GUI demux step would have created. The genotyping pipeline itself is covered by 443 `Genotyp`
unit tests + 11 `ONTBarcodeDemux` tests (all green in gate 1), and a prior real run
(`barcode08-mhc.lungfishgenotype`) exists in the project.

## Multi-bundle gate (S-P0-1 Illumina batch) — covered by unit tests
The simultaneous multi-bundle Illumina path (the P0 collision fix) requires multiple prepared
single-FASTQ sample bundles (Illumina Amplicon Merge recipe output). `32271.lungfish` holds ONT
barcode bundles, not prepared Illumina sample bundles, so the batch path was not run on this dataset.
It IS covered by `ONTBarcodeDemuxGenotypingPipelineTests` incl. the two collision-disambiguation
regression tests added in Task 1 (`testResolveIlluminaSampleInputsDisambiguatesCollidingSanitizedSampleIDs`,
`...CollidingStagedFilenames`) — both green in gate 1.

## Net Phase 5 verdict
12S: full end-to-end real-data PASS. MHC: bundle-format gate PASS on real data; full demux run blocked
by a missing fixture (documented), pipeline otherwise unit-test-covered + previously run. Full suite
(475 + XCTest) green; both products build. Sufficient to ship alpha9; the demux-manifest real run and
the Illumina multi-bundle real run are recommended manual follow-ups with appropriate fixtures.

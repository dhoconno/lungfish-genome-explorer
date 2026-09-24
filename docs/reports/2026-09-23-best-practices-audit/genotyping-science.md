# MHC genotyping scientific correctness review (GEN)

Audit date: 2026-09-23. Worktree `claude/lge-best-practices-audit-0a1b8f`. Decision D7 (review only; code changes only if a P0 is found). Finding prefix: GEN.

## Scope

- `Sources/LungfishWorkflow/ONTGenotyping`: the amplicon genotyper (`ONTBarcodeDemuxGenotypingPipeline` and its embedded pysam filter), the Illumina pair merger, the Fluidigm and PacBio barcode materializers, the full-length ONT (savont cluster) genotyper, and the legacy `ont-genotype` CLI pipeline.
- `Sources/LungfishIO/Bundles/ONTGenotype*.swift` and the call, threshold and haplotype code they depend on (`GenotypeHaplotypeAnalyzer`, `GenotypeDropoutEvaluator`, `GenotypeHaplotypeLocusResolver`, `GenotypeMatrixBaseProjection`).
- The threshold, pivot and Excel logic in `Sources/LungfishGenotypeUI` and `GenotypeExcelSnapshotBuilder`.
- The shipped MCM MiSeq preset: reference FASTA (189 records) and haplotype definition set `mcm-mhc-miseq-20260617`.

## Method

- Traced every count from the minimap2 argv, through the embedded Python filter, the CSV, `ONTGenotypeResultBundle`, the haplotype analyzer, to the matrix and the Excel snapshot.
- Extracted the two embedded Python filter scripts verbatim from the Swift sources. I ran them with the managed tools in `~/.lungfish/conda/envs` (minimap2 2.31-r1302, samtools, pysam) on synthetic reads in the session scratchpad. These runs are the **Confirmed** results below. They exercise the exact filter code LGE ships, not a re-implementation.
- Used the shipped MCM reference and definition set directly as data. I ran them against the real Fluidigm Access Array barcode table in `FluidigmBarcodeData.swift` and against a Python port of the deterministic haplotype caller.
- No build, no test, no repo changes other than this report.

## Limits

- I did not run LGE or the Swift analyzer. Findings on Swift-only logic are **Traced**. GEN-02 is Traced through a Python port of `callHaplotype`, and its acceptance test must be a Swift unit test.
- I had no real MiSeq or ONT run data. The owner's real-bundle smoke test is gated on `LUNGFISH_GENOTYPE_REAL_BUNDLE`.
- AI haplotyping (D5) is out of scope except for one surface note (GEN-12).
- The full-length ONT path was reviewed for calling and counting only, not for savont parameters.

## Executive summary

The core read-to-allele rule for amplicons is sound and conservative. A read counts only if its alignment spans the reference end to end with zero mismatches in the MD tag. The shipped MCM reference is well prepared: I found no exact duplicates, no reverse-complement duplicates and no containment. In both `sr` and `map-ont` modes, an error-free read of each of the 189 alleles is credited only to its own reference. For MiSeq data with the MCM preset, the per-allele read counts are therefore trustworthy.

The serious defects sit on either side of that core:

- **Sample assignment (ONT barcode demux, GEN-01).** The barcode matchers take the leftmost exact barcode match anywhere in the read, including inside the MHC amplicon. Five MCM DRB alleles, including the DR primary alleles for M1, M3, M4 and M6, contain the Fluidigm FLD0026 barcode. I confirmed with the shipped filter that half of such reads move to the FLD0026 animal. This creates phantom DR alleles in one animal and removes reads from all the others.
- **Haplotype calling (GEN-02).** The shipped definition set uses `minimumMatches: 1` everywhere. The caller counts a haplotype as matched when any one of its full-weight alleles is seen. A homozygote that shares one allele with a second haplotype is therefore reported as a confident heterozygote with status `called`. Examples are DQ M2/M2 reported as "M2 / M6" and DR M4/M4 reported as "M4 / M5". DP M4 and M7 have identical definitions and cannot be told apart, yet they are reported as a heterozygous pair.

Thresholds are the third problem area:

- `--min-support` never filters the report or workbook, although the help text says it does (GEN-03).
- "Locus %" has three different denominators across the pipeline, matrix and evidence pane (GEN-05).
- "Minimum percent" means per-sample read fraction for known alleles but fraction of animals for candidate rows (GEN-06).
- Illumina retention percentages divide merged fragments by mate count, which halves them (GEN-07).

Ambiguity is barely represented. Tied reads are credited in full to every tied allele with no marker (GEN-04). A second haplotype of "-" means both "homozygous" and "not found" (GEN-08).

My judgment: MiSeq allele counts with the MCM preset can be trusted. ONT barcode-demultiplexed runs cannot be trusted until GEN-01 is fixed. Deterministic haplotype calls at DQ and DR should not be reported without review until GEN-02 is fixed. Both are P0 under D7.

## Preserve (do not "fix" these away)

- **The zero-mismatch, full-span, MD-based filter.** It keeps a record only if `reference_start == 0`, `reference_end == len(ref)` and the MD mismatch count is `<= 0` ([ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:345](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:345)). A novel SNP allele can never be credited to a known allele. This matches the reference notebook's `bbmap semiperfectmode=t` intent.
- **The shipped MCM reference.** `mcm_mhc_miseq_reference.trimmed.unique.fasta` has 0 exact duplicates, 0 reverse-complement duplicates and 0 containment pairs (checked in Python). The cross-pass experiment below found no read credited to more than one allele. `build_mcm_mhc_miseq_reference.py` collapses duplicate amplicons ([build_mcm_mhc_miseq_reference.py:798](scripts/analysis/build_mcm_mhc_miseq_reference.py:798)). Keep that step for any future reference.
- **`IlluminaAmpliconPairMerger`.** It detects unmerged pairs and merges them before mapping. It loudly reports that it did so and records per-sample bbmerge argv and staging ([IlluminaAmpliconPairMerger.swift:1](Sources/LungfishWorkflow/ONTGenotyping/IlluminaAmpliconPairMerger.swift:1), [ONTBarcodeDemuxGenotypingPipeline.swift:2236](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2236)). This is the fix for the historical DRB-zero defect, and it is correct.
- **Reference locking and hashing.** `lockedReferenceSHA256` is checked before mapping ([ONTBarcodeDemuxGenotypingPipeline.swift:893](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:893)). The filter's own provenance hashes the BAM, reference, barcode sheet and manifest ([ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:70](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:70)).
- **`size=N` read weights.** They are handled the same way by the Swift stager and the Python filter, so dereplicated exemplars count correctly.
- **Barcode-sheet collision validation in the Swift Fluidigm materializers** ([ONTFluidigmBarcodeCollisionValidation.swift:1](Sources/LungfishWorkflow/ONTGenotyping/ONTFluidigmBarcodeCollisionValidation.swift:1)). Extend it (GEN-09), do not remove it.
- **The Excel snapshot builder's coherence checks.** They refuse to export when the projected matrix disagrees with the native authority ([GenotypeExcelSnapshotBuilder.swift:232](Sources/LungfishWorkflow/ONTGenotyping/GenotypeExcelSnapshotBuilder.swift:232)). This is the mechanism that keeps the screen and the export consistent.
- **Explicit ambiguity statuses in the haplotype caller.** It emits `ERR: TMH`, `ERR: TMG` and `ERR: NO HAP` and writes notes whenever a dominance rule resolves a call. Failing loudly is the right design. GEN-02 is about the cases where it does not fail loudly.

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| GEN-01 | P0 | ONT barcode assignment takes the leftmost exact barcode match anywhere in the read, including inside the amplicon, which moves DRB reads between animals | Confirmed | M |
| GEN-02 | P0 | `minimumMatches: 1` plus a count-only match rule reports homozygotes as heterozygotes (DQ M2/M2 as "M2 / M6", DR M4/M4 as "M4 / M5") and reports indistinguishable DP definitions as a heterozygous pair | Traced (Python port) | M |
| GEN-03 | P1 | `--min-support` does not filter the report CSV or pipeline workbook, contrary to its help text | Confirmed | S |
| GEN-04 | P1 | Reads tied across alleles are credited in full to each allele with no ambiguity marker. minimap2 `-N 5` makes counts in groups of more than 6 arbitrary | Confirmed | M |
| GEN-05 | P1 | "Locus %" uses three different locus groupings (pipeline haplotype filter, matrix "Viewed Locus", evidence pane) | Traced | M |
| GEN-06 | P1 | "Minimum percent" means within-sample read fraction for known alleles but fraction of animals for candidate rows, on screen and in Excel | Traced | S |
| GEN-07 | P1 | Illumina sample totals count mates before merging while retained reads count merged fragments, which halves retention % and inflates pivot `percent_reads_unmapped` | Traced | S |
| GEN-08 | P2 | A second haplotype of "-" means both "homozygous" and "second haplotype not identified", and the viewer hides it | Traced | S |
| GEN-09 | P2 | The Python demux filter silently resolves duplicate or reverse-complement-colliding barcodes to the first sample | Traced | S |
| GEN-10 | P2 | Full-length ONT: a zero-SNP hit is a known call regardless of indel size, with no indel count in the call | Traced | S |
| GEN-11 | P2 | PacBio exact dual-barcode demux assigns multi-matching reads in Swift `Dictionary` iteration order, which varies between runs | Traced | S |
| GEN-12 | P2 | Provenance and QC gaps: bbtools missing from `managedTools`, hard-coded "resolvedDefaults", hard-coded QC cut-offs, AI prompt snapshot in every MCM run | Traced | S |
| GEN-13 | P2 | Legacy `fastq ont-genotype` maps ONT reads with the short-read preset, ignores `--allow-indels`, and randomly splits tied reads | Confirmed | S |

---

### GEN-01 (P0): Barcode assignment matches barcode sequences inside the amplicon

**Evidence**

- **Python filter (ONT barcode demux mode).** All barcodes and their reverse complements go into one alternation regex ([Scripts.swift:246](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:246)). `assign_barcode` takes `regex.search(...)`, the leftmost exact match anywhere in the read ([Scripts.swift:257](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:257)). The read is first restored to its sequencing orientation ([Scripts.swift:290](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:290)). The code has no position window, no check that the match sits next to CS1 or CS2, no check that both ends agree, and no masking of the aligned amplicon.
- **Swift Fluidigm materializers.** They use the same leftmost-anywhere rule ([ONTFluidigmAmpliconMaterializer.swift:806](Sources/LungfishWorkflow/ONTGenotyping/ONTFluidigmAmpliconMaterializer.swift:806), [ONTFluidigmSampleMaterializer.swift:318](Sources/LungfishWorkflow/ONTGenotyping/ONTFluidigmSampleMaterializer.swift:318)). They exclude only the CS1 and CS2 tag matches ([ONTFluidigmAmpliconMaterializer.swift:164](Sources/LungfishWorkflow/ONTGenotyping/ONTFluidigmAmpliconMaterializer.swift:164)). The insert is still searched.
- **Read layout.** The Fluidigm layout that LGE's own tests model is `CS1 + insert + rc(CS2) + NN + barcode` ([ONTFluidigmAmpliconMaterializerTests.swift:38](Tests/LungfishWorkflowTests/ONTFluidigmAmpliconMaterializerTests.swift:38)). In one read orientation the whole insert comes before the true barcode.

**Reference k-mer scan.** I compared the shipped MCM reference with the 864 barcodes in `FluidigmBarcodeData.swift` (forward and reverse complement):

| Barcode set | MCM alleles containing a barcode 10-mer |
|---|---|
| FLD0001-FLD0096 (one plate) | 7 of 189 |
| first 384 | 15 of 189 |
| all 864 | 21 of 189 |

`GAGTGTCACT` = FLD0026 ([FluidigmBarcodeData.swift:36](Sources/LungfishIO/Formats/FASTQ/FluidigmBarcodeData.swift:36)) sits at position 16 of five DRB records: 0166, 0167, 0168, 0171 and 0174. Of these, 0166, 0167, 0168 and 0174 are the MHC-DR primary alleles of M1, M3, M6 and M4 in the shipped definition set.

**Reproduction (Confirmed, shipped filter code).** Scratchpad `gen/e3`.

- Reference: the shipped MCM FASTA.
- Reads: 20 reads of `MCM_MHC_MiSeq_0168` (DRB1) and 20 reads of `MCM_MHC_MiSeq_0002` (class I), all from animal `Monkey_FLD0001`. Layout: adapter, CS1, primer, insert, primer, rc(CS2), "CC", FLD0001 barcode. Half of the reads are reverse-complemented.
- Barcode sheet: FLD0001 and FLD0026.
- Pipeline steps: `minimap2 -a -x map-ont --MD`, `samtools sort`, then the extracted `filter-demux-retained-bam.py` with `--assignment-mode barcode --require-both-end-softclips`.

Output:

```
sample,genotype,passed_alignments,passed_unique_reads
Monkey_FLD0001,MCM_MHC_MiSeq_0002,20,20
Monkey_FLD0001,MCM_MHC_MiSeq_0168,10,10
Monkey_FLD0026,MCM_MHC_MiSeq_0168,10,10     <- phantom DRB1 call in the wrong animal
```

Expected: all 40 reads in `Monkey_FLD0001`.

**Impact**

- On any Fluidigm ONT plate that includes FLD0026, every animal carrying the M1, M3, M4 or M6 DR primary allele loses about half of its reads for that allele.
- The FLD0026 animal receives phantom M1, M3, M4 and M6 DR alleles. This produces `ERR: TMH` or a wrong DR haplotype.
- The same happens for the other 2 (96-plex), 10 (384-plex) or 16 (all 864) affected alleles, each with its own barcode.
- Any ONT read whose true barcode has a sequencing error is also exposed. The next exact barcode k-mer anywhere in the read wins, so a spurious hit decides the sample instead of the read being left unassigned.

**Recommendation**

- Replace free search with anchored search in all three places. Search for the barcode only in a short window (for example 0 to 8 bp) outside the matched CS2 (or CS1) tag, in the orientation implied by that tag.
- Assign a read only when the anchored window matches exactly one sample. Classify conflicting or absent anchors as `unassigned` with a reason counter.
- Share the logic in one Swift type used by both materializers. Pass the same rule to the Python filter, or move demux ahead of mapping so the filter only ever sees `query-prefix`.
- Add a preflight check that scans the reference (and its reverse complement) for barcode k-mers and warns in provenance, as defence in depth.
- Record the assignment rule and window in provenance.

**Acceptance test**

- The fixture above yields 40 of 40 reads in `Monkey_FLD0001`, and no row for `Monkey_FLD0026`.
- A second fixture puts a 1-mismatch barcode at the anchor and an exact barcode k-mer in the insert. That read must be `unassigned`, not assigned to the k-mer's sample.
- Unit tests cover both Swift materializers with the same two fixtures.

**Effort:** M.

---

### GEN-02 (P0): Homozygotes are reported as heterozygotes when one allele is shared

**Evidence**

- The analyzer counts a haplotype as matched when `observedRequiredDiagnostics.count >= effectiveMinimumMatches` ([GenotypeHaplotypeAnalyzer.swift:631](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:631)). "Required" means every diagnostic allele with weight >= 1 ([GenotypeHaplotypeAnalyzer.swift:933](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:933)).
- In the shipped definition every haplotype at every locus has `"minimumMatches": 1` (for example [mcm-mhc-miseq-20260617.lungfishhaplotypedef.json:43](Sources/LungfishWorkflow/Resources/MCMHaplotyping/MCM-MHC-miSeq-20260617.lungfishmhcref/haplotypes/mcm-mhc-miseq-20260617.lungfishhaplotypedef.json:43)). One shared full-weight allele is therefore enough to match.
- With exactly two matches, the caller returns `h1 / h2` with status `.called` ([GenotypeHaplotypeAnalyzer.swift:702](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:702)).
- The only homozygote rescue, `dominantMHCBSingletonHomozygousResolution`, applies to MHC-B only, and only when the second haplotype has at most 1 read ([GenotypeHaplotypeAnalyzer.swift:827](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:827)).
- The DP overcall resolver ([GenotypeHaplotypeAnalyzer.swift:418](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:418)) depends on a called DQ. Nothing corrects DQ or DR.

**Worked example from the shipped data**

- DQ haplotype M2 = {0025 DQA1\*01:04, 0178 DQB1\*06:01}. DQ haplotype M6 = {0022 DQA1\*01:08, 0178 DQB1\*06:01}. The reference header says so: `0178 ... haplotypes=M2,M6`.
- An M2/M2 animal shows 0025 and 0178. M6 matches through 0178, so the call is `M2 / M6`, status `called`, with no note.
- DR M4 and M5 share the full-weight alleles 0027 (DRB5\*03:01) and 0182 (DRB6\*01:13). An M4/M4 animal is called `M4 / M5`.
- DP M4 and M7 have identical diagnostic lists, weights and primaries. Any M4/M4, M7/M7 or M4/M7 animal is called `M4 / M7`. The DQ-linked resolver changes this only when DQ was called, and DQ has its own defect.

**Python port over all 28 genotypes per locus.** Each true haplotype contributes 100 reads to each of its diagnostic alleles. This is a port of `callHaplotype` plus `dominantTopTwoMatches`, run against the shipped definition file.

| Locus | Correct | Wrong but `called` | `ERR: TMH` |
|---|---|---|---|
| MHC-A | 0 | 0 | 28 |
| MHC-B | 0 | 0 | 28 |
| MHC-DP | 4 | 2 (M4/M4, M7/M7 -> M4/M7) | 22 |
| MHC-DQ | 16 | 2 (M2/M2, M6/M6 -> M2/M6) | 10 |
| MHC-DR | 16 | 2 (M4/M4, M5/M5 -> M4/M5) | 10 |

The class I result (everything `ERR: TMH` under full expression) is consistent with the owner's real-bundle smoke test, which expects "most carry ERR: TMH / ERR: TMG / ERR: NO HAP" ([GenotypeRealBundleSmokeTests.swift:135](Tests/LungfishGenotypeUITests/GenotypeRealBundleSmokeTests.swift:135)). The class I behaviour is therefore loud, not wrong. The six wrong-but-called class II cases are the silent defects.

**Impact**

- Homozygous DQ M2 or M6, DR M4 or M5, and DP M4 or M7 animals get a confident heterozygous haplotype call.
- The call feeds the pivot "Haplotype 1/2" rows, the Excel export and breeding or cohort decisions.
- Homozygosity is exactly what MCM colony managers select on, so these are the calls most likely to be acted on.

**Recommendation**

- **Analyzer.** A haplotype should only enter `matched` when it has at least one observed allele that is not explained by another matched haplotype. An equivalent rule: require complete primary evidence (`hasCompletePrimaryEvidence`) for the match, not only for dominance. The primaries of M6 (0022) and M5 (0175) are unique, and an M2/M2 or M4/M4 animal lacks them.
- **Ambiguity output.** When two haplotypes have identical definitions at a locus (DP M4 and M7), emit an ambiguity token such as `M4|M7` with status `review`, never a heterozygous pair.
- **Definition check.** Add a lint in `HaplotypeDefinitionCommandService` that rejects or warns on haplotypes with identical required sets. It should also warn when `minimumMatches` is below the number of unique alleles.
- **Rollout.** Per the consensus rules, add a golden test and a release-note line, and bump the haplotype-analysis cache version so stored analyses are recomputed.

**Acceptance test.** A Swift unit test builds synthetic calls for all 28 genotypes at DQ, DR and DP from the shipped definition, with each allele at 100 reads per haplotype copy. No genotype may be `called` with a haplotype pair different from the truth. DP M4/M7-class cases must come out as an explicit ambiguity.

**Effort:** M. The rule change is small, but the golden set and the owner's review of MCM expectations take time.

---

### GEN-03 (P1): `--min-support` does not filter report rows

**Evidence**

- The CLI help says: "Minimum retained unique-read support required for a genotype row in the report and workbook" ([FastqGenotypingSubcommand.swift:52](Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift:52)).
- The filter script parses `--min-support` ([Scripts.swift:47](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:47)) but only writes it into stats and provenance ([Scripts.swift:567](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:567)). Every `(sample, genotype)` pair is written to the CSV.
- The pipeline workbook is written with `filter: .unfiltered` ([GenotypePipelineExcelReport.swift:62](Sources/LungfishWorkflow/ONTGenotyping/GenotypePipelineExcelReport.swift:62)).
- `minSupport` is used only as the `absolute` term of the haplotype dropout evaluator when it is greater than 1 ([ONTBarcodeDemuxGenotypingPipeline.swift:315](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:315)).

**Reproduction (Confirmed).** Scratchpad `gen/e1`, filter run with `--min-support 15`. The stats say `"minSupport": 15`, yet the CSV still contains the rows with 14, 11 and 9 unique reads.

**Impact**

- Users who set a minimum (the GUI field "Minimum supporting reads" at [WorkflowOperationsDialog.swift:302](Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift:302)) believe single-read cross-talk rows were removed from the long CSV and workbook. They were not.
- Haplotypes are computed with the threshold, but the allele table next to them is not filtered. The two disagree.

**Recommendation.** Choose one of these:

- (a) Apply `min_support` in the filter when writing `genotype_rows`, while keeping sample totals over all retained reads.
- (b) Keep the report unfiltered by design, and rename and re-document the option as "Minimum reads for haplotype evidence".

Option (b) is the smaller change and keeps raw evidence intact. Whichever is chosen, make the provenance `resolvedDefaults` truthful (see GEN-12).

**Acceptance test.** The `e1` fixture with `--min-support 15` either omits the 14, 11 and 9 read rows, or the help, GUI label and provenance state that the threshold applies only to haplotype evidence.

**Effort:** S.

---

### GEN-04 (P1): Tied reads are credited to every tied allele, arbitrarily beyond 6

**Evidence**

- minimap2 runs with `-a -x <preset> --MD` and no `-N`/`--secondary` control ([ONTBarcodeDemuxGenotypingPipeline.swift:3056](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:3056)). The minimap2 defaults therefore apply: up to 5 secondary alignments per read.
- Secondary records keep soft clips and MD, so they pass the filter. Every passing record adds its weight to `genotype_alignment_counts` and its name to `genotype_unique_reads` for that reference ([Scripts.swift:469](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:469)).
- The sample total counts each name once. Per-allele counts can therefore add up to more than the sample.
- Nothing marks an allele row as shared with another.
- The full-length path does the same for ties ([FullLengthONTMHCClusterGenotyper.swift:306](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift:306), [FullLengthONTMHCClusterGenotyper.swift:678](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift:678)).

**Reproduction (Confirmed).** Scratchpad `gen/e1`: eight references with an identical 200 bp amplicon, one with 6 SNPs, and 20 perfect reads.

```
genotype          passed_unique_reads
..._007g7  19 | ..._001g1 17 | ..._003g3 17 | ..._004g4 17
..._006g6  16 | ..._002g2 14 | ..._008g8 11 | ..._005g5  9
sample passed_alignments 120 (= 20 x 6), sample unique 20
```

Expected: 20 for each of the eight identical alleles, flagged as one ambiguity group. Alternatively, one collapsed record with 20 reads. With a 10-read threshold, `005g5` alone would be dropped. Its evidence is identical to the others.

**Scope note.** The shipped MCM reference has no identical sequences, and I verified that exact reads are uniquely credited. The defect bites user-built references, which any FASTA or `.lungfishref` passed to `--reference` can be, since there is no duplicate-sequence check at load ([ONTBarcodeDemuxGenotypingPipeline.swift:2849](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2849)). IPD-MHC exon 2 sets are full of identical amplicons.

**Impact**

- Custom-reference users get "heterozygous-looking" lists of alleles that are really one ambiguous group, with arbitrary unequal counts.
- The "Viewed Locus" and analyzer denominators (sums over calls) are inflated by the tie multiplicity.

**Recommendation**

- At reference resolution, group identical sequences (including reverse complements) and either refuse the reference or map to one representative per group.
- Carry the group members into the call as an `ambiguousWith` list, as the 12S reassigner does for its case.
- If ties must remain, pass `--secondary=yes -N <refCount>`, or post-process so every equal-best hit is counted. Mark such rows as ambiguous.
- Compute locus and sample denominators from unique read names, never as sums of per-allele counts.

**Acceptance test.** The `e1` fixture produces one call with 20 reads listing all eight IDs as an ambiguity group, or eight rows of 20 each carrying the same ambiguity group ID. Sample and locus denominators are 20. A reference with duplicate sequences produces a provenance warning.

**Effort:** M.

---

### GEN-05 (P1): Three different "locus" denominators

**Evidence**

- **Pipeline and live haplotype filter** (`applyDropout`). The locus total is the sum of `passedUniqueReads` per `GenotypeHaplotypeLocusResolver.canonicalLocus`. That function prefers the `haplotype_groups` metadata ([GenotypeHaplotypeAnalyzer.swift:544](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:544), [GenotypeHaplotypeLocusResolver.swift:100](Sources/LungfishIO/Bundles/GenotypeHaplotypeLocusResolver.swift:100)). In the MCM reference, `haplotype_groups=MHC-A` pools 18 source loci: A1, A2, A4, A5, AG1-6, G, E, F, I, J, K and L. `MHC-DQ` pools DQA1 with DQB1.
- **Matrix "Viewed Locus".** The denominator groups by `call.locusGroup`, which is the canonicalized `source_loci` ([ONTGenotypeResultBundle.swift:1738](Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:1738)). Here G, AG, E, F, I and K are separate groups, and DQA1 and DQB1 are separate.
- **Sample denominator.** The analyzer sums per-allele reads. The matrix "Sample Retained" uses `sampleUniqueRetainedReads` from the CSV ([ONTGenotypeResultBundle.swift:1757](Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:1757)). They differ whenever GEN-04 ties exist.
- **Name-based fallback.** Without metadata, `haplotypeEvidenceLocusName` maps I, J and K to MHC-B ([GenotypeHaplotypeLocusResolver.swift:68](Sources/LungfishIO/Bundles/GenotypeHaplotypeLocusResolver.swift:68)). The shipped metadata puts them in MHC-A. The name heuristic and the metadata therefore disagree for references without `haplotype_groups`.

**Worked example.** One animal with A1 3,000 reads, AG 2,000, E 1,500, and two G alleles of 75 each. Locus threshold 5%.

| View | Denominator for a G allele | G share | Result |
|---|---|---|---|
| Haplotype analyzer (pipeline and live) | 6,650 (MHC-A group) | 1.1% | Dropped |
| Matrix, "Viewed Locus" 5% | 150 (MHC-G) | 50% | Shown as passing |

G alleles 0003 and 0004 are M1 diagnostics. The haplotype call silently excludes evidence that the matrix shows as above threshold.

**Impact.** A user checking a haplotype call against the matrix sees evidence that "passes 5%" but was not used, and the reverse. The same field name means different things in two panes.

**Recommendation**

- Define one `GenotypeLocusDenominator` in LungfishIO, with an explicit choice of the source locus or the haplotype group.
- Use it in `applyDropout`, `supportFilteredCalls`, the evidence pane ([GenotypeResultViewController.swift:3196](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:3196)) and the Excel filter.
- Show which grouping is active in the threshold UI, the workbook "Filters" sheet and provenance.
- Compute denominators from unique reads.

**Acceptance test.** For the worked example, the matrix, the evidence pane and the haplotype analyzer report the same percentage for each G allele under the same setting. A unit test pins the grouping for a record with `source_loci=MHC-G|haplotype_groups=MHC-A`.

**Effort:** M.

---

### GEN-06 (P1): "Minimum percent" changes meaning for candidate rows

**Evidence**

- For known alleles, the matrix filter compares each occurrence's read fraction with the threshold ([GenotypeMatrixBaseProjection.swift:264](Sources/LungfishIO/Bundles/GenotypeMatrixBaseProjection.swift:264)).
- For candidate (novel or unmatched cluster) rows, the same `matrixMinimumPercent` and `globalMinimumPercent` are compared with `candidatePopulationFraction`. That is the number of animals with the candidate divided by the number of animals in the run ([GenotypeMatrixBaseProjection.swift:299](Sources/LungfishIO/Bundles/GenotypeMatrixBaseProjection.swift:299), [GenotypeMatrixBaseProjection.swift:359](Sources/LungfishIO/Bundles/GenotypeMatrixBaseProjection.swift:359)).
- The Excel snapshot copies this ([GenotypeExcelSnapshotBuilder.swift:188](Sources/LungfishWorkflow/ONTGenotyping/GenotypeExcelSnapshotBuilder.swift:188)) and records "Candidate percent basis: Positive supporting samples / full logical sample roster" on the filter sheet ([GenotypeExcelSnapshotBuilder.swift:416](Sources/LungfishWorkflow/ONTGenotyping/GenotypeExcelSnapshotBuilder.swift:416)).

**Worked example.** 30 animals, "Min %" = 5.

- A novel allele carried by 1 animal at 60% of that animal's locus reads has population fraction 1/30 = 3.3%. It is hidden, row and all.
- A candidate seen in 2 animals at 0.2% of reads each (a typical chimera or cross-talk profile) has 2/30 = 6.7%. It is shown in both animals.

**Impact.** Private novel alleles, the most important thing to review in an outbred or new cohort, disappear. Low-level artefacts shared across animals stay. The screen and export are consistent with each other (the Preserve item works), but both are misleading.

**Recommendation.** Filter candidate cells by the same per-sample read fraction and denominator as known alleles. If a prevalence filter is wanted, make it a separate, separately named control ("Seen in at least N% of animals").

**Acceptance test.** In the worked example, the 60% private allele stays visible and the 0.2% shared candidate is hidden. The workbook filter sheet lists both controls separately.

**Effort:** S.

---

### GEN-07 (P1): Illumina retention % divides fragments by mates

**Evidence**

- The per-sample `readCount` is `countWeightedFASTQRecords(fastqURL)` on the input FASTQ before merging. Each mate of an interleaved pair is one record ([ONTBarcodeDemuxGenotypingPipeline.swift:2434](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2434)). Bundle or metadata overrides are used when present ([ONTBarcodeDemuxGenotypingPipeline.swift:2467](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2467)), but their pair or mate unit is not stated.
- `mergeIlluminaPairsIfNeeded` swaps the mapping FASTQ to merged plus unmerged reads but does not update `readCount` ([ONTBarcodeDemuxGenotypingPipeline.swift:2372](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2372)).
- The filter uses `totalPairs or readCount` as `sample_total_reads` ([Scripts.swift:178](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:178)).
- Unmerged mates keep their identifier, so the retained unique count depends on the read-name style. Casava names count one per pair. `/1` and `/2` names count two per pair, because the sample prefix does not strip the suffix, although `fragmentKey` does for pairing ([IlluminaAmpliconPairMerger.swift:106](Sources/LungfishWorkflow/ONTGenotyping/IlluminaAmpliconPairMerger.swift:106), [ONTBarcodeDemuxGenotypingPipeline.swift:2626](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2626)).

**Worked example.** 1,000 pairs, 900 merged and 100 unmerged, all passing.

| Quantity | Value |
|---|---|
| `sample_total_reads` | 2,000 |
| Retained unique, Casava names | 1,000, so 50.0% |
| Retained unique, `/1` `/2` names | 1,100, so 55.0% |
| Pivot `percent_reads_unmapped` ([FullLengthONTMHCPivotWorkbookBuilder.swift:101](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCPivotWorkbookBuilder.swift:101)) | 50% or 45% |
| True fragment retention | 100% |

**Impact.** Sample QC numbers are wrong by about a factor of 2 for unmerged-input runs. Retention depends on read-name convention. Short class I amplicons can be double counted under `/1` and `/2` naming.

**Recommendation**

- Recount the sample total in fragments after merging: merged + unmerged/2, or `Outcome.pairCount`.
- Label the unit in the manifest (`"readCountUnit": "fragments"`).
- Collapse unmerged mates to one fragment key when counting unique reads.

**Acceptance test.** The worked example reports `sample_total_reads = 1000` and 100% retention under both naming styles.

**Effort:** S.

---

### GEN-08 (P2): "-" means both homozygous and unresolved

**Evidence**

- A single matched haplotype yields `haplotype2 = "-"`, status `called` ([GenotypeHaplotypeAnalyzer.swift:699](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:699)). So does the MHC-B homozygote rescue ([GenotypeHaplotypeAnalyzer.swift:710](Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift:710)).
- The caller never emits `h1 == h2`.
- The viewer shows `h1` alone when `h2` is "-" or equal to `h1` ([GenotypeResultViewController.swift:3782](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:3782)).

**Impact.** "M1" on screen can mean M1/M1, or M1 plus a novel or undefined haplotype. These need different follow-up work.

**Recommendation.** Emit `h2 = h1` with a `homozygous` note only when the evidence supports it (for example no residual unexplained alleles and balanced primaries). Otherwise emit an explicit `?` or `unresolved` with status `review`. Display "M1 / M1" and "M1 / ?" distinctly.

**Acceptance test.** Synthetic M1/M1 and M1/(novel) animals render differently in the matrix, the pivot and Excel.

**Effort:** S.

---

### GEN-09 (P2): Colliding barcodes are silently resolved in the Python filter

**Evidence.** `barcode_regex` keeps the first sample for a repeated pattern (`if pattern not in pattern_to_sample`) ([Scripts.swift:251](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:251)). A barcode equal to another sample's reverse complement collides the same way. `ONTFluidigmBarcodeCollisionValidation` exists, but it is called only by the two Swift materializers.

**Impact.** A sample-sheet typo in `fastq genotype --barcodes` sends every read of one animal to another animal, with no error.

**Recommendation.** Run the same validation on the barcode sheet in `prepareInputPlan` before the filter. This becomes moot if GEN-01 moves demux into shared Swift code.

**Acceptance test.** A sheet with two rows sharing a barcode, or a barcode and its reverse complement, fails fast with the existing `duplicateBarcodeSequence` message.

**Effort:** S.

---

### GEN-10 (P2): Full-length ONT treats any zero-SNP hit as known, whatever its indels

**Evidence**

- For genomic references, `isKnownGenotype = hit.snps == 0` ([FullLengthONTMHCClusterGenotyper.swift:244](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift:244)). Indel bases only lower the score (10 per base).
- An indel-free partial-coverage hit is deferred as an "extension" candidate ([FullLengthONTMHCClusterGenotyper.swift:259](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift:259)). A hit with, for example, a 9 bp deletion is called as the known allele.
- The call row carries no indel count.

**Impact**

- A true indel allele (in-frame deletion, or frameshift null) that is identical to a known allele elsewhere is reported as that known allele.
- A truncated but otherwise perfect cluster becomes a candidate. This is the inverse of the expected strictness.

**Recommendation**

- Allow indels only up to a homopolymer-error budget: for example, indel runs of at most 2 bp inside homopolymers, and a total cap.
- Send anything larger to the candidate or closest-match path.
- Store `indelBases` on the call.

**Acceptance test.** A cluster equal to allele X except for a 9 bp non-homopolymer deletion is not called X. It appears in the closest-match list with `indelBases = 9`.

**Effort:** S.

---

### GEN-11 (P2): PacBio exact dual-barcode assignment order is not deterministic

**Evidence.** `leftToRight` is a Swift `Dictionary`, and the loop takes the first `(leftBC, targets)` that matches ([ExactBarcodeDemux.swift:194](Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift:194), [ExactBarcodeDemux.swift:299](Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift:299)). Swift seeds hashing per process, so iteration order changes between runs. A read that satisfies two sample pairs goes to a different animal on different runs. Such reads are chimeras, or come from asymmetric designs that share one barcode across samples.

**Impact.** Rare, but not reproducible. Chimeras are assigned instead of being rejected.

**Recommendation**

- Collect all matching pairs.
- Assign only when exactly one sample matches. Count multi-matches as `chimeric/ambiguous`.
- Iterate in a sorted order.

**Acceptance test.** A read containing the barcode pairs of samples A and B is unassigned with the reason `ambiguous`, identically across 10 process launches.

**Effort:** S.

---

### GEN-12 (P2): Provenance and QC gaps

**Evidence**

- Run provenance lists `managedTools` as minimap2, samtools, pysam and openpyxl only ([ONTBarcodeDemuxGenotypingPipeline.swift:4480](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:4480)). bbtools/bbmerge is missing even when it ran. The merge argv is in the manifest, but its version is not.
- Tool versions come from the lock manifest, not from `--version` of the binary that ran.
- The filter provenance `resolvedDefaults` hard-codes `haplotypeMinSamplePercent: 0.0` and the locus equivalents whatever was passed ([Scripts.swift:589](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:589)).
- Sample QC status `lowSupport` uses fixed cut-offs of fewer than 20 alignments or fewer than 1,000 unique reads, for both MiSeq and ONT. These are neither configurable nor recorded ([ONTGenotypeResultBundle.swift:996](Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:996)).
- Barcode-mode sample totals are always null (synthesized manifest, [ONTBarcodeDemuxGenotypingPipeline.swift:2731](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2731)). ONT per-animal retention % is therefore never available.
- (D5 lens.) Every MCM-preset run copies the AI specialist prompt into `artifacts/ai-haplotyping/prompts` and hashes it into provenance ([ONTBarcodeDemuxGenotypingPipeline.swift:3980](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:3980)), although AI haplotyping is disabled.

**Recommendation**

- Add `bbtools` to `managedTools` when merging ran.
- Record the executed tool version from the binary.
- Emit the thresholds that took effect.
- Record the QC cut-offs, and make them preset fields.
- Skip the prompt snapshot while D5 is in force.

**Acceptance test.** A merged-input run's provenance contains a bbtools descriptor and the true threshold values. An MCM run with AI disabled has no `artifacts/ai-haplotyping` directory.

**Effort:** S.

---

### GEN-13 (P2): Legacy `fastq ont-genotype` pipeline

**Evidence**

- Maps ONT reads with `MappingMode.defaultShortRead` and read group platform `ILLUMINA` ([ONTGenotypingPipeline.swift:278](Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPipeline.swift:278)).
- Passes `--allow-indels`, which the script parses and never reads ([ONTGenotypingPysamFilterRunner.swift:130](Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPysamFilterRunner.swift:130)). Indels are always allowed.
- Secondary records have an empty `query_sequence` and always fail the mismatch check ([ONTGenotypingPysamFilterRunner.swift:188](Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPysamFilterRunner.swift:188)). Only the primary counts.

**Reproduction (Confirmed).** On the `e1` tie fixture, the 20 reads are split 3/3/3/3/2/2/2/2 across the eight identical alleles. With `--min-support 5`, the sample reports no allele at all. This is the opposite of the main pipeline's behaviour for the same input (GEN-04).

**Impact.** A CLI-only path (no GUI entry point) that gives different answers from `fastq genotype` for the same data.

**Recommendation.** Deprecate it in favour of `fastq genotype --mode ont-sample-bundles`, or hide it (consensus rule "hide rather than ship broken"). Do not invest in fixing it.

**Acceptance test.** `lungfish-cli fastq ont-genotype --help` shows the deprecation, or the command is removed from the command list.

**Effort:** S.

## Proposed work packages

Order matters. Package G1 changes which animal a read belongs to, and G2 changes haplotype calls. Both need golden tests and release-note lines under the consensus rules.

1. **G1: anchored, conflict-aware demultiplexing (GEN-01, GEN-09, GEN-11). P0.**
   - Files: new shared Swift barcode assigner in `LungfishWorkflow/ONTGenotyping`, used by `ONTFluidigmAmpliconMaterializer`, `ONTFluidigmSampleMaterializer` and `ONTBarcodeDemuxGenotypingPipeline+Scripts.swift`. The last one either receives the rule or switches ONT demux to pre-mapping materialization plus `query-prefix`. Also `ExactBarcodeDemux.swift`, and the collision validation call in `prepareInputPlan`.
   - Risk: medium-high. Per-animal counts change for existing ONT results. Keep old bundles readable and mark them in the viewer as "pre-G1 demux".
   - Tests: the `e3` fixture, the mismatched-anchor fixture, the collision sheet and the ambiguous dual-barcode read.
2. **G2: haplotype match rule and ambiguity output (GEN-02, GEN-08). P0.**
   - Files: `GenotypeHaplotypeAnalyzer.swift`, `GenotypeHaplotypeAnalysis.swift` (status or ambiguity token), a definition lint in `HaplotypeDefinitionCommandService.swift`, and display in `GenotypeResultViewController.swift` and the pivot builder.
   - Risk: medium. Needs the owner to confirm expected MCM calls. Bump the analysis cache version.
   - Tests: a 28-genotype golden set per class II locus from the shipped definition.
3. **G3: one threshold semantics (GEN-03, GEN-05, GEN-06, GEN-07).**
   - Files: `Scripts.swift` (min-support or its re-labelling, fragment totals), `ONTBarcodeDemuxGenotypingPipeline.swift` (fragment `readCount`), a new shared denominator type in LungfishIO, `ONTGenotypeResultBundle.swift`, `GenotypeMatrixBaseProjection.swift`, `GenotypeExcelSnapshotBuilder.swift`, the evidence pane, and the CLI and GUI help text.
   - Depends on G2 for the analyzer side. Risk: medium, since visible numbers change.
4. **G4: ties and reference hygiene (GEN-04, GEN-10).**
   - Files: reference resolution in `ONTBarcodeDemuxGenotypingPipeline.swift` (duplicate-sequence grouping), `FullLengthONTMHCClusterGenotyper.swift` (ambiguity list, indel budget), and the call model (`ambiguousWith`).
   - Independent of G1 to G3. Risk: low for the MCM preset (no ties), medium for custom references.
5. **G5: provenance and cleanup (GEN-12, GEN-13).** Small and independent. Can land any time.

**Do not fix / accept:**

- The notebook-compatible "indels allowed, zero mismatches" rule for amplicons. It is the right tolerance for ONT homopolymer errors, and with the shipped reference it cannot credit a read across a SNP.
- Exact-match barcode sensitivity loss on ONT (reads with a barcode error go unassigned). It reduces yield, not correctness, once G1 lands.
- The `ERR: TMH` outcomes at class I under full expression. They are loud, owner-expected and routed to manual review, and changing them is a curation decision, not a code defect.

## Reproduction notes

All synthetic experiments live in the session scratchpad under `gen/`. They can be rebuilt from the descriptions above.

- `filter.py` and `simple_filter.py` were extracted byte-for-byte from the `#"""…"""#` literals in `ONTBarcodeDemuxGenotypingPipeline+Scripts.swift` and `ONTGenotypingPysamFilterRunner.swift`.
- `e1`: identical-allele tie fixture (GEN-03, GEN-04, GEN-13).
- `e2`: shipped-reference cross-pass check and indel-distance scan. The shipped reference was clean.
- `e3`: barcode k-mer misassignment (GEN-01).
- The haplotype port for GEN-02 re-implements `callHaplotype` (match rule, `dominantTopTwoMatches`) and nothing else. It omits the MCM class I rescue paths, which are keyed on `sourceLocus == "Mafa-A"` and do not fire for the shipped definition's `"MHC-A"`. It also omits the DQ-linked DP resolver.

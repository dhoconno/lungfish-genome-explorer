# Scientific correctness, data integrity and reproducibility audit (SCI)

Audit date: 2026-09-23. Worktree HEAD a1f439076. Reviewer area: scientific correctness, data integrity, reproducibility. Finding prefix: SCI.

## Scope

- Native parsers and writers in `Sources/LungfishIO` and `Sources/LungfishCore`. This covers SAM/CIGAR, BED, GFF3/GTF, GenBank locations, VCF import, FASTA/FAI (plain and bgzip), and FASTQ.
- Coordinate conversions and extraction (`SequenceExtractor`, region to bundle extraction, variant and annotation transforms).
- Statistics: Nx, GC, mapping rate and per-contig read percentages, NAO-MGS coverage, duplicate counts.
- External tool invocation in `Sources/LungfishWorkflow`. Covers iVar, LoFreq, bcftools, samtools, kraken2 and Bracken, clumpify, seqkit and reformat.sh.
- Data safety of in-place mutation and deletion paths. Provenance recording for variant calling, mapping, consensus and classification.

## Method

- Read the code and traced control flow from the GUI and CLI entry points down to argv construction and output parsing.
- Where it was feasible I reproduced tool behaviour with the managed tool installs at `~/.lungfish/conda/envs/*`: samtools 1.24, bcftools 1.24, ivar, lofreq, kraken2 wrapper and seqkit 2.13. I ran them on tiny synthetic SAM, FASTA and GFF inputs in the session scratchpad. I also used the checked-in SARS-CoV-2 fixture `Tests/Fixtures/sarscov2/genome.fasta` (MT192765.1).
- I ran one 4-line standalone `swift` interpreter script to confirm a Foundation string operation. This did not use SwiftPM and did not touch `.build`.
- I did not build, test or modify any repository file.

## Limits

- I did not run LGE itself. A finding marked **Confirmed** means I reproduced the external-tool or string behaviour that the LGE code path feeds. The LGE side of that path is **Traced** unless stated otherwise.
- Genotyping (MHC), primer design, Viral Recon (nf-core) and the GUI renderers were only sampled.
- About 95K lines of LungfishIO and a similar volume of Workflow code exist. I sampled widely and dug into the paths most likely to change a published number.

## Executive summary

The low-level primitives are mostly correct and some are unusually careful. SAM POS/CIGAR handling, BED/GFF/GenBank to 0-based half-open conversion, VCF `END`, the shared Nx function, the strict FASTQ parser, and the samtools consensus snapshot pipeline all check out. The problems sit one layer up, where LGE glues tools together or decides defaults for the user.

The most serious defects are in the viral variant-calling path, which is the app's flagship scientific workflow:

- The GFF that LGE hands to iVar collapses every multi-segment CDS into one span. This breaks the SARS-CoV-2 ORF1ab -1 frameshift and every spliced CDS, and changes which SNPs LGE merges into codon haplotypes.
- The iVar TSV to VCF converter emits duplicate records for overlapping CDS.
- The minimum allele frequency and depth fields are silently ignored for four of five callers. Provenance still records them as applied.
- bcftools runs with diploid genotyping and a 250-read depth cap on viral amplicon data.

Mapping statistics count alignment records instead of reads. Annotation extraction ignores strand and splicing. Reverse-complement region extraction leaves variants untransformed. Illumina imports apply lossy quality binning by default, and silently on downloads.

The provenance system is extensive: argv, versions, checksums, database identity receipts, seeds. It should be preserved. In several places, though, it records the parameters the user asked for rather than those that took effect.

My overall judgment: LGE's numbers are trustworthy for display and simple extraction on forward-strand, unspliced, LF-terminated data. They are not yet trustworthy for publication-grade variant calls or mapping QC without the fixes in work packages A and B.

## Preserve (do not "fix" these away)

- `SequenceLengthStatistics.threshold`/`nx`: one shared, overflow-safe Nx implementation used by FASTQ, CLI, ONT and assembly code ([SequenceLengthStatistics.swift:7](Sources/LungfishCore/Models/SequenceLengthStatistics.swift:7)). I checked the `count > (remaining-1)/length` test against `count*length >= remaining` and they are equivalent.
- `SAMParser.parseLine`: POS and PNEXT converted to 0-based, `*` SEQ/QUAL handled, unmapped skipped ([SAMParser.swift:286](Sources/LungfishIO/Formats/SAM/SAMParser.swift:286)). `CIGAROperation.consumesReference/consumesQuery` are correct for M/I/D/N/S/H/P/=/X ([AlignedRead.swift:49](Sources/LungfishCore/Models/AlignedRead.swift:49)).
- GFF3/GTF/GenBank to internal coordinates: `start-1, end` everywhere I checked ([GFF3Reader.swift:112](Sources/LungfishIO/Formats/GFF/GFF3Reader.swift:112), [GTFReader.swift:126](Sources/LungfishIO/Formats/GFF/GTFReader.swift:126), [GenBankReader.swift:988](Sources/LungfishIO/Formats/GenBank/GenBankReader.swift:988)). VCF `END` is used as the half-open end ([VariantDatabase+Classification.swift:137](Sources/LungfishIO/Bundles/VariantDatabase+Classification.swift:137)), and symbolic, `*` and breakend ALTs are classified as complex.
- `FASTQReader`: supports wrapped records, never treats a quality line starting with `@` as a header, and checks quality length ([FASTQReader.swift:255](Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift:255)).
- `AlignmentDataProvider.fetchConsensus`: an immutable filtered snapshot. It clears samtools' implicit flag masks (`--ff 0`, `-g 1796`), records the samtools version and per-stage argv, and applies explicit deletion and insertion policies ([AlignmentDataProvider.swift:763](Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:763)). `fetchDepth` uses the correct `-q`/`-Q` semantics for `samtools depth`.
- `convertBAMToSingleFASTQ`: the 4-way `-0/-1/-2/-s` split prevents the classic `samtools fastq` silent read loss ([BAMToFASTQConverter.swift:68](Sources/LungfishWorkflow/Extraction/BAMToFASTQConverter.swift:68)).
- `AnnotationDatabaseRecord.transformed`: correct BED12 reverse-complement coordinate mirroring and strand flip for extracted annotations ([AnnotationDatabaseRecord.swift:133](Sources/LungfishIO/Bundles/AnnotationDatabaseRecord.swift:133)).
- `BundleVariantTrackAttachmentService`: stages artifacts, then rolls back the promoted files and restores the manifest on any failure ([BundleVariantTrackAttachmentService.swift:143](Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift:143)). `NativeBundleBuilder` builds in a hidden staging directory and refuses to overwrite ([NativeBundleBuilder.swift:822](Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift:822)).
- The GUI subsample path draws a random seed and records it, and it is pair-aware for interleaved bundles ([FASTQDerivativeService+Transformations.swift:32](Sources/LungfishApp/Services/FASTQDerivativeService+Transformations.swift:32)). BLAST subsampling uses a seeded RNG.
- iVar `mpileup` argv matches the viralrecon recipe (`-aa -A -d 600000 -B -Q 20 -q 0`) ([ViralVariantCallingPipeline.swift:1227](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1227)).
- Provenance framework (`Sources/LungfishWorkflow/Provenance`, about 11K lines): per-step tool version, argv, exit code, stderr, file records, and metagenomics database identity receipts ([MetagenomicsDatabaseInstallProvenance.swift:579](Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstallProvenance.swift:579)). The fixes below should feed this system more accurately, not replace it.
- Plain `FASTAIndex.fetch` strips both LF and CR ([FASTAIndex.swift:286](Sources/LungfishIO/Index/FASTAIndex.swift:286)). The bgzip reader should copy this behaviour (SCI-12).

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| SCI-01 | P0 | GFF exported to iVar collapses multi-segment CDS (ORF1ab frameshift, spliced CDS) into one span, which changes codon-merged VCF records | Confirmed (iVar) + Traced (LGE) | S |
| SCI-02 | P1 | iVar TSV to VCF converter emits duplicate records for overlapping CDS (ORF1a/ORF1ab) | Confirmed (iVar) + Traced (LGE) | S |
| SCI-03 | P1 | Minimum AF and depth thresholds silently ignored for LoFreq, bcftools, Medaka and Clair3, yet recorded in provenance | Confirmed | S |
| SCI-04 | P1 | bcftools caller runs with diploid ploidy and max-depth 250 on viral data | Confirmed | S |
| SCI-05 | P1 | Mapping "reads mapped / total" and per-contig % count alignment records (secondary and supplementary), not reads | Confirmed | S |
| SCI-06 | P1 | Annotation extraction ignores strand and splicing, and the core API applies 5'/3' flanks by coordinate | Traced | M |
| SCI-07 | P1 | Region to bundle extraction with Reverse Complement does not transform variants | Traced | M |
| SCI-08 | P1 | Lossy quality binning on by default (silent on downloads and FASTQ operation outputs), mislabelled schemes, originals deleted | Traced | M |
| SCI-09 | P1 | NAO-MGS "coverage %" uses the furthest alignment end as reference length when references were not fetched | Traced | S |
| SCI-10 | P2 | CDS translation ignores `/codon_start`, GFF phase and `/transl_table`, and reverse-strand phase comes from the wrong end | Traced | M |
| SCI-11 | P2 | GFF3 export writes phase 0 on every CDS segment, splits one CDS into distinct IDs, and leaves a dangling `Parent` | Traced | S |
| SCI-12 | P2 | Bgzip FASTA reader returns `\r` and drops bases for CRLF FASTA | Confirmed (string op) + Traced | S |
| SCI-13 | P2 | User-visible `chr:start-end` strings mix 0-based and 1-based conventions | Traced | S |
| SCI-14 | P2 | Variant track chromosome aliasing silently matches by length or max-position (up to 20% tolerance) | Traced | S |
| SCI-15 | P2 | Origin-spanning features on circular genomes are sorted by start, which reorders segments | Traced (frequency Suspected) | M |
| SCI-16 | P2 | Interleaved paired FASTQ subsample via the CLI-backed Operations path is not pair-aware | Suspected | S |
| SCI-17 | P2 | Markdup shell pipeline: no `pipefail`, double-quote interpolation of paths, duplicate fraction over alignment records | Traced / Suspected | S |
| SCI-18 | P2 | Bracken always uses the 150 bp distribution regardless of actual read length | Traced | S (document) |
| SCI-19 | P3 | `kraken2 --fasta-input` is not a Kraken2 option (warning only) but is recorded in provenance | Confirmed | S |
| SCI-20 | P3 | Assembly statistics drop IUPAC codes from contig length and count N in the GC denominator | Traced | S |
| SCI-21 | P3 | Variant extraction keeps the full REF for records straddling the region start | Traced | S |

---

### SCI-01 (P0): GFF exported to iVar collapses multi-segment CDS into one span

**Evidence**
- When a GFF3 has several CDS lines sharing one `ID`, the annotation builder merges them into one database row spanning `min(start)..max(end)`, with the segments kept only as BED12 blocks ([AnnotationDatabase+Building.swift:493](Sources/LungfishIO/Bundles/AnnotationDatabase+Building.swift:493)). This is the NCBI RefSeq representation of ORF1ab: `CDS 266..13468` and `CDS 13468..21555`, both `ID=cds-YP_009724389.1`.
- Before iVar runs, `exportBundleGFFIfAvailable` writes the bundle's annotations with `AnnotationDatabaseGFFExporter.export` ([ViralVariantCallingPipeline.swift:1270](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1270)). The exporter writes one line per row using `record.start+1 .. record.end`. It ignores `block_count/block_sizes/block_starts` and takes the phase from the first segment's attributes ([AnnotationDatabaseGFFExporter.swift:21](Sources/LungfishWorkflow/Annotation/AnnotationDatabaseGFFExporter.swift:21)).
- iVar receives this file via `-g` ([ViralVariantCallingPipeline.swift:1241](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1241)). LGE's converter then merges adjacent SNPs whose iVar `REF_CODON`/`ALT_CODON` match ([IVarCodonMerger.swift:74](Sources/LungfishWorkflow/Variants/IVarCodonMerger.swift:74), [IVarCodonMerger.swift:87](Sources/LungfishWorkflow/Variants/IVarCodonMerger.swift:87)).

**Reproduction (Confirmed with managed ivar)**

I used fixture MT192765.1, whose ORF1ab segments are 259..13461 and 13461..21548. Reads carry SNPs at 14402 T>C and 14403 A>G. I compared a split GFF (what the source says) with a merged GFF (what LGE exports):

| GFF given to iVar | 14402 REF_CODON | 14403 REF_CODON | LGE merger decision |
|---|---|---|---|
| split (correct -1 frameshift) | CTT | ACA | two SNP records |
| merged span 259..21548 (LGE export) | TTA | TTA | one MNP record `TA>CG` |

A single SNP 14401 T>C gives `L>P` (non-synonymous) with the correct GFF and `L>L` (synonymous, POS_AA 4715) with the merged GFF.

**Impact**
- Every SARS-CoV-2 ORF1b variant (nsp12 to nsp16) called with iVar on an NCBI-annotated bundle goes through codon logic in the wrong frame. The same holds for any spliced or frameshifted CDS (influenza M2/NS2, HIV tat/rev, eukaryotic genes).
- Adjacent SNPs are merged into MNPs, or kept apart, incorrectly. The VCF record structure and the allele frequencies shown per record change.
- Any retained iVar TSV carries wrong amino-acid consequences.

**Recommendation**
- In `AnnotationDatabaseGFFExporter`, expand BED12 blocks into one GFF line per block with the same `ID`.
- Compute each segment's phase from the cumulative CDS length in transcription order. On the minus strand that order is descending.
- Preserve overlapping blocks. ORF1ab's blocks overlap by 1 nt, and the builder currently clips against a merged span; confirm it keeps both.
- Add a shared helper, `CDSSegmentPhases.compute(intervals:strand:)`, and reuse it in SCI-10 and SCI-11.

**Acceptance test**
- Build a bundle from the NCBI NC_045512.2 GFF3. Run the exporter and assert two ORF1ab CDS lines, 266..13468 and 13468..21555, both phase 0 and the same ID.
- Add a synthetic spliced minus-strand CDS whose exon 1 length is 10. Assert that the second segment in transcription order gets phase 2.
- End-to-end fixture: SNPs at 14402/14403 give two VCF records.

**Effort:** S.

### SCI-02 (P1): iVar converter emits duplicate VCF records for overlapping CDS

**Evidence**
- iVar writes one TSV row per overlapping GFF feature. I confirmed this with the managed ivar: a single SNP at 3030 inside ORF1a and ORF1ab gives two rows, `orf1ab:cds-orf1ab` and `orf1a:cds-orf1a`.
- `IVarTSVToVCFConverter.convert` maps every row through `IVarTSVRow.parse` and never deduplicates ([IVarTSVToVCFConverter.swift:73](Sources/LungfishWorkflow/Variants/IVarTSVToVCFConverter.swift:73)). Every SNP and indel is written, so duplicates carry through ([IVarTSVToVCFConverter.swift:85](Sources/LungfishWorkflow/Variants/IVarTSVToVCFConverter.swift:85)).
- Duplicate rows also break the adjacency grouping in `adjacentCodonGroups`. After 3030/orf1ab comes 3030/orf1a, so `pos == prev.pos + 1` fails and codon groups are split.
- The file header says it mirrors nf-core `ivar_variants_to_vcf.py`. I recall, without re-checking it, that the upstream script keeps one record per (CHROM, POS, REF, ALT). Verify against the pinned version.

**Impact**
- On NCBI SARS-CoV-2 bundles, which carry both ORF1a and ORF1ab, every variant in 266 to 13483 is stored twice. That inflates variant counts, per-sample counts and table rows.
- Downstream tools see non-unique records.
- Combined with SCI-01, haplotype merging in ORF1a also becomes unstable.

**Recommendation**
- Group TSV rows by (REGION, POS, REF, ALT) before merging. Keep one row, preferring the feature whose codon frame is authoritative, and collect every `GFF_FEATURE` in an INFO list.
- Run codon grouping per feature, then deduplicate the resulting records.

**Acceptance test:** A TSV fixture with duplicated rows for two overlapping CDS gives exactly one VCF record per allele, and adjacent-codon merging behaves the same as with the single-CDS fixture.

**Effort:** S.

### SCI-03 (P1): Min AF and min depth thresholds silently ignored for four callers

**Evidence**
- The GUI dialog shows "Minimum Allele Frequency 0.05" and "Minimum Depth 10" for every caller ([BAMVariantCallingToolPanes.swift:46](Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift:46)). It is pre-filled with those values ([BAMVariantCallingDialogState.swift:75](Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift:75)).
- The CLI exposes `--min-af` and `--min-depth` without saying which callers use them ([VariantsCommand.swift:819](Sources/LungfishCLI/Commands/VariantsCommand.swift:819)).
- Only `ivarVariantArguments` uses the values ([ViralVariantCallingPipeline.swift:1248](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1248)). LoFreq, bcftools, Medaka and Clair3 argv do not ([ViralVariantCallingPipeline.swift:1217](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1217), [:1306](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1306), [:1318](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1318), [:1329](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1329)).
- No post-call filter exists. `run` does reheader, sort, bgzip and tabix only ([ViralVariantCallingPipeline.swift:312](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:312)).
- `callerParametersJSON` still records `minimumAlleleFrequency`/`minimumDepth` for every caller ([ViralVariantCallingPipeline.swift:1348](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1348)). The help text claims thresholds "are both written with command provenance" ([LungfishHelpContent.swift:688](Sources/LungfishKit/LungfishHelpContent.swift:688)).

**Reproduction (Confirmed):** 2000 reads with a 4% alt allele. `lofreq call -f ref.fa -o out.vcf b.bam` emits `AF=0.040000;DP=2000` with FILTER PASS. With the dialog's 0.05 threshold, LGE would import this variant.

**Impact:** Low-frequency variants below the user's stated threshold appear in the track and in exports. The provenance says the threshold was applied, which is a reproducibility falsehood.

**Recommendation**
- Apply the thresholds uniformly with a post-call step, for example `bcftools view -i 'INFO/AF>=X && INFO/DP>=Y'`. The per-caller tag mapping needs care: LoFreq AF/DP, bcftools `FORMAT/AD`-derived AF, Clair3 `FORMAT/AF`.
- Record that step as its own provenance step.
- Alternatively, disable the fields and label them "iVar only". Either way, `callerParametersJSON` must record the effective threshold per caller, or `null`.

**Acceptance test:** A LoFreq run on the 4% fixture with min-AF 0.05 produces 0 records, and the provenance contains the filter step and expression. A run with min-AF 0.03 produces 1 record.

**Effort:** S.

### SCI-04 (P1): bcftools caller defaults are wrong for viral amplicon data

**Evidence:** `bcftoolsMpileupArguments` is `mpileup -Ou -f ref bam`, and `bcftoolsCallArguments` is `call <advanced> -mv -Ov` ([ViralVariantCallingPipeline.swift:1329](Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1329)). None of these are passed:
- `--ploidy 1`
- `-d/--max-depth` (bcftools 1.24 default 250)
- `-A` (orphan pairs)
- `-a AD,DP` (allele depth)

**Reproduction (Confirmed, bcftools 1.24):** 2000 reads, 30% alt. The output is `DP=250;DP4=175,0,75,0` and `GT 0/1`, with the note "assuming all sites are diploid". At 4% alt, bcftools emits nothing, while LoFreq emits AF=0.04.

**Impact**
- Depth and allele support are computed from a random 250-read subset.
- Haploid viral genomes get diploid heterozygous genotypes, and mixed-infection signals are lost or mis-described.
- There is no AD tag, so AF cannot be derived, which makes SCI-03's fix harder.

**Recommendation**
- mpileup: `-d 0` (or a high cap), `-A`, `-a FORMAT/AD,FORMAT/DP,INFO/AD`, `-B` or `-Q` consistent with the iVar branch, and `-q 0`.
- call: `--ploidy 1`.
- Label bcftools in the UI as a consensus-level caller, not a minor-variant caller.

**Acceptance test:** On the 30% fixture, DP is 2000 and GT is `1` (haploid). An AD tag is present.

**Effort:** S.

### SCI-05 (P1): Mapping rate and per-contig % count alignment records, not reads

**Evidence**
- `parseFlagstat` takes `in total` as totalReads and the `mapped (` line, excluding only `primary mapped`, as mappedReads ([ManagedMappingPipeline.swift:1126](Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift:1126)). Both count secondary and supplementary records.
- The unmapped count is derived as `total - mapped` ([ManagedMappingPipeline.swift:344](Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift:344)).
- The UI shows "N/M reads mapped" and "Mapped Rate" ([MappingDocumentStateBuilder.swift:46](Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift:46), [AppDelegate+ToolsMenu.swift:796](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:796)).
- Per-contig `% Mapped` = `samtools coverage` numreads / totalReads ([MappingSummaryBuilder.swift:112](Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:112)). numreads includes supplementary records.
- On the read-group-filtered path, the denominator is `samtools view -c -R` over all records, including unmapped, secondary and supplementary ([MappingSummaryBuilder.swift:314](Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:314)). So filtered and unfiltered percentages use different denominators.
- Supplementary is kept by default (GUI `includeSupplementary = true`, [MappingWizardSheet.swift:86](Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift:86)). Secondary is optional.

**Reproduction (Confirmed):** 10 reads: 8 mapped primaries, 2 unmapped, 4 supplementary and 4 secondary records. flagstat gives `18 in total`, `16 mapped`, `8 primary mapped`.

| Metric | LGE reports | Correct |
|---|---|---|
| Reads mapped | 16/18 (88.9%) | 8/10 (80%) |
| Per-contig % | 12/18 (66.7%) | 8/10 (80%) |

With the defaults (supplementary only) the result is 12/14 = 85.7% against a true 80%.

**Impact:** Mapping QC, the most-quoted mapping number, is inflated, especially for ONT and chimeric data. Per-contig percentages do not add up.

**Recommendation**
- Use `samtools flagstat -O json` and take `primary` and `primary mapped`. For paired data also report pairs.
- For per-contig counts use `samtools view -c -F 0x904` per contig, or `samtools idxstats`, and one consistent primary-read denominator on both paths.
- Label the columns "primary reads".

**Acceptance test:** The 18-record fixture above reports 8/10 (80%). Per-contig % sums to at most 100%. The filtered and unfiltered paths agree when all read groups are selected.

**Effort:** S.

### SCI-06 (P1): Annotation extraction ignores strand and splicing

**Evidence**
- Every annotation extraction entry point builds `ExtractionRequest(source: .annotation(annotation))` with defaults `reverseComplement: false, concatenateExons: false`: Copy as FASTA, the Extract Sequence dialog, FASTA operation, and drawer multi-select ([ViewerViewController+Extraction.swift:101](Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:101), [:129](Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:129), [:157](Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:157), [:188](Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:188)).
- The strand-aware configuration sheet is only reached for `.region` ([ViewerViewController+Extraction.swift:254](Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:254)). Even there `reverseComplement` defaults to false regardless of strand ([ExtractionConfigurationView.swift:60](Sources/LungfishApp/Views/Extraction/ExtractionConfigurationView.swift:60)).
- `SequenceExtractor.extractAnnotation` returns the plus-strand genomic span, introns included ([SequenceExtractor.swift:295](Sources/LungfishCore/Extraction/SequenceExtractor.swift:295)). The same result object carries a strand-correct protein from `translateCDS` ([SequenceExtractor.swift:320](Sources/LungfishCore/Extraction/SequenceExtractor.swift:320)), so the nucleotide and protein in one result disagree.
- The core API also applies `flank5Prime` at the lower coordinate and `flank3Prime` at the higher one regardless of strand ([SequenceExtractor.swift:262](Sources/LungfishCore/Extraction/SequenceExtractor.swift:262), [:297](Sources/LungfishCore/Extraction/SequenceExtractor.swift:297)). For a minus-strand gene with flank5=100 and RC on, the 100 extra bases are downstream of the gene: they end up at the 3' end of the output.

**Impact:**
- For a human or macaque minus-strand CDS, "Copy as FASTA" gives the reverse complement of the coding sequence, with introns, under a header reading `[CDS] [strand: -]`.
- Pasting this into BLAST, a primer designer or an alignment gives wrong results.
- Every other genome tool (UCSC, gffread, SnapGene, Geneious) returns features in feature orientation.

**Recommendation**
- For annotations, default `reverseComplement = (strand == .reverse)` and `concatenateExons = true` for CDS, mRNA and transcript types.
- In `SequenceExtractor`, interpret flanks in feature orientation: swap the flanks when `strand == .reverse`.
- Include "(feature orientation)" or "(genomic + strand)" in the header.
- Route annotation extraction through the configuration sheet, with those defaults preselected.

**Acceptance test:**
- A minus-strand 2-exon CDS fixture copied as FASTA equals the reverse complement of the joined exons, and translating it equals `result.proteinSequence`.
- flank5=3 on a minus-strand feature adds bases from `end..end+3`, reverse-complemented at the 5' end of the output.

**Effort:** M.

### SCI-07 (P1): Reverse-complement region extraction does not transform variants

**Evidence**
- `SequenceExtractionPipeline.buildBundle` passes `isReverseComplement` to annotation transforms ([SequenceExtractionPipeline.swift:263](Sources/LungfishApp/ViewModels/SequenceExtractionPipeline.swift:263)).
- It calls `VariantDatabase.extractRegion(... start:end:)` with no orientation parameter ([SequenceExtractionPipeline.swift:326](Sources/LungfishApp/ViewModels/SequenceExtractionPipeline.swift:326)). `extractRegion` only shifts by `-start` and copies REF/ALT verbatim ([VariantDatabase+RegionExtraction.swift:244](Sources/LungfishIO/Bundles/VariantDatabase+RegionExtraction.swift:244)).

**Worked example:** The region is 0-based [100, 200) with RC on. A SNP at 0-based 110 with REF A and ALT G:

| | Position | REF/ALT |
|---|---|---|
| Stored by LGE | 10 | A/G |
| Correct | 200-1-110 = 89 | T/C |

For an indel, the position must also be re-anchored to the new left base.

**Impact:** In the derived bundle, variants sit at mirrored-wrong positions with REF alleles that do not match the displayed sequence. Any downstream export (VCF) of that bundle is corrupt.

**Recommendation:**
- Add `isReverseComplement` to `extractRegion`. For each record, mirror the position, reverse-complement REF and ALT, and re-normalize indels. This needs the reference base to the left in the new orientation.
- Drop symbolic or breakend records with a warning.
- Until then, skip variant extraction when RC is on and say so in the result.

**Acceptance test:** A fixture VCF with one SNP and one deletion inside the region. After RC extraction, `bcftools norm -c e -f extracted.fa` reports no REF mismatch.

**Effort:** M.

### SCI-08 (P1): Lossy quality binning on by default, applied silently in several paths

**Evidence**
- The default of `FASTQIngestionConfig.qualityBinning` is `.illumina4` ([FASTQIngestionPipeline.swift:73](Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:73)). `illumina4` becomes clumpify `quantize=0,8,13,22,27,32,37`, which is 7 levels, and `eightLevel` becomes `quantize=2`, about 21 levels ([FASTQIngestionPipeline.swift:433](Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:433)). Both names misdescribe the transform.
- `FASTQIngestionService.ingestIfNeeded` runs in place with `deleteOriginals: true` and the default binning ([FASTQIngestionService.swift:151](Sources/LungfishApp/Services/FASTQIngestionService.swift:151)). It is triggered automatically after downloads without any dialog ([AppDelegate+Classification.swift:2654](Sources/LungfishApp/App/AppDelegate+Classification.swift:2654)).
- `FASTQOperationOutputImporter` hard-codes `.illumina4` and `deleteOriginals: true` for FASTQ operation outputs ([FASTQOperationOutputImporter.swift:108](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:108)).
- The import sheet preselects 4-level for Illumina, Element and MGI ([FASTQImportConfigSheet.swift:619](Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift:619)). `lungfish import fastq` also defaults to `illumina4` ([ImportFastqCommand.swift:91](Sources/LungfishCLI/Commands/ImportFastqCommand.swift:91)).
- Originals are removed with `try? removeItem` after compression. There is no read-count or checksum check between input and output ([FASTQIngestionPipeline.swift:340](Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:340)).

**Impact**
- MiSeq and iSeq data, which is unbinned at source, loses quality resolution irreversibly. The downloaded SRA/ENA originals are deleted.
- LoFreq's quality-aware model, iVar's `-q 20` cut (Q19 rounds to 22 and passes), and bcftools BAQ all see altered qualities.
- Provenance records the binning, which is good, but the user never chose it on the download path.

**Recommendation**
- Make `.none` the default everywhere, with binning an explicit storage option.
- Never bin on the implicit paths: downloads and operation outputs.
- Rename the schemes after their real bins.
- Before deleting originals, verify that the output read count equals the input count (pairs × 2) and record input checksums.

**Acceptance test:**
- After downloading an SRA run, the bundle's FASTQ qualities are byte-identical to the fasterq-dump output.
- The import sheet defaults to "None".
- Deleting originals is blocked when the counts differ.

**Effort:** M.

### SCI-09 (P1): NAO-MGS coverage % uses alignment extent as the reference length

**Evidence**
- `bulkInsertAccessionSummaries` sets `coverage_fraction = coveredBP / maxExtent`, where maxExtent is the largest `ref_start + query_length` seen ([NaoMgsDatabase+Create.swift:694](Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase+Create.swift:694)).
- The same extent is stored as the fallback `reference_lengths` ([NaoMgsDatabase+Create.swift:729](Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase+Create.swift:729)).
- Real lengths replace it only when `fetchReferences` is on and the NCBI fetch plus faidx succeed ([MetagenomicsImportService.swift:1018](Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:1018)).
- The result is shown as "Coverage NN%" ([NaoMgsResultViewController.swift:1115](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1115)).
- Materialized BAM headers use `refLengths[accession] ?? 100000` ([NaoMgsBamMaterializer.swift:360](Sources/LungfishIO/Services/NaoMgsBamMaterializer.swift:360)).

**Worked example:** A 30 kb coronavirus with reads covering only 1 to 3,000 shows 100% coverage (3000/3000) instead of 10%.

**Impact:** When LGE is offline, references are not fetched, or an accession was withdrawn, the headline breadth metric used to judge a true detection is inflated. The metric is exactly the one used to separate real hits from spurious ones.

**Recommendation**
- Store `reference_length_source` ("fasta", "alignment-extent", "unknown").
- Show coverage as "n/a" or "≥ extent-based" when the source is not "fasta".
- Never write a fabricated LN, and fail or warn instead.

**Acceptance test:** Import with `fetchReferences=false` shows coverage as unavailable or flagged. With fetched references the fraction equals `coveredBP / fasta length`.

**Effort:** S.

### SCI-10 (P2): CDS translation ignores phase, `/codon_start` and `/transl_table`

**Evidence**
- `TranslationEngine.translateCDS` uses `exonSequences.first?.interval.phase`, which is the lowest-coordinate segment. On the minus strand that is the 3' end of the CDS ([TranslationEngine.swift:128](Sources/LungfishCore/Translation/TranslationEngine.swift:128)). The table defaults to `.standard`.
- None of the callers pass a table ([SequenceViewerView.swift:2098](Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift:2098), [SelectionSection.swift:200](Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift:200), [SequenceViewerView+AnnotationRendering.swift:590](Sources/LungfishApp/Views/Viewer/SequenceViewerView+AnnotationRendering.swift:590), [SequenceExtractor.swift:320](Sources/LungfishCore/Extraction/SequenceExtractor.swift:320)).
- `AnnotationInterval.phase` is never populated from input. The GFF3 feature to annotation conversion drops it ([GFF3Reader.swift:112](Sources/LungfishIO/Formats/GFF/GFF3Reader.swift:112)), and GenBank `/codon_start` is not read.

**Impact**
- Partial CDS with `/codon_start=2|3` translate in the wrong frame. These are common in viral GenBank records.
- For vertebrate mitochondrial CDS (`/transl_table=2`, for example 12S projects' mito genomes), every TGA (Trp) shows as a stop and AGA/AGG as Arg.
- The minus-strand phase bug is latent today and becomes live once phase is populated.

**Recommendation**
- Populate the phase for the 5'-most segment from GFF phase or GenBank `codon_start - 1`.
- Choose the 5'-most segment by strand.
- Read `transl_table`, and fall back to a per-bundle genetic code setting.

**Acceptance test:** A GenBank fixture with `/codon_start=2` and a mito COX1 with table 2 each translate to their `/translation` qualifier.

**Effort:** M.

### SCI-11 (P2): GFF3 export writes wrong phase and breaks multi-segment CDS identity

**Evidence:** `GFF3Writer` feature conversion gives each interval of a multi-interval annotation a distinct `ID=<uuid>_<n>` and `Parent=<uuid>`, where no feature has that ID. It also writes `phase = interval.phase ?? 0` for every CDS segment ([GFF3Reader.swift:758](Sources/LungfishIO/Formats/GFF/GFF3Reader.swift:758)). This is used by user export, `BuiltInFormats` and `lungfish convert` ([AnnotationExportService.swift:34](Sources/LungfishApp/Services/AnnotationExportService.swift:34), [ConvertCommand.swift:210](Sources/LungfishCLI/Commands/ConvertCommand.swift:210)).

**Worked example:** For CDS `join(1..10,21..32)`, the second segment is written with phase 0 instead of 2.

**Impact:**
- gffread, VEP, snpEff and iVar translate exported CDS out of frame.
- Round-tripping through LGE splits one CDS into two features with an invalid parent. GFF3 validators reject the dangling `Parent`.

**Recommendation:**
- Emit all segments of one CDS with the same `ID`, and no synthetic Parent unless the parent is also emitted.
- Compute phase with the shared helper from SCI-01.

**Acceptance test:** `gt gff3validator` passes on the exported GFF3. Re-import gives one CDS with two intervals. `gffread -y` protein equals LGE's translation.

**Effort:** S.

### SCI-12 (P2): Bgzip FASTA reader corrupts sequence for CRLF files

**Evidence**
- `BgzipIndexedFASTAReader.fetch` and `fetchSync` strip only `"\n"` ([BgzipIndexedFASTAReader.swift:314](Sources/LungfishIO/Formats/FASTA/BgzipIndexedFASTAReader.swift:314), [:587](Sources/LungfishIO/Formats/FASTA/BgzipIndexedFASTAReader.swift:587)). The plain reader strips both LF and CR.
- `NativeBundleBuilder` copies the source FASTA verbatim, then bgzips and runs faidx ([NativeBundleBuilder.swift:863](Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift:863)). samtools happily indexes CRLF (`c1 24 10 10 12`).
- `ReferenceBundle` uses the bgzip reader ([ReferenceBundle.swift:324](Sources/LungfishIO/Bundles/ReferenceBundle.swift:324)).

**Reproduction (Confirmed):**
- The Foundation operation on `"ACGT\r\nGGCC\r\nTT"` yields scalars `...84,13,71...` and `prefix(6) == "ACGT\rG"`.
- For the fixture above, region 0-based [4,14): `samtools faidx` returns `ACGTACGGGG`, while LGE's algorithm returns `ACGTAC\rGGG`.

**Impact:** Windows-edited references return sequences containing CR with bases missing. This affects rendering, extraction, primer checks, and any consensus or translation built from the fetch.

**Recommendation:** Reuse `FASTAIndex.sequenceText(fromIndexedWindow:)` in both bgzip fetch methods. Also normalize line endings at bundle build time.

**Acceptance test:** A CRLF FASTA bundle fetch equals `samtools faidx` output for random regions.

**Effort:** S.

### SCI-13 (P2): Mixed coordinate conventions in user-visible `chr:start-end` strings

**Evidence**
- Annotation "Copy Coordinates" writes `chrom:start0-end` (BED-style) in the samtools/IGV notation that readers take as 1-based. Variants get `start+1` ([AnnotationTableDrawerView.swift:1738](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:1738)).
- FASTA headers from `SequenceExtractor` print `[chrom:effectiveStart0-end]` ([SequenceExtractor.swift:367](Sources/LungfishCore/Extraction/SequenceExtractor.swift:367)).
- `lungfish extract --region chr1:1-100` converts to 0-based, and `sourceName` becomes `chr1:0-100` ([SequenceExtractor.swift:153](Sources/LungfishCore/Extraction/SequenceExtractor.swift:153), [ExtractCommand.swift:159](Sources/LungfishCLI/Commands/ExtractCommand.swift:159)). The header reads `>chr1:0-100 [chr1:0-100] [100 bp]`.
- The drawer `region:` filter treats typed numbers as 0-based half-open, while the table shows `start+1` ([AnnotationTableDrawerView+Filtering.swift:2102](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Filtering.swift:2102), [AnnotationTableDrawerView.swift:3474](Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift:3474)).

**Impact:** One-base shifts whenever a coordinate string is pasted into samtools, IGV, UCSC or a methods section.

**Recommendation:**
- Standardize on 1-based closed notation for every `chr:start-end` string the app shows or copies. Keep 0-based only in files that are BED by definition.
- Add a `GenomicRegion.displayString` helper and ban ad hoc interpolation.

**Acceptance test:** Unit tests for the copy-coordinates, FASTA header and filter parse. A region round-trip copy then filter selects the same feature.

**Effort:** S.

### SCI-14 (P2): Silent length-based chromosome aliasing for variant tracks

**Evidence:** When VCF contig names do not match, the viewer maps them in two ways ([SequenceViewerView+Rendering.swift:993](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:993)):
- By `##contig` length within 10 bp.
- When no contig lengths exist, by `MAX(position)` within 20% of the reference length for contigs under 1 Mb.

Name heuristics also strip version suffixes: `MN908947.3` matches bundle `MN908947` ([ChromosomeNameMapping.swift:39](Sources/LungfishCore/Bundles/ChromosomeNameMapping.swift:39)). The only feedback is a log line.

**Impact:** A VCF called against a different, similar-length viral genome, or a different accession version, is drawn on the bundle's sequence with no warning. REF alleles then do not match the displayed bases.

**Recommendation:**
- Surface any non-exact alias in the track header, for example "VCF contig X shown on Y (matched by length)".
- Verify REF alleles against the reference for a sample of records, and refuse the mapping on mismatch.

**Acceptance test:** A VCF on a 20%-shorter contig with mismatching REFs is not displayed, or is displayed with a visible warning.

**Effort:** S.

### SCI-15 (P2): Origin-spanning features are reordered by start

**Evidence:** `SequenceExtractor.extractAnnotation` and `TranslationEngine.translateCDS` sort intervals ascending before concatenating ([SequenceExtractor.swift:249](Sources/LungfishCore/Extraction/SequenceExtractor.swift:249), [TranslationEngine.swift:105](Sources/LungfishCore/Translation/TranslationEngine.swift:105)). GenBank `join(4000..4200,1..100)` on a circular plasmid or mitogenome is joined as `1..100` then `4000..4200`.

**Impact:** Wrong extracted sequence and protein for origin-spanning genes on circular molecules. The frequency depends on the organism.

**Recommendation:** Keep the parser's segment order. Sort by transcription order only when the molecule is linear or the segments do not wrap. Honor GenBank `circular` in LOCUS.

**Acceptance test:** A circular GenBank fixture with a wrapping CDS translates to its `/translation` qualifier.

**Effort:** M.

### SCI-16 (P2, Suspected): CLI-backed subsample is not pair-aware

**Evidence**
- The FASTQ Operations launch path executes the CLI through `FASTQOperationExecutionService` and `FASTQOperationCLIInvocationBuilder` ([FASTQOperationExecutionService.swift:358](Sources/LungfishApp/Services/FASTQOperationExecutionService.swift:358)). The builder emits `fastq subsample <firstInput> --proportion p` ([FASTQOperationCLIInvocationBuilder.swift:243](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:243)).
- `FastqSubsampleSubcommand` runs `seqkit sample -p` with no interleave detection and no seed option ([FastqCommand.swift:327](Sources/LungfishCLI/Commands/FastqCommand.swift:327)).
- Paired imports are stored interleaved (clumpify `in2=` and `interleaved=t`).

**Needs verification:** Confirm that the dialog passes the interleaved payload URL, not a bundle the CLI resolves.

**Impact if confirmed:** Records are sampled independently, which orphans mates. Downstream tools that treat the file as interleaved pair R1 of one fragment with R2 of another.

**Recommendation:** Share one subsample implementation between the GUI and CLI. Detect interleaved input and use `reformat.sh samplerate= sampleseed= interleaved=t`. Add `--seed` to the CLI and record it.

**Acceptance test:** Subsample an interleaved fixture via the Operations dialog. Every output record at index 2k/2k+1 shares a read name.

**Effort:** S.

### SCI-17 (P2): Markdup shell pipeline robustness

**Evidence**
- `MarkdupService.runPipeline` runs `/bin/sh -c "<samtools> sort -n ... | fixmate -m - - | sort - | markdup - out"` without `set -o pipefail`. It interpolates paths inside double quotes, so `$`, backtick or `"` in a path breaks or injects ([MarkdupService.swift:200](Sources/LungfishIO/Services/MarkdupService.swift:200)).
- The output is only checked for non-zero size before `replaceItemAt` swaps it in ([MarkdupService.swift:68](Sources/LungfishIO/Services/MarkdupService.swift:68)).
- The duplicate fraction is `view -c -F 0x4` against `-F 0x404`, which counts secondary and supplementary records ([MarkdupService.swift:96](Sources/LungfishIO/Services/MarkdupService.swift:96)).
- Current callers operate on staged copies (NVD import) or generated BAMs (NAO-MGS), so user originals are not at risk ([MetagenomicsImportService.swift:700](Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:700)).

**Impact:**
- A mid-pipeline failure can be masked, although in most cases htslib's EOF checks propagate. This part is Suspected.
- Unique-read counts derived after markdup are counted over alignment records.

**Recommendation:**
- Use `NativeToolRunner.runPipeline` with argv arrays (as the variant pipeline does), or at least add `set -o pipefail` and `shellEscape`.
- Validate the output with `samtools quickcheck` and record counts before the swap.
- Count with `-F 0x904`.

**Acceptance test:** Inject a failing first stage. The service throws and leaves the original BAM untouched.

**Effort:** S.

### SCI-18 (P2): Bracken distribution length is fixed at 150 bp

**Evidence:** `BrackenDatabaseCapabilities.supportedReadLength = 150`, which every non-explicit request uses ([BrackenProfileModels.swift:85](Sources/LungfishWorkflow/Metagenomics/BrackenProfileModels.swift:85)).

**Impact:** For 2×250 MiSeq or ONT reads, Bracken re-estimates abundance with the wrong k-mer distribution. This is a known, modest bias. It is acceptable only if disclosed.

**Recommendation:** Record the observed read-length distribution next to the Bracken result. Warn when the median differs from 150 by more than 30%. Offer other distributions when the database ships them. This is an accept and document item unless additional `databaseXmers.kmer_distrib` files are available.

**Acceptance test:** A classification of 250 bp reads shows the warning, and provenance contains both the read length used and the observed length.

**Effort:** S.

### SCI-19 (P3): `--fasta-input` passed to kraken2

**Evidence:** `ClassificationConfig.kraken2Arguments` appends `--fasta-input` for FASTA input ([ClassificationConfig.swift:398](Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift:398)). This is a Kraken 1 flag.

**Reproduction (Confirmed):** The managed kraken2 wrapper's `GetOptions` has no such option and ignores the return value. Perl prints `Unknown option: fasta-input` and continues. Kraken2 auto-detects the format.

**Impact:** Harmless at runtime. Provenance and the "CLI equivalent" record a bogus flag, and stderr carries a warning users will ask about.

**Recommendation:** Remove the flag and update [ClassificationPipelineTests.swift:392](Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift:392), which asserts it.

**Acceptance test:** The kraken2 argv for FASTA input contains no `--fasta-input`.

**Effort:** S.

### SCI-20 (P3): Assembly statistics mis-handle IUPAC and N

**Evidence:** `AssemblyStatistics` counts only A/C/G/T/U/N toward length and skips R, Y, K, M, S, W and the other IUPAC codes. It uses total length including N as the GC denominator ([AssemblyStatistics.swift:103](Sources/LungfishIO/Assembly/AssemblyStatistics.swift:103)).

**Worked example:** For contig `ACGTRYN`, LGE reports length 5 and GC 40%. QUAST-style values are length 7 and GC 50% (N excluded).

**Recommendation:** Count every non-whitespace residue toward length, and exclude N and ambiguity codes from the GC denominator.

**Acceptance test:** The `ACGTRYN` fixture reports length 7 and GC 0.5.

**Effort:** S.

### SCI-21 (P3): Straddling variants keep the full REF after region extraction

**Evidence:** `extractRegion` clamps `newPosition = max(0, pos - start)` but keeps the original REF ([VariantDatabase+RegionExtraction.swift:244](Sources/LungfishIO/Bundles/VariantDatabase+RegionExtraction.swift:244)).

**Worked example:** A deletion spanning [95,105) with the region starting at 100 is written at 0 with a 10-base REF that includes 5 bases outside the new sequence.

**Recommendation:** Drop, or trim and re-anchor, records that cross either boundary. Count and report them.

**Acceptance test:** `bcftools norm -c e` on the exported VCF of an extracted region reports no mismatches.

**Effort:** S.

## Proposed work packages

Packages are ordered by scientific risk. Each one can be reviewed on its own.

**A. Viral variant-calling correctness (SCI-01, SCI-02, SCI-03, SCI-04).** No dependencies.
- Files: `Sources/LungfishWorkflow/Annotation/AnnotationDatabaseGFFExporter.swift`, `Variants/IVarTSVToVCFConverter.swift`, `Variants/IVarCodonMerger.swift`, `Variants/ViralVariantCallingPipeline.swift`, the BAM variant-calling dialog state and help text, `LungfishCLI/Commands/VariantsCommand.swift`.
- Add a shared `CDSSegmentPhases` helper in LungfishCore.
- Risk: medium. Changes VCF contents for existing workflows. Re-run the SARS-CoV-2 fixture suite and snapshot tests and document the change in release notes.
- Do this first. It affects the headline workflow.

**B. Mapping and coverage statistics (SCI-05, SCI-09, SCI-17 counting part).**
- Files: `Mapping/ManagedMappingPipeline.swift`, `Mapping/MappingSummaryBuilder.swift`, NAO-MGS create, summaries and materializer, NaoMgs UI label, `MarkdupService.swift`.
- Risk: low to medium. Displayed numbers change. Existing result bundles keep old numbers unless they are recomputed, so consider a "recompute stats" affordance.

**C. Extraction orientation and coordinates (SCI-06, SCI-07, SCI-13, SCI-15, SCI-21).**
- Files: `LungfishCore/Extraction/SequenceExtractor.swift`, `ViewerViewController+Extraction.swift`, `ExtractionConfigurationView.swift`, `VariantDatabase+RegionExtraction.swift`, `SequenceExtractionPipeline.swift`, `AnnotationTableDrawerView*`, a new `GenomicRegion.displayString`.
- Depends on the SCI-15 decision about segment order.
- Risk: medium. UI defaults change. Update user-manual chapters on extraction.

**D. Translation and GFF export (SCI-10, SCI-11).**
- Files: `TranslationEngine.swift`, `GFF3Reader.swift` (writer part), GenBank and GFF3 to annotation converters (phase and `transl_table` capture).
- Depends on A's `CDSSegmentPhases` helper.
- Risk: low.

**E. Read-data preservation (SCI-08, SCI-16).**
- Files: `Ingestion/FASTQIngestionPipeline.swift`, `FASTQIngestionService.swift`, `FASTQOperationOutputImporter.swift`, `FASTQImportConfigSheet.swift`, `ImportFastqCommand.swift`, `FastqCommand.swift` (subsample), `FASTQOperationCLIInvocationBuilder.swift`.
- Risk: medium. Disk usage rises when binning is off by default. Communicate this as a product decision. Verify SCI-16 before changing it.

**F. Robustness and hygiene (SCI-12, SCI-14, SCI-17 shell part, SCI-19, SCI-20).**
- Files: `BgzipIndexedFASTAReader.swift`, `SequenceViewerView+Rendering.swift` (alias surfacing), `MarkdupService.swift`, `ClassificationConfig.swift` and its test, `AssemblyStatistics.swift`.
- Risk: low.

**Accept (document, do not engineer now)**
- SCI-18: Bracken 150 bp is a database constraint. Disclose it and warn, and do not build a multi-distribution install flow until the catalog ships other distributions.
- Deliberate consensus policies stay as they are: deletions rendered as N, insertions omitted in `fetchConsensus`. They are explicit, recorded in `consensusResolvedDefaults`, and appropriate for a reference-length viewer consensus. Only the UI label should say so.
- The 37 remove-then-move replacement sites I found are mostly fallbacks after a successful write into staging (for example [FASTQAtomicFileWriter.swift:17](Sources/LungfishIO/Formats/FASTQ/FASTQAtomicFileWriter.swift:17)). I did not find one that destroys user originals, so they are not worth a sweep.

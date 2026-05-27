# 12S Amplicon Matching Workflow and Evidence Viewport

Date: 2026-05-27

## Goal

Add a separate custom Lungfish Genome Explorer workflow for 12S rRNA amplicon matching from prepared Illumina FASTQ bundles. The workflow consumes merged/clumpified sample FASTQ bundles, compares reads to a deduplicated 12S reference FASTA, reports exact retained target matches, tracks non-exact/unresolved sequence space, runs vsearch chimera review, and presents results in a target-centric evidence viewport for wastewater/eDNA exploration.

This workflow is related to the existing MHC/KIR amplicon genotyping work only through shared FASTQ preparation, mapping/filtering, provenance, and app integration patterns. It must remain a separate workflow and result bundle so the 12S evidence model can grow independently.

## Scientific Context

The expected use case is 12S amplicon sequencing from wastewater samples containing many comingled species. A typical reference is a deduplicated FASTA such as:

```text
/Users/dho/Downloads/amplicons_12s_deduplicated.fa
```

The provided FASTA is deduplicated at the sequence level and uses headers that encode display and ambiguity metadata, for example:

```text
human (Homo sapiens)|locus=12S|len=107|n_refs=1572|n_species=2|also_matches=Heidelberg man (Homo heidelbergensis)|n_primer_pairs=1|primer_pairs=12S_vert_F_x_12S_vert_R
```

Because wastewater 12S is an environmental assay, the result must be framed as evidence rather than confirmed species presence. Primer bias, shedding, transport, degradation, library depth, cross-contamination, low-level index bleed, reference ambiguity, and PCR chimeras can all affect interpretation.

## Inputs

The 12S workflow accepts one or more prepared sample inputs:

- `.lungfishfastq` bundles containing a single merged FASTQ payload.
- Single merged FASTQ files.

Raw R1/R2 pairs are out of scope for the matching command. Users should import paired Illumina data with the existing `illumina-amplicon-merge` recipe first. That recipe performs overlap merging and final FASTQ import materialization, and its provenance records the R1/R2 preparation step.

Reference input:

- A FASTA file or `.lungfishref` bundle containing deduplicated 12S targets.
- No metadata sidecar is required for the first version; metadata is parsed from FASTA headers.

Optional metadata:

- Sample type, run/batch, site, collection date, index/barcode, and control labels should be read from existing sample metadata when available.
- Missing sample metadata must not block workflow execution.

## Matching Semantics

The workflow maps merged reads to the 12S reference FASTA and classifies read fate.

Exact retained target matches require:

- Full reference-span alignment.
- Zero mismatches.
- Indels allowed.
- Soft-clipped sequence at both ends.
- One retained target per matched read, assuming the reference FASTA is sequence-deduplicated.

The workflow must preserve enough alignment summary data to explain retained and non-retained decisions. Indel-allowed matching must not be invisible in the UI.

## Read Fate Model

The result bundle must track the whole fate of merged reads, not only exact matches.

Per sample, record:

- `input_read_pairs` when derivable from import provenance.
- `merged_reads`.
- `merge_rate` when derivable from import provenance.
- `mapped_12s_reads`.
- `retained_exact_match_reads`.
- `non_exact_mapped_reads`.
- `unmapped_or_off_panel_reads`.
- `suspected_chimera_reads`.
- `unresolved_non_chimera_reads`.
- `percent_exact_retained`.
- `percent_mapped_but_non_exact`.
- `percent_unmapped_or_off_panel`.
- `percent_suspected_chimera`.

The overview viewport should show a QC funnel:

```text
input pairs -> merged reads -> mapped 12S reads -> exact retained matches -> non-exact mapped -> unresolved/chimera/off-panel
```

## Target Match Outputs

The primary target table is target-centric because 12S references outnumber samples.

Rows are deduplicated FASTA targets. Columns are samples. Cells can display:

- Raw retained match reads.
- CPM over retained 12S reads.
- Percent of retained 12S reads.
- Evidence tier.
- Log-scaled heatmap value.

For each target, store:

- `target_id`.
- `target_display_name`.
- Raw FASTA header.
- Parsed header fields: `locus`, `reference_len`, `n_refs`, `n_species`, `also_matches`, `n_primer_pairs`, `primer_pairs`.
- Total retained match reads across samples.
- Sample prevalence.
- Maximum sample count.
- Maximum negative-control count when controls are labeled.
- Ambiguity flag based on `n_species > 1` or non-empty `also_matches`.
- Control/background flag.
- Evidence tier summary.

For each sample-target cell, store:

- `sample_id`.
- `target_id`.
- `raw_count`.
- `cpm_retained_12s`.
- `percent_retained_12s`.
- `rank_in_sample`.
- `control_detected_flag`.
- `max_negative_control_count`.
- `sample_to_control_ratio`.
- `cross_sample_prevalence`.
- `evidence_tier`.

## Evidence Tiers

The workflow should compute conservative default tiers and allow the viewport to filter by them.

Default rules:

- `strong`: at least 50 retained reads and at least 0.1% of retained 12S reads for the sample.
- `moderate`: at least 10 retained reads, especially when replicated or expected in the sample group.
- `trace`: 1-9 reads or below background threshold.
- `review`: blank-associated, broad low-level run signal, ambiguous reference metadata, or indel-heavy evidence.
- `not_observed`: no retained reads for a sample-target pair.

These are display classifications, not final biological calls. The UI should use language like "strong evidence", "trace", "blank-associated", "ambiguous", "unusual", and "needs review" rather than "confirmed species".

## Unresolved and Non-Exact Sequence Outputs

The workflow must preserve non-exact sequence space for review. Merged reads that do not become exact retained target matches should be collapsed into observed sequence clusters.

For each observed non-exact cluster, store:

- `observed_sequence_id`.
- Sequence.
- Total count.
- Per-sample counts.
- Sample prevalence.
- Percent of sample and CPM where applicable.
- Nearest reference target.
- Edit distance or alignment distance to nearest reference when available.
- Mismatch count.
- Indel profile.
- Soft clip left/right summary.
- Reason not retained: mismatch, partial span, missing both-end soft clips, ambiguous alignment, off-panel, low quality, or unmapped.
- vsearch chimera status and score.
- Candidate parent targets when available.
- Exportable FASTA/CSV records.

The result schema should allow external search results to be attached to unresolved sequence clusters. The first UI should at minimum support exporting selected unresolved sequences as FASTA/CSV with stable sequence IDs. If existing database search services are available, the UI can add a "Search selected sequences" action that persists search provenance and returned hits in the bundle.

## Chimera Review

vsearch is already a managed native tool in LGE and should be part of the first workflow implementation.

Default behavior:

- Dereplicate observed merged amplicon sequences.
- Run reference-guided vsearch chimera review against the deduplicated 12S FASTA.
- Store chimera status per observed sequence cluster.
- Keep suspected chimeras visible but flagged and filterable; do not delete them by default.

Chimera states:

- `not_chimera`.
- `suspected_chimera`.
- `confirmed_by_reference`.
- `undetermined`.

The workflow should store vsearch version, argv, stderr, wall time, parent candidates, score fields, and all output files in provenance. De novo chimera detection can be added as an advanced option, but reference-guided review is sufficient for the first implementation because the 12S reference FASTA is large.

## Viewport Design

The native viewport should reuse the broad mechanics of existing result viewports: summary strip, segmented lenses, searchable sortable tables, split detail panes, and Inspector/provenance integration. It should not clone the MHC/KIR haplotype viewport.

Initial lenses:

1. **Overview**
   - QC funnel.
   - Sample count, target count, total retained matches, unresolved fraction, suspected chimera fraction.
   - Provenance status and reference FASTA identity/checksum.

2. **Targets**
   - Target rows, sample columns.
   - Virtualized table/heatmap for large target counts.
   - Controls/blanks pinned first when sample metadata identifies them.
   - Filters for target text, minimum count, minimum CPM, evidence tier, ambiguity, control-associated targets, primer pair, and sample group.
   - Default sort by total retained reads and prevalence.
   - Default hiding of zero-only rows and optional hiding of trace-only rows.

3. **Samples**
   - Per-sample QC table.
   - Composition bars showing top N retained targets plus `Other`.
   - Sample-level unresolved and suspected chimera percentages.

4. **Controls / Contamination**
   - Target counts in blanks, extraction controls, PCR negatives, positive controls, and ordinary wastewater samples.
   - Flags for targets present in controls, targets broadly present at low counts, and targets near a high-count sample or shared index/run context.
   - These flags downgrade confidence; they do not automatically remove targets.

5. **Unresolved**
   - Non-exact observed sequence clusters.
   - Chimera status filters.
   - Nearest-reference and reason-not-retained columns.
   - Export/search actions for selected sequences.

6. **Artifacts**
   - Raw CSV/TSV summaries.
   - Matched-read FASTA/FASTQ exports.
   - Unresolved sequence FASTA.
   - vsearch outputs.
   - Provenance files.

## Cross-Contamination and Background Flags

The workflow and viewport should flag suspicious patterns without making irreversible calls.

Flags:

- Present in negative controls above a configurable count.
- Sample count less than configurable fold-change over max blank count.
- Broad low-level presence across many samples in one run.
- Trace-level presence in samples sharing index/barcode/run context with a high-count sample.
- Target appears only in one run or one low-depth sample.
- Low-count target in a sample with poor merge rate or poor retained 12S depth.
- Target has high ambiguity metadata (`n_species > 1` or non-empty `also_matches`).
- Evidence depends on indel-heavy alignments.
- Reference is unusually short or otherwise problematic.

## CLI Contract

Add a separate command:

```bash
lungfish fastq 12s-match INPUT... \
  --reference /path/to/amplicons_12s_deduplicated.fa \
  --output-dir /path/to/output.lungfish12s \
  --output-name sample-or-run-name
```

Useful options:

- `--threads`.
- `--min-count`.
- `--min-cpm`.
- `--strong-min-count`.
- `--strong-min-percent`.
- `--trace-policy show|hide`.
- `--sample-metadata`.
- `--run-id`.
- `--skip-chimera-review`.
- `--chimera-mode reference|reference-and-denovo`.
- `--extra-vsearch-args`.
- `--extra-mapping-args`.

The command must reject raw paired R1/R2 inputs with a message directing users to import through `illumina-amplicon-merge`.

## Result Bundle

Use a new bundle type rather than `.lungfishgenotype`.

```text
.lungfish12s
```

Bundle contents:

- `12s-result.json`.
- `targets.tsv`.
- `sample-target-counts.tsv`.
- `samples.tsv`.
- `read-fate.json`.
- `unresolved-sequences.tsv`.
- `unresolved-sequences.fasta`.
- `matched-targets.fasta` when matched-read export is requested.
- `vsearch/` outputs.
- `.lungfish-provenance.json` at the bundle root.

The manifest must point to final stored payloads inside the result bundle, not staging files.

## Provenance Requirements

Missing provenance is a blocking defect.

The final `.lungfish12s` bundle must include canonical reproducibility provenance covering:

- Workflow/tool name and version.
- Exact argv and durable replay command.
- User-visible options plus resolved defaults.
- Input bundle paths and resolved FASTQ payload paths.
- Import provenance links for prepared FASTQ bundles.
- Reference FASTA path, checksum, size, record count, and copied/staged bundle path if applicable.
- Mapping tool/runtime identity.
- vsearch path, version, conda environment, argv, output files, exit status, wall time, and stderr.
- Output paths, checksums, file sizes, and roles.
- Exit status, wall time, and useful stderr for every scientific step.

GUI-imported CLI outputs must preserve or rehydrate CLI provenance so the final bundle points to the final stored payloads.

## Error Handling

Block execution when:

- No inputs are provided.
- An input cannot be resolved to exactly one merged FASTQ payload.
- Raw paired R1/R2 files are supplied directly.
- The reference FASTA is missing or unreadable.
- vsearch is unavailable when chimera review is enabled.
- Provenance cannot be written to the final result bundle.

Soft warnings:

- Missing sample metadata.
- No controls/blanks identified.
- No retained exact matches.
- High unresolved fraction.
- High suspected chimera fraction.
- High reference ambiguity among top targets.

## Testing

Use synthetic fixtures for ordinary automated tests.

Required coverage:

- CLI validation rejects raw R1/R2 inputs and accepts prepared single FASTQ bundles.
- FASTA header parsing extracts display names and metadata fields.
- Exact retained matching counts deduplicated target references correctly.
- Non-exact reads are represented in unresolved outputs.
- vsearch chimera outputs are parsed into stable chimera states using fake or synthetic vsearch output.
- Result bundle manifest points to final payload paths.
- Provenance includes FASTQ payloads, reference FASTA checksum/size, vsearch identity/argv, output checksums, exit status, wall time, and stderr.
- View model tests cover target-row/sample-column orientation, filtering, evidence tiers, control flags, unresolved/chimera filters, and provenance availability.

Optional live/manual tests can use the provided local data:

```text
/Users/dho/Downloads/HI_Hilo_WWTP_20260511__12S_F09_S69_L001_R1_001.fastq.gz
/Users/dho/Downloads/HI_Hilo_WWTP_20260511__12S_F09_S69_L001_R2_001.fastq.gz
/Users/dho/Downloads/amplicons_12s_deduplicated.fa
```

These files must not be committed to the repository.

## Initial Implementation Scope

The first implementation should deliver:

- New separate 12S CLI workflow.
- Prepared merged FASTQ input handling.
- Deduplicated FASTA reference metadata parsing.
- Exact retained target counts.
- Read fate metrics.
- vsearch reference-guided chimera review.
- Non-exact/unresolved sequence table and FASTA export.
- New `.lungfish12s` result bundle.
- Target-row/sample-column viewport with overview, targets, samples, controls, unresolved, and artifacts lenses.
- Complete canonical provenance.

External database search can start as export/search hooks and persisted schema support. Integrated remote or local database search can follow once the target database and operational constraints are chosen.

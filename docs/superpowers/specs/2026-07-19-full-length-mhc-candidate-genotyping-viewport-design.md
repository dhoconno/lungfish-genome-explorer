# Full-Length MHC Candidate Genotyping Viewport Design

Date: 2026-07-19

Status: Approved for written-spec review

## Summary

Extend fresh full-length ONT MHC genotyping analyses so previously unmatched sequence clusters become reproducible candidate-allele records and appear beside known genotypes in the existing full-length genotyping matrix.

The analysis will retain two sorted, indexed cohort BAM artifacts, classify every defensibly nameable unmatched sequence as a known genotype, a provisional novel allele (`_nov`), or a cDNA genomic extension (`_ext`), and retain unresolved sequences as a separate un-nameable artifact. A versioned JSON projection will carry the candidate definitions and sample support used by both the viewport and Excel workbooks.

The viewport will display known genotypes, candidates observed in one sample, and candidates observed in two or more samples. All three populations are visible initially. `_nov` and `_ext` rows in the singleton and shared populations receive four independently configurable allele-name tints stored per result bundle.

Excel remains a required curation surface. The initial workbook and `current.xlsx` will contain all candidates, candidate details, un-nameable records, and the same four tint categories. App visibility filters never remove scientific records from Excel. Per-bundle tint changes reach `current.xlsx` only through the existing explicit **Update Current Workbook** action.

## Scope

### Goals

- Show defensibly nameable unmatched full-length MHC clusters beside known genotypes.
- Separate candidates observed in one sample from candidates observed in two or more samples.
- Distinguish `_nov` from `_ext` candidates without conflating distinct sequences that share a provisional label.
- Retain the alignment evidence used for known calls, closest-reference selection, and extension classification.
- Produce only two durable cohort alignment artifacts rather than hundreds of per-sample BAMs.
- Keep app and Excel candidate projections synchronized from one structured candidate model.
- Preserve un-nameable clusters as explicit scientific artifacts.
- Preserve legacy result-bundle behavior and avoid changing other Lungfish result surfaces.
- Record complete reproducibility provenance for every new scientific artifact and transformation.

### Non-goals

- Changing non-full-length MHC genotype viewports.
- Feeding provisional candidates into current haplotype inference, QC classification, known-call CSV semantics, or unrelated exports.
- Replacing Excel curation in this change.
- Implementing the broader allele-curation and reference-promotion system described by earlier MHC curation designs.
- Reprocessing existing `.lungfishgenotype` bundles in place. The new data may require a fresh full-length analysis.
- Automatically modifying the reference library used by the analysis.

## Terminology

**Known genotype**
: A cluster with zero SNP substitutions relative to an existing eligible genomic allele. Indel-only differences do not make the cluster novel.

**Candidate**
: A stable unmatched sequence cluster classified as `_nov` or `_ext` and assigned a provisional reference-derived locus and label.

**Singleton candidate**
: A candidate observed in exactly one distinct analysis sample ID.

**Shared candidate**
: A candidate observed in two or more distinct analysis sample IDs. This is the cohort-support class eligible for future reference-database consideration.

**Extension candidate**
: A genomic cluster that completely and exactly covers a cDNA reference at comparable bases, has zero SNP substitutions, and contains additional query sequence explained by intron-sized gaps.

**Novel candidate**
: A nameable cluster whose best defensible reference relationship contains at least one SNP substitution and does not satisfy extension classification.

**Un-nameable cluster**
: A retained cluster for which no defensible reference-derived locus and provisional name can be assigned.

**Stable cluster ID**
: The sequence-derived identifier assigned after the existing unmatched normalization and deduplication step. It is the scientific row identity even when provisional labels collide.

## Architecture

The structured candidate projection is an optional, versioned addition to a full-length `.lungfishgenotype` bundle. It does not replace the existing known-call CSV or haplotype-analysis files.

The source relationships are:

1. Retained cohort BAMs are the durable alignment evidence.
2. Candidate and un-nameable FASTA files are the canonical sequence payloads.
3. `candidate-alleles.json` is the structured classification and support projection referencing those payloads by stable ID, path, size, and checksum.
4. The full-length viewport and Excel workbooks are deterministic projections of the known-call CSV plus candidate JSON.
5. The annotation sidecar stores per-bundle display visibility and tint preferences; it does not alter candidate classification.

The design uses JSON instead of a new SQLite database because candidate populations are cohort-sized, read-mostly, atomically published once per analysis, and directly compatible with the existing Codable result manifest. The annotated reference library remains in its existing SQLite record store. Candidate migration to SQLite is deferred until an interactive, large-scale curation workload requires transactions or indexed ad hoc queries.

## Durable Bundle Artifacts

A fresh analysis adds these final artifacts:

```text
artifacts/alignments/genotyping-evidence.bam
artifacts/alignments/genotyping-evidence.bam.bai
artifacts/alignments/unmatched-to-reference.bam
artifacts/alignments/unmatched-to-reference.bam.bai
candidate-alleles.json
candidate_alleles.fasta
unnameable_unmatched_clusters.fasta
unnameable-unmatched-clusters.json
```

The existing files remain, including:

```text
<output-name>.full-length-ont-mhc-genotypes.csv
<output-name>.full-length-ont-mhc-samples.csv
<output-name>.full-length-ont-mhc-genotypes.xlsx
artifacts/workbooks/current.xlsx
unmatched_clusters.fasta
deduplicated_unmatched_clusters.fasta
cdna_clusters.fasta
full-length-ont-mhc-genotyping-provenance.json
genotype-result.json
```

The result manifest gains optional paths for both BAM/BAI pairs, candidate JSON, candidate FASTA, and both un-nameable artifacts. Their absence means legacy behavior. If a new manifest declares an artifact that is missing, unreadable, or checksum-inconsistent, the viewport preserves known-call display and shows an explicit bundle-integrity warning instead of silently omitting declared candidates.

`deduplicated_unmatched_clusters.fasta` remains the reciprocal-mapping input and contains every deduplicated unmatched cluster before classification. `candidate_alleles.fasta` contains only `_nov` and `_ext` records, while `unnameable_unmatched_clusters.fasta` contains only un-nameable records. Zero-SNP clusters reassigned to an existing genomic allele remain in the historical deduplicated-unmatched input for traceability but are not copied into either classified FASTA.

## Cohort Genotyping BAM

### Per-sample generation

Samples continue to run independently and concurrently. Each sample mapping produces a temporary BAM with:

- target cluster names prefixed by the stable sample ID so every `@SQ` name is globally unique;
- `@RG` records with a unique `ID` and `SM` equal to the analysis sample ID;
- `--eqx` alignment encoding so SNP substitutions remain distinguishable from matches;
- the same user-visible mapping inputs and resolved defaults used by current full-length genotyping.

Temporary per-sample BAMs are not published as durable bundle artifacts. They remain only when `--keep-intermediates` is enabled.

### Merge and publication

After all per-sample mappings succeed:

1. Merge temporary BAMs with `samtools merge` while retaining the union sequence dictionary and read groups.
2. Coordinate-sort the merged stream with `samtools sort` into a staging path.
3. Move the completed BAM atomically to `artifacts/alignments/genotyping-evidence.bam`.
4. Create `genotyping-evidence.bam.bai` with `samtools index`.
5. Validate the pair with `samtools quickcheck` and an index-open check.
6. Parse the final merged BAM for known genotypes and closest-match evidence.
7. Delete temporary per-sample BAMs only after the final BAM, index, classification outputs, manifest, and provenance are successfully published, unless intermediates were requested.

The merged BAM is filterable with `samtools view -r <sample>`. Stable namespaced cluster references preserve exact cluster/sample traceability.

## Reciprocal Candidate BAM

After normalized unmatched clusters have been deduplicated across the cohort, run minimap2 once with:

- query: deduplicated unmatched clusters named by stable cluster ID;
- target: the resolved reference allele library;
- SAM output retaining `=`/`X`, CIGAR, mapping score, and long `cs` evidence required to distinguish substitutions and long gaps.

Convert, coordinate-sort, atomically publish, index, and validate the result as `unmatched-to-reference.bam` plus `.bai`. This is the durable reciprocal evidence for closest-reference ranking and cDNA extension detection.

## Classification Rules

Classification order is binding.

### 1. Existing genomic genotype

A zero-SNP alignment against an eligible existing genomic allele is a genotype of that allele even when the alignment contains insertions or deletions. Indel-only differences do not create `_nov` names.

This rule preserves existing-allele identity and replaces the current generic behavior that labels every zero-SNP indel-only unmatched relationship as an extension.

### 2. cDNA genomic extension

Before applying generic zero-SNP genomic classification, evaluate cDNA references as the explicit exception.

Classify a cluster as `_ext` only when reciprocal mapping shows:

- the reference record is classified as cDNA;
- the complete cDNA reference is covered at comparable bases;
- every comparable base is identical, with zero SNP substitutions;
- additional genomic query sequence is explained by one or more intron-sized gaps; and
- no conflicting non-intron difference invalidates the exact cDNA relationship.

Annotated reference bundles use existing record metadata for cDNA classification. FASTA-only references use the workflow's existing resolved `cdnaThreshold` rule, which is recorded in provenance.

The display label is:

```text
<closest-reference>_ext
```

Extensions follow the same singleton/shared visibility and eligibility rules as novel candidates.

### 3. novel candidate

Classify a cluster as `_nov` only when its selected best defensible reference relationship contains at least one SNP substitution and it does not satisfy `_ext` classification.

The display label is:

```text
<closest-reference>_<N>nt_nov
```

`N` counts SNP substitutions only. Inserted and deleted bases never contribute to `N`. `_0nt_nov` is invalid and must never be emitted.

### 4. un-nameable cluster

A cluster is un-nameable when it lacks a defensible closest-reference relationship or locus. Reasons are explicit enum values in metadata:

- `no-alignment`
- `insufficient-aligned-bases`
- `insufficient-coverage`
- `insufficient-identity`
- `unresolved-locus`
- `ambiguous-reference-class`

The baseline defensibility thresholds reuse the current MHC-like comparison policy where applicable:

- at least 1,000 aligned bases;
- at least 75% identity; and
- at least 70% coverage of the shorter comparable sequence.

Extension classification is stricter and requires complete comparable cDNA-reference coverage.

Un-nameable clusters remain in dedicated FASTA, JSON, and Excel artifacts and do not enter the allele matrix.

## Closest-reference Selection

For each nameable non-extension candidate, rank defensible reference alignments by:

1. fewer SNP substitutions;
2. more comparable aligned bases;
3. fewer non-intron indel bases;
4. higher alignment score;
5. higher mapping quality;
6. localized-standard reference-name order.

The chosen reference supplies the provisional allele-name prefix and locus. All ranking metrics and the selected-alignment identity are retained in candidate JSON.

## Stable Identity and Label Collisions

The stable cluster ID, not the provisional allele label, is the unique candidate key.

Two distinct sequences may share the same closest reference, SNP count, and provisional label. They remain separate rows and separate JSON records. The matrix keeps the biological provisional label unchanged and exposes the stable cluster ID in a dedicated column and candidate evidence detail. It does not append an unstable ordinal to the biological label and never merges distinct sequences by display name.

## Candidate JSON Contract

`candidate-alleles.json` is a versioned object with:

- schema version and creation timestamp;
- resolved classification thresholds and defaults;
- input artifact references and checksums;
- final BAM/BAI and FASTA artifact references and checksums;
- candidate records; and
- per-sample observations.

Each candidate record contains:

- stable cluster ID;
- provisional allele label;
- resolved locus;
- classification: `novel` or `extension`;
- support class: `singleton` or `shared`;
- closest reference name and reference class;
- SNP count;
- insertions, deletions, long-gap metrics, comparable bases, coverage, identity, mapping quality, and score;
- independent sample count;
- occurrence count;
- total cluster reads;
- ordered supporting sample IDs;
- canonical FASTA record ID and sequence checksum; and
- selected evidence BAM path plus alignment/read-group locator fields.

Each observation contains:

- stable cluster ID;
- sample ID;
- sample read-group ID;
- source cluster IDs;
- per-source-cluster read counts;
- aggregated sample read count; and
- supporting alignment locators.

Nucleotide sequence is not duplicated in JSON. FASTA is the canonical sequence payload; JSON verifies it with record ID, checksum, and file checksum.

`unnameable-unmatched-clusters.json` uses the same identity, support, sequence-reference, and evidence fields plus the un-nameable reason and failed threshold metrics. Candidate records resolve their sequence references against `candidate_alleles.fasta`; un-nameable records resolve theirs against `unnameable_unmatched_clusters.fasta`.

## Viewport Projection

Only a `full-length-ont-mhc-genotype` result bundle with valid candidate metadata gains candidate controls and rows. Other result kinds and legacy full-length bundles remain unchanged.

### Matrix populations

The unified genotype matrix contains:

1. known genotypes;
2. shared candidates observed in two or more samples; and
3. singleton candidates observed in one sample.

All populations are visible by default. Three independent controls show or hide known, shared-candidate, and singleton-candidate rows. `_nov` and `_ext` both follow the candidate's sample-count control.

Candidate sample cells show aggregated cluster reads for that stable candidate and sample. Candidate rows participate in existing row search, locus filtering, sorting, selection, and matrix support thresholds without entering haplotype inference or QC calculations.

### Candidate columns and evidence

Candidate rows display:

- provisional allele name;
- resolved locus;
- stable cluster ID;
- sample count;
- total candidate reads; and
- per-sample read cells.

Known rows leave candidate-only fields blank.

Selecting a candidate exposes read-only evidence in this viewport's existing detail/Inspector surface:

- stable cluster ID;
- provisional label and classification;
- singleton/shared support class;
- closest reference and locus;
- SNP and gap metrics;
- supporting samples and reads;
- FASTA record and checksum; and
- final BAM/BAI evidence paths and alignment locators.

### Four configurable tints

Only the allele-name cell receives the candidate category tint. The four categories are:

- shared `_nov`;
- singleton `_nov`;
- shared `_ext`; and
- singleton `_ext`.

Initial default tints are visually distinct, low-saturation colors:

- shared `_nov`: amber;
- singleton `_nov`: orange;
- shared `_ext`: teal; and
- singleton `_ext`: blue.

Each category has a color control and reset action in the genotype result Display Inspector. Selection borders, manual matrix annotations, and readable label contrast remain visible above the base category tint.

### Per-bundle display persistence

The existing genotype annotation sidecar gains an optional candidate-display section containing:

- three visibility booleans; and
- four normalized RGBA tint values.

Defaults apply when the section is absent. Changes are scoped to the current `.lungfishgenotype` bundle and use the existing atomic sidecar/provenance update path. Display preferences never change candidate JSON or classification.

## Excel Projection

Excel is a required projection of the same candidate model.

### Full Sequencing Results 1

The main genotype matrix includes:

- all known genotypes;
- every shared and singleton `_nov` candidate;
- every shared and singleton `_ext` candidate;
- per-sample aggregated cluster-read counts; and
- category fill colors on allele-name cells.

All candidates are always written, regardless of viewport visibility settings.

The immutable initial workbook uses default candidate tints. The existing explicit **Update Current Workbook** action regenerates `current.xlsx` using per-bundle tint choices. Visibility settings remain app-only and do not remove or hide workbook rows.

### Candidate Alleles sheet

Add a `Candidate Alleles` detail sheet with one row per stable candidate and columns for:

- stable cluster ID;
- provisional allele name;
- locus;
- classification and support class;
- closest reference and reference class;
- SNP count and alignment/gap metrics;
- independent sample count, occurrence count, and total reads;
- ordered supporting samples;
- per-sample read counts;
- FASTA record ID and checksum; and
- final evidence BAM path and alignment locator.

### Un-nameable Clusters sheet

Add an `Un-nameable Clusters` sheet with stable IDs, failure reasons, failed-threshold metrics, support summaries, FASTA identity/checksums, and BAM evidence locators.

### Existing unmatched sheets

Retain existing unmatched detail and pivot sheets for continuity, but update them to use the stable cluster IDs, `_nov`/`_ext` classification vocabulary, and candidate-model metrics. They must not continue emitting competing `_extension` or `_nSNP` identifiers.

### Workbook revision provenance

Initial workbook provenance includes candidate JSON, candidate and un-nameable FASTA, and final BAM evidence as inputs. Explicit `current.xlsx` updates additionally include the annotation sidecar and record the resulting workbook checksum, size, revision ID, predecessor, user-visible tint options, status, wall time, and final path.

## Provenance Contract

Every new scientific step and final artifact must satisfy the repository Lungfish provenance requirements.

At minimum record:

- workflow/tool name and exact version for minimap2, samtools merge, sort, index, quickcheck, candidate classification, FASTA/JSON rendering, and workbook rendering;
- exact argv or a reproducible Lungfish command for in-process transformations;
- all user-visible options and resolved defaults, including thresholds, mapping preset, thread allocation, cDNA rule, intermediate-retention policy, and tint values when updating Excel;
- conda/container/native runtime identity as applicable;
- input, staging, and final output paths;
- SHA-256 checksums and byte sizes for retained inputs and outputs;
- exit status and wall time;
- stderr when useful; and
- the final stored payload paths, never only temporary per-sample or staging paths.

The provenance must demonstrate that the BAM parsed for genotyping is the final `genotyping-evidence.bam`, and that reciprocal classification uses the final `unmatched-to-reference.bam`.

Missing provenance for either BAM/BAI pair, candidate JSON/FASTA, un-nameable artifacts, or workbook candidate projection is a blocking defect.

## Atomicity and Failure Handling

- Write BAMs, indexes, JSON, FASTA, workbooks, manifest, and provenance to staging paths before atomic publication.
- A minimap2, merge, sort, index, quickcheck, parse, classification, rendering, checksum, or provenance failure fails the analysis rather than publishing a successful incomplete manifest.
- Do not delete temporary per-sample BAMs until both final cohort BAM pairs and all dependent outputs are published successfully.
- Un-nameable clusters are valid classified outputs, not workflow failures.
- A legacy bundle with no candidate fields loads normally.
- A new bundle declaring corrupt or missing candidate artifacts preserves known calls but shows a visible integrity warning and does not invent candidate rows.

## Implementation Change Sets

### Set 1: durable cohort genotyping evidence

- Namespace sample cluster targets and add read groups.
- Create temporary sorted per-sample BAMs.
- Merge, final-sort, index, quickcheck, and retain `genotyping-evidence.bam`.
- Parse the final BAM for existing known-genotype behavior.
- Add manifest and complete provenance coverage.
- Run focused tests, build a fresh debug app, verify its menu/app name is **Lungfish Debug**, and launch it.

### Set 2: candidate classification and Excel analysis artifacts

- Create, sort, index, validate, and retain `unmatched-to-reference.bam`.
- Implement the corrected genomic-known, cDNA `_ext`, SNP `_nov`, and un-nameable rules.
- Write versioned candidate and un-nameable JSON/FASTA artifacts.
- Update the initial workbook's unified matrix and detail sheets.
- Add manifest, integrity checks, and complete provenance.
- Run focused tests, rebuild **Lungfish Debug**, and relaunch it.

### Set 3: viewport and editable workbook synchronization

- Load optional candidate data into the full-length result model.
- Add unified rows, stable cluster identities, visibility controls, evidence display, and four tints.
- Persist display settings per bundle.
- Extend explicit **Update Current Workbook** to apply candidate tints while always retaining all candidates.
- Run focused and regression tests, rebuild **Lungfish Debug**, and relaunch it.

No adjacent Lungfish feature or result surface is changed without separate user confirmation.

## Verification

### Automated behavior

- A zero-SNP genomic alignment with insertions or deletions remains an existing genotype.
- A completely covered zero-SNP cDNA relationship with intron-sized query gaps becomes `_ext`.
- `_nov` requires at least one SNP.
- `_Nnt_nov` counts SNP substitutions and excludes inserted/deleted bases.
- `_0nt_nov` cannot be encoded or rendered.
- Distinct sequences with identical provisional labels retain separate stable cluster IDs and rows.
- Sample aggregation correctly separates singleton from shared candidates.
- Extensions follow the same sample-count rule as novel candidates.
- Un-nameable records are absent from the matrix and present in FASTA, JSON, and Excel.
- Both cohort BAMs are coordinate-sorted, indexed, quickcheck-valid, and openable through their indexes.
- Read-group filtering recovers each sample from `genotyping-evidence.bam`.
- Manifest paths, checksums, JSON references, FASTA records, BAM evidence, and Excel rows agree.
- New scientific steps include complete final-path provenance.
- Legacy bundles and non-full-length genotype surfaces render unchanged.
- All three matrix populations default visible and filter independently.
- The four tint categories render only on allele-name cells and persist per bundle.
- Excel always contains every candidate, irrespective of viewport visibility.
- Tint changes affect `current.xlsx` only after explicit update.
- Debug packaging exposes **Lungfish Debug**, distinct from the main Lungfish app.

### Real-data validation

Run a fresh debug-named analysis using the four source samples and annotated MHC reference recorded by:

```text
/Volumes/iWES_WNPRC/32355/32355.lungfish/Analyses/Full-length ONT MHC genotyping results/2026-07-19.lungfishgenotype
```

Write the validation result to a separate debug-named bundle. Do not modify or overwrite the July 19 bundle.

Validate:

- merged cohort BAM filtering by all four sample IDs;
- reciprocal BAM and index integrity;
- candidate/support counts against deduplicated unmatched sequence evidence;
- representative `_nov` labels and SNP counts;
- representative `_ext` labels with complete cDNA identity and intron-gap evidence;
- explicit un-nameable artifacts;
- unified viewport population controls and four tints;
- initial workbook candidate rows and detail sheets;
- explicit tint update to `current.xlsx`; and
- provenance final paths, checksums, sizes, versions, argv, statuses, stderr, and wall times.

## Baseline Test Caveat

In the new worktree, the relevant baseline suites pass:

- `FullLengthONTMHCGenotypingPipelineTests`: 31 tests;
- `ONTGenotypeResultBundleTests`: 15 tests;
- `GenotypeResultViewportTests`: 130 tests; and
- `AppDebugLaunchConfigurationTests`: 5 tests.

One initial full-suite run blocked in the pre-existing `ONTBarcodeDemuxGenotypingPipelineTests.testRunIlluminaModeConsumesPreparedSampleBundlesWithoutMergingReads` while waiting for a subprocess. The same test passed independently in 1.8 seconds without code changes, indicating an existing order/interference-dependent baseline issue. Feature verification must continue to run the focused suites and should rerun the complete suite after the implementation sets, reporting any recurrence separately rather than attributing it to this feature without evidence.

# Standalone Savont Clustering Design

**Date:** 2026-08-04
**Status:** Approved for implementation planning
**Scope:** Standalone Savont FASTQ clustering in the CLI and FASTQ Operations interface

## Goal

Add Savont as a standalone clustering tool beside pbAA. A user can select any FASTQ dataset, run Savont without entering the MHC genotyping workflow, and receive a plain FASTA file containing one consensus sequence per cluster with the cluster's supporting read count in its header.

The implementation reuses Lungfish's managed Savont runtime and the small, general parts of the existing full-length ONT MHC Savont integration. It does not invoke or imitate the rest of the MHC genotyping pipeline.

## Non-goals

- Do not add reference matching, allele naming, genotyping, haplotyping, BAM creation, or workbook output.
- Do not wrap the result in a `.lungfishref` or another scientific bundle. The primary result is a normal FASTA file.
- Do not expose arbitrary Savont command-line arguments in the first version.
- Do not apply the full-length MHC workflow's default 2,000-4,000 bp read-length filter.
- Do not combine multiple selected FASTQ datasets into one clustering run.
- Do not retain large hidden copies of the input or Savont work directory after a successful publication.

## User experience

`Tools > Clustering` and the FASTQ Operations clustering category show two tools:

- `Savont Clustering`
- `pbAA Amplicon Clustering`

Savont accepts one or more `.fastq`, `.fastq.gz`, or `.lungfishfastq` inputs. Every selected input is an independent job and produces one result. A selection of three inputs therefore produces three counted-cluster FASTA files; reads are never pooled implicitly.

The ordinary controls are intentionally small:

- output directory;
- output name for a single input, defaulting to `<input>-savont-clusters`;
- thread count, defaulting to the active processor count;
- quality-value cutoff, defaulting to `90`;
- minimum cluster size, defaulting to `3`.

Advanced Options contains:

- optional minimum read length;
- optional maximum read length;
- single-strand mode.

Minimum and maximum length are unset by default. Lungfish omits the corresponding Savont arguments when a field is unset. If both values are entered, minimum must not exceed maximum. Threads and minimum cluster size must be positive; quality cutoff uses Savont's accepted range.

For multiple inputs, the output basename is derived independently from each input. Lungfish removes compound FASTQ extensions before adding `-savont-clusters.fasta`. Existing output files are not overwritten silently; the standard per-input conflict resolver chooses an available name.

Each job appears separately in Operations so progress, cancellation, errors, logs, and output paths remain attributable to the correct source dataset.

## CLI contract

Add:

```text
lungfish-cli fastq savont-cluster <input> \
  --output <clusters.fasta> \
  [--threads <n>] \
  [--quality-value-cutoff <n>] \
  [--min-cluster-size <n>] \
  [--min-read-length <n>] \
  [--max-read-length <n>] \
  [--single-strand]
```

The CLI accepts one FASTQ file or `.lungfishfastq` bundle per invocation. GUI batch selection launches this command once per resolved input so the exact command remains reproducible and failures are isolated.

The CLI writes a small JSON result payload to standard output containing the final FASTA path, provenance sidecar path, cluster count, total supporting reads, and whether a retry changed the executed thread or strand mode. Human progress and warnings go to standard error through the existing progress reporter.

## Savont execution

The focused workflow request resolves a `.lungfishfastq` bundle to its durable FASTQ payload or accepts a plain FASTQ path directly. It creates a run-owned temporary directory and invokes managed Savont 0.5.0 as:

```text
savont asv <resolved-input.fastq> \
  -o <temporary-output-directory> \
  -t <threads> \
  --quality-value-cutoff <quality> \
  --min-cluster-size <count>
```

It appends `--min-read-length`, `--max-read-length`, and `--single-strand` only when requested or when the documented retry policy activates single-strand mode.

The workflow extracts generic scratch-directory planning, retry classification, and cluster-header normalization from the MHC-specific Savont files into focused reusable types. MHC behavior and command construction remain unchanged and keep their existing tests.

### Retry policy

The standalone tool uses the already proven narrow retries:

1. If Savont exits with one of its known crash statuses while using more than one thread, retry once with one thread.
2. If Savont reports that fewer than 0.1% of SNPmers are bidirectional and requests `--single-strand`, retry once in single-strand mode.
3. If the single-strand attempt reports the same low-SNPmer condition, publish a valid empty FASTA with a warning rather than failing after a long run.
4. All other nonzero exits fail without speculative retries.

Every attempt is recorded separately in provenance, including the actual arguments, exit status, timing, and useful standard error. The final JSON payload and Operations entry clearly state when a fallback was used.

Cancellation terminates the active managed process and removes its temporary workspace. A cancelled or failed run never publishes a new final FASTA or provenance sidecar.

## Counted FASTA contract

Savont normally writes `final_asvs.fasta` with headers containing `_depth_<N>`. Lungfish publishes a normalized FASTA whose records use the first Savont header token and end in exactly one `_ReadCount-<N>` field:

```fasta
>final_consensus_0_depth_71_ReadCount-71
ACGT...
```

If a header already contains a valid `ReadCount-<N>` field, the field is preserved and not duplicated. Record order and sequences are unchanged.

Supporting counts are scientific data. A nonempty Savont FASTA whose record lacks a valid, nonnegative depth or read-count value is rejected instead of being published with an invented zero. Duplicate record identifiers, malformed FASTA records, and integer overflow also block publication. An empty Savont result is allowed only through the documented no-cluster path and produces an empty final FASTA plus a warning.

Before publication, Lungfish computes the cluster count and sum of supporting reads from the normalized records. These summaries are returned by the CLI and recorded in provenance.

## Publication and provenance

The primary visible output is:

```text
<name>-savont-clusters.fasta
```

Its canonical hidden sidecar is:

```text
<name>-savont-clusters.fasta.lungfish-provenance.json
```

Lungfish stages the normalized FASTA and its sidecar, validates both, and then publishes them as one recoverable operation. An existing output and sidecar are preserved if either new file cannot be installed. Successful publication removes the run-owned Savont workspace. Failure details and bounded log excerpts remain available in the Operations report without leaving multi-gigabyte hidden staging directories.

The provenance envelope records:

- workflow name and schema version;
- Lungfish CLI/app version and Savont version;
- exact top-level CLI argv and every actual Savont attempt argv;
- all user-visible options, defaults, and resolved values;
- whether length limits were absent or explicitly supplied;
- whether a single-thread or single-strand fallback was used;
- original input path, size, checksum, and source-bundle provenance when applicable;
- resolved FASTQ payload path used by Savont;
- final FASTA and sidecar paths, output size, checksum, cluster count, and summed support;
- managed conda environment/package identity and executable path;
- runtime and user identity;
- start/end timestamps, wall time, exit status, cancellation status, and useful standard error.

For `.lungfishfastq` input, GUI import/provenance rehydration preserves the bundle as the durable scientific source and points the final record at the published FASTA, not only at a temporary materialized payload. Missing or invalid provenance is a blocking publication failure.

## GUI routing

Add `savont` to `FASTQOperationToolID` in the clustering category. It:

- requires only a FASTQ dataset;
- does not accept FASTA inputs;
- uses per-input output mode;
- requires provenance;
- uses a native Savont configuration pane rather than pbAA's guide-reference pane;
- launches one `SavontClusteringRunRequest` per selected input;
- imports or reveals the final FASTA while keeping the provenance sidecar hidden from the ordinary sidebar.

The tool uses the existing managed-tool preflight. If Savont is unavailable, the dialog explains which managed runtime must be installed or repaired before Run is enabled.

## Error handling

Errors name the affected input and the failed phase. User-visible failures include:

- missing or unreadable FASTQ payload;
- invalid option values;
- managed Savont runtime unavailable;
- temporary workspace creation failure;
- Savont process failure after permitted retries;
- missing `final_asvs.fasta`;
- malformed FASTA or missing/invalid support counts;
- output-name conflict that cannot be resolved;
- output or provenance publication failure.

The operation does not report success until the final FASTA and valid provenance sidecar are both present at their durable paths.

## Testing and verification

Implementation follows test-first development. Automated coverage includes:

- request validation and default resolution, including no default length restriction;
- exact Savont argv with absent and present length bounds;
- single-thread and single-strand retry decisions;
- empty-cluster warning behavior;
- strict FASTA normalization, count parsing, duplicate detection, and summary totals;
- atomic FASTA-plus-provenance publication and rollback;
- provenance fields, hashes, sizes, runtime identity, attempt history, and final durable paths;
- CLI parsing and JSON result payload;
- FASTQ Operations catalog placement beside pbAA;
- native dialog defaults, validation, multi-input fan-out, cancellation, and output naming;
- `.lungfishfastq` payload resolution and provenance rehydration;
- preservation of existing full-length MHC Savont behavior.

The bounded manual integration test uses a deterministic 1,000-read subset of:

```text
/Volumes/iWES_WNPRC/32500/32500.lungfish/barcode12.lungfishfastq
```

The test verifies that Savont completes, every published FASTA record has an accurate `_ReadCount-N` field, the support sum is internally consistent, the sidecar points to the final FASTA, and the temporary workspace is removed. A deterministic 10,000-read subset is used only if 1,000 reads do not produce enough clusters to exercise the result contract.

## Acceptance criteria

The feature is complete when:

1. Savont appears beside pbAA under Clustering.
2. One or more FASTQ inputs can be launched without a reference sequence.
3. Every input produces its own plain counted-cluster FASTA.
4. No read-length restriction is applied unless the user enters one.
5. Every nonempty record has a validated support count.
6. The final FASTA has complete, rehydrated provenance at its canonical sidecar.
7. Failures and cancellation leave no partial published result or stale large workspace.
8. Existing pbAA and full-length MHC Savont workflows remain unchanged.

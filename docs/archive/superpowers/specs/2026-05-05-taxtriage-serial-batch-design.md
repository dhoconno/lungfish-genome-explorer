# TaxTriage Serial Batch Design

## Goal

Run multi-sample TaxTriage jobs from the app as a serial batch: one TaxTriage/Nextflow execution per selected sample or `.lungfishfastq` bundle, with aggregate results discoverable from the same batch directory.

## Current Behavior

The TaxTriage wizard builds one `TaxTriageConfig` containing all selected samples. `AppDelegate.runTaxTriage` materializes each sample, then calls `TaxTriagePipeline.run` once. That produces one Nextflow samplesheet and lets Nextflow schedule all sample work in a single pipeline run.

## Target Behavior

For multi-sample TaxTriage configs, Lungfish will run samples in a deterministic `config.samples` order. Each sample gets a single-sample `TaxTriageConfig` and a sample-specific output directory under the batch root. The app operation remains one Operations Center item, but progress is mapped as `sample index + sample progress` over total samples.

Single-sample TaxTriage remains unchanged and writes directly to the requested output directory.

## Output Layout

Multi-sample output:

```text
taxtriage-batch-.../
  taxtriage-result.json
  .lungfish-provenance.json
  taxtriage.sqlite
  <sample-id>/
    samplesheet.csv
    taxtriage-result.json
    taxtriage-launch-command.txt
    ...
  <next-sample-id>/
    ...
```

Sample directory names are sanitized for the filesystem and made unique if needed. The aggregate root `taxtriage-result.json` preserves the original multi-sample config, source bundle URLs, combined output file lists, ignored Nextflow task failures, and sample-level failures.

## Data Flow

`AppDelegate.runTaxTriage` still resolves/materializes bundle inputs first. It then delegates execution to a serial batch runner. The runner calls `TaxTriagePipeline.run` one sample at a time. Successful sample results are combined into one aggregate `TaxTriageResult` at the batch root. If some samples fail, the runner continues with remaining samples and records failures in the aggregate result. If all samples fail, the app operation fails.

After execution, the existing `lungfish-cli build-db taxtriage <batch-root>` path builds `taxtriage.sqlite`. The build-db command will detect serial sample subdirectories when the batch root does not contain a direct TaxTriage report and merge rows from each sample directory, prefixing relative BAM paths with the sample directory so the viewer can open BAMs from the aggregate database.

## Provenance

Each sample run keeps the existing TaxTriage launch metadata and result sidecar in its sample directory. The aggregate batch root writes `.lungfish-provenance.json` with workflow parameters, per-sample inputs, outputs, exit status, wall time, and stderr for failed samples. This makes the final batch directory point at final stored payloads instead of only temporary staging paths.

## Tests

Add workflow tests for serial execution order, sample output directories, aggregate result persistence, and partial-failure continuation. Add CLI tests for `build-db taxtriage` parsing serial sample subdirectories into one aggregate SQLite database.

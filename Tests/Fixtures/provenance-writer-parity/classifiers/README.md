# Classifier record facts

This folder holds the facts of five classifier records as Lungfish Genome Explorer (LGE) wrote them at the base of Phase 2.7 (`18e422c4f`). Lane F1 captured them with fake tools before any executor lane changed a classifier writer, as the rule "Freeze, then change" in `docs/contracts/RECORDING-PROVENANCE.md` asks. The bare-run parity suites list only the files of the parent folder, so these files sit in a folder of their own.

## How the files were made

`ClassifierWriterFactsTests` in LungfishAppTests runs each writer the way its route ran it at the base, through `ClassifierLegacyRuns`. Kraken2 and Bracken are the fake tools of `FakeClassificationCondaFixture` in LungfishTestSupport. EsViritu is the stand-in in `ClassifierLegacyRuns`. Each test projects the record with `ProvenanceCompatFacts`, normalizes the facts with `BareRunWriterParity.normalized` and compares them with the file here.

```
LUNGFISH_CAPTURE_PROVENANCE_FACTS=1 swift test --skip-update --filter ClassifierWriterFactsTests
```

The command writes the files that are missing and compares the rest. It never replaces a file, and a recapture is its own reviewed commit.

The normalization keeps the facts the same on every Mac and every run.

- Host values become tokens, namely `<app-version>`, `<host-os>`, `<host-name>`, and `<cli-version>` when the CLI version differs from the app version.
- Any UUID becomes `<uuid>`.
- The times a clock decides are cleared (timing `clockedRunAndSteps`), and every `peakMemoryBytes` is removed.
- The checksum and size of a file whose bytes differ on every run are cleared. These are the result sidecars `classification-result.json` and `esviritu-result.json`, the gzipped per-read output and its SQLite index, and the Kraken2 batch manifest.

The two batch indexes `kraken2.sqlite` and `esviritu.sqlite` are fixed stand-in files, because `lungfish-cli build-db` runs as a subprocess that the unit tier does not start.

## Scenarios

| File | Writer and route | Input |
|---|---|---|
| `kraken2-pipeline-profile.facts.json` | `ClassificationPipeline.profile`, the run the Kraken2 wizard always asks for | One FASTQ file |
| `conda-classify-wrapper.facts.json` | `lungfish-cli conda classify` with the command the Operations panel records for the same wizard config. Its wrapper record `lungfish.classify` replaces the pipeline record | One FASTQ file |
| `kraken2-batch.facts.json` | `MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance` as `runClassificationBatch` calls it, with the `/bin/sh -c` argv of `classificationBatchReplayCommand` | Two samples that complete |
| `esviritu-pipeline.facts.json` | `EsVirituPipeline.detect`, the record both routes write for one sample | One FASTQ file |
| `esviritu-batch.facts.json` | `MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance` as `runEsVirituBatch` calls it, with the folded argv of `esVirituBatchCLIArguments` | Two samples that complete |

## Which lane may move which fact

A lane moves only the facts its panel decision names, in a reviewed commit that names the decision. Any other difference is a defect of that lane.

| Lane | Files | Facts it may move |
|---|---|---|
| A8, Kraken2 on the executor | `conda-classify-wrapper`, `kraken2-pipeline-profile`, `kraken2-batch` | The argv, durable replay argv and reproducible command, which become `kraken2 classify ... --format json` (E11) and one batch command (E8). The status, exit status and stderr of a run (E4, E5). The preset and the defaults, which come from one table (E12). Where `readSetPlan` lives (E13). The output files the executor adds, such as `analysis-metadata.json` (E1), and the database identity (E9) |
| A9, EsViritu on the executor | `esviritu-pipeline`, `esviritu-batch` | The batch argv, which becomes the command that ran (E8). The lineage of each input (D5) and the kept inputs folder (E3). The output files the executor adds and the cleanup that keeps two tables (E7). The database identity (E9) |
| S2, environment changes | every file | The conda and container values each step records, and the tool version evidence a managed environment gives (P10, P12) |
| S3, the recorder rebuilt on the builder | `kraken2-pipeline-profile`, `esviritu-pipeline` | The repeated `files` entries and the step order the rebuild declares, never the canonical run rules (P11) |
| S4a and S4b, the envelope copy helper | `kraken2-batch`, `esviritu-batch` | The status and the step ids the batch rollup copies from each sample record (P5) |

The known defects these records hold are pinned on their own in `ClassifierLegacyRecordPinTests` and `ClassifierBrackenDegradePinTests`, each with the lane that flips it.

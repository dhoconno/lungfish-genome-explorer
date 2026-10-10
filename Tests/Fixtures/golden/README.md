# Phase 1 golden fixtures

These goldens are the oracle for the Lungfish Genome Explorer (LGE) architecture program. Phases 1 to 4 restructure how operations launch, how Nextflow environments run, how events are scoped and where files live. Those changes must leave the scientific output of LGE byte for byte the same, and these files are how the program checks that. They were captured from LGE 2026.9.78, built from code identical to main at 1f70a13ea, before any Phase 1 code merged.

Each capture runs `lungfish-cli` the way the app runs it, normalizes the outputs and stores them here. The compare command reruns every capture and diffs the fresh outputs against these files. Only wall-clock times, run IDs and the fields the program manager ruled on are masked. Everything else is compared byte for byte, including tool versions, argv, parameters, read counts and hashes.

## Running the compare

Run the compare from the root of any checkout:

```sh
python3 scripts/golden/golden.py compare                  # builds lungfish-cli from this checkout first
python3 scripts/golden/golden.py compare --cli PATH       # use a lungfish-cli that is already built
python3 scripts/golden/golden.py compare --only mapping   # one capture, repeatable
python3 scripts/golden/golden.py compare --strict         # leave out rules N1 and N2 to show what they hide
```

Without `--cli` the command runs `swift build --skip-update --product lungfish-cli --package-path <repo root>`. The compare prints a unified diff and exits 1 when any golden differs, when a fresh output has no golden, when a golden is not produced, or when a self-check fails. It prints the wall time of each capture and of the whole run and writes them to `/Users/Shared/lungfish-golden/cache/last-compare.json`. The four captures take 25 to 60 seconds on the Mac they were captured on, depending on load, plus the build.

The captures run in a fixed scratch folder, `/Users/Shared/lungfish-golden/run`, which is emptied at the start of every run and kept afterwards for inspection. A fixed folder keeps the bytes of outputs that embed their own paths the same from run to run. The CLI is cloned into that folder, so the executable path that provenance records does not depend on the checkout. Each command gets a minimal environment with the bare `PATH` the app gives the CLI, `TMPDIR` inside the scratch folder and `COLUMNS=80`. Thread counts are pinned in argv. A lock file in the cache folder keeps two runs from overlapping.

The captures run the CLI with `LUNGFISH_STORAGE_ROOT=/Users/Shared/lungfish-golden/storage`, the golden environment that `Tests/Fixtures/golden-environment/lock.json` pins. It holds the minimap2, samtools, seqkit, kraken2, EsViritu, BBTools, pysam and openpyxl environments, the Kraken2 database named Viral and the EsViritu Viral DB. `python3 scripts/golden/environment.py provision` builds it, and every run checks it against the lock before any capture that needs it. Nothing is installed or updated by the compare. Every path under `/Users/Shared/lungfish-golden` is the same on every Mac and for every user, so the goldens are not bound to an account. `docs/contracts/MACHINES.md` says which Macs run the comparison. The genotype capture downloads the demo project archive once into `/Users/Shared/lungfish-golden/cache` and checks its size and SHA-256 on every run.

## What each capture runs

### cli-help

`lungfish-cli --experimental-dump-help` lists the command tree, 280 command paths including the hidden `fastq ont-genotype`. The capture runs `<command path> --help` for each one and stores one file per path, named like `lungfish-cli.fastq.materialize.txt`, with `index.tsv` listing the path, whether it is shown, the exit status and the file.

### mapping

The capture copies `Tests/Fixtures/sarscov2` into the scratch folder and runs `lungfish-cli map` with minimap2, the `sr` preset, paired reads and two threads. The goldens hold the CLI report, the BAM header without the `@PG` line samtools adds for itself, a SHA-256 of the alignment records as `samtools view --no-PG` prints them in BAM order, the read counts (total, primary, mapped, unmapped, secondary, supplementary, per contig and the full flagstat), `mapping-result.json`, both provenance files and the list of output files.

### classifiers

The capture builds a project with the 100-read `test_1.fastq.gz` as a physical bundle and a virtual length-filter subset of the 55 reads of 150 bases or more. The subset bundle holds only `read-ids.txt`, a 10-read `preview.fastq` and `derived.manifest.json`, the layout the app writes. The preview is shorter than the app's 1,000 reads so the counts tell a tool that read the preview (10) from one that read the materialized subset (55) and from one that read the whole root (100).

Kraken2 runs through `lungfish-cli conda classify` on the bundle, which materializes the subset itself. EsViritu runs as `fastq materialize` followed by `esviritu detect` on the FASTQ. A probe golden also runs `esviritu detect` on the bundle itself, which materializes the subset into `.lungfish-esviritu-inputs` in its output folder and records the bundle in provenance. The probe once recorded a refusal, and its change to a successful run was a deliberate golden update when the CLI learned to read bundles. The goldens hold the input counts, fingerprints of both databases, the materialized read counts, the report and per-read output and result tables in sorted order, a dump of the Kraken2 read index, the result sidecars, all provenance files and the output inventories.

### genotype

The capture downloads the mhc-genotyping demo project 2026.9.58, extracts it into the scratch folder and runs `lungfish-cli fastq genotype-cohort` with the options the demo verifier uses. It then exports the workbook with `genotype export-xlsx` and `genotype export-pivot-xlsx`, and the matrix with `genotype export` as TSV and CSV. The demo project in `~/Documents/LGE Demo Projects` is never opened.

The goldens hold every text file of the result bundle under `bundle/` and every export under `exports/`, and the stdout of each command. The genotyping-evidence BAM and the merged BAM it is filtered from each get a records hash and the per-reference counts `samtools idxstats` reads from the index, under `bundle-bam/` and `merged-bam/`. A workbook is stored as its XML parts in sorted name order, under `<name>.xlsx.parts/`, because an `.xlsx` is a zip whose entry order and dates are container details. The base64 scientific inputs of each export snapshot are also stored decoded under `captured-inputs/`, so a change in them reads as a plain diff. Input copies named `input-N.bin` and the workbook renderer script are left out, because they repeat files that are compared elsewhere or ship with the app.

The run deletes three intermediates whose digests its provenance records. They are the sample manifest `.amplicon-genotyping/inputs/illumina-sample-manifest.json`, the merged BAM and the merged BAM's index. The capture copies them while the run is going, keeping the last bytes it read before the run deleted them, and checks each copy against the digest the provenance records. The manifest is stored as `run/illumina-sample-manifest.json`, and the merged BAM feeds the `merged-bam/` goldens.

Paths in the goldens drop a leading dot and a trailing UUID from each folder or file name, so `.lungfish-provenance.json` is stored as `lungfish-provenance.json` and `workbook.xlsx.export-<UUID>` as `workbook.xlsx.export`.

## Normalization

Every rule works on the raw text. Formatting, key order and escaping of everything a rule does not touch are compared byte for byte. The scratch folder path becomes `<RUN_ROOT>` in every spelling tools write, which keeps the rest of each path.

### Binding rules

These rules come from the lane brief and mask only wall-clock times and run IDs.

| Rule | What it masks | Token |
|---|---|---|
| Timestamps | ISO 8601 and RFC 3339 dates and date-times in any text, including the comma fraction Python logging writes | `<TIMESTAMP>` |
| Run IDs | UUIDs, numbered by first appearance in each file so links inside a file stay visible | `<UUID-1>` |
| Epoch times | Numbers under `createdAt`, `startTime`, `endTime` and similar keys, only within a wall-clock range | `<EPOCH>` |
| Durations | Numbers under `wallTimeSeconds`, `wallClockSeconds`, `runtime` and similar keys, quoted or not | `<DURATION>` |
| Tool log times | EsViritu step and total run times, fastp `time used`, minimap2 elapsed and real time, kraken2 `processed in`, LGE `completed in` and `Runtime` | `<DURATION>` |

The workbook rule from the brief stores the XML parts in canonical order and masks the times in `docProps/core.xml`.

### Rules the program manager approved

The program manager ruled on these on 2026-10-02. Each one names the row of the two-run catalog it was approved for.

| Rule | What it masks | Why it varies |
|---|---|---|
| R5 | `processIdentifier` in provenance, as `<PID>` | The process ID changes every run |
| R6 | minimap2 CPU ratio, CPU seconds and peak memory | They follow scheduling and load |
| R7 | kraken2 sequences and bases per minute | They are computed from elapsed time |
| R8 | Hash and size of mapping records whose path ends in `.sam`, `.bam` or `.bai` | minimap2 writes the per-run reference staging folder into `@PG`, and the header and records goldens compare the content |
| R10 | Hash and size of a file that holds a masked field and is itself a golden | Its bytes change with the masked field, and its own golden compares the content |

| Rule | What it masks | Why it varies |
|---|---|---|
| R11 | Hash of `classification.kraken.gz` | gzip stores the wall-clock time in header bytes 4 to 7, and the sorted per-read golden compares the content |
| R12 | Hash of the Kraken2 read index | The index stores its creation time, and its dump is a golden |
| R13 | The partial line on each side of the stderr truncation marker, as `<TRUNCATED-LINE>`, and the partial last line before the older head-only marker | The two cuts, 2,048 characters from the start and 8,192 from the end, move with the length of every masked number around them |
| R14 | Date-times in worksheet cells | The workbook records when it was generated |
| R15, R16 | Digests of export inputs that hold a run-dependent field, and the base64 inputs of each snapshot and request file decoded, normalized and encoded again | Their bytes change with the masked fields, which the decoded inputs compare |
| Q3 | The exact version `lungfish-cli --version` prints, under the keys that record the LGE app or CLI version, as `<APP_VERSION>` | It changes with every release |

A masked digest becomes `<SHA256-R10>` or the token of its rule, and a masked size becomes `<SIZE-R10>` or the like. The token names only the rule. The record's path or the key next to it says what the digest belongs to. A file or input counts as holding a masked field only when that field changes from run to run, so a timestamp copied from the inputs, such as the `lastModified` date of the demo's definition set, does not mask its file's digest. The digest is replaced only where it equals the digest of the file on disk at capture time, so a record that names the file with any other digest shows in the diff.

### Masked records

Each capture writes `normalization.tsv`, the list of every masked file, input and record path, and the compare checks it like any other golden. A new mask therefore shows up as a diff. The R10 files are these.

| Capture | Files whose digest and size R10 masks |
|---|---|
| mapping | `lungfish-provenance.json`, `mapping-provenance.json`, `mapping-result.json` |
| classifiers | `kraken2/classification-result.json`, `kraken2/lungfish-provenance.json`, `esviritu/esviritu-result.json`, `esviritu/lungfish-provenance.json`, `esviritu/materialize-provenance.json`, `esviritu/materialize-folder-provenance.json` |
| genotype, bundle | `genotype-result.json`, `lungfish-provenance.json`, `retained-demux-genotyping-provenance.json`, the haplotype analysis, the hyphen and underscore stats files, the underscore provenance file, both minimap2 stderr logs, the workbook, its receipt and its export folder's `replay.sh`, `request.json`, `snapshot.json` and `stdout.json` |
| genotype, provenance | All 26 per-file provenance records under `bundle/provenance/` |
| genotype, exports | `lungfish-provenance.json`, both matrix provenance files, both workbooks, both receipts, and the `replay.sh`, `request.json`, `snapshot.json` and `stdout.json` of both export folders |
| genotype, run | `run/illumina-sample-manifest.json`, digest only, because its size never changes (see N3) |

R16 masks the digests of the `analysis.json`, `annotations.json`, `capture-context.json` and `result.json` inputs of the bundle's own workbook, and of the `annotations.json` and `result.json` inputs of both exports. The other inputs keep their digests because they hold no run-dependent field.

### Rules from the second ruling round

The program manager ruled on these on 2026-10-02 as well. N1 and N2 cover nondeterminism in the app and random identifiers in tool output, so `--strict` leaves them out to show what they hide.

| Rule | What it masks | Why it varies |
|---|---|---|
| N1 | Member order inside the JSON strings stored under `stats.rawMetrics` in each export's `result.json` input, put in sorted key order with values and array order untouched | `ONTGenotypeRunStats.load` serializes nested dictionaries without sorted keys, so the order changes with each process |
| N2 | Hash and size of the evidence BAM and the merged BAM wherever a record names them, the hash of their indexes, and their base64 copies in the request files | `samtools merge` names colliding `@PG` IDs with a suffix from `lrand48`, and the index offsets move with the header length |
| N3 | Nothing beyond the binding run ID rule and R10 | The manifest records the per-run `bbmerge-<UUID>` staging folder, needed because the demo project's path holds a space |

N2 keeps a records hash and index statistics of both BAMs as goldens, so their content is compared, and the size of each index stays compared. No header golden is kept for these two BAMs, because the suffix would need a mask of its own. For N3 the capture keeps the copy of the deleted manifest as a golden, where the run ID rule masks the staging folder, and R10 masks the digest the provenance records for it.

### Host rules

The owner ruled on these on 2026-10-08, when a second Mac became a release Mac. Without them the goldens pass only on the macOS build and the core count they were captured with.

| Rule | What it masks | Why it varies |
|---|---|---|
| H1 | The macOS version as `<HOST-OS-VERSION>` and the build as `<HOST-OS-BUILD>`, only under `hostOS` and `operatingSystemVersion` (`macOS 26.6.2 (arm64)`) and `platform` (`Version 26.6.2 (Build 25G83)` from LGE, `macOS-26.6.2-arm64-arm-64bit` from Python) | Each release Mac runs its own macOS build, and macOS updates change it |
| H2 | The number ArgumentParser prints after `(default: active cores)` in help text, as `<ACTIVE-CORES>` | It is the core count of the Mac that prints the help. Every capture pins its thread counts in argv, so no other golden records it. |

The architecture and the rest of each value stay compared. An export folder's `stdout.json` holds Python's `platform`, so R10 masks its digest and size where they are recorded.

### What stays unmasked

Some fields would differ with another environment or after an update. They stay unmasked, so the goldens are bound to the locked golden environment. They are the conda and database paths under `/Users/Shared/lungfish-golden/storage`, the tool versions, the `dependencySet`, the database fingerprints in `classifiers/environment.json`, and the `(dev)` build label of a SwiftPM build. A golden that records the home folder fails the run's portability check, because the home folder differs between users. A CLI inside a Preview or Stable app runs in place, resolves another channel's storage and records another version label, so its goldens differ from these.

## Updating a golden deliberately

A golden changes only through a reviewed commit. When a change is meant to alter an output, such as a new provenance field, a tool update, a database update or a CLI parity fix, follow these steps:

1. Run `python3 scripts/golden/golden.py compare` and read the whole diff.
2. Run `python3 scripts/golden/golden.py capture --only <capture>` for each capture the change should alter. Capture refuses to write a capture whose self-checks fail.
3. Review `git diff Tests/Fixtures/golden` and check that every changed line follows from the intended change.
4. Commit the goldens with the change and say in the message which captures changed and why.

A new run-dependent field fails the compare. Report it with both values and the narrowest rule that would mask it, and wait for a ruling before adding the rule to `scripts/golden/normalize.py`. The tests in `scripts/tests/test_golden.py` cover every rule.

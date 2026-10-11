# CLI event fixtures

These folders hold transcripts of the event lines that `lungfish-cli` prints when a command runs with events on. `CLIEventCompatibilityTests` decodes every file in `v1`, `CLIPrimerTrimRunnerTests` reads the file in `v2`, `CLIEventLegacyNamesTests` decodes every file in `legacy`, the runner tests of the four import commands play them, `CLIEventTranscriptCoverageTests` decodes every file under `commands`, and `CLIEventContractCoverageTests` decodes every file under `results`. The wire format is written down in `docs/formats/cli-events.md`.

## v1

Every file in `v1` is captured output, not hand-written text. The runs were made at program commit `90d34c550`, before the version 2 envelope existed, so each line is what the shipped version 1 emitters print. A file is one run of one command, one JSON object per line, in the order the command wrote them.

Each command ran in process on a small fixture with a capturing sink. `fastq platform` has no sink to inject, because it writes through the flushing stdout helper, so its standard output was redirected for the length of the run. The scratch folder of each run is rewritten to `/work` in every line, in both its plain and its slash-escaped spelling. Nothing else is edited, and lines keep the escaped slashes that `JSONEncoder` writes.

These files must not be captured again. After the version 2 encoder landed, the same commands print version 2 lines, so a new run would no longer show what a version 1 app receives.

| Transcript | Command and fixture |
| --- | --- |
| `msa-annotate-add` | `msa annotate add` on a three-row alignment |
| `msa-annotate-edit` | `msa annotate edit` on that annotation |
| `msa-annotate-project` | `msa annotate project` to another row, which ends with `warningCount` 1 |
| `msa-annotate-delete` | `msa annotate delete` |
| `msa-export` | `msa export` to aligned FASTA from an alignment with no annotation |
| `msa-export-with-warning` | `msa export` to PHYLIP, which logs a warning that annotations are dropped |
| `msa-export-failed` | `msa export` of a bundle that does not exist, which ends in `failed` |
| `msa-consensus` | `msa consensus` |
| `msa-extract` | `msa extract` to a derived alignment |
| `msa-distance` | `msa distance` with the identity model |
| `msa-discriminating-sites` | `msa discriminating-sites` on four rows |
| `msa-mask-columns` | `msa mask columns` |
| `msa-trim-columns` | `msa trim columns --gap-only` |
| `tree-export-subtree` | `tree export subtree` by label |
| `tree-reroot` | `tree reroot` on a tip |
| `tree-extract-subtree` | `tree extract-subtree` by node |
| `tree-relabel` | `tree relabel` from a metadata column |
| `tree-reroot-failed` | `tree reroot` on a tip that does not exist, which ends in `failed` |
| `fastq-platform` | `fastq platform --set ont` on a bundle recorded as Illumina |
| `fastq-platform-failed` | `fastq platform --set ont` on a bundle whose metadata file cannot be read |

## v2

`v2/bam-primer-trim.ndjson` is a version 2 run of `bam primer-trim` captured in process in lane C3, with paths rewritten to `/work` and `outputs` in version 1 order. `CLIPrimerTrimRunnerTests` asserts its track id.

## legacy

Every file in `legacy` is the stream of a command in the private shape that it printed before the version 2 envelope. The shapes are S2 for `import msa` and `import tree`, S3 for `import geneious` and `import application-export`, and S8 and S9 for the two ONT FASTQ commands, as numbered in the Phase 2.6 inventory. `CLIEventLegacyNamesTests` reads each file with the version 2 decoder, which maps the names of S2 and S3 through its dated legacy table and needs no row for S8 and S9. `ImportMSATreeE2ETests` and `ApplicationExportImportE2ETests` check that the version 2 stream of each run of the four import commands reads to the same events as the file for that run. `CLINativeBundleImportRunnerTests` and `CLIApplicationExportImportRunnerTests` play those files back through a stand-in `lungfish-cli` to pin what the Operations Panel shows for each.

The runs were made in process at program commit `1171aef68`, each on a small fixture that `ImportStreamCapture` builds, with the scratch folder rewritten to `/work` in its plain and slash-escaped spellings. Nothing else is edited. The two ONT files hold the event lines from standard error, because those commands printed their progress there. Like the files in `v1`, these must not be captured again. The four import commands print version 2 events now, so a new run would no longer show what an older CLI prints.

| Transcript | Command and fixture |
| --- | --- |
| `import-msa` | `import msa` of a two-row CLUSTAL alignment |
| `import-msa-with-warning` | `import msa` of an alignment whose two rows share a name, which logs one warning |
| `import-msa-failed` | `import msa` of a file that does not exist, which ends in `nativeBundleImportFailed` |
| `import-tree` | `import tree` of a tree with numeric support values |
| `import-tree-with-warning` | `import tree` of a tree with no branch lengths, which logs one warning |
| `import-tree-failed` | `import tree` of a file that does not exist |
| `import-geneious` | `import geneious --no-import-references` of a folder that scans as a Geneious export |
| `import-geneious-with-warning` | the same folder with `--preserve-unsupported`, which logs five warnings |
| `import-geneious-failed` | `import geneious` of a file that does not exist |
| `import-application-export` | `import application-export alignment-tree --no-import-references` of a folder with one alignment and one tree |
| `import-application-export-with-warning` | the same folder with a report file that the native-only card does not import, which logs one warning |
| `import-application-export-failed` | `import application-export alignment-tree` of a folder that does not exist |
| `fastq-ont-fluidigm-samples` | `fastq ont-fluidigm-samples` on four reads and two barcodes |
| `fastq-ont-pacbio-barcode-demux` | `fastq ont-pacbio-barcode-demux --chunk-jobs 1` on two reads and one plate barcode row |

## commands

The contract table `CLIEventContractTable` names the leaf commands that emit events. Each has a folder here, named by its path with hyphens, such as `msa-annotate-add`. A file in it is one run that ends one way. `complete` ends in a `complete` line, `complete-with-warning` is such a run that also logs a warning, and `failed` ends in a `failed` line. Every line is a version 2 line, and every line is captured output.

`CLIEventTranscriptCoverageTests` decodes each line with the current reader and with the frozen version 1 reader and expects the same events from both. It also checks that each run starts with `start`, ends with one terminal event, holds no line a reader skips as chatter, and carries no text that a system message wrote.

### Captured in process

The leaves that need no external tool ran in process on a small fixture, as the version 1 captures did. A command with a test seam handed its lines to a capturing sink. `fastq platform`, the four import commands and the three `build-db` leaves have none, so their standard output was redirected for the length of the run, and `ImportStreamCapture` builds the fixtures of the four import commands. `BuildDbStreamCapture` builds those of the `build-db` leaves. The two ONT split commands print their events on standard error, so their `execute(emit:)` seam handed the lines to the sink. The scratch folder is rewritten to `/work` in its plain and slash-escaped spellings, and nothing else is edited.

`CLIEventTranscriptCoverageTests` runs the same captures again and fails when a line differs from its file. After a deliberate change to an emitter, run that suite with `LUNGFISH_RECAPTURE_CLI_EVENTS=1`, which writes the files instead of comparing them, and review the diff.

A failed run is kept only when Lungfish wrote its message. A Foundation message changes with the system language and the macOS release, so `msa export` has no failed run.

| Folder | Files | Command and fixture |
| --- | --- | --- |
| `msa-annotate-add` | `complete` | `msa annotate add` on a three-row alignment |
| `msa-annotate-edit` | `complete`, `complete-with-warning` | `msa annotate edit` of a source annotation, then of a projected one that carries a warning |
| `msa-annotate-project` | `complete-with-warning` | `msa annotate project` onto a row that splits the feature, which logs one warning |
| `msa-annotate-delete` | `complete` | `msa annotate delete` |
| `msa-export` | `complete`, `complete-with-warning` | `msa export` of one row to aligned FASTA, then of an annotated alignment to PHYLIP |
| `msa-consensus` | `complete` | `msa consensus` |
| `msa-extract` | `complete` | `msa extract` to a derived alignment |
| `msa-distance` | `complete` | `msa distance` with the identity model |
| `msa-discriminating-sites` | `complete` | `msa discriminating-sites` on four rows |
| `msa-mask-columns` | `complete` | `msa mask columns` |
| `msa-trim-columns` | `complete` | `msa trim columns --gap-only` |
| `tree-export-subtree` | `complete` | `tree export subtree` by label |
| `tree-reroot` | `complete`, `failed` | `tree reroot` on a tip, then on a node that does not exist |
| `tree-extract-subtree` | `complete`, `failed` | `tree extract-subtree` by node, then by a node that does not exist |
| `tree-relabel` | `complete` | `tree relabel` from a metadata column |
| `fastq-ont-fluidigm-samples` | `complete`, `failed` | `fastq ont-fluidigm-samples` on two reads that carry both Fluidigm primers and one barcode, then on an output folder that already exists |
| `fastq-ont-pacbio-barcode-demux` | `complete`, `failed` | `fastq ont-pacbio-barcode-demux` on two reads between one barcode pair, then on an output folder that already exists |
| `fastq-platform` | `complete`, `failed` | `fastq platform --set ont` on a bundle recorded as Illumina, then on a folder that is not a bundle |
| `import-msa` | `complete`, `complete-with-warning`, `failed` | `import msa` of a two-row CLUSTAL alignment, then of an alignment whose rows share a name, then of a file that does not exist |
| `import-tree` | `complete`, `complete-with-warning`, `failed` | `import tree` of a tree with numeric support values, then of a tree with no branch lengths, then of a file that does not exist |
| `import-geneious` | `complete`, `complete-with-warning`, `failed` | `import geneious --no-import-references` of a folder that scans as a Geneious export, then the same with `--preserve-unsupported`, then of a file that does not exist |
| `import-application-export` | `complete`, `complete-with-warning`, `failed` | `import application-export alignment-tree --no-import-references` of a folder with one alignment and one tree, then of the same folder with a report file the card does not import, then of a folder that does not exist |
| `build-db-kraken2` | `complete`, `complete-existing`, `failed` | `build-db kraken2` on a copy of `Tests/Fixtures/kraken2-mini`, then a second run that finds the database the first one built, then a run whose `--sample-dir` names a folder with no `classification.kreport` |
| `build-db-esviritu` | `complete` | `build-db esviritu` on a copy of `Tests/Fixtures/esviritu-mini` without the `_temp` folders that hold its BAMs, so no samtools runs |
| `build-db-taxtriage` | `complete` | `build-db taxtriage` on a copy of `Tests/Fixtures/taxtriage-mini` without `minimap2`, the folder that holds its BAMs |

### Captured from the built CLI

Five leaves run an external tool that a unit test cannot start, so each was run once as the `lungfish-cli` built from the program branch with lane C3 landed, and its event lines were kept as they came. Each folder holds one `complete` file. The command lines name the scratch folder `/work`, which the lines rewrite the same way. Lane C6 ran `align-mafft` and `variants-call` again with the CLI built from its branch, after both commands began to type their completions, and replaced those two files. Their runs followed the same recipe.

The run followed `scripts/golden/captures.py`. The current folder was a scratch folder, `PATH` was the bare system path, and `LUNGFISH_CONDA_SHARED_PKGS=0` kept the shared package cache out. One difference needs saying. The locked golden storage at `/Users/Shared/lungfish-golden/storage` holds eight conda environments, and none is MAFFT, IQ-TREE, an assembler, LoFreq or iVar. `LUNGFISH_STORAGE_ROOT` named a scratch storage root instead. Its `conda/envs` folders were links to the environments in the owner's own managed storage, and it held a copy of the `micromamba` binary, so no run needed to change that storage. The lines record only the versions that the tools print, which are MAFFT 7.526 and MEGAHIT 1.2.9. A run in the golden environment, once it holds these tools, gives the same shapes.

| Folder | Command | Fixture |
| --- | --- | --- |
| `align-mafft` | `align mafft /work/inputs/sars-cov-2-genomes.fasta --project /work/Project.lungfish --threads 1 --format json` | `Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Inputs/sars-cov-2-genomes.fasta` |
| `tree-infer-iqtree` | `tree infer iqtree <bundle from import msa> --project /work/Project.lungfish --output /work/Project.lungfish/known-sarcopterygian.lungfishtree --model JC --seed 12345 --threads 1 --format json` | `Tests/Fixtures/phylogenetics/known-sarcopterygian/alignment.fasta` |
| `assemble` | `assemble /work/inputs/test_1.fastq.gz /work/inputs/test_2.fastq.gz --paired --assembler megahit --read-type illumina-short-reads --output /work/assembly --name sarscov2-test --threads 1 --json-events` | `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz` |
| `variants-call` | `variants call --bundle <reference bundle> --alignment-track <track id> --caller lofreq --name "Sample LoFreq" --format json` | `Tests/Fixtures/sarscov2/genome.fasta` and `test.paired_end.sorted.bam`, imported with `import fasta` and `import bam`, which took the bundle as its output folder so the alignment joined its manifest |
| `bam-primer-trim` | `bam primer-trim --bundle <reference bundle> --alignment-track <track id> --scheme /work/inputs/mt192765-integration.lungfishprimers --name "Primer-trimmed Sample" --format json` | the same bundle and `Tests/Fixtures/primerschemes/mt192765-integration.lungfishprimers` |

Four of the five print their events on standard output. `assemble` prints them on standard error, where its transcript was read, and keeps its human report on standard output. In every run the other stream held no event line. All five write through the shared emitter, which sorts the keys of each line, and a reader never depends on their order.

These five files are not captured again by a test. A lane that changes one of these emitters runs the command again and replaces the file.

Lane A9 of Phase 2.7 ran `esviritu-detect` the same way with the CLI built from its branch, in the locked golden storage, with `LUNGFISH_STORAGE_ROOT` at `/Users/Shared/lungfish-golden/storage` and the EsViritu database of that storage read in place. A listing of the database folder taken before and after the runs was the same. The command lines and the paths the lines name are rewritten to `/work`, and the database path stands as `<database>` below.

| File | Command |
| --- | --- |
| `complete` | `esviritu detect --input /work/inputs/test_1.fastq.gz --sample sarscov2 --db <database> --project /work/Project.lungfish --threads 2 --format json` |
| `complete-batch` | `esviritu detect --input /work/inputs/test_1.fastq.gz /work/inputs/test_2.fastq.gz --batch --db <database> --project /work/Project.lungfish --threads 2 --format json`, which groups the two files into the one paired sample `test` |
| `failed` | `esviritu detect --input /work/inputs/test_1.fastq.gz --sample sarscov2 --db /work/missing-db --project /work/Project.lungfish --threads 2 --format json`, which the plan refuses before any folder exists |

The inputs are `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz`.

Lane A8 of Phase 2.7 ran `kraken2-classify` and `conda-classify` the same way with the CLI built from its branch. `LUNGFISH_STORAGE_ROOT` named the stable storage at `~/.lungfish-stable`, whose `kraken2` and `bracken` environments ran, and its `Viral` database was read in place. A listing of the database folder and of the database registry taken before and after the runs was the same. The command lines and the paths the lines name are rewritten to `/work`. The files are in `kraken2-classify` unless the table names the folder.

| File | Command |
| --- | --- |
| `complete` | `kraken2 classify /work/inputs/test_1.fastq.gz --output-dir /work/out/kraken2-test --db Viral --threads 2 --format json`, a plain folder outside a project |
| `complete-project` | `kraken2 classify /work/inputs/test_1.fastq.gz --project /work/Project.lungfish --db Viral --threads 2 --format json`, which also builds `kraken2.sqlite` in the new folder |
| `complete-batch` | `kraken2 classify /work/inputs/test_1.fastq.gz /work/inputs/test_2.fastq.gz --batch --project /work/Project.lungfish --db Viral --threads 2 --format json`, which groups the two files into the one paired sample `test` |
| `complete-profile` | `kraken2 classify /work/inputs/test_1.fastq.gz --profile --project /work/Project.lungfish --db Viral --threads 2 --format json`, whose artifacts include the Bracken profile |
| `complete-with-warning` | `kraken2 classify /work/inputs/negative-control.fastq --profile --project /work/Project.lungfish --db Viral --threads 2 --format json`. The Bracken preflight finds no species row, so the profile degrades and the run logs one warning before `complete` (decision E4) |
| `failed` | `kraken2 classify /work/inputs/test_1.fastq.gz --project /work/Project.lungfish --db Missing --threads 2 --format json`, which the plan refuses before any folder exists |
| `failed-cancelled` | `kraken2 classify /work/inputs/large.fastq --project /work/Project.lungfish --db Viral --threads 2 --format json`. Half a second after the `Running kraken2...` line the CLI and its descendants got SIGTERM, as the app's transport sends it. The CLI exited 125 within a second, and no kraken2 process outlived it |
| `conda-classify/complete` | `conda classify /work/inputs/test_1.fastq.gz --output-dir /work/out/conda-classify-test --db Viral --threads 2 --format json`, the same command under its older spelling |

The inputs are `test_1.fastq.gz` and `test_2.fastq.gz` of `Tests/Fixtures/sarscov2`, `Tests/Fixtures/classifier-parity/negative-control.fastq`, and `large.fastq`, which holds the reads of `test_1.fastq.gz` 10,000 times over, one million reads in all.

## results

`results` holds the document that a leaf prints when the contract table marks it `.result`, one file for each of 13 schemas. Each file is the standard output of one real run of the built `lungfish-cli` on a repository fixture, run the way the commands above were. The scratch folder is `/work` in the file, and nothing else is edited. `CLIEventContractCoverageTests` decodes each file with the Swift type that reads it, adds one key that no reader knows, and expects the same value back.

Some leaves print text before their document. `convert` prints status lines unless `--quiet` is given, and `translate` and `extract sequence` print the sequences to standard output unless an output file is named. The runs used `--quiet` and an output file, so that standard output holds the document alone.

| File | Command |
| --- | --- |
| `analyze-stats`, `analyze-composition`, `analyze-validate` | `analyze stats`, `analyze composition` and `analyze validate` on `small.fasta`, with `--format json` |
| `convert` | `convert /work/inputs/small.fasta --to /work/out/small-copy.fasta --format json --quiet` |
| `translate` | `translate /work/inputs/small.fasta --frame 1 -o /work/out/protein.fasta --format json --quiet` |
| `search` | `search /work/inputs/small.fasta <twelve bases of the sequence> --format json` |
| `extract-sequence` | `extract sequence /work/inputs/small.fasta MT192765.1:1-60 -o /work/out/region.fasta --format json --quiet` |
| `bundle-info`, `bundle-validate`, `bundle-list` | `bundle info`, `bundle validate` and `bundle list` of the reference bundle that `import fasta` made from `Tests/Fixtures/sarscov2/genome.fasta`, with `--format json` |
| `msa-actions`, `msa-describe` | `msa actions --format json` and `msa describe msa.inspection.discriminating-sites --format json` |
| `r5-map-report` | `map test_1.fastq.gz test_2.fastq.gz --paired --reference genome.fasta --mapper minimap2 --preset sr --sample-name sarscov2-test --threads 1 --format json --output-dir /work/out` on the files in `Tests/Fixtures/sarscov2` |

`small.fasta` is the first record of `Tests/Fixtures/sarscov2/genome.fasta`, cut after five lines of sequence.

The other `.result` schemas have no file here. The test names each one with its reason. For some, no Swift type decodes the document, because the command builds it as a dictionary or its type is private or only encodes. For others, a real run needs the network, or inputs that the suite does not build, such as a result bundle or a model, or writes the user, the machine or a storage path into the document. The test also names the three schemas that the app decodes, which are `r1-ont-barcode-genotyping`, `r5-genotype-cohort-report` and `r2-full-length-ont-mhc`, with the decoder and the test that covers each today.

## Shapes no run produced

No command writes an `output` event today, and none sets `detail` on a `failed` event. The compatibility tests cover those shapes with lines written in the test file, and they say so there.

# CLI event fixtures

These folders hold transcripts of the event lines that `lungfish-cli` prints when a command runs with events on. `CLIEventCompatibilityTests` decodes every file in `v1`, `CLIPrimerTrimRunnerTests` reads the file in `v2`, and `CLIEventContractCoverageTests` decodes every file under `commands`. The wire format is written down in `docs/formats/cli-events.md`.

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

## commands

The contract table `CLIEventContractTable` names 21 leaf commands that emit events. Each has a folder here, named by its path with hyphens, such as `msa-annotate-add`. A file in it is one run that ends one way. `complete` ends in a `complete` line, `complete-with-warning` is such a run that also logs a warning, and `failed` ends in a `failed` line. Every line is a version 2 line, and every line is captured output.

`CLIEventContractCoverageTests` decodes each line with the current reader and with the frozen version 1 reader and expects the same events from both. It also checks that each run starts with `start`, ends with one terminal event, holds no line a reader skips as chatter, and carries no text that a system message wrote.

### Captured in process

Sixteen leaves need no external tool, so they ran in process on a small fixture, as the version 1 captures did. A command with a test seam handed its lines to a capturing sink. `fastq platform` has none, so its standard output was redirected for the length of the run. The scratch folder is rewritten to `/work` in its plain and slash-escaped spellings, and nothing else is edited.

`CLIEventTranscriptCaptureTests` runs the same 20 captures again and fails when a line differs from its file. After a deliberate change to an emitter, run that suite with `LUNGFISH_RECAPTURE_CLI_EVENTS=1`, which writes the files instead of comparing them, and review the diff.

A failed run is kept only when Lungfish wrote its message. A Foundation message changes with the system language and the macOS release, so `msa export` and `fastq platform` have no failed run.

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
| `fastq-platform` | `complete` | `fastq platform --set ont` on a bundle recorded as Illumina |

### Captured from the built CLI

Five leaves run an external tool that a unit test cannot start, so each was run once as the `lungfish-cli` built from the program branch with lane C3 landed, and its event lines were kept as they came. Each folder holds one `complete` file. The command lines name the scratch folder `/work`, which the lines rewrite the same way.

The run followed `scripts/golden/captures.py`. The current folder was a scratch folder, `PATH` was the bare system path, and `LUNGFISH_CONDA_SHARED_PKGS=0` kept the shared package cache out. One difference needs saying. The locked golden storage at `/Users/Shared/lungfish-golden/storage` holds eight conda environments, and none is MAFFT, IQ-TREE, an assembler, LoFreq or iVar. `LUNGFISH_STORAGE_ROOT` named a scratch storage root instead. Its `conda/envs` folders were links to the environments in the owner's own managed storage, and it held a copy of the `micromamba` binary, so no run needed to change that storage. The lines record only the versions that the tools print, which are MAFFT 7.526 and MEGAHIT 1.2.9. A run in the golden environment, once it holds these tools, gives the same shapes.

| Folder | Command | Fixture |
| --- | --- | --- |
| `align-mafft` | `align mafft /work/inputs/sars-cov-2-genomes.fasta --project /work/Project.lungfish --threads 1 --format json` | `Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Inputs/sars-cov-2-genomes.fasta` |
| `tree-infer-iqtree` | `tree infer iqtree <bundle from import msa> --project /work/Project.lungfish --output /work/Project.lungfish/known-sarcopterygian.lungfishtree --model JC --seed 12345 --threads 1 --format json` | `Tests/Fixtures/phylogenetics/known-sarcopterygian/alignment.fasta` |
| `assemble` | `assemble /work/inputs/test_1.fastq.gz /work/inputs/test_2.fastq.gz --paired --assembler megahit --read-type illumina-short-reads --output /work/assembly --name sarscov2-test --threads 1 --json-events` | `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz` |
| `variants-call` | `variants call --bundle <reference bundle> --alignment-track <track id> --caller lofreq --name "Sample LoFreq" --format json` | `Tests/Fixtures/sarscov2/genome.fasta` and `test.paired_end.sorted.bam`, imported with `import fasta` and `import bam` |
| `bam-primer-trim` | `bam primer-trim --bundle <reference bundle> --alignment-track <track id> --scheme /work/inputs/mt192765-integration.lungfishprimers --name "Primer-trimmed Sample" --format json` | the same bundle and `Tests/Fixtures/primerschemes/mt192765-integration.lungfishprimers` |

Four of the five print their events on standard output. `assemble` prints them on standard error, where its transcript was read, and keeps its human report on standard output. In every run the other stream held no event line. `variants call` encodes its events itself, so the order of the keys inside a line is not fixed, and a reader never depends on it.

These five files are not captured again by a test. A lane that changes one of these emitters runs the command again and replaces the file.

## Shapes no run produced

No command writes an `output` event today, and none sets `detail` on a `failed` event. The compatibility tests cover those shapes with lines written in the test file, and they say so there.

# CLI event fixtures

These folders hold transcripts of the event lines that `lungfish-cli` prints when a command runs with events on. `CLIEventCompatibilityTests` decodes every file in `v1`, and `CLIPrimerTrimRunnerTests` reads the file in `v2`. The wire format is written down in `docs/formats/cli-events.md`.

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

## Commands that are not captured

Five of the 21 leaf commands that emit `CLIEvent` need an external tool, so they were skipped. They get real transcripts in the golden environment when the contract coverage lane adds the per-command table.

| Command | Why it is skipped |
| --- | --- |
| `tree infer iqtree` | Runs IQ-TREE |
| `align mafft` | Runs MAFFT |
| `assemble` | Runs a managed assembler, and writes its events to standard error |
| `bam primer-trim` | Runs iVar on a bundle alignment. A version 2 run is in `v2`. |
| `variants call` | Runs LoFreq, iVar or Medaka |

## Shapes no run produced

No command writes an `output` event today, and none sets `detail` on a `failed` event. The compatibility tests cover those shapes with lines written in the test file, and they say so there.

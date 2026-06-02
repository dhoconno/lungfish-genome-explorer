# Appendices Round 2 verification (2026-06-02)

Round 2 of the iterative simulated-reader review of the LGE user manual,
appendices section. This pass verifies that the Round 1 corrections actually
landed in the revised chapters AND are themselves correct against the live
binary. The chapters were NOT edited in this pass.

Verification baseline: binary `.build/debug/lungfish-cli`, self-reports
`0.5.0-alpha11` (the same build Round 1 used). Every signature below was
re-derived by running `lungfish-cli <command> --help` and, for a few claims,
by actually invoking the documented command to observe the parse error.
Keyboard shortcuts were verified against `Sources/LungfishApp/App/MainMenu.swift`.
The shipped primer manifest was read from
`Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/manifest.json`.
Tool versions were verified against live `lungfish-cli version --tools`.

Headline: Round 1 LANDED almost completely and is accurate. The command index
is now complete and correct (all 43 top-level commands, no phantom rows). The 8
renames, the 8 flag-signature fixes, the 14 added commands, the tool-versions
table, the Cmd-Ctrl-S sidebar fix, and the primer-scheme snake_case + 563/223
counts are all verified against the binary. TWO genuine signature errors remain
in `cli-reference.md`, both in the `extract` family, and ONE nonexistent flag
(`--seed`) remains in `power-user-notes.md`. These three are the only must-fixes.

---

## PART 1: Verification table

Legend: LANDED = correction is present and matches the binary. STILL-WRONG = a
documented command/flag the binary rejects. PARTIAL = landed but with a residual
inaccuracy. All line numbers are in the CURRENT (revised) chapters.

### A. The 8 renames (R1 "nonexistent / misnamed commands")

| # | R1 wrong form | Now documented as | Status | Binary evidence |
|---|---|---|---|---|
| 1 | `classify --tool kraken2 ... --reads` | `conda classify <fastq...> --db <name>` (cli-reference.md:277) | LANDED | `USAGE: lungfish conda classify [<options>] <fastq-files> ... --db <db>`; presets `sensitive, balanced, precise`; `-o/--output-dir`. Matches. |
| 2 | `esviritu run --reads` | `esviritu detect -i <fastq...> -s <sample>` (cli-reference.md:286) | LANDED | `USAGE: lungfish esviritu detect [<options>] --sample <sample>`; `-i/--input`, `-s/--sample`, `--paired`, `--no-qc`, `--db`, `--min-read-length`. Chapter says "There is no `esviritu run`." Correct. |
| 3 | `nao-mgs import --run-dir` | `nao-mgs summary <input-path>` + `nao-mgs import <input-path> [-o] [--sample-name] [--sam]` (cli-reference.md:294-296) | LANDED | `nao-mgs summary` and `nao-mgs import [<options>] <input-path>` both exist; no `--run-dir`. Matches. |
| 4 | `blast <sequence> [--database nt]` | `blast verify --kreport --kraken-output --source --taxid [--reads]` (cli-reference.md:298) | LANDED | `USAGE: lungfish blast verify [<options>] --kreport <kreport> --source <source> --kraken-output <kraken-output> --taxid <taxid>`; `--reads` default 20. Chapter says "not a free-form `blast <sequence>` and does not take `--database`." Correct. |
| 5 | `extract-contigs --assembly` (top-level) | `extract contigs ...` (cli-reference.md:328) | LANDED as a subcommand, but the SIGNATURE is STILL-WRONG (see must-fix M1) | `extract contigs` is a real subcommand of `extract`. Confirmed. The argument shape is wrong though. |
| 6 | `extract-annotations --bundle` (top-level) | `bundle extract-annotations <bundle> [--output]` (cli-reference.md:199) | LANDED | `bundle extract-annotations` exists under `bundle` (default-subcommand group). Confirmed. |
| 7 | `bam annotations` (plural) | `bam annotate --bundle --alignment-track --output-track-name` (cli-reference.md:227) | LANDED | `USAGE: lungfish bam annotate [<options>] --bundle <bundle> --alignment-track <alignment-track> --output-track-name <output-track-name>`. Singular, matches. |
| 8 | `import application <path>` | `import application-export <kind> <source-path> --project` (cli-reference.md:160) | LANDED | `USAGE: lungfish import application-export [<options>] <kind> <source-path> --project <project>`. Two positionals, matches. |
| 8b | `msa add` / `msa edit` (top-level) | `msa` subcommands `actions/describe/annotate/export/consensus/extract/mask/trim/distance`; add/edit under `msa annotate` (cli-reference.md:553-555) | LANDED | `msa` SUBCOMMANDS are exactly those 9. Chapter says "Annotation editing lives one level deeper: `msa annotate add`, `msa annotate edit`, ...". Correct. |

### B. The 8 flag-signature fixes

| # | R1 wrong flags | Now documented as | Status | Binary evidence |
|---|---|---|---|---|
| 1 | `convert --in --out` | `convert <input> --to <path> [--to-format]` (cli-reference.md:545) | LANDED | `USAGE: lungfish convert [<options>] <input> --to <to>`; `--to-format` default `fasta`; values `fasta, genbank, gff3, fastq`. No `--in`/`--out`. Matches. |
| 2 | `markdup --in --out` | `markdup <path> [--force] [--sort-threads] [--deduplicated-bundle]` (cli-reference.md:231) | LANDED | `USAGE: lungfish markdup [<options>] <path>`; `--force`, `--sort-threads` (default 4), `--deduplicated-bundle`. Single positional. Matches. The same fix is reflected in troubleshooting.md and power-user-notes.md (no `--in`/`--out` remains anywhere; grep clean). |
| 3 | `import vcf [--reference]` | `import vcf <input-file> [--output-dir]` (cli-reference.md:156) | LANDED | `USAGE: lungfish import vcf <input-file> [--output-dir <output-dir>]`; `-o/--output-dir`. No `--reference`. Chapter says "There is no `--reference` flag." Correct. |
| 4 | `taxtriage run --reads [--profile clinical]` | `taxtriage run {--input [--input2] --sample \| --samplesheet} --output [--platform] [--db] [--confidence]` (cli-reference.md:290) | LANDED | `USAGE: lungfish taxtriage run [<options>] --output <output>`; flags `--input`, `--input2`, `--sample`, `--samplesheet`, `--platform` (illumina/oxford/pacbio, default illumina), `--db`, `--confidence` (default 0.2). No `--reads`, no `--profile`. Chapter says so. Correct. |
| 5 | `blast <sequence> [--database nt]` | `blast verify ...` (cli-reference.md:298) | LANDED | See A#4. |
| 6 | `conda install --pack <name>...` (value syntax) | `conda install --pack <packages...>` with `--pack` as a boolean toggle (cli-reference.md:399-401) | LANDED | `USAGE: lungfish conda install [<options>] [<packages> ...]`; `--pack  Install a plugin pack instead of individual packages` (boolean flag, no value). Chapter says "`--pack` is a boolean mode toggle; the pack names are positional." Correct. |
| 7 | `bam adopt-mapping` missing `--name` (troubleshooting.md) | `bam adopt-mapping --bundle --mapping-result --name [--track-id]` (cli-reference.md:219; troubleshooting.md:78) | LANDED | `USAGE: lungfish bam adopt-mapping [<options>] --bundle <bundle> --mapping-result <mapping-result> --name <name>`. troubleshooting.md:78 now reads "`--name <track-name>`. The `--name` option is required." Correct. |
| 8 | (markdup recurrence) | covered by B#2 | LANDED | grep for `--in`/`--out` across all nine chapters returns nothing. |

### C. The 14 added top-level commands

All 14 now appear in the command index AND have a body entry. Each verified to exist with the documented subcommand count.

| Command | In index? | Body entry | Subcommand count claim | Binary evidence |
|---|---|---|---|---|
| `analyze` | yes (40) | `analyze stats` (428) | "composition, file-validate; stats is default" | `USAGE: lungfish analyze stats [<options>] <input>` (stats is default). Confirmed. |
| `translate` | yes (75) | line 432 | frames 1-6, `--table` default 1 | `-f/--frame` "1-3 forward, 4-6 reverse, default all 6"; `--table`. Matches. |
| `sequence` | yes (73) | line 436 | annotate-orfs + delete-annotations + delete-annotation-track | `sequence` SUBCOMMANDS = exactly those 3. Confirmed. |
| `universal-search` | yes (77) | line 440 | `<project-path>` | `USAGE: lungfish universal-search [<options>] <project-path>`. Confirmed. |
| `align` | yes (38) | `align mafft` (450) | `--strategy auto/linsi/ginsi/einsi/fftns2/parttree` | `USAGE: lungfish align mafft [<options>] <input-files> ... --project <project>`; `--strategy` values match exactly. Confirmed. |
| `orient` | yes (66) | line 354 | top-level, same as `fastq orient` | `USAGE: lungfish orient [<options>] <fastq-file> --reference <reference>`. Confirmed. |
| `gatk` | yes (54) | line 456 | 10 subcommands | `gatk` SUBCOMMANDS = `haplotype-caller, joint-genotype, filter, select, variants-to-table, bqsr, markdup, validate-sam, leftalign, collect-metrics` (exactly 10). Chapter lists all 10 in the same order. Confirmed. |
| `freyja` | yes (53) | `freyja demix` (462) | demix only | `freyja` SUBCOMMANDS = `demix`; `freyja demix --variants --depths --output-dir [--execute] [--sample]`. Confirmed. |
| `nvd` | yes (64) | line 470 | summary (default) + import | `nvd summary <input-path>` and `nvd import [<options>] <input-path>`. Confirmed. |
| `cz-id` | yes (47) | line 474 | summary (default) + import | `cz-id summary <input-path>` and `cz-id import <input-path> [--output-dir]`. Confirmed. |
| `metadata` | yes (61) | line 480 | get/set/import/export/export-biosample | `metadata get/set/export-biosample` confirmed present (default group); chapter's 5-subcommand list is consistent. Confirmed. |
| `haplotypes` | yes (56) | line 490 | 10 subcommands (list/validate/import/save/export/duplicate/delete + 3 bundle) | `haplotypes` SUBCOMMANDS = `list, validate, import, save, bundle-create, bundle-save, bundle-replace-reference, export, duplicate, delete` (exactly 10). Confirmed. |
| `build-db` | yes (43) | line 494 | taxtriage/esviritu/kraken2 | `build-db` SUBCOMMANDS = `taxtriage, esviritu, kraken2`; `build-db taxtriage <result-dir> [--force]`. Confirmed. |
| `genotype` | yes (55) | line 498 | 7 subcommands | `genotype` SUBCOMMANDS = `list-samples, list-cohorts, apply-annotations, export, export-xlsx, export-pivot-xlsx, export-labkey` (exactly 7). Chapter lists all 7. Confirmed. |

### D. Command index completeness (the 43-row table)

LANDED and CORRECT. The chapter's "Command index" (cli-reference.md:36-80) has
exactly 43 rows. `lungfish-cli --help` lists exactly 43 SUBCOMMANDS. Set-equal
check, name by name:

`align, analyze, assemble, bam, blast, build-db, bundle, conda, convert, cz-id,
debug, esviritu, extract, fastq, fetch, freyja, gatk, genotype, haplotypes,
import, import-fastq, map, markdup, metadata, msa, nao-mgs, nvd, ops, orient,
primers, project, provenance, provision-tools, run-headless, search, sequence,
taxtriage, translate, tree, universal-search, variants, version, workflow`.

- No real command is missing from the index.
- No listed command is nonexistent. Note: `provision-tools` (R1 flagged it as
  "not documented anywhere") is now both in the index (row 70) and given a body
  line; `lungfish provision-tools` is a real top-level command. LANDED.
- The chapter is honest about subcommand families R1 called out: `fetch ena` is
  named (cli-reference.md:123, real: `fetch ena search ...`), the `bundle` group
  is described as including `info/validate/deduplicate-alignments` beyond
  create/list/export (cli-reference.md:201, all real), and the `markdup` /
  `bam markdup` duplication is explained (cli-reference.md:233, both real).

### E. file-formats.md (2 invented removed, 4 real added)

| Item | Status | Evidence |
|---|---|---|
| `.lungfishvcf` invented bundle removed | LANDED | No `.lungfishvcf` row in the bundle table (file-formats.md:125-136); chapter now states "Variants do not have a standalone bundle format. They live inside the reference bundle's `variants/` subdirectory" (262). The old `bcftools view variants.lungfishvcf/...` example is gone; the inspection block uses `ref.lungfishref/variants/...` (337). |
| `.lungfishtax` rescoped to CZ-ID only | LANDED | Table row now reads "CZ-ID taxonomy ... A CZ-ID taxon report normalized" (136); dedicated section says "produced only by the CZ-ID import path ... not the storage format for Kraken2, EsViritu, TaxTriage, or NAO-MGS results" (228-230). |
| `.lungfishfastq` added | LANDED | Table row (129) + section (210-214). |
| `.lungfish12sref` added | LANDED | Table row (133) + section (216-218); "Produced by `lungfish fastq 12s-reference-bundle`." |
| `.lungfishmhcref` added | LANDED | Table row (134) + section (220-222). |
| `.lungfishhaplotypedef` added | LANDED | Table row (135) + section (224-226). |
| `.lungfishflow` noted | LANDED | Described at file-formats.md:264 as a workflow definition referenced by `workflow diff`. |
| provenance example version reconciled to alpha11 | LANDED | file-formats.md:289 now `"version": "0.5.0-alpha11"`. |

The verified real LungfishIO bundle set is exactly the 8 the table now lists
(`.lungfishref, .lungfishfastq, .lungfishmsa, .lungfishtree, .lungfishprimers,
.lungfish12sref, .lungfishmhcref, .lungfishhaplotypedef`), with `.lungfishtax`
correctly scoped as a CZ-ID import artifact. No phantom formats remain.

### F. tool-versions.md (table == `version --tools`)

LANDED and CORRECT. Live `version --tools` prints exactly 17 rows: micromamba
(bundled) + 16 managed. The chapter's Bundled table (1 row: micromamba 2.0.5-0)
plus Managed table (16 rows) reproduce them exactly, version for version.

| Check | Status | Evidence |
|---|---|---|
| Clair3 / WhatsHap / Freyja removed from the managed table | LANDED | Not in the managed table; moved to a prose note (tool-versions.md:66) "not in the bundled managed-tool lock and do not appear in `lungfish version --tools` ... provided by separate plugin packs." `version --tools` does not print them. Correct. |
| openpyxl 3.1.5 added | LANDED | tool-versions.md:64; live table prints `openpyxl 3.1.5 ... openpyxl ... python`. Matches. |
| pysam 0.24.0 added | LANDED | tool-versions.md:63; live table prints `pysam 0.24.0 ... pysam ... python`. Matches. |
| Casing (Fastp, BCFtools) | LANDED | Chapter uses "Fastp" (52) and "BCFtools" (55), matching the live table's casing. |
| License column provenance | LANDED (honest) | Chapter now explains (33) the License and Source URL "come from the managed-tool lock file's per-tool metadata, which the command reads but does not print," resolving the R1 "implies it comes from the command" problem. |

All 16 managed versions verified against the live table: Nextflow 25.10.4,
Snakemake 9.19.0, BBTools 39.80, Fastp 1.3.2, Deacon 0.15.0, Samtools 1.23.1,
BCFtools 1.23.1, HTSlib 1.23.1, SeqKit 2.13.0, Cutadapt 5.2, VSEARCH 2.30.5,
pigz 2.8, SRA Tools 3.4.1, UCSC bedGraphToBigWig 482, pysam 0.24.0, openpyxl
3.1.5. Exact match.

### G. keyboard-shortcuts.md

| Check | Status | Evidence (MainMenu.swift) |
|---|---|---|
| Sidebar = Cmd-Ctrl-S (was Cmd-Shift-S) | LANDED | Line 425 comment "Control-Command-S per macOS standard"; 431 `keyEquivalent: "s"`; 433 `[.command, .control]`. Chapter:46 "Cmd-Ctrl-S" and the "Memorizing chords" para:129 now says "The Sidebar is the exception: it toggles with `Cmd-Ctrl-S`, using Control rather than Shift." Correct. |
| Find Previous has no chord; Cmd-Shift-G is Go to Gene only | LANDED | Line 403 comment "no shortcut -- Cmd-Shift-G is used by Go to Gene"; 407 `keyEquivalent: ""`. Find Next = `Cmd-G` (400 `keyEquivalent: "g"`). Chapter:113 states exactly this. Correct. |
| Added View shortcuts (Focus Viewer, Restore Side Panes, Zoom In/Out/Fit) | LANDED | Focus Viewer `Cmd-Opt-F` (447-451), Restore Side Panes (455), Zoom In `+` (484), Zoom Out `-` (490), Zoom to Fit `0` (496). Chapter:57-61. Correct. |
| Show as RNA = Cmd-Shift-U | LANDED | Line 530 `keyEquivalent: "u"` + `[.command, .shift]`. Chapter:63. Correct. |
| Taxonomy Expand/Collapse = Cmd-Shift-Right/Left Arrow | LANDED | 513-524, both `[.command, .shift]` with Right/Left arrow keys. Chapter:63. Correct. |

### H. primer-schemes.md

LANDED and CORRECT against the shipped manifest.

| Check | Status | Evidence (shipped manifest.json) |
|---|---|---|
| snake_case manifest keys | LANDED | Manifest keys: `schema_version, name, display_name, description, organism, reference_accessions, primer_count, amplicon_count, source, source_url, version, created`. Chapter field table (50-61) lists exactly these, all snake_case. The invented `imported`/`attachments`/camelCase keys are gone. |
| `reference_accessions` object shape | LANDED | Manifest: `[{"accession":"MN908947.3","canonical":true},{"accession":"NC_045512.2","equivalent":true}]`. Chapter:66-69 shows this exact JSON. Correct. |
| Real counts 563 / 223 | LANDED | Manifest `primer_count: 563`, `amplicon_count: 223`. Chapter:28 "It declares `primer_count` 563 and `amplicon_count` 223." Correct. |
| display_name + source | LANDED | Manifest `display_name: "QIAseq Direct SARS-CoV-2 with Booster A"`, `source: "built-in"`. Chapter:28 states both. Correct. |
| canonical / equivalent accessions | LANDED | Manifest canonical MN908947.3, equivalent NC_045512.2. Chapter:28, 67-68. Correct. |
| CLI flag set | LANDED (unchanged, still correct) | `primers import --bed [--fasta] --output [--project] [--reference-accession] [--display-name] [--equivalent-accession ...] [--attachment ...]`. Chapter:90-100 matches. |

### I. 06-running-in-ci.md, shared-projects.md, power-user-notes.md, troubleshooting.md

| Chapter | Status | Evidence |
|---|---|---|
| 06-running-in-ci.md | LANDED, no command errors | `conda offline-export --pack <pack> --output <output> [--conda-root]` and `conda offline-install <pack-directory> [--conda-root] [--overwrite]` confirmed verbatim. `run-headless <workflow>` confirmed. (Quoted lock/read-only error strings still not source-traced; see should-fix S5.) |
| shared-projects.md | LANDED | `project lock/unlock/migrate` confirmed; `--mode`, `--force`, `--dry-run`, `--format json` all real. Lock-record example version reconciled to `lungfish-cli 0.5.0-alpha11` (44). Source-build name `lungfish-cli` correctly noted (30). |
| power-user-notes.md | LANDED except one nonexistent flag (must-fix M3) | Version reconciled to alpha11 (24, 133). `ops stats`, `conda lock`/`--from-lockfile`, `bundle export --format container` all confirmed. The `--seed` reference (284) is STILL-WRONG: `fastq subsample` has no `--seed` flag. |
| troubleshooting.md | LANDED | `bam adopt-mapping ... --name` fixed (78); `fetch ncbi --no-retry` real; `conda install --pack read-mapping variant-calling` uses `--pack` correctly as a mode toggle (40). |

---

## PART 2: Two persona re-reads

### Persona 1: Tomás Reyes, pipeline engineer copy-pasting CLI commands

Tomás reopens `cli-reference.md` for the Snakemake rules that failed him in
Round 1. This time he works top to bottom and pastes each command into
`lungfish <cmd> --help` and, where he can, a dry invocation.

**The Classification section is fixed.** "The graveyard is gone. `lungfish conda
classify SRR..._1.fastq.gz SRR..._2.fastq.gz --db Viral --paired --preset
balanced -o classification/` (cli-reference.md:282) is exactly what
`--help` shows: `USAGE: lungfish conda classify [<options>] <fastq-files> ...
--db <db>`. `esviritu detect -i <fastq> -s <sample>` (286) matches. `taxtriage
run` with `--input/--input2/--sample` (290) matches, and the chapter explicitly
kills the dead flags: 'There is no `--reads` or `--profile` flag.' `blast verify`
with the four required flags (298) matches. Every command I tried to paste
in Round 1 now parses."

**The command index is the win.** "cli-reference.md:36-80 is a flat 43-row table
and it is exactly `--help`'s SUBCOMMANDS, name for name. When something fails now
I can tell instantly whether a command exists. `gatk` lists all ten subcommands
(456), `genotype` all seven (498), `haplotypes` all ten (490), and I checked each
against `--help`: they match. This is the reference I wanted."

**Two commands still break, both in `extract`.** "I hit a wall on read and contig
extraction.

1. `lungfish extract reads --bundle <taxonomy-bundle> --taxon <id> --output
   <path>` (cli-reference.md:302). I pasted it with a real taxon and it failed:
   `Error: Validation failed: Exactly one of --by-id, --by-region, --by-db, or
   --by-classifier must be specified`. And `--bundle` in this command is not a
   value option that takes my taxonomy-bundle path, it is a boolean flag that
   means 'Wrap output in a .lungfishfastq bundle' (`--bundle  Wrap output in a
   .lungfishfastq bundle`). So the documented line is wrong twice: there is no
   `--bundle <path>`, and you must pick a `--by-*` mode. To extract taxon reads
   from a classifier result the real shape is `extract reads --by-classifier
   --tool kraken2 --result <dir> --taxon <id> -o <path>`.

2. `lungfish extract contigs <assembly> --contig <id> [--contig <id>...]
   --output <path>` (cli-reference.md:328). I pasted `lungfish extract contigs
   my-assembly/ --contig NODE_1` and got `Error: Specify exactly one of
   --assembly or --contigs`. There is no positional `<assembly>`; the input is a
   flag, `--assembly <dir>` (a managed assembly output) or `--contigs <fasta>`,
   and output is `-o/--output`. The correct line is `lungfish extract contigs
   --assembly <dir> --contig <id> -o <path>`.

These are the only two in the whole chapter, but they are real copy-paste
failures, so I still cannot tell my team 'paste anything from the reference.' I
can tell them 'paste anything except the two `extract` data-extraction lines.'"

**Everything else I spot-checked held.** "`convert <input> --to <path>` (545),
`markdup <path>` (231), `import vcf <input-file>` (156), `bam adopt-mapping ...
--name` (219), `conda install --pack <packages...>` (399), `align mafft ...
--strategy` (450), `orient <input> --reference` (354), `fetch ena` (123). All
match `--help`. Net: the chapter went from 'trust nothing' to 'two known-bad
lines,' which is a huge step, but those two are still must-fix because they are
data-extraction commands a metagenomics user reaches for constantly."

### Persona 2: Dr. Hannah Brandt, clinical validation lead checking versions and primer schemes

Hannah re-validates `tool-versions.md` and `primer-schemes.md` against the binary
and the shipped manifest, because the Round 1 versions failed her audit at the
exact rows she depends on.

**`tool-versions.md` now matches `version --tools` exactly.** "I ran `lungfish
version --tools` and diffed it against the chapter row by row. Seventeen rows in
the command, seventeen in the chapter (one bundled, sixteen managed), and every
version string agrees: Nextflow 25.10.4, Snakemake 9.19.0, BBTools 39.80, Fastp
1.3.2, Deacon 0.15.0, Samtools 1.23.1, BCFtools 1.23.1, HTSlib 1.23.1, SeqKit
2.13.0, Cutadapt 5.2, VSEARCH 2.30.5, pigz 2.8, SRA Tools 3.4.1, UCSC
bedGraphToBigWig 482, pysam 0.24.0, openpyxl 3.1.5. The three tools I could NOT
let into a validation appendix in Round 1, Clair3, WhatsHap, and Freyja, are out
of the managed table and moved to a clearly labeled note that says they ship via
plugin packs and do not appear in `version --tools` (66). pysam and openpyxl,
which the command prints, are now in. The casing matches the live table (Fastp,
BCFtools). And the chapter is now honest about the License column: it tells me
those values come from the lock file's per-tool metadata, not from the command
(33). That is a column I can keep, because the doc no longer claims it came from
a command that does not emit it. This table is now safe to paste into a
validation appendix."

**`primer-schemes.md` matches the shipped manifest exactly.** "I opened the
shipped `QIASeqDIRECT-SARS2.lungfishprimers/manifest.json` and checked it against
the chapter. Every key I cite is now correct snake_case: `display_name`,
`reference_accessions`, `primer_count`, `amplicon_count`, `source`, `source_url`,
`version`, `created`, plus `schema_version`, `description`, `organism`. The
invented `imported` and `attachments` keys are gone. The `reference_accessions`
object shape is shown exactly as the file stores it,
`[{"accession":"MN908947.3","canonical":true},{"accession":"NC_045512.2","equivalent":true}]`
(66-69). And the five anchor numbers I needed and could not find in Round 1 are
now in the very first paragraph (28): primer_count 563, amplicon_count 223,
display_name 'QIAseq Direct SARS-CoV-2 with Booster A', source 'built-in',
canonical MN908947.3 with equivalent NC_045512.2. I confirmed all of them against
the manifest. Both of my validation-anchor chapters now pass."

**One residual in the methods-flags chapter.** "I still pull canonical flags from
`power-user-notes.md` for my methods section. The mpileup and ivar and LoFreq
flag sets read the same as Round 1; those were flagged for a source trace and I
cannot independently confirm them from `--help` (they are internal pipeline
steps, not CLI flags). Separately, the chapter tells me to pass `--seed <int>`
to `lungfish fastq subsample` for a reproducible draw (284), but `fastq subsample
--help` shows no `--seed` flag at all, only `--proportion`, `--count`, `-o`,
`--force`, `--compress`. So that one reproducibility instruction is wrong as
written. For a validation context that matters: I would have documented a seed
flag that does not exist."

---

## Round 2 fixes for editors

Prioritized. Must-fix = a documented command/flag the binary rejects (copy-paste
fails). Should-fix = clarity, completeness, or a claim that needs a source trace.

### Must-fix (a command/flag is still wrong)

**M1. `cli-reference.md:328` - `extract contigs` has no positional `<assembly>`.**
Current: `lungfish extract contigs <assembly> --contig <id> [--contig <id>...]
--output <path>`. Binary: `USAGE: lungfish extract contigs <options>` with NO
positional; input is `--assembly <dir>` (managed assembly output containing
`assembly-result.json`) OR `--contigs <fasta>` (exactly one required), and output
is `-o/--output`. Invoking `lungfish extract contigs my-assembly/ --contig NODE_1`
returns `Error: Specify exactly one of --assembly or --contigs`. Fix to:
`lungfish extract contigs --assembly <dir> --contig <id> [--contig <id>...] -o
<path>` (or `--contigs <fasta>` instead of `--assembly`). Optionally note
`--bundle`/`--bundle-name`/`--project-root` for deriving a `.lungfishref` in
place.

**M2. `cli-reference.md:302` - `extract reads` signature is wrong twice.**
Current: `lungfish extract reads --bundle <taxonomy-bundle> --taxon <id> --output
<path>`. Binary: `extract reads` requires a mode selector and `--bundle` is a
boolean flag, not a value. Invoking the documented line returns `Error:
Validation failed: Exactly one of --by-id, --by-region, --by-db, or
--by-classifier must be specified`, and `--help` shows `--bundle  Wrap output in
a .lungfishfastq bundle` (no value). The real way to extract reads for a taxon
from a classifier result is `lungfish extract reads --by-classifier --tool
kraken2 --result <dir> --taxon <id> -o <path>` (the `--taxon` flag is documented
as "for --by-classifier --tool kraken2"). For NAO-MGS DB extraction it is
`--by-db --database <sqlite> --db-taxid <id> -o <path>`. Rewrite the line to pick
a real mode and drop the `--bundle <taxonomy-bundle>` value form. (Note: R1
ground-truth listed `extract reads --output` as "correct," but the specific
`--bundle <taxonomy-bundle> --taxon` shape the revision settled on does not parse;
this needs correcting.)

**M3. `power-user-notes.md:284` - `fastq subsample --seed` does not exist.**
Current: "For reservoir-sampling subset operations (`lungfish fastq subsample
--count`), pass `--seed <int>` to make the draw reproducible." Binary: `fastq
subsample --help` shows only `--proportion`, `--count`, `-o/--output`, `--force`,
`--compress`. There is no `--seed`. Either remove the sentence or, if
reproducibility is genuinely controlled by `--threads` (as cli-reference.md:338
implies with "the global `--threads` and the count path use deterministic
reservoir sampling"), rewrite to say so without inventing a flag. The two
chapters should also agree: cli-reference.md:338 ties determinism to `--threads`;
power-user-notes.md ties it to a nonexistent `--seed`. Reconcile to whatever the
binary actually honors (no seed flag is exposed on the subcommand).

### Should-fix (clarity / completeness / source trace)

**S1. `cli-reference.md:338` - reword the `fastq subsample` determinism claim.**
The line "For a reproducible draw, the global `--threads` and the count path use
deterministic reservoir sampling" is awkward and, paired with M3, risks implying
a seed exists. State plainly that the count path uses reservoir sampling and that
there is no user-facing seed flag; pin `--threads` for run-to-run stability if
that is what the implementation relies on.

**S2. `cli-reference.md:209` - `map --preset` value list is a subset.** Chapter
names `sr`, `map-ont`, `map-hifi`. Binary (minimap2) accepts `sr, asm5, splice,
map-ont, map-hifi, map-pb` plus bbmap presets `bbmap-standard, bbmap-pacbio`. The
three named are all real and the prose does not claim completeness, so this is
optional, but adding `map-pb` (PacBio CLR) and a "run `map --help` for the full
preset list" pointer would help the short-read-vs-long-read reader.

**S3. `cli-reference.md:514` - `provenance export` format list omits `python`.**
Chapter: `--format shell|nextflow|snakemake|methods|json`. Binary: `shell,
python, nextflow, snakemake, methods, json`. Add `python` (or note it) so the
enumerated set matches `--help`. All listed values are valid; this is a
completeness gap, not an error.

**S4. `keyboard-shortcuts.md` - add `Zoom Reset (10kb) = Cmd-1`.** MainMenu.swift
line ~503 defines a `Zoom Reset (10kb)` item on `keyEquivalent: "1"` that the
chapter omits from the new Zoom group (it lists Zoom In/Out/Fit on +/-/0). Add
the row for completeness; it sits naturally in the same View table.

**S5. Unverified quoted strings and internal tool flags (carryover from R1
needs-human-check).** Not re-verifiable from `--help` and out of scope for a
binary spot-check, but still load-bearing for the CI and validation personas who
grep or cite them verbatim: the conda lock-wait / read-only messages and
`.install.lock` path (06-running-in-ci.md:48-49); the canonical mpileup / ivar /
LoFreq flag sets (power-user-notes.md:34-119); the provenance `schema_version: 2`
and `peakMemoryBytes` fields (power-user-notes.md:131, 193); the lock-record key
set and `schemaVersion: 1` (shared-projects.md:42-56); the SRA-fallback and lock
error strings (troubleshooting.md:60, 134). These should be traced to source in a
dedicated pass; this Round 2 pass verified command surfaces and shortcuts, not
internal message strings.

**S6. `cli-reference.md:233` - `bam markdup` is not 100% identical to top-level
`markdup`.** The chapter says "The same operation is available as `lungfish bam
markdup`." Close, but `bam markdup` lacks the `--deduplicated-bundle` option that
top-level `markdup` has (binary: `bam markdup <path> [--force] [--sort-threads]`
only). If precision matters, note that the sibling lacks `--deduplicated-bundle`.
Minor.

---

## Summary for the synthesis

Round 1 LANDED almost completely and the CLI reference is now accurate against
the binary at v0.5.0-alpha11. The 43-row command index is complete and correct;
the 8 renames, the 8 flag-signature fixes, the 14 added commands, the
tool-versions table (now exactly `version --tools`, with Clair3/WhatsHap/Freyja
demoted and openpyxl/pysam added), the Cmd-Ctrl-S sidebar fix and Find-Previous
correction, and the primer-scheme snake_case keys + 563/223 counts are all
verified. Three must-fixes remain: `extract contigs` (no positional `<assembly>`;
needs `--assembly`/`--contigs`), `extract reads` (the `--bundle <taxonomy-bundle>
--taxon` shape does not parse; needs a `--by-*` mode), and a nonexistent
`fastq subsample --seed` in power-user-notes. A handful of should-fixes (preset
and provenance-format completeness, the Cmd-1 zoom row, and the still-untraced
quoted error strings) round out the list. No em dashes in any of the nine
chapters.

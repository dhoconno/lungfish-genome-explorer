# Ground-truth reality map: appendices

Arbiter-of-truth comparison of the appendix chapters against the real CLI and
Swift source. Verified against the debug binary at
`.build/debug/lungfish-cli` (reports `Lungfish 0.5.0-alpha11`) and the source
under `Sources/LungfishCLI/Commands/`, `Sources/LungfishApp/App/MainMenu.swift`,
`Sources/LungfishIO/Bundles/`, and
`Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`.

Method: ran `lungfish-cli --help` for the root and recursed one level into every
subcommand. The root parser is `LungfishCLI` in
`Sources/LungfishCLI/LungfishCLI.swift`; its `subcommands:` array has exactly
**43 top-level commands**. Commands with a `defaultSubcommand:` do not print a
`SUBCOMMANDS:` block in `--help`, so subcommand existence was confirmed by
reading the `CommandConfiguration` arrays directly.

Reference: the 43 real top-level commands are `version`, `convert`, `analyze`,
`translate`, `sequence`, `search`, `universal-search`, `extract`, `fastq`,
`workflow`, `run-headless`, `fetch`, `bundle`, `project`, `provision-tools`,
`conda`, `blast`, `esviritu`, `taxtriage`, `align`, `msa`, `tree`, `assemble`,
`orient`, `map`, `import`, `import-fastq`, `ops`, `provenance`, `bam`,
`variants`, `gatk`, `nao-mgs`, `freyja`, `nvd`, `cz-id`, `metadata`,
`haplotypes`, `build-db`, `markdup`, `primers`, `genotype`, `debug`.

---

## cli-reference.md

This is the highest-priority chapter and it has the most drift. The chapter
organizes commands by domain instead of by the real command tree, which hides
the fact that several documented invocations do not exist and 14+ real
top-level commands are entirely absent.

### Documented but nonexistent commands

These exact invocations FAIL against the real binary.

1. **`lungfish classify --tool kraken2 ...`** (cli-reference.md:217). No
   top-level `classify` command. `lungfish classify --help` falls through to
   root help. The real command is `lungfish conda classify <fastq...> --db <db>`
   (`CondaCommand` subcommand, confirmed `USAGE: lungfish conda classify`).
2. **`lungfish extract-contigs --assembly ...`** (cli-reference.md:261). No
   top-level `extract-contigs`. The real command is `lungfish extract contigs`
   (`ExtractContigsSubcommand` under `ExtractCommand`, alongside `sequence` and
   `reads`).
3. **`lungfish extract-annotations --bundle ...`** (cli-reference.md:141). No
   top-level `extract-annotations`. The real command is
   `lungfish bundle extract-annotations` (`BundleExtractAnnotationsSubcommand`,
   `commandName: "extract-annotations"` under `BundleCommand`).
4. **`lungfish bam annotations --bundle ...`** (cli-reference.md:169). Wrong
   name. `lungfish bam annotations` returns `Error: Unexpected argument
   'annotations'`. The real subcommand is singular: `lungfish bam annotate`
   (`USAGE: lungfish bam annotate ... --bundle <bundle> --alignment-track
   <alignment-track> --output-track-name <output-track-name>`).
5. **`lungfish import application <path>`** (cli-reference.md:102). Wrong name
   and signature. The real subcommand is `import application-export` with two
   positionals: `USAGE: lungfish import application-export <kind> <source-path>
   --project <project>`.
6. **`lungfish nao-mgs import --run-dir <path>`** (cli-reference.md:229). No
   `nao-mgs import` subcommand. `NaoMgsCommand` exposes `lungfish nao-mgs
   summary <input-path>` (and the project-side import is `lungfish import
   nao-mgs`). There is no `--run-dir` flag.
7. **`lungfish esviritu run --reads <fastq...>`** (cli-reference.md:221). Wrong
   subcommand name and flag. The real command is `lungfish esviritu detect`
   with `-i/--input` and `-s/--sample` (`USAGE: lungfish esviritu detect
   [<options>] --sample <sample>`). There is no `esviritu run` and no `--reads`.
8. **`lungfish msa <command>` with `add` / `edit`** (cli-reference.md:408-410).
   The real `msa` subcommands are `actions`, `describe`, `annotate`, `export`,
   `consensus`, `extract`, `mask`, `trim`, `distance`. There is no top-level
   `msa add` or `msa edit`; `add`/`edit` live one level deeper under `msa
   annotate` (`AddSubcommand`/`EditSubcommand` in `MSACommand.swift`).

### Documented flags / signatures that do not match

These commands exist but the documented flags or argument shapes are wrong.

1. **`lungfish convert --in <path> --out <path>`** (cli-reference.md:400). Real
   signature is positional input plus `--to`: `USAGE: lungfish convert
   [<options>] <input> --to <to>`, with `--to-format` (default `fasta`). There
   is no `--in` or `--out`.
2. **`lungfish markdup --in <path> --out <path>`** (cli-reference.md:173;
   troubleshooting and power-user reference it too). Real signature is a single
   positional path: `USAGE: lungfish markdup [<options>] <path>` with `--force`,
   `--sort-threads`, `--deduplicated-bundle`. No `--in`/`--out`.
3. **`lungfish import vcf <path> [--reference <bundle>]`** (cli-reference.md:98).
   The `--reference` flag does not exist. Real: `USAGE: lungfish import vcf
   <input-file> [--output-dir <output-dir>]`. Reference inference may happen
   internally, but no documented `--reference` flag is accepted.
4. **`lungfish taxtriage run --reads <fastq...> [--profile clinical]`**
   (cli-reference.md:225). `taxtriage run` is correct, but the flags are wrong:
   real flags are `--input`/`--input2`/`--sample` or `--samplesheet`, plus
   `--platform`, `--db`, `--confidence`. There is no `--reads` and no `--profile`.
5. **`lungfish blast <sequence> [--database nt]`** (cli-reference.md:233). The
   real command is `lungfish blast verify` with required `--kreport`, `--source`,
   `--kraken-output`, `--taxid` (`USAGE: lungfish blast verify`). It is not a
   free-form `blast <sequence>` and does not take `--database nt`.
6. **`lungfish conda install --pack <name>...`** (cli-reference.md:332).
   `--pack` is a boolean `@Flag` (pack-mode toggle), not a value option. Real
   shape is `lungfish conda install --pack <packages...>` where the pack names
   are positional. Minor, but the `--pack <name>` value syntax is misleading.

### Real top-level commands MISSING from the reference

These commands have NO entry in cli-reference.md (verified by grepping the
chapter for each name). Counts below distinguish "absent from this chapter" from
"absent from every appendix."

Absent from the cli-reference chapter AND from every appendix:

- `analyze` (sequence statistics)
- `translate` (DNA/RNA to protein; note `Cmd-Shift-T` GUI verb is documented but the CLI command is not)
- `sequence` (annotate-orfs, delete-annotations, delete-annotation-track on bundles)
- `universal-search` (`USAGE: lungfish universal-search <project-path>`)
- `align` (create native MSA bundles)
- `orient` (top-level FASTQ orient; note `fastq orient` is documented, this top-level one is not)
- `gatk` (10 subcommands: haplotype-caller, joint-genotype, filter, select, variants-to-table, bqsr, markdup, validate-sam, leftalign, collect-metrics)
- `freyja` (`freyja demix`)
- `nvd` (NVD classification import/view)
- `cz-id` (CZ-ID import/view)
- `metadata` (FASTA/FASTQ sample metadata)
- `haplotypes` (10 subcommands for ONT genotyping haplotype definitions)
- `build-db` (taxtriage/esviritu/kraken2 SQLite builders)
- `genotype` (7 subcommands: list-samples, list-cohorts, apply-annotations, export, export-xlsx, export-pivot-xlsx, export-labkey)

Absent from the cli-reference chapter but documented in a sibling appendix:

- `project` (lock/unlock/migrate) is covered in shared-projects.md, not here.
- `ops` (`ops stats`) is shown in power-user-notes.md, not here.
- `provision-tools` is not documented anywhere.
- `primers` (`primers import`) is covered in primer-schemes.md, not here.

### Documented commands that ARE correct (spot-verified)

For balance: `version --tools`, `fetch ncbi --db --fetch-format --save-to`,
`fetch sra search`/`download`, `fetch genome`, `import fastq`/`import-fastq
--samplesheet`, `bundle export --format container --output --plugin-pack`,
`map` and its read-group flags, `variants call --caller {ivar,lofreq,medaka,
bcftools}`, `bam adopt-mapping`, `bam primer-trim`, `assemble`, `extract reads
--output`, `fastq subsample`/`length-filter`/`qc-summary`/`scrub-human`/
`orient`/`materialize`, `workflow run`/`list`/`validate`/`diff`, `run-headless`,
`conda lock`/`install --from-lockfile`/`offline-export`/`offline-install`,
`provenance bibliography`/`export`/`verify`, and the global flags table all
match the real binary.

### App features / commands missing from the docs

The cli-reference chapter is the canonical CLI lookup, so the missing
top-level commands above are the headline gap. Additionally, whole real
subcommand families are undocumented here: `fetch ena` (a real fifth fetch
subcommand), the seven real `bundle` subcommands (`info`, `create`,
`extract-annotations`, `deduplicate-alignments`, `export`, `validate`, `list`;
the chapter shows only `create`/`list`/`export`), and the 30+ `fastq`
subcommands (the chapter names six). The `bam markdup` subcommand exists in
parallel with top-level `markdup` and neither duplication is explained.

### Uncertain / needs-human-check

1. The chapter's framing "a single binary, `lungfish`" (cli-reference.md:22) is
   true for installed releases, but the SwiftPM product is `lungfish-cli`;
   shared-projects.md explains this and cli-reference.md does not. Decide whether
   the CLI reference should note the source-build name.
2. `CompositionCommand.swift` exists in `Sources/LungfishCLI/Commands/` but is
   NOT in the root `subcommands:` array (`lungfish composition` falls through to
   root help). It is dead/unregistered code; correctly absent from the docs.
   Flag for the engineering owner, not the doc editor.
3. The doc says `lungfish provenance show` does not exist (cli-reference.md:392).
   Confirmed: `provenance` has only `bibliography`, `export`, `verify`. Accurate.

---

## file-formats.md

### Claims that do not match code

1. **`.lungfishtax` is described as the universal classifier bundle**
   (file-formats.md:130, 207-223): "Stores classifier output (Kraken2,
   EsViritu, TaxTriage, NAO-MGS) in a normalized form." In code, `.lungfishtax`
   is produced only by the CZ-ID import path (`CzIdProjectImportWorkflow`,
   `ImportCzIdSubcommand.swift`, `SidebarViewController.swift:1370`). Kraken2,
   EsViritu, TaxTriage, and NAO-MGS results are not stored as `.lungfishtax`
   bundles. The claimed multi-classifier scope and the
   `classifications.tsv`/`abundance.tsv`/`tree.json`/`raw/` layout are not
   grounded in the source for those tools.
2. **`.lungfishvcf` is presented as a real on-disk bundle format**
   (file-formats.md:133, 255-268, plus the manifest/sharing examples). The only
   occurrence of `lungfishvcf` in source is an enum case in
   `Sources/LungfishWorkflow/WorkflowPackages/WorkflowPackageManifest.swift:19`
   (a workflow-package output-kind). There is no `.lungfishvcf` bundle reader or
   writer in `Sources/LungfishIO/Bundles/`, and the chapter's own `.lungfishref`
   layout (file-formats.md:173-175) stores variants in the reference bundle's
   `variants/` subdirectory. The standalone `.lungfishvcf` bundle with
   `variants.vcf.gz`/`.tbi`/`consensus.fasta` appears fabricated.
3. **The bundle-format table omits real bundle extensions**
   (file-formats.md:125-133). `Sources/LungfishIO/Bundles/` defines
   `.lungfishfastq`, `.lungfish12sref`, `.lungfishmhcref`, and
   `.lungfishhaplotypedef`, none of which appear in the table. The table lists
   `.lungfishtax` and `.lungfishvcf`, which (per the two points above) are not
   real LungfishIO bundle formats.

### App features / file formats missing from the docs

The real LungfishIO bundle set (verified by grepping the directory for literal
`.lungfish*` extensions) is `.lungfishref`, `.lungfishfastq`, `.lungfishmsa`,
`.lungfishtree`, `.lungfishprimers`, `.lungfish12sref`, `.lungfishmhcref`, and
`.lungfishhaplotypedef`. The chapter documents only `.lungfishref`,
`.lungfishprimers`, `.lungfishmsa`, `.lungfishtree` (plus the two questionable
ones). Missing entirely: `.lungfishfastq` (FASTQ read bundles, central to the
import and 12S workflows), `.lungfish12sref` and `.lungfishmhcref` (amplicon
reference bundles produced by `fastq 12s-reference-bundle` and
`fastq mhc-reference-bundle`), and `.lungfishhaplotypedef` (ONT genotyping
haplotype definition sets managed by `haplotypes`). The `.lungfishflow`
workflow bundle is referenced in cli-reference (`workflow diff`) but not
described here.

### Uncertain / needs-human-check

1. The provenance JSON example uses `"schema_version": 2` in power-user-notes.md
   but the file-formats.md example shows no `schema_version` and lists
   `"version": "0.5.0-alpha6"`. The current build is `0.5.0-alpha11`. Verify the
   real provenance schema version and the version string against
   `Sources/LungfishWorkflow` provenance writers (not re-derived here).
2. The manifest field claims (`genome` block with assembly accession, primer
   `pool_count`/`amplicon_count`, taxonomy `tool`/`database`/`read_count`,
   file-formats.md:284) were not verified against actual manifest writers. The
   primer manifest specifically uses snake_case `amplicon_count` (see primer
   section below), not the camelCase implied; confirm the others.
3. Whether GenBank import truly produces a GFF3 track (file-formats.md:50) was
   not re-verified in this pass.

---

## keyboard-shortcuts.md

Verified against `Sources/LungfishApp/App/MainMenu.swift` (titles, `keyEquivalent`,
and `keyEquivalentModifierMask`).

### Claims that do not match code

1. **Sidebar toggle is Cmd-Ctrl-S, not Cmd-Shift-S** (keyboard-shortcuts.md:46).
   `MainMenu.swift:431-433` sets `keyEquivalent: "s"` with
   `keyEquivalentModifierMask = [.command, .control]` and a code comment
   "Control-Command-S per macOS standard." This also breaks the "Memorizing
   chords" claim (keyboard-shortcuts.md:117) that `Cmd-Shift-letter` toggles the
   Sidebar.
2. **`Cmd-Shift-G` does NOT step to the previous find match**
   (keyboard-shortcuts.md:101). In `MainMenu.swift:404-409` "Find Previous" has
   an empty `keyEquivalent` (no shortcut), with the comment "Cmd-Shift-G is used
   by Go to Gene." So `Cmd-Shift-G` is only Go to Gene; it is never overloaded
   onto find-previous. "Find Next" is `Cmd-G` (`MainMenu.swift:397-401`).

### App features / shortcuts missing from the docs

The View menu has real shortcuts the chapter omits: Focus Viewer `Cmd-Opt-F`
(`MainMenu.swift:446-451`), Restore Side Panes `Cmd-Ctrl-Opt-F` (454-459), Zoom
In `Cmd-+` / Zoom Out `Cmd--` / Zoom to Fit `Cmd-0` (483-499), Show as RNA
`Cmd-Shift-U` (529-534), and Taxonomy Expand All / Collapse All on
`Cmd-Shift-RightArrow` / `Cmd-Shift-LeftArrow` (512-524). The Window menu adds
New Window for Current Project `Cmd-Opt-N` (864-870). None appear in the chapter.

### Uncertain / needs-human-check

1. The chapter labels several rows "Show or Hide X" (Sidebar, Inspector). The
   real titles start as "Show Sidebar"/"Show Inspector" and toggle dynamically
   via `validateMenuItem` tags (1000/1001). The toggle behavior is real; the
   "Show or Hide" phrasing is a reasonable description. No change needed unless
   editors want exact titles.
2. App-menu rows are documented as "Hide Lungfish" / "Quit Lungfish"; the real
   titles are "Hide Lungfish Genome Explorer" / "Quit Lungfish Genome Explorer"
   (`MainMenu.swift`). The chapter intentionally abbreviates the product name.
   Confirmed correct shortcuts (`Cmd-H`, `Cmd-Q`, `Cmd-,` Settings, `Cmd-M`
   Minimize, `Cmd-?` Help, `Cmd-Shift-I` Import Center, `Cmd-Shift-B` Plugin
   Manager, `Cmd-Shift-P` Operations Panel, `Cmd-Opt-I` Inspector, `Cmd-Opt-D`
   Document Inspector, `Cmd-Shift-A` AI Assistant, `Cmd-Ctrl-F` Enter Full
   Screen, all Sequence verbs).
3. The "Hide Lungfish = Cmd-H" plus the chapter's separate New/Open/Save/Close
   rows match. "Save Project = Cmd-S" maps to the menu title "Save"; "Open
   Project = Cmd-O" maps to "Open Project Folder...". Naming drift only.

---

## primer-schemes.md

Verified against
`Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/manifest.json`
and `Sources/LungfishCLI/Commands/PrimerCommand.swift`.

### Claims that do not match code

1. **Manifest field names are snake_case in the real manifest, not camelCase**
   (primer-schemes.md:49-57). The chapter's field table lists `displayName`,
   `referenceAccessions`, `primerCount`, `ampliconCount`, `created`, `imported`,
   `attachments`. The shipped manifest uses `display_name`,
   `reference_accessions`, `primer_count`, `amplicon_count`, `source`,
   `source_url`, `version`, `created`. There is no `imported` field and no
   `attachments` field in the shipped manifest; `schema_version`, `description`,
   `organism`, and `source_url` are present and undocumented.
2. **`reference_accessions` shape differs** (primer-schemes.md:51). The chapter
   describes it as "canonical accession plus equivalent accessions." The real
   value is an array of objects: `[{"accession": "MN908947.3", "canonical":
   true}, {"accession": "NC_045512.2", "equivalent": true}]`. Worth showing the
   object shape.

### App features missing from the docs

The shipped scheme's concrete numbers are not stated and would anchor the
chapter: `primer_count` = 563, `amplicon_count` = 223, `display_name` =
"QIAseq Direct SARS-CoV-2 with Booster A", `source` = "built-in",
canonical accession `MN908947.3` with equivalent `NC_045512.2`. The chapter
calls the scheme `QIASeqDIRECT-SARS2` (the `name`) but never gives its display
name or counts.

### Uncertain / needs-human-check

1. The CLI flag set is accurate: `PrimerCommand.swift` confirms `--bed`,
   `--fasta`, `--output`, `--project`, `--reference-accession`, `--display-name`,
   `--equivalent-accession` (repeatable), `--attachment` (repeatable). No change.
2. The chapter says project schemes get `source: imported` (primer-schemes.md:56,
   "Usually `imported` for project schemes"). The CLI importer's actual `source`
   value was not traced into `PrimerSchemeImportService`; the shipped built-in
   uses `"built-in"`. Confirm the importer writes `imported` for CLI/GUI imports.

---

## tool-versions.md

Verified against `lungfish version --tools` (live output) and
`Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`.

### Claims that do not match code

1. **The managed-tools table lists three tools that are NOT in the
   managed-tool lock** (tool-versions.md:55-57): Clair3 1.0.10, WhatsHap 2.3,
   Freyja 2.0.0. The lock file contains no `clair3`, `whatshap`, or `freyja`
   environment, and `lungfish version --tools` does not print them. These tools
   ship via plugin packs (conda packs), not the bundled managed-tool lock. The
   chapter states (tool-versions.md:27) "The same table is available from
   `lungfish version --tools`," but the documented table does not match the
   command output.
2. **The managed-tools table omits two tools the command actually prints**
   (live output): `openpyxl` 3.1.5 (env `openpyxl`) and `pysam` 0.24.0 (env
   `pysam`). Both are in the lock file and in `version --tools`, neither is in
   the chapter.
3. **Tool name casing drift vs the live table.** The command prints "Fastp"
   (the chapter says "fastp"), and prints "BCFtools" with license shown only in
   the chapter (the live table has no License column). Minor, but the chapter
   implies the License/Source columns come from `version --tools`; the live
   table shows only Tool / Version / Source / Environment / Executables (no
   License, no Source values beyond "bundled"/"managed").

### App features missing from the docs

The real `version --tools` set (17 rows): micromamba (bundled), BBTools,
BCFtools, Cutadapt, Deacon, Fastp, HTSlib, Nextflow, openpyxl, pigz, pysam,
Samtools, SeqKit, Snakemake, SRA Tools, UCSC bedGraphToBigWig, VSEARCH. The
chapter is missing `openpyxl` and `pysam` and wrongly adds Clair3, WhatsHap,
and Freyja.

### Uncertain / needs-human-check

1. The chapter's License column values (e.g. BCFtools "GPL", VSEARCH "GPL-3.0
   OR BSD-2") may be sourced from the lock file's per-tool metadata even though
   `version --tools` does not display licenses. The lock JSON was not fully
   dumped for licenses in this pass; verify the License column against the lock's
   `license` fields before trusting it.
2. The Supported Workflow Pins table (nf-core/viralrecon 3.0.0,
   tool-versions.md:71) was not traced to a source constant. The
   `workflow run nf-core/viralrecon --version` override is real (it appears in
   the workflow adapter help); confirm the default `3.0.0` pin in source.

---

## 06-running-in-ci.md

### Claims that do not match code

None found. The CI-facing commands are real: `lungfish run-headless <workflow>`
(`RunHeadlessSubcommand` in `Sources/LungfishCLI/Commands/WorkflowCommand.swift`,
registered as `run-headless` in the root array), `lungfish conda offline-export
--pack <pack> --output <output>` (`USAGE` confirmed), and `lungfish conda
offline-install <pack-directory> [--conda-root]` (`USAGE` confirmed). The
`--conda-root` flag and `LUNGFISH_CONDA_ROOT` usage match the real
`offline-install` signature.

### App features / commands missing from the docs

Not applicable for this chapter's scope.

### Uncertain / needs-human-check

1. The error strings quoted (`waiting for conda lock held by pid <n>`,
   `conda root is read-only; reinstall as the admin user`,
   running-in-ci.md:48-49) were not located in source in this pass. Verify the
   exact lock-wait and read-only messages against the conda manager source.
2. The `<conda-root>/.install.lock` path (running-in-ci.md:48) was not verified;
   confirm the lock filename used by the conda manager.

---

## power-user-notes.md

### Claims that do not match code

1. **Version string drift**: the chapter pins to `0.5.0-alpha6`
   (power-user-notes.md:24, 134) and the provenance example uses `"version":
   "0.5.0-alpha6"`. The current build reports `0.5.0-alpha11`. The numbers are
   "as documented for that build" by the chapter's own framing, but the example
   should track the shipping version.
2. **`lungfish bam adopt-mapping` provenance-verification claim**
   (power-user-notes.md:315): the chapter says a manual non-Lungfish BAM means
   "`lungfish bam adopt-mapping` will not be able to verify the BAM came from the
   expected pipeline." `bam adopt-mapping` exists, but whether it performs
   provenance verification (vs just attaching) was not confirmed in source. Flag.

### App features / commands missing from the docs

Not a gap-listing chapter; the `ops stats <project>` and `bundle export
--format container` references are correct. `conda lock`/`install
--from-lockfile` references match the real flags.

### Uncertain / needs-human-check

1. The canonical mpileup flags (`-aa -A -d 600000 -B -Q 20 -q 0`,
   power-user-notes.md:34-44) and ivar flags (`-p -q 20 -t 0.05 -m 10 -r -g`)
   are presented as exactly what Lungfish runs. These were NOT traced into the
   variant-calling pipeline source in this pass. Verify against the iVar pipeline
   builder before treating them as ground truth.
2. The LoFreq `indelqual --dindel` and `call-parallel --pp-threads 4
   --no-default-filter` invocations (power-user-notes.md:93-110) were likewise
   not traced to source. Verify.
3. The provenance schema (`schema_version: 2`, `peakMemoryBytes` on steps,
   power-user-notes.md:128-196) needs verification against the provenance writer.
   The `ops stats` description (recursively scans `.lungfish-provenance.json`,
   ignores failed/cancelled, reports peak RAM) matches the `OpsCommand` abstract
   "Summarize runtime and peak RAM from provenance sidecars."

---

## shared-projects.md

### Claims that do not match code

None found in the command surface. `lungfish project lock`, `project unlock`,
and `project migrate` are the three real `ProjectCommand` subcommands
(`USAGE` confirmed earlier: `lock`, `unlock`, `migrate`). The `--mode`,
`--force`, `--dry-run`, and `--format json` flags align with the documented
behavior, and the `.lungfish/project.lock` record is described in detail.

### App features / commands missing from the docs

Not applicable; this chapter scopes to the `project` command group only.

### Uncertain / needs-human-check

1. The lock-record JSON fields (`appVersion`, `schemaVersion: 1`, `toolName:
   "lungfish project lock"`, `processStartTime`, shared-projects.md:42-56) were
   not verified field-by-field against the lock writer. Confirm the exact key set
   and `schemaVersion`.
2. The migration semantics around `browser_summary` synthesis and
   `dry-run-synthesize-browser-summary` action labels (shared-projects.md:100)
   were not traced into the migration code. Verify the action strings and the
   `.lungfish/migrations/` backup path.
3. The chapter correctly notes the source-build binary name `lungfish-cli` and
   the app-bundle path `Lungfish.app/Contents/MacOS/lungfish-cli`
   (shared-projects.md:30). Both binary names exist in `.build/debug/`.

---

## troubleshooting.md

### Claims that do not match code

1. **`lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir>`**
   (troubleshooting.md:78) omits the required `--name`. The real signature
   requires `--name`: `USAGE: lungfish bam adopt-mapping ... --bundle <bundle>
   --mapping-result <mapping-result> --name <name>`. A copy-paste of the doc
   command will fail with a missing-required-option error.

Confirmed correct: `lungfish fetch ncbi --no-retry` (troubleshooting.md:58) is
real (`--no-retry  Do not retry HTTP 429 rate-limit responses`). The retry
description matches.

### App features / commands missing from the docs

Not a command-listing chapter. The `--ivar-primer-trimmed` flag reference
(troubleshooting.md:90) matches `variants call`. The `conda install --pack
read-mapping variant-calling` example (troubleshooting.md:40) uses the `--pack`
flag correctly as a mode toggle with positional pack names.

### Uncertain / needs-human-check

1. Several quoted error strings were not located in source:
   `command not found: minimap2/ivar`, `could not acquire lock on
   manifest.json`, `Falling back to SRA Toolkit (prefetch + fasterq-dump)`
   (troubleshooting.md:30-32, 60, 134). Verify the exact wording, especially the
   SRA fallback message used in the Operations Panel disclosure.
2. The menu item `Project > Migrate Bundles to Current Version`
   (troubleshooting.md:142) and `Project` menu existence were not verified in
   `MainMenu.swift` (the verified menus are App, File, Edit, View, Sequence,
   Operations, Tools, Window, Help; no top-level "Project" menu was seen). The
   migration is CLI-exposed (`project migrate`); confirm whether a GUI menu item
   exists.
3. The Kraken2 database RAM figures (Standard ~50 GB, PlusPF ~80 GB, Viral
   ~500 MB, troubleshooting.md:122) are advisory and not code-derived.

---

## Section-wide

### Most consequential findings (ranked)

1. **cli-reference.md is the worst-drifted chapter.** 8 documented invocations
   do not exist or are mis-named (`classify`, `extract-contigs`,
   `extract-annotations`, `bam annotations`, `import application`, `nao-mgs
   import`, `esviritu run`, `msa add/edit`), 6 more have wrong flags/signatures
   (`convert`, `markdup`, `import vcf --reference`, `taxtriage run`, `blast`,
   `conda install --pack`), and 14 real top-level commands are absent from every
   appendix (`analyze`, `translate`, `sequence`, `universal-search`, `align`,
   `orient`, `gatk`, `freyja`, `nvd`, `cz-id`, `metadata`, `haplotypes`,
   `build-db`, `genotype`). The chapter's domain-grouping structure masks the
   real 43-command tree.
2. **file-formats.md invents two bundle formats.** `.lungfishvcf` has no
   LungfishIO reader/writer (only a workflow enum case), and `.lungfishtax` is
   CZ-ID-only rather than the universal classifier bundle the chapter claims. It
   also omits four real bundle types (`.lungfishfastq`, `.lungfish12sref`,
   `.lungfishmhcref`, `.lungfishhaplotypedef`).
3. **tool-versions.md self-contradicts its own "same as `version --tools`"
   promise.** It lists Clair3/WhatsHap/Freyja (not in the managed lock) and
   omits openpyxl/pysam (which the command prints).
4. **keyboard-shortcuts.md has one hard error** (Sidebar is `Cmd-Ctrl-S`, not
   `Cmd-Shift-S`) plus a wrong Find-Previous overload claim, and omits ~8 real
   View/Window shortcuts.
5. **primer-schemes.md documents camelCase manifest keys** that are snake_case
   in the shipped manifest, and never states the real counts (563 primers, 223
   amplicons).

### Cross-cutting reliability note

Many quoted error strings, provenance-schema fields, and tool-invocation flag
sets across power-user-notes.md, troubleshooting.md, running-in-ci.md, and
shared-projects.md were not traceable to source in this pass and are marked
needs-human-check. The command surfaces and shortcuts WERE verified against the
live binary and `MainMenu.swift`; the internal tool flags and message strings
need a second pass against the pipeline-builder and conda-manager source.

### Verification baseline

Binary: `.build/debug/lungfish-cli`, self-reports `Lungfish 0.5.0-alpha11`.
Root parser: `Sources/LungfishCLI/LungfishCLI.swift` (43 subcommands). Lock
manifest: 17 tools, no Clair3/WhatsHap/Freyja/Medaka/lofreq/ivar/minimap2.
LungfishIO bundle extensions: `.lungfishref`, `.lungfishfastq`, `.lungfishmsa`,
`.lungfishtree`, `.lungfishprimers`, `.lungfish12sref`, `.lungfishmhcref`,
`.lungfishhaplotypedef` (no `.lungfishtax`/`.lungfishvcf` defined there).

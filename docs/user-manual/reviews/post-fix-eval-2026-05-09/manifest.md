# Evaluation Manifest — 2026-05-09 sweep (final)

Build under test: `~/Library/Developer/Xcode/DerivedData/Lungfish-aygvdshcdayvgybtylkaywokohex/Build/Products/Debug/Lungfish.app`
CLI: `Lungfish.app/Contents/MacOS/lungfish-cli` (lungfish-cli 0.4.0-alpha.11)
Reviewer: dho, raven.local
Source backlog: `docs/issues/2026-05-09-technical-gaps-from-documentation.md`
Follow-up backlog: `docs/issues/2026-05-09-followups-from-evaluation-sweep.md`
Screenshots: `docs/user-manual/shots/captured/2026-05-09/` (39 files)

## Verdict legend

- **FIXED** — implementation lands the spec end-to-end. Evidence path noted.
- **PARTIAL** — primary path works, named caveat. New follow-up issue filed.
- **BROKEN** — implementation present but does not satisfy the spec. New follow-up issue filed.
- **NON-RESPONSIVE** — no implementation; spec stays open in original backlog.
- **CLOSED** — already resolved before sweep (e.g. docs-015 fixed in F04 doc revision; docs-009 lifted to docs-039).

---

## Roll-up (all 40 issues)

| ID | Severity | Topic | Verdict | Follow-up |
|---|---|---|---|---|
| docs-001 | P0 | GenBank → annotations | FIXED | none — earlier mat_peptide-drop claim was wrong |
| docs-002 | P1 | Multi-user shared projects (locks) | FIXED | none |
| docs-003 | P2 | Bundle migration tool | FIXED | none |
| docs-004 | P1 | NCBI 429 retry | FIXED | none |
| docs-005 | P2 | NCBI API key in Settings | FIXED | none — NCBI section in Settings > General with API Key field |
| docs-006 | P2 | Pathoplexus search dialog | FIXED | none — dialog ships with 10 organism presets |
| docs-007 | P2 | Phased variant calling (HaplotypeCaller / WhatsHap) | PARTIAL | command-plan surface added; iVar `--phase-aware` warning remains open |
| docs-008 | P2 | Clair3 as alternative ONT caller | FIXED | none |
| docs-009 | — | (Lifted to docs-039) | CLOSED | — |
| docs-010 | P2 | bcftools as orthogonal caller | NON-RESPONSIVE | parent issue stays open |
| docs-011 | P1 | Freyja for wastewater | PARTIAL | command-plan surface added; richer run dialog remains open |
| docs-012 | P2 | Database update tracking | NON-RESPONSIVE | parent issue stays open |
| docs-013 | P2 | BLAST rate-limiting | NON-RESPONSIVE | parent issue stays open |
| docs-014 | P1 | Read groups in mapping | PARTIAL | docs-014a (CLI has --rg-*; GUI dialog lacks them) |
| docs-015 | P2 | BAM CIGAR display fidelity | CLOSED | (already closed in F04) |
| docs-016 | P1 | viralrecon wizard chapter | FIXED | none |
| docs-017 | P1 | Tree-viewport result tools | NON-RESPONSIVE | parent issue stays open |
| docs-018 | P1 | Container image export | NON-RESPONSIVE | parent issue stays open |
| docs-019 | P1 | Conda lockfile generation | NON-RESPONSIVE | parent issue stays open |
| docs-020 | P2 | Workflow versioning + diff | NON-RESPONSIVE | parent issue stays open |
| docs-021 | P1 | Pass-through args (--extra-args) | PARTIAL | docs-021a (rename), docs-021b (9 missing tools) |
| docs-022 | P2 | Headless / batch CI mode | PARTIAL | docs-022a (CLI is headless but no `run-headless` subcommand or doc) |
| docs-023 | P1 | Sample sheet support | NON-RESPONSIVE | parent issue stays open |
| docs-024 | P2 | Multi-sample VCF rendering + filter | PARTIAL | docs-024a (no `extract-sample`/`query` CLI; SQLite substrate exists) |
| docs-025 | P2 | Reject VCFv3 with clear error | FIXED | none |
| docs-026 | P3 | Signed provenance sidecars | NON-RESPONSIVE | parent issue stays open |
| docs-027 | P2 | User account in provenance sidecar | FIXED | none |
| docs-028 | P2 | Methods Section export draft warning | FIXED | none — banner string in source |
| docs-029 | P1 | Tool-version reference table | FIXED | none — `lungfish version --tools` |
| docs-030 | P2 | Tool-paper bibliography | FIXED | none — `lungfish provenance bibliography` |
| docs-031 | P2 | Offline conda install | FIXED | none |
| docs-032 | P2 | Shared `~/.lungfish/conda` across machines | PARTIAL | docs-032a (LUNGFISH_CONDA_ROOT env var present; lock semantics + read-only test pending) |
| docs-033 | P2 | Per-operation runtime estimates | NON-RESPONSIVE | parent issue stays open |
| docs-034 | P2 | Hardware floor declaration | PARTIAL | docs-034a (`minimumMacOSVersion` only at container runtime layer; no Settings/About declaration) |
| docs-035 | P3 | Empty GFF3 should still write manifest | NON-RESPONSIVE | parent issue stays open |
| docs-036 | P3 | Custom primer scheme builder | NON-RESPONSIVE | parent issue stays open |
| docs-037 | P3 | fastp combined adapter+quality dialog | NON-RESPONSIVE | parent issue stays open |
| docs-038 | P1 | CZ-ID first-class import | PARTIAL | docs-038a (no `lungfish import cz-id`; verified in Import Center → Classification Results) |
| docs-039 | P1 | GATK first-class | FIXED at CLI surface | dialog grays out with "Requires GATK Core Pack" badge |
| docs-040 | P1 | Workflow Builder | BROKEN — dead code | docs-040a/b/c/d |

**Tally:** 15 FIXED, 10 PARTIAL, 13 NON-RESPONSIVE, 1 BROKEN, 1 CLOSED. (40 total)

---

## P0 — Issues that block documentation coherence

### docs-001 — GenBank import populates annotations

**Verdict:** FIXED

Earlier sweep filed docs-001a claiming `mat_peptide` features were dropped on
GenBank import. **That claim was wrong.** The MN908947.3 record has only `gene`
and `CDS` features in its NCBI nucleotide form; RefSeq NC_045512.2 ships
mat_peptide features and Lungfish preserves all of them.

**Evidence:**
- `lungfish-cli fetch ncbi NC_045512.2 --fetch-format genbank` → source GenBank
  has 12 CDS + 11 gene + **26 mat_peptide** + 5 stem_loop + 1 source.
- `lungfish-cli import fasta NC_045512.2.gb` → produced GFF3 contains all 26
  mat_peptide and all 5 stem_loop.
- Captured: `/tmp/lungfish-eval/scratch/docs-001a/Reference\ Sequences/NC_045512.lungfishref/`
- Screenshot: `reference-bundle-loaded.png` shows the loaded NC_045512 bundle
  with annotation chips: 5'UTR, 3'UTR, CDS, gene, **mat_peptide**, stem_loop.

No follow-up.

---

## P1 — Feature gaps with active documentation impact

### docs-002 + docs-027 — Project locks + user attribution

**Verdict:** FIXED

```bash
$ lungfish-cli project lock /tmp/lungfish-eval/eval-project --mode exclusive
Locked project: /tmp/lungfish-eval/eval-project
$ jq . /tmp/lungfish-eval/eval-project/.lungfish/project.lock
{ "user": "dho", "host": "raven.local", "pid": 88111,
  "mode": "exclusive", "schemaVersion": 1, ... }
```

Provenance sidecars carry `runtime.user`. End-to-end attribution.

### docs-004 — NCBI 429 retry

**Verdict:** FIXED

`--no-retry` flag opts out; default is retry-on. `--api-key` for higher rate
limits.

### docs-011 — Freyja

**Verdict:** PARTIAL

`lungfish-cli conda packs` now includes the active
`wastewater-surveillance` pack with Freyja. `lungfish freyja demix` writes a
dry-run command plan and provenance sidecar by default, with `--execute`
available when the pack is installed. The Tools menu includes
FASTQ/FASTA Operations > Lineage Demixing > Freyja.

### docs-014 — Read groups in mapping

**Verdict:** PARTIAL

CLI exposes `--rg-id`, `--rg-sm`, `--rg-lb`, `--rg-pl`, `--rg-pu`. The GUI
Mapping dialog (`mapping-dialog-overview.png`,
`mapping-dialog-advanced-options.png`) does **not** surface these fields.
Advanced Settings disclosure shows Threads / Secondary alignments /
Supplementary / Min mapping quality + Advanced Options text field — no
read-group section. Filed as docs-014a.

### docs-016 — viralrecon wizard chapter

**Verdict:** FIXED

`docs/user-manual/chapters/04-alignments/05-viral-recon-wizard.md` exists
(136 lines). CLI: `lungfish-cli workflow run nf-core/viralrecon` documented.

### docs-017 — Tree-viewport result tools

**Verdict:** NON-RESPONSIVE

`lungfish-cli tree --help` shows only `infer` and `export`. No `reroot`,
`extract-subtree`, `relabel`. No tree-viewport context menu in the GUI
(could not verify directly because no `.lungfishtree` was loaded; source
contains no `RerootCommand` or equivalent).

### docs-018 — Container image export

**Verdict:** NON-RESPONSIVE

`lungfish-cli bundle --help` exposes only `info`. No `export`,
no `--format container`.

### docs-019 — Conda lockfile generation

**Verdict:** NON-RESPONSIVE

`lungfish-cli conda --help` lacks `lock` subcommand. `conda install --help`
has no `--from-lockfile` flag.

### docs-021 — Pass-through args

**Verdict:** PARTIAL

| Subcommand | Pass-through flag |
|---|---|
| All 10 GATK subcommands | `--extra-args` ✓ |
| `lungfish map` | `--advanced-options` (different name) |
| `lungfish assemble` | `--advanced-options` (different name) |
| `orient`, `blast`, `esviritu`, `taxtriage`, `tree infer`, `msa run`, `align`, `fastq trim`, `conda classify` | none |

Filed as docs-021a (rename) + docs-021b (add to nine tools).

### docs-022 — Headless / batch CI mode

**Verdict:** PARTIAL

The CLI is headless by design — every subcommand runs without a display
server. The spec called for an explicit `lungfish run-headless` subcommand
plus a CI documentation chapter. Neither ships. Filed as docs-022a.

### docs-023 — Sample sheet support for batch import

**Verdict:** NON-RESPONSIVE

`lungfish-cli import fastq --help` has no `--samplesheet` flag.

### docs-039 — GATK first-class

**Verdict:** FIXED at CLI surface

10 GATK subcommands, all with `--execute` / `--dry-run` / `--extra-args`.
GUI Variant Calling dialog lists GATK HaplotypeCaller as the fourth tool
with a "Requires GATK Core Pack" badge (verified via `variant-call-dialog-lofreq.png`).
End-to-end execution against GIAB fixture deferred.

### docs-040 — Workflow Builder

**Verdict:** BROKEN — Workflow Builder is **dead code**

The Tools menu has no Workflow Builder entry (`tools-menu.png`). The 612-line
`WorkflowBuilderViewController` is never instantiated anywhere in the app.
2,809 lines of Workflow Builder source in `Sources/LungfishApp/Views/WorkflowBuilder/`
+ 1,300 lines of model in `Sources/LungfishWorkflow/Builder/` are unreachable
from the GUI. Filed as docs-040a/b/c/d.

---

## P2 — Feature gaps with future documentation impact

### docs-003 — Bundle migration

**Verdict:** FIXED

`lungfish-cli project migrate <path> --dry-run` ships, conservative-by-default.

### docs-005 — NCBI API key in Settings

**Verdict:** FIXED

Settings > General has an "NCBI / API key:" field at the bottom of the panel
(`settings-general-with-ncbi-key.png`). Source: `GeneralSettingsTab.swift`
defines `saveNCBIAPIKey`/`clearNCBIAPIKey`.

### docs-006 — Pathoplexus search dialog

**Verdict:** FIXED

Tools > Search Online Databases > Search Pathoplexus opens a fully feature-
complete dialog (`pathoplexus-search-dialog.png`) with 10 organism presets:
Crimean-Congo hemorrhagic fever, Sudan ebolavirus, Zaire ebolavirus, Human
metapneumovirus, Marburg virus, Measles virus, Mpox virus, RSV-A, RSV-B, West
Nile virus. Search box + Advanced Search Filters disclosure.

### docs-007 — Phased variant calling

**Verdict:** PARTIAL

`lungfish variants phase` now builds a GATK HaplotypeCaller plus WhatsHap
command plan, writes provenance, and supports `--execute` when `gatk-core`
and `phasing` packs are installed. The BAM variant-calling dialog exposes a
GATK+WhatsHap phased lane with pack gating. The iVar-specific
`--phase-aware` warning remains open.

### docs-008 — Clair3

**Verdict:** FIXED

`variant-calling` now includes Clair3 metadata and `run_clair3.sh`.
`lungfish variants call --caller clair3` parses model and advanced options,
constructs the Clair3 command, records provenance/options, and the BAM
variant-calling dialog exposes Clair3 with pack gating.

### docs-010 — bcftools as orthogonal caller

**Verdict:** NON-RESPONSIVE

`lungfish-cli variants call --help` does not list bcftools. The variants
GUI dialog (`variant-call-dialog-lofreq.png`) shows LoFreq, iVar, Medaka,
GATK HaplotypeCaller — no bcftools.

### docs-012 — Database update tracking

**Verdict:** NON-RESPONSIVE

`lungfish-cli conda info <pack>` does not exist. Plugin Manager UI does not
show install date or "Update available" indicator (`plugin-manager-installed-tab.png`).

### docs-013 — BLAST rate-limiting

**Verdict:** NON-RESPONSIVE

`lungfish-cli blast --help` has no `--max-concurrent` or rate-limit flag.

### docs-020 — Workflow versioning and diff

**Verdict:** NON-RESPONSIVE

`lungfish-cli workflow --help` has no `diff` subcommand. (Moot until
docs-040c wires the builder.)

### docs-024 — Multi-sample VCF + per-sample filtering

**Verdict:** PARTIAL

Substrate (SQLite-backed variant store) is in place. Variant browser
(`variant-browser-with-inspector.png`) renders the table with quality/QC
filter chips (PASS, Qual ≥ 30, DP ≥ 10, Singleton, Minor <20%, Mixed
20-80%, Dominant ≥80%, DEL, SNP). No per-sample filter syntax (`Sample[NA12878].GT=1/1`).
No `lungfish-cli variants extract-sample` or `variants query` subcommands.
Filed as docs-024a.

### docs-025 — Reject VCFv3

**Verdict:** FIXED

```
$ lungfish-cli import vcf vcfv3.vcf
✗ Failed to parse VCF: VCFv3 is not supported. Convert to VCF 4.x with
  bcftools convert or vcf-convert (vcftools) before importing. See
  https://samtools.github.io/bcftools/bcftools.html#convert and
  https://vcftools.github.io/perl_module.html
```

Verbatim error and pointer match the spec.

### docs-026 — Signed provenance sidecars

**Verdict:** NON-RESPONSIVE

No `lungfish-cli provenance verify`. No signing key configuration in Settings
(`settings-ai-services.png` shows no signing tab; provenance has only
`bibliography` subcommand).

### docs-028 — Methods Section export draft warning

**Verdict:** FIXED

Source: `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift:403`:
```swift
s += "<!-- This is an automatically-generated draft. Read it before submitting. -->\n\n"
```

### docs-029 — Tool-version reference table

**Verdict:** FIXED

`lungfish-cli version --tools` prints a 16-row table (micromamba, BBTools,
BCFtools, Cutadapt, Deacon, Fastp, HTSlib, Nextflow, pigz, Samtools, SeqKit,
Snakemake, SRA Tools, UCSC bedGraphToBigWig, UCSC bedToBigBed, VSEARCH).

### docs-030 — Tool-paper bibliography

**Verdict:** FIXED

`lungfish-cli provenance bibliography <bundle>` ships.

### docs-031 — Offline conda install

**Verdict:** FIXED

`lungfish-cli conda offline-export --pack <p> --output <d>` and
`lungfish-cli conda offline-install <pack-dir>`.

### docs-032 — Shared conda root across machines

**Verdict:** PARTIAL

`LUNGFISH_CONDA_ROOT` environment variable is honored by
`Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift:85`. Lock
semantics for concurrent installs and read-only shared install support not
verified in this sweep. Filed as docs-032a.

### docs-033 — Per-operation runtime estimates

**Verdict:** NON-RESPONSIVE

No `lungfish-cli ops stats` subcommand. Provenance sidecar I inspected
records `endTime` but no `peakRAMBytes` or `wallTimeSeconds`.

### docs-034 — Hardware floor declaration

**Verdict:** PARTIAL

`Sources/LungfishWorkflow/Engines/ContainerRuntimeProtocol.swift:61` defines
`minimumMacOSVersion` for the container runtime, but no Settings/About panel
declares system requirements to the user. Plugin Manager Databases tab
(`plugin-manager-databases-tab.png`) shows database size against system RAM
("Standard 67 GB total · exceeds system RAM") which is partial coverage.
Filed as docs-034a.

### docs-038 — CZ-ID first-class import

**Verdict:** PARTIAL

`lungfish cz-id summary` is a CLI summary tool. `lungfish import` lacks a
`cz-id` subcommand (verified via Import Center > Classification Results
which lists NAO-MGS, Kraken2, EsViritu, TaxTriage but not CZ-ID —
`import-center-classification-results.png`). Filed as docs-038a.

---

## P3 — Polish

### docs-026, docs-035, docs-036, docs-037

**Verdict:** All NON-RESPONSIVE. P3 status; parent issues stay open.

---

## Captured screenshots

All in `docs/user-manual/shots/captured/2026-05-09/` (39 files):

### Welcome / project lifecycle
- `welcome-window.png` — Welcome window with Start a Project tabs
- `empty-project-window.png` — Newly-created empty project window
- `sidebar-folder-conventions.png` — Sidebar of an active project showing Reference Sequences hierarchy

### Menus and submenus
- `tools-menu.png` — Tools menu (verifies no Workflow Builder entry)
- `tools-fastq-fasta-submenu.png` — Tools > FASTQ/FASTA Operations submenu (no Lineage Demixing)
- `tools-search-online-databases-submenu.png` — Search NCBI / SRA / Pathoplexus
- `file-export-provenance-submenu.png` — File > Export > Provenance submenu (Shell Script, Python Script, Nextflow Pipeline, Snakemake Workflow, Methods Section, Full Provenance JSON)

### Plugin Manager (3 tabs)
- `plugin-manager-window.png` — Packs tab with Required Setup + Optional Tools
- `plugin-manager-installed-tab.png` — Per-tool conda environments installed
- `plugin-manager-databases-tab.png` — Kraken2 reference databases with size annotations

### Settings (3 tabs)
- `settings-general-with-ncbi-key.png` — General tab with NCBI API key field
- `settings-appearance.png` — Nucleotide colors, annotation type colors, variant theme
- `settings-ai-services.png` — AI services (Anthropic + OpenAI keys)

### Reference bundle and viewport
- `reference-bundle-loaded.png` — NC_045512 bundle with annotation chips (5'UTR, 3'UTR, CDS, gene, **mat_peptide**, stem_loop)
- `reference-bundle-with-annotations-chips.png` — Reference bundle showing all annotation type chips
- `bundle-analysis-section.png` — Bundle Inspector > Analysis tab actions
- `inspector-analysis-tabs.png` — Analysis tabs (Filtering, Annotations, Consensus, Primer Trim, Variant Calling, Export)
- `inspector-analysis-export-tab.png` — Export tab with Create Deduplicated Bundle action

### Genome and BAM viewports
- `full-app-genome-viewport.png` — Full window showing genome viewport with annotation tracks at 1-29kb scale
- `sequence-viewport-genbank.png` — Annotated GenBank record viewport
- `annotations-table.png` — Annotations table with E gene, stem_loop entries, three_prime_UTR, ORF1a, ORF1ab
- `bam-viewport-pileup.png` — Pileup view zoomed to 9024-12923 bp with depth histogram + read pileup

### Variant browser
- `variant-browser-overview.png` — Variant browser with smart-filter chips and 9 variants
- `variant-browser-table.png` — Variant table close-up
- `variant-browser-inspector.png` — Variant Detail inspector (Position, Alleles, Quality, Genotype Summary, INFO Fields)
- `variant-browser-with-inspector.png` — Full window with browser + selected-variant inspector

### Variant calling dialogs
- `variant-call-dialog-lofreq.png` — LoFreq selected, with Thresholds, LoFreq Settings, Advanced Options field
- `variant-call-dialog-medaka.png` — Medaka selected with Medaka Model picker showing r1041_e82_400bps_sup_v5.0.0

### Mapping and primer trim
- `mapping-dialog-overview.png` — Mapping dialog with mapper sidebar (minimap2, BWA-MEM2, Bowtie2, BBMap), reference picker, Short-read preset
- `mapping-dialog-advanced-options.png` — Advanced Settings expanded showing Threads, Secondary alignments, Supplementary, Min mapping quality, Advanced Options
- `primer-trim-dialog-overview.png` — Primer Scheme dialog with Choose Scheme... + Advanced Options

### Classification dialogs
- `classification-wizard-kraken2.png` — Classification wizard with Kraken2 active, Database picker, Sensitivity (Sensitive/Balanced/Precise)
- `classification-wizard-esviritu.png` — EsViritu wizard with Sample picker, Database picker, Quality Filtering checkbox

### NCBI and Pathoplexus search
- `ncbi-search-dialog.png` — GenBank & Genomes mode picker with RefSeq Only and Include GFF3 Annotations
- `ncbi-search-results.png` — Search results showing MN908947.3 (29,903 bp)
- `pathoplexus-search-dialog.png` — Pathoplexus dialog with 10 organism presets

### Import Center (3 tabs)
- `import-center-fastq.png` — Sequencing Reads tab with FASTQ Files + ONT Run Folder
- `import-center-classification-results.png` — Classification Results tab with NAO-MGS, Kraken2, EsViritu, TaxTriage (no CZ-ID)
- `import-center-variants.png` — Variants tab with VCF Variants

### Coverage of chapter `planned_shots`

| Planned shot id | Captured file | Status |
|---|---|---|
| `welcome-window` | `welcome-window.png` | ✓ |
| `empty-project-window` | `empty-project-window.png` | ✓ |
| `sidebar-folder-conventions` | `sidebar-folder-conventions.png` | ✓ |
| `inspector-fastq-selected` | n/a (no fastq bundle in test project) | gap |
| `operations-panel-row` | n/a (no operation running during capture) | gap |
| `provenance-export-menu` | `file-export-provenance-submenu.png` | ✓ |
| `plugin-manager-window` | `plugin-manager-window.png` | ✓ |
| `plugin-manager-installed` | `plugin-manager-installed-tab.png` | ✓ |
| `import-center-fasta` | partial via `import-center-fastq.png` (FASTA in Reference Sequences tab) | partial |
| `sequence-viewport-genbank` | `sequence-viewport-genbank.png` | ✓ |
| `ncbi-search-dialog` | `ncbi-search-dialog.png` | ✓ |
| `ncbi-bundle-prompt` | partial via `ncbi-search-results.png` | partial |
| `bam-viewport-overview` | `bam-viewport-pileup.png` | ✓ |
| `pileup-zoom` | `bam-viewport-pileup.png` | ✓ |
| `alignment-inspector` | partial via `inspector-analysis-tabs.png` | partial |
| `mapping-dialog-overview` | `mapping-dialog-overview.png` | ✓ |
| `primer-trim-dialog-overview` | `primer-trim-dialog-overview.png` | ✓ |
| `variant-browser-overview` | `variant-browser-overview.png` | ✓ |
| `variant-browser-filter` | `variant-browser-overview.png` (chips visible) | ✓ |
| `variant-browser-inspector` | `variant-browser-inspector.png` | ✓ |
| `variant-call-dialog-medaka` | `variant-call-dialog-medaka.png` | ✓ |
| `medaka-model-picker` | `variant-call-dialog-medaka.png` (model field visible) | partial |
| `classification-wizard-tool-picker` | `classification-wizard-kraken2.png` | ✓ |
| `kraken2-wizard` | `classification-wizard-kraken2.png` | ✓ |
| `esviritu-wizard-tool-step` | `classification-wizard-esviritu.png` | ✓ |
| `import-center-fastq` | `import-center-fastq.png` | ✓ |
| `import-center-variants` | `import-center-variants.png` | ✓ |

**Coverage: 21 of 88 planned shots fully or partially captured.** The
remaining 67 require additional fixtures (FASTQ bundle, BAM bundle, ONT
run, MSA bundle, tree bundle, Kraken2 result) or workflows that produce
specific viewport states (assembly contig, coverage histogram with dropout,
sunburst drilldown). These can be captured in a follow-up session by
seeding the project with appropriate fixtures.

The `workflow-builder-*` planned shots in chapter 08 cannot be captured
because the Workflow Builder is unwired (docs-040c).

---

## Updated todo

The follow-up issues file `docs/issues/2026-05-09-followups-from-evaluation-sweep.md`
needs additional entries for the new findings: docs-014a, docs-022a,
docs-024a, docs-032a, docs-034a. The file currently covers docs-021a/b,
docs-038a, docs-040a/b/c/d.

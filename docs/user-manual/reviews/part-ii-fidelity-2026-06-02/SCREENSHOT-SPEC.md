# Screenshot capture spec — Part II+ user manual (2026-06-02)

This spec lists every screenshot the revised Part II+ chapters (`02-sequences`
through `08-workflows` plus `appendices`) need, in chapter nav order, grounded in
the ground-truth reality maps at
`docs/user-manual/reviews/part-ii-fidelity-2026-06-02/ground-truth/`. It is
written so the project lead can open the app once, follow the prerequisites, then
capture shots section by section from top to bottom.

You are capturing by hand. After each capture, a recipe YAML is authored so the
PNG is regeneratable. This document does not edit any chapter or frontmatter; the
caption fixes and shot removals it lists are applied in a later pass.

## How to use this spec

Each marker `<!-- SHOT: id -->` in a chapter body, and each `planned_shots:`
entry in a chapter frontmatter, becomes one PNG plus one recipe YAML.

- PNGs land at `docs/user-manual/assets/screenshots/<chapter>/<id>.png`,
  2x retina, cropped per the recipe `crop` block.
- Recipes land at `docs/user-manual/assets/recipes/<chapter>/<id>.yaml`,
  matching `docs/user-manual/build/scripts/shot/schema.json`. The runner is
  `build/scripts/run-shot.sh <plan|execute> <recipe.yaml>`.
- Every shot uses `appearance: light`. The brand surface is Cream; capture in
  Light mode so the palette matches the manual.
- Never include the macOS menu bar or Dock in any crop. Use `crop.mode: window`
  for whole-dialog and whole-viewport shots, `crop.mode: viewport` for the
  document area only, and `crop.mode: region` with an explicit `[x,y,w,h]` for a
  tight detail (for example a single table row or a sunburst wedge).
- Default window size for full-app shots is `[1600, 1000]`; for a focused dialog
  use `crop.mode: window` and let the dialog set its own size. Keep the window
  size identical between two machines so the PNG is byte-comparable modulo pixel
  noise.
- Point every recipe `fixture` at a committed fixture, never at user state.
  Never capture Recents, Spotlight, or Dock contents.

Once a planned shot is captured and its recipe exists, the chapter's
`planned_shots:` entry is promoted to an active `shots:` entry and a
`<!-- SHOT: id -->` marker is placed at the right spot in the body. Two chapters
already carry active markers (`02-sequences/04-msa-and-trees.md` and
`05-variants/01-calling-variants-from-amplicons.md`); the rest carry
`planned_shots:` only.

### Known runner limitation (read before planning a dialog shot)

The current runner action vocabulary is `open_application`, `wait_ready`,
`open_file`, `resize_window`, `scroll_to` (see `schema.json`). There is **no
`click` action and no `run_pipeline` action**. That means the runner can open the
app, open a committed fixture file, resize, and wait on a named signal, but it
**cannot click a sidebar row, press a toolbar button, or open a Tools-menu
dialog on its own**. Every shot whose target is a dialog, a popover, a wizard, a
context menu, or a viewport that only exists after a pipeline run requires the
project lead to drive the UI by hand to the target state, then trigger the
capture. Write those manual steps into the recipe as prose comments (the two
committed recipes under `assets/recipes/04-variants/` show the pattern). The
recipe's `steps:` still records the launchable prefix (open app, open fixture,
resize, wait) so the prerequisite state is reproducible; the click sequence lives
in comments until the runner grows a `click` verb.

Consequence for planning: budget hand-driving time. The PNG is captured by hand;
the recipe documents how to get back to that state.

## Prerequisites

Do these once before capturing. Everything below is needed for at least one
Priority 1 shot.

1. **Debug app build.** Build and launch `.build/debug/Lungfish` (kernel +
   leaf-module SPM build). The runner requests access only to `Lungfish`.

2. **Worked-example data in a project.** Create a project and load the committed
   chapter fixture `docs/user-manual/fixtures/sarscov2-srr36291587/`:
   - reference `MN908947.3.fasta` (Wuhan-Hu-1, 30 KB) plus `MN908947.3.gff3`
     (NCBI annotation),
   - the full SRR36291587 paired FASTQ is **not** committed; run the fixture's
     `regenerate.sh` to re-derive the FASTQ and the working `.lungfishref`
     project (it lands under `fixture-tmp/`). Several Priority 1 shots need a
     real mapped/trimmed/called bundle, which only exists after `regenerate.sh`.
   - A second committed fixture, `docs/user-manual/fixtures/sarscov2-clinical/`,
     already ships a prebuilt sorted `alignments.bam` + `.bai`, `reference.fasta`
     + `.fai`, and `variants.vcf.gz` + `.tbi`. Use it for alignment-viewport and
     variant-browser shots that do not need to show the QIASeq primer-trim story,
     because it gives a ready BAM and VCF without running the pipeline.
   - The shared `Tests/Fixtures/sarscov2/` dataset (reference MT192765.1) also
     has a paired FASTQ, sorted BAM+BAI, and VCF+TBI; prefer the manual's own
     `fixtures/` copies so on-disk paths in recipes stay inside
     `docs/user-manual/`.

3. **Plugin packs and databases** (install only what a given section needs; the
   per-section tables flag which):
   - **Kraken2 Viral database** (small, ~0.5 GB) via Plugin Manager
     (`Tools > Plugin Manager…`, Cmd-Shift-B) for the Kraken2 wizard, taxonomy
     viewport, and Kraken2-derived BLAST shots.
   - **EsViritu database** (~5 GB extracted) for the EsViritu wizard and result
     viewport.
   - **TaxTriage** requires **Nextflow + a container runtime (Docker or Apple
     Containerization)** in addition to a Kraken2 database. This is a hard
     dependency, not a footnote; `lungfish taxtriage check-prerequisites` verifies
     it. Without Nextflow+Docker the TaxTriage wizard cannot run and its result
     viewports cannot be produced from scratch.
   - **MAFFT + IQ-TREE** ship as managed tools for the MSA and tree shots.
   - **variant-calling pack** (iVar, LoFreq, Medaka, Clair3) for the Call
     Variants dialog; **bcftools** for cross-caller work is in the
     `lungfish-tools` pack, gated separately from `variant-calling`.
   - **gatk-core pack** (`isExperimental: true`, ~600 MB) only if you capture the
     GUI GATK HaplotypeCaller tool row; the human-germline chapters are otherwise
     CLI-only and need no screenshots.
   - **wastewater-surveillance pack** (Freyja) is CLI-only; no Freyja screenshot
     is requested (there is no Freyja menu item).

4. **NCBI / SRA reachability** for the live NCBI and SRA search-dialog shots
   (`02-sequences/02`, `05-variants/01`, `03-reads/02`). An `NCBI_API_KEY` in
   Settings raises rate limits but is not required to render the dialog.

5. **Provenance signing** is optional; the provenance-disclosure shot in
   `03-reads/02` reuses an existing capture (see that row).

## Reuse first: shots that likely already exist

A capture run on 2026-05-09 produced 39 PNGs at
`docs/user-manual/shots/captured/2026-05-09/`. Several planned shots map onto
those by id or by subject and should be **verified against the corrected chapter
text** rather than re-shot. The most directly reusable, with the corrections to
re-check before adopting:

| Captured PNG (2026-05-09) | Reuse for | Verify before adopting |
| --- | --- | --- |
| `ncbi-search-dialog.png`, `ncbi-search-results.png` | `02-sequences/02` ncbi-search-dialog; `05-variants/01` ncbi-search-fasta | dialog must show the **Mode** picker (Nucleotide/Genome/Virus) + RefSeq Only / Include GFF3 toggles + **Download Selected**, NOT a Format menu |
| `sequence-viewport-genbank.png` | `02-sequences/01` sequence-viewport-genbank | annotated GenBank record open; matches corrected text |
| `import-center-fastq.png` | `03-reads/01` import-center-fastq | Sequencing Reads tab, **FASTQ Files** tile, paired auto-detect |
| `import-center-variants.png` | `05-variants/06` import-center-variants | Variants tab with inferred-reference field |
| `import-center-classification-results.png` | `06-classification/05` nao-mgs-import-card; `06-classification/08` nvd-import-card | the card grid under Classification Results showing NAO-MGS and NVD cards |
| `mapping-dialog-overview.png`, `mapping-dialog-advanced-options.png` | `04-alignments/01` mapping-wizard-overview | wizard sections are Reference / Preset / Read Group / Input Compatibility / Advanced (NO Reads or Tool picker) |
| `primer-trim-dialog-overview.png` | `04-alignments/03` primer-trim-dialog-overview; `05-variants/01` primer-trim-dialog | scheme picker shows "QIAseq Direct SARS-CoV-2 with Booster A (Built-in)" |
| `variant-call-dialog-lofreq.png`, `variant-call-dialog-medaka.png` | `05-variants/04` variant-call-dialog-medaka | Medaka pane has a **free-text model field** (placeholder `r1041_e82_400bps_sup_v5.0.0`), no dropdown |
| `variant-browser-overview.png`, `variant-browser-table.png`, `variant-browser-with-inspector.png`, `variant-browser-inspector.png` | `05-variants/01` variant-browser-overview; `05-variants/02` all four | columns are `ID, Chrom, Position, Ref, Alt, Quality, Filter, Source` |
| `bam-viewport-pileup.png` | `04-alignments/02` pileup-zoom | zoomed pileup with per-read bases |
| `classification-wizard-kraken2.png`, `classification-wizard-esviritu.png` | `06-classification/01` classification-wizard-tool-picker; `02` kraken2-wizard; `03` esviritu-wizard-tool-step | wizard shows three tools only (Kraken2/EsViritu/TaxTriage); confidence default **0.2**; Sensitivity preset present |
| `plugin-manager-databases-tab.png`, `plugin-manager-installed-tab.png`, `plugin-manager-window.png` | `06-classification/02` kraken2-plugin-manager | Plugin Manager is `Tools > Plugin Manager…`, not under Settings |
| `file-export-provenance-submenu.png` | `08-workflows/02` export-provenance-submenu | submenu must show **all six** targets (Shell, Python, Nextflow, Snakemake, Methods, Full Provenance JSON) |
| `inspector-analysis-tabs.png`, `inspector-analysis-export-tab.png`, `bundle-analysis-section.png` | `04-alignments/02` alignment-inspector; `04` markdup-dialog | Analysis section button labels must match (Mark Duplicates in Bundle Tracks, Create Deduplicated Bundle, Primer-trim BAM…, Call Variants…) |

Treat every "exists-verify" row in the per-section tables below as: open the
captured PNG, compare against the corrected chapter, and if it still matches,
author a recipe pointing at it; if the corrected chapter changed the UI shown
(for example the NCBI Format menu removal), re-shoot.

The earlier `assets/recipes/04-variants/` recipes (`primer-trim-dialog.yaml`,
`variant-call-dialog.yaml`, etc.) target an **old chapter path** (`04-variants`).
The variants section is now `05-variants`. Treat those recipes as templates for
the click-prose pattern, not as final recipes for the new ids.

---

## Priority 1: screenshots for the most-changed / new chapters

These illustrate features a reader cannot otherwise picture, in chapters that
were rewritten or newly added in the three review rounds. Capture these first.

1. **`06-classification/08` Novel Virus Diagnostics (NVD) — entirely new
   chapter.** NVD had zero prior coverage and its own distinct viewport. Both
   shots (`nvd-import-card`, `nvd-result-viewport`) are NEW. The
   `nvd-result-viewport` (a contig row expanded to its secondary BLAST hits, with
   detail pane + mini-BAM) is the single most important capture for reader
   comprehension in this whole spec: it is the only way a reader can picture the
   contig-keyed NVD browser, which exists nowhere else in the manual.

2. **`05-variants/03` Cross-Caller Comparison — rebuilt premise.** The old
   chapter described an intersection/union comparison tool that does not exist.
   The corrected chapter reads two callers by eye in the **single aggregated
   variant table** (all of a bundle's variant tracks shown together, distinguished
   by the `Source` column). The four shots (`cross-caller-source-column`,
   `cross-caller-disagreement-1193`, `cross-caller-disagreement-1989`,
   `cross-caller-codon-merge-28881`) must show ONE table with a Source column, not
   any comparison view. NEW.

3. **`05-variants/05` Consensus and Lineage — repointed.** The old chapter
   documented a non-existent iVar consensus FASTA output. The corrected chapter
   points at the three real consensus surfaces: the Viral Recon Consensus caller,
   the Inspector consensus mode on an alignment track, and `lungfish msa
   consensus`. All three shots (`viralrecon-consensus-picker`,
   `inspector-consensus-mode`, `msa-consensus-cli`) are NEW.

4. **`06-classification/05` NAO-MGS — import-only, rebuilt.** The old chapter
   described running NAO-MGS in the wizard and a multi-week time-series viewport;
   neither exists. The corrected chapter is import-only with a single split-view
   table viewport. `nao-mgs-result-viewport` is NEW and important: it is the only
   picture of the real (table, not time-series) NAO-MGS viewport.

5. **`06-classification/06` BLAST Verification — rebuilt entry point and flow.**
   No BLAST tab exists; verification is a "BLAST Verify" action-bar button +
   config popover (read-count slider only) + a bottom results drawer whose
   headline is a verdict and a verification rate. `blast-verify-popover` and
   `blast-results-drawer` are NEW.

6. **`08-workflows/01` Workflow Builder — corrected palette and node set.** The
   old chapter invented categories and node types and a non-buildable
   reads-to-variants graph. The corrected chapter shows the real seven categories
   and the buildable VSP2 FASTQ chain. `workflow-builder-palette` (seven real
   category headers) and `workflow-builder-canvas` (the VSP2 chain) are NEW.

7. **`04-alignments/05` Viral Recon Wizard — corrected entry point.** Reached via
   `Tools > FASTQ/FASTA Operations > Mapping…` then the **Viral Recon tool row**,
   not a Workflows menu. `viral-recon-tool-row` and `viral-recon-wizard-overview`
   are NEW and show the only SARS-CoV-2 consensus+variant wizard.

---

## Per-section shot list

One subsection per chapter, in nav order. Columns:

- **shot id** — the id from the marker or `planned_shots:`.
- **caption (corrected)** — the caption to use; where the planned caption drifts
  from the corrected chapter, the corrected wording is given here and the fix is
  itemized under "Caption corrections needed."
- **app state + exact path** — the precise menu path / Import Center route and
  the dialog or viewport to capture, grounded in the ground-truth map.
- **fixture/sample** — what to load.
- **crop/notes** — crop mode and any capture note (including hand-drive steps).
- **status** — NEW (no usable capture), exists-verify (a 2026-05-09 PNG likely
  fits), or caption-drift-fix-needed (capture or reuse, but the planned caption
  must change).

Reach-the-dialog convention used throughout: the real op-launch pattern is
`Tools > FASTQ/FASTA Operations > <Category>…` then pick the operation in the
opened dialog; Classification is a single `Classification…` item; ONT / NVD /
NAO-MGS / CZ-ID import via the Import Center (Cmd-Shift-I). The Plugin Manager is
`Tools > Plugin Manager…` (Cmd-Shift-B), never under `Lungfish > Settings`.

### 02-sequences/01 — Importing and Viewing a Sequence

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| import-center-fasta | The Import Center with a FASTA file selected. | `Import Center…` (Cmd-Shift-I) → References category → FASTA / Reference tile, file chosen | `fixtures/sarscov2-srr36291587/MN908947.3.fasta` | window crop; hand-drive: open Import Center, choose the file | exists-verify (compare `import-center-fastq.png` is FASTQ; this is a FASTA import — likely NEW) |
| sequence-viewport-genbank | An annotated GenBank record open in the sequence viewport. | Open an annotated GenBank reference; viewport shows ruler, base track, annotation track with gene blocks | a GenBank record with annotations (the GFF3-annotated MN908947.3 bundle works) | viewport crop | exists-verify (`sequence-viewport-genbank.png`) |

### 02-sequences/02 — Downloading from NCBI

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| ncbi-search-dialog | The NCBI search dialog on the GenBank & Genomes tab with an accession searched, the Mode picker, and a record selected for Download Selected. | `Tools > Search Online Databases > Search NCBI…` opens the dialog on the **GenBank & Genomes** tab. Shows Mode picker (Nucleotide/Genome/Virus), RefSeq Only + Include GFF3 Annotations toggles, results list, and the **Download Selected** primary button | live NCBI; search `MN908947.3` | window crop; live network; hand-drive search then select a row | caption-drift-fix-needed (planned caption says "a format selected"; there is no Format menu — reword to Mode + Download Selected). Reuse `ncbi-search-dialog.png`/`ncbi-search-results.png` if they show Mode not Format |
| ncbi-bundle-prompt | The reference import result for an annotated GenBank record. | After Download Selected on a nucleotide/virus record, the produced `.lungfishref` bundle (download builds the bundle in one action; there is no separate import step) | live NCBI | window or sidebar region crop | NEW (verify against corrected one-step download text) |

### 02-sequences/03 — Extracting and Comparing Sequences

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| extract-region-dialog | The Extract Sequence dialog with its Destination radio group and Name field. | With a region visible in the sequence viewport, `Sequence > Extract Visible Region…` (Cmd-Shift-E). Dialog title is **Extract Sequence**; it has only a Destination radio group and a Name field (no start/end coordinate fields), Run button | the MN908947.3 reference open, a region selected via the ruler position field first | window crop; hand-drive: select a region, then open the menu item | exists-verify-or-NEW (no captured PNG named for it; likely NEW) |

### 02-sequences/04 — Multiple Sequence Alignments and Phylogenetic Trees

Active markers already in body (`<!-- SHOT: msa-viewport -->` at line 72,
`<!-- SHOT: tree-viewport -->` at line 123).

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| msa-viewport | An MSA viewport showing aligned sequences with a column ruler. | Build an MSA via `Tools > FASTQ/FASTA Operations > Multiple Sequence Alignment…` (MAFFT; the picker is **Strategy**, default Auto), open the resulting MSA bundle | a few related FASTA records (for example several SARS-CoV-2 genomes) to align with MAFFT | viewport crop | NEW |
| tree-viewport | A phylogenetic tree viewport showing a rectangular tree with annotated tips. | From the MSA viewport context menu choose **Build Tree with IQ-TREE…** (opens "Phylogenetic Tree Operations"; enable Ultrafast Bootstrap if support values are wanted), then open the resulting tree bundle | the MSA bundle from the previous shot | viewport crop | NEW |

### 03-reads/01 — Importing FASTQ Reads

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| import-center-fastq | The Import Center Sequencing Reads tab with the FASTQ Files tile and paired files auto-detected. | `Import Center…` (Cmd-Shift-I) → **Sequencing Reads** category → **FASTQ Files** tile, two paired files chosen, paired auto-detect shown | SRR36291587 paired FASTQ (after `regenerate.sh`) or `fixtures/sarscov2-clinical/reads_R1/R2.fastq.gz` | window crop | exists-verify (`import-center-fastq.png`) |
| sidebar-after-import | The sidebar after a paired-end import, showing the new bundle under Imports. | Project sidebar after the import completes; the `.lungfishfastq` bundle appears under `Imports/` | same | sidebar region crop | NEW |
| fastq-viewport-sparklines | The FASTQ viewport showing per-file QC sparklines and the metadata drawer. | Click the imported FASTQ bundle; the FASTQ viewport shows per-file QC sparklines | same | viewport crop | NEW |
| inspector-sample-metadata | The Inspector with sample metadata fields editable for a selected FASTQ bundle. | Select the FASTQ bundle, open the Inspector, show the editable Sample Metadata section | same | window or Inspector region crop | NEW |

### 03-reads/02 — Downloading Reads from the SRA

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| sra-search-results | The SRA search dialog showing search results with run accessions. | `Tools > Search Online Databases > Search SRA…` opens the dialog on the **SRA Runs** tab; search and show result rows | live NCBI; search `SRR36291587` or a study term | window crop; live network | NEW |
| sra-operations-record | The Operations Panel row for an SRA download, with the provenance disclosure expanded. | Operations Panel (Cmd-Shift-P), an SRA download row expanded to show provenance | reuse an existing provenance-disclosure capture if available | window or region crop | exists-verify (an existing foundations provenance shot may substitute; otherwise NEW) |

### 03-reads/03 — Quality Control for Reads

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| fastq-qc-charts | The FASTQ viewport QC charts: per-base quality, length distribution, and GC content. | Run `Tools > FASTQ/FASTA Operations > QC & Reporting…` then pick **Refresh QC Summary** in the dialog; open the FASTQ viewport's QC charts | SRR36291587 FASTQ bundle | viewport crop; hand-drive the QC run first | NEW |

### 03-reads/04 — Trimming and Filtering Reads

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| trimming-dialog | The combined fastp Adapter + Quality Trim operation selected in the Trimming & Filtering dialog, with default parameters. | `Tools > FASTQ/FASTA Operations > Trimming & Filtering…` then select **fastp Adapter + Quality Trim** in the dialog's operation list (defaults: threshold 20, window 4, cut-right) | any FASTQ bundle selected in the sidebar | window crop; hand-drive: open category dialog, select the op | NEW |

### 03-reads/05 — Decontaminating Reads

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| human-scrub-dialog | The Remove Human Reads operation in the Decontamination dialog, with the managed deacon-panhuman database. | `Tools > FASTQ/FASTA Operations > Decontamination…` then select **Remove Human Reads** (Deacon; managed database `deacon-panhuman`) | any FASTQ bundle; deacon-panhuman database installed | window crop; hand-drive | NEW |

### 03-reads/06 — Subsetting and Extraction

No planned shots. The corrected chapter is prose + CLI only (the panes are single
Query/Pattern fields, not file pickers); no screenshot is requested. **None.**

### 03-reads/07 — Oxford Nanopore Runs

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| ont-import-dialog | The Import Center ONT Run Folder tile with a barcoded run directory selected. | `Import Center…` (Cmd-Shift-I) → **Sequencing Reads** category → **ONT Run Folder** tile, a run directory chosen. (There is NO `File > Import ONT Run` menu item.) | a small ONT run folder with a couple of barcode subfolders | window crop | NEW (caption already corrected to the Import Center route) |

### 04-alignments/01 — Mapping Reads to a Reference

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| mapping-tool-picker | The FASTQ/FASTA Operations dialog, Mapping category, with the minimap2 tool row selected. | `Tools > FASTQ/FASTA Operations > Mapping…`; the dialog's tool list shows the mappers; select the minimap2 row | a FASTQ bundle + reference selected | window crop | exists-verify-or-NEW (the captured mapping shots are the wizard, not the tool list; likely NEW) |
| mapping-wizard-overview | The mapping wizard with Reference and Preset filled in and the Input Compatibility readout reporting a compatible match. | After selecting minimap2, the wizard opens with sections **Reference / Preset / Read Group / Input Compatibility / Advanced** (no Reads picker, no Tool picker). Preset display names: Short-read, Oxford Nanopore, PacBio HiFi, etc. | SRR36291587 FASTQ + MN908947.3 reference | window crop | exists-verify (`mapping-dialog-overview.png`); confirm sections match |

### 04-alignments/02 — Reading an Alignment

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| bam-viewport-overview | The BAM viewport showing reads stacked on the reference with a strand-split coverage track. | Click an alignment track in the sidebar. Coverage renders as a forward/reverse stacked area at zoom (not a single histogram). Strand colour is one of several colour modes | `fixtures/sarscov2-clinical/alignments.bam` adopted onto `reference.fasta`, or the mapped SRR36291587 BAM | viewport crop | NEW |
| pileup-zoom | Zoomed pileup view at a single position showing per-read base calls. | Zoom in (Cmd-= / Cmd-+ / Cmd-keypad-plus, or Arrow Up; bare `=` does NOT zoom) to a single position; show per-read bases | same | region or viewport crop | exists-verify (`bam-viewport-pileup.png`) |
| alignment-inspector | The Inspector for an alignment track, with aggregate stats and the Analysis section. | Select the alignment track, open Inspector; Analysis section lists Primer-trim BAM…, Call Variants…, Mark Duplicates in Bundle Tracks, Create Deduplicated Bundle, Create Filtered Alignment, Convert Mapped Reads to Annotations, Extract Consensus… | same | Inspector region or window crop | exists-verify (`inspector-analysis-tabs.png` / `bundle-analysis-section.png`) |

### 04-alignments/03 — Primer Trimming a BAM

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| primer-trim-dialog-overview | The Primer-trim BAM dialog with the QIAseq Direct SARS-CoV-2 (Booster A, Built-in) scheme selected. | `Inspector > Analysis > Primer-trim BAM…` (the only BAM-level entry; the Trimming & Filtering menu primer-trim is the FASTQ-level trim, a different feature). iVar engine; fields Minimum read length after trim, Minimum quality, Sliding window width, Primer offset | a mapped SRR36291587 BAM; built-in QIAseq scheme | window crop | exists-verify (`primer-trim-dialog-overview.png`); confirm scheme display name |
| primer-trim-track-result | The primer-trimmed alignment track in the sidebar, with soft-clip ticks visible at amplicon ends in the viewport. | After the trim runs, a new track lands in `alignments/primer-trimmed`; primer ends are **soft-clipped** (lighter ticks, reads keep length), not hard-clipped/removed | the trimmed BAM (after running primer-trim) | sidebar + viewport region crop | NEW |

### 04-alignments/04 — Alignment Quality

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| inspector-alignment-stats | Inspector pane showing mean coverage, mapped reads, and flagstat-style counts for an alignment track. | Select the alignment track, open Inspector aggregate stats | clinical fixture BAM or mapped SRR36291587 | Inspector region crop | exists-verify (overlaps alignment-inspector; may reuse) |
| coverage-histogram-uniform | BAM viewport coverage track for a well-tiled amplicon BAM, showing roughly even depth. | BAM viewport on a primer-trimmed amplicon BAM with even tiling | trimmed SRR36291587 BAM | viewport region crop | NEW |
| coverage-histogram-dropout | BAM viewport coverage track with amplicon-edge dropouts visible as gaps. | BAM viewport on a BAM with a couple of dropout regions | a BAM exhibiting dropouts (may need a constructed fixture) | viewport region crop | NEW (data-dependent; confirm a fixture shows dropouts) |
| markdup-dialog | The Inspector Analysis section showing the Mark Duplicates in Bundle Tracks and Create Deduplicated Bundle buttons. | Inspector Analysis section; note the button is **bundle-wide** (Mark Duplicates in Bundle Tracks), not per-track | any alignment bundle | Inspector region crop | exists-verify (`bundle-analysis-section.png`) |

### 04-alignments/05 — Viral Recon Wizard (SARS-CoV-2)

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| viral-recon-tool-row | The FASTQ/FASTA Operations dialog, Mapping category, with the Viral Recon tool row selected. | `Tools > FASTQ/FASTA Operations > Mapping…`; select the **Viral Recon** tool row (it lives under Mapping, NOT a Workflows menu) | a FASTQ bundle selected | window crop | NEW (Priority 1) |
| viral-recon-wizard-overview | The Viral Recon wizard with FASTQ inputs, SARS-CoV-2 reference, a primer scheme, callers, and executor selected. | The wizard header reads "Viral Recon — SARS-CoV-2 consensus and variant analysis"; reference modes SARS-CoV-2 Genome (MN908947.3) or Local FASTA; a SARS-CoV-2 primer scheme is required; variant/consensus callers iVar/BCFtools; executor Docker default | SRR36291587 FASTQ + built-in QIAseq scheme + Docker | window crop | NEW (Priority 1) |

### 05-variants/01 — Calling Variants from Amplicon Reads

Active markers in body (lines 108–190). This is the worked-example chapter; most
of its shots overlap other chapters' planned shots and several already exist.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| ncbi-search-fasta | Searching NCBI for the SARS-CoV-2 reference sequence. | `Tools > Search Online Databases > Search NCBI…`, GenBank & Genomes tab, search MN908947.3, Mode = Nucleotide | live NCBI | window crop | exists-verify (`ncbi-search-dialog.png`); confirm Mode not Format |
| ncbi-search-gff3 | Downloading the matching GFF3 annotations from NCBI. | Same dialog with **Include GFF3 Annotations** toggle on before Download Selected (the GFF3 is fetched and attached) | live NCBI | window region crop | caption-drift-fix-needed (the GFF3 comes from the Include-GFF3 toggle, not a separate GFF3 search; confirm wording) |
| sra-search-dialog | Downloading SRR36291587 reads from the SRA. | `Tools > Search Online Databases > Search SRA…`, SRA Runs tab, search SRR36291587 | live NCBI | window crop | exists-verify (overlaps `03-reads/02` sra-search-results) |
| mapping-dialog | Mapping reads to MN908947.3 with minimap2. | Mapping wizard (via `Mapping…` → minimap2 row), Reference = MN908947.3, Preset = Short-read | SRR36291587 + MN908947.3 | window crop | exists-verify (`mapping-dialog-overview.png`) |
| primer-trim-dialog | Primer-trimming the alignment with the QIAseq Direct SARS-CoV-2 (Booster A) scheme. | `Inspector > Analysis > Primer-trim BAM…`, built-in QIAseq scheme | mapped SRR36291587 BAM | window crop | exists-verify (`primer-trim-dialog-overview.png`) |
| variant-call-dialog-ivar | The Call Variants dialog with iVar selected against the trimmed alignment. | `Inspector > Analysis > Call Variants…`; in the tool sidebar (seven entries: LoFreq default, iVar, Medaka, bcftools, Clair3, GATK HaplotypeCaller, GATK + WhatsHap Phased) click **iVar**. Shared Thresholds = Minimum Allele Frequency 0.05 / Minimum Depth 10; iVar Options = consensus AF 0.75, merge AF distance 0.25, min ALT quality 20, "Ignore strand bias (recommended for amplicons)" on | trimmed SRR36291587 BAM (needs `regenerate.sh`) | window crop; hand-drive sidebar+button; recipe template exists at `assets/recipes/04-variants/variant-call-dialog.yaml` | NEW (old recipe targets old chapter path) |
| variant-browser-overview | The variant browser showing the iVar VCF track over the reference genome. | Open the called iVar variant track; table columns `ID, Chrom, Position, Ref, Alt, Quality, Filter, Source` | called iVar VCF on the bundle, or clinical fixture VCF | window crop | exists-verify (`variant-browser-overview.png`) |
| variant-browser-codon-merge | Position 28881 in the variant browser, where iVar collapsed three SNPs into one row (REF GG, ALT AA). | Variant browser scrolled to position 28881; the merged row shows REF GG / ALT AA (the protein consequence is NOT in INFO; any AA label is re-derived by the Inspector against the GFF) | iVar VCF from the fixture (`ivar.expected.vcf` shows the 28881-28883 merge) | region crop on the row | NEW |

### 05-variants/02 — Reading the Variant Browser

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| variant-browser-overview | The variant browser with the genome track on top and the ID, Chrom, Position, Ref, Alt, Quality, Filter, and Source columns in the table. | Click a variant track; the bundle browser is the annotation-table drawer with those eight columns (plus dynamically promoted INFO columns and a GT genotype sub-tab) | clinical fixture VCF or called iVar VCF | window crop | exists-verify (`variant-browser-overview.png`/`variant-browser-table.png`) |
| variant-browser-filter | The variant table filter bar with the PASS smart-filter chip selected. | Filter bar; tap the **PASS** smart token. (Curated tokens include PASS, SNV, Indel, High Impact, Qual >= 30, DP >= 10, etc.; there is no `AF >= 0.5` or `Coding` chip) | same | region crop on the filter bar + a few rows | NEW |
| variant-browser-inspector | The Inspector showing the INFO and FORMAT payload for a selected variant row. | Select a row; Inspector shows INFO/FORMAT. For iVar rows, allele depth/frequency are FORMAT fields (ALT_FREQ etc.), INFO carries only TYPE | same | window or Inspector region crop | exists-verify (`variant-browser-inspector.png`/`variant-browser-with-inspector.png`) |
| variant-browser-source-column | A bundle with two variant tracks aggregated into one table, with the Source column distinguishing the iVar and LoFreq rows. | A bundle that has both an iVar and a LoFreq track; the browser aggregates all variant tracks automatically; the Source column shows the per-row source file | bundle with both `ivar.expected.vcf` and `lofreq.expected.vcf` imported/called | window crop | NEW (shared with cross-caller; capture once) |

### 05-variants/03 — Reading Two Callers in One Table (cross-caller)

All NEW; Priority 1. Capture the aggregated single table, never a comparison view.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| cross-caller-source-column | The aggregated variant table on a bundle with iVar and LoFreq tracks, sorted by Position, with the Source column distinguishing the rows. | One table aggregating both tracks; sort by Position; Source column visible | bundle with both iVar + LoFreq tracks | window crop | NEW |
| cross-caller-disagreement-1193 | Position 1193 in the variant table: an iVar row with no matching LoFreq row at the same coordinate. | Same table scrolled to position 1193 | same | region crop | NEW (confirm the fixture VCFs actually disagree at 1193) |
| cross-caller-disagreement-1989 | Position 1989 in the variant table: a LoFreq row with no matching iVar row at the same coordinate. | Same table scrolled to position 1989 | same | region crop | NEW (confirm fixture disagreement) |
| cross-caller-codon-merge-28881 | The 28881 neighbourhood: one merged iVar GG-to-AA row and a 28883 row alongside three single-base LoFreq rows. | Same table scrolled to 28881-28883 | both fixture VCFs (`ivar.expected.vcf` merges the trio; `lofreq.expected.vcf` keeps singles) | region crop | NEW |

### 05-variants/04 — Nanopore Variant Calling

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| variant-call-dialog-medaka | The Call Variants dialog with Medaka selected and the empty model field showing its placeholder. | `Inspector > Analysis > Call Variants…`, click **Medaka** in the tool sidebar. The Medaka pane has a single **free-text model field** (placeholder `r1041_e82_400bps_sup_v5.0.0`), no dropdown, no min-mapq/region fields; the field starts empty | any eligible BAM | window crop | exists-verify (`variant-call-dialog-medaka.png`); confirm it shows the empty free-text field |
| medaka-model-field | The free-text Medaka model field with a basecaller model string typed in and the Run button enabled. | Same dialog with a model string typed; Run enables only once the field is non-empty (Medaka and Clair3 share this one field) | same | region crop on the field + Run button | NEW |

### 05-variants/05 — Consensus and Lineage

All NEW; Priority 1. There is no iVar consensus output; these are the three real
consensus surfaces.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| viralrecon-consensus-picker | The Viral Recon wizard with the Consensus caller picker set, the only reads-to-consensus-FASTA path in Lungfish. | `Tools > FASTQ/FASTA Operations > Mapping…` → Viral Recon tool row → wizard; show the Consensus caller picker (iVar / BCFtools) | SRR36291587 FASTQ + scheme + Docker | window or region crop | NEW |
| inspector-consensus-mode | The Inspector consensus controls on an alignment track: consensus mode, IUPAC ambiguity, gap masking, and the depth and quality minimums. | Select an alignment track; the Inspector consensus controls expose consensus mode, IUPAC ambiguity, gap masking, min depth, min mapQ, min baseQ (backed by `samtools consensus` over the region) | clinical fixture BAM or mapped SRR36291587 | Inspector region crop | NEW |
| msa-consensus-cli | A lungfish msa consensus run writing a consensus FASTA from an aligned bundle with an explicit threshold. | A terminal/text capture of `lungfish msa consensus` output (CLI surface). If captured as an app shot, show the MSA viewport's "Create consensus FASTA" action instead | an MSA bundle | terminal/region crop (CLI) | NEW (CLI shot; may be a code block rather than a PNG — confirm with Lead) |

### 05-variants/06 — Importing Existing VCFs

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| import-center-variants | The Variants tab of the Import Center, with a chosen VCF and the inferred reference bundle shown. | `Import Center…` (Cmd-Shift-I) → **Variants** tab; choose a VCF; the inferred-reference field and alias matching (e.g. NC_045512.2 → MN908947.3) appear. (Note: reference inference + bgzip/index is GUI-only; the CLI `import vcf` only copies+summarizes) | `fixtures/sarscov2-clinical/variants.vcf.gz` or `Tests/Fixtures/sarscov2/test.vcf` | window crop | exists-verify (`import-center-variants.png`) |
| imported-vcf-track-sidebar | The sidebar after a successful VCF import, with the new variant track nested under its matched reference bundle. | Project sidebar after import; the variant track sits under the matched `.lungfishref` | same | sidebar region crop | NEW |

### 06-classification/01 — What Is Read Classification

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| classification-wizard-tool-picker | The Classification wizard with its three runnable tools visible: Kraken2, EsViritu, and TaxTriage. | `Tools > FASTQ/FASTA Operations > Classification…`; the wizard tool picker shows exactly three runnable tools (NAO-MGS/NVD/CZ-ID are import-only and not in the wizard) | a FASTQ bundle selected | window crop | exists-verify (`classification-wizard-kraken2.png` shows the wizard; confirm three tools) |
| taxonomy-viewport-overview | A Kraken2 taxonomy viewport showing the side-by-side sunburst and per-taxon table with the breadcrumb bar. | After a Kraken2 run, the `TaxonomyViewController` is a side-by-side split (Sunburst Chart \| Taxonomy Table) with a breadcrumb. Only Kraken2 and imported CZ-ID use this sunburst viewport | SRR36291587 classified with Kraken2 Viral DB | window crop | NEW |

### 06-classification/02 — Running Kraken2

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| kraken2-wizard | The Classification wizard with Kraken2 selected, showing the database picker, the Sensitivity preset, and the FASTQ bundle input. | `Classification…` wizard, Kraken2 selected; controls include Database picker, **Sensitivity preset** (Sensitive/Balanced/Precise, default Balanced), Confidence (default **0.2**), Minimum hit groups (default 2) | SRR36291587 FASTQ + Kraken2 Viral DB | window crop | exists-verify (`classification-wizard-kraken2.png`); confirm Sensitivity preset + 0.2 default |
| kraken2-plugin-manager | Plugin Manager with the Kraken2 Viral database listed as installed. | `Tools > Plugin Manager…` (Cmd-Shift-B), Databases tab, Kraken2 Viral row installed (NOT under Settings) | Kraken2 Viral DB installed | window crop | exists-verify (`plugin-manager-databases-tab.png`) |
| kraken2-taxonomy-viewport | Taxonomy viewport after classifying SRR36291587, with the side-by-side sunburst and table and Riboviria highlighted. | The sunburst+table split after the run; highlight a Riboviria wedge | classified SRR36291587 | window crop | NEW (shares subject with taxonomy-viewport-overview) |
| kraken2-drilldown-coronaviridae | Sunburst drilled into Coronaviridae after a click, with the breadcrumb bar showing the path. | Click a wedge to drill into Coronaviridae; breadcrumb updates | same | window or region crop; hand-drive the drilldown | NEW |
| kraken2-extract-reads | Right-click menu on a taxon row, with Extract Reads as FASTQ Bundle selected. | Right-click a taxon table row; show the context menu with **Extract Reads as FASTQ Bundle** | same | region crop; hand-drive the context menu | NEW |

### 06-classification/03 — Running EsViritu

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| esviritu-wizard-tool-step | The run wizard with EsViritu chosen as the tool. | `Classification…` wizard, EsViritu selected; the EsViritu pane exposes only **Min Read Length** (default 100) and a quality-filter toggle (no breadth/read-count fields) | a FASTQ bundle + EsViritu DB | window crop | exists-verify (`classification-wizard-esviritu.png`); confirm only Min Read Length + QC toggle |
| esviritu-database-missing | The wizard's inline notice when the EsViritu database has not yet been installed. | Same wizard with EsViritu DB uninstalled; the inline "database not installed" notice shows | EsViritu DB NOT installed | window or region crop | NEW |
| esviritu-result-viewport | The EsViritu result viewport showing per-virus coverage sparklines for SRR36291587. | After an EsViritu run, the table-based viewport (`ViralDetectionTableView`) with per-virus coverage; columns include reads, uniqueReads, rpkmf, coverage (breadth %) | SRR36291587 classified with EsViritu | window crop | NEW |
| esviritu-mini-bam | The mini-BAM preview that appears in the detail pane for a selected virus row. | Select a virus row; the mini-BAM appears **automatically** in the detail pane (no "Show reads" button) | same | region crop | NEW |

### 06-classification/04 — Running TaxTriage

Requires Nextflow + Docker. If that runtime is unavailable, these four cannot be
captured from scratch; flag to Lead.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| taxtriage-wizard-tool-step | The run wizard with TaxTriage selected and a multi-sample batch loaded. | `Classification…` wizard, TaxTriage selected. Fields: Kraken2 Database picker, Sequencing Platform (Illumina/ONT/PacBio), Skip-assembly (default on), Skip-Krona, Advanced (k2 confidence 0.2, top hits 10, max memory 16 GB, CPUs). There is **no profile picker** | a multi-sample FASTQ batch; Kraken2 DB + Nextflow + Docker | window crop | NEW (caption-drift: planned text elsewhere implies profiles; none exist) |
| taxtriage-result-table | The TaxTriage result table, with organisms ranked by TASS score and a compact confidence bar. | After a run, the organism table shows **TASS** scores and a confidence bar column using the >=0.8 / 0.4-0.8 / <0.4 tiers. | classified batch | window crop | NEW |
| taxtriage-batch-overview | The batch overview showing per-sample organism calls across a four-sample run. | `TaxTriageBatchOverviewView` tab | four-sample batch | window crop | NEW |
| taxtriage-batch-export | The cross-sample organism matrix written by the batch exporter. | The exporter (reached from the viewport action bar, NOT a File-menu item) writes a cross-sample organism-matrix CSV; show the CSV or the export action. No PDF, no templates | exported CSV from a batch | region/text crop | NEW (caption-drift: no PDF/template export) |

### 06-classification/05 — Importing NAO-MGS Results

Priority 1. Import-only; no run wizard, no time-series viewport.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| nao-mgs-import-card | The Import Center card for NAO-MGS Results under Classification Results. | `Import Center…` (Cmd-Shift-I) → **Classification Results** tab → **NAO-MGS Results** card (attributed to SecureBio). The importer needs only a results location containing `virus_hits_final.tsv(.gz)` | a NAO-MGS results folder with that TSV | window or card region crop | exists-verify (`import-center-classification-results.png` shows the card grid) |
| nao-mgs-result-viewport | The NAO-MGS taxon viewport: detail pane on the left, taxon table on the right. | After import, `NaoMgsResultViewController` is a single-import split (detail pane \| taxon table) with columns Sample, Taxon, Hits, Unique Reads, Refs, plus a per-accession coverage sparkline. NO multi-week chart | imported NAO-MGS results | window crop | NEW (Priority 1) |

### 06-classification/06 — BLAST Verification

Priority 1. No BLAST tab; action-bar button + popover + bottom drawer.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| blast-verify-popover | The Verify-via-NCBI-BLAST popover with the Reads to submit slider and the Run BLAST button. | In a classifier viewport (Kraken2/EsViritu/TaxTriage/NAO-MGS), click the **BLAST Verify** button in the action bar (or a row's "BLAST Verify…" context item). The popover title is `Verify "<taxon>" via NCBI BLAST` and has a single **Reads to submit** slider (default 20, range 1-50) and a **Run BLAST** button. There is no database selector and no representative-read picker | a Kraken2 result with a taxon selected; live NCBI | popover region crop; hand-drive | NEW (Priority 1) |
| blast-results-drawer | The BLAST results drawer showing the verdict, the verification rate, and the per-read hit rows. | After Run BLAST, results appear in a **bottom drawer**: a headline **verdict** (supported/unsupported/mixed/inconclusive) and **verification rate**, then per-submitted-read parent rows each with up to ~5 child hits (Status, Read ID, Organism, Identity, E-value, Bit score, Accession, Coverage, Align Length, Tax ID, Verdict), plus Open in NCBI BLAST / Re-run BLAST buttons | same; live NCBI | window crop | NEW (Priority 1) |

### 06-classification/07 — Importing CZ-ID Results

No planned shots; the corrected chapter is the most accurate in the section and
requests none. **None.**

### 06-classification/07 — Running Freyja

No planned shots; Freyja is CLI-only with no menu item, and the chapter is honest
that it runs from the CLI. **None.**

### 06-classification/08 — Novel Virus Diagnostics (NVD)

Priority 1; new chapter. The `nvd-result-viewport` is the single most important
capture in this spec.

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| nvd-import-card | The Import Center card for NVD Results under Classification Results. | `Import Center…` (Cmd-Shift-I) → **Classification Results** tab → **NVD Results** card (source: Novel Virus Diagnostics Snakemake pipeline; parses `*_blast_concatenated.csv(.gz)`) | an NVD results folder | window or card region crop | exists-verify (`import-center-classification-results.png` shows the card grid; confirm NVD card present) |
| nvd-result-viewport | The NVD viewport: a contig row expanded to its secondary BLAST hits, with the detail pane and mini-BAM on the left. | After import, `NvdResultViewController` is a contig-keyed browser (best-hit contig rows expandable to secondary BLAST hits), distinct from the sunburst taxonomy viewport | imported NVD results | window crop; hand-drive: expand a contig row | NEW (Priority 1, highest-value shot) |

### 06-human-germline-variants/01–04 — GATK chapters

These four chapters are CLI-first and carry **no `planned_shots:`**. The only GUI
surface the ground-truth map surfaces is the BAM variant-calling tool rows **GATK
HaplotypeCaller** and **GATK + WhatsHap Phased**, which are already visible in the
Call Variants tool sidebar captured for `05-variants/01`/`/04`. No new screenshot
is requested here. **None** (optional: if the Lead wants a GUI GATK shot, reuse
the Call Variants dialog with the GATK HaplotypeCaller row selected; requires the
gatk-core pack).

### 07-assembly/01 — When to Assemble

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| assembly-wizard-assembler-picker | The Assembly wizard's segmented Assembler picker (SPAdes, MEGAHIT, SKESA, Flye, Hifiasm) above the separate Read Type control. | `Tools > FASTQ/FASTA Operations > Assembly…` (single menu item; there is NO `Assembly > SPAdes` submenu). The wizard's Assembler picker is a flat segmented control of all five tools; Read Type is a separate segmented control | a FASTQ bundle selected | window crop | NEW |
| assembly-bundle-in-sidebar | An assembly bundle in the Assemblies/ folder, with contigs listed in the Inspector. | Project sidebar with an assembly `.lungfishref` under `Assemblies/`; Inspector lists contigs | a completed SPAdes assembly of SRR36291587 | sidebar + Inspector region crop | NEW |

### 07-assembly/02 — Running SPAdes (and MEGAHIT, SKESA)

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| assembly-wizard-spades | The Assembly wizard with SPAdes selected and the Isolate profile chosen. | Assembly wizard, SPAdes selected; SPAdes profiles are **Isolate / Meta / Plasmid only** (there is NO Viral mode). Optional Careful-mode toggle; Min Contig stepper (a Lungfish post-filter) | SRR36291587 FASTQ | window crop | NEW (caption-drift: ensure no "viral mode") |
| assembly-viewport | The assembly result viewport showing contigs ranked by length with N50 in the summary strip. | After the run, `AssemblyResultViewController` ranks contigs by length with N50 in the summary | completed SPAdes assembly | window crop | NEW |
| contig-inspector | Inspector pane for the longest contig showing length, coverage, and GC content. | Select the longest contig; Inspector shows length, coverage (parsed from SPAdes header `cov_…`), GC | same | Inspector region crop | NEW |

### 07-assembly/03 — Running Flye or Hifiasm

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| assembly-wizard-flye | Assembly wizard with Flye selected, an ONT FASTQ chosen as input, and the Nano HQ profile in the Profile picker. | Assembly wizard, Flye selected (ONT reads only); Profile picker = Nano HQ (default) / Nano Raw / Nano Corrected. There is NO genome-size field and NO polishing toggle (only a Metagenome toggle) | an ONT FASTQ bundle | window crop | NEW (caption-drift: no genome-size/polishing) |
| assembly-wizard-hifiasm | Assembly wizard with Hifiasm selected and a PacBio HiFi FASTQ chosen as input. | Assembly wizard, Hifiasm selected; options are Profile (Diploid / Haploid-Viral) and a Primary-only toggle. No trio-binning fields | a PacBio HiFi FASTQ bundle | window crop | NEW (caption-drift: no trio fields) |
| flye-single-contig-result | Project sidebar showing a Flye assembly bundle that contains a single full-length contig. | Project sidebar after a Flye run with one full-length contig | a completed Flye assembly (hypothetical per chapter; data-dependent) | sidebar region crop | NEW (data-dependent) |

### 07-assembly/04 — Extracting Contigs

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| create-bundle-action-bar | The assembly result action bar with three contigs selected in the table and the Create Bundle button enabled. | In the assembly result viewport, select contigs in the table; the action bar's **Create Bundle** button enables (there is NO right-click "Extract Contigs" sheet; the same bar also has BLAST Contigs / Copy FASTA / Export FASTA) | a completed assembly with several contigs | window or region crop; hand-drive selection | NEW (caption already corrected to Create Bundle) |
| derived-bundle-in-sidebar | The derived reference bundle in the project sidebar under Reference Sequences/, named with the -subset default. | After Create Bundle, the new `.lungfishref` appears under `Reference Sequences/`. Default name is `<source>-subset` (NOT `-contig1`) | same | sidebar region crop | NEW (caption-drift: name is -subset) |

### 08-workflows/01 — The Workflow Builder

Priority 1 (palette + canvas).

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| workflow-builder-canvas | The Workflow Builder canvas with the VSP2 FASTQ chain composed as connected nodes. | `Tools > Workflow Builder (Experimental)…`; build (or load the VSP2 template) the FASTQ chain input → dedup → trim → scrub → merge → length-filter → Project output. This is the one buildable, runnable graph | a project FASTQ bundle for the Sample input | window crop | NEW (Priority 1) |
| workflow-builder-palette | The operation palette showing the seven real category headers: Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, Output. | The left-edge palette; categories come from NodeCategory (the seven above). NOT Acquire/Align/Trim/Call/Profile/Assemble/Tree | same | region crop on the palette | NEW (Priority 1; caption already lists the seven real headers) |
| workflow-builder-node-inspector | A selected Adapter + quality trim node showing its parameter form in the right inspector pane. | Select the fastp trim node; the right inspector shows its real typed parameters (the generic analysis nodes only carry hidden metadata params) | same | region crop | NEW |

### 08-workflows/02 — Exporting as Nextflow or Snakemake

| shot id | caption (corrected) | app state + exact path | fixture/sample | crop/notes | status |
| --- | --- | --- | --- | --- | --- |
| export-provenance-submenu | The File > Export > Provenance submenu showing all six export targets. | `File > Export > Provenance`; the submenu lists **six** items: Shell Script, Python Script, Nextflow Pipeline, Snakemake Workflow, Methods Section, Full Provenance (JSON). (The exporter renders from a run's provenance record, not from a saved Builder graph) | a bundle with a completed run's provenance | menu region crop | exists-verify (`file-export-provenance-submenu.png`); confirm all six render |
| nextflow-export-main-nf | The generated main.nf opened in a text editor, with one process per recorded provenance step. | Run the Nextflow export, open `main.nf`; one process per provenance step. (The real config emits per-input `params.<sanitized-filename>` + `params.outdir`, and a `containers/manifest.json` is also written; there are no `standard`/`slurm` profiles) | exported Nextflow artifacts | editor window or text crop | NEW |

### Appendices

The ground-truth map for the appendices flags many text/flag corrections but the
appendix chapters carry **no `planned_shots:`** (cli-reference, file-formats,
keyboard-shortcuts, primer-schemes, tool-versions, troubleshooting,
power-user-notes, shared-projects, running-in-ci, bibliography). **No appendix
screenshots are requested.** The appendix work is prose/flag fixes, out of scope
for this capture spec.

---

## Caption corrections needed

Planned-shot captions that no longer match the corrected chapter text. The user
or a later pass edits the frontmatter; this list says what each should say.

1. **`02-sequences/02` ncbi-search-dialog.** Planned caption: "The NCBI search
   dialog with an accession entered and **a format selected**." The corrected
   chapter removed the Format menu (FASTA/GenBank/GFF3/XML is CLI-only). The GUI
   dialog has a **Mode** picker (Nucleotide/Genome/Virus), RefSeq Only and Include
   GFF3 Annotations toggles, and a **Download Selected** button. Reword to: "The
   NCBI search dialog on the GenBank & Genomes tab with an accession searched, the
   Mode picker set, and a record selected for Download Selected."

2. **`02-sequences/02` ncbi-bundle-prompt.** Planned caption: "The reference
   import result for an annotated GenBank record." The corrected chapter notes the
   download builds the `.lungfishref` in one action (no separate import step). The
   caption is acceptable but should not imply a manual import step; prefer "The
   `.lungfishref` bundle produced directly by Download Selected for an annotated
   record."

3. **`05-variants/01` ncbi-search-gff3.** Body caption: "Downloading the matching
   GFF3 annotations from NCBI." There is no separate GFF3 download/search; GFF3 is
   fetched by toggling **Include GFF3 Annotations** before Download Selected.
   Reword to: "Toggling Include GFF3 Annotations so the matching GFF3 is fetched
   and attached."

4. **`04-alignments/03` primer-trim-dialog-overview** and **`05-variants/01`
   primer-trim-dialog.** The scheme display name is "QIAseq Direct SARS-CoV-2 with
   Booster A (Built-in)", not "QIASeqDIRECT-SARS2". If the caption names the
   scheme, use the display name (with Booster A).

5. **`05-variants/04` variant-call-dialog-medaka.** Planned caption already says
   "the empty model field showing its placeholder" — correct. Ensure the capture
   shows a **free-text field**, never a dropdown; the old chapter's "Basecaller
   model dropdown" is gone.

6. **`06-classification/03` esviritu-strain-comparison** (if present anywhere in
   the body or an older frontmatter copy). The EsViritu strain-comparison feature
   does not exist. See "Shots to remove."

7. **`06-classification/04` taxtriage shots.** Any caption mentioning a clinical /
   research / wastewater **profile picker** is wrong (no profile picker exists).
   Any caption mentioning a **PDF** report or export **templates** is wrong (the
   exporter writes a cross-sample CSV + text summary only, from the viewport
   action bar). The four current `planned_shots` captions are clean, but verify no
   profile/PDF wording leaks in.

8. **`07-assembly/02` assembly-wizard-spades.** The caption already says "Isolate
   profile" — correct. Ensure no "viral mode" wording appears (SPAdes has no
   `--viral`; profiles are Isolate/Meta/Plasmid only).

9. **`07-assembly/03` assembly-wizard-flye.** Caption is fine as written, but the
   chapter body must not promise a genome-size field or a polishing toggle (the
   wizard has neither; only a Metagenome toggle and the Nano HQ/Raw/Corrected
   Profile picker). The shot must not be staged to show a genome-size control.

10. **`07-assembly/03` assembly-wizard-hifiasm.** The shot must not show
    trio-binning fields (none exist); options are the Profile picker
    (Diploid/Haploid-Viral) and a Primary-only toggle.

11. **`07-assembly/04` derived-bundle-in-sidebar.** Planned caption: "named after
    the selected contig." The default name is `<source>-subset`, not a
    `-contig1`/`-contig1+2` tag. Reword to: "named with the `-subset` default."

12. **`08-workflows/02` export-provenance-submenu.** Planned caption already says
    "all six export targets" — correct (Shell, Python, Nextflow, Snakemake,
    Methods, Full Provenance JSON). The earlier chapter claimed four; if any body
    text still says four, that is a prose fix, not a caption fix.

13. **`08-workflows/01` workflow-builder-canvas.** The caption correctly scopes to
    the **VSP2 FASTQ chain**. Do not stage the old reads-to-variants graph
    (Download reference / Map reads / Trim primers / Call variants / Annotate
    variants) — none of those node types exist and the graph is not buildable.

## Shots to remove

Planned/implied shots that reference fabricated or removed features and should be
deleted from chapter frontmatter (no capture).

1. **`06-classification/03` `esviritu-strain-comparison`.** The ground-truth map
   confirms there is no Compare control, no two-track coverage stack, and no
   unique-read bar chart in EsViritu (the only `StrainComparisonView` lives in the
   TaxTriage module and is a per-position SNP table, a different thing). If this id
   still appears in any frontmatter or body marker, delete it. The current
   `06-classification/03` frontmatter `planned_shots` does **not** list it (good);
   confirm no stale copy in the body or an older revision survives.

2. **`06-classification/05` any `nao-mgs` time-series / longitudinal shot.** The
   old chapter implied a multi-week stacked-line surveillance chart
   (`nao-mgs-result-viewport` framed as a time series). The real viewport is a
   single-import table. The current frontmatter caption for `nao-mgs-result-viewport`
   already describes the table viewport (good); ensure no separate "series" or
   "twelve weeks of influent" shot id remains anywhere. No removal needed if only
   the two current ids are present, but the **caption** must stay table-scoped.

3. **`05-variants/05` any "iVar consensus output" shot.** If a prior revision had
   a shot of a `.consensus.fa` second output in the Operations Panel or a
   `File > Export > Consensus FASTA` menu, delete it; that output does not exist.
   The current three `planned_shots` (viralrecon-consensus-picker,
   inspector-consensus-mode, msa-consensus-cli) are the correct replacements and
   need no removal.

4. **No other removals.** All other current `planned_shots:` and `shots:` entries
   point at real, capturable UI once the prerequisites are installed.

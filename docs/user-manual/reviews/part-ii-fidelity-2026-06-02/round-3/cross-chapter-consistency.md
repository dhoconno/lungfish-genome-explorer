# Round 3 cross-chapter consistency audit

Scope: all chapters under `docs/user-manual/chapters/` in `02-sequences`,
`03-reads`, `04-alignments`, `05-variants`, `06-classification`,
`06-human-germline-variants`, `07-assembly`, `08-workflows`, and `appendices`.
Method: read every chapter in full, then compared each tool/menu/CLI/dialog/
output description against the same description in other chapters, using the
ground-truth maps in `../ground-truth/*.md` as the arbiter. Live-binary checks
were run against `.build/debug/lungfish-cli` where a CLI signature was in
dispute. No chapter files were edited.

Headline: the section is in good shape after two revision rounds. The recurring
pre-revision errors (4-level menu paths, soft-clip-vs-hard-clip, three-vs-five
callers, three-vs-four classifiers, Plugin Manager under `Lungfish > Settings`,
ARTIC-vs-QIAseq for the SRR36291587 fixture, the `lungfishtax` "universal
classifier bundle" claim) are now resolved and internally consistent across
chapters. What remains is a smaller set of cross-chapter contradictions
concentrated in two places: (1) the `05-variants` worked-example chapter still
describes the NCBI download and the Mapping dialog the old way, out of step with
the dedicated chapters that own those features; and (2) the `appendices/cli-reference.md`
lookup table disagrees with the body chapters (and the binary) on a few command
signatures. Each finding below names at least two locations and states the
correct form per ground truth.

---

## Must-fix inconsistencies

### 1. NCBI download described two contradictory ways (a "Format" menu that does not exist)

The dedicated NCBI chapter and the variant-calling worked example disagree on
the entire shape of the NCBI download flow.

- **`05-variants/01-calling-variants-from-amplicons.md:104`** (and `:106`): "Leave
  `Format` set to `FASTA` and click `Download`. The dialog closes when the FASTA
  file lands in the project's `Downloads/` folder. Lungfish then prompts you to
  make a reference bundle out of it." Step 2 then sets `Format` to `GFF3` for a
  second download and walks a separate `Create Bundle` prompt (`:112`).
- **`02-sequences/02-downloading-from-ncbi.md:53-64`** (the chapter that owns this
  feature): "The GUI has no four-way file-format menu." It documents a **Mode**
  picker (Nucleotide/Virus/Genome) plus an **Include GFF3 Annotations** toggle,
  the primary button toggling **Search -> Download Selected**, and "There is no
  separate import step in the GUI. The download produces the bundle directly"
  (`:78`).

Correct per ground truth (`ground-truth/02-sequences.md`, ch02 items 1-4): the
GUI has no FASTA/GenBank/GFF3/XML "Format" menu (that is the CLI `--fetch-format`
concept only), the control is a **Mode** picker plus an **Include GFF3
Annotations** checkbox, the button is **Download Selected** (never "Download"),
and the GUI builds the `.lungfishref` in one action with no "Create Bundle"
prompt. `05-variants/01` should adopt the `02-sequences/02` model (Mode +
annotation toggle + Download Selected, one-step bundle). The CLI block in
`05-variants/01:119-121` (`lungfish fetch ncbi ... --fetch-format fasta/gff3`)
is correct and can stay.

### 2. Mapping dialog has a "Reads"/"Tool" section in two chapters but not in the chapter that owns it

- **`04-alignments/01-mapping-reads-to-a-reference.md:36-41`** and **`:182-186`**
  (the chapter that owns mapping): the wizard has **no Reads picker and no mapper
  picker**; reads come from the sidebar selection, the mapper from the tool row
  you clicked, and the wizard sections are Reference / Preset / Read Group / Input
  Compatibility / Advanced Settings.
- **`05-variants/01-calling-variants-from-amplicons.md:136-138`**: "The dialog has
  three sections: `Reads`, `Reference`, and `Tool`. In the `Reads` section, click
  `Choose…` and select both FASTQ files ... In the `Tool` section, set `Mapper` to
  `minimap2`."
- **`05-variants/04-nanopore-variant-calling.md:87-89`**: "In the `Reads` section,
  choose the ONT FASTQ ... In the `Tool` section, set `Mapper` to `minimap2`."

Correct per ground truth (`ground-truth/04-alignments.md`, ch01 item 2): the
mapping wizard has no Reads picker and no Tool/Mapper picker; reads are the
sidebar selection and the mapper is the tool row clicked in the FASTQ/FASTA
Operations dialog. `04-alignments/01` is right; both `05-variants` chapters
describe a Reads/Tool dialog that does not exist and should be re-pointed to the
"select FASTQ in sidebar, click the mapper tool row" model.

### 3. Mapping track default name: "minimap2 Mapping" vs "SRR36291587 (minimap2)"

The two conventions are used as definite track names in different chapters and
never reconciled.

- **"<tool> Mapping" form** (correct): `04-alignments/01:233` ("the default
  display name \"minimap2 Mapping\" (the mapper name plus \"Mapping\")"),
  `04-alignments/02:88` ("named \"minimap2 Mapping\" by default"),
  `04-alignments/03:131` ("\"minimap2 Mapping\" by default").
- **"SRR36291587 (minimap2)" form** (invented): `05-variants/01:142` ("a fresh
  alignment track named `SRR36291587 (minimap2)`"), `:150`, and the
  auto-populated primer-trim name `SRR36291587 (minimap2) - Primer-trimmed
  (QIASeqDIRECT-SARS2)` (`:152`); `05-variants/03:78`; and
  `05-variants/04:91` (`ONT-SAMPLE-01 (minimap2 map-ont)`).

Correct per ground truth (`ground-truth/04-alignments.md`, ch01 item 3, ch02
item 2, Section-wide item 2): the GUI managed-mapping default display name is
`"<tool> Mapping"` (e.g. "minimap2 Mapping"); nothing in code generates the
`(minimap2)` / `(minimap2 sr)` parenthetical, and `04-alignments/01:56` itself
says so. The `05-variants` chapters (01, 03, 04) should use "minimap2 Mapping".
Note this is load-bearing: `05-variants/03` instructs the reader to find two
tracks by these exact invented names in the sidebar.

### 4. `lungfish bam adopt-mapping` printed without its required `--name` in one chapter

- **`04-alignments/01-mapping-reads-to-a-reference.md:254-256`** (worked-example
  shell block) prints `lungfish bam adopt-mapping --bundle "..." --mapping-result
  mapping/` with no `--name`.
- **`appendices/cli-reference.md:219-221`** and **`appendices/troubleshooting.md:78`**
  both state `--name` is **required** ("The `--name` option is required."), and
  **`05-variants/01:249-252`** correctly includes `--name "minimap2 mapping"` in
  its script.

Correct per the live binary (`bam adopt-mapping --help`: `USAGE: lungfish bam
adopt-mapping [<options>] --bundle <bundle> --mapping-result <mapping-result>
--name <name>`): `--name` is required, so the `04-alignments/01:254` block as
printed fails with a missing-required-option error. Add `--name` there to match
the appendices and `05-variants/01`. (The inline form at `04-alignments/01:256`
in "Equivalent CLI" has the same omission.)

### 5. `lungfish tree infer` documented with two different (and one wrong) signatures

- **`02-sequences/04-msa-and-trees.md:113-118`** (the chapter that owns tree
  inference) uses the correct form: `lungfish tree infer iqtree <bundle>
  --project . --output S-gene-10-isolates.lungfishtree --model MFP --bootstrap
  1000`.
- **`appendices/cli-reference.md:567`** (the canonical CLI lookup) prints
  `lungfish tree infer --msa <path> --out <path>`.

Correct per the live binary (`tree infer --help`: `USAGE: lungfish tree infer
iqtree [<options>] <msa-bundle-path> --project <project> --output <output>`):
there is no `--msa` and no `--out` flag, the `iqtree` subcommand is required, and
`--project` is mandatory. The body chapter is right; the cli-reference entry is
wrong and contradicts both the body chapter and the binary.

### 6. `lungfish import` documented as taking a bare path in the appendix, but requiring a subcommand in the body

- **`02-sequences/01-importing-and-viewing.md:112-115`** uses the correct form:
  `lungfish import fasta path/to/MN908947.3.gb` and states "The `fasta`
  subcommand handles FASTA, GenBank, and EMBL."
- **`appendices/cli-reference.md:131-133`** prints `lungfish import <path>`
  "Imports a FASTA, GenBank, or GFF3+FASTA pair as a reference bundle."

Correct per the live binary (`import --help`: `USAGE: lungfish import
<subcommand>`, with `fasta` as a required subcommand and no default): a bare
`lungfish import <path>` errors. The body chapter is right; the cli-reference
"bare path" entry is wrong. (Ground truth `ground-truth/02-sequences.md` ch01
item 1 flagged this; it was fixed in the body but persists in cli-reference.)

### 7. SRA download given a third, nonexistent menu path in the assembly chapter

- **`03-reads/02-downloading-from-sra.md`** (owns SRA) and **`05-variants/01:126`**
  and **`05-variants/04`** all use `Tools > Search Online Databases > Search SRA`.
- **`07-assembly/02-running-spades.md:75`**: "Download the run via `File > Import
  > From SRA`."

Correct per ground truth (`ground-truth/03-reads.md`, ch02 item 1): the SRA
entry point is `Tools > Search Online Databases > Search SRA…`. There is no
`File > Import > From SRA` menu. `07-assembly/02:75` should use the
`Tools > Search Online Databases > Search SRA` path (or cross-reference
`03-reads/02`) like every other chapter.

### 8. "Map Reads" menu path drift: `Tools > Map Reads` / `... > Map Reads` vs `... > Mapping…`

The canonical mapping entry point is `Tools > FASTQ/FASTA Operations >
Mapping…` (used throughout `04-alignments/01`, `04-alignments/05`,
`05-variants/01`, `05-variants/04`). Two chapters drift:

- **`03-reads/05-decontamination.md:109`**: "Pass the kept-read bundle to `Tools
  > Map Reads` against the SARS-CoV-2 reference." (`Tools > Map Reads` is not a
  real menu item.)
- **`07-assembly/04-extracting-contigs.md:174`**: "Open the Map Reads wizard from
  `Tools > FASTQ/FASTA Operations > Map Reads`." (the leaf is `Mapping…`, then a
  mapper tool row, not a `Map Reads` item).

Correct per ground truth (`ground-truth/04-alignments.md`, Section-wide item 4:
"the real path is `Tools > FASTQ/FASTA Operations > Mapping…`"): both should use
`Tools > FASTQ/FASTA Operations > Mapping…`. (`02-sequences/03:105` uses the
correct path but parenthesizes it as "the \"Map Reads\" operation," which is an
acceptable paraphrase; the two above use it as the literal menu path and are
wrong.)

### 9. Broken cross-reference: ONT chapter links to a nonexistent `04-variants` folder

- **`03-reads/07-ont-runs.md:104`**: "Medaka, the ONT-aware consensus and variant
  caller used in [Variants](../04-variants/), ships with model-specific
  parameters..."

The link target `../04-variants/` does not exist (verified: `ls
chapters/04-variants` -> no such directory). The Variants part is `05-variants`.
Medaka's variant-calling chapter is `05-variants/04-nanopore-variant-calling.md`.
The link should be `../05-variants/` (or, more precisely, the Medaka chapter
`../05-variants/04-nanopore-variant-calling.md`). This is the only broken
relative chapter link inside Part II+ scope.

### 10. `.lungfishmsa` provenance lists MUSCLE and Nextclade as in-app aligners, contradicting the MSA chapter

- **`appendices/file-formats.md:245`**: "Provenance records the aligner used
  (**MAFFT, MUSCLE, Nextclade**) and its parameters."
- **`02-sequences/04-msa-and-trees.md:50-58`**: "MAFFT is the only aligner wired
  into Lungfish, in both the GUI and the CLI; there is no aligner picker," and the
  comparison table marks MUSCLE and Clustal Omega "In Lungfish: **No**."

Correct per ground truth (`ground-truth/02-sequences.md`, ch04 item 3, and
Section-wide: "the only MSA alignment tool wired in the GUI and CLI is MAFFT"):
Lungfish produces `.lungfishmsa` bundles only with MAFFT; MUSCLE is import-only
and Nextclade is not an in-app aligner at all. `file-formats.md:245` should list
MAFFT as the aligner (an imported alignment carries its own external-tool
provenance, but the in-app MSA bundle is MAFFT). As written it implies the app
runs MUSCLE/Nextclade to build `.lungfishmsa`, which the MSA chapter explicitly
denies.

### 11. VCFv3 rejection asserted as fact in the appendix, deliberately hedged in the body chapter

- **`appendices/file-formats.md:95`**: "Lungfish reads VCF 4.0, 4.1, 4.2, 4.3, and
  4.4 **only**. **VCFv3 files must be converted** to VCF 4.x with an external
  converter before import." (flat claim that v3 is rejected)
- **`05-variants/06-importing-existing-vcfs.md:51`**: "Very old VCFv3 files predate
  the modern spec; **whether the GUI reader rejects them outright was not
  confirmed for this chapter**, so ... rather than relying on a specific rejection
  message."

These take opposite epistemic stances on the same behaviour. Per ground truth
(`ground-truth/05-variants.md`, ch06: the CLI import does not check the VCF
version or reject v3, and the GUI rejection is "UNCERTAIN, not confirmed"), the
hedged body-chapter wording is the accurate stance and the appendix's flat
"reads 4.x only / must be converted" overstates a verified-as-unconfirmed
behaviour. Align the two to the cautious form (recommend conversion without
promising a hard rejection), or verify the reader and make both definite.

---

## Should-fix consistency / polish items

### A. "Operation Center" vs "Operations Panel" (user-facing name drift)

The user-facing surface is consistently called the **Operations Panel** in the
overwhelming majority of chapters (foundations `06-the-lungfish-project.md`,
`appendices/keyboard-shortcuts.md:48`, and ~30 body-chapter mentions). Two places
use the raw code-class name **"Operation Center" / "OperationCenter"**:

- `08-workflows/01-the-workflow-builder.md:263`, `:264`, `:336`, `:351` ("the
  Operation Center shows the same words", "The Operation Center receives a parent
  workflow row", "one Operation Center row per node", "the Operation Center marks
  that row's status").
- `07-assembly/03-running-flye-or-hifiasm.md:135` ("The wizard hands the run to
  the **OperationCenter**").

The UI name is "Operations Panel" (foundations + keyboard-shortcuts agree, and
ground truth treats `OperationCenter` as the code symbol). Rename these to
"Operations Panel" for one consistent user-facing term.

### B. "Operations Panel" vs "Operations panel" capitalization

Most chapters capitalize "Operations Panel". Lowercase "Operations panel" appears
in `06-classification/04-running-taxtriage.md:154`, `07-assembly/02-running-spades.md:69`
and `:110`, and `07-assembly/03-running-flye-or-hifiasm.md:137` and `:157`. Pick
one casing (the dominant "Operations Panel") across the section.

### C. iVar primer-trim acknowledgement label wording

The auto-checked acknowledgement in the iVar Variant Calling dialog is quoted
two slightly different ways:

- `05-variants/01:166`: "This BAM has already been primer-trimmed for iVar".
- `05-variants/03:84`: "This BAM has already been primer-trimmed".

Minor, but they describe the same control; standardize the quoted label. (Ground
truth did not pin the exact string, so either is acceptable as long as both
chapters agree.)

### D. ONT primer scheme name for the hypothetical fixture

`05-variants/04:143` primer-trims `ONT-SAMPLE-01` with a scheme it calls
`ARTIC-v3-SARS2`, and `05-variants/04:95` tells readers to "choose the matching
primer scheme" generically. The only built-in scheme documented across the
manual (`04-alignments/03:99-101`, `appendices/primer-schemes.md:28`,
`appendices/file-formats.md:208`) is `QIASeqDIRECT-SARS2`; `ARTIC-v3-SARS2` is
not a shipped scheme. Because chapter 04 is explicitly aspirational/hypothetical
this is not a hard contradiction, but a reader who looks for `ARTIC-v3-SARS2` in
the picker will not find it. Consider noting it must be imported, or using the
built-in scheme name, for consistency with the rest of the section.

### E. `05-variants/02` table lists `sb_fdr` as a sample Filter value

`05-variants/02-reading-the-variant-browser.md:56` and `:139` use `sb_fdr` as an
illustrative non-PASS Filter value, and `04-alignments/03` reasons about LoFreq
filters generically. Ground truth (`ground-truth/05-variants.md`, ch03) notes
`sb_fdr` is not a Lungfish-generated filter string (the iVar strand-bias filter
is `sb`). This is internally consistent within `05-variants` (both mentions are
framed as caller-dependent examples), so it is a per-section fidelity matter
rather than a cross-chapter contradiction; flagged here only so the editor can
decide whether to keep `sb_fdr` as an example or swap to a real Lungfish filter
(`ft`, `bq`, `sb`).

---

## Confirmed-consistent (areas checked and clean)

These cross-cutting facts were checked across every chapter that mentions them
and are now consistent with each other and with ground truth. Listing them so the
editor knows the coverage and does not re-open settled items.

- **Op-launch menu pattern.** Every FASTQ/FASTA operation chapter now uses the
  3-level `Tools > FASTQ/FASTA Operations > <Category>…` then pick-in-dialog
  pattern (Trimming & Filtering, Decontamination, QC & Reporting, Search &
  Subsetting, Read Processing, Classification, Assembly, Mapping). No surviving
  4-level paths and no "Reads"/"Workflows"/"Classification > Kraken2" submenus in
  the procedure text. (The two `Map Reads` strays in finding 8 are the exception.)
- **Plugin Manager location.** Consistently `Tools > Plugin Manager…`
  (Cmd-Shift-B) in `01-foundations/07`, `06-classification/01-04`,
  `06-classification/07-running-freyja`, and the keyboard-shortcuts appendix. The
  old `Lungfish > Settings > Plugin Manager` error is gone everywhere.
- **Soft-clip, not hard-clip.** `04-alignments/02:59`, `04-alignments/03:29-44`,
  `05-variants/01:156`, `03-reads/04:85`, `01-foundations/03` and `04` all agree
  primer trim soft-clips (CIGAR `M`->`S`), keeps reads at original length, and
  preserves bases. The chapter-02/chapter-03 hard-clip contradiction flagged in
  ground truth is resolved.
- **Caller roster.** `05-variants/01:69` and `:164`, `05-variants/04:101`, and
  `05-variants/03` consistently describe **five viral callers** (LoFreq, iVar,
  Medaka, bcftools, Clair3) plus the two GATK options, with the sidebar listing
  seven entries and **LoFreq selected by default**. Matches ground truth; the
  three-caller framing is gone.
- **Classifier roster.** `06-classification/01`, `02`, `05`, `07`, `08` all agree
  on **three runnable** (Kraken2, EsViritu, TaxTriage) and **three import-only**
  (CZ-ID, NAO-MGS, NVD), one `Classification…` menu item, and NAO-MGS/NVD/CZ-ID
  reached from the Import Center. The "four classifiers / same viewport for all"
  errors are gone, and NVD now has its own chapter.
- **`lungfish classify` -> `lungfish conda classify`.** `06-classification/02:277`
  and `appendices/cli-reference.md:45,277` both use `lungfish conda classify`.
- **`esviritu detect`, `taxtriage run`.** `06-classification/03`, `04`, and
  cli-reference all use `esviritu detect` (not `esviritu run`) and `taxtriage
  run`.
- **`lungfish extract contigs` (two words).** `07-assembly/04:114-118` and
  `appendices/cli-reference.md:338` both use `extract contigs` and explicitly warn
  against the hyphenated `extract-contigs`. GUI trigger is the **Create Bundle**
  action-bar button (not a right-click "Extract Contigs" sheet) in both
  `07-assembly/04` and its ground truth.
- **SPAdes has no `--viral` mode.** `07-assembly/01:84`, `07-assembly/02:33,53-55,136`
  consistently state there is no viral profile, default to Isolate, and route the
  upstream `--viral` pipeline through `--extra-args "--viral"` only.
- **Assembler roster.** `07-assembly/01` and `02` and `03` and cli-reference all
  list the same five (SPAdes, MEGAHIT, SKESA, Flye, Hifiasm) with the same
  per-tool profiles (SPAdes Isolate/Meta/Plasmid, MEGAHIT Default/Meta
  Sensitive/Meta Large, Flye Nano HQ/Raw/Corrected, Hifiasm Diploid/Haploid-Viral,
  SKESA no profile).
- **Primer scheme identity and counts.** `04-alignments/03:99-101`,
  `appendices/primer-schemes.md:28`, and `appendices/file-formats.md:208` agree:
  display name "QIAseq Direct SARS-CoV-2 with Booster A", manifest name
  `QIASeqDIRECT-SARS2`, 223 amplicons / 563 primers, canonical `MN908947.3` /
  equivalent `NC_045512.2`, snake_case manifest keys. Import path
  `File > Import Center > Primer Scheme` is consistent in all four locations.
- **SRR36291587 fixture = QIAseq, not ARTIC.** `04-alignments/03`,
  `04-alignments/04:155`, and `05-variants/01` all primer-trim SRR36291587 with
  the QIAseq Direct scheme; the ARTIC v3 mentions are now generic illustrations,
  not the fixture's scheme. The ch03-vs-ch04 ARTIC/QIAseq contradiction is
  resolved.
- **`.lungfishtax` is CZ-ID-only.** `appendices/file-formats.md:228-230`,
  `06-classification/07-importing-cz-id-results.md`, and `06-classification/01:85`
  agree `.lungfishtax` is produced only by the CZ-ID import path and is not the
  storage format for Kraken2/EsViritu/TaxTriage/NAO-MGS. The "universal classifier
  bundle" error is gone.
- **Viral Recon is SARS-CoV-2-specific and lives in the Mapping category.**
  `04-alignments/05` and `04-alignments/01:314-323` agree there is no "Workflows"
  menu and the wizard is reached via `Tools > FASTQ/FASTA Operations > Mapping…`
  then the Viral Recon tool row. (`05-variants/05:81` omits the "Mapping…" leaf,
  saying only `Tools > FASTQ/FASTA Operations` then select Viral Recon in the tool
  sidebar; this is a minor under-specification rather than a contradiction, but
  could be tightened to name the Mapping category like `04-alignments/05` does.)
- **`.lungfishrun` vs `.lungfishflow`.** Correctly distinct: `.lungfishrun` is the
  viralrecon run bundle (`04-alignments/05`, cli-reference), `.lungfishflow` is the
  Workflow Builder graph (`08-workflows/01`, cli-reference, file-formats). Not a
  conflict.
- **Consensus FASTA does not come from the iVar Call Variants step.**
  `05-variants/05:39` and `05-variants/01:213` agree the iVar variant step writes a
  VCF (not a consensus), and consensus comes from Viral Recon / `lungfish msa
  consensus` / Inspector consensus mode. The codon-merge `ivarConsensusAF`
  explanation is consistent across `05-variants/01:188`, `05-variants/03:132`, and
  `05-variants/05:39`.
- **Six provenance export targets.** `08-workflows/02:38-49`,
  `01-foundations/08-provenance-and-reproducibility.md:19`, and the
  `08-workflows/02` frontmatter agree on all six (Shell, Python, Nextflow,
  Snakemake, Methods, Full Provenance JSON) and the `File > Export > Provenance`
  menu path.
- **Variant browser columns.** `05-variants/02:48-57` and `05-variants/03:100`
  agree on `ID, Chrom, Position, Ref, Alt, Quality, Filter, Source` (Position not
  "Pos", Quality not "Qual"), AND-only free-text filter with no `OR`/colon/`Source=`
  syntax, and dynamically promoted INFO columns. Consistent with ground truth.
- **GATK execution framing.** `06-human-germline-variants/01-haplotype-caller.md:121`
  and the cli-reference GATK section (`:464-468`) agree GATK previews by default and
  `--execute` runs it through the managed `gatk-core` env, consistent with each
  other (the chapters were updated away from the "does not run GATK" framing the
  ground-truth map flagged).
- **Decontamination tool/database attributions.** `03-reads/05` consistently uses
  Deacon + `deacon-panhuman` / `deacon-ribokmers` (managed databases, not a
  "Decontamination pack"), bbduk for contaminants, clumpify for duplicates,
  matching ground truth; no RiboDetector-toggle claim survives.

---

## Out-of-scope note (foundations, flagged for completeness)

`01-foundations/08-provenance-and-reproducibility.md:85` links
`[Exporting workflows for collaborators](../../README.md)`, which resolves to
`docs/user-manual/README.md` -- a file that does not exist (only
`docs/user-manual/chapters/README.md` exists). This is a foundations chapter,
outside the Part II+ audit scope, but it is a broken link and the intended target
is almost certainly `08-workflows/02-exporting-as-nextflow-or-snakemake.md`.
Recorded here only so it is not lost.

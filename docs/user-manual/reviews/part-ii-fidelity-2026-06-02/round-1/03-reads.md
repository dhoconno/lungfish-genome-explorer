# Reads (03-reads) focus group, Round 1 of 3

Simulated-reader focus group on the seven `03-reads` chapters, run against the
arbiter-of-truth map in
`docs/user-manual/reviews/part-ii-fidelity-2026-06-02/ground-truth/03-reads.md`
(every claim there re-confirmed against `Sources/LungfishApp/App/MainMenu.swift`,
`FASTQOperationDialogState.swift`, and the live `.build/debug/lungfish-cli`
on 2026-06-02). Four personas read cold, quoted lines, and reacted to BOTH
fidelity breaks and accessibility gaps. Part 2 is the prioritized revision plan.

---

## PART 1: Personas

### Persona A: Dolores, wet-lab novice importing her first FASTQ

Background: third-year virology PhD student, runs the bench MiSeq, has never
used a terminal beyond `cd`. Reads chapters 01 and 02. Declared tier:
`bench-scientist`.

What worked. "An import is not a copy step alone" (01, line 34) landed. She
liked that the pairing-convention table (01, lines 50-56) gave her exact
filenames to compare against her own `Sample01_R1.fastq.gz`. The SHA-256
checksum explanation (01, line 140) made her trust the tool: "OK, so it checks
the file didn't get corrupted on the way in, good."

Where she got stuck.

1. She tried the very first instruction and it was already wrong. Front matter
   says the entry point is "File > Import Center (Cmd-Shift-I) > FASTQ" (01,
   line 11), and the body repeats "Click the FASTQ tab" (01, line 82). She
   pressed Cmd-Shift-I, saw no tab labelled "FASTQ" and no tab labelled
   "FASTQ Files" either, just a grid of category tiles. She quote: "There is no
   FASTQ tab. There's a tile. Which one?" Ground truth: the destination is a
   tile titled `FASTQ Files` under a category `Sequencing Reads`, not a "FASTQ
   tab" (`ImportCenterViewModel.swift:231`).

2. The metadata import path is a dead end. She got to "import it through
   `File > Import > Project Sample Metadata`" (01, line 166) and could not find
   a File > Import submenu at all. Quote: "I clicked File. There's no Import
   that opens anything like this." Ground truth: no such menu path exists; the
   File menu has only an EXPORT action for sample metadata
   (`MainMenu.swift:232`).

3. Jargon for her tier. "ENA" appears in chapter 02 (lines 43-48, the whole
   ENA-vs-Toolkit table) with no expansion until you already understand it is a
   European mirror. She is primed for SRA but not ENA. She also hit
   "interleaved FASTQ" (02, line 209) cold: "two reads in one file, is that bad?
   nobody told me what interleaved means." Neither term is glossed at first use.

Net: Dolores could not complete the GUI import by following the words on the
page. Both blockers are one-line label fixes, but for a true novice a wrong
label is a full stop.

### Persona B: Marcus, research associate doing QC and trimming

Background: core-lab RA, runs QC and trimming on every incoming run, lives in
the GUI, occasionally copies a CLI line into a notebook. Reads chapters 03 and
04. Declared tier: `bench-scientist`.

What worked. The Phred threshold table (03, lines 87-92) and the three
"what bad QC looks like" signatures (03, lines 117-145) are, in his words,
"the best QC explainer I've read in a tool manual." He would keep them
verbatim. The FASTQ-vs-BAM primer-trim decision (04, lines 80-86) he called
"genuinely useful, I never knew why our pipeline did it at the BAM level."

Where he got stuck.

1. The QC menu path has a level that does not exist. He followed "From the menu
   bar choose `Tools > FASTQ/FASTA Operations > QC & Reporting > Refresh QC
   Summary`" (03, line 62) and stopped at the menu item `QC & Reporting…`,
   which opened a dialog. Quote: "There's no fourth menu. It just opens a
   window and then I pick Refresh QC Summary inside it." Ground truth: the menu
   ends at `QC & Reporting…` (`MainMenu.swift:646`); the operation is picked
   in-dialog.

2. Same broken pattern five more times in chapter 04. Every entry point and
   every in-body instruction is the four-level form
   `Tools > FASTQ/FASTA Operations > Trimming & Filtering > <Operation>` (04,
   lines 11-15, 56, 66, 76). After the third one he stopped trusting the menu
   paths entirely: "I get it, the operation is always inside the dialog. The
   docs keep writing it like it's a submenu and it never is."

3. A default he would have entered wrong. Chapter 04 says Filter by Read Length
   defaults to "Minimum 30 bp, drop pair if either fails" (line 41) and the
   procedure says "Leave the minimum length at 30 bp and the 'drop pair if
   either mate fails' checkbox ticked" (line 67). He opened the pane: there is
   no 30 bp default (both fields are blank) and there is no drop-pair checkbox.
   Quote: "It told me to leave a checkbox ticked that isn't there, and a default
   that isn't there. If I'd trusted the doc I'd have reported a bug." Ground
   truth: GUI defaults `filterByReadLengthMin = nil`, `filterByReadLengthMax =
   nil`; the pane shows only `Min Length`/`Max Length`
   (`FASTQOperationToolPanes.swift:333-336`); CLI `length-filter` has `--min`/
   `--max` with no default and no drop-pair flag (confirmed live).

4. Wrong tool in a table he relies on. The tool table lists "Primer Trimming
   (FASTQ-level) ... Tool: fastp" (04, line 40). Marcus knows primer trimming
   is not what fastp does. Ground truth: FASTQ-level primer trim is
   `fastq primer-remove`, engine `bbduk` by default (cutadapt-linked as the
   alternative), `--kmer 23 --mink 11 --hdist 1`; fastp is never used for it.

Net: Marcus's QC reading is excellent and his trimming concepts are right, but
three of the operational specifics (menu depth, length-filter default,
primer-trim tool) would each cause a wrong action.

### Persona C: Priya, advanced postdoc doing decontamination and subsetting

Background: metagenomics postdoc, host-depletes clinical swabs, subsamples to
normalize depth, reads release notes for tool identity. Reads chapters 05 and
06. Declared tier: chapter 05 is `analyst`, chapter 06 is `bench-scientist`.

What worked. The "Should I decontaminate?" three-question framework (05, lines
44-52) she called "exactly the right way to teach this, sensitivity vs
specificity up front." The virtual-bundle / materialization explanation (06,
lines 49-53, 105-113) she praised: "finally a manual that admits the preview
file is not the whole dataset."

Where she got stuck, hard. Chapter 05 names the wrong tool in almost every row.

1. "Remove Ribosomal RNA runs either Deacon against an rRNA database or
   RiboDetector" plus the table row "Tool: Deacon or RiboDetector" and "a tool
   toggle for RiboDetector" (05, lines 30, 35, 70). She opened the Remove
   Ribosomal RNA pane looking for the RiboDetector toggle to get the
   deep-learning classifier. There is no toggle. Quote: "I came here for
   RiboDetector. The pane has one segmented control, Retain Reads, and that's
   it. Where is the deep-learning option the table promised?" Ground truth: the
   GUI op builds ONLY `fastq deacon-ribo` (Deacon + BBMap ribokmers,
   `--retain norrna`); the pane is a single `Retain Reads` picker
   (`FASTQOperationToolPanes.swift:355-361`); RiboDetector is a separate
   CLI-only op (`fastq ribodetector`) not wired to this dialog at all.

2. "Remove Contaminants runs Deacon against a custom reference" and table "Tool:
   Deacon" (05, lines 30, 36), reinforced by the troubleshooting line "Deacon
   needs enough k-mers to build a discriminating index" (line 106). She would
   have prepared a Deacon index. Ground truth: Remove Contaminants is
   `fastq contaminant-filter`, engine bbduk, `--mode phix|custom`, `--kmer 31`,
   custom mode takes a reference FASTA via `--ref` (confirmed live). Quote:
   "It's bbduk, not Deacon. The troubleshooting advice about Deacon k-mers is
   for a tool this operation never calls."

3. The install story points at a pack that does not exist. "find the
   Decontamination plugin pack ... pulls the Deacon binary plus the
   human-genome and rRNA k-mer indexes" (05, line 58) and "install the
   RiboDetector plugin pack instead" (line 60). Ground truth: there is no
   `Decontamination` plugin pack; the Deacon indexes are managed databases
   (`deacon-panhuman`, `deacon-ribokmers` in `DatabaseRegistry`), and
   `ribodetector` is a member of the metagenomics pack, not a standalone pack
   (`PluginPack.swift:633, 671-684`). She: "If I open Plugin Manager looking for
   a 'Decontamination' pack I will not find one. This sends me on a hunt."

Chapter 06 merged two different operations and invented a seed.

4. "Optionally set a random seed if you need a reproducible draw" (06, line 69)
   and the worked example "a fixed seed (for example, `42`)" with "reservoir
   sampling, so the result is exactly 100,000 reads" (06, lines 71, 135). She
   went to set the seed so her normalization would be reproducible. There is no
   seed field, and the CLI has no `--seed`. Quote: "I told a reviewer my
   subsample used seed 42. There is no seed. My methods sentence is a lie."
   Ground truth: `fastq subsample` has ONLY `--proportion`/`--count`, no
   `--seed` (confirmed live); the seed field exists only on `pbaa-cluster`.

5. The two extract operations are described as a single conflated op. Extract
   Reads by ID is documented as "a text file of read names ... one read ID per
   line ... Drop the ID list into the file picker" (06, lines 46, 80-86), and
   Extract Reads by Motif is documented with "Set the mismatch budget" and
   "search both strands (default)" (06, lines 92-94). She: "Extract by ID has a
   single Query text box, not a file picker. And the motif op has a Pattern box
   and a regex toggle, no mismatch budget, no strand control." Ground truth:
   Extract by ID is `search-text --query <string> --field id|description`,
   Extract by Motif is `search-motif --pattern <p> [--regex]`; the
   mismatch/strand behavior belongs to a THIRD undocumented op,
   `Select Reads by Sequence` / `sequence-filter` (`--search-end both`,
   `--error-rate 0.1`, `--min-overlap 8`, `--search-rc`) (confirmed live).

6. Invented CLI names. "The CLI mirror is `lungfish fastq subsample`,
   `lungfish fastq extract-ids`, and `lungfish fastq extract-motif`" (06, lines
   96-97). She tried `extract-ids` in a script. Ground truth: `extract-ids` and
   `extract-motif` do not exist; they fall through to the parent `fastq` help
   (confirmed live). The real names are `search-text` and `search-motif`.

Net: Priya is the persona the fidelity breaks hurt most. Chapter 05's tool
identity is wrong in four of seven claims, and chapter 06 would put a fabricated
seed into her published methods.

### Persona D: Sam, power-user running ONT runs and scripting the CLI

Background: sequencing-core informatician, imports MinKNOW output, scripts
batch runs, reads CLI help before trusting a doc. Reads chapter 07, skims the
CLI mentions across all seven. Declared tier: `bench-scientist` (though Sam
reads as a power-user; see accessibility note).

What worked. The ONT-vs-Illumina table (07, lines 74-80) and the
basecaller-model / Medaka-match warning (07, lines 91-105) he called "correct
and the kind of thing people forget." The "what this chapter does not cover"
section on POD5/FAST5/adaptive sampling (07, lines 209-222) he praised as
honest scoping.

Where he got stuck.

1. The headline entry point is a phantom menu item. "Lungfish imports the whole
   tree in one step through `File > Import ONT Run`" (07, line 35), with a full
   procedure: "Choose `File > Import ONT Run`. Click 'Choose Run Folder'" (07,
   line 146) and an "Attach Sample Sheet" button (line 153). He opened the File
   menu: there is no Import ONT Run item. Quote: "The entire procedure is built
   on a menu item that isn't in the menu bar." Ground truth: `importONTRun(_:)`
   is declared and implemented as an action but attached to NO menu item; ONT
   import is reached via Import Center (Cmd-Shift-I) > Sequencing Reads >
   `ONT Run Folder` tile (`ImportCenterViewModel.swift:270-271`,
   `AppDelegate+ImportExport.swift:259`).

2. The Orient Reads checkbox does not exist. "the Orient Reads dialog has a
   'Keep unmapped reads' checkbox" (07, line 199). He opened the pane: Word
   Length, a Database Mask picker (dust/none), and an Extra arguments field, no
   keep-unmapped checkbox. Ground truth: the pane has exactly those three
   controls (`FASTQOperationToolPanes.swift:397-405`); the underlying tool is
   vsearch `--orient`, whose drop/keep behavior is a vsearch detail, not a
   Lungfish checkbox. Plus the menu path is again the four-level form (07, lines
   12, 176) that ends at `Read Processing…`.

3. As a scripter he wanted the CLI and the chapter gives none. There is no
   mention of `fastq import-ont` anywhere, even though it is the actual batch
   entry point: `import-ont <dir> -o <out> --include-unclassified --concurrency
   --storage-mode --quality-binning` (confirmed live). Worse, the chapter says
   "By default every detected barcode is selected" and "you can deselect
   `unclassified`" (07, lines 159, 161), but the CLI default is to SKIP
   unclassified (`--include-unclassified` opts it back in, confirmed live) —
   the opposite framing. Quote: "The default is the inverse of what the doc
   says, and the flag that controls it is never named."

4. Sample-sheet-at-import may be GUI-only. The chapter leans on attaching a CSV
   barcode-to-sample sheet at ONT import (07, lines 37-39, 132-142, 153). The
   `import-ont` CLI takes no `--samplesheet` (confirmed live), so a scripter
   cannot reproduce the GUI's sheet-mapping step from the command line. The
   chapter never flags this asymmetry.

Accessibility note for Sam's tier. Chapter 07 is declared `bench-scientist` but
is the most power-user chapter in the section (MinKNOW worker threads, Dorado
model strings, vsearch orientation, POD5 squiggle). A true bench scientist is
over-served; a scripter is under-served because the CLI surface is absent. The
tier label and the missing CLI both deserve attention.

---

## PART 2: Synthesis and revision plan

### Critical fidelity fixes (the app does not work as written)

These are TOP PRIORITY: a reader following the current text performs the wrong
action or none. Grouped by defect class. All corrected strings verified against
source/CLI on 2026-06-02.

#### F1. Systematic menu-path error across all five operation chapters

Every chapter writes a four-level path
`Tools > FASTQ/FASTA Operations > <Category> > <Operation>`. The real menu is
three levels ending at the category item `<Category>…`; the operation is then
chosen from a list inside the opened dialog
(`MainMenu.swift:643-671`, category lists at `FASTQOperationDialogState.swift:1060-1066`).
This is the single most pervasive defect (chapters 03, 04, 05, 06, 07).

Corrected pattern, to apply everywhere a four-level path appears:

> Choose `Tools > FASTQ/FASTA Operations > <Category>…`. In the dialog that
> opens, select `<Operation>` from the operations list, set the parameters, and
> click `Run`.

Concrete instances to fix (entry-point front matter AND in-body):
- 03 line 11, 37-38, 62-64 (`QC & Reporting…`, op `Refresh QC Summary`).
- 04 lines 11-15, 56, 66, 76 (`Trimming & Filtering…`).
- 05 lines 11-13, 65 (`Decontamination…`).
- 06 lines 11-14, 67, 90 (`Search & Subsetting…`).
- 07 lines 12, 176 (`Read Processing…`, op `Orient Reads`).

#### F2. Chapter 05 names the wrong tool in four of seven claims

a. Remove Ribosomal RNA is Deacon only, not "Deacon or RiboDetector," and has
no tool toggle. Replace the table row (05, line 35) and the prose (05, lines 30,
70):

> Remove Ribosomal RNA runs Deacon against the managed `deacon-ribokmers`
> database and keeps the read classes you choose with the `Retain Reads`
> control (default: keep non-rRNA). RiboDetector is a separate command-line tool
> (`lungfish fastq ribodetector`) and is not reachable from this dialog.

b. Remove Contaminants is bbduk, not Deacon. Replace the table row (05, line 36)
and the troubleshooting note (05, line 106):

> Remove Contaminants runs bbduk. The default mode (`phix`) screens the PhiX
> spike-in; `custom` mode screens a reference FASTA you supply. Tuning is k-mer
> size (default 31) and Hamming distance (default 1).

For the troubleshooting line, replace "Deacon needs enough k-mers to build a
discriminating index" with "bbduk matches 31-mers, so a reference of only a few
hundred bases will not catch much; supply full chromosomes or contigs."

c. Remove Human Reads uses the managed `deacon-panhuman` database (a Deacon
minimizer index), not a Plugin Manager pack and not a bbduk-style "k-mer
database." Reword 05 lines 30, 34 accordingly.

d. No `Decontamination` plugin pack exists. Replace the install instructions
(05, lines 57-60): the Deacon human and rRNA indexes are managed DATABASES
(`deacon-panhuman`, `deacon-ribokmers`), installed as databases, not as a single
named pack. The true install surface needs a human pass against the actual
Plugin Manager / database UI before final wording.

#### F3. Chapter 06 invents a subsample seed and conflates two extract ops

a. There is NO random seed. Delete "Optionally set a random seed if you need a
reproducible draw" (06, line 69), delete "a fixed seed (for example, `42`)"
(06, line 71), delete "Record the seed in your methods" (06, line 133), and
delete the "reservoir sampling, so the result is exactly 100,000 reads" claim
(06, line 135) unless the implementation is separately confirmed. `fastq
subsample` exposes only `--proportion`/`--count` (confirmed live).

b. Extract Reads by ID is a query string, not a file of IDs. Replace 06 lines
46, 80-86:

> Extract Reads by ID matches a query string against the read header. Enter the
> query in the `Query` field, choose whether to match the `ID` or the
> `Description` portion of the header, and optionally enable `Use Regular
> Expression`. There is no file-of-IDs upload.

c. Extract Reads by Motif has only a pattern and a regex toggle. Replace 06
lines 47, 92-94:

> Extract Reads by Motif takes a `Pattern` and an optional `Use Regular
> Expression` toggle. It has no mismatch budget and no strand option.

d. The mismatch/strand behavior the chapter described belongs to a DIFFERENT,
undocumented op. See coverage gap C1 (Select Reads by Sequence).

#### F4. Chapter 06 invented CLI subcommand names

Replace "`lungfish fastq extract-ids`, and `lungfish fastq extract-motif`"
(06, lines 96-97). The real commands are:

> `lungfish fastq subsample`, `lungfish fastq search-text` (Extract Reads by
> ID), and `lungfish fastq search-motif` (Extract Reads by Motif).

`extract-ids`/`extract-motif` do not exist (confirmed: they fall through to the
parent `fastq` help).

#### F5. Chapter 04 wrong tool and wrong defaults

a. Primer Trimming (FASTQ-level) is bbduk, not fastp. Fix the table row (04,
line 40): tool is `fastq primer-remove`, engine bbduk by default
(cutadapt-linked alternative), `--kmer 23 --mink 11 --hdist 1`.

b. Filter by Read Length has no 30 bp default and no drop-pair checkbox. Fix the
table row (04, line 41) and the procedure (04, line 67). Corrected procedure:

> Choose `Filter by Read Length` in the dialog. Set `Min Length` and/or
> `Max Length` (both are blank by default; set the minimum to the shortest read
> you want to keep). Click `Run`.

Remove the "(fastp-trim, len30)" output-suffix claim (04, line 70) unless the
real suffix is confirmed; the `len30` token is tied to the fictional 30 bp
default.

#### F6. Chapter 07 phantom menu item and phantom checkbox

a. `File > Import ONT Run` does not exist. Replace the entry point (07, line 11)
and the whole "Open the Import ONT Run dialog" procedure (07, lines 35, 144-146):

> Import an ONT run through the Import Center: press `Cmd-Shift-I`, choose the
> `Sequencing Reads` category, and select the `ONT Run Folder` tile. Point it at
> the top-level run directory.

The "Choose Run Folder" / "Attach Sample Sheet" button walkthrough must be
re-grounded against the actual Import Center ONT tile controls (needs a human
view-level check; the standalone dialog at the claimed path does not exist).

b. The Orient Reads "Keep unmapped reads" checkbox does not exist (07, line 199).
Remove it. The pane exposes `Word Length`, a `Database Mask` picker
(dust/none), and `Extra arguments` (`FASTQOperationToolPanes.swift:397-405`).
If keep/drop of non-orientable reads matters, document it as vsearch `--orient`
behavior, not a Lungfish control.

c. Unclassified default is inverted. The chapter says "By default every detected
barcode is selected" and implies unclassified is included unless deselected
(07, lines 159-161). The CLI default is to SKIP unclassified; `--include-
unclassified` opts it in (confirmed live). Reconcile the GUI default against
this and correct the framing.

#### F7. Chapter 02 SRA search limit and missing override flags

a. "returns up to the first 200 matching runs" (02, line 76) contradicts the CLI
default `--limit 20` (confirmed live). Either correct to the real GUI limit
(verify the dialog model) or drop the specific number.

b. The chapter frames the ENA-to-Toolkit fallback as automatic only. The CLI
exposes `fetch sra download --use-toolkit` to force the Toolkit path, and
`fetch sra search --api-key` is the real mitigation for the rate-limit
troubleshooting at 02 lines 191-195. Both should be named.

#### F8. Chapter 01 wrong import-tile label and dead metadata menu path

a. "Click the FASTQ tab" (01, lines 82-83) and entry point "...> FASTQ" (01,
line 11): the destination is a tile titled `FASTQ Files` under the
`Sequencing Reads` category, not a "FASTQ tab"
(`ImportCenterViewModel.swift:231`). Reword to match the tile model.

b. "import it through `File > Import > Project Sample Metadata`" (01, line 166):
no such menu path exists (`MainMenu.swift` has only the export action). Identify
the real per-project metadata import surface (the CLI has `lungfish metadata`)
and correct, or remove the claim pending a human check.

### Coverage gaps (real app features missing from the docs)

Real, shipping operations that belong in this section and are entirely absent.

#### C1. Select Reads by Sequence (the op chapter 06 actually described)

`selectReadsBySequence` / `fastq sequence-filter` is a real fifth op in the
Search & Subsetting category (`FASTQOperationDialogState.swift:1066`) and is the
adapter/barcode-presence filter with `--search-end left|right|both` (default
both), `--min-overlap 8`, `--error-rate 0.1`, `--search-rc`, and
`--keep-matched` (confirmed live). It is exactly the "motif with mismatch budget
and strand choice" the chapter mis-attributed to Extract Reads by Motif. Add it
as its own subsection; it is the correct home for the mismatch/strand prose.

#### C2. Trim Fixed Bases (undocumented sixth trim op)

`trimFixedBases` / `fastq fixed-trim` (`--front 0`, `--tail 0`, confirmed live)
hard-trims N bases off each end independent of quality. It is the sixth op in
the Trimming & Filtering category; chapter 04 documents only five and omits it.
Useful for fixed-length UMIs and adapter stubs.

#### C3. Manual materialize CLI

`fastq materialize <bundle> -o <out>` is the manual escape hatch behind the
virtual-bundle story chapter 06 tells well (06, lines 49-53, 110-113). The
chapter correctly says materialization is automatic but never names the manual
command, which power users want for pre-staging.

#### C4. ONT barcode handling and the import-ont CLI

Chapter 07 treats ONT barcodes as already-split by MinKNOW and gives no CLI.
Missing: `fastq import-ont` with `--include-unclassified`, `--storage-mode
chunked|flattened`, `--optimize-storage`, `--quality-binning` (all alter stored
bytes); and the broader `fastq demultiplex`/`fastq scout` surface with ~20
built-in kits including ONT kits (`ont-nbd104`, `ont-rbk114-24`, `ont-16s114-24`)
for re-demultiplexing. At minimum, name `import-ont` as the scriptable path.

#### C5. Remove Duplicates lives in Decontamination but is undocumented

`removeDuplicates` / `fastq deduplicate` (clumpify.sh, `--subs`, `--optical`,
`--dupedist 40`) is in the Decontamination category
(`FASTQOperationDialogState.swift:1062`) yet appears in neither chapter 05 nor
06. Add a short subsection to chapter 05.

#### C6. Read Processing ops beyond Orient

The Read Processing category also contains Merge Overlapping Pairs
(`fastq merge`, bbmerge), Repair Paired-End Files (`fastq repair`),
Reverse Complement, Translate, and Correct Sequencing Errors
(`fastq error-correct`, tadpole) (`FASTQOperationDialogState.swift:1064`). Only
Orient is documented. A brief table of the category's six ops would close the
gap and contextualize Orient.

#### C7. import-fastq options that silently transform reads

`lungfish import-fastq` defaults to `--quality-binning illumina4` and
storage-optimized reordering, plus `--recipe`, `--compression`, `--recursive`,
`--dry-run` (per ground truth, `import-fastq --help`). Chapter 01 presents
import as a plain copy + checksum; the binning/reordering defaults change the
stored reads and should be disclosed.

### Accessibility fixes

Per the declared audience tier of each chapter (STYLE: "No chapter may mention a
concept the audience tier has not been primed for").

#### Bench-scientist tier (01, 02, 03, 04, 06, 07)

- Gloss `ENA` at first use in chapter 02 (line 43): "ENA, the European
  Nucleotide Archive, one of the three INSDC mirrors."
- Gloss `interleaved FASTQ` at first use in chapter 02 (line 209): "interleaved
  means read 1 and read 2 alternate inside a single file instead of living in
  two files."
- Chapter 07 is declared bench-scientist but reads at power-user level (MinKNOW
  worker threads, Dorado model strings, vsearch). Either reclassify to
  `power-user` or add one-line glosses for `basecaller`, `worker thread`, and
  `unstranded` at first use. `Orient Reads` is in `glossary_refs` already; make
  sure the first body use carries the inline short form.
- Chapter 03 uses `adapter read-through` (lines 132-134) and `flow cell`
  (line 122) without gloss; one clause each.

#### Analyst tier (05)

- Chapter 05 reads cleanly for analysts EXCEPT that it leans on tool names
  (Deacon, RiboDetector, bbduk after correction) the reader may not know map to
  which operation. After the F2 tool-name corrections, add a one-line "which
  tool does what" note so the analyst is not surprised when the pane shows a
  different control set than the table implied.

#### Cross-cutting (carried from the foundations synthesis)

- Add a scope line at the top of each chapter ("This chapter covers X; for
  adjacent topic Y see chapter Z"), per the foundations editorial rule.
- Vary the "So what should you do with this?" refrain; it recurs in 01, 02, 03,
  05, 06 and was flagged as patronizing in the foundations groups.
- Citation surface: chapters naming fastp, Deacon, bbduk, seqkit, vsearch should
  link the tool's docs or paper, per the foundations rule that Part II has no
  citation surface yet.

### What to keep

These landed well across personas and should survive revision:

- Chapter 03's QC explainer end to end: the Phred threshold table (lines 87-92),
  the "what good / bad QC looks like" signatures (lines 98-145), and the
  decision rule (lines 167-174). Marcus called it the best QC explainer he has
  read in a tool manual.
- Chapter 04's FASTQ-vs-BAM primer-trim decision (lines 80-86). The rationale
  ("ivar consults alignment position") taught Marcus something new.
- Chapter 05's "Should I decontaminate?" three-question framework (lines 44-52)
  and the sensitivity-vs-specificity framing. Priya wants it kept verbatim.
- Chapter 06's virtual-bundle / materialization explanation (lines 49-53,
  105-113). Honest about the preview file not being the whole dataset.
- Chapter 01's "an import is not a copy step alone" framing and the
  pairing-convention table (lines 50-56). Concrete filenames a novice can match.
- Chapter 07's basecaller-model / Medaka-match warning (lines 91-105) and the
  POD5/FAST5/adaptive-sampling scoping section (lines 209-222). Sam praised both
  as correct and honest.

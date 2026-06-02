# Reads (03-reads) focus group, Round 2 of 3

Round 2 simulated-reader review of the seven `03-reads` chapters after the
Round 1 editorial pass. Every fidelity claim below was re-confirmed on
2026-06-02 against the live `.build/debug/lungfish-cli` and the Swift source
(`MainMenu.swift`, `ImportCenterViewModel.swift`, `FASTQOperationDialogState.swift`,
`FASTQOperationToolPanes.swift`, `DatabaseRegistry.swift`). The chapter linter
(`build/scripts/lint/bin/lint-chapter.mjs`) was run on all seven chapters; its
output is reproduced verbatim in the bullet-cap section.

Bottom line: Round 1 landed almost completely. Every critical fidelity defect
from the Round 1 synthesis is fixed in the current text and matches the live
binary. What remains is mostly style and one or two small residual fidelity
risks, plus the two known bullet-cap warnings the editor must restructure.

---

## PART 1: Verification table

Each critical fidelity fix from the Round 1 synthesis, checked against the
revised text and re-verified against source/CLI.

| # | Round 1 fix | Status | Note (verified 2026-06-02) |
|---|---|---|---|
| 1 | Menu path: 4-level -> 3-level ending at `<Category>…`, op picked in dialog | **LANDED** | All five op chapters (03,04,05,06,07) now write `Tools > FASTQ/FASTA Operations > <Category>…` then "pick the operation in the dialog". Matches `MainMenu.swift:646,656,661,666,671` (titles end in `…`). Entry-point front matter updated too. |
| 2 | Decontam tool identity: Remove Contaminants = bbduk (not Deacon), Remove Human/rRNA = Deacon, install via managed DBs not a "Decontamination pack" | **LANDED** | ch05 line 33/39 now says Remove Contaminants "runs bbduk… against either the bundled PhiX… or a reference FASTA"; line 62 explicitly "not a single Plugin Manager 'pack': two separate managed databases, `deacon-panhuman`… and `deacon-ribokmers`". Confirmed `DatabaseRegistry.swift:64,85`; `contaminant-filter --help` = bbduk, `--mode phix\|custom`, `--kmer 31`. Troubleshooting line (109) now correctly says "bbduk… matches 31-mers". |
| 3 | Remove Ribosomal RNA = Deacon only, no RiboDetector toggle | **LANDED** | ch05 line 71: rRNA pane shows "one segmented `Retain Reads` control… and no RiboDetector toggle". Matches `FASTQOperationToolPanes.swift:355-361` (single `Retain Reads` picker). RiboDetector phantom plugin-pack prose is gone. |
| 4 | Removed the invented subsample random seed (no `--seed`) | **LANDED** | ch06 line 75: "There is no random-seed control on the subsample operations, so do not record a seed in your methods." Worked example (line 161) replaced "seed 42" with "archive the output bundle itself". `subsample --help` confirms only `--proportion`/`--count`. The fabricated "reservoir sampling, exactly 100,000" guarantee is gone (line 163 now "about the target number… or fewer"). |
| 5 | CLI names: `search-text` / `search-motif` (not `extract-ids`/`extract-motif`) | **LANDED** | ch06 lines 116-118 list `lungfish fastq search-text`, `search-motif`, `sequence-filter`. Confirmed real commands at `FastqSearchTextSubcommand.swift:12`, `FastqSearchMotifSubcommand.swift:12`, `FastqSequenceFilterSubcommand.swift:12`. `extract-ids`/`extract-motif` no longer appear anywhere in the section. |
| 6 | ONT entry point: Import Center (not phantom `File > Import ONT Run`) | **LANDED** | ch07 line 11 front matter + lines 41-42, 141-143 all route through "Import Center: press `Cmd-Shift-I`… `Sequencing Reads` tab… `ONT Run Folder` tile". Phantom `File > Import ONT Run` menu item is gone. Matches `ImportCenterViewModel.swift:270` tile + `MainMenu.swift` (no ONT menu item). |
| 7 | Removed phantom checkboxes (Orient "Keep unmapped reads"; length-filter "drop pair if either mate fails") | **LANDED** | ch07 lines 200-205: Orient pane = `Word Length`, `Database Mask` (dust/none), `Extra arguments`, "no keep-or-drop checkbox… a vsearch behavior". Matches `FASTQOperationToolPanes.swift:397-407`. ch04 line 69: length filter "applies per read; it does not have a 'drop the whole pair if one mate fails' option". Matches pane (`:333-337`, Min/Max only). |
| 8 | Primer Trimming tool = bbduk (not fastp) | **LANDED** | ch04 table row (line 38) = "bbduk (default) or cutadapt-linked", "K-mer 23, min k-mer 11, Hamming distance 1"; body line 79 matches. Confirmed `primer-remove --help`: `--engine bbduk` default, `--kmer 23 --mink 11 --hdist 1`, cutadapt-linked `--minimum-overlap 12 --error-rate 0.12`. |

Additional Round 1 items (beyond the eight headline fixes) also verified:

| Item | Status | Note |
|---|---|---|
| F5b: length-filter 30 bp default removed | **LANDED** | ch04 line 40/66: "Min Length and Max Length both blank (you set them)". Matches `filterByReadLengthMin/Max = nil`. The fictional `(fastp-trim, len30)` suffix is gone. |
| F7a: SRA "200 results" corrected | **LANDED** | ch02 line 82: "caps results at `--limit 20` by default". Confirmed `fetch sra search --limit (default: 20)`. |
| F7b: `--use-toolkit` and `--api-key` named | **LANDED** | ch02 lines 141, 170-171, 206-207 name both. Confirmed live. |
| F8a: "FASTQ tab" -> `Sequencing Reads` tab + `FASTQ Files` tile | **LANDED** | ch01 lines 38, 84. The top-level nav genuinely is a tab/segmented control (`ImportCenterViewModel.swift:145-181`) and the destination is the `FASTQ Files` tile (`:231`). Now accurate. |
| F8b: dead `File > Import > Project Sample Metadata` path | **LANDED** | Replaced by `lungfish metadata import <folder> <csv>` CLI (ch01 line 170-173). Confirmed `metadata import <folder-path> <csv-path> [--sync-bundles]`. |
| Trim Fixed Bases documented (was C2 gap) | **LANDED** | ch04 line 39 + dedicated subsection (lines 71-73); `fixed-trim --front/--tail`. The category's full six ops are now acknowledged (line 31 "holds six operations"). |
| Select Reads by Sequence documented (was C1 gap) | **LANDED** | ch06 dedicated subsection (lines 105-113); fields match `sequence-filter` exactly. |
| Remove Duplicates documented (was C5 gap) | **LANDED** | ch05 table row + line 71 ("`Preset` picker… substitution and optical-duplicate fields"). Matches pane `:363-375`. |
| `fastq materialize` named (was C3 gap) | **LANDED** | ch06 line 138. Confirmed subcommand exists. |
| import-fastq transforming defaults disclosed (was C7 gap) | **LANDED** | ch01 line 138 discloses `--quality-binning illumina4`, storage reorder, `--recipe`, `--dry-run`. |
| ONT `import-ont` + storage/binning + demux kits (was C4 gap) | **LANDED** | ch07 lines 46, 164, 167-173, 233-236. Unclassified default correctly inverted ("By default the importer skips… `--include-unclassified`… default is to skip", lines 151-154). Confirmed `import-ont --help`. |
| ENA glossed, interleaved glossed (accessibility) | **LANDED** | ch02 line 51 "ENA (the European Nucleotide Archive, EMBL-EBI's mirror…)"; line 219-221 "Interleaved means read 1 and read 2 alternate inside a single file". |

No MISSED items. No PARTIAL items among the eight headline fixes. The only
residual fidelity risks are smaller and listed in Part 2.

---

## PART 2: Three persona re-reads

### Persona A (novice): Dolores, wet-lab, importing her first FASTQ

Reads ch01 and ch02.

**Resolved.** Her two Round 1 full-stops are gone. The import now reads
"choose the `Sequencing Reads` tab and click the `FASTQ Files` tile" (ch01,
line 84), which is exactly what she sees on screen this time, so she completes
the GUI import. The metadata dead-end is replaced with a CLI line she can copy
(ch01, line 173). ENA is glossed at first use (ch02, line 51) and "interleaved"
is now defined in place (ch02, lines 219-221), both of which stopped her cold
last round.

**New problems from the revision.**

1. The literal green "Paired" badge is still asserted three times (ch01 lines
   72, 85, 97: "a green 'Paired' badge linking them"). I could not find the
   literal string `"Paired"` or a green-badge color in
   `ImportCenterViewModel.swift`; the tile descriptions only say "automatic
   pair detection" (`:232`). This is unverified at the view level (carried from
   ground-truth needs-human-check #3). For a novice the exact words on a badge
   are a landmark, so if the badge actually reads differently she stalls again.
   Should-fix: confirm the badge text/color against a screenshot before
   shipping, or soften to "a badge marking the two files as a pair".

2. ch01 line 138 is dense for her tier. The CLI-defaults paragraph
   ("`--quality-binning` defaults to `illumina4`, which re-quantises each base
   quality into one of four levels (the same scheme NovaSeq applies in
   hardware)…") is accurate and important, but it lands inside the
   "import from the command line" procedure where a bench novice has already
   been told she can ignore the CLI. Not a blocker; she skips it. Flag only as
   placement.

**Residual fidelity vs ground truth.** None that affect her. The SHA-256
checksum wording from Round 1 has been softened to "computes a checksum"
(ch01 line 144, no longer asserting the algorithm), which neatly sidesteps the
ground-truth needs-human-check #1.

### Persona B (intermediate): Marcus, RA doing QC and trimming

Reads ch03 and ch04.

**Resolved.** All three of his Round 1 wrong-action defects are fixed. The QC
menu path now stops at `QC & Reporting…` with the op picked in the dialog
(ch03, lines 41-42, 67-70). The length-filter pane is described correctly:
"`Min Length` and `Max Length`. Both fields are blank by default" (ch04, line
66), and the phantom drop-pair checkbox is explicitly denied (ch04, line 69).
The primer-trim tool is corrected to bbduk in the table (ch04, line 38) and
body (line 79). His praised QC explainer (Phred table, good/bad signatures) is
preserved intact (ch03, lines 89-153).

**New problems from the revision.**

1. ch04 table, "Quality Trim … Tool: fastp" and "Adapter Removal … Tool:
   fastp" (lines 36-37). These are correct (`quality-trim`/`adapter-trim` are
   fastp). But the lead sentence above the table now says "most of these run
   fastp, but primer trimming runs bbduk" (line 31) and the table also lists
   "Filter by Read Length … Tool: seqkit". So a careful reader sees three tools
   (fastp, bbduk, seqkit) but the prose only contrasts two. Minor: add seqkit
   to the "the tool matters" sentence or drop the count. Should-fix, clarity.

2. ch04 line 73, fixed-trim CLI is written `lungfish fastq fixed-trim --front N
   --tail N`, but the GUI pane labels are `5' Trim` / `3' Trim` (confirmed
   `FASTQOperationToolPanes.swift:329-330`). The chapter does name the pane
   labels correctly in the same paragraph ("Set `5' Trim` and `3' Trim`"), so
   the front/tail vs 5'/3' mapping is implicit but never stated. A scripter
   bridging GUI->CLI has to infer front=5', tail=3'. Should-fix: one clause.

**Residual fidelity vs ground truth.** None. The combined-trim provenance
command (`lungfish fastq trim`, ch04 line 60) is correct per `trim --help`.
The `--adapter` / `--no-adapter-trimming` / `--extra-args` additions (line 60)
are all real.

### Persona C (power-user / analyst): Priya, decontamination and subsetting

Reads ch05 (analyst) and ch06 (bench-scientist).

**Resolved.** This is the persona Round 1 hurt most, and the bleeding has
stopped. Every one of her five tool-identity / fabrication complaints is fixed:

- Remove Ribosomal RNA is Deacon-only with no RiboDetector toggle (ch05, line
  71), matching the single `Retain Reads` pane.
- Remove Contaminants is bbduk, and the troubleshooting note now correctly
  reasons about "bbduk… matches 31-mers" instead of "Deacon k-mers" (ch05,
  lines 39, 109).
- The non-existent "Decontamination plugin pack" is replaced with the two real
  managed databases `deacon-panhuman` / `deacon-ribokmers` (ch05, line 62),
  both confirmed in `DatabaseRegistry.swift`.
- The fabricated subsample seed is gone; ch06 line 75 tells her explicitly
  "do not record a seed in your methods for a Lungfish subsample", which
  directly answers her Round 1 "my methods sentence is a lie" complaint.
- Extract by ID is now a `Query` field with `ID`/`Description` + regex (ch06,
  lines 84-92), Extract by Motif is `Pattern` + regex only (lines 94-103), and
  the mismatch/strand behavior is correctly relocated to the newly documented
  Select Reads by Sequence op (lines 105-113). All three panes match source.

She would now keep ch05's "Should I decontaminate?" framework (lines 46-56) and
ch06's virtual-bundle explanation (lines 52-59, 129-139), both preserved.

**New problems from the revision.**

1. ch06 Procedure H2 now carries five lists and trips the bullet-cap linter
   three times (lines 88-92, 98-101, 109-113; see the bullet-cap section).
   For Priya this is not a fidelity issue but the per-operation step lists read
   as a wall of near-identical numbered blocks; restructuring into a compact
   table or H3-per-op (the H3s already exist, but the linter counts lists per
   H2, so the fix is to convert the step lists to prose or a parameter table)
   would help.

2. ch05 line 71 packs the three remaining panes (rRNA, Contaminants,
   Duplicates) into one dense paragraph. Accurate, but an analyst skimming for
   "what controls will I see for Remove Duplicates" has to parse a run-on.
   Should-fix, clarity only.

**Residual fidelity vs ground truth.** None material. ch05 line 85's CLI
mirrors are all correct (`scrub-human --database-id`, `deacon-ribo --retain`,
`contaminant-filter --mode`, `deduplicate`), confirmed live. The worked-example
removal-rate numbers (ch05 lines 94-101) remain illustrative, which the chapter
now frames as "typically report something like", an honest hedge.

### Persona D (power-user): Sam, ONT runs and CLI scripting

Reads ch07, skims CLI mentions across the section.

**Resolved.** Both Round 1 blockers are fixed. The phantom `File > Import ONT
Run` is replaced everywhere by the Import Center route (ch07, lines 41-42,
141-143), and the phantom Orient "Keep unmapped reads" checkbox is gone,
replaced by an accurate three-control pane description plus the honest "a
vsearch behavior, not a Lungfish setting" (ch07, lines 200-205, 219-224). The
scriptable path he wanted is now front and center: `lungfish fastq import-ont
<dir> -o <out>` (line 46), with `--include-unclassified`, `--storage-mode`,
`--optimize-storage`, `--quality-binning` all documented (lines 164-173) and
all confirmed in `import-ont --help`. Crucially the unclassified default is now
stated correctly ("the default is to skip", line 154), reversing the Round 1
inversion. He also gets the demultiplex escape hatch (lines 233-236) with real
ONT kit names.

**New problems from the revision.**

1. ch07 line 51 still calls ONT reads "unstranded by default". `unstranded`
   was flagged in Round 1 as needing a gloss for the declared bench-scientist
   tier. The chapter does gloss it inline ("meaning the read in the FASTQ may
   correspond to either strand", lines 51-52), so this is actually resolved.
   No action.

2. ch07 declared tier is still `bench-scientist`, yet the chapter remains the
   most power-user content in the section (Dorado model strings, worker
   threads, vsearch word length, POD5 squiggle). Round 1 flagged this; the
   editor chose to keep `bench-scientist` and add inline glosses
   (`basecaller` line 35, `worker thread` line 35, `squiggle` line 242) rather
   than reclassify. Defensible, but `Word Length` "the seed length vsearch
   uses" (line 200) and `Database Mask`/`dust` (line 201) are bench-opaque.
   Should-fix: either reclassify to `power-user` or gloss `dust`/seed once.

3. ch07 line 173, "The defaults leave the read bytes unchanged; the binning and
   reordering options do not." The double negative ("do not [leave unchanged]")
   is correct but easy to misread as "the options also leave bytes unchanged".
   Should-fix: reword to "the binning and reordering options change them."

**Residual fidelity vs ground truth.** None. `import-ont` default
`--storage-mode chunked` and `--quality-binning none` match the doc (lines
167-172). The ONT/Illumina comparison-table numbers (lines 79-85) remain
illustrative as labeled.

---

## Round 2 fixes for editors

Prioritized. Must-fix = fidelity (a reader performs a wrong action or cites a
false fact). Should-fix = clarity/style/accessibility. The bullet-cap warnings
are listed first because they are mechanical and the brief called them out.

### Must-fix (fidelity)

There are no remaining hard fidelity defects. Every Round 1 critical fix
landed and matches the live binary. Two items are fidelity-adjacent and need a
human view-level check rather than a code check:

1. **ch01: literal green "Paired" badge (lines 72, 85, 97).** The string
   `"Paired"` and its color are not in the Import Center view model
   (`ImportCenterViewModel.swift` only describes "automatic pair detection").
   Either confirm the badge text and color against the running app (a screenshot
   is planned: `import-center-fastq`) or soften to "a badge marking the two
   files as a pair". Until confirmed, treat the specific word + color as
   unverified. (Carries ground-truth needs-human-check #3.)

2. **ch01: `metadata import` sync semantics (line 170).** The chapter says
   `--sync-bundles` writes a per-bundle `metadata.csv`; the CLI help says it
   "syncs metadata to per-bundle metadata.csv files". Consistent, but the
   chapter also asserts the folder-level write produces `samples.csv` only
   implicitly. Low risk; confirm the file names against one real run if a
   screenshot is taken.

### Bullet-cap warnings (mechanical, must restructure to clear the linter)

Linter output, `lint-chapter.mjs`, 2026-06-02 (warnings, not errors, so they
ship but carry a review note):

1. **`02-downloading-from-sra.md`, lines 120-131.** Warning: "3rd list in this
   H2 section. Cap is 2 lists per section." This is the numbered worked-example
   list under `### Worked example: SRR36291587`. The linter counts lists per
   H2, and `### Worked example` sits inside the `## Procedure` H2 alongside the
   two `### Search the SRA` / `### Download a run` lists. Fix: promote
   `### Worked example` content so its steps are prose, or split `## Procedure`
   so each sub-task is its own H2, or convert the worked-example steps to a
   short prose paragraph (it is only four steps).

2. **`06-subsetting-and-extraction.md`, lines 88-92, 98-101, 109-113.** Warnings
   for the 3rd, 4th, and 5th lists in the `## Procedure` H2. These are the
   per-operation step
   lists (Extract Reads by ID, Extract Reads by Motif, Select Reads by
   Sequence). The H3 subheadings already exist but do not reset the count.
   Fix: convert the five per-op step blocks into a single parameter table
   (operation x field x default x note), keeping at most two genuine lists in
   the H2; or split `## Procedure` into one H2 per operation group. A table is
   the better fit here because the ops are parallel and the steps are nearly
   identical ("open dialog, select op, set field, Run").

No other chapter trips the linter (01, 03, 04, 05, 07 report "no issues
found").

### Should-fix (clarity / style / accessibility)

1. **ch04 line 31 + table:** the "the tool matters" sentence contrasts fastp
   vs bbduk but the table introduces a third tool (seqkit, for Filter by Read
   Length). Mention seqkit in the sentence or drop the two-way framing.

2. **ch04 line 73:** state the front/tail = 5'/3' mapping explicitly so a
   reader bridging the GUI pane (`5' Trim`/`3' Trim`) to the CLI (`--front`/
   `--tail`) does not have to infer it.

3. **ch05 line 71:** the three remaining panes (rRNA, Contaminants,
   Duplicates) are crammed into one run-on paragraph. Break into three short
   sentences or a tiny "pane controls by operation" table so an analyst can
   scan for the op they need.

4. **ch07 line 173:** reword the double negative "the binning and reordering
   options do not [leave the read bytes unchanged]" to a positive "the binning
   and reordering options change them."

5. **ch07 tier / glosses:** either reclassify the chapter to `power-user` or
   gloss `dust` (low-complexity masking) and "seed length" once. The rest of
   the power-user vocabulary is already glossed inline.

6. **ch01 line 138 placement:** the transforming-defaults paragraph
   (quality-binning, storage reorder) is important and accurate but is buried
   in the CLI procedure where a bench reader has been told to skip. Consider
   surfacing the one load-bearing fact (import is not byte-identical by default)
   into the "What gets recorded at import" section so GUI-only users see it too.

7. **Cross-section refrain:** the closing "Run X on every new bundle / decide
   explicitly and record" exhortation recurs in 01, 03, 05, 06. Still a little
   repetitive across the set; vary the phrasing in at least two of them. Carried
   from Round 1; lower priority now that the fidelity is sound.

8. **Citation surface:** chapters now name fastp, bbduk, Deacon, seqkit,
   vsearch, clumpify by tool. Part II still has no citation/link surface for
   these. When the citation mechanism lands, this section is a prime consumer.
   Tracking item, not a Round 2 blocker.

### What to keep (survived Round 1, still strong)

- ch03's QC explainer end to end (Phred table lines 95-99, good/bad signatures
  lines 107-153, decision rule lines 176-182). Unchanged and still the best
  content in the section.
- ch04's FASTQ-vs-BAM primer-trim decision (lines 83-89). The `ivar`-consults-
  alignment rationale is intact.
- ch05's "Should I decontaminate?" three-question framework (lines 46-56) and
  the sensitivity-vs-specificity framing.
- ch06's virtual-bundle / materialization explanation (lines 52-59, 129-139),
  now strengthened by naming `fastq materialize`.
- ch07's basecaller-model / Medaka-match warning (lines 96-111) and the
  POD5/FAST5/adaptive-sampling scoping section (lines 238-251).
- The scope line every chapter now opens with ("This chapter covers X; for
  adjacent topic Y see chapter Z"). Implemented across all seven and reads well.

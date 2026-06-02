# 04-alignments review, round 2

Iterative simulated-reader review, round 2 of the five chapters under
`docs/user-manual/chapters/04-alignments/`. Round 1 editors revised the chapters
from the Round 1 synthesis. This pass verifies the critical fidelity fixes
landed, re-reads as three personas (novice, intermediate, power-user), and flags
residual or newly-introduced problems. Every claim is re-checked against the
Swift source and the built `./.build/debug/lungfish-cli` help, not just against
the prior review text. No chapters were edited in this pass.

## Source re-verification performed for this round

To avoid trusting the revised prose, I re-confirmed the load-bearing facts
directly against code and the built CLI:

- `lungfish-cli markdup --help`: positional `<path>` (a BAM or directory), no
  `--in`/`--out`, only output-redirecting flag is `--deduplicated-bundle`. The
  in-place replace is `fm.replaceItemAt(bamURL, withItemAt: tempBamURL)`
  (`Sources/LungfishCLI/Commands/MarkdupCommand.swift:312`).
- Preset display names from `MappingTool.swift:204-227`: `.defaultShortRead` =
  "Short-read" / token `sr`; `.minimap2MapONT` = "Oxford Nanopore" / `map-ont`;
  `.minimap2MapHiFi` = "PacBio HiFi" / `map-hifi`; `.minimap2Asm5` =
  "Assembly-to-assembly" / `asm5`; `.minimap2Splice` = "Spliced CDS/cDNA" /
  `splice`; `.minimap2MapPB` = "PacBio CLR" / `map-pb`.
- Mapping wizard sections (`MappingWizardSheet.swift:321-329, 362-503`):
  Reference, Preset/Mode (title `initialTool == .minimap2 ? "Preset" : "Mode"`,
  line 411), Read Group, Input Compatibility, Advanced Settings. No Reads
  picker, no Tool picker.
- Built-in scheme manifest
  (`Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/manifest.json`):
  `"primer_count": 563`, `"amplicon_count": 223`, `"display_name": "QIAseq
  Direct SARS-CoV-2 with Booster A"`, canonical accession `MN908947.3`.
- Zoom handler (`ZoomShortcutHandler.swift:28`): `guard
  modifiers.contains(.command) else { return false }`; `"+"/"="` zoom in,
  `"-"/"_"` zoom out (lines 48-52).
- Soft-clip rendering (`ReadTrackRenderer.swift:92, 1473-1507`): `softClipColor`
  with alpha dimming, semi-transparent extensions at clipped ends. No
  hard-clip-and-remove path for primer trim.
- Viral Recon tool placement
  (`FASTQOperationDialogState.swift:1070`): `.mapping` category returns
  `[.minimap2, .bwaMem2, .bowtie2, .bbmap, .ontGenotyping, .viralRecon]`.
  `MainMenu.swift` has "Workflow Operations…" (line 710), "Workflow Builder",
  and "Workflow Library", but no "Workflows" menu and no Viral Recon menu item.
- Fixture attribution: `docs/user-manual/fixtures/sarscov2-srr36291587/README.md:3-4`
  states "Reads: SRR36291587 (QIAseq Direct SARS-CoV-2, paired-end Illumina,
  86,281 read pairs)." The fixture is QIAseq Direct, not ARTIC. This is the
  arbiter for the Round 1 ARTIC-vs-QIAseq contradiction.

Mechanical style check: all five chapters contain **0 em dashes**. No banned
hype words (`powerful`, `revolutionary`, etc.) present. Bullet lists are within
the 5-item / 2-list-per-H2 cap.

---

## PART 1: Verification table (critical Round 1 fidelity fixes)

| # | Round 1 fix | Status | Note (confirmed in current text) |
|---|---|---|---|
| 1 | **markdup in-place + data-loss warning + `--deduplicated-bundle` escape hatch** | **LANDED** | Ch04 lines 70-82. `lungfish markdup path/to/alignment.bam` (positional, no `--in`/`--out`). Explicit "marks duplicates **in place**: it replaces the input BAM and does not write a separate output file. There is no `--in` or `--out` flag." Scripting warning present (line 74): "if you wrap `markdup` in a loop over a cohort, it overwrites every source BAM, so copy the originals first if you need to keep them." Escape hatch present (lines 76-82): `--deduplicated-bundle path/to/dedup.lungfishref` "writes a sibling `.lungfishref` with duplicate reads removed and leaves the input untouched," with the GUI equivalent named. See dedicated power-user verification below. |
| 2 | **Viral Recon real menu path (no Workflows menu)** | **LANDED** | Ch05 line 33: "There is no 'Workflows' menu in Lungfish. You reach Viral Recon at `Tools > FASTQ/FASTA Operations > Mapping…`, then by clicking the **Viral Recon** tool row in the Mapping category." Parenthetical disambiguates the separate "Workflow Operations…" generic runner. Procedure step 2 (line 83) and front-matter `entry_points` (line 11) both use the real path. Ch01 cross-reference (lines 310-318) also corrected to the Mapping-dialog tool row. |
| 3 | **Viral Recon SARS-CoV-2-amplicon scoping** | **LANDED** | Ch05 line 31: "The wizard is **SARS-CoV-2-specific**, not a general viral pipeline. Its own subtitle reads 'SARS-CoV-2 consensus and variant analysis from FASTQ bundles.'" Reference = built-in `MN908947.3` or Local FASTA; protocol "always **amplicon**"; primer scheme "**required** to run (it is a readiness gate, not an optional extra)." GUI-generates-samplesheet vs CLI-supplies-samplesheet split is explicit (lines 43-44). Mixed-platform refusal documented (line 53). Default skip set `[Assembly, Kraken2]` documented (line 92). |
| 4 | **Zoom keys Cmd-= / Cmd--** | **LANDED** | Ch02 lines 103-111: "Press `Cmd-=` (or `Cmd-+`, or keypad `+`) to zoom in and `Cmd--` (or keypad `-`) to zoom out; bare `=` and `-` do nothing. **Arrow Up** also zooms in and **Arrow Down** zooms out... These match the Zoom In and Zoom Out items in the menu bar." Matches `ZoomShortcutHandler.swift` exactly, including the Arrow Up/Down addition Round 1 requested. |
| 5 | **Soft-clip, not hard-clip (ch02/ch03 reconciliation)** | **LANDED** | Ch02 lines 58-63 now read: "the primer-derived ends become **soft-clipped**: they stay in the record at their original length and remain faintly visible at amplicon edges, but pileup and coverage exclude them. The trim never deletes bases or removes reads. Chapter 03 is the canonical explanation of this behaviour." The Round 1 "hard-clipped and disappear from the view entirely" text is gone. Ch02 and Ch03 now agree and both match code. |
| 6 | **223 amplicons / 563 primers + Booster A display name** | **LANDED** | Ch03 table (line 101) and step 3 (line 138): "223" amplicons, "563" primers; picker label "QIAseq Direct SARS-CoV-2 with Booster A (Built-in)" with the internal manifest name `QIASeqDIRECT-SARS2` correctly distinguished for the bundle folder and `--scheme` path (lines 93-97). Matches manifest. The self-contradiction (verify-in-dialog said 223, prose said 422) is resolved. |
| 7 | **Mapping preset GUI labels vs CLI tokens** | **LANDED** | Ch01 table (lines 101-108) is split into "GUI preset label" and "CLI `--preset` token" columns: Short-read/`sr`, Oxford Nanopore/`map-ont`, PacBio HiFi/`map-hifi`, plus Assembly-to-assembly/`asm5`, Spliced CDS/cDNA/`splice`, PacBio CLR/`map-pb`. Matches `MappingTool.swift`. BBMap's separate "Standard"/"PacBio" modes are now noted (lines 110-114). |
| 8 | **Mapping wizard has no Reads/Tool picker (select-then-open model)** | **LANDED** | Ch01 lines 35-41 and Procedure (lines 175-201): "You do not pick the reads or the mapper inside the mapping wizard. Instead you select the FASTQ bundle in the sidebar first, then open `Tools > FASTQ/FASTA Operations > Mapping…` and click the row for the mapper you want." Wizard sections named correctly: "Reference, Preset (titled 'Mode' for non-minimap2 mappers), Read Group, Input Compatibility, and Advanced Settings. There is no Reads picker and no mapper picker inside the wizard." |
| 9 | **`lungfish bam filter` coverage (the missing QC toolset)** | **LANDED** | Ch04 lines 99-125: new "Filtering a BAM before variant calling" section with the full flag table: `--mapped-only`, `--primary-only`, `--min-mapq <n>`, `--exclude-marked-duplicates`, `--remove-duplicates`, `--exact-match`, `--min-percent-identity <p>`. Mutual-exclusion pairs noted, GUI equivalent "Create Filtered Alignment" named, and a recommended shotgun pre-call filter given. Matches `BAMCommand.swift` flag set from ground truth. |
| 10 | **Fixture scheme attribution (ARTIC v3 vs QIAseq)** | **LANDED** | Ch04 line 155 now reads "a SARS-CoV-2 amplicon library, primer-trimmed against the built-in QIAseq Direct SARS-CoV-2 scheme as described in [Primer Trimming]". The Round 1 "ARTIC v3" label is gone. Matches the fixture README (QIAseq Direct) and Ch03. Arbiter confirms QIAseq is the correct attribution. |
| 11 | **Invented track names reconciled to a code-true pattern** | **LANDED (partial across the manual)** | Within section 04 the convention is now consistent: managed runs adopt "minimap2 Mapping" (tool name + "Mapping"), the value is user-renamable, and CLI uses `--name` (Ch01 lines 228-231; Ch02 lines 87-90; Ch03 lines 130, 148-151). No invented `SRR36291587 (minimap2 sr)` or `.bam` filenames remain in section 04. NOTE: chapter 05-variants (outside this section) still uses `SRR36291587 (minimap2) - Primer-trimmed (QIASeqDIRECT-SARS2)` as an auto-populated name. That is a cross-section consistency item for the 05 reviewer, not a 04 regression. |

### Special attention: markdup data-loss safety (power-user must not lose source BAMs)

Both required safety elements are present and clear:

1. **The in-place warning is unambiguous.** Ch04 line 74: "it replaces the input
   BAM with the marked version and does not write a separate output file. There
   is no `--in` or `--out` flag. This matters for scripting: if you wrap
   `markdup` in a loop over a cohort, it overwrites every source BAM, so copy
   the originals first if you need to keep them." This is the exact hazard
   Round 1 flagged (the false "original is preserved" promise) and it has been
   inverted to the correct, loud warning.

2. **The escape hatch is present and correct.** Ch04 lines 76-82:
   `lungfish markdup path/to/alignment.bam --deduplicated-bundle path/to/dedup.lungfishref`,
   described as writing "a sibling `.lungfishref` with duplicate reads removed
   and leaves the input untouched," with the GUI equivalent "Create Deduplicated
   Bundle" named. This matches `MarkdupCommand.swift` (`--deduplicated-bundle`
   is the only output-redirecting flag, line 45) and the built CLI help.

The one residual nuance (minor, not data-loss): the escape hatch produces a
duplicate-*removed* bundle, whereas in-place `markdup` only *marks* (keeps the
reads, sets the flag). The chapter states this correctly ("duplicate-*removed*
copy," line 76) but a fast reader could conflate "mark" and "remove." See
should-fix S1.

---

## PART 2: Three persona re-reads

### Persona A: Maria Okonkwo, novice, mapping reads for the first time (ch01, ch02)

**Resolved pain points.** The two failures that stopped her cold in Round 1 are
gone. The wizard no longer promises a Reads picker or a Tool picker; the new
opening (Ch01 lines 35-41) tells her plainly that she selects the bundle in the
sidebar first and clicks the mapper row, and "The wizard that opens already
knows the reads (your sidebar selection) and the mapper (the row you clicked);
it asks you only for the reference and the preset." The preset table now shows
the GUI label she will actually see ("Short-read") in its own column, separated
from the `sr` CLI token she would never find in the menu. The worked-example
result name is now the real one: "A managed run adopts the track under the
default display name 'minimap2 Mapping'" (Ch01 line 228).

The two passages Round 1 singled out as her favourites survive intact: the
preset-is-about-data-type framing (Ch01 lines 43-49) and the "Very low mapping
rate" troubleshooting (Ch01 lines 284-292).

**New problems.**

- **Audience-tier creep in the worked example.** Ch01 line 232: "expect a
  mapping rate above 95% and mean coverage in the hundreds or thousands." Fine.
  But the Read Groups section (lines 123-153) drops `@RG`, `SM`, `ID`, `LB`,
  `PU`, GATK, and joint-genotyping on a `bench-scientist`-tier chapter with no
  primer. For Maria this is a wall of acronyms two screens before her worked
  example. It is fidelity-correct and useful to an intermediate reader, but it
  is the densest thing in a novice chapter. Not a fidelity break; a leveling
  concern (should-fix S2).

- **"FLAG bits" unglossed.** Ch01 line 120: "the BAM records FLAG bits that mark
  each read as first-of-pair or second-of-pair." Maria has no model of SAM
  FLAGs. One clause of plain English ("a per-read marker") would carry her.

**Residual fidelity issues.** None in ch01/ch02 for the novice path. The zoom
keys, the soft-clip description, and the track names are all now code-true.

> Maria, re-read: "This time the manual and the dialog agree. I selected my
> FASTQ, opened Mapping, clicked minimap2, and the wizard asked me for exactly
> the two things the manual said it would. The only place I drifted off was the
> Read Group box full of two-letter codes, but the manual did tell me the
> defaults are fine, so I left it alone and kept going."

### Persona B: David Reyes, research associate / core lab, reading a pileup (ch02, ch03)

**Resolved pain points.** The five-second credibility killer is fixed: zoom is
now `Cmd-=` / `Cmd--` with the keypad variants and the Arrow Up/Down shortcut he
said he would actually reach for (Ch02 lines 103-107). The soft-clip-vs-hard-clip
contradiction that ended his trust in Round 1 is resolved; Ch02 now says
soft-clipped, original length retained, faintly visible (lines 58-63), agreeing
with Ch03. The colour channels he uses daily are now documented: "By pair," "By
insert size," "By split read," "By read group" (Ch02 lines 215-222), with the
correct framing that an analyst chasing a structural variant switches from
strand to insert size.

The accessibility gap he raised is also addressed: Ch02 lines 48-52 now give two
non-colour cues for strand ("forward and reverse reads point opposite ways" and
"the Inspector reports per-strand depth as numbers"), and line 98 gives a
keyboard path to depth ("jump to the position (step 3) and read depth from the
status bar and the Inspector instead") rather than hover-only.

**New problems.**

- **Coverage histogram "split by strand" claim needs a careful read against the
  default.** Ch02 lines 42-45 and 94-96 state the histogram is "split the same
  way: forward-read depth and reverse-read depth stack as two tinted bands."
  Ground truth (ch02 missing-feature item 3) confirms `forwardCoverageColor` /
  `reverseCoverageColor` exist, so this is code-true. But the chapter presents
  the strand-split histogram as the unconditional default appearance, while the
  source renders strand split as part of the strand colour mode. If a reader
  switches the read colour channel to "By insert size," does the histogram stay
  strand-split or follow the channel? The chapter does not say, and I did not
  trace the coupling. NEEDS-HUMAN-CHECK whether the coverage band split is tied
  to the strand colour mode or always-on. Low harm either way.

- **Position 21618 biology is now stated more confidently than Round 1.** Ch02
  lines 141-148 assert position 21618 "sits inside the spike gene and will be
  called as a variant in the next chapter." Ground truth flagged the 21618
  pileup narrative as a fixture/data claim it could not verify from code
  (ch02 uncertain item 1). The chapter dropped the unverifiable "L452R-adjacent"
  phrasing from Round 1 (good) but still commits to "inside the spike gene" and
  a guaranteed variant call. This is a data claim; it should be confirmed
  against `ivar.expected.vcf` in the fixture before ship. NEEDS-HUMAN-CHECK
  (carried from ground truth, not a new code break).

**Residual fidelity issues.** None that contradict code. The two items above are
a coupling question and a fixture-data confirmation, not wrong claims.

> David, re-read: "Zoom works on the first try now, and they finally listed the
> insert-size colour mode, which is the one I live in. The hard-clip line that
> made me close the manual last time is gone. I'd still like one sentence on
> whether the strand-split coverage follows the colour mode I picked, but that's
> a refinement, not a lie."

### Persona C / D combined: Aisha Bello (advanced, primer trim) and Tomás Lindgren (power-user, scripting markdup / bam filter / Viral Recon) (ch03, ch04, ch05)

**Resolved pain points.**

- **Amplicon count and scheme name (Aisha).** Ch03 now says 223 amplicons / 563
  primers and the picker label "QIAseq Direct SARS-CoV-2 with Booster A
  (Built-in)," with the internal `QIASeqDIRECT-SARS2` name correctly reserved
  for the bundle folder and `--scheme` path (lines 93-97, 101, 138). The
  step-3 self-contradiction (prose 422 vs dialog 223) is gone. She can now find
  the scheme by the name she actually sees.

- **`--target-reference` (Aisha).** Now documented, Ch03 lines 171-176:
  "`--target-reference` overrides the contig name (`@SQ SN`) used to resolve the
  scheme against the BAM... if you mapped to a reference whose contig is named
  differently from the scheme accession, pass the BAM's contig name." This is
  exactly the override she needed and it matches `BAMPrimerTrimSubcommand.swift`.
  The output subdirectory she wanted for her audit is also stated:
  "`alignments/primer-trimmed` directory" (line 151).

- **`markdup --in/--out` data-loss hazard (Tomás).** Fully fixed; see the
  dedicated verification above. His "this could have cost me a dataset" sentence
  no longer applies: the prose now warns that the command mutates in place and
  gives the `--deduplicated-bundle` escape hatch.

- **`bam filter` (Tomás).** The single largest Round 1 coverage gap is closed.
  Ch04's new "Filtering a BAM before variant calling" section (lines 99-125)
  gives the whole flag set with a worked invocation and a recommended shotgun
  pre-call combination. This is the QC toolset he expected the chapter to name.

- **Viral Recon menu path and scope (Tomás).** Both fixed. He no longer concludes
  the feature was cut: Ch05 line 33 names the real path and explicitly says there
  is no Workflows menu. The SARS-CoV-2-amplicon-only scope is stated up front
  (line 31), so he will not waste a session trying to run a non-SARS virus
  through the GUI. The GUI-generates-samplesheet vs CLI-supplies-samplesheet
  distinction (lines 43-44) and the mixed-platform refusal (line 53) are both
  present.

**New problems.**

- **Ch03 entry-point front matter: confirm the FASTQ-trim path was removed.**
  Round 1's item 3 was that the front-matter `entry_points` listed
  `Tools > FASTQ/FASTA Operations > Trimming & Filtering > Primer Trimming`,
  which is the wrong (FASTQ-level) feature. The current front matter (Ch03
  lines 10-12) lists only `Inspector > Analysis > Primer-trim BAM…` and
  `CLI: lungfish bam primer-trim`. **This is correct now** and the bad path is
  gone. I note it here only because it was a Round 1 must-fix and I want the
  record to show it LANDED. (Not repeated in Part 1's table for space; treat as
  fix 12 = LANDED.)

- **Ch04 markdup pipeline parenthetical.** Ch04 line 73: "The command wraps
  `samtools markdup` (sort, mark, index)." Ground truth (ch04 item 2) said the
  underlying `AlignmentMarkdupPipeline` runs a collate/fixmate/sort/markdup
  chain and the exact stage list is not enumerated in `MarkdupCommand`. The
  Round 1 synthesis suggested the fuller "(collate, fixmate, position-sort,
  mark, index)" wording. The current "(sort, mark, index)" matches the CLI
  provenance step labels (sort -> markdup -> index) but understates the fixmate
  step. This is cosmetic and directionally correct; a power-user auditing
  provenance might want the fixmate stage named. Should-fix S3.

- **Ch05 CLI option table contains a table-syntax risk.** Ch05 line 111:
  `` | `--executor <docker|conda|local>` | ``. The literal pipe characters
  inside the inline code span sit inside a Markdown table cell. Depending on the
  renderer, the un-escaped `|` can break the table or be read as a column
  delimiter. This is a rendering/style risk, not a fidelity error (the flag
  itself is correct). Should-fix S4: render as `docker`, `conda`, or `local` in
  prose, or escape the pipes.

- **Ch05 default-versus-choice density.** Ch05 procedure step 3 (line 92) packs
  every default into one sentence: "executor Docker, workflow version 3.0.0,
  minimum mapped reads 1000, memory 8.GB, variant caller iVar, and consensus
  caller BCFtools; the skip toggles default to skipping Assembly and Kraken2."
  All correct against `ViralReconWizardSheet.swift:31-34`, but it is six
  defaults in one breath. A small table would read better for a power-user
  scanning for one value. Should-fix S5 (style only).

**Residual fidelity issues.** None against code. The markdup pipeline wording
(S3) understates fixmate but is not wrong; the rest are style/rendering.

> Tomás, re-read: "The markdup page is safe now: it tells me it overwrites in
> place and gives me `--deduplicated-bundle` if I want to keep the source. And
> `bam filter` is finally documented, which was the whole reason I open this
> chapter. Viral Recon is where the manual says it is, in the Mapping dialog,
> and it admits it is SARS-only so I won't fight it for a non-SARS run. The one
> thing I'd polish is the executor row with the bare pipes inside the code
> span; it renders oddly in my viewer."

> Aisha, re-read: "223 amplicons, 563 primers, and the scheme is named the way
> the picker names it. `--target-reference` is documented, which I need for my
> contig naming. The 'Why this matters' phantom-variant section is still the
> best version of that explanation I've read, and they didn't touch it."

---

## Round 2 fixes for editors

All ten critical Round 1 fidelity fixes (plus the ch03 front-matter entry-point
fix, twelve total) LANDED. Nothing in section 04 now contradicts the code. The
remaining items are minor.

### Must-fix (fidelity / data accuracy)

None in section 04. Every code-checkable claim matches source. Two **data
claims** carried over from ground truth still need a human to confirm against the
fixture before ship (they are not code breaks, but they are assertions only the
fixture can validate):

- **M1 (carry-over, NEEDS-HUMAN-CHECK).** Ch02 lines 141-148 assert position
  21618 "sits inside the spike gene and will be called as a variant in the next
  chapter." Confirm against `docs/user-manual/fixtures/sarscov2-srr36291587/ivar.expected.vcf`
  that 21618 is (a) within the spike CDS and (b) a PASS call in the iVar output.
  If either is false, soften to a representative coordinate that the fixture
  actually calls.
- **M2 (carry-over, NEEDS-HUMAN-CHECK).** Ch04 line 155 worked-example numbers
  ("mean coverage near 800x and >99% mapped") and Ch01 line 232 ("mapping rate
  above 95% and mean coverage in the hundreds or thousands") are fixture-data
  claims. Confirm they match the regenerated fixture's actual Inspector readout.

### Should-fix (clarity / style / leveling)

- **S1 (clarity).** Ch04 line 73-82: make the mark-versus-remove distinction
  one beat sharper. In-place `markdup` *marks* (flags, keeps reads);
  `--deduplicated-bundle` *removes*. The text is correct but a fast reader can
  conflate the two verbs. One added clause ("in-place marking keeps every read
  and only sets the duplicate flag, whereas `--deduplicated-bundle` drops the
  flagged reads") would prevent the conflation.

- **S2 (leveling, novice).** Ch01 Read Groups section (lines 123-153) is
  intermediate-density on a `bench-scientist` chapter: `@RG`, `SM`, `ID`, `LB`,
  `PU`, GATK, joint genotyping arrive with no primer. Consider a one-line "skip
  this box if you are not feeding GATK" signpost at the top of the section so a
  novice knows it is optional, or move the read-group field detail to an
  intermediate aside. The defaults-are-fine reassurance exists (line 148) but
  arrives after the dense block, not before it.

- **S3 (provenance precision, power-user).** Ch04 line 73: "(sort, mark, index)"
  understates the pipeline; the underlying `AlignmentMarkdupPipeline` also runs
  collate/fixmate before sort. For an audit-minded reader, "(collate, fixmate,
  sort, mark, index)" is more faithful. Optional, since the CLI provenance
  labels are sort/markdup/index.

- **S4 (rendering).** Ch05 line 111: the inline code span
  `` `--executor <docker|conda|local>` `` contains un-escaped pipes inside a
  table cell, which can break table rendering. Rewrite the Meaning cell to
  reference `docker`, `conda`, or `local` in prose, or escape the pipes
  (`\|`), or drop the angle-bracket enumeration and describe the three values
  in the cell text.

- **S5 (scannability).** Ch05 procedure step 3 (line 92) lists six defaults in a
  single sentence. A compact "Default settings" table (Setting / Default) would
  let a reader find one value without parsing a run-on. Style only; the values
  are all correct.

- **S6 (novice glossary).** Ch01 line 120 "FLAG bits" and the broader SAM-FLAG
  references would benefit from a four-word gloss for the bench-scientist tier.
  Minor.

### Keep (do not touch in round 3)

These survived Round 1 revision correct and well-pitched; preserve them:

- Ch03 "Why this matters" phantom-variant explanation (lines 60-87) and the
  soft-clip-not-delete framing (lines 38-44). Still the canonical soft-clip
  explanation the section defers to.
- Ch03 iVar defaults (step 4, lines 140-144) and `lungfish primers import`
  (lines 116-119): confirmed correct, unchanged.
- Ch01 preset-is-about-data-type framing (lines 43-49) and Troubleshooting
  (lines 280-307).
- Ch02 artefact-vs-real-variant heuristics (lines 141-153) and the Inspector
  field table (lines 161-167); the new non-colour strand cues (lines 48-52).
- Ch04 Thresholds-by-workflow table (lines 88-95) and the markdup-for-shotgun /
  skip-for-amplicon rule with the 80-95% amplicon-duplicate explanation
  (lines 40, 146-147).
- Ch05 CLI option table (lines 109-122, modulo the S4 pipe-escaping), the
  `--timeout not supported` note (line 139), the `viralrecon` shorthand
  (line 63), and `provenance bibliography` (line 145).

### Cross-section note (not a 04 fix)

Track-naming convention is now internally consistent inside section 04
("minimap2 Mapping" default, user-renamable, CLI `--name`). However
`docs/user-manual/chapters/05-variants/` still uses the long auto-populated form
`SRR36291587 (minimap2) - Primer-trimmed (QIASeqDIRECT-SARS2)`
(05-variants/01 line 152, 05-variants/03 line 78). For whole-manual consistency,
the 05-variants reviewer should reconcile that name against the section-04
convention. Flagging here only because section 04 cross-references those
chapters; no edit to section 04 is implied.

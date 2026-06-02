# 04-alignments focus group, round 1

Simulated-reader focus group on the five chapters of Part II 04-alignments, read as a unit against the ground-truth reality map at `../ground-truth/04-alignments.md`. Four named biologist personas, novice to power-user. Every fidelity break below is anchored to a quoted chapter line and the ground-truth citation that contradicts it. This is round 1 of 3. No chapters were edited.

## Part 1: Personas

### Persona A: Maria Okonkwo, novice, mapping reads for the first time

Maria is a wet-lab virologist three weeks into using Lungfish. She has a SARS-CoV-2 FASTQ pair and a reference, and she opens chapter 01 to map them. She follows procedures literally and trusts that menu paths and button labels are exact.

**Where she gets stuck.**

The chapter sells her a tidy three-section wizard. Line 131: *"The wizard has three sections (Reads, Reference, Tool), all visible at once."* Step 2: *"Under **Reads**, click the picker and choose your FASTQ bundle."* Step 4: *"Under **Tool**, leave the mapper at minimap2."* Maria opens the Mapping dialog and there is no **Reads** picker and no **Tool** picker. Ground truth is blunt: the wizard sections are Reference, Preset/Mode, Read Group, Input Compatibility, and Advanced Settings; the reads come from her sidebar selection and the mapper is chosen by which tool row she clicked, not from a control inside the wizard. Maria scrolls the dialog up and down looking for the Reads picker the manual promised, decides she has the wrong dialog open, and closes it. She is now stuck before step 3.

> "The manual told me to click a Reads picker. There isn't one. So either I'm in the wrong place or the manual is wrong, and I can't tell which. As a beginner that's exactly the moment I give up and email someone."

The preset table makes it worse. Lines 84-87 tell her to pick **Short read (sr)**, **Map ONT (map-ont)**, **Map HiFi (map-hifi)**. The actual menu labels (ground truth, chapter 01 item 1) are "Short-read", "Oxford Nanopore", "PacBio HiFi". Maria reads "Short read (sr)", scans the menu for a row containing "sr", and does not find one. The literal CLI tokens `sr` / `map-ont` / `map-hifi` she was told to look for live only on the command line.

**The worked example dead-ends on the result.** Line 174: *"A new track named `SRR36291587 (minimap2 sr)` will be present."* Ground truth (chapter 01 item 3): nothing generates that parenthetical name; managed runs default to "minimap2 Mapping". Maria expands the sidebar, sees a track called "minimap2 Mapping", and is not sure it is the one the manual meant.

**Accessibility.** The zoom and navigation gaps land harder on a novice because she cannot guess the workaround. She is also the reader most dependent on the planned screenshots (`mapping-dialog-overview`), which are not yet shipped (`shots: []`), so the only model she has of the dialog is the prose that does not match it.

**What she liked.** The conceptual framing is genuinely good for her level. *"The preset ... is named for the *data type* ... rather than for any biological choice. The right preset is determined entirely by which sequencer produced the FASTQ"* (lines 38-40) is the one sentence that demystifies presets for a bench scientist, and the Troubleshooting "Very low mapping rate" section (lines 224-232) reads like it was written by someone who has actually consoled a panicking trainee.

### Persona B: David Reyes, research associate, reading a pileup

David runs a sequencing core and reads alignments daily in IGV. He came to chapter 02 to learn the Lungfish viewport equivalents. He knows what a pileup is, so he is testing the keystrokes and the claims, not the concepts.

**The zoom keys do not work and he notices in five seconds.** Line 89: *"Use `=` to zoom in and `-` to zoom out."* David navigates to position 21618, presses `=` repeatedly, and nothing happens. Ground truth (chapter 02 item 1): the zoom handler requires the Command modifier, so zoom is `Cmd-=` / `Cmd-+` / `Cmd--` plus keypad +/-, and a bare `=` falls through to `super.keyDown`. He eventually finds Cmd-= by reflex from other Mac apps, but the manual actively sent him down the wrong path.

> "I literally sat there mashing the equals key at a pileup that wasn't zooming. The fix is one modifier key. Just print `Cmd-=`. And the manual never told me Arrow Up and Arrow Down also zoom, which is the shortcut I'd actually reach for."

**The soft-clip vs hard-clip claim contradicts the next chapter and the code.** Lines 49-51: *"After primer trimming (the next chapter), the primer-derived ends become hard-clipped and disappear from the view entirely."* David flips to chapter 03 and reads the opposite (lines 39-41): trim *"changes their CIGAR flag from `M` ... to `S` (soft-clipped, present but excluded from pileups). The reads keep their original length. The primer footprints stay visible in the viewport."* Ground truth (chapter 02 item 3, and section-wide item 3) confirms chapter 03 matches the code and chapter 02 is wrong. For a core-lab reader this is a credibility-ending contradiction: the same manual tells him primer-trimmed bases both vanish and remain.

**The track name is invented again.** Step 1 (lines 74-76) tells him to click `SRR36291587-minimap2.bam`; chapter 01 told him the track was `SRR36291587 (minimap2 sr)`. Two chapters, two different names for the same artifact, and ground truth (section-wide item 2) says neither is code-generated. David, who keeps strict file naming, distrusts the whole walkthrough after this.

**He wants the colour channels the viewport actually has.** The chapter presents strand colour as the only channel (lines 38-43, 167-177). Ground truth (chapter 02 missing-features item 2) lists colour-by-pair, by insert size, by split-read, and by read-group, plus forward/reverse stacked coverage. David colour-codes by insert size to spot structural problems and is surprised the manual does not mention it exists.

**Accessibility.** Strand colour is described purely as colour: *"Forward-strand reads ... render in one shade, and reverse-strand reads render in another"* (lines 38-40) and *"A pileup column that is all-one-colour is a strand-bias warning"* (lines 171-172). There is no non-colour cue named, which is a problem for a colour-blind reader since strand is sold as *"the most useful at-a-glance cue you have."* The chapter also leans on hover-only depth readout (line 82, *"Hover any bar to see the exact depth"*) with no keyboard path to the same number.

**What he liked.** The artefact-vs-real-variant heuristics (lines 41-43 strand bias; lines 133-136 one-strand / read-end / low-MAPQ artefacts) are exactly how an experienced reader actually triages a pileup, and the table of Inspector fields (lines 144-150) is a clean reference.

### Persona C: Aisha Bello, advanced user, primer-trimming a BAM

Aisha is a bioinformatics-leaning research scientist who runs amplicon SARS-CoV-2 pipelines and audits her own provenance. She reads chapter 03 closely and checks the numbers against her kit documentation.

**The amplicon count is wrong and she catches it because she knows the kit.** Line 99 (table) and step 3 (line 137) both state QIASeqDIRECT-SARS2 has **422 amplicons**. Ground truth (chapter 03 item 1): the shipped manifest says `"amplicon_count": 223` and `"primer_count": 563`. The dialog will show her 223 below the picker (per step 3's own instruction to read that number), directly contradicting the 422 the manual printed two lines earlier. She also notes the doc never gives the primer count and that "~250 bp" insert is unverified.

> "I'm told to confirm the amplicon count in the dialog, and the dialog says 223 while the sentence telling me to check it says 422. The manual is arguing with itself in a single step. And the picker calls the scheme 'QIAseq Direct SARS-CoV-2 with Booster A (Built-in)', not 'QIASeqDIRECT-SARS2', so I can't even find it by the name you gave me."

**The display name omits Booster A.** Lines 99 and 135 call it "QIASeqDIRECT-SARS2". Ground truth (chapter 03 item 2): the picker shows `display_name` = "QIAseq Direct SARS-CoV-2 with Booster A" with a " (Built-in)" suffix. The manifest `name` and the GUI `display_name` differ, and the chapter uses the one the user never sees in the picker.

**The second entry point points at the wrong feature.** Front matter line 12: *"Tools > FASTQ/FASTA Operations > Trimming & Filtering > Primer Trimming"* listed as an entry point for BAM primer trim. Ground truth (chapter 03 item 3): that menu opens the FASTQ-level k-mer/BBDuk trim, which is the very thing this chapter contrasts itself against in lines 47-55. The BAM-level iVar trim has only two real entry points: `Inspector > Analysis > Primer-trim BAM…` and the CLI. Aisha, trusting the front matter, clicks the Trimming & Filtering path, lands in a FASTQ trimming dialog with k-mer-size and Hamming-distance fields, and realises she is in the wrong tool entirely.

**She wants the override and the bundle path she knows must exist.** Ground truth (chapter 03 missing-features item 1) documents `--target-reference` to override the `@SQ SN` used to resolve the scheme. Aisha routinely maps to a contig whose name differs from the scheme accession, and this flag is exactly what she needs; the chapter never mentions it. She also wants confirmation of the output subdirectory (`alignments/primer-trimmed`) for her provenance audit.

**Accessibility.** This chapter is the cleanest of the five for non-colour readers (it describes soft-clips as "short, lighter ticks" and "half-tone bases", which is lightness, not hue), but it inherits the viewport's hover-and-colour dependence by reference.

**What she liked.** The "Why this matters" section (lines 61-87) is the best explanation of primer-derived phantom variants she has read in any tool's docs: *"every read overlapping that footprint reports the primer base, not the sample base ... The variant caller sees a column where 100% of reads carry the same alternate allele at perfect quality and emits a confident SNP call."* The iVar default values (min length 30, min quality 20, sliding window 4, primer offset 0) are confirmed correct by ground truth (chapter 03 item 5), and the soft-clip-not-delete framing (lines 38-45) matches the code exactly. These are the load-bearing correct passages and should survive untouched.

### Persona D: Tomás Lindgren, power-user, running Viral Recon and scripting markdup / bam filter

Tomás is a pipeline engineer who scripts the CLI, validates clinical runs, and only opens the GUI to sanity-check. He reads chapters 04 and 05 as a CLI reference and tries every command.

**`markdup --in/--out` does not exist and his script fails immediately.** Chapter 04 line 68: *`lungfish markdup --in path/to/alignment.bam --out path/to/alignment.markdup.bam`*. Ground truth (chapter 04 item 1): the real command takes a *positional* `<path>` and marks **in place** (`fm.replaceItemAt(bamURL, withItemAt: tempBamURL)`); there is no `--out`. The only output-redirecting flag is `--deduplicated-bundle`. Tomás runs the documented line, gets an unknown-option error on `--in`, and then realises the deeper hazard: line 71 promises *"The output is a new BAM track ... the original is preserved,"* but the real command **mutates his input BAM in place**. If he had wrapped this in a batch loop trusting the "original is preserved" claim, he would have overwritten every source BAM in his cohort.

> "This is the dangerous kind of doc error. It's not just that the flags are wrong and it errors out. It's that the prose promises my original is preserved while the actual command overwrites it in place. I script against docs. That sentence could have cost me a dataset."

**`bam filter` is the toolset he expected and it is entirely missing.** Chapter 04's whole QC framing (mapped-only, primary-only, MAPQ floor, exclude/remove duplicates, exact-match, percent-identity) maps almost 1:1 onto `lungfish bam filter` flags: `--mapped-only`, `--primary-only`, `--min-mapq`, `--exclude-marked-duplicates`, `--remove-duplicates`, `--exact-match`, `--min-percent-identity` (ground truth chapter 04 missing-features item 2). The chapter describes the QC concepts and then never tells him the command that performs them. For a "validate before variant calling" chapter aimed at an analyst, omitting `bam filter` is the single largest coverage gap in the section.

**The Viral Recon menu path does not exist.** Chapter 05 front matter line 11 and step 2 (line 71): *"Tools > Workflows > Viral Recon."* Chapter 01 line 253 also references "a viral recon wizard." Ground truth (chapter 05 item 1): there is no "Workflows" menu in `MainMenu.swift`. Viral Recon is a *tool* inside the **Mapping** category of the FASTQ/FASTA Operations dialog; the real path is `Tools > FASTQ/FASTA Operations > Mapping…`, then select the "Viral Recon" tool. There is a separate "Workflow Operations…" item, but that is the generic Nextflow/Snakemake runner, not this wizard. Tomás opens the menu bar, finds no Workflows menu, and assumes the feature was cut.

> "I went to Tools looking for a Workflows menu and there isn't one. So my first conclusion was that Viral Recon got pulled from this build. It didn't. It's buried two levels into a dialog called 'FASTQ/FASTA Operations > Mapping', which is the last place I'd look for a consensus pipeline."

**The wizard is SARS-CoV-2-only, not general "viral".** Chapter 05 lines 27-31 and the tags frame it as a general viral pipeline. Ground truth (chapter 05 item 2): the header subtitle is literally "SARS-CoV-2 consensus and variant analysis from FASTQ bundles", the reference modes are "SARS-CoV-2 Genome" (default `MN908947.3`) and "Local FASTA", and the protocol is hardcoded to amplicon (`protocol: .amplicon`, ground truth item 4) with a primer scheme *required* to run. Tomás, who wanted to run a non-SARS amplicon virus, would have wasted a session discovering the GUI cannot do it.

**GUI vs CLI input models are conflated.** Lines 35-44 frame the GUI as analogous to the CLI samplesheet requirement. Ground truth (chapter 05 item 3): the GUI takes FASTQ bundles and *generates* the samplesheet; the "exactly one samplesheet" rule is CLI-only. He also notes the wizard refuses mixed-platform bundles outright (`mixedPlatforms` error, ground truth item 5), which the doc never warns about.

**The fixture's scheme attribution contradicts chapter 03.** Chapter 04 line 116 calls SRR36291587 a *"SARS-CoV-2 ARTIC v3 amplicon library"*; chapter 03 (lines 124-126) trims the same fixture with QIASeqDIRECT-SARS2. Ground truth (section-wide item 3b) flags this as an unresolved contradiction. A validation engineer cannot cite a methods record that disagrees with itself on which primer scheme produced the BAM.

**What he liked.** The CLI flag tables he *can* trust are good: ground truth confirms `lungfish primers import` (chapter 03 lines 115-117), the `workflow run` option table (chapter 05 lines 96-109), the `--timeout not supported` note (line 126), and `provenance bibliography` (line 132) all match the built CLI help. The Thresholds-by-workflow table (chapter 04 lines 77-86) is a genuinely useful decision aid, and the markdup-for-shotgun / skip-for-amplicon rule (line 39) with the 80-95% amplicon duplicate explanation (lines 106-108) is correct and well-argued.

## Part 2: Synthesis

## Critical fidelity fixes (the app does not work as written)

These are ordered by harm. Each is a place where a reader who follows the manual literally fails, is misled into a wrong action, or risks data loss.

### 1. `markdup --in/--out` is wrong AND the "original is preserved" promise is false (data-loss hazard)

Chapter 04, line 68 and front matter line 11. The doc shows `lungfish markdup --in <bam> --out <bam>` and claims (line 71) *"The output is a new BAM track adopted onto the same reference; the original is preserved."* Ground truth (chapter 04 item 1): the command takes a **positional** `<path>` (a BAM or a directory of BAMs) and marks **in place** via `fm.replaceItemAt(...)`. There is no `--out`. The only output-redirecting flag is `--deduplicated-bundle <path>`. The "original is preserved + new track" behaviour belongs to the *GUI* "Create Deduplicated Bundle", a different action.

Corrected text:

```
lungfish markdup path/to/alignment.bam
```

Replace line 71 with: "The command wraps `samtools markdup` (collate, fixmate, position-sort, mark, index) and marks duplicates **in place**, replacing the input BAM. It does not write a separate output file. To keep the original and produce a duplicate-removed copy as a new bundle, use `--deduplicated-bundle <path>` (CLI) or 'Create Deduplicated Bundle' in the Inspector's Analysis section." Add an explicit warning that `markdup` mutates its input so batch scripts must copy first if the original is needed.

### 2. Viral Recon menu path does not exist; there is no Workflows menu

Chapter 05 front matter line 11, step 2 (line 71), and chapter 01 line 253. Ground truth (chapter 05 item 1): no "Workflows" menu exists. Replace every "Tools > Workflows > Viral Recon" with the real path: **`Tools > FASTQ/FASTA Operations > Mapping…`, then select the "Viral Recon" tool** (it lives in the Mapping tool category). Note that the separate top-level "Workflow Operations…" item is the generic Nextflow/Snakemake runner, not this wizard, so readers are not misdirected there. Fix the front-matter `entry_points` line and chapter 01's cross-reference to match.

### 3. Viral Recon is SARS-CoV-2 amplicon-only, not a general viral pipeline

Chapter 05 lines 27-31, 55-64, and tags. Ground truth (chapter 05 items 2 and 4). Corrected framing: state up front that this wizard is **SARS-CoV-2-specific** ("SARS-CoV-2 consensus and variant analysis from FASTQ bundles"), that the reference is either the built-in SARS-CoV-2 genome (`MN908947.3`) or a Local FASTA, and that the protocol is **always amplicon** so a primer scheme is **required** to run (it is a readiness gate, not optional). Reword "For amplicon protocols, choose a primer scheme" (line 64) to "A SARS-CoV-2 primer scheme is required." Add the GUI behaviours the doc omits: it **generates** the samplesheet from FASTQ bundles (the "exactly one samplesheet" rule is CLI-only, ground truth item 3), it **refuses mixed-platform bundles** (item 5), and the default skip set is `[Assembly, Kraken2]` (item 6).

### 4. Zoom keys require Command; bare `=` / `-` do nothing

Chapter 02 line 89: *"Use `=` to zoom in and `-` to zoom out."* Ground truth (chapter 02 item 1): the handler requires `.command`. Corrected text: "Press `Cmd-=` (or `Cmd-+`, or keypad `+`) to zoom in and `Cmd--` (or keypad `-`) to zoom out. Arrow Up and Arrow Down also zoom." The menu items are "Zoom In" / "Zoom Out" as Cmd-accelerators, so naming the modifier also reconciles the menu with the keystroke.

### 5. Soft-clip vs hard-clip contradiction between chapters 02 and 03

Chapter 02 lines 49-51 says primer trim makes ends *"hard-clipped and disappear from the view entirely."* Chapter 03 (lines 39-41, correct) says it soft-clips (`M`→`S`), keeps original read length, and the footprints *"stay visible in the viewport as short, lighter ticks."* Ground truth (chapter 02 item 3, section-wide item 3a): chapter 03 matches the code; chapter 02 is wrong. Fix: rewrite chapter 02 lines 49-51 to "After primer trimming (the next chapter), the primer-derived ends become **soft-clipped**: they stay in the record and remain faintly visible, but pileup and coverage exclude them." Pick soft-clip as the single truth across the section.

### 6. QIASeqDIRECT-SARS2 amplicon count is 223, not 422; name omits Booster A

Chapter 03 line 99 (table) and step 3 (line 137) say **422 amplicons**. Ground truth (chapter 03 item 1): manifest is `amplicon_count: 223`, `primer_count: 563`. Correct the table to **223 amplicons / 563 primers**. This is self-contradicting today because step 3 tells the reader to verify the count in the dialog, where it reads 223. Also (item 2): the picker shows `display_name` "QIAseq Direct SARS-CoV-2 with Booster A (Built-in)", not the manifest `name` "QIASeqDIRECT-SARS2". Update lines 99 and 135 to the display name the user actually sees, or footnote that the picker label includes "with Booster A (Built-in)".

### 7. Mapping wizard has no Reads picker and no Tool picker

Chapter 01 line 131 and procedure steps 2-4. Ground truth (chapter 01 item 2): the wizard sections are Reference, Preset/Mode, Read Group, Input Compatibility, Advanced Settings. Reads come from the sidebar selection; the mapper is chosen by the tool row clicked in the FASTQ Operations dialog, not inside the wizard. Rewrite the procedure: select the FASTQ bundle in the sidebar first, open `Tools > FASTQ/FASTA Operations > Mapping`, choose the **Viral Recon-sibling mapper tool row** (minimap2 / BWA-MEM2 / Bowtie2 / BBMap) in the dialog, then in the wizard set the **Reference** and the **Preset** (and optionally Read Group / Advanced). Remove the "three sections (Reads, Reference, Tool)" claim.

### 8. GUI preset labels are wrong

Chapter 01 table lines 84-87 prints "Short read (sr)", "Map ONT (map-ont)", "Map HiFi (map-hifi)". Ground truth (chapter 01 item 1): the menu labels from `MappingMode.displayName` are **"Short-read", "Oxford Nanopore", "PacBio HiFi"** (plus "Assembly-to-assembly", "Spliced CDS/cDNA", "PacBio CLR"). The `sr` / `map-ont` / `map-hifi` strings are the CLI `--preset` tokens. Split the table into a GUI-label column and a CLI-token column so the two are not conflated.

### 9. Invented track names across chapters 01, 02, 03 (reconcile to one code-true pattern)

`SRR36291587 (minimap2 sr)` (ch01 line 174), `SRR36291587-minimap2.bam` (ch02 line 76), `SRR36291587 vs MN908947.3.bam` / `... (Primer-trimmed).bam` (ch03 lines 128, 147). Ground truth (section-wide item 2): none are code-generated; managed runs default to "<tool> Mapping" (e.g. "minimap2 Mapping") and CLI `--name` is user-supplied. Pick one convention, state it is the default and user-renamable, and use it identically in all three chapters.

### 10. Fixture scheme attribution contradiction (ARTIC v3 vs QIASeqDIRECT)

Chapter 04 line 116 calls SRR36291587 "SARS-CoV-2 ARTIC v3"; chapter 03 trims it with QIASeqDIRECT-SARS2. Ground truth (section-wide item 3b) flags this as unresolved and NEEDS-HUMAN-CHECK on the fixture's real scheme. Resolve to one attribution and use it in both chapters. Flag for the human reviewer to confirm which scheme the SRR36291587 fixture actually uses before either chapter ships.

## Coverage gaps (real app features missing from the docs)

These features exist in the shipped app and CLI but are undocumented. Listed by reader value.

- **`lungfish bam filter` (the entire QC-subsetting toolset).** Ground truth (chapter 04 missing-features item 2). Flags map 1:1 onto chapter 04's QC narrative: `--mapped-only`, `--primary-only`, `--min-mapq`, `--exclude-marked-duplicates`, `--remove-duplicates`, `--exact-match`, `--min-percent-identity`. Chapter 04 describes every one of these QC concepts and names none of the commands. Add a "Filtering a BAM before variant calling" section to chapter 04 built on `bam filter`.

- **The real mapper roster is only half-described in practice.** Chapter 01 names minimap2 / BWA-MEM2 / Bowtie2 / BBMap (correct), but the preset table covers only minimap2 presets (sr / map-ont / map-hifi) and tells Sanger/contig users to "use a different tool". Ground truth (chapter 01 missing-features item 4): minimap2 also ships `map-pb` (PacBio CLR), `asm5` (assembly-to-assembly), and `splice` (spliced cDNA). Document asm5 and splice rather than punting contig/assembly mapping.

- **Mapping filters and passthrough.** `--secondary`, `--no-supplementary`, `--min-mapq` (CLI) and the matching wizard toggles, plus `--extra-args` / the "Extra arguments" field. Ground truth (chapter 01 missing-features items 1-2). None are documented.

- **Input-compatibility pre-run gate.** The wizard auto-selects a preset, shows detected format / read class / max read length, and can **block** Run on an incompatible combination. Ground truth (chapter 01 missing-features item 3). The chapter mentions preset mismatch only as a post-hoc low-mapping-rate cause, not as the live gate it actually is.

- **`markdup --deduplicated-bundle` / "Create Deduplicated Bundle".** The duplicate-*removal*-into-a-new-bundle path. Ground truth (chapter 04 missing-features item 1). Chapter 04 covers only in-place marking. (Also resolves the false "original preserved" claim in fix #1.)

- **The Inspector Analysis section has 7 actions, not 2.** Ground truth (chapter 02 missing-features item 1): Primer-trim BAM, Call Variants, Mark Duplicates in Bundle Tracks, Create Deduplicated Bundle, Create Filtered Alignment, Convert Mapped Reads to Annotations, Extract Consensus. Chapter 02 names only the first two. At minimum name the others so readers know the section is the launch point.

- **Read colour modes beyond strand.** Colour-by-pair, by insert size, by split-read, by read-group, and strand-split forward/reverse coverage. Ground truth (chapter 02 missing-features items 2-3). Chapter 02 presents strand as the only channel.

- **`bam primer-trim --target-reference`.** Override the `@SQ SN` used to resolve the scheme when the BAM contig name differs from the scheme accession. Ground truth (chapter 03 missing-features item 1).

- **Viral Recon GUI specifics.** GFF picker in Local-FASTA mode, genome-accession / primer-scheme compatibility validation, primer-FASTA derivation requiring a local reference when a scheme lacks bundled FASTA, CPU/memory steppers bounded by host cores, and the executor/version/min-mapped-reads defaults (docker, 3.0.0, 1000). Ground truth (chapter 05 missing-features items 1-4 and items 7-9).

## Accessibility fixes

- **Strand colour needs a non-colour cue or honest caveat.** Chapter 02 sells strand colour as *"the most useful at-a-glance cue you have"* (line 40) and a *"all-one-colour is a strand-bias warning"* (line 171), described purely as hue. A colour-blind reader (red-green is the commonest case, and forward/reverse palettes often pair red/blue or green/magenta) cannot use the primary diagnostic. Either name a secondary encoding the viewport offers, or add a caveat plus a pointer to a colour-mode setting. This also aligns with the STYLE rule against red-amber-green severity encoding.

- **Hover-only depth has no keyboard equivalent.** Chapter 02 line 82 (*"Hover any bar to see the exact depth"*) and chapter 04's histogram scan both depend on mouse hover. Document a keyboard path to per-position depth (e.g. Go to Location at Cmd-L plus the Inspector readout) so non-pointer users can read coverage.

- **Spell out modifier keys, never bare punctuation.** The `=` / `-` zoom bug (fix #4) is also an accessibility issue: bare-punctuation instructions are ambiguous for screen-reader and assistive-input users. Always write the full chord (`Cmd-=`) and name the menu equivalent.

- **Ship the planned screenshots with alt text.** All five chapters have `shots: []` with planned captions. Novice readers (Persona A) depend on them most, and the prose-only dialog descriptions are exactly where the fidelity breaks hide. When captured, each needs descriptive alt text, not just the caption.

## What to keep

These passages are correct, well-pitched, and praised across personas. Preserve them through revision.

- **Chapter 03 "Why this matters" (lines 61-87)** on primer-derived phantom variants. Aisha called it the best explanation of the problem in any tool's docs. The soft-clip-not-delete framing (lines 38-45) matches the code exactly and should be the canonical soft-clip explanation the whole section defers to.

- **Chapter 03 iVar defaults (step 4, lines 138-141)** and the `lungfish primers import` CLI (lines 115-117): both confirmed correct by ground truth (chapter 03 items 4-5). Do not touch the command or the default values.

- **Chapter 01 preset-is-about-data-type framing (lines 38-40)** and the Troubleshooting section (lines 224-247). The conceptual model and the failure-mode triage are the strongest novice-facing writing in the section.

- **Chapter 02 artefact-vs-real-variant heuristics** (strand bias lines 41-43; one-strand / read-end / low-MAPQ tells lines 133-136) and the Inspector field table (lines 144-150). Exactly how an experienced reader triages, per Persona B.

- **Chapter 04 Thresholds-by-workflow table (lines 77-86)** and the markdup-for-shotgun / skip-for-amplicon rule with the 80-95% amplicon-duplicate explanation (lines 39, 106-108). The duplicate-handling logic is correct and clearly argued.

- **Chapter 05 CLI surface that ground truth confirmed:** the `workflow run` option table (lines 96-109), the `--timeout not supported` note (line 126), the `viralrecon` shorthand (line 53), and `provenance bibliography` (line 132). The CLI reference is trustworthy where the GUI menu paths are not.

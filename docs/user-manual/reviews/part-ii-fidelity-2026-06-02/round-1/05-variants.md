# 05-variants: simulated-reader focus group and revision plan (Round 1 of 3)

Note: this is a fidelity review. Reader reactions below are simulated against the
six Variants chapters and arbitrated against the ground-truth reality map
(`../ground-truth/05-variants.md`), which is treated as fact. Where a reader's
frustration tracks a real code mismatch, the ground-truth citation is given. No
chapter files were edited.

**Date:** 2026-06-02
**Section:** Part II, 05-variants (six chapters)
**Method:** Four biologist personas, novice to power-user, each reading the
chapters that match their task, reacting to the prose and to fidelity breaks.
Synthesis converts those reactions into a prioritized revision plan.

The headline: two of the six chapters describe features that do not exist.
Chapter 03 (Cross-Caller Comparison) documents a comparison surface,
intersection/union export, and codon-aware decomposition that are not in the
codebase. Chapter 05 (Consensus and Lineage) documents an iVar consensus-FASTA
side output, a `Consensuses` folder, and a `File > Export > Consensus FASTA`
menu that do not exist. Both must be rewritten around the real workflow or
honestly rescoped. The other four chapters are mostly sound but carry a recurring
caller-roster error (three callers documented, five-plus-two real), wrong browser
column names, an invented `OR` / `Source=` filter grammar, and a CLI `import vcf`
that is described with flags it does not have.

---

## PART 1: Personas

### Persona A: Nadia, novice (calling variants from amplicons)

Nadia runs a SARS-CoV-2 surveillance bench. She has never called variants from
the command line and is doing it for the first time through Lungfish. She reads
chapter 01 start to finish and follows it click by click.

**What worked.** The chapter is the strongest in the section for her. The
opening promise ("a list of every position where those reads disagree with the
reference") oriented her immediately. The vocabulary section defining allele
frequency, depth, and soft-clip up front meant she never had to leave the page.
The phased procedure (gather inputs, clean alignment, call variants) gave her a
mental map. Above all, the codon-merge lesson at step 8 landed: "A VCF row's
correspondence to a biological variant is not one-to-one without annotation
context." She said that single sentence taught her more than a week of reading
VCF specs. The closing shell script let her see "every flag visible," which she
appreciated even though she used the GUI.

**Where it broke.** At step 6 she read "Three variant callers ship with
Lungfish" and the three-row table, then opened the dialog. The real dialog left
sidebar lists seven entries (LoFreq, iVar, Medaka, bcftools, Clair3, GATK
HaplotypeCaller, GATK + WhatsHap Phased), and the default selection is LoFreq,
not iVar (ground truth ch.01: `BAMVariantCallingDialogState.swift:72-73`,
`selectedToolID = .lofreq`). She quote: "The book said three and told me to
'choose iVar' as if it were already selected. There are seven, and the one
highlighted is LoFreq. For thirty seconds I thought I had the wrong dialog." For
a true novice this is the worst kind of mismatch: it makes her distrust the rest
of the chapter at the exact moment she needs to trust it.

The second break is subtler and she only half-caught it. Step 8 says iVar reports
the codon pair "with `REF GG`, `ALT AA`, and the protein consequence in the
`INFO` field." She looked for the protein consequence in the row's INFO and
could not find it. Ground truth (ch.01) is explicit: the converter writes only
`INFO=TYPE=SNP`; there is no `GFF_FEATURE`/`AA_REF`/`AA_ALT` anywhere in the
emitted VCF, and the amino-acid label she sees comes from the Inspector
re-deriving it against the bundle GFF, not from the VCF row. She wrote: "The
`R203K` showed up in the Inspector, so I assumed that's what 'in the INFO field'
meant. A picky reviewer would call me out." She is right to worry.

She also expanded "iVar Options" expecting to find "minimum allele frequency
`0.05`" there, per the chapter, and found it instead in a shared **Thresholds**
section that applies to every caller (ground truth ch.01:
`BAMVariantCallingToolPanes.swift:43-66`). Minor, but it cost her a confused
minute.

**Accessibility.** Nadia uses the manual at 150% zoom and relies on the table of
disagreements being legible. The three-row caller table is fine. But she noted
that every numbered position claim ("expect roughly 80-90 PASS rows," "Position
`21618 C>T`") reads as fact, and she has no way to know these are biological
expectations rather than guaranteed outputs (ground truth ch.01 marks them
not-code-checkable). A novice cannot tell an illustrative number from a contract.

### Persona B: Marcus, research associate (reading the variant browser)

Marcus is a research associate who lives in the variant table. He does not call
variants himself; a postdoc hands him VCF tracks and he triages them. He reads
chapter 02 as his daily reference.

**What worked.** This is, for him, the best-conceived chapter in the section.
The "practical reading guide" (combine `Filter`, then AF, then depth, "because
each column rejects a different failure mode") is exactly how he already works,
written down for the first time. The interpretation section's contrast between a
well-behaved session and a pathological one ("Zero PASS rows almost always means
the reference is wrong") is the kind of diagnostic he wished he'd had as a
junior. The per-sample smart-filter examples (`Sample[NA12878].GT=1/1`,
`count(Sample[*].GT=1/1) >= 5`, `Sample[X].GT != Sample[Y].GT`) are real and
work exactly as written (ground truth ch.02: `VariantSmartFilter.swift:43-54`,
72-86). He called those "the reason I'd keep this page open."

**Where it broke.** The column table is wrong in ways he hit within the first
minute. The chapter's headers are `Pos` and `Qual`; the real columns are
**`Position`** and **`Quality`**, and there is an `ID` column the chapter omits
(ground truth ch.02: `AnnotationTableDrawerView+Columns.swift:313-332`). "I
right-clicked the header looking for a column called `Qual` to show it. It's
`Quality`. Small, but the whole table-columns section is presented as
authoritative and the first two names are off." Worse, the table lists
`INFO.AF`, `INFO.DP`, `INFO.SB`, `FORMAT.GT`, `FORMAT.AD` as if they were fixed
columns with dotted names. They are not: INFO keys are promoted dynamically, the
title is `AF` (not `INFO.AF`), there is no built-in `SB` or `AD` column, and
genotype lives in a `GT` sub-tab, not a `FORMAT.GT` column (ground truth ch.02:
`AnnotationTableDrawerView+Columns.swift:51-62,526-527`). "The dotted names look
precise, which is exactly why I trusted them. They're invented."

He then tried the filter examples and two of them silently did nothing.
`Source=iVar` (line 106) is not a recognized variant-table filter key, and the
chapter's claim that you "combine clauses with spaces (AND) or with the literal
token `OR`" (line 116) is false: the engine is AND-only, with no `OR` token
between clauses (ground truth ch.02: `VariantDatabase+Query.swift:159-177`).
"I typed `Filter=PASS OR AF>=0.5` and got nonsense. There is no OR. I'd have
filed a bug if the book hadn't told me the feature existed." This is the most
damaging kind of doc error for a power-filter user: it sends him chasing a
capability the app never had.

The preset chips are also fictional. The chapter promises `PASS only`,
`AF >= 0.5`, `DP >= 50`, `Coding`, `High confidence` (line 93). The real curated
tokens are a different and longer set (`PASS`, `SNV`, `Indel`, `High Impact`,
`Qual >= 30`, `DP >= 10`, the viral-minority chips `Minor <=20%` /
`Mixed 20-80%` / `Dominant >=80%`, etc.) plus value chips generated from the
VCF's actual INFO values (ground truth ch.02: `SmartFilterTokens.swift:15-66`).
"None of the four chips after `PASS only` exist. But the ones that DO exist
(`Minor`, `Mixed`, `Dominant`) are exactly what I need for minority-variant
reading, and the book never mentions them."

Finally he looked for `File > Export Filtered VCF` (line 38) to hand a subset to
a colleague and could not find it. Ground truth (ch.02) found no such menu; the
only filtered-VCF export is the CLI `lungfish variants query ... --filter
--output`. "The book's main verb for this page is 'export,' and the export menu
it names isn't there."

**Accessibility.** Marcus is red-green colorblind. The chapter's multi-track
section says the genome track is "colour-coded by source" (ch.03 echoes this).
He cannot rely on color to tell iVar ticks from LoFreq ticks. He needs the
`Source` column (text) to be the primary discriminator, and he wants the chapter
to say so explicitly rather than leaning on color. He also flagged that the
chapter never states a keyboard path for sorting or for row navigation; he uses
VoiceOver intermittently and "click the header" is not enough.

### Persona C: Aaron, advanced user (attempting cross-caller comparison)

Aaron is a computational postdoc who wants a defensible methods paragraph. He
came to chapter 03 specifically to run iVar against LoFreq, take the
intersection for phylogenetics and the union for surveillance, and cite the
machinery. He read the whole chapter, then tried to execute it.

**What worked conceptually.** The framing is genuinely good writing. "Running
more than one caller on the same sample and reading their disagreements is a
calibration exercise, not a 'which one is right' question" is the right mental
model. The three categories of disagreement (iVar-only, LoFreq-only,
filter-disagreement) are a useful taxonomy. The caller-philosophy table (iVar =
AF threshold, LoFreq = per-base error model) is the clearest statement of the
distinction he has read. If the features existed, this would be an excellent
chapter.

**Where it broke, catastrophically.** Almost every concrete instruction failed.

He started at step 2 and expanded "LoFreq Options" to confirm "minimum coverage
10, minimum base quality 6, significance threshold 0.01, multiple-testing
correction Benjamini-Hochberg, strand-bias filter on" (line 77). None of those
controls exist. The real LoFreq pane is a single sentence: "LoFreq is ready to
run directly on the selected bundle alignment track" (ground truth ch.03:
`BAMVariantCallingToolPanes.swift:82-84`). Lungfish supplies no `--min-cov`,
`--min-bq`, `--sig`, or `-B`; the only knobs are the shared thresholds and a
free-text extra-args box. Aaron: "There is no LoFreq Options dialog. The five
settings the book tells me to 'confirm' are fabricated. I spent five minutes
hunting for a Benjamini-Hochberg toggle that was never built."

Then he tried to navigate. Step 4 tells him to type `Pos:1193` into the filter
bar. The colon is not a valid operator; the ops are `>= <= != > < = ~` (ground
truth ch.03: `VariantDatabase+Query.swift:164`). "`Pos:1193` matched nothing. I
had to guess `Position=1193`, and even the column isn't called `Pos`." Every one
of the four worked positions uses the same broken `Pos:` syntax.

The core of the chapter is the intersection/union tooling, and it does not exist
at all. There is no cross-caller comparison view, no intersection or union
export, and no codon-aware decomposition feature (ground truth ch.03 and
section-wide: grep for `cross.caller|isec|intersection` returns only unrelated
set operations). The chapter's claim that "Lungfish's intersection export does
the decomposition automatically; manual `bcftools isec` does not" (line 141) is
backwards: there is no Lungfish intersection export, so the only path IS manual
`bcftools isec`. Aaron: "This is the whole reason I opened the chapter. The
intersection size, the union size, the automatic atomization at codon-merge
positions: none of it is a feature. I cannot do what the chapter is named after."

He also re-hit the iVar INFO error from chapter 01: line 133 says the merged row
carries "INFO carrying the protein consequence `R203K`." It does not (ground
truth ch.03, ch.01).

One thing he could verify worked: the bcftools cross-check via
`--caller bcftools --extra-args "--ploidy 1"` is a real and valid CLI invocation
(ground truth ch.03: `--extra-args` inserted into `bcftools call`,
`ViralVariantCallingPipeline.swift:1143-1160`). But the chapter never warns him
that in the GUI bcftools is gated behind the `lungfish-tools` pack, not the
`variant-calling` pack the setup step installs (ground truth ch.03:
`BAMVariantCallingCatalog.swift:44-46`). "So even the one real path has an
undocumented install gotcha."

**Accessibility.** Aaron uses a 13-inch laptop and the variant table at small
sizes. He noted the chapter assumes he can visually align an iVar row and a
LoFreq row "on adjacent lines" after sorting by position. With codon-merge,
adjacent rows do not line up by coordinate (the iVar `GG->AA` row spans
28881-28882; the LoFreq rows are at 28881, 28882, 28883 separately), so the
"read them back to back" instruction breaks down precisely at the case the
chapter spends the most words on. The real substrate (all of a bundle's variant
tracks shown together automatically, distinguished by the `Source` column) is
the thing the chapter should teach, and it barely mentions it (ground truth
ch.03 sec.2).

### Persona D: Priya, surveillance power-user (consensus + lineage)

Priya runs a public-health wastewater and clinical-isolate program. She needs
consensus FASTAs out the door to Pangolin and Nextclade, and she reads chapter 05
to learn Lungfish's consensus path. She is the most experienced reader and the
one the chapter most badly misleads.

**What worked.** The conceptual frame is correct and useful. The definition of a
consensus ("the reference sequence with high-confidence variants applied in
place ... an `N` mask where the reads do not give a confident call") is exactly
right. The threshold-choice table (0.5 majority-rule for mixed populations, 0.75
default, 0.9 for deposits) is good biology and she would keep it. The "What
Lungfish does not do" section correctly states that Lungfish does not assign Pango
lineages and that you hand the consensus to Pangolin / Nextclade, which is true
in spirit (ground truth ch.05: Pangolin/Nextclade ship as conda tools and are
cited; there is no in-app lineage assignment).

**Where it broke, catastrophically.** The entire production procedure describes
an output that does not exist.

The core claim, "Lungfish writes a consensus FASTA as a side output of the iVar
Variant Calling step ... whenever the consensus allele-frequency threshold is set
in the dialog" (line 34), is false. The iVar variant pipeline writes only VCF +
tabix + SQLite; it never produces a `.consensus.fa`. The `ivarConsensusAF` field
(default 0.75) is a codon-merge AF rule consumed by `IVarCodonMerger` to decide
whether adjacent within-codon SNPs collapse into one row, NOT a "call this base
vs mask as N" threshold (ground truth ch.05: `IVarCodonMerger.swift:50,105-115`).
Priya: "I set the consensus AF threshold, ran iVar, and went looking for the
FASTA the book promised would be 'next to the VCF.' There is no FASTA. The field
I set doesn't even do what the chapter says it does."

She then followed the Interpretation section to "the **Consensuses** subfolder of
the reference bundle" (line 66). There is no `Consensuses` folder and no
`.consensus.fa` second output in the Operations Panel (ground truth ch.05: the
attachment service writes only VCF.GZ, tabix, SQLite). "The folder the book tells
me to open does not get created. I refreshed the sidebar three times."

The export paths fail next. `File > Export > Consensus FASTA` (lines 76, 87) does
not exist, and there is no consensus track to right-click "Save As FASTA" (ground
truth ch.05: the File menu has a generic `exportFASTA`, not a consensus-track
exporter). "The worked example walks me from V01 to a Pango lineage through three
menu items, and the consensus-producing one and the consensus-exporting one are
both fictional. The Pangolin half is fine; the Lungfish half is a dead end."

For a surveillance lead this is the most expensive failure in the section: the
chapter's promise is a one-click consensus inside her existing variant run, and
the reality is that consensus lives in three entirely different places she is
never told about. Ground truth (ch.05) names them: `lungfish msa consensus` and
the MSA "Create consensus FASTA" action (MSA-scoped); `samtools consensus` over an
alignment region via the Inspector consensus mode (alignment-scoped); and the
nf-core/viralrecon wizard, whose Consensus picker is the only true
"variant-call to consensus FASTA" path (`ViralReconConsensusCaller`). She also
runs wastewater, and the chapter never mentions `lungfish freyja demix` (ground
truth ch.05 sec.2), which is the closest thing to in-app lineage work for her
mixed samples. "The one feature built for my exact job is missing, and the one
the chapter sells me doesn't exist."

**Accessibility.** Priya delegates to technicians and prints SOPs. A printed SOP
built from this chapter would send a technician hunting for a non-existent menu
with no recovery path, because the troubleshooting does not cover "the consensus
FASTA never appeared" (there is no consensus FASTA). The chapter needs to point
at a real, reproducible CLI path (`lungfish msa consensus` or the viralrecon
wizard) that a technician can run identically every time.

### Persona D (continued): Priya on chapter 06 (importing existing VCFs)

Priya also imports published VCFs, so she read chapter 06.

**What worked.** The GUI Import Center flow is accurate and well explained: the
Variants tab, the "Inferred reference" field, and the alias-map matching of
`NC_045512.2` to a `MN908947.3` bundle are all real (ground truth ch.06:
`VCFAutoIngestor.swift:107-111`, `VCFReferenceInference`). The worked example
(matching a RefSeq-keyed wastewater VCF to her GenBank bundle) is exactly her use
case and works as written. The sanity-check advice ("look at the first few `POS`
values ... spike falls roughly 21,500-25,400") is genuinely good practice.

**Where it broke.** The CLI section conflates GUI capability with CLI capability.
The chapter says run `lungfish import vcf <path> --project <path>` and "Pass
`--reference <bundle-name>` to skip inference" (line 70). Neither flag exists:
the CLI `VCFSubcommand` has only a positional `inputFile` and `--output-dir`,
does not infer a reference, does not apply the alias map, does not attach a bundle
track, and does not bgzip/index a plain VCF. It validates the header, prints a
summary, and copies the file (ground truth ch.06: `ImportCommand.swift:376-474`).
Priya: "I scripted `lungfish import vcf calls.vcf --project ... --reference
MN908947.3` for a batch and it errored on the unknown flags. The reference
inference the chapter sells is GUI-only." Worse, the chapter then implies a
CLI-import-to-CLI-query chain, but `variants extract-sample` and `variants query`
require a bundle that already has a SQLite variant database, which CLI import does
not create (ground truth ch.06). "So the scripted path the chapter draws is
broken end to end: import via CLI, then query, doesn't work because import via CLI
doesn't build the database."

She also noted the accepted-formats table omits `.bcf` (the CLI guard is
`["vcf","bcf"]`) and claims plain-`.vcf` bgzip/index-on-import that the CLI does
not do (ground truth ch.06). The VCFv3-rejection claim is unverified, not
confirmed (ground truth ch.06 marks it UNCERTAIN).

---

## PART 2: Synthesis and revision plan

### Critical fidelity fixes (the app does not work as written)

These are blocking. Two chapters describe features that do not exist and must be
rewritten around the real workflow or honestly rescoped; the rest correct
recurring factual errors. Citations are to the ground-truth reality map.

#### F1. Chapter 03 (Cross-Caller Comparison): rewrite around the real substrate, delete the fabricated tooling

Cross-caller comparison as a guided feature does not exist. There is no
comparison view, no intersection/union export, and no codon-aware decomposition
(ground truth ch.03 sec.1; section-wide "Does cross-caller comparison work as
documented? NO."). The chapter must stop describing tooling Lungfish does not
have and instead teach the one real substrate: the bundle variant browser
aggregates all of a bundle's variant tracks simultaneously, distinguished by the
`Source` column, so comparison is done by eye in that shared table.

Specific deletions and corrections:

- Delete the entire "LoFreq Options" paragraph (line 77). Replace with the truth:
  the LoFreq pane is a single line ("LoFreq is ready to run directly on the
  selected bundle alignment track"); the only knobs are the shared
  **Minimum Allele Frequency** / **Minimum Depth** thresholds and a free-text
  **Extra arguments** box. To reach LoFreq's internal flags (`--min-cov`,
  `--min-bq`, significance), the user types them into Extra arguments; Lungfish
  supplies none of them itself. Real command: `lofreq call-parallel --pp-threads
  N -f <ref> -o <out> <bam>` plus any extra args (ground truth ch.03,
  section-wide).
- Delete every `Pos:NNNN` filter instruction. The colon is not an operator. Use
  `Position=1193` (and note the column is `Position`, not `Pos`) (ground truth
  ch.03, ch.02).
- Delete the intersection/union tooling claims, including "Lungfish's
  intersection export does the decomposition automatically" (line 141). There is
  no intersection export. If the user wants a set intersection, the honest
  instruction is the external `bcftools isec`, and the codon-merge caveat is real
  and worth keeping: decompose the iVar VCF first with `bcftools norm -a` because
  the merged `GG->AA` row will not match LoFreq's three single-base rows
  position-for-position.
- Replace the "intersection size / union size" interpretation numbers with prose
  that says comparison is visual in the shared table; the row-count contracts are
  not features Lungfish computes (ground truth ch.03 sec.1).
- Correct the merged-row claim: the iVar row does NOT carry the protein
  consequence in INFO; the only INFO key is `TYPE` (ground truth ch.03, ch.01).
- Add the GUI gotcha: bcftools is gated behind the `lungfish-tools` pack, not the
  `variant-calling` pack the setup installs (ground truth ch.03 sec.1).

Suggested corrected framing for the chapter's "What it is": "Lungfish does not
provide a cross-caller comparison tool. What it provides is a variant browser
that loads every variant track on a reference bundle into one table, tagged by a
`Source` column. This chapter teaches you to call two callers, read them
side-by-side in that shared table, and reason about their disagreements by eye.
For a programmatic set intersection or union, export each track and use external
`bcftools isec`; this chapter shows where the codon-merge representation will
trip that up."

If a true comparison feature is on the roadmap, the alternative is to retitle the
chapter "Reading two callers in one table" and scope it strictly to the
manual-by-eye workflow, with a one-line note that programmatic set operations are
external.

#### F2. Chapter 05 (Consensus and Lineage): rewrite around `lungfish msa consensus` / viralrecon; delete the iVar consensus output

The iVar Call Variants step does not write a consensus FASTA; `ivarConsensusAF`
is a codon-merge rule, not an N-mask threshold; there is no `Consensuses` folder,
no `.consensus.fa`, and no `File > Export > Consensus FASTA` (ground truth ch.05
sec.1; section-wide "Does consensus/lineage work as documented? NO."). The whole
production procedure (lines 41-68, 76-89) is fictional and must be replaced.

Re-point the chapter at the three real consensus surfaces (ground truth ch.05):

- **nf-core/viralrecon wizard** (`ViralReconWizardSheet.swift`, Consensus picker
  `ViralReconConsensusCaller`). This is the only true "variant-call to consensus
  FASTA" path and is the natural primary recommendation for the
  amplicon-to-consensus surveillance workflow this chapter targets. The
  consensus-caller choice and threshold live here, not in Call Variants.
- **`lungfish msa consensus`** and the MSA "Create consensus FASTA" action
  (`MSACommand.swift:678`, `MultipleSequenceAlignmentActionRegistry.swift:478-485`).
  MSA-scoped consensus from aligned rows with explicit thresholds and gap policy.
  This is the reproducible CLI path a technician can run identically each time.
- **`samtools consensus`** over an alignment region via the Inspector consensus
  mode (`AlignmentDataProvider.swift:273,305`; Inspector controls in
  `InspectorView.swift:741-814`: consensus mode, IUPAC ambiguity, gap masking,
  min depth, min mapQ, min baseQ). Alignment-scoped quick consensus for a region.

Keep the threshold-choice table's biology but re-attach it to the real control
(the viralrecon consensus caller's threshold, or the MSA consensus threshold),
not to the iVar dialog. Keep the entire "What Lungfish does not do" section: it
is accurate that Lungfish does not assign lineages and you export to Pangolin /
Nextclade (ground truth ch.05). Fix only the false premise that Lungfish reaches
a consensus FASTA via Call Variants; the correct statement is that Lungfish
reaches a consensus FASTA via viralrecon or MSA, then stops, and you hand that
file to Pangolin / Nextclade for lineage.

Add the wastewater path: `lungfish freyja demix` is the in-app lineage-demixing
tool for mixed populations and is this chapter's most relevant omission for
surveillance readers (ground truth ch.05 sec.2). State the Freyja relationship
explicitly: Freyja demixes lineage abundances from a mixed sample's variant
profile; it is the mixed-population analogue to single-consensus Pangolin
assignment.

Suggested corrected "What it is" lead: "A consensus FASTA is the reference with
your sample's high-confidence variants applied in place and an `N` mask where
coverage or signal is too low to call. Lungfish produces a consensus FASTA two
ways: end-to-end from reads with the nf-core/viralrecon wizard, or from an
existing alignment or multiple-sequence alignment with `lungfish msa consensus`
and the Inspector's consensus mode. The iVar Variant Calling step does not
produce a consensus; it produces a VCF. Once you have a consensus FASTA, hand it
to Pangolin or Nextclade for lineage, since Lungfish does not assign lineages
itself."

#### F3. Correct the caller roster everywhere (ch.01, ch.02, ch.03, ch.04)

The recurring "three callers" framing is wrong. `ViralVariantCaller` =
**lofreq, ivar, medaka, bcftools, clair3**; the GUI adds **gatk-haplotype-caller**
and **gatk-whatshap-phased**; the default dialog selection is **LoFreq** (ground
truth section-wide "Caller roster"). Corrections:

- Ch.01 line 69 and the 3-row table: replace "Three variant callers ship with
  Lungfish" with the real roster, and stop telling the reader iVar is
  pre-selected. State that the dialog opens on LoFreq and the user clicks iVar.
- Ch.01 line 163 / ch.03 line 75 / ch.04 line 103: the left sidebar has seven
  entries, not three. Correct the wording at each entry point.
- Keep the "which caller for which data" guidance (iVar = amplicon Illumina,
  LoFreq = shotgun, Medaka/Clair3 = ONT) as biological advice, but frame it as
  "of the available callers, choose..." not "three callers ship."

#### F4. Correct the variant-browser columns and filter grammar (ch.02, echoed in ch.03)

- Columns are `ID, Chrom, Position, Ref, Alt, Quality, Filter, Source` (+
  dynamically promoted INFO/sample columns and a `GT` genotype sub-tab). Rename
  `Pos` to `Position` and `Qual` to `Quality` throughout; add the `ID` column;
  delete the invented dotted column names `INFO.AF` / `INFO.DP` / `INFO.SB` /
  `FORMAT.GT` / `FORMAT.AD` and describe INFO promotion + the `GT` sub-tab
  instead (ground truth ch.02 sec.1).
- Filter grammar is `key OP value` with ops `>= <= != > < = ~`, joined **AND
  only**. Delete the `OR` token claim (line 116) and the `Source=iVar` example
  (line 106); `Source=` is not a recognized variant-table key (ground truth
  ch.02 sec.1).
- Preset chips: replace the fictional `AF >= 0.5` / `DP >= 50` / `Coding` /
  `High confidence` list with the real curated tokens, and add the viral-minority
  chips (`Minor <=20%`, `Mixed 20-80%`, `Dominant >=80%`) that are purpose-built
  for this audience (ground truth ch.02 sec.1, sec.2).
- The iVar/LoFreq INFO/FORMAT field list (line 63) is wrong: iVar's allele
  depth/frequency are FORMAT fields (`ALT_FREQ`, not an `AF` INFO key) and there
  is no `GFF_FEATURE`/`AA_REF`/`AA_ALT` in the iVar VCF (ground truth ch.02 sec.1,
  section-wide "iVar VCF field reality"). Rewrite to FORMAT fields, or drop the
  field-by-field enumeration and say "the browser promotes whatever INFO keys the
  loaded VCF defines."
- Remove or rewrite `File > Export Filtered VCF` (line 38): no such menu was
  found; the real filtered-VCF export is CLI `lungfish variants query --filter
  --output` (ground truth ch.02 sec.1). If the GUI has a filtered export under
  another menu, a human must confirm the exact path before this line ships.
- The "Cmd-click a second track to merge" interaction (Step 5) is unverified and
  probably not the mechanism; the browser appears to aggregate all of a bundle's
  variant tracks automatically (ground truth ch.02 sec.1, NEEDS-HUMAN-CHECK).
  Flag for human verification before describing the interaction.

#### F5. Correct chapter 04 (Nanopore): no model picker, real Medaka command, shared model field

- There is no "Basecaller model" dropdown / picker grouped by pore chemistry, and
  nothing is selected by default. The Medaka and Clair3 model controls are
  **free-text fields** (placeholder `r1041_e82_400bps_sup_v5.0.0`), the field
  initializes empty, and the Run button is disabled until the user types a model
  (ground truth ch.04 sec.1). Rewrite lines 109-112 to describe typing a model
  string, and keep the excellent "how to read the model from the FASTQ header"
  guidance, which is the real way to get the right string.
- The Medaka command is `medaka variant -i <fastq> -r <ref> -o <out> -m <model>
  -t N`, NOT `medaka_haploid_variant`, and Medaka takes a FASTQ reconstructed from
  the BAM, not the BAM (ground truth ch.04 sec.1, section-wide). Correct line 115.
- "Minimum mapping quality 20, Minimum depth 20, Region blank" (line 113) do not
  exist as Medaka controls; the shared Minimum Depth default is 10, not 20
  (ground truth ch.04 sec.1). Delete these.
- Both Medaka and Clair3 write to the same model field, and the CLI flag for both
  is `--medaka-model` (ground truth ch.04 sec.1). The chapter's Clair3 CLI example
  correctly uses `--medaka-model`, so keep that; just stop implying a separate
  Clair3-specific picker.
- Surface the real failure mode: Medaka throws `medakaRequiresModelMetadata` if no
  model is supplied (ground truth ch.04 sec.2).

#### F6. Correct chapter 06 (import vcf) CLI vs GUI

- CLI `import vcf` has only a positional input and `--output-dir`. Delete
  `--project` and `--reference` (line 70). State plainly that reference
  inference, alias matching, bundle attachment, and bgzip/index are **GUI-only**;
  the CLI validates, summarizes, and copies (ground truth ch.06 sec.1).
- Do not imply a CLI-import-to-CLI-query chain. `variants extract-sample` /
  `variants query` require a bundle that already has a SQLite variant database,
  which CLI import does not build; import via the GUI first (ground truth ch.06
  sec.1).
- Add `.bcf` to the accepted-formats table (CLI guard is `["vcf","bcf"]`), and do
  not claim CLI plain-`.vcf` bgzip/index-on-import (that is GUI-side) (ground
  truth ch.06 sec.1).
- Mark the VCFv3-rejection claim UNCERTAIN until a human confirms the GUI reader
  rejects v3; the CLI does not check the version (ground truth ch.06 sec.1).

### Coverage gaps (real app features missing from the docs)

These features exist in the app and are absent or under-served in the chapters.

- **Clair3 and bcftools as first-class viral callers.** Both are real
  (`ViralVariantCaller.bcftools`, `.clair3`) with real command lines (ground
  truth section-wide "Real caller command lines"). Clair3 gets a thin treatment
  in ch.04 and bcftools only appears in the fabricated ch.03; both deserve honest
  coverage of their inputs, gating packs, and CLI flags.
- **GATK callers (gatk-haplotype-caller, gatk-whatshap-phased).** Listed in the
  GUI dialog (ground truth section-wide). The viral chapters correctly defer GATK
  to Part 06, but should at least name the two GATK entries when they correct the
  roster so the reader is not surprised by them in the sidebar.
- **The real consensus surfaces.** `lungfish msa consensus`, the MSA "Create
  consensus FASTA" action, the Inspector `samtools consensus` region mode, and the
  viralrecon Consensus caller are entirely undocumented in this section (ground
  truth ch.05 sec.2). They are the replacement content for ch.05.
- **Freyja relationship.** `lungfish freyja demix` is the in-app
  mixed-population lineage-abundance tool and the closest thing to lineage
  assignment Lungfish ships (ground truth ch.05 sec.2). It belongs in ch.05's
  wastewater discussion and should be explicitly distinguished from
  single-consensus Pangolin assignment.
- **The `--extra-args` / `--advanced-options` passthrough.** This is the only way
  to reach LoFreq's and bcftools's internal knobs, and it is under-explained
  relative to its importance once the fabricated options dialogs are removed
  (ground truth ch.03 sec.2).
- **Shared Minimum Depth threshold (default 10).** Applies to iVar via `ivar
  variants -m` and to other callers; ch.01 never mentions it (ground truth ch.01
  sec.2).
- **The `GT` genotype sub-tab, variant bookmarking, and the all-haplotypes VCF.**
  Real browser/pipeline features the chapters omit (ground truth ch.02 sec.2,
  ch.01 sec.2).
- **`analyze validate <vcf>`** is a natural companion to import and is
  undocumented (ground truth ch.06 sec.2).

### Accessibility fixes

- **Do not lean on color for `Source` discrimination.** Ch.02 and ch.03 describe
  multi-track ticks as "colour-coded by source." Colorblind readers (Persona B,
  Marcus) cannot use that. State that the `Source` text column is the primary
  discriminator, and that the track-tick color is secondary. Per STYLE, data viz
  must not encode meaning by color alone; use Deep Ink weight and the text label.
- **Provide keyboard and assistive paths.** Ch.02 instructs "click the header" to
  sort and "click any row" to inspect, with no keyboard equivalent. VoiceOver and
  keyboard-only readers need a stated path for sorting columns and navigating
  rows. Add it or note where it is documented.
- **Mark illustrative numbers as illustrative.** Novice (Persona A) and advanced
  (Persona C) readers both treated biological expectations ("80-90 PASS rows,"
  specific positions and AFs) as guaranteed outputs. Add a one-line "these are
  expected ranges for this isolate, not guaranteed outputs" note wherever exact
  counts and positions appear (ground truth flags these not-code-checkable
  throughout).
- **Printed-SOP recovery paths.** Power-user (Persona D, Priya) prints SOPs for
  technicians. Every procedure that a technician follows blind must point at a
  real, reproducible path with a recovery step, not a non-existent menu. This is
  the strongest argument for re-pointing ch.05 at the CLI `lungfish msa consensus`
  path, which runs identically every time.
- **Respect the bullet cap and table-first rule.** Several corrected sections
  (the caller roster, the consensus surfaces) are five-plus-item enumerations;
  per STYLE, render them as tables or prose, not as over-long bullet lists.

### What to keep

These landed well across personas and should survive the rewrite.

- **Chapter 02 is the section's best work.** The "practical reading guide"
  (Filter, then AF, then depth, each rejecting a different failure mode) and the
  well-behaved-vs-pathological interpretation contrast are exactly how
  experienced readers triage, written down. Keep them intact; only fix the column
  names and filter grammar around them.
- **The per-sample smart-filter syntax** (`Sample[X].GT/AF/DP`, `count(...)`,
  field-vs-field) is real and works as documented (ground truth ch.02). Keep all
  of it.
- **Chapter 01's codon-merge lesson.** "A VCF row's correspondence to a
  biological variant is not one-to-one without annotation context" is the most
  valuable single idea in the section and taught every persona something. Keep the
  lesson; only fix the false "protein consequence in INFO" detail.
- **Chapter 01's phased procedure and final shell script.** The
  gather-inputs / clean-alignment / call-and-read structure and the
  every-flag-visible CLI script are excellent for novices. Keep them; correct the
  caller-roster line and the iVar-pre-selected assumption.
- **Chapter 03's caller-philosophy framing.** The "calibration, not which-one-is-
  right" mental model and the three-category disagreement taxonomy are good
  writing and good science. Keep the concepts; delete the fabricated tooling and
  re-anchor them on the real shared-table substrate.
- **Chapter 04's basecaller-matching discipline.** "Confirm the basecaller
  version before you call" and the FASTQ-header decoding (`model_version_id` to
  Medaka model string) are the real way to get a correct ONT call. Keep them;
  only replace the model-picker fiction with the free-text-field reality.
- **Chapter 05's consensus concept and "What Lungfish does not do" boundary.** The
  definition of a consensus, the threshold-choice biology, and the honest handoff
  to external Pangolin / Nextclade are all correct. Keep them; re-attach the
  threshold to the real control and replace the fictional iVar consensus output
  with the viralrecon / MSA paths.
- **Chapter 06's GUI Import Center flow and alias-map explanation.** The guided
  import, reference inference, alias matching, and the RefSeq-to-GenBank worked
  example are accurate and well written (ground truth ch.06). Keep them; fix only
  the CLI section's GUI/CLI conflation.

# 05-variants: Round 2 simulated-reader re-review

**Date:** 2026-06-02
**Section:** Part II, 05-variants (six chapters)
**Round:** 2 of 3
**Method:** Verify that Round 1 critical fidelity fixes landed in the revised
chapters; scrutinize the two substantial rewrites (ch03 cross-caller, ch05
consensus/lineage) for fidelity and readability; re-read as three biologist
personas; catch residual and newly introduced problems. Arbitrated against the
ground-truth reality map (`../ground-truth/05-variants.md`), treated as fact.
Rewrite-critical claims were additionally re-verified against live source
(`Sources/`), cited inline. No chapter files were edited.

**Headline.** The Round 1 fixes landed, and they landed well. Both rewrites are
now faithful to the code: ch03 opens by stating plainly that no cross-caller
comparison tool exists and teaches the real shared-table substrate; ch05 deletes
the fictional iVar consensus output and re-points at the three real consensus
surfaces (Viral Recon, `msa consensus`, Inspector consensus mode) plus Freyja.
The caller roster, browser columns, AND-only filter grammar, iVar FORMAT-not-INFO
correction, free-text model field, and `import vcf` CLI scoping are all corrected
across every chapter that carried the error. I verified the rewrites' new factual
claims against source and they check out (`msa consensus` defaults threshold 0.6 /
gap-policy omit; `ViralReconConsensusCaller` is exactly `{ivar, bcftools}`;
`freyja demix` flags `--variants/--depths/--sample/--execute/--dry-run`; bcftools
gated by `lungfish-tools`). Remaining items are small: one must-fix is a residual
ch05 frontmatter/glossary inaccuracy (`features_refs: [variants.call]` and a
consensus chapter still pointed at the variant-call feature), one is the
documented bullet-cap warning in ch06, and a handful are clarity polish. No new
fabrications were introduced.

---

## PART 1: Verification table

Each row is a critical fidelity fix called for in Round 1. Status is LANDED /
PARTIAL / MISSED with the current text quoted.

| # | Round 1 fix | Status | Note (current text quoted) |
|---|---|---|---|
| 1 | Caller roster = 5 viral + 2 GATK; dialog opens on **LoFreq**, not iVar pre-selected | **LANDED** | ch01: "offers five viral callers (LoFreq, iVar, Medaka, bcftools, and Clair3) plus two GATK germline options. ... The dialog opens with LoFreq selected, so for this chapter you will click iVar to select it yourself." ch01 step 6, ch03 step 2, ch04 step 3 all list the "seven entries ... with `LoFreq` selected by default." |
| 2 | Browser columns: `Position`/`Quality` (not `Pos`/`Qual`); add `ID`; kill dotted `INFO.AF`/`FORMAT.GT` | **LANDED** | ch02 column table now reads `ID, Chrom, Position, Ref, Alt, Quality, Filter, Source` and states "There is no fixed list and no dotted `INFO.AF` naming: a key named `AF` in the file becomes a column titled `AF`." `GT` sub-tab described, not a `FORMAT.GT` column. |
| 3 | Filter grammar AND-only; no `OR`, no `Pos:` colon, no `Source=` | **LANDED** | ch02: "Clauses are joined by AND only ... There is no `OR` operator between clauses, no colon syntax such as `Pos:1193`, and no `Source=` key." ch03 step 4 repeats: "The colon syntax some tools use (`Pos:1193`) is not a valid operator here, and the column is `Position`, not `Pos`." |
| 4 | iVar puts AF/depth in FORMAT (`ALT_FREQ`), not INFO; no amino-acid in VCF | **LANDED** | ch01 step 8: "The iVar VCF carries only `TYPE=SNP` in its `INFO` column, and puts depth and allele frequency in the per-sample `FORMAT` fields (`ALT_FREQ`, and `MERGED_AF`/`MERGED_DP` on a merged row), not in `INFO`. The `R203K` ... consequences you see come from the Inspector re-deriving them." Echoed correctly in ch02 line 59 and ch03 line 132. |
| 5 | ch03 REWRITE: real Source-column comparison + external `bcftools isec`; delete fabricated comparison view / intersection export / LoFreq Options dialog | **LANDED** | Opens: "Lungfish does not have a dedicated cross-caller comparison tool. There is no comparison view, no intersection or union export, and no codon-aware decomposition feature." LoFreq pane corrected: "its panel reads only \"LoFreq is ready to run directly on the selected bundle alignment track.\"" Intersection is now honestly external: "Lungfish does not compute these; the honest path is external `bcftools isec`" with the `bcftools norm -a` atomize caveat. No fabricated tooling remains. |
| 6 | ch05 REWRITE: real consensus paths (`msa consensus` / viralrecon / `samtools consensus`) + Pangolin/Nextclade handoff + `freyja demix`; delete iVar consensus FASTA, `Consensuses` folder, `File > Export > Consensus FASTA` | **LANDED** | "The iVar Variant Calling step ... writes a VCF, a tabix index, and a SQLite store; it does not write a consensus FASTA, and the dialog's consensus allele-frequency field controls how iVar merges adjacent codon SNPs into one VCF row, not where a base is masked as `N`." Three surfaces tabled (Viral Recon / `lungfish msa consensus` / Inspector consensus mode). Freyja section present. No `Consensuses` folder, no fictional export menu. |
| 7 | ch04: free-text model field, not a picker; `medaka variant` on reconstructed FASTQ; shared `--medaka-model` | **LANDED** | ch04 step 4: "The model field is a free-text box, not a dropdown. ... There is no curated list grouped by pore chemistry; you supply the exact model string yourself." "The Medaka command is `medaka variant -i <fastq> -r <reference> -o <out> -m <model> -t <threads>`; Medaka reads the reconstructed FASTQ through `-i`, not the BAM." Both callers share `--medaka-model`. |
| 8 | ch06: `import vcf` has no `--reference`/`--project`; CLI copies+summarizes, GUI-only inference/attach | **LANDED** | ch06: "Its only arguments are the positional input file and `--output-dir` (short `-o`). It has no `--project` and no `--reference` flag. ... It does not infer a reference, apply the alias map, build a bundle, bgzip a plain VCF, or attach a track." Also correctly breaks the CLI-import-to-CLI-query chain: "Because the CLI import does not build a bundle variant database, you cannot chain it straight into the bundle-scoped query commands." |

### Re-verification of the two rewrites against live source (no re-introduced fabrications)

I re-checked every load-bearing factual claim the rewrites newly assert, because
a rewrite is the highest-risk place for fresh invention.

**Chapter 03 (cross-caller):**
- "There is no comparison view, no intersection or union export, and no
  codon-aware decomposition feature." Consistent with ground truth (grep
  `cross.caller|isec|intersection` returns only unrelated set ops). TRUE.
- LoFreq pane single sentence, only knobs are shared thresholds + Extra
  arguments: matches `BAMVariantCallingToolPanes.swift:82-84`. TRUE.
- "bcftools is gated behind a different pack, `lungfish-tools`." Verified:
  `BAMVariantCallingCatalog.swift:45` gates `.bcftools` on
  `packID: "lungfish-tools"`, while lofreq/ivar/medaka/clair3 gate on
  `variant-calling` (lines 41, `PluginPack.swift:383-428`). TRUE. (Nuance flagged
  in Part 2: `lungfish-tools` is the **Required Setup** pack, see S2.)
- `lofreq call-parallel --pp-threads N -f <reference> -o <out> <bam>`: matches
  `ViralVariantCallingPipeline.swift:1030-1039`. TRUE.
- `bcftools norm -a -f ... -Oz -o ...` then `bcftools isec`: this is the correct
  external decomposition recipe; `norm -a` atomizes the merged `GG>AA` row into
  per-base records so `isec` lines up with LoFreq. Sound and external (not
  claimed as a Lungfish feature). TRUE.
- `--caller bcftools --extra-args "--ploidy 1"` ... "inserted into the `bcftools
  call` stage": matches `ViralVariantCallingPipeline.swift:1143-1160`. TRUE.

**Chapter 05 (consensus/lineage):**
- `ivarConsensusAF` "controls how iVar merges adjacent codon SNPs into one VCF
  row, not where a base is masked as `N`": matches ground truth
  (`IVarCodonMerger.swift:50,105-115`). TRUE.
- `lungfish msa consensus` exists with `--threshold` (default `0.6`),
  `--gap-policy omit`: verified `MSACommand.swift:678,697,701` (`threshold: Double
  = 0.6`, `gapPolicy: String = "omit"`). The chapter's note that the default is
  `0.6` "across aligned rows rather than read allele frequency" is exactly right.
  TRUE.
- Viral Recon `Consensus` picker is `iVar` or `bcftools`: verified
  `ViralReconConsensusCaller` enum = `{ivar, bcftools}`
  (`ViralReconRunRequest.swift:17-20`), surfaced as a `Picker("Consensus", ...)`
  in `ViralReconWizardSheet.swift:304`. TRUE. (Default is `.bcftools`; the
  chapter says "set `Consensus` to `iVar` or `bcftools`," which is accurate as an
  instruction.)
- Inspector consensus mode controls (`Consensus Mode`, `Use IUPAC ambiguity
  codes`, `Hide high-gap sites`, depth/MAPQ/baseQ sliders) drive `samtools
  consensus`: matches ground truth (`AlignmentDataProvider.swift:273,305`,
  `InspectorView.swift:741-814`). TRUE.
- `lungfish freyja demix --variants ... --depths ... --output-dir ... --sample
  ... --execute` and `--dry-run`: every flag verified in `FreyjaCommand.swift`
  (`--execute` L19, `--dry-run` L22, `--variants` L25, `--depths` L28,
  `--output-dir` L31, `--sample` L34). "Running Freyja requires the
  `wastewater-surveillance` tool pack": verified `PluginPack.swift:699` id
  `wastewater-surveillance`. TRUE.
- "Lungfish does not assign lineages itself" / hand consensus to Pangolin or
  Nextclade: matches ground truth (Pangolin/Nextclade ship as conda tools and are
  cited; no in-app lineage assignment). TRUE.

No fabricated features were re-introduced in either rewrite. The fictional
content Round 1 flagged (comparison view, intersection export, LoFreq Options
dialog, iVar consensus FASTA, `Consensuses` folder, `File > Export > Consensus
FASTA`) is gone.

---

## PART 2: Three persona re-reads

### Persona A: Nadia, novice (ch01, calling variants from amplicons)

Nadia returns to ch01. The two breaks that derailed her in Round 1 are fixed.

**The roster mismatch is gone.** She reads "The dialog opens with LoFreq
selected, so for this chapter you will click iVar to select it yourself," opens
the dialog, sees LoFreq highlighted and seven entries, and her mental model
matches the screen. Her Round 1 thirty-second panic does not recur. The step-6
prose names all seven entries explicitly ("`LoFreq`, `iVar`, `Medaka`,
`bcftools`, `Clair3`, `GATK HaplotypeCaller`, and `GATK + WhatsHap Phased`"), so
nothing in the sidebar surprises her.

**The INFO claim is fixed and, importantly, fixed gently.** Step 8 now teaches
the truth as a feature, not a correction: "The `R203K` and `G204R` consequences
you see come from the Inspector re-deriving them against the bundle's GFF3 when
you select the row, not from a field in the file. If you hand this VCF to an
external tool, it will not find an amino-acid annotation inside it." That last
sentence is genuinely useful to a novice who might later run Nextclade. Her Round
1 worry ("a picky reviewer would call me out") is resolved.

**Threshold structure fixed.** The shared `Thresholds` section vs the iVar-only
`iVar Options` section is now described accurately: "Two controls live in a
shared `Thresholds` section that applies to whichever caller is selected:
`Minimum Allele Frequency` (default `0.05`) and `Minimum Depth` (default `10`).
The iVar-specific `iVar Options` section holds the rest." Her confused minute is
gone, and `Minimum Depth` (the Round 1 coverage gap) is now surfaced, including
in the prose ("passing the minimum depth as `-m 10`").

**Accessibility improved.** Her Round 1 complaint that illustrative numbers read
as contracts is addressed directly: "That figure is an expected range for this
particular isolate, not a guaranteed output," and at the landmark positions
"These positions are biological landmarks for this sample, not values the app
guarantees." A novice can now tell an example from a promise.

**Residual nit (should-fix).** ch01 line 78 still says LoFreq is "for Illumina
shotgun viral or bacterial," then the same line later sends shotgun work to
ch03. ch03 then runs LoFreq on an *amplicon* alignment as its worked example.
Nadia would not notice, but Aaron does (below). Not a fidelity break, just a
small tension in how LoFreq's "assumed input" is framed across chapters.

### Persona B / analyst (ch02 + ch03, reading the browser and comparing callers)

The analyst reads ch02 as a daily reference and ch03 to compare callers.

**Chapter 02 is now both well-written and accurate.** Every Round 1 break is
fixed:
- Columns are `Position`/`Quality` with `ID` added; the dotted-name invention is
  explicitly disowned: "There is no fixed list and no dotted `INFO.AF` naming."
- The `OR`/`Source=`/`Pos:` fictions are deleted and replaced with a correct,
  actionable instruction: "To pull one track's rows out of an aggregated table,
  filter on a column that differs between the tracks rather than on `Source`."
- The preset chips are now the real curated set, and the three viral-minority
  chips Round 1 said were missing are present and explained: "`Minor (<=20%)`,
  `Mixed (20-80%)`, and `Dominant (>=80%)`. Those last three are the quickest way
  to triage within-host frequency in a viral sample."
- The `GT` sub-tab is described correctly.
- The colorblind concern is met head-on: "Use the text in the `Source` column,
  not the tick color on the genome track, to tell the callers apart. ... the only
  one that works in print, at small sizes, or for a colorblind reader." This is
  exactly the STYLE data-viz rule applied in prose.
- The export verb is corrected: the browser is "read-only," and a filtered subset
  goes out via "the CLI command `lungfish variants query` with a `--filter`
  expression and an `--output` path." The fictional `File > Export Filtered VCF`
  is gone.
- The multi-track aggregation is now described as automatic ("the browser shows
  all of them in the same table automatically. You do not load a second track by
  hand"), replacing the unverified Cmd-click mechanism.

**Chapter 03 now reads as honest calibration guidance.** The opening sentence
sets the right expectation immediately, and the analyst can actually execute the
whole chapter:
- The fabricated LoFreq Options dialog is replaced with the real single-line pane
  and the Extra-arguments escape hatch, with a concrete example: "to set one of
  LoFreq's internal knobs, type it into `Extra arguments` exactly as LoFreq
  expects it (for example, `--min-cov 50`)."
- The intersection/union is correctly external, and the codon-merge trap is the
  star of the chapter rather than a buried false claim: the `bcftools norm -a` /
  `bcftools isec` recipe is correct and runnable.
- The caller-philosophy table survived the rewrite intact and is still the
  clearest statement of the iVar-vs-LoFreq distinction in the section.

**Residual fidelity nuance in ch03 (should-fix, borderline).** ch03's "note on
caller availability" frames `lungfish-tools` as an extra optional install: "If
you plan to use bcftools as the orthogonal caller ... install that pack too:
`lungfish conda install --pack lungfish-tools`." I verified the command is valid
(`PluginPack.visibleForCLI` includes it via `requiredSetupPack`,
`CondaCommand.swift:53,163`). But `lungfish-tools` is in fact the **Required
Setup** pack ("Needed before you can create or open a project,"
`PluginPack.swift:292-305`, `requiredSetupPack` loaded from
`third-party-tools-lock.json` whose `packID` is `lungfish-tools`, bundling
bcftools, samtools, htslib, nextflow). So bcftools is realistically already
installed for any user who has opened a project, and the separate install step,
while harmless and idempotent, slightly overstates the friction. This is not a
fidelity break (the gate and the command are both real), but a one-clause
softening would be more accurate: "bcftools lives in the `lungfish-tools` pack
(the Required Setup pack you already installed to open a project); if it is
missing, `lungfish conda install --pack lungfish-tools` restores it."

**Residual clarity issue in ch03 (should-fix).** Step 4 still tells the analyst
that after sorting by `Position` "the iVar row and the LoFreq row for one
coordinate appear on adjacent lines." For the codon-merge case the chapter spends
the most words on, they do not line up by coordinate: the iVar `GG>AA` row sits
at 28881 spanning 28881-28882, while LoFreq's rows are at 28881, 28882, 28883.
Round 1 (Persona C) raised exactly this. The chapter now handles it correctly in
the dedicated 28881 subsection and in the `bcftools isec` caveat, so the
information is present, but the blanket "adjacent lines" sentence in step 4
slightly oversells the visual alignment. A half-sentence ("except where iVar's
codon merge spans two bases, covered below") would close the gap.

### Persona C: Priya, surveillance/clinical power-user (ch05 + ch06)

Priya reads ch05 for the consensus-to-lineage path and ch06 to import published
VCFs. In Round 1 ch05 was the section's most expensive failure. It is now
faithful and, for her job, genuinely useful.

**Chapter 05 now points her at real, reproducible paths.** The false premise is
gone and replaced with a precise disclaimer: "It is worth being precise about
where consensus comes from in Lungfish, because it is easy to assume the variant
caller produces it. It does not." The three surfaces are tabled with the exact
input each one starts from, and the one she needs for surveillance (Viral Recon,
reads to consensus FASTA) is correctly named the primary path. The
threshold-choice biology she liked in Round 1 survived and is now attached to the
real controls (the Viral Recon `Consensus` picker and the `msa consensus`
`--threshold`), with the honest note that the `msa consensus` default is `0.6`,
not `0.75`.

**The wastewater gap is closed, and it is closed well.** Her Round 1 lament ("the
one feature built for my exact job is missing") is answered: the Freyja section
gives her a runnable command and the right mental model: "Freyja demixes the
lineage abundances from the mixed sample's variant profile; it is the
mixed-population analogue of single-consensus Pangolin assignment." The
`--dry-run` vs `--execute` distinction is correct and is the safe default a
technician SOP wants.

**The printed-SOP recovery problem is solved.** `lungfish msa consensus` is
offered as "the reproducible path: the same command and the same inputs produce
the same file every time, which is what a printed SOP needs," and the
Interpretation section gives a real recovery signal ("Long stretches of `N` ...
usually mean an amplicon failed and the sample needs re-sequencing"). A technician
following this blind no longer hits a non-existent menu.

**The Pangolin/Nextclade boundary is preserved and accurate.** "What Lungfish
does not do" cleanly states the handoff to `pangolin.cog-uk.io` and
`clades.nextstrain.org` and explains why (moving nomenclature vs stable file
format). This matches the code reality (external conda tools, cited, no in-app
assignment).

**One residual fidelity item in ch05 (MUST-FIX, low-severity).** The chapter body
is now entirely re-pointed away from Call Variants, but two metadata/pointer
remnants still tie this consensus chapter to the variant-call feature it no
longer documents:
1. Frontmatter `features_refs: [variants.call]`. The chapter no longer documents
   `variants.call` as its subject; its real features are the Viral Recon
   consensus caller, `msa consensus`, the Inspector `samtools consensus` mode,
   and `freyja demix`. Per STYLE, `features_refs[]` must "resolve to an existing
   target," and while `variants.call` exists, it is the wrong target for this
   chapter and misrepresents coverage to the cartographer. The accurate refs are
   the viralrecon/msa/freyja feature ids (the cartographer should confirm the
   exact `features.yaml` ids; candidates per ground truth are the viralrecon
   consensus, `msa.consensus`, and `freyja.demix` entries).
2. Frontmatter `glossary_refs: [..., consensus-fasta, ...]` and `tools: [ivar,
   bcftools, samtools, freyja]` are fine, but the body still leans on the
   prereq `05-variants/01-calling-variants-from-amplicons` as the only prereq.
   Given the chapter's real inputs are an alignment or an MSA bundle, a reader
   arriving only from ch01 has a VCF, not the inputs ch05 actually consumes. This
   is a soft prereq mismatch, not a hard error; flag for the editor to consider
   adding the alignment/MSA chapters as prereqs or stating the input requirement
   in "Before you start."

This is bookkeeping, not a reader-facing fabrication. The prose a reader sees is
correct. But `features_refs: [variants.call]` on a chapter that explicitly says
the variant caller does *not* produce its output is the kind of inconsistency a
fidelity pass should catch.

**Chapter 06 is accurate for Priya's scripted batch.** Her Round 1 failure
(scripting `--project`/`--reference` and erroring on unknown flags) is fixed: the
chapter now states the CLI "has no `--project` and no `--reference` flag" and
that "Reference matching and attachment are GUI-only." The broken CLI-import-to-
CLI-query chain is explicitly called out and rerouted through the GUI first.
`.bcf` is added to the accepted-formats table ("Accepted by the reader; the CLI
also accepts `.bcf`"). The VCFv3 claim is correctly softened to uncertain:
"whether the GUI reader rejects them outright was not confirmed for this chapter."
`analyze validate` is now mentioned as the companion check. All Round 1 ch06
items landed.

**Accessibility (all three personas).** The color-alone problem is fixed in both
ch02 and ch03 with explicit "use the `Source` text, not the tick color" prose.
Illustrative numbers are now marked as illustrative in ch01, ch03, ch04, and ch05.
The one remaining accessibility gap Round 1 raised and that is still open: ch02
still describes sorting and row navigation only as "click the header" / "click
any row" with no stated keyboard or VoiceOver path (Round 1, Persona B). This is
a should-fix carried over, not a regression.

---

## Round 2 fixes for editors

Prioritized. Must-fix = fidelity (the doc states something the code does not do,
or a metadata/coverage claim that misrepresents the feature). Should-fix =
clarity, accessibility, or style.

### Must-fix (fidelity / metadata accuracy)

1. **ch05 frontmatter `features_refs: [variants.call]` is the wrong target for a
   chapter that explicitly says the variant caller does not produce consensus.**
   The body correctly re-points at Viral Recon / `msa consensus` / Inspector
   `samtools consensus` / `freyja demix`; the frontmatter still claims the
   variant-call feature. Update `features_refs` to the real consensus/lineage
   feature ids (cartographer to confirm the exact `features.yaml` ids; per ground
   truth the targets are the viralrecon consensus caller, the MSA consensus
   action, and `freyja demix`). Leaving `variants.call` here is the only residual
   fidelity inconsistency in the two rewritten chapters.

### Should-fix (clarity / accessibility / style)

2. **ch06 bullet-cap warning (documented, per the task brief).** The "Accepted
   formats" context plus the Procedure list: the numbered Procedure under
   `## Procedure` is a six-item list (steps 1-6, lines 57-65), which exceeds the
   STYLE cap of five items per list and trips `bullet-cap.js` (warning, so it can
   ship with a review note). Two clean options: (a) fold steps 5 and 6 into one
   ("Wait for the progress bar; when it finishes, close the Import Center and the
   new track appears in the sidebar"), bringing it to five; or (b) convert the
   import flow to a short prose walkthrough as ch05's Viral Recon procedure does.
   Recommend (a). This is a warning, not an error, so a one-line review note in
   the frontmatter or a reviewer sign-off also satisfies the linter if the editor
   prefers to keep six steps.

3. **ch03 `lungfish-tools` framing slightly overstates install friction
   (borderline fidelity).** The install command is valid, but `lungfish-tools` is
   the **Required Setup** pack every user installs to open a project
   (`PluginPack.swift:292-305`; it bundles bcftools/samtools/htslib/nextflow), not
   a niche optional add-on. Reframe the "note on caller availability" to say
   bcftools lives in the Required Setup pack the user already has, with the
   install command as a restore-if-missing fallback rather than an expected extra
   step. Keeps the command, removes the false impression of a separate gate.

4. **ch03 step 4 "adjacent lines" oversells visual alignment at the codon-merge
   case.** Add a half-clause: after "the iVar row and the LoFreq row for one
   coordinate appear on adjacent lines," append "except where iVar's codon merge
   spans two bases, which the 28881 walkthrough below covers." The dedicated
   subsection and the `isec` caveat already handle it correctly; this just keeps
   the general instruction from contradicting the special case.

5. **ch05 prereq/input mismatch (soft).** The only prereq is
   `05-variants/01-calling-variants-from-amplicons`, which leaves the reader with
   a VCF, but ch05's real inputs are reads (Viral Recon), an MSA bundle (`msa
   consensus`), or an alignment (Inspector mode). Add a one-line "Before you
   start" stating which input each path needs, or add the alignment/MSA chapters
   as prereqs. Prevents a reader from arriving with the wrong artifact.

6. **ch02 keyboard / VoiceOver path for sort and row navigation (carried from
   Round 1).** ch02 still says only "click the header" (step 2) and "click any
   row" (step 3). Add a stated keyboard equivalent for sorting columns and
   navigating rows, or a pointer to where it is documented, for keyboard-only and
   VoiceOver readers.

7. **ch01 LoFreq "assumed input" tension (minor).** ch01 line 78 routes shotgun
   work to ch03, but ch03's worked example runs LoFreq on an amplicon alignment.
   Consider a one-line note in ch01 or ch03 that LoFreq accepts amplicon BAMs as
   a cross-check (which the code allows; there is no caller-specific trim
   coupling for LoFreq) so the cross-reference does not read as a contradiction.

### What landed and should be preserved as-is

- ch03's opening disclaimer and the corrected `bcftools isec` / `bcftools norm
  -a` recipe. Faithful and runnable; do not soften the "no comparison tool"
  statement.
- ch05's three-surface table, the Freyja section, and the "What Lungfish does not
  do" boundary. All verified against source.
- ch02's "practical reading guide," the well-behaved-vs-pathological
  interpretation contrast, the per-sample smart-filter grammar, and the
  color-vs-text accessibility prose.
- ch01's codon-merge lesson and the every-flag-visible shell script.
- ch04's basecaller-matching discipline and the free-text-field correction.

---

## Bottom line

The Round 1 critical fixes all landed, and both substantial rewrites are now
faithful to the code with no re-introduced fabrications (verified against live
source for every load-bearing new claim). The section moved from "two chapters
describe features that do not exist" to "accurate throughout." The only residual
fidelity item is a metadata inconsistency in ch05 (`features_refs: [variants.call]`
on a chapter that disowns the variant caller as the consensus source). Everything
else is clarity, accessibility, or the documented ch06 bullet-cap warning.

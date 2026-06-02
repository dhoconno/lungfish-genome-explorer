# Round 3 final reader panel: accessibility and flow

**Date:** 2026-06-02
**Scope:** End-to-end accessibility and flow read across Part II+ (chapters 02-08 + appendices), after two rounds of fidelity revision. This panel owns flow and accessibility only. Fidelity (does the manual match the app) is owned by the sibling Round 3 agents.
**Method:** Three final readers each followed a reading path matched to their tier. The novice and intermediate readers read their tier's chapters as a learning path; the power user read the appendices and power-user chapters. The priority rewrites (05-variants/03, 05-variants/05, 06-classification/05, 06-classification/06, 06-classification/08, 08-workflows/01, 08-workflows/02) were read closely; the rest were sampled. 22 chapters were read in full; frontmatter, opening primer, scope sentence, and the closing-refrain pattern were checked mechanically across all 51 files.

**Headline:** Part II+ now reads well end to end for working biologists. The fidelity rewrites did not leave the rewritten chapters thin: the cross-caller, consensus-and-lineage, NAO-MGS, BLAST, and novel-virus chapters all replaced their fabricated features with a clear "here is what the app actually gives you and here is what to do with it," and they are satisfying to read. Glossing discipline is strong: load-bearing terms (Phred, basecaller, soft-clip, TASS, GenomicsDB, BQSR, phylogram, seed, dust, squiggle, adapter read-through) are defined inline at first use for the declared tier. The problems that remain are polish, not structure. One is a genuine comprehension blocker (a broken cross-section link). The rest are uniformity and tone: a closing-sentence tic that now appears in nearly every chapter, a handful of chapters missing the standardized scope one-liner, and two or three chapters that read thinner or more abruptly than their neighbors.

---

## Persona 1: NOVICE bench scientist (bench-scientist-tier learning path)

I followed the bench path: 02-sequences (01-03), 03-reads (01-04, 06, 07), 04-alignments (01-03), 05-variants (01, 02, 05, 06), 06-classification (01-04, 06, 07), 07-assembly (01, 02, 04). I came in able to click a dialog and read a small terminal command, and not much more.

**(a) Does the reading path hold end to end?** Yes. The spine holds: import a sequence, import reads, QC them, map them, read the alignment, call variants, read the variant browser, make a consensus. Each chapter told me what I needed before I needed it, and the "What you will learn" lists at the top let me confirm I was in the right place. The single best chapter for me was 05-variants/01 (Calling Variants from Amplicons): the "Vocabulary you will need" section up front (reference genome, FASTQ, amplicon, BAM, VCF, allele frequency, depth, soft-clip) meant I never hit a wall, and the "What does good look like" section told me how to know it worked. That is the model the rest of the bench path should aspire to, and mostly it lives up to it.

I never got lost on an unexplained term. 03-reads/03 glosses Phred ("the standard log scale for base-call confidence") and adapter read-through ("the insert was shorter than the read, so sequencing ran off the end of the fragment and into the adapter") right where I needed them. 04-alignments/02 glosses pileup and soft-clip the first time it uses them. 07-assembly/01 glosses contig in its first sentence. This is a real improvement and it is consistent.

**(b) Did the fidelity rewrites introduce jargon, density, or abruptness?** Not in the bench-tier chapters I read. They read like they were written for me, not down-edited from an analyst draft. 05-variants/05 (Consensus and Lineage) is a chapter that lost a feature (the manual is now explicit that the variant caller does not produce a consensus and Lungfish does not assign lineages), and it does not feel hollow: it gives me three concrete surfaces, a threshold table that explains 0.5 vs 0.75 vs 0.9 in plain biological terms, and a clear "hand this FASTA to Pangolin" close. I finished it knowing exactly what to do.

The one density bump on my path is 06-classification/07-importing-cz-id-results. Compared to its neighbors it reads like a reference card, not a learning chapter: it has no "What you will learn," it drops a CLI block (`lungfish import cz-id ...`) into step 3 of the Procedure before I have a feel for the GUI flow, and its scope statement is parked in a "## Scope" section at the very bottom instead of up top where every other chapter puts it. It is not wrong and it is short, so I was not lost for long, but the rhythm change was noticeable after the smooth chapters around it.

**(c) Are the rewritten chapters still satisfying?** Yes for everything on my path. 06-classification/06 (BLAST Verification) in particular is a model of a "second opinion" chapter: it leads with the four verdicts in plain words (Supported / Unsupported / Mixed / Inconclusive), tells me to read the verdict and verification rate first, and explains percent identity, coverage, and e-value with concrete numbers ("A 99.8% identity over a 250-base alignment means two of those 250 positions disagreed"). I never felt the absence of a fancier feature.

**(d) Scope, glosses, forward references.** Glosses: excellent. Scope: mixed. The 03-reads chapters all open with a crisp one-line scope-and-redirect ("This chapter covers importing FASTQ files that already live on disk. To pull reads from a public archive instead, see ..."), which is exactly right and oriented me instantly. The 02-sequences chapters and most 05-variants and 06-classification chapters do not open with that explicit one-liner; they convey scope implicitly through "What it is" plus "What you will learn." That is acceptable but less crisp, and the inconsistency is visible when you read straight through. Forward references on my path resolved, with one exception my power-user colleague found in 03-reads/07 (the `../04-variants/` typo, below).

---

## Persona 2: INTERMEDIATE analyst (analyst-tier path)

I read the analyst tier: 02-sequences/04 (MSA and trees), 03-reads/05 (decontamination), 04-alignments/04 (alignment quality), 05-variants/03 (cross-caller), 05-variants/04 (nanopore), 06-classification/05 (NAO-MGS), 06-classification/07 (Freyja), 06-classification/08 (novel virus), 07-assembly/03 (Flye/Hifiasm), 08-workflows/01 and 02.

**(a) Does the reading path hold end to end?** Yes, and the analyst chapters are the strongest writing in Part II. 02-sequences/04 glosses MFP ("ModelFinder Plus: it tests a set of substitution models and picks the best-fitting one") and phylogram and support values inline, and the "this step is easy to miss: bootstrap is off by default" callout is the kind of operator-grade warning an analyst actually needs. 04-alignments/04 (Alignment Quality) is excellent: the per-workflow thresholds table (viral amplicon vs shotgun vs metagenomic) is the reference I will come back to, and the mark-vs-remove distinction ("the plain command only marks") is exactly the trap I would have fallen into.

**(b) Did the fidelity rewrites introduce jargon, density, or abruptness?** This is where the heavy rewriting shows, and it is mostly in 08-workflows/01 (The Workflow Builder). The chapter is correct and thorough, but the density of caveats about what is runnable vs export-only is high and repetitive. The same distinction is restated many times in slightly different words:

- "the only operations the native runner executes today are the five FASTQ-preprocessing steps"
- "Those generic nodes do not run inside the app."
- "is valid in the editor for export purposes but is rejected when you run it natively"
- "The five operation nodes marked runnable are the ones the native runner executes; the Analysis nodes are export-only"
- "There is no download node, no primer-trim node, no annotation node, and no phylogenetics node in the palette."

Each individual sentence is justified (the fidelity work clearly fought hard to stop a reader over-reading the Builder), but stacked together in one chapter they read as defensive, and the runnable/export-only boundary gets hammered five or six times before the worked example. An analyst skims this and thinks "I get it, the Builder only really does FASTQ preprocessing" by the third repetition. The 12-minute estimate feels low for the actual density; this is a 20-minute read. None of this is a comprehension blocker, but it is the one chapter on my path where the fidelity rigor visibly costs readability.

By contrast, 08-workflows/02 (Exporting) carries an equal amount of honest-limitations content but spreads it across well-labeled "what the export captures / what it does not" sections and a clean six-target table, so the density never piles up in one place. 02 is the model; 01 could borrow its structure.

One genuinely thin chapter: 06-classification/07-running-freyja. It is the only analyst chapter with no "What you will learn" section and no closing takeaway, its "## What it is" is three short paragraphs, and it goes straight to Inputs / GUI path / CLI path / Provenance. After the rich NAO-MGS and novel-virus chapters on either side, Freyja reads abrupt, almost like a man page. It is accurate, but a reader arriving here from the "run Freyja for wastewater" pointer in 05-variants/05 or 06-classification/01 will feel the chapter under-delivers on the build-up. The term "demix" is used in its title and body without a one-line gloss at first use (it is explained well in 05-variants/05 and 06-classification/01, but not in the Freyja chapter itself, which is where a reader who jumped straight here lands).

**(c) Are the rewritten chapters still satisfying?** 05-variants/03 (cross-caller) and 06-classification/05, /08 (NAO-MGS, novel virus) are very satisfying despite each losing a fabricated feature. 05-variants/03 is honest in its first paragraph that "Lungfish does not have a dedicated cross-caller comparison tool ... no comparison view, no intersection or union export, no codon-aware decomposition feature," and then it teaches me to do the comparison by eye in the shared table and to run `bcftools isec` externally, including the real codon-merge trap (`bcftools norm -a` before isec). That is more useful than the fake feature would have been, and it lands. The NAO-MGS and novel-virus chapters both pivot cleanly to "this is import-only" and give me a real viewport to read; neither feels like a stub.

**(d) Scope, glosses, forward references.** Glosses on the analyst path are strong (TASS, MFP, phylogram, seed, dust all defined inline). Scope one-liners are inconsistent (decontamination has one up top; cross-caller, nanopore, NAO-MGS, novel-virus, Freyja, and both workflow chapters do not lead with the explicit redirect, though they reach scope through "What it is"). Forward references resolved on my path.

---

## Persona 3: POWER USER (appendices + power-user chapters)

I read the power-user surface: all four 06-human-germline-variants chapters, appendices/power-user-notes, appendices/bibliography, and skimmed appendices/troubleshooting, cli-reference, file-formats, primer-schemes, shared-projects, tool-versions, and 06-running-in-ci.

**(a) Does the reading path hold end to end?** Yes. The GATK germline chapters (06-human-germline-variants 01-04) form a tight unit: HaplotypeCaller, joint genotyping, filtering/metrics, reference files. The preview-versus-execute model is defined once in 01 (the `isDryRun = !execute || dryRun` rule, with the three-row flag table) and correctly cross-referenced from 02, 03, and 04 rather than re-explained, which is exactly the cross-link-not-repeat discipline the foundations review asked for. Inline glosses are present where a power user new to GATK would need them: GVCF ("genomic VCF: per-position reference confidence"), GenomicsDB ("GATK's on-disk multi-sample store"), BQSR ("base quality score recalibration: GATK's correction of systematic sequencer quality errors using known sites"), dbSNP ("NCBI's database of known human variation"). Good.

appendices/power-user-notes is the standout reference: the canonical mpileup and ivar and lofreq flag tables, the provenance sidecar schema, the determinism table (which tool is bit-reproducible under which conditions), and the plugin-pack-version-is-not-a-lockfile caveat. This is the chapter that answers the "plugin pack version is not a conda lock" concern from the foundations review (#10), and it answers it precisely.

**(b) Did the fidelity rewrites introduce jargon, density, or abruptness?** For a power-user audience, the density in power-user-notes and the GATK chapters is appropriate and not a problem; that is what this tier is for. The bibliography is clean and resolves the missing-citations gap (#8) with real DOIs (Grubaugh 2019 iVar, Wilm 2012 LoFreq, Li 2018 minimap2, Quick/ARTIC-adjacent, Pangolin, Nextclade, IQ-TREE, MAFFT, Kraken2). No complaints on density.

The one thin-but-fine chapter is 06-human-germline-variants/04 (Reference Files for GATK). It is short and leads honestly with "'Reference pack' is a convenience name this manual uses ... It is not a Lungfish object. There is no `lungfish` command that installs ... a 'reference pack'." That negation-first opening is the right fidelity call (it kills a feature a reader might expect), and for a power user it reads fine because it immediately gives the folder-layout table and the real `gatk bqsr` and `conda install --pack` commands. A less expert reader might find an all-negation opener slightly deflating, but at the power-user tier it is correct and I would not change it.

**(c) Are the rewritten chapters still satisfying?** Yes. The GATK chapters never pretend Lungfish does more than wrap-and-provenance GATK, and the "preview by default, `--execute` to run" framing is consistent and trustworthy. The honesty is a feature for this audience.

**(d) Scope, glosses, forward references. THE ONE BLOCKER I HIT:** In 03-reads/07-ont-runs (which I read because it feeds the ONT variant chapter), the Medaka pointer is a broken link:

> "Medaka, the ONT-aware consensus and variant caller used in [Variants](../04-variants/), ships with model-specific parameters ..."

`../04-variants/` does not exist. Section 04 is alignments; variants is `05-variants`. Following that link is a 404. This is the exact failure mode the foundations review named as rule #4 ("forward references must resolve"), and it is the only one of its kind I found in the entire Part II+ corpus (I checked every cross-section and same-folder relative link mechanically; this is the sole broken target). It is a one-character fix but it is a real comprehension blocker because the reader who clicks it is specifically trying to find the Medaka chapter.

A second, softer scope gap: appendices/shared-projects is the only chapter in Part II+ whose first H2 is not the standard "## What it is" primer (it opens "## Locking a project"). It has no scope sentence and no primer; a reader arriving cold gets dropped straight into a procedure. Lint's primer-before-procedure rule may even flag this. Minor, but it is the one structural outlier.

---

## Round 3 accessibility polish for editors

These are polish items, not structural changes. The fidelity work is sound; this is about reading rhythm, tone uniformity, and one broken link. Ordered by priority within each tier.

### Must-fix (a real comprehension blocker)

1. **Broken cross-section link in 03-reads/07-ont-runs (line ~106).** `[Variants](../04-variants/)` must be `[Variants](../05-variants/)` (variants is section 05; section 04 is alignments). This is the only broken relative link in all of Part II+ and it sits exactly on the Medaka pointer a reader is trying to follow. One-character fix; do it.

### Nice-to-have (tone, uniformity, abruptness; no comprehension lost)

2. **Vary the closing refrain "So what should you do with this?"** The literal phrase now appears in 30 of 51 chapters (41 total occurrences; 05-variants/03, 06-germline/01, and 06-germline/03 use it twice each). The foundations review explicitly flagged this exact pattern (fix #14: "Don't use the literal phrase ... in every chapter") and recommended varying it ("the practical takeaway is...", "in practice...", or a clean topic sentence). The heavy fidelity rewrites appear to have propagated the literal phrase nearly universally rather than varying it. Read straight through, it becomes a tic. This is the single highest-leverage low-risk polish: keep the closing-takeaway move (it is genuinely useful), but reword maybe half the instances. The two-in-one-chapter cases (05-variants/03 and 06-germline/01, /03) are the most worth de-duplicating first.

3. **Thin out the runnable/export-only repetition in 08-workflows/01.** The native-runner-only-executes-five-FASTQ-steps point is restated five or six times (quoted in the analyst section above). Keep the single clearest statement in the "## What it is" scope paragraph plus the "Runnable natively" column in the node-type table, and trim the mid-chapter repetitions. Also bump `estimated_reading_min` from 12 toward 18-20; the density warrants it. 08-workflows/02 is the structural model: equal honesty, spread across labeled sections, never piled up.

4. **Warm up the three thin/abrupt chapters so they match their neighbors.**
   - **06-classification/07-running-freyja**: add a one-line "What you will learn" and a closing takeaway, and gloss "demix" at first use in this chapter (it is glossed in 05-variants/05 and 06-classification/01 but not here, and readers jump straight here from those pointers). It reads like a man page between two rich chapters.
   - **06-classification/07-importing-cz-id-results**: move the bottom "## Scope" section up into the opener as a one-line scope-and-redirect (the 03-reads pattern), and consider leading the Procedure with the GUI flow before the CLI block. Currently it changes rhythm against the smoother chapters around it.
   - **appendices/shared-projects**: give it a "## What it is" primer opener with a one-line scope sentence so it matches every other chapter (and satisfies primer-before-procedure). It is the only chapter that opens straight into a procedure heading.

5. **Standardize the opening scope one-liner.** The 03-reads section (and 04-alignments/05, appendices/cli-reference) leads every chapter with an explicit "This chapter covers X; for adjacent topic Y see Z" sentence, which the foundations review asked to standardize manual-wide (rule #1). Most of 02-sequences, 05-variants, 06-classification, 06-germline, 07-assembly, and 08-workflows convey scope implicitly via "What it is" + "What you will learn" but do not open with that explicit redirect. This is the lowest-risk uniformity improvement: lift the existing scope content into a leading one-liner per chapter, matching the 03-reads template. Not a blocker (scope is reachable), purely a crispness and consistency gain.

6. **Resolve or name the wastewater forward reference at its entry point.** This one lives in foundations (01-foundations/05, line ~135: "Wastewater ... is covered later in the manual") rather than Part II, so it is adjacent to my scope, but it is the doorway into the Part II wastewater chapters and it is the exact unresolved-forward-reference the foundations review flagged as #7. The Part II destinations now exist and are good (05-variants/05's Freyja section, 06-classification/07-running-freyja). Name them: change "covered later in the manual" to point at Consensus and Lineage and Running Freyja by name. Low risk, and it closes a loop the foundations readers complained about.

### Things to keep (landed well, do not touch)

- The "Vocabulary you will need" section in 05-variants/01 is the strongest accessibility device in Part II. Consider it the template for any future concept-heavy chapter.
- The inline-gloss discipline across the whole corpus is excellent and consistent (Phred, basecaller, soft-clip, pileup, TASS, MFP, GenomicsDB, BQSR, dbSNP, GVCF, phylogram, seed, dust, squiggle, adapter read-through all defined at first use for the right tier). Do not strip these in any future trim pass.
- The colorblind-safe framing is consistent and correct: 04-alignments/02 and 05-variants/03 both explicitly tell the reader to read the `Source` text / per-strand numbers rather than the tick color, honoring the no-RAG data-viz rule.
- The "what does good look like" / expected-output sections (05-variants/01, 03-reads/03, 04-alignments/04, 05-variants/04) give bench readers a competence checkpoint and are worth preserving everywhere they appear.
- The honest "what Lungfish does not do" / boundary sections (05-variants/05, 02-sequences/04, 08-workflows/02, the GATK chapters) are exactly what senior readers wanted and read as trustworthy, not apologetic. The negation-first openers in 06-germline/04 and 05-variants/03 are the right fidelity call; keep them.

# Focus group 3: early-career lab scientists (raw reactions)

**Date:** 2026-05-09
**Method:** Five distinct early-career-scientist personas reading the chapter cold and reporting honest reactions. Quotes are direct from the chapter.

## Persona 1: Maya Chen, research associate, academic virology lab

Maya read this on her second coffee of the morning. She has FASTQs from a recent in-house run sitting in `~/Desktop/run17/` and her PI told her to "try the Lungfish thing."

The opening line "A variant call set is the short answer to a long question" lost her for a beat. She wanted to know what she was about to *do*, not philosophy. She skimmed until she hit "The path has six ingredients" and that helped — she counted them off, felt grounded, then noticed the prose lists them as five + two callers, which read as six only if you parse carefully. She'd want a numbered list there.

What stopped her: "QIASeq Direct primers." She knows her lab uses ARTIC v3, not QIAseq. She immediately worried: *can I even use this chapter if my scheme is different?* The chapter eventually says "pick the primer scheme that matches the protocol you used" in Next Steps but does not tell her how to know what's bundled or how to bring her own. She would flag this for her senior tech before running on real data.

"The QIASeqDIRECT-SARS2 scheme bundled with Lungfish lists the start and end coordinates of every primer" — she does not know what that file looks like, where it lives, or how she would ever check it was correct. A screenshot of the primer scheme picker showing what schemes are available would be the single most useful image in the chapter for her.

Things she'd want shots for: the Operations Panel during a run (she's never seen it), the Inspector pane with the `Primer-trim BAM…` button, and the variant browser showing two tracks color-coded.

She would lift directly into her SOP: the `lungfish conda install --pack read-mapping variant-calling` line, the disk/time budget paragraph, and the iVar-vs-LoFreq one-liner ("iVar consumes a primer-trimmed BAM... LoFreq is happiest with a raw alignment"). She'd actually paste that quote into her lab notebook.

Condescending? No. Under-explained at her level? Yes — "soft-clips," "pileup," "multiple-testing correction," "dynamic threshold," "minority-haplotype evidence" all appeared without definitions. She knows what an allele frequency is but "Phred score can still fail to clear its dynamic threshold" was opaque.

She second-guessed: should she leave Advanced Options alone? The chapter says yes twice but she's been burned by defaults before. The "minimum allele frequency 0.05" got flagged in her brain because her PI cares about minority variants in some samples. She wants a sentence telling her *when* to lower it.

She would not run this on real data without asking her senior tech to confirm ARTIC v3 is in the picker. She would also ask: how do I know my BAM is good? The chapter never QCs the alignment.

## Persona 2: Diana Reyes, clinical microbiology technologist, public health lab

Diana works under SOPs. She does not customize. She read the chapter looking for the box she could check that says "this is validated; follow it exactly."

First reaction: "This chapter walks the full path from two public accession numbers to that VCF, twice over, using two different callers." She reread that. Twice over with two callers? Her SOP would pick one caller. She immediately asked: *which one is correct for clinical surveillance?* The chapter never recommends. It explicitly says "the takeaway is not that one caller is right and the other wrong." For her workflow, that is exactly the wrong message — she needs a recommendation tied to a use case.

She liked the "Before you start" section. Concrete commands, sizes, times. She would lift the install command, the disk budget, and the network-fallback note ("Lungfish tries ENA first and falls back automatically") straight into her validation document.

Stopped her: "iVar is tuned for primer-trimmed amplicon data, LoFreq for short-read viral data more generally, Medaka for long-read Nanopore." Her lab runs amplicon Illumina. So iVar? But the chapter then says LoFreq wants un-trimmed amplicon for population statistics. She does not know which to pick for her SOP.

"Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2" — she liked seeing the provenance string. That goes in her validation packet. She would screenshot that for her SOP.

Things she'd want a screenshot of: the entire Operations Panel after a successful run, the variant browser with the `PASS` chip selected, and the Inspector showing the primer-trim provenance sidecar.

Second-guessed: "minimum allele frequency 0.05." For surveillance, 0.05 is on the low end and would generate review burden. She wants guidance on lab-appropriate thresholds.

What she'd flag for a colleague: the un-trimmed BAM going into LoFreq feels wrong to her gut; she would want their bioinformatician to sign off before adopting it.

Under-explained: "multiple-testing correction" and "the LoFreq Phred score can still fail to clear its dynamic threshold." "ft filter flag" not defined; she'd guess "fail-threshold" and move on.

What's missing: positive/negative controls, validation guidance, a contamination check, a coverage minimum.

Tone: not condescending. Slightly academic. She wished it told her what to do, not what to think about.

## Persona 3: Sam Okafor, wastewater surveillance, small biotech

Sam is the one in this group who actually wants two callers and a calibration run. He read the chapter and largely nodded along.

He liked the framing: "A position both callers agree on at high allele frequency is a finding you can take to a downstream analysis. A position one caller flags and the other ignores deserves a second look at the pileup." That matches how he already works in R.

What stopped him briefly: "QIASeq Direct primers" again. His lab uses a custom amplicon scheme for wastewater. He looked for a "bring your own scheme" path. The chapter says Next Steps will cover that "future amplicon chapter" but does not give him a CLI flag or file format to look at.

What he'd lift: every `lungfish` CLI line in this chapter goes into a script. He noted with approval that the GUI exposes the same commands in the wizard. That is exactly what he wants. He would script the SRA download, mapping, primer-trim, and dual variant calls and treat the GUI as a viewer.

He second-guessed: minimap2 `-ax sr` for amplicon data. Some pipelines he's used preferred bwa-mem for amplicon. The chapter does not justify minimap2 vs alternatives.

He noticed and appreciated: the LoFreq-on-untrimmed convention is exactly what's in the field, and the chapter explained the model assumption. He'd quote that paragraph in his own internal docs.

What he'd want a worked example for: low-AF rows in his actual application (wastewater is full of minority variants — that *is* the signal). The chapter dismisses sub-1% LoFreq calls as "nearly always sequencing-error noise." For wastewater that is too dismissive. He would push back on this paragraph.

The codon teaching moment at 28881: he loved this section. He would screenshot the paragraph for his lab Slack.

Screenshots he wanted that aren't there: an actual rendering of the cross-caller comparison view at position 27889 to see how AF disagreement is visualized.

He would run this on real data after a single test run.

## Persona 4: Priya Krishnan, lab manager, academic core facility

Priya reads documentation looking for trouble. She runs many investigators' samples and needs to know where this pipeline will fail and what a user will call her about.

The "five minutes on a recent Apple Silicon Mac" claim made her squint. She services Intel Macs and older Apple Silicon. The chapter implies but does not specify a hardware floor.

She liked the determinism statement: "Variant calling is deterministic on the same inputs with the same caller." That is exactly the assurance she needs to tell investigators "if you re-run, you get the same numbers."

What stopped her: "The dialog closes when the FASTA lands in the project's `Downloads/` folder. Lungfish prompts you to make a reference bundle out of it." She wants a screenshot of the bundle prompt. Without it she cannot picture what users will see and cannot answer their tickets.

She second-guessed: the "Auto-detect" layout for SRA. She knows SRA metadata is sometimes wrong. What happens when metadata is wrong? Not addressed.

Things she'd want a screenshot for: the Operations Panel mid-run, the Inspector with `Primer-trim BAM…`, the Call Variants tool sidebar, the variant browser showing the `Source` column and the `PASS` chip. None of these are rendered in this draft.

What she'd lift directly into facility documentation: the "two plugin packs" install line, the disk/time budget, the ENA-vs-SRA-Toolkit fallback paragraph, and the "primer-trim is not optional decoration" paragraph for her training deck.

What she'd flag for colleagues before facility rollout: (1) no QC step on coverage or contamination, (2) no recommendation on iVar vs LoFreq for her users' use cases, (3) the chapter assumes one sample at a time, no batch mode shown, (4) the "future amplicon chapter" gap for non-QIAseq schemes — most of her users do ARTIC.

Under-explained at her level: the codon-merging paragraph. She does not know how a user attaches a GFF. The chapter gestures at "a project that already has the GFF attached" but never says how to attach one.

Tells she sees: "Lungfish drives every step from the Operations Panel" appears twice; she'd want one consolidated "what the Operations Panel is" sidebar early. The chapter assumes the user knows what that is.

She would not roll this out to her facility without a screenshot pass, a QC section, and an ARTIC scheme pre-bundled.

## Persona 5: Daniel Park, postdoc year 1, viral evolution lab

Daniel did his PhD on autophagy. Fluent in pipettes, blots, confocal. Has never opened a VCF until last week. His PI handed him a real Nanopore dataset.

He read the chapter slowly. He liked the philosophical frame — it sounded like a paper introduction.

But: he is doing Nanopore. The chapter is Illumina. The chapter mentions Medaka for Nanopore in passing and again in Next Steps as a future chapter. He felt the rug pulled. He read on anyway because he needs the concepts.

Stopped him cold: "VCF: one row per position where the sample disagrees, with the bases involved and how confident the caller is." He has been told there is a chapter zero. There is no chapter zero. The "Before you start" section says "you can read a VCF row at the level chapter zero introduced." He does not know what INFO or FORMAT payloads are.

Stopped him: "soft-clips the primer-derived bases off read ends so they do not look like real variants." He does not know what soft-clipping is.

Stopped him: "pileup." Used three times. Never defined.

Stopped him: "minus-strand," "strand-bias filter," "Phred score," "dynamic threshold," "multiple-testing correction." He has heard of Phred. Not the others.

What he'd want screenshots of: literally everything. The Welcome window, the New Project dialog, every menu path, the Inspector pane, the Operations Panel, the variant browser. He has not seen the app.

He second-guessed: every choice. "Short read (sr)" preset — is that right for Illumina paired-end? Why is the iVar default 5%?

What he'd lift: the explanatory paragraphs in "Why this matters" and "Interpreting what you see." Those translate to lab-meeting explanation. The codon merging story at 28881 he found genuinely illuminating.

What he'd flag for a colleague: he would not run this on his Nanopore data. The chapter does not warn him off; it just doesn't apply to his sequencing platform.

Condescending? Slightly. The "you will read the cross-caller comparison the way you read a gel, fluently" assumes he reads gels with practiced fluency. He does. But the analogy still stings a little because the chapter didn't earn the casual tone for someone this new.

He felt the chapter was written for someone with one prior sequencing analysis under their belt. He has zero.

## Cross-cutting issues

- Chapter zero is referenced but does not exist; multiple personas hit the VCF column primer gap. Postdoc is fully blocked, others partially.
- Primer scheme coverage: only QIASeqDIRECT-SARS2 is shown. Three of five personas use ARTIC or custom schemes. The "bring your own scheme" path is deferred to a future chapter without even a CLI hint.
- Nanopore reader hits a wall. Chapter is Illumina-only despite "you will run this against your own reads" framing.
- Missing screenshots: every persona wants the Inspector pane, the Operations Panel mid-run, the variant browser, and the Call Variants tool sidebar.
- Vocabulary gaps: soft-clip, pileup, strand-bias, Phred, multiple-testing correction, dynamic threshold, minority-haplotype, consensus AF, merge AF distance.
- No QC section. No coverage minimum, no contamination check, no positive/negative control guidance.
- No recommendation on which caller to use. Clinical SOPs and many academic labs need a default recommendation.
- GFF attachment is invoked in the codon-merging discussion but never explained or shown.
- "Five minutes on a recent Apple Silicon Mac" is unspecific about hardware floor.
- iVar 0.05 default flagged by three personas as the parameter most likely to need tuning per use case.
- The "low-AF LoFreq calls are sequencing-error noise" paragraph reads as actively wrong to wastewater readers whose signal lives there.
- Strong points: the "Before you start" disk/time/network paragraph; the iVar-trimmed vs LoFreq-untrimmed rationale; the codon merging passage at 28881; the determinism sentence; the CLI equivalents under each step.

# Focus group 4: experienced power users (raw reactions)

**Date:** 2026-05-09
**Method:** Five distinct power-user personas (15+ years, PI, consultant, postdoc, tool developer) reading the chapter cold and reporting honest reactions. Quotes are direct from the chapter.

## Persona 1: Dr. Margaret Chen, senior staff scientist, sequencing core

15+ years in core facilities. Maintains a Snakemake pipeline that runs bwa-mem2/bcftools for hundreds of samples a week.

The opening line "A variant call set is the short answer to a long question" makes her roll her eyes. She is here for the procedure. By paragraph three she is wondering whether the tool is opinionated enough to be useful or vague enough to bury its choices. The "five minutes on a recent Apple Silicon Mac" claim sets off alarms — five minutes from accession to VCF tells her corners are being cut. Where is the QC? She sees no FastQC, no fastp, no adapter trim, no duplicate marking. The author hand-waves this as "A future alignment chapter ... will walk through producing the BAM you used here at greater depth, including read-quality filtering and duplicate marking." That is not a future chapter, that is the chapter.

The specific thing that worries her most: `minimap2 -ax sr` for paired Illumina amplicons, piped to sort, with no mention of `-Y`, no read-group injection that she can see, and "leave them as shipped" as the only advice. What does the wizard actually pass? When she runs her own pipeline she wants to know the exact command. The author shows snippets like `lungfish map ... --paired --preset sr` with literal ellipses.

Provenance sidecar that the iVar dialog reads to disable the "already primer-trimmed" checkbox — that's actually nice. Better than what most GUIs do. But "the iVar TSV-to-VCF converter, when handed a real GFF, would group those three SNPs into a single haplotype row with REF `GGG` and ALT `AAC`" — that's a non-trivial piece of behavior. Where is that documented? What annotation source? GenBank? Ensembl? RefSeq's GFF? Different GFFs disagree about ORF1ab boundaries.

Best-practices critique: the chapter teaches that you feed iVar primer-trimmed BAM and LoFreq un-trimmed BAM. That is a defensible position, but it is not the only convention. Plenty of shops trim once and feed both. A power user reading this needs the citation.

What she wants and doesn't get: a way to dump the Operations Panel as a runnable shell script, a config schema for the wizard defaults, and a way to override `lofreq call-parallel` thread count.

Verdict: she'd run the CLI before she touched the GUI.

## Persona 2: Prof. James Okonkwo, PI, viral surveillance lab

20+ years. Runs a wastewater and clinical surveillance program. Reads docs to decide whether to recommend tools to a half-dozen students.

The framing of the chapter is good. "Producing the VCF yourself is the only way to know which caller, which parameters, and which preprocessing steps are baked into the table you are looking at." Yes. That's the right thing to teach a beginner. The cross-caller comparison framing — "two different statistical lenses" — is also good pedagogy.

But this chapter assumes a "chapter zero" that doesn't exist. "you can read a VCF row at the level chapter zero introduced (CHROM, POS, REF, ALT, FILTER, the per-site INFO and FORMAT payloads)." Don't ship a chapter that points at a missing prerequisite.

The thing he'd push back on is the throwaway "Omicron-lineage SARS-CoV-2 isolate" without naming the lineage. If you tell a student that 28881-28883 GGG>AAC is "the classic B.1.1 / Omicron N-protein signature" you should at minimum say which lineage SRR36291587 actually is. As written, the student learns a folk fact about a sample they cannot identify.

The line "iVar is tuned for primer-trimmed amplicon data, LoFreq for short-read viral data more generally, Medaka for long-read Nanopore" is the kind of one-liner that is fine as orientation but wrong as guidance. LoFreq is fine on amplicon data with appropriate filters. iVar will run on un-trimmed data and warn.

What impresses: the explicit teaching that primer scheme choice matters and that strict strand-bias filters reject real amplicon variants. That's a concept he has to teach his third-year students every single year.

What he'd want: a section on consensus generation. Going from VCF to a consensus FASTA is the actual surveillance workflow. A "next steps" mention is not enough.

Recommendation to his group: maybe. Worth piloting on one or two samples. He'd want to see the consensus chapter exist before he sent students at it.

## Persona 3: Sara Linhardt, bioinformatics consultant, clinical lab support

10 years supporting CLIA labs. Galaxy and CLI. Strong opinions about validation and audit trails.

She evaluates tools on whether she can reconstruct exactly what happened to a sample three months later when a regulator asks. So her eyes go straight to provenance. The "primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2" caption with auto-checked acknowledgement is exactly right. That is what an audit trail looks like.

Now the things that scare her. "Lungfish tries the ENA mirror first and falls back to the SRA Toolkit if ENA refuses; you do not see that decision unless the fallback fires." For a clinical workflow the reader needs to see the decision every time, and the fixture's md5 needs to be in the provenance record.

The defaults table buried in the Advanced Options is not enough. "Minimum read length after trim 30, Minimum quality 20, Sliding window width 4, Primer offset 0" — those are the iVar defaults from the iVar man page. Document that they are.

`LoFreq's permissive defaults` keeps getting referenced but never specified. What min-cov, what min-bq, what min-mq, what sig threshold? The author is conflating two different filters when they say LoFreq is "permissive."

Best-practices critique: for clinical work the chapter should be calling variants with `bcftools mpileup | bcftools call -m -v` as a baseline orthogonal caller, not just iVar vs LoFreq, both of which are amplicon-flavored. Two callers from the same family is not actually the kind of cross-validation the prose claims.

What she'd want: a manifest file that captures every command, every input md5, every plugin pack version, every conda env hash.

The worst sentence in the chapter: "Once you have walked it once with these accessions, you can run the same procedure against your own reads with two clicks and one accession swap." No clinical reader is doing two clicks. They are validating a pipeline. Do not market the workflow as casual.

## Persona 4: Dr. Aaron Vinokur, postdoc, computational biology

8 years past PhD. Builds Snakemake/Nextflow pipelines. Cares about reproducibility.

His first question: where is the lockfile? "The first install pulls about 250 MB into `~/.lungfish/conda` and takes a couple of minutes" — a couple of minutes of what, exactly? Is that solving environment, or pulling a pinned env from a frozen YAML? If it solves on every machine, the tool versions drift and the chapter's "deterministic on the same inputs with the same caller" claim is wrong in practice.

The deterministic claim is also too strong. `lofreq call-parallel` with default threads will produce identical output across runs only if you pin the chunking. `samtools sort` is deterministic, but `minimap2` with multi-threading and certain build options is not bit-identical across thread counts on every input.

The provenance sidecar idea is the right idea. What he wants to see is the sidecar schema: is it JSON, is it versioned, does it embed the conda env hash, does it embed the input md5, does it survive `lungfish bundle export`?

The CLI translation footnotes are useful but inconsistent. Step 1 shows full `lungfish fetch ncbi` invocation. Step 3 shows `lungfish map ... --paired --preset sr` with ellipses. Step 5 shows the iVar invocation in full. If the chapter is going to teach the CLI as a parity surface, teach it consistently.

What impresses: that the GUI and CLI are the same engine and the wizard records the CLI invocation. If that is real, that solves a real reproducibility problem with click-driven tools.

The codon-merge footnote is fascinating but also concerning. "the iVar VCF you produce there will collapse the three rows into one. LoFreq will still emit three rows." That means the same sample run on the same machine gives different output depending on whether a GFF is attached to the bundle. That's not deterministic in the sense readers will expect.

Worst omission: no mention of the GenBank/Ensembl provenance for the GFF.

## Persona 5: Lin Patel, bioinformatics engineer, sequencing company

Has read both the iVar paper and the LoFreq paper. Has actually contributed PRs to similar pipelines.

She's specific about where the tool description is wrong on its own terms.

"iVar is tuned for primer-trimmed amplicon data, LoFreq for short-read viral data more generally" — iVar is not "tuned" in any statistical sense. iVar variants is essentially a thresholding caller on top of `samtools mpileup` with allele-frequency and quality cutoffs and a Fisher's exact test for strand bias. There is no model. LoFreq has a per-base error model with Phred-aware likelihood. Calling iVar "tuned" puts them on equal footing, which they aren't.

"LoFreq applies a per-site quality model and a multiple-testing correction; on high-depth amplicon pileups, the LoFreq Phred score can still fail to clear its dynamic threshold." The dynamic threshold is the Bonferroni correction over the number of tested positions. That's correct, but the chapter doesn't explain the mechanism. Worse: the example numbers ("position 1193, AF 0.123, depth 1531") are exactly the regime where LoFreq SHOULD call. If LoFreq is silent there, something else is going on — possibly indel realignment (`lofreq indelqual --dindel` and `lofreq alnqual` are not mentioned anywhere), possibly base-quality cutoff, possibly the un-trimmed primer artifact contaminating the pileup. The chapter should at minimum mention `lofreq indelqual` for indel calling. Without it LoFreq under-calls indels by design.

`samtools mpileup | ivar variants` with no `-aa -A -d 600000 -B -Q 20` flags shown. Those are the canonical iVar flags from the iVar docs. Are they being passed? `-B` (no BAQ) is critical for amplicon data; `-d 600000` raises the depth cap; `-A` keeps anomalous read pairs. If Lungfish is passing `samtools mpileup` defaults, depth gets capped at 8000 and a high-depth amplicon dataset gets silently truncated.

The codon-merge claim is also confused. iVar emits per-position rows in its TSV with codon annotation when given a GFF, but it does not emit a haplotype row with REF=GGG ALT=AAC unless the converter is doing extra work. The author says "the Lungfish converter writes the iVar TSV out as VCF" and elsewhere says the converter does codon merging. So Lungfish is doing the merge, not iVar. Attribute the work correctly. A reader who goes looking in the iVar source for codon merging is going to file a bug against the wrong project.

What impresses: that the chapter knows iVar is not a model-based caller and that LoFreq's threshold rises with depth. Most user manuals don't get either point.

What she'd want: the exact mpileup invocation, the exact lofreq invocation, the conda env solve hashes, and an indelqual flag.

## Aggregate

Where they converged:

- The CLI parity story is undermined by ellipses. Chen, Vinokur, and Patel all want the full underlying invocations shown.
- The "five minutes, two clicks, accession swap" framing repels every power user. Chen, Linhardt, and Vinokur all read it as marketing copy that contradicts the chapter's own teaching about provenance.
- The chapter assumes a chapter zero that does not exist. Okonkwo flagged it explicitly; everyone else implicitly relied on knowing VCF already.
- LoFreq is mischaracterized. Linhardt and Patel both pushed back on the word "permissive" and on the missing `indelqual` step. Okonkwo would be uncomfortable teaching a student from this description.
- The provenance sidecar is the standout positive. Chen, Linhardt, and Vinokur all called it out as the reason to take the tool seriously.
- Read QC and duplicate marking are absent and noticed by Chen and Okonkwo.
- The codon-merge behavior is interesting and unsettling: every reviewer who registered it (Vinokur, Patel, Chen) wanted attribution clarified and a louder warning about non-determinism with respect to GFF presence.

Where they disagreed:

- Patel wants more statistical machinery exposed (mpileup flags, indelqual). Okonkwo wants less jargon and more lineage-level orientation. Same chapter, opposite directions.
- Linhardt wants bcftools added as an orthogonal caller. Patel thinks two callers is fine if they are described correctly.
- Vinokur wants every CLI invocation appended as a shell block. Chen wants per-step CLI; Okonkwo doesn't care.
- On audience: Okonkwo and Linhardt would assign this to trainees; Chen and Patel would not.

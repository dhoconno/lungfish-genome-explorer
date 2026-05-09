# Focus group 1: undergraduate biology students (raw reactions)

**Date:** 2026-05-09
**Method:** Five distinct undergraduate personas reading the chapter cold and reporting honest reactions. Quotes are direct from the chapter.

## Persona 1: Maya Chen, sophomore (Intro Genetics)

Maya skims the title and the first paragraph carefully. She gets through one sentence before hitting trouble: *"The short answer is a VCF file."* She has no idea what that is. The chapter says she should already, because of "chapter zero," but she can't find a chapter zero, so she's already feeling behind.

She reads on. *"a sequencing run (`SRR36291587`, about 86,000 paired-end Illumina read pairs from a clinical sample prepared with QIAseq Direct primers)"* — this is where she stalls. "Paired-end," "Illumina," "QIAseq Direct primers," and "primers" all in one sentence. She knows DNA is A/C/G/T and that primers exist from her textbook, but "paired-end" and "amplicon" later are blank slots.

She tries to power through "Why this matters" and gives up at *"Strand bias treatment matters: amplicon data is structurally strand-biased because primers point in fixed directions."* She doesn't know what amplicon data is, what strand bias is, or why primers pointing in fixed directions would matter. She copies the term "amplicon" intending to look it up later.

She does notice and likes: *"The whole workflow takes about five minutes on a recent Apple Silicon Mac."* That feels reassuring. She also likes *"Treat the chapter as a calibration run."*

She skims "Before you start" and gets stuck on `lungfish conda install --pack read-mapping variant-calling`. She has not used a terminal before in any serious way and the chapter doesn't say where to type that. The line *"Install both at once from the shell"* assumes she knows what "the shell" is.

She skips down to "Procedure" and follows step 1 mostly OK because the menu names are concrete (`Tools > Search Online Databases > Search NCBI…`). She likes that. But then step 1 ends with a CLI line: *"Behind the dialog the CLI ran `lungfish fetch ncbi MN908947.3 --fetch-format fasta --save-to Downloads/MN908947.3.fasta`"* and she wonders if she's supposed to type that too. She's not sure what "behind the dialog" means.

By step 4 (Primer-trim) she's lost. *"soft-clips the primer-derived bases off read ends so they do not look like real variants"* — what's soft-clipping? What's a primer-derived base?

She'd give up around the iVar dialog, specifically at *"the `This BAM has already been primer-trimmed for iVar` acknowledgement is auto-checked."* She doesn't know what BAM is, has no idea what acknowledgement she'd be making, and feels the chapter isn't for her.

What she wishes existed: a one-line definition of VCF, BAM, FASTQ, primer, amplicon, and "reference genome" near the top. Or just a "you'll need to know these words first" list with links.

## Persona 2: Jordan Patel, junior pre-med (one summer of microbiology wet-lab)

Jordan reads the opening paragraph carefully and is mostly fine. They know what a reference genome is and have a vague idea of "comparing a sequence to a reference." VCF is new but the description *"one row per position where the sample disagrees, with the bases involved and how confident the caller is"* clicks. They mark this as a small "oh, that's what a VCF is" moment.

They get to the second paragraph and hit *"a clinical sample prepared with QIAseq Direct primers."* They know what PCR primers are from lab. They're guessing this means PCR-amplified for sequencing, which is mostly right.

Then: *"a primer-trim step (`ivar trim` driven by the QIASeqDIRECT-SARS2 primer scheme) that soft-clips the primer-derived bases off read ends so they do not look like real variants."* They re-read this twice. They get the gist (primers add bases that aren't really from the patient sample) but don't know what "soft-clip" means. The metaphor of "trimming" lands.

The "Why this matters" section is where they have a real insight. *"Primer-derived bases sit at fixed positions on every read from a given amplicon, and a caller cannot tell those bases apart from the sample's real sequence."* They write "ohhhh" mentally. This is the most useful sentence in the chapter for them. But they hit "amplicon" three times and finally Google it.

They skim the rest of "Why this matters" because it's dense and starts feeling like a lecture. The line *"iVar is tuned for primer-trimmed amplicon data, LoFreq for short-read viral data more generally, Medaka for long-read Nanopore"* feels like name-dropping.

Procedure section: they read carefully and follow along mentally. Step 3 (Map the reads) goes fine. Step 4 (primer-trim) makes sense now. Step 5 (iVar) is where they slow down at *"merge AF distance 0.25, minimum ALT quality 20, ignore strand bias on."* They don't know what any of those numbers mean, but the chapter says "leave them as shipped," so they're OK.

The Interpreting section is where they get genuinely interested. The codon teaching moment lands: *"the codon that encodes amino acid 203 of the nucleocapsid"* — they know codons, they know nucleocapsid from COVID news. Insight: variants can be three rows or one row depending on annotation. They mark this as the coolest part of the chapter.

They wish: a one-sentence definition of "amplicon" near the first use. Maybe a small diagram of "primer + read + reference" showing what gets soft-clipped.

## Persona 3: Riley Okonkwo, senior CS+Bio (only ran BLAST in a course)

Riley flies through the introduction. The CLI vibe is comforting. They notice immediately: *"Variant calling is deterministic on the same inputs with the same caller. Different callers with different defaults can disagree on borderline calls."* They like this framing.

They skim "Why this matters" because it reads like prose; they prefer the data flow. They mentally redraw it as: SRA + NCBI ref → minimap2 → BAM → primer-trim → BAM' → {iVar, LoFreq} → 2 VCFs. Fine.

They install the conda packs from the shell without issue. They don't know what micromamba is doing, but the line *"about 250 MB into `~/.lungfish/conda`"* is concrete enough.

In "Procedure" they actually slow down because the GUI instructions are verbose and they'd rather just see the CLI. They appreciate that the CLI equivalent is included at the end of every step. They might just run the whole thing from the shell.

They get caught on the convention switcheroo around step 5: the chapter has "Procedure" steps 1-4, then re-numbers from 1 again for the variant-calling steps. *"You now have a project with one reference, two alignment tracks, and zero variant tracks. The next four steps run two callers..."* and then steps 1-4 again. They flag this as bad numbering. They thought step 1 referenced creating the project.

They stop at *"the Lungfish converter writes the iVar TSV out as VCF."* They're mildly annoyed. They want to know: what is iVar's native output? The chapter implies TSV, but doesn't say so until here. Why TSV not VCF natively? Minor curiosity.

The Interpreting section is what they read most carefully. *"LoFreq applies a per-site quality model and a multiple-testing correction; on high-depth amplicon pileups, the LoFreq Phred score can still fail to clear its dynamic threshold."* They want a citation or a doc link to understand the model. *"dynamic threshold"* is hand-wavy.

They love the codon paragraph. *"`##LungfishNote=GFF unavailable; codon merging skipped`"* — concrete, debuggable. They'd want a "how to attach a GFF" link.

What they wish: an architecture diagram, the actual CLI commands collapsed into one runnable shell block at the end, and a deeper dive on LoFreq's threshold math. Maybe a flag about reproducibility: which versions of minimap2, ivar, lofreq are pinned in the conda packs.

## Persona 4: Sam Reyes, junior (one bioinformatics elective)

Sam read about FASTQ in a course slide deck once. Never opened one. They remember "phred scores."

They read the opening fine. *"VCF file: one row per position where the sample disagrees"* — that mostly clicks. They've seen VCF on a slide before. The mention of "chapter zero" worries them; they look for it, can't find it, and feel the chapter assumes more than they have.

The "six ingredients" paragraph is helpful. They like the explicit list. *"about 86,000 paired-end Illumina read pairs"* — they remember "paired-end" vaguely from the elective. *"`SRR36291587`"* — they don't know what an SRA accession is on sight, though the chapter explains "Sequence Read Archive" later in passing.

"Why this matters" — they read carefully because they want to understand. The amplicon paragraph mostly lands. *"iVar consumes a primer-trimmed BAM (it disclaims any responsibility for amplicon bias if you give it an un-trimmed one)"* — they like the personification, makes it memorable.

They get tripped up at *"LoFreq is happiest with a raw alignment because its statistical model expects a population of reads where read starts are randomly distributed."* They don't fully understand why "randomly distributed read starts" matters but they take it on faith.

In "Before you start," the conda install line works. They were not sure what a "plugin pack" was at first but the *"about 250 MB into `~/.lungfish/conda`"* makes them feel oriented.

In "Procedure" they follow along. They like that menu paths are explicit. They're a little confused at *"Lungfish prompts you to make a reference bundle out of it. Accept the default name and click `Create Bundle`. The reference appears in the left sidebar under `Reference Sequences > MN908947.3`."* — what is a "reference bundle"? Why bundle? But they keep going.

They love step 4 because primer-trim actually does something visible: a new track shows up. They feel they're making progress.

Step 5 (iVar) is where they hit jargon density. *"minimum allele frequency 0.05, consensus allele frequency 0.75, merge AF distance 0.25, minimum ALT quality 20, ignore strand bias on"* — they don't know what most of those mean. They take the "leave them as shipped" advice and move on.

The Interpreting section is the high point. The lesson *"`the call set' is not a single object. It is a function of caller, parameters, and preprocessing"* lands hard. They didn't know that.

They wish: a glossary box for "allele frequency," "depth," "Phred quality," "soft-clip," and "primer scheme" right where these terms first appear. Also a caption for the screenshots — they're labeled but the page has no images yet?

## Persona 5: Aaliyah Brooks, senior biochem (thesis on viral evolution)

Aaliyah reads the opening with confidence. She's read papers describing variant calls and is here to finally produce one. *"one row per position where the sample disagrees, with the bases involved and how confident the caller is"* — yes, she already knew that, but the framing is clean.

She finds the six-ingredients paragraph reassuring. She's heard of minimap2, has seen "iVar" in supplementary methods, vaguely knows LoFreq. The Wuhan reference accession (`MN908947.3`) is familiar. She's never run any of this herself.

"Why this matters" is the section where she settles in. *"Producing the VCF yourself is the only way to know which caller, which parameters, and which preprocessing steps are baked into the table you are looking at."* She nods. This is exactly her situation reading her advisor's papers. *"Variant calling is deterministic on the same inputs with the same caller. Different callers with different defaults can disagree on borderline calls."* — she finds this honest.

She skim-reads "Before you start." Conda install is fine.

In "Procedure" she goes carefully. The mapping wizard makes sense. Primer-trim makes sense. iVar dialog makes sense. She likes *"the `This BAM has already been primer-trimmed for iVar` acknowledgement is auto-checked and disabled, with a caption that reads `Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2`."* — she sees provenance tracking and approves.

The Interpreting section is where she's most engaged. The three-category breakdown of disagreements is exactly what she needs. *"iVar is reporting raw observations. LoFreq is reporting observations the model believes are more likely real than instrumentation noise."* She wants more here, specifically about LoFreq's multiple-testing correction. The chapter waves at it.

The codon paragraph is the climax for her. *"`R203K plus G204R, the classic B.1.1 / Omicron N-protein signature`"* — she knows R203K from papers. She gets a real "oh!" moment at *"This is the moment you realize that 'one variant per row' is a presentation choice with biological consequences."*

But she has questions: how does the GFF merging work for non-adjacent SNPs in the same codon (split by a deletion, say)? What about overlapping reading frames in viruses? The chapter doesn't say.

She also notices the chapter never compares to a published consensus or known lineage call. *"the classic B.1.1 / Omicron N-protein signature"* is mentioned but not cross-referenced to a Pango call or a Nextclade output. She'd want that for her thesis.

What she wishes: more on filter strategy for real samples (not the calibration run); a link to a fuller treatment of LoFreq's stats; how to take the VCF into downstream analysis (annotation, lineage assignment, phylogenetics); what a real publication-quality call set workflow looks like.

## Aggregate cross-cutting points

- Missing chapter zero is felt by everyone except the senior biochem. Maya, Sam, and even Riley flag the chapter zero reference. The CHROM/POS/REF/ALT/FILTER/INFO/FORMAT primer is assumed but doesn't exist.
- "Amplicon" is the single most repeated stumbling word. Jordan, Maya, and Sam all hit it. It appears unglossed in paragraph 2 of "Why this matters" and is load-bearing for the rest of the chapter.
- Other unglossed jargon flagged across personas: soft-clip, BAM, FASTQ, primer scheme, allele frequency, depth, ALT quality, strand bias, pileup, Phred score, reference bundle, paired-end, preset sr, GFF.
- The CLI lines confuse the GUI-only readers. Maya in particular doesn't know if she's supposed to run the *"Behind the dialog the CLI ran ..."* lines herself.
- Numbering bug. Riley flagged that "Procedure" restarts at 1 after step 4.
- "Leave them as shipped" rescues people but feels black-boxy.
- The codon paragraph is the most-loved paragraph among the three more advanced personas.
- Aaliyah and Riley both want more on LoFreq's statistics and on what to do downstream.
- Maya would close the page around step 4 or 5.
- Nobody complained about prose quality. The complaint is consistently about assumed prerequisites and unglossed terms, not writing.

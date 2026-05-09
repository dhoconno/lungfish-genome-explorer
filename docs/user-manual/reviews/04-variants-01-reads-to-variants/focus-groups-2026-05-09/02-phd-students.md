# Focus group 2: PhD students (raw reactions)

**Date:** 2026-05-09
**Method:** Five distinct PhD-student personas reading the chapter cold and reporting honest reactions. Quotes are direct from the chapter.

## Persona 1: Maya Chen, year 2 microbiology PhD

Studies *Pseudomonas aeruginosa* virulence factors. Has run Illumina MiSeq through her core a few times for bacterial WGS, and once cobbled together a `bwa | samtools` pipeline from a tutorial.

She nods at the opening: "what does this sample carry that differs from the reference" matches how she'd explain it to a rotation student. She likes that the chapter promises a finished project at the end.

She stops at "two public accession numbers." She knows what an SRA accession is, but only vaguely. The chapter assumes she knows MN908947.3 is "the" SARS-CoV-2 reference — she doesn't, and she'd want a parenthetical for that.

She gets uneasy at *"a primer-trim step (`ivar trim` driven by the QIASeqDIRECT-SARS2 primer scheme) that soft-clips the primer-derived bases."* She has never touched amplicon data — bacterial WGS uses random fragmentation. The Why-this-matters section helps her, especially *"Primer-derived bases sit at fixed positions on every read from a given amplicon."* That's the line that lands.

She wants a citation or footnote at *"iVar disclaims any responsibility for amplicon bias if you give it an un-trimmed one."* That sounds like an editorial paraphrase. She'd want the iVar paper or docs linked.

The shell command in "Before you start" is fine — she can copy/paste — but *"Lungfish tries ENA first and falls back automatically"* makes her wonder what ENA is. No expansion of the acronym.

In the procedure, *"In the `Mapper` row choose `minimap2`. In the `Preset` dropdown choose `Short read (sr)`, the right preset for paired Illumina data"* is the kind of hand-holding she wants — she'd nod here.

She bounces off the codon section hard. *"The N-protein open reading frame puts positions 28881, 28882, and 28883 inside one codon"* — she remembers codons are three bases, but she has no intuition for SARS-CoV-2 gene structure, and the casual mention of "R203K plus G204R, the classic B.1.1 / Omicron N-protein signature" reads like jargon she can't decode without Googling.

Prerequisite assumptions she lacks: SARS-CoV-2 lineage names (B.1.1, Omicron), the QIAseq Direct protocol, what amplicon means structurally, ENA. She'd want a brief glossary callout for "amplicon library."

Things she'd verify: the 86,000 read-pair count for SRR36291587, the 250 MB conda footprint, the 5-minute claim.

She finishes feeling she could click through it but would feel shaky about transferring it to her own (non-amplicon) bacterial reads.

## Persona 2: Daniel Okafor, year 4 virology PhD

Works on influenza A reassortment. Runs `nf-core/viralrecon` regularly but didn't build it. R is his second home.

The opening lands well. *"The short answer is a VCF file: one row per position where the sample disagrees"* matches his model. He likes the framing of running two callers on purpose.

He pushes back on *"`minimap2` with the short-read preset"*. Viralrecon uses `bwa-mem` for short reads by default, and he'd want a sentence on why minimap2-sr instead of bwa. Not wrong, just a choice he'd want defended.

He's never primer-trimmed by hand, so *"you do not see that decision unless the fallback fires"* is exactly the level of automation he wants. He likes the ENA-first behavior because viralrecon does the same.

He's suspicious of *"LoFreq is happiest with a raw alignment because its statistical model expects a population of reads where read starts are randomly distributed."* He's read that LoFreq documentation actually does support amplicon mode with appropriate filters, and the chapter's framing makes it sound like trim-then-LoFreq is wrong. He'd want a citation — the LoFreq paper or the artic / viralrecon convention — because *"the convention in the field, and the one the chapter follows, is to feed LoFreq the un-trimmed alignment"* is asserted, not sourced. In his experience viralrecon trims first and then calls with everything.

He nods at *"A position both callers agree on at high allele frequency is a finding you can take to a downstream analysis"* — that matches how he reads variant tables.

He's annoyed by *"iVar gives you a clean call set with a higher floor; LoFreq gives you a noisier call set that includes minority-haplotype evidence."* He thinks of LoFreq as more conservative, not less, on per-site evidence. He'd want the depth-AF threshold trade-off explicit.

The codon block reads fine to him. But he'd want *"the iVar TSV-to-VCF converter, when handed a real GFF, would group those three SNPs into a single haplotype row with REF `GGG` and ALT `AAC`"* checked against actual iVar behavior. iVar itself outputs codon-aware annotations only with `-g` and a GFF; the chapter's claim that the converter merges rows is a Lungfish behavior, not an iVar behavior, and the prose blurs that.

Citations he'd want: minimap2 sr-preset choice, LoFreq-on-amplicons convention, iVar's primer-trim assumption.

He's the persona most likely to fact-check the prose against the upstream tool docs. Overall he'd run it but with skepticism.

## Persona 3: Priya Raghavan, year 1 bioinformatics PhD

CS undergrad, year of ML, pivoting. Fluent in Python, Docker, AWS. Has never sequenced anything.

The first paragraph reads fine to her as prose. She immediately searches for "what's a VCF column" — and the chapter explicitly says *"you can read a VCF row at the level chapter zero introduced (CHROM, POS, REF, ALT, FILTER, the per-site INFO and FORMAT payloads)."* Chapter zero doesn't exist. She doesn't know what FILTER means, what INFO and FORMAT carry, what AF is. Every later table reference assumes she does.

She reads *"about 86,000 paired-end Illumina read pairs from a clinical sample prepared with QIAseq Direct primers"* and asks: paired-end, amplicon, primers, clinical sample — four concepts in one phrase she has no biology for. She'd want a 30-second amplicon-vs-shotgun primer.

She likes the imperative, dialog-by-dialog procedure. As a programmer she finds *"The CLI equivalent is `lungfish fetch sra download SRR36291587`"* very valuable.

She trips over *"`minimap2 -ax sr` piped into `samtools sort` and `samtools index`."* What's `-ax`? What's a "sorted, indexed BAM"? She'd want a footnote linking to a BAM-format primer.

The Why-this-matters paragraph on strand bias is opaque. She has no idea what "strand" means in a sequencing context.

She nods at *"Variant calling is deterministic on the same inputs with the same caller."* That matches her CS expectation.

The interpretation section is the hardest. She'd want a calibration table: "for SARS-CoV-2 amplicon data, depth above X is typical, AF below Y is suspect."

The codon paragraph is fine — she gets that R203K is a name for a substitution — but she wouldn't know it's diagnostic of a lineage.

Prerequisites she lacks: codon mechanics by heart, lineage taxonomy, basic sequencing biology, the full VCF schema.

Things she'd want linked out: VCF spec, BAM spec, minimap2 paper, iVar paper, LoFreq paper. As a programmer she'd be frustrated that the chapter cites tools by name without DOIs or version numbers.

She'd finish having clicked through every step but understanding maybe 60% of why each step matters.

## Persona 4: Rachel Sturm, year 3 genetics PhD

Studies rare-disease alleles in trios using GATK joint-genotyping. Lives in VCFs. Has never opened a viral genome.

The opening is too gentle for her. *"A variant call set is the short answer to a long question"* — yes, she knows. She skims to the path-of-six-ingredients paragraph and finds it useful as a roadmap.

She immediately notices what's missing from her mental model: there's no joint genotyping, no GQ, no PL, no pedigree. *"one row per position where the sample disagrees"* — no, in her world a row is one position with N samples. She'd push back on the framing as oversimplified, then realize this is single-sample viral, and accept it.

She's surprised by *"a primer-trim step."* Human exomes don't have this. She'd want one sentence saying "this step is amplicon-specific; shotgun and capture data skip it."

She nods hard at *"Variant calling is deterministic on the same inputs with the same caller. Different callers with different defaults can disagree on borderline calls."* That's GATK vs. DeepVariant in her world.

She bounces off *"Lungfish's iVar dialog default of 5%."* In her world AF is per-allele in a diploid, not "fraction of reads supporting ALT." She'd want one sentence reframing AF for haploid viral. Specifically: *"a variant supported by 2% of reads"* — she'd have to translate "of reads" rather than "of alleles." That's a real conceptual shift the chapter doesn't flag.

She's curious about *"strand-bias filter."* GATK's `FS` and `SOR` are her daily companions. The chapter's mention of *"a strict strand-bias filter will reject genuine variants on the basis of the protocol you used to generate the reads"* matches her intuition that strand bias is protocol-confounded.

She'd want a citation at *"LoFreq applies a per-site quality model and a multiple-testing correction; on high-depth amplicon pileups, the LoFreq Phred score can still fail to clear its dynamic threshold."* That's a substantive statistical claim she'd want sourced.

The codon paragraph is the place she'd pause. In GATK she's used to multi-nucleotide variants (MNVs) and `--mnp-distance`. The chapter's framing — that the iVar converter merges three adjacent SNPs into one row only if a GFF is attached — would prompt her to ask whether it's actually a haplotype-phased merge or just a positional merge. *"REF `GGG` and ALT `AAC`"* implies positional, but she'd want it spelled out: are reads required to carry all three changes on the same molecule, or is the merge purely codon-coordinate?

Prerequisite assumptions she has and doesn't: she has VCF, FILTER, INFO, FORMAT, BAM, depth, AF (diploid). She lacks viral biology (gene names, lineage names, what 21618 means anatomically).

She'd verify: the LoFreq dynamic-threshold-with-depth claim, the iVar codon-merge mechanics.

She'd finish able to read the tables but mildly suspicious of the haploid-AF semantics.

## Persona 5: Tomás Herrera, year 5 epidemiology PhD

Writes a dissertation on SARS-CoV-2 lineage circulation in Latin America. Uses Pangolin and Nextstrain daily. Has never run a variant caller from raw reads.

He recognizes *"`MN908947.3` SARS-CoV-2 Wuhan isolate, 29,903 bases"* immediately. He nods at *"the spike `C21618T` near the start of the gene"* — that's spike T19I in his head, an Omicron BA.2 hallmark. He likes that the chapter is honestly about Omicron without forcing him to guess the lineage.

But he stalls at *"the run of substitutions and deletions in the spike receptor-binding domain (around positions 21632, 21764, 22578, 22674-22688)."* Some of those positions don't match canonical BA.1/BA.2/BA.5 RBD signatures cleanly in his head. He'd want to verify against Outbreak.info or CoV-Spectrum. The phrase *"around positions"* is loose enough that he'd flag it.

He nods at *"the synonymous pattern in nsp3 (positions 1931, 2790, 2954, 3037)"* — 3037 C>T he knows by heart.

He pushes back on *"R203K plus G204R, the classic B.1.1 / Omicron N-protein signature."* R203K/G204R is canonically a B.1.1 (Alpha-precursor) signature — calling it "Omicron" without clarification is loose. Most Omicron lineages do carry it (inherited), but the framing matters for an epidemiologist.

He'd push back on *"the spike `C21618T` near the start of the gene."* C21618T sits at the start of the gene in nucleotide coordinates, but spike's signal peptide is functionally distinct from RBD; he'd want "near the start of the gene" replaced by "in the N-terminal domain."

He's the persona most attuned to whether the example data plus the prose actually cohere. He'd want to verify SRR36291587's lineage assignment against Pangolin. The chapter never says which lineage this isolate is, which annoys him — half the calls he'd interpret depend on lineage.

He nods at *"reading two callers' tables for the same sample is the most honest way to see which positions are findings."* He believes in cross-tool sanity checks because he does the same with Nextclade vs. Pangolin.

Things he'd want cited: the Outbreak.info lineage definitions, Pangolin/Nextclade for the example sample's assignment, the QIASeq Direct protocol primer scheme version.

Prerequisite knowledge he has: lineage names, gene anatomy, key positions. What he lacks: minimap2 vs. bwa choices, iVar internals, LoFreq statistics.

He'd finish wishing the chapter named the lineage of SRR36291587 explicitly and either showed or linked a Pangolin assignment, because that's how he'd contextualize every variant.

## Cross-cutting issues

- Missing chapter zero is felt hard. Maya, Priya, and Rachel all hit the *"at the level chapter zero introduced"* assumption and get different things from it.
- The LoFreq-on-untrimmed-amplicons claim wants a citation. Daniel and Rachel both flagged *"the convention in the field, and the one the chapter follows, is to feed LoFreq the un-trimmed alignment"* as an asserted convention without a source.
- The codon-merging behavior is ambiguous about agency. Daniel and Rachel both noticed that the chapter blurs whether codon collapse is an iVar feature, a Lungfish converter feature, or a positional vs. phased merge.
- Lineage and genomic-coordinate claims want verification. Tomás flagged the RBD position list and the *"classic B.1.1 / Omicron"* attribution; Maya flagged the Omicron-jargon density; Daniel flagged minimap2-sr vs. bwa.
- Amplicon biology assumed, not introduced. Maya, Priya, and Rachel all came in cold to amplicons.
- The 5% AF default trade-off lands but isn't quantified. Rachel and Daniel both noticed iVar 5% vs. LoFreq permissive without a depth-AF curve or threshold table.
- Citations and version pinning absent. Priya, Daniel, and Tomás independently wanted DOIs or version numbers for minimap2, iVar, LoFreq, and the QIASeq scheme.

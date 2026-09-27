---
title: Questions on Designing qPCR and dPCR Assays
page_type: study-questions
chapter_id: 10-primer-design/04-designing-qpcr-and-dpcr-assays
checked_against: "2026.9.52"
tiers:
  beginner: {questions: 3, design_minutes: 45}
  intermediate: {questions: 3, design_minutes: 90}
  advanced: {questions: 3, design_minutes: 150}
datasets:
  - accession: NM_001101.5
    what: human ACTB messenger RNA
    source: NCBI Nucleotide
    size: "1,812 bases"
    tier: beginner
    verified: 2026-09-27
  - accession: NM_000344.4
    what: human SMN1 messenger RNA, variant d
    source: NCBI Nucleotide
    size: "1,482 bases"
    tier: intermediate
    verified: 2026-09-27
  - accession: NM_017411.4
    what: human SMN2 messenger RNA, variant d
    source: NCBI Nucleotide
    size: "1,482 bases"
    tier: intermediate
    verified: 2026-09-27
  - accession: LN830753.3
    what: HLA-B*27:05:02 genomic
    source: NCBI Nucleotide
    size: "3,325 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT908328.1
    what: HLA-B*27:05:03 genomic
    source: NCBI Nucleotide
    size: "3,325 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT962569.1
    what: HLA-B*27:03 genomic
    source: NCBI Nucleotide
    size: "3,325 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT795519.1
    what: HLA-B*27:09 genomic
    source: NCBI Nucleotide
    size: "3,325 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT962574.1
    what: HLA-B*27:08 genomic
    source: NCBI Nucleotide
    size: "3,324 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT962598.1
    what: HLA-B*44:03:01:02 genomic, exclusion set
    source: NCBI Nucleotide
    size: "3,323 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT575606.1
    what: HLA-B*15:01:01 genomic, exclusion set
    source: NCBI Nucleotide
    size: "3,326 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT908373.1
    what: HLA-B*81:02 genomic, exclusion set
    source: NCBI Nucleotide
    size: "3,323 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT962566.1
    what: HLA-C*04:49 genomic, exclusion set
    source: NCBI Nucleotide
    size: "3,349 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT908386.1
    what: HLA-A*29:11 genomic, exclusion set
    source: NCBI Nucleotide
    size: "3,315 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: LT908351.1
    what: HLA-A*03:08 genomic, exclusion set
    source: NCBI Nucleotide
    size: "3,299 bases"
    tier: advanced
    verified: 2026-09-27
demo_projects: []
answer_keys:
  - 10-primer-design/04-designing-qpcr-and-dpcr-assays/beginner
  - 10-primer-design/04-designing-qpcr-and-dpcr-assays/intermediate
  - 10-primer-design/04-designing-qpcr-and-dpcr-assays/advanced
glossary_refs: [primer, pcr, msa, consensus-sequence, iupac-ambiguity-code, gc-content, allele, mhc]
reader_checked: false
expert_checked: false
---

These questions go with [Designing qPCR and dPCR Assays](../../chapters/10-primer-design/04-designing-qpcr-and-dpcr-assays.md). None can be answered by finding a sentence in the chapter. Work through the tier that fits you and stop there. [How to use the study questions](../index.md) explains the three tiers and the Guidance blocks.

Every tier ends with a design project in Lungfish Genome Explorer (LGE) on real human sequences that no demo project contains, so the chapter's lesson gets tested on data you have not seen. Each project needs the PCR Primer Design pack, and the Intermediate and Advanced ones also need the Multiple Sequence Alignment pack.

## Beginner

For a reader who has just finished the chapter. It assumes you know what a primer and a probe are and nothing about running a design. The design project gives you every step and takes under an hour.

### Question B1. A probe that melts with its primers

**Explain.** About 10 minutes.

A colleague's assay has both primers at 60 °C and a probe at 59 °C, run with a combined annealing and extension step at 60 °C. The same primers work well with an intercalating dye.

Predict how the probe assay's signal compares with the same assay redesigned with a probe at 67 °C, and explain the mechanism. Then explain why the dye version gives no hint of the problem.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The prediction is weaker and later signal, meaning a lower plateau and a later cycle of quantification. The mechanism is that signal comes only from probes the polymerase cuts. At 60 °C a probe melting at 59 °C is bound less than half the time, so the polymerase often passes the site with no probe there to cut. The product is made and under-reported.

The dye binds any double-stranded DNA, so it reports the product whether a probe was bound or not. A good dye result therefore shows the primers work and says nothing about the probe. An answer that blames the primers has missed that the dye run clears them.

</details>

### Question B2. Why the amplicon is short

**Explain.** About 10 minutes.

A colleague wants to raise a qPCR assay's product maximum from 150 to 400 bases so that more primer pairs come back.

Give two separate reasons a quantitative assay keeps its product short, and say which of the two the chapter's own failed run demonstrated.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The first reason is that quantification assumes every molecule is copied completely in every cycle, which becomes less true as the product grows. The second is that a long single-stranded product folds, and a folded product competes for the sites the primers and the probe need.

The chapter's failure demonstrates the second. With the size bounds at 360 to 440 bases, every candidate folded more stably than the −3 free-energy cutoff, so the run discarded all of them and reported nothing after 938 seconds. A complete answer names both reasons and attributes the failure to folding rather than to copying.

</details>

### Question B3. Reading a pair before you order it

**Apply.** About 15 minutes.

A design returns this pair.

| Role | Sequence | Length | Tm |
|---|---|---|---|
| Forward primer | `CCCTGGACTTCGAGCAAGAG` | 20 nt | 60.1 °C |
| Reverse primer | `GAACCGCTCATTGCCAATGG` | 20 nt | 60.2 °C |

The product is 107 bases. Apply the chapter's checks to it and say, item by item, whether each passes. Then name the one thing this table cannot tell you.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

Three checks pass. The two primers sit 0.1 °C apart, so one annealing temperature suits both. The product is 107 bases, inside 70 to 200. And both primers are 20 bases, inside the usual 18 to 24.

The thing the table cannot tell you is whether the pair is specific, meaning whether these primers also bind something else in the sample. That needs a comparison against the sequences the assay must not detect, which is the chapter's central point. A strong answer also notes that no probe is listed, so this is a dye assay and the readout will report any product.

</details>

### Design project B4. A reference-gene assay, step by step

**Design, guided.** About 45 minutes, every step given.

Laboratories that measure how much of a gene is expressed compare it against a gene whose level barely changes, and human ACTB is one of the commonest such reference genes. This project designs a dye assay on it.

1. Make a new project with **File > New Project**, then choose **Tools > Search Online Databases > Search NCBI...**, type `NM_001101.5`, and download the record, as [Downloading from NCBI](../../chapters/02-sequences/02-downloading-from-ncbi.md) shows. It is 1,812 bases.
2. Select the new bundle in the sidebar and choose **Tools > PCR Primer Design > Primer3…**.
3. Set **Assay** to **qPCR · intercalating dye**, leave **Amplify a specific region** off, set **Candidate pairs** to 5, and name the analysis `ACTB qPCR dye`. Click **Run**. The first run prepares the Primer3 environment, so allow about a minute.
4. Open the analysis under `Analyses` and read the Results tab. Write down the five pairs with their product sizes and both melting temperatures.
5. Open the **Primer3 explanation** disclosure at the foot of the Results tab and copy the line it holds.

Hand in the table of five pairs, the explanation line with a sentence saying what its last number means, and one sentence for each of the two checks from Question B3 that this table can answer.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The reference run returned five pairs, the best two being `CCCTGGACTTCGAGCAAGAG` with `GAACCGCTCATTGCCAATGG` at a 107-base product, and the same forward primer with `GGAACCGCTCATTGCCAATG` at 108 bases. Three more pairs sit further along the transcript with products of 141, 143 and 87 bases. Every primer melts between 59.6 and 60.2 °C.

The explanation line reads `considered 523, unacceptable product size 513, tm diff too large 1, ok 9`. The last number means nine pairs satisfied every rule, and the analysis reports the best five of them.

Your numbers should match if every setting was left at the preset's value. A difference means something was changed, which is worth finding rather than worrying about. If a probe appears in your results, the probe preset was selected instead of the dye preset.

</details>

## Intermediate

For a reader who has run a design and wants to test one. It assumes you can build an alignment and read Binding inspection. The design project names the goal and the route, and leaves the settings to you.

### Question I1. What a degenerate probe costs

**Apply.** About 15 minutes.

A varVAMP design returns this probe.

```text
ACYTGGRCCAAKTCGGTACCTGCAG
```

1. How many different sequences does the supplier synthesise, and at what concentration is each present if the probe is used at 250 nM in total?
2. A sample carries only one of the target versions. Predict how its signal compares with a non-degenerate probe at 250 nM, and explain why.
3. You rerun with **Maximum probe ambiguities** set to 0. Describe what varVAMP must now find, and one reason it might return fewer assays.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

Y is C or T, R is A or G, and K is G or T, so three positions with two choices each give 8 sequences, each at about 31 nM.

A target matching one version is recognised by an eighth of the probe molecules, so fewer are bound and cut each cycle, giving weaker signal and a later cycle of quantification. A strong answer adds that the effect differs between versions, so quantification is unequal across the alleles the assay was meant to treat alike.

With no ambiguities allowed, the probe must sit where every aligned sequence carries the same base at every position under it. In a variable gene such stretches may be rare inside a short amplicon, so fewer candidates survive. Mentioning the supplier point from the chapter, that some suppliers refuse mixed bases in a labelled probe, shows why anyone would set this.

</details>

### Question I2. The consensus threshold on six sequences

**Apply.** About 15 minutes.

You add two more alleles to the four the chapter uses, giving six rows, and set the cumulative consensus threshold to 0.75.

1. One column holds A in five rows and G in one. Another holds A in four rows and G in two. What does the consensus write at each?
2. A primer sits over the first column. Which allele is at risk, and how does the answer change with where in the primer the column falls?

<details class="guidance" markdown="1">
<summary>Guidance</summary>

At 0.75 on six rows a base needs at least 4.5 rows, so 5 of 6 in practice. The first column, 5 of 6, is written as A. The second, 4 of 6, falls short, so varVAMP writes R for A or G.

The one allele carrying G at the first column is at risk, because the primer holds a plain A there. Near the primer's 3′ end the mismatch can stop extension and lose that allele. Near the 5′ end it is usually tolerated. The chapter's run at 0.99 on four rows avoided this, because every row had to agree.

</details>

### Question I3. Reading a new explanation line

**Analyse.** About 20 minutes.

A probe design on a different template ends with this line.

```text
considered 1540, unacceptable product size 1490, tm diff too large 25, no internal oligo 19, ok 6
```

1. What share of the pairs passed, and what does "no internal oligo 19" say about the sequence between those primers?
2. A colleague wants more candidates and suggests three changes. Raise the product maximum to 400, allow 3 °C between the two primers, or move the target elsewhere on the gene. Which would you accept for a quantitative assay, which would you refuse, and why?

<details class="guidance" markdown="1">
<summary>Guidance</summary>

Six of 1,540 is about 0.4 percent. "No internal oligo 19" counts pairs that met every primer rule but had no stretch between them meeting the probe rules, so no site there had the right length, melting temperature and GC content, or every candidate began with a G.

Read the counts correctly. These pair-level numbers cover only primers that already passed every single-oligo rule, so "unacceptable product size" means no surviving left primer could be paired with a surviving right primer inside the size range. It does not mean primers that failed on GC content were counted here, because such a primer never reached the pairing stage.

A strong answer refuses the first two changes. A 400-base product breaks the assumption that every molecule is copied completely each cycle and folds more, and a 3 °C gap means no single annealing temperature suits both primers. It accepts moving the target, or accepts six candidates as enough to test.

</details>

### Design project I4. An assay for one of two nearly identical genes

**Design, partly guided.** About 90 minutes.

Humans carry two nearly identical copies of the survival motor neuron gene, SMN1 and SMN2. How many copies of SMN1 a person has sets whether they develop spinal muscular atrophy. An assay that cannot tell the two apart is useless for that question. This project finds out whether a routine probe design can tell them apart.

Download both transcripts into a new project, align them, design a probe assay on SMN1, then test it against SMN2.

| Accession | What it is | Length |
|---|---|---|
| `NM_000344.4` | SMN1 messenger RNA, variant d | 1,482 bases |
| `NM_017411.4` | SMN2 messenger RNA, variant d | 1,482 bases |

The route. Import both records, align them with MAFFT, and read how similar they are. Then design a hydrolysis-probe assay with Primer3 using the SMN1 row as the template. Finally open **Binding inspection** and compare each oligo against the SMN2 row.

Hand in the alignment's dimensions and identity value, the columns at which the two transcripts differ, the oligos of your best pair with their melting temperatures, the mismatch counts against SMN2, and a paragraph answering the question the project asks, which is whether this assay could count SMN1 copies.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The alignment is 2 rows by 1,482 columns with no gaps, and the identity is 0.998650. The two transcripts differ at exactly two columns, 857 and 1141, which is 2 differences in 1,482 positions.

The reference run's best pair is forward `ACCACCACCCCACTTACTATC` at 685, probe `TGCTGGCTGCCTCCATTTCCTTCTGGACC` at 707 melting at 65.5 °C, and reverse `TCCCAAAGCATCAGCATCATC` at 779, giving a 115-base product spanning 685 to 800. Every oligo matches SMN2 with zero mismatches, because the amplicon contains neither differing column.

The answer to the project's question is no. The assay would measure SMN1 and SMN2 together. A complete paragraph says so and names what would have to change, which is placing an oligo over column 857 or 1141, ideally with the difference at a primer's 3′ end or under the probe.

Two findings earn extra credit. Noticing that the conserved-sites policy changes almost nothing here, because with two variable columns in 1,482 nearly the whole transcript is already conserved. And noticing that both differing columns lie outside this transcript's coding sequence, which runs from 18 to 902, so a real copy-number assay for these genes is designed on genomic sequence instead.

</details>

## Advanced

For a reader who wants to judge whether a design is fit for its purpose. It assumes everything above and a willingness to reach a negative conclusion. The design project states a requirement and leaves the method to you.

### Question A1. Which mismatch stops a primer

**Analyse.** About 15 minutes.

A forward primer ends `...GCTTCCAG-3′`. Three sequences you must not detect differ from it as follows, while the reverse primer and probe match all three perfectly.

| Sequence | Mismatches under the forward primer |
|---|---|
| N1 | One at the last base, the 3′ end |
| N2 | One at the fourth base from the 3′ end |
| N3 | Two, both in the 5′ half |

Rank the three by how likely each is to amplify, explain the ranking, and say what bench result would show whether your ranking was right.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

N3 is most likely to amplify, since the 3′ end pairs perfectly and 5′ mismatches are usually tolerated. N2 comes next, since a mismatch a few bases in slows extension without reliably stopping it. N1 is least likely, because a mismatch at the 3′ terminal base can prevent extension outright.

A complete answer adds two cautions. Which bases meet matters, and some pairings extend more readily than others. And one mismatch reduces the chance of amplification rather than removing it. The bench result is a reaction on DNA carrying each non-target sequence with no target present. Late signal or none shows the discrimination works.

</details>

### Question A2. Choosing one assay to order

**Analyse.** About 20 minutes.

A varVAMP run with an off-target screen reports three assays.

| Assay | Length | ΔG | Penalty | Probe ambiguities | Off-target warning |
|---|---|---|---|---|---|
| A | 180 bp | −2.8 | 1.9 | 2 | yes |
| B | 90 bp | −0.5 | 3.4 | 0 | no |
| C | 120 bp | −1.2 | 2.5 | 1 | yes |

Choose one to order first for a dPCR test that must give a yes or no answer per animal, justify it, explain why the lowest penalty is not the obvious pick, and say what the absence of a warning does and does not prove.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

A strong answer picks B. It is shortest and folds least, its probe has no ambiguity codes, and it is the only one without an off-target warning, which matters most for a yes or no answer. Its higher penalty only means its oligos sit further from the ideal length, melting temperature and GC content, and the penalty says nothing about specificity.

The absence of a warning means varVAMP found no product in the database you gave it. It says nothing about sequences absent from that database, such as alleles missing from your exclusion set, and nothing about behaviour in a tube. The answer should end with the bench test on known positive and known negative material.

</details>

### Question A3. A specificity claim you cannot check in silico

**Explain.** About 20 minutes.

A collaborator sends a design and writes that every oligo was checked against a database of related sequences with no hits, so the assay is specific.

Give three separate reasons that claim could still be wrong, and for each one name the evidence that would settle it.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

Three good reasons, and a complete answer needs three distinct ones rather than three versions of one.

The database may be incomplete, missing alleles or organisms present in real samples, and the evidence is a reaction on material known to carry them. A hit search may miss a partial match that still amplifies, since two primers with a few tolerated mismatches can make a product where an exact search finds nothing, and the evidence is a reaction rather than a search. And the sample contains material the design never considered at all, such as host DNA or other organisms, so the evidence is a reaction on real sample matrix rather than on purified target.

The best answers add that specificity is a property of an assay in a particular sample type, not of a sequence, so the claim needs the negative controls named.

</details>

### Design project A4. Detect one HLA-B lineage and nothing else

**Design, open-ended.** About two and a half hours.

HLA-B*27 is the human class I lineage associated with ankylosing spondylitis, and a laboratory screening for it needs an assay that detects the lineage and stays off the rest of a locus that is among the most variable in the human genome. The chapter reached a hard conclusion about this kind of assay using macaque sequences. This project tests whether the same conclusion holds on human data.

Build a project on these eleven records, all verified to exist, each about 3.3 kb.

| Role | Accessions |
|---|---|
| Must detect | `LN830753.3` B*27:05:02, `LT908328.1` B*27:05:03, `LT962569.1` B*27:03, `LT795519.1` B*27:09, `LT962574.1` B*27:08 |
| Must not detect | `LT962598.1` B*44:03, `LT575606.1` B*15:01, `LT908373.1` B*81:02, `LT962566.1` C*04:49, `LT908386.1` A*29:11, `LT908351.1` A*03:08 |

Design the best lineage-detection assay you can, then establish whether it meets the requirement. How you do that is up to you. Decide what to measure, what evidence would convince a colleague, and what you would do next.

Hand in your design with its oligos, the evidence you gathered about the exclusion set, a verdict, and a plan.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

What the reference run found, so you can check your own. MAFFT on the five targets gives 5 rows by 3,325 columns, and on all eleven gives 11 rows by 3,466 columns. varVAMP in qPCR mode at a 0.99 threshold reported eight assays in 79 seconds, none carrying an ambiguity code, because the five B*27 alleles agree at every column the design used. The top-ranked assay spans 123 to 250, with forward `CAACCTATGTCGGGTCCTTCTT`, probe `CCGGCGACACTGATTGGCTTCTCTA` and reverse `TGCGTGGGGACTTTAGAACTG`.

The verdict, which is the point of the project. All 24 oligos across the eight assays match all five B*27 targets with zero mismatches. Every one of the eight assays also matches B*44:03 and B*15:01 with zero mismatches on all three oligos, and the top-ranked eighth assay additionally matches B*81:02 with zero on all three. Only the two HLA-A records are reliably excluded. So no reported assay is specific to the lineage, and any of them would amplify a sample carrying B*44:03 or B*15:01, which is common.

This reproduces the chapter's conclusion on independent human data, which is why the project is worth doing. A design engine maximises conservation inside the set you give it, and the sites five B*27 alleles share are largely the sites the whole locus shares.

A complete submission states the verdict plainly and proposes a plan that names a discriminating column and where in an oligo to place it. A submission that concludes the assay works because every target matched perfectly has walked into the trap the exclusion set exists to expose.

Acceptable approaches vary. Reading mismatches in the alignment viewport is as valid as any other route, and adding a local BLAST database of the exclusion set so varVAMP reports its own off-target warnings is the fuller version of the task.

</details>

## For instructors

Each tier's conceptual questions use numbers that can be changed without changing what is tested, and each design project has verified substitutes of equal difficulty. Guidance here gives the measured results for the published data only, so changing a record or a table keeps a graded set honest. All three design projects on this page have been solved in LGE, and the resulting projects and write-ups are available to instructors, including the full oligo-by-allele mismatch table for the Advanced project.

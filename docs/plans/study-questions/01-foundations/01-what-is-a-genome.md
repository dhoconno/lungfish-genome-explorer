---
title: Questions on What Is a Genome
page_type: study-questions
chapter_id: 01-foundations/01-what-is-a-genome
checked_against: "2026.9.52"
tiers:
  beginner: {questions: 3, design_minutes: 40}
  intermediate: {questions: 3, design_minutes: 60}
  advanced: {questions: 3, design_minutes: 120}
datasets:
  - accession: NM_000518.5
    what: HBB messenger RNA
    source: NCBI Nucleotide
    size: "628 bases"
    tier: beginner
    verified: 2026-09-27
  - accession: NG_011806.1
    what: F5 RefSeqGene
    source: NCBI Nucleotide
    size: "81,578 bases"
    tier: intermediate
    verified: 2026-09-27
  - accession: NG_016465.4
    what: CFTR RefSeqGene
    source: NCBI Nucleotide
    size: "257,188 bases"
    tier: advanced
    verified: 2026-09-27
  - accession: NC_001807.4
    what: the older human mitochondrial reference, named in a question only
    source: NCBI Nucleotide
    size: "16,571 bases"
    tier: advanced
    verified: 2026-09-27
demo_projects: []
answer_keys:
  - 01-foundations/01-what-is-a-genome/beginner
  - 01-foundations/01-what-is-a-genome/intermediate
  - 01-foundations/01-what-is-a-genome/advanced
glossary_refs: [reference-genome, coordinate, contig-reference, accession, codon, cds, exon]
reader_checked: false
expert_checked: false
---

These questions go with [What Is a Genome](../../chapters/01-foundations/01-what-is-a-genome.md). None can be answered by finding a sentence in the chapter, because each one applies the chapter's ideas to a case it does not cover. Work through the tier that fits you and stop there. [How to use the study questions](../index.md) explains the three tiers and what the Guidance blocks are for.

Every tier ends with a design project in Lungfish Genome Explorer (LGE) on a real public record that no demo project contains. The Beginner project gives you every step. The Advanced project gives you a goal.

## Beginner

For a reader who has just finished the chapter. It assumes you can read a coordinate and find a codon in a table, and nothing more. The design project walks you through every click.

### Question B1. Naming a position so someone else can find it

**Explain.** About 10 minutes.

A colleague sends you this message. "The variant is at position 5227002, please check it in your data."

List every piece of information you would have to ask for before you could look that position up, and say for each one what could go wrong if you guessed instead.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

A complete answer asks for three things. Which sequence the number counts along, because a number alone names no place. Which assembly or record version, because the same sequence name carries different positions in GRCh37 and GRCh38. And how the sequence is spelled in their files, `chr11` or `11` or an accession, because a program that meets two spellings treats them as two sequences.

For each one the answer should say what guessing costs. Guessing the sequence lands you on a position in the wrong chromosome. Guessing the assembly lands you near the right place but on the wrong base. Guessing the spelling gives you no match at all, which is the least dangerous of the three because it fails loudly.

</details>

### Question B2. A length that does not match

**Apply.** About 10 minutes.

You are given a file that claims to hold the HBB region record used in the chapter. LGE shows its length as 81.7 Kb. A colleague's copy of the same record shows 1,608 bases.

Which of the two is the record the chapter uses, and what is the other one most likely to be? Say what you would check next to be sure.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The chapter's record is 81,706 bases, which LGE rounds to 81.7 Kb, so the first file is the record. 1,608 bases is the span of the HBB gene alone, from 70545 to 72152, which is 72152 minus 70545 plus 1. The second file is most likely an extraction of just the gene, not the whole region.

The check that settles it is the sequence name and the feature list. The region record carries several genes, including HBE1, HBG2, HBG1, HBD and HBB. A gene-only extraction carries one.

</details>

### Question B3. Which codon does the base fall in

**Apply.** About 10 minutes.

The HBB coding sequence starts at position 70595 of the record and its first stretch runs to 70686.

Work out which codon number each of these record positions falls in, and which base of that codon it is. Show the arithmetic.

| Position | Codon number | Base within the codon |
|---|---|---|
| 70601 | | |
| 70607 | | |
| 70614 | | |

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The method is the same each time. Subtract 70595, divide by 3, and read the whole part and the remainder. Position 70601 gives 6, so codon 3, base 1. Position 70607 gives 12, so codon 5, base 1. Position 70614 gives 19, so codon 7, base 2, which is the sickle cell base.

A complete answer shows the subtraction and the division rather than only the three answers. A common slip is to forget that a remainder of 0 means the third base of the previous codon, not the first base of the next.

</details>

### Design project B4. Find a disease base on the HBB transcript

**Design, guided.** About 40 minutes, every step given.

Hemoglobin E is a common variant of the same gene the chapter follows. Clinical reports write it `c.79G>A`. This project finds that base on a different record from the chapter's, the HBB messenger RNA.

1. Make a new project with **File > New Project** and name it something like `HbE`.
2. Choose **File > Search Online Databases > Search NCBI...**, type `NM_000518.5`, and download the record, as [Downloading from NCBI](../../chapters/02-sequences/02-downloading-from-ncbi.md) shows. It is 628 bases and arrives in seconds.
3. Click the new bundle in the sidebar and write down two things from the Inspector. The record's length, and the range of its CDS feature, which the annotation track draws below the bases.
4. The CDS starts at position 51. Work out the record position of coding position 79 with the method from Question B3, then type that position into the location field to see it.
5. Read the three bases of the codon it falls in, and say which amino acid the codon specifies and which it becomes after the change. The chapter's codon table covers both.

Hand in the record length, the CDS range, the record position of `c.79`, the codon before and after the change with both amino acids, and one sentence saying why this record needs no jump across an intron while the chapter's record does.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The record is 628 bases and its CDS is `51..494`, one unbroken stretch. Coding position 79 is record position 51 plus 79 minus 1, which is 129. That is codon 27, base 1, and the codon reads `GAG`, glutamate. The change makes it `AAG`, lysine.

The last sentence is the point of the project. A messenger RNA record holds the joined-up message with the introns already removed, so the coding sequence is one range and the arithmetic is a single subtraction. The chapter's `NG_000007.3` is genomic, so its CDS is three ranges and a codon can straddle two of them.

If your position lands on a different base, check whether you added 51 and 79 without subtracting 1, which gives 130 and shifts you one base along.

</details>

## Intermediate

For a reader who is comfortable with coordinates and wants to handle a real record. It assumes you can read a CDS made of many exons and are ready to think about strands. The design project tells you the goal and the route but not every click.

### Question I1. The other variant in codon 7

**Apply.** About 15 minutes.

Hemoglobin C changes the first base of the same codon as the sickle cell change. Clinical reports write it `c.19G>A`.

1. What is the coordinate of this base on `NG_000007.3`?
2. What is codon 7 before and after the change, and which amino acid does each specify?
3. What is the GRCh38 coordinate of this base, which base does GRCh38 show there, and which base would a carrier's reads show?

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The record coordinate is `NG_000007.3:70613`, since coding position 19 is 70595 plus 18. Codon 7 changes from `GAG` to `AAG`, glutamate to lysine.

The GRCh38 coordinate is `chr11:5227003`, one higher than the sickle cell base, not one lower. Because HBB runs along the opposite strand from the one GRCh38 prints, positions along the gene count down as chromosome positions count up. GRCh38 shows C there, the partner of the G on HBB's strand, and a carrier's reads show T, the partner of A. dbSNP lists this variant as rs33930165 at these coordinates.

An answer that gives `chr11:5227001` has missed the strand reversal, which is what part 3 tests.

</details>

### Question I2. A codon split by an intron

**Apply.** About 15 minutes.

The HBB coding sequence is `join(70595..70686,70817..71039,71890..72018)`.

1. Which three record positions hold codon 31? The record reads `AGG` across them. Which amino acid is that, and what number does it carry in the mature protein?
2. A laboratory reports a one-base deletion at `NG_000007.3:70750`. Does it change the reading frame? Explain what it could still affect.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The first coding stretch holds 70686 minus 70595 plus 1, which is 92 bases, so it ends after 30 whole codons and 2 spare bases. Codon 31 takes 70685 and 70686 from the first stretch and 70817 from the second. `AGG` is arginine, numbered 30 in the mature protein, because the removed methionine shifts every number down by one. Show the arithmetic, not only the positions.

Position 70750 lies inside the first intron, between 70686 and 70817. Intron bases are cut out before translation, so the reading frame is untouched. A complete answer adds that intron bases are not all irrelevant, because sequences near the exon edges direct splicing, and a change there can make the cell cut the message in the wrong place.

</details>

### Question I3. The same exon counted two ways

**Analyse.** About 15 minutes.

A collaborator's table counts from 0 and gives each range as a start that is not included and an end that is. The first coding stretch of HBB appears in it as start 70594, end 70686.

1. How many bases does that range hold, and does it describe the same bases as `70595..70686`?
2. A student reads the table as 1-based and inclusive and starts translating at 70594, where the record holds a C. Which codons and amino acids would the student write for the first two, and why is every later codon wrong too?

<details class="guidance" markdown="1">
<summary>Guidance</summary>

In the 0-based form the length is end minus start, 92 bases. In the record's form it is end minus start plus 1, also 92. The two ranges name the same bases.

Read as 1-based, the range starts one base early. The student's first codon is `CAT`, histidine, and the second is `GGT`, glycine, formed from the `G` of `ATG` and the first two bases of `GTG`. The protein no longer begins with methionine and every later codon is shifted by one base. Name the one-base shift as the reason, and name the extra base the student included.

</details>

### Design project I4. A clinically famous variant in a gene of 25 exons

**Design, partly guided.** About 60 minutes.

Factor V Leiden is the most common inherited risk factor for venous thrombosis, and it is one base in the F5 gene. The published clinical name is `c.1601G>A`. This project locates it on a real RefSeqGene record whose coding sequence is split across 25 exons, so the arithmetic the chapter teaches has to be done properly.

Download `NG_011806.1` into a new project, find the base, and work out what the change does. The record is 81,578 bases, so nothing here is slow.

What to work out, in whatever order suits you.

1. The record's length, and how many exons its F5 coding sequence has.
2. The record position of `c.1601`, and which exon holds it.
3. The codon that position falls in, which base of the codon it is, and the amino acid before and after the change.
4. The GRCh38 and GRCh37 coordinates of this base, and which base each build shows there.

Hand in a table of those four groups of facts, one screenshot showing the base in its exon, and a paragraph explaining why the two assembly coordinates differ and why the base letters differ too.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The record is 81,578 bases. Its F5 coding sequence runs across 25 exons, from `5146..5303` to `77073..77219`, totalling 6,675 coding bases. Walking that join, `c.1601` is record position 41721, in the coding exon at `41517..41731`. The codon spans 41720 to 41722 and reads `CGA`, arginine, and the variant is its second base, so the codon becomes `CAA`, glutamine.

The assembly rows are `chr1:169549811` on GRCh38, where the reference shows C, and `chr1:169519049` on GRCh37, where that build shows T. The two coordinates differ by 30,762. The letters differ because the two builds print opposite strands for this region, exactly as the chapter's HBB table shows for chromosome 11. dbSNP lists this as rs6025.

Two things distinguish a strong submission. It shows the walk along the CDS join rather than only the answer, and it notices that the published protein name R506Q does not match codon 534. The difference is the signal peptide and propeptide that the cell removes, the same kind of offset the chapter explains for the sickle cell codon.

</details>

## Advanced

For a reader who wants to reason about reference choice as a source of error. It assumes everything above, plus the patience to read a large record. The design project states a goal and leaves the route to you.

### Question A1. A mitochondrial file that matches nothing

**Analyse.** About 20 minutes.

A collaborator sends a VCF file of human mitochondrial variants. You attach it to your `NC_012920.1` reference bundle and nothing appears. The file's header contains this line.

```text
##contig=<ID=chrM,length=16571>
```

Name two separate problems this one line reveals. Explain why fixing only the first would leave you worse off than the failure you have now, and say what you would ask the collaborator for.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The first problem is the name. The file says `chrM` and the bundle's sequence is `NC_012920.1`, so nothing matches.

The second is the length. `NC_012920.1` is 16,569 bases, and this file was made against a 16,571-base mitochondrial sequence, the older reference `NC_001807.4`. The two sequences differ by insertions and deletions, so positions after the first difference are offset. Renaming `chrM` would make every variant appear, some of them at the wrong base, which is worse than a failure that announces itself.

The right request is calls made against `NC_012920.1`, or a conversion by a tool built for moving coordinates between references. Asking which reference the reads were mapped to is the first question.

</details>

### Question A2. Reads that cross the join of a circle

**Analyse.** About 20 minutes.

A 150-base read comes from human mitochondrial DNA. Its first 40 bases match positions 16530 to 16569 of `NC_012920.1`, and its last 110 bases match positions 1 to 110.

1. Predict how a program that treats the reference as a line records this read.
2. Across many such reads, predict how depth near positions 1 and 16569 compares with depth in the middle, and explain why.
3. You need to trust a variant call at position 60. Propose a check that does not depend on the join.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The read cannot be laid out as one continuous piece on a line, so it is recorded as two pieces, or as one piece with the other end left unmatched. Fewer reads are placed in full near both ends, so depth falls toward positions 1 and 16569 even though the molecule has no ends. A call near position 60 therefore rests on less evidence than one in the middle.

The check that shows real understanding is to make a copy of the reference that starts somewhere else, for example at position 8,000, so the old join sits mid-sequence, then map the same reads to it. The call should reappear at the shifted position with a fair depth. Collecting more reads does not help, because they meet the same join.

</details>

### Question A3. Two references, one base pair, four names

**Explain.** About 15 minutes.

A single base pair in HBB appears in the chapter as `NG_000007.3:70614` with an A, as `c.20`, as `chr11:5227002` with a T on GRCh38, and as `chr11:5248232` on GRCh37.

Explain to a colleague who has never met this why all four describe one base pair, and construct one concrete way a laboratory could report a wrong result by mixing two of these four names.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The explanation needs three ideas. A coordinate is a position along a chosen sequence, so a different chosen sequence gives a different number. A record written along the gene's own strand shows the complementary base to a chromosome written along the other strand, and A facing T is one base pair. And two assemblies of the same chromosome differ in earlier sequence, so later positions shift, here by 21,230.

A good failure story is specific. For example, a laboratory takes the coding position `c.20` from a clinical report, treats it as a record position, looks at `NG_000007.3:20`, finds nothing resembling the expected codon, and concludes the sample is normal. Or a pipeline uses GRCh37 positions against a GRCh38 reference and calls a variant 21,230 bases away from the gene, reporting no change in HBB.

The best answers note that only the mismatch that fails loudly is safe, and that the dangerous combinations are the ones that still produce a plausible-looking answer.

</details>

### Design project A4. An in-frame deletion whose name does not match its coordinates

**Design, open-ended.** About two hours.

The commonest variant causing cystic fibrosis is a three-base deletion in CFTR, published as F508del. Its name says residue 508, and the three bases that go are not the three bases of codon 508. This project works out what is really deleted and why the naming is what it is.

Build a project on the CFTR RefSeqGene record `NG_016465.4`, which is 257,188 bases and imports in about two seconds, and answer the question with evidence from the record itself rather than from a database summary.

Decide what to measure and what to hand in. A complete submission will convince a reader that you know which bases are deleted, which codons they belong to, what the protein loses, and why the reading frame survives.

<details class="guidance" markdown="1">
<summary>Guidance</summary>

The facts a complete submission establishes. The record is 257,188 bases and the CFTR coding sequence runs across 27 exons totalling 4,443 bases, which is 1,480 codons plus a stop. The published coding change is `c.1521_1523delCTT`. Walking the CDS join, `c.1519` to `c.1524` are record positions 98807 to 98812, and the bases at record positions 98804 to 98815 read `ATCATCTTTGGT`. Codon 506 is `ATC`, codon 507 is `ATC` at `c.1519` to `c.1521`, and codon 508 is `TTT` at `c.1522` to `c.1524`.

The finding is that the deleted bases `c.1521` to `c.1523` are the last base of codon 507 and the first two of codon 508. After the deletion the sequence reads `ATC` then `TGGT`, so isoleucine 507 survives, one phenylalanine is lost, and the frame is intact because three bases went.

A submission that assumes the deletion removes codon 508 reaches the same protein answer by luck with the wrong coordinates, and that is exactly the failure this project is built to expose.

Worth extra credit. Noticing that dbSNP writes rs113993960 as `TCTT` deleted to `T` at record position 98808, a four-base to one-base spelling of the same three-base deletion, and explaining why a deletion inside a repeated stretch has more than one valid spelling. Also noticing that the neighbouring variant I507del deletes an overlapping set of bases and carries a different name.

</details>

## For instructors

Each tier's conceptual questions are built on parameters that can be changed without changing what is tested, and each design project has verified substitutes of the same difficulty. Guidance on this page gives complete answers for the published numbers only, so changing a codon, a position or a record keeps a graded set honest. Every design project on this page has been solved in LGE and has an answer-key project and a write-up available to instructors.

---
title: Read Processing
chapter_id: 03-reads/08-read-processing
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq, 03-reads/03-quality-control]
estimated_reading_min: 23
task: Merge overlapping pairs, repair desynchronized mates, correct sequencing errors, reverse-complement reads, orient reads against a reference, and translate reads to protein.
tags: [reads, merge, repair, error-correct, reverse-complement, orient, translate, interleave]
tools: [bbmerge, repair.sh, tadpole, reformat, vsearch]
parameters_refs: [fastq.merge-overlapping-pairs, fastq.repair-paired-end-files, fastq.reverse-complement, fastq.translate, fastq.orient-reads, fastq.correct-sequencing-errors]
entry_points:
  - "Tools > Read Processing > Merge Overlapping Pairs…"
  - "Tools > Read Processing > Repair Paired-End Files…"
  - "Tools > Read Processing > Reverse Complement All Sequences…"
  - "Tools > Read Processing > Translate All Sequences…"
  - "Tools > Read Processing > Orient Reads…"
  - "Tools > Read Processing > Correct Sequencing Errors…"
  - "CLI: lungfish-cli fastq merge, repair, reverse-complement, translate, orient, error-correct"
  - "CLI: lungfish-cli fastq interleave, deinterleave"
shots:
  - id: read-processing-menu
    caption: "The Tools > Read Processing submenu open, showing its six operations."
  - id: merge-overlapping-pairs-pane
    caption: "The Merge Overlapping Pairs pane of the FASTQ/FASTA Operations window, with Strictness on Normal and Minimum Overlap reading 12 under Primary settings."
  - id: orient-reads-pane
    caption: "The Orient Reads pane, with the reference chosen in the Inputs section and the Word Length field, the Database Mask segments, and the Extra arguments field under Primary settings."
  - id: sidebar-after-merge
    caption: "The sidebar after a merge run, showing the new bundle under Analyses."
illustrations: []
glossary_refs: [fastq, fasta, read, mate, read-merging, insert-size, paired-end, interleaved-fastq, singleton-read, k-mer, phred-score, reverse-complement, reading-frame, codon, genetic-code, orient-reads, vsearch, amplicon, shotgun, provenance, inspector, required-setup-pack, library-prep, depth, de-novo-assembly, bbmerge, mapper, stderr]
features_refs: [fastq.read-processing]
fixtures_refs: [hg002-chr20, hg002-long-reads, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A [read](../../GLOSSARY.md#read) is the record a sequencer writes for one DNA fragment, its bases with a quality score for each base. [Phred scores](../../GLOSSARY.md#phred-score) are explained in [Quality Control for Reads](03-quality-control.md#q20-and-q30). The six operations under **Tools > Read Processing** in Lungfish Genome Explorer (LGE) rewrite or rearrange reads, and only Orient Reads drops reads as part of its job. [Trimming and Filtering Reads](04-trimming-and-filtering.md) does the opposite job and discards bases and reads that cannot be trusted. Read Processing changes the form of the reads instead, so that a later tool receives them the way it expects, for example as one file and not two, or all on one strand.

A [paired-end](../../GLOSSARY.md#paired-end) run gives two [mates](../../GLOSSARY.md#mate) per DNA fragment, one read from each end, as [Importing Sequencing Reads](01-importing-fastq.md) explains. Two of the operations work on those pairs. Merge Overlapping Pairs performs [read merging](../../GLOSSARY.md#read-merging), joining the two mates of a fragment into one longer sequence where they overlap in the middle, and keeps the pairs that do not overlap as pairs. Repair Paired-End Files puts mates back next to each other when an earlier program has pulled them out of step.

Two operations rewrite each read on its own. Reverse Complement All Sequences flips every read onto the opposite DNA strand, which means reversing the bases and swapping A with T and C with G. Translate All Sequences turns the bases into the protein they would encode. The last two use outside information. [Orient Reads](../../GLOSSARY.md#orient-reads) compares each read with a reference sequence, flips the reads that came off the other strand, and drops any read it cannot place. Correct Sequencing Errors compares every read with the rest of the data set to repair bases that look like instrument mistakes, changing bases in place so the read count stays the same.

<!-- SHOT: read-processing-menu -->

[FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces. Merge, Repair, and Correct Sequencing Errors read and write FASTQ. Reverse Complement and Orient Reads also accept [FASTA](../../GLOSSARY.md#fasta), the plain sequence format with no quality scores, and keep the format they are given. Translate always writes protein FASTA, which holds amino acid letters and no quality scores. No operation changes its input.

Two more utilities exist only on the command line. Interleave folds a separate R1 file and R2 file into one [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq), where the two mates of each fragment sit as neighboring records, and writes nothing when the files do not match. Deinterleave splits it back into two and needs `--unpaired` when the file holds reads that have no mate. Importing a paired sample already stores it interleaved, so the window never needs Interleave. Deinterleave matters in one case the window does not cover, keeping only the merged reads after a merge, which [Merging the overlapping pairs](#merging-the-overlapping-pairs) shows as a command for Terminal, the macOS text window.

So reach for this chapter when a later tool refuses your reads because of their form, and reach for the trimming chapter when it refuses them because of their quality.

## Why you would do this

The example in this chapter is a slice of human chromosome 20 from HG002, a human genome from the Genome in a Bottle project whose true sequence is already known. The slice covers 500,001 bases, under one percent of the chromosome. Its two files hold 45,574 read pairs, which is 91,148 reads counted one mate at a time, most of them the full 250 bases long.

That combination is the case merging was built for. [Library preparation](../../GLOSSARY.md#library-prep), the bench work that turns extracted DNA into something a sequencer can read, breaks the DNA at random into fragments a few hundred bases long. The sequencer then reads 250 bases inward from each end of a fragment, so the two mates point toward each other. The [insert size](../../GLOSSARY.md#insert-size) is the full length of the original fragment. When the insert is shorter than 500 bases, two 250-base reads must cover some of the same bases in the middle. On this fixture the average insert is about 371 bases, so the two reads together hold 2 × 250 = 500 bases of sequence from a fragment only 371 bases long. The surplus, 500 − 371 = 129 bases in the middle, is read twice.

Merge Overlapping Pairs serves two needs. The first is learning how long a library's fragments were. Every pair that joins reports the length of its fragment, so a merge run estimates the insert size before any mapping. The second is one longer read per fragment for a step that wants it, such as [de novo assembly](../../GLOSSARY.md#de-novo-assembly), where a program rebuilds a genome from overlapping reads without a reference. The middle of the joined sequence is also more accurate, because every base in the overlap was measured twice and the merger keeps the better-supported call. Pairs that do not join stay in the result as pairs, so a merge loses no read. It is still not a step for reads headed to a [mapper](../../GLOSSARY.md#mapper), the program that places each read on a reference, because a mapper uses the two mates together to place each one. [Choosing a tool](#choosing-a-tool) gives the rule.

## Choosing a tool

Check whether your reads are paired and whether they are already merged, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) describes. Merging is the one job in this chapter that LGE does with two programs, and the step that comes next decides whether to merge at all. Error correction always runs Tadpole and orientation always runs [vsearch](../../GLOSSARY.md#vsearch), so neither has a choice to make.

Merge when the next step is a de novo assembly, or when you only want the insert sizes. Do not merge when the next step is mapping for variant calling, because a mapper places each read with the help of its mate and a merged read has no mate left. A 2 × 250 Illumina bundle from a human sample that is headed for variant calling therefore stays unmerged. If you are unsure, leave the pairs alone. Merging never changes the input bundle, so you can run it later.

**BBMerge** runs behind Merge Overlapping Pairs and joins a pair only when it trusts the overlap, as the procedure below describes.

**fastp** merges pairs inside three import recipes and matters only for viral, wastewater, or amplicon libraries. A recipe is a set of read-processing steps that LGE runs during import, as [Importing Sequencing Reads](01-importing-fastq.md#processing-recipes) explains, so skip this paragraph if you import without one. The VSP2 target enrichment and Wastewater metagenomics recipes require 15 shared bases and keep the pairs that did not merge beside the merged reads, which only some mappers keep paired, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#choosing-a-tool) explains. The Illumina Amplicon Merge recipe requires 20 shared bases and keeps only the merged reads.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| BBMerge, Merge Overlapping Pairs | Joining overlapping mates in a bundle you already imported | You want insert sizes, or one longer read per fragment for assembly | The reads will be mapped for variant calling, which works from the pairs |
| fastp merge, VSP2 or Wastewater recipe | Short-insert viral and wastewater libraries at import | You import those libraries with the matching recipe | You want to choose the merge settings yourself |
| fastp merge, Illumina Amplicon Merge recipe | Amplicons read end to end for exact-match genotyping | You import MiSeq MHC amplicon pairs | Losing the pairs that did not merge would cost you data |
| No merging | Mapping pairs directly | Shotgun human or macaque reads headed for variant calling | A later step needs one read per fragment |

### Merging for MHC amplicon genotyping

This subsection is only for MiSeq MHC amplicon data, where MHC names the major histocompatibility complex, a family of immune genes. Skip it for shotgun reads such as the HG002 fixture. Import MiSeq MHC amplicon pairs with the Illumina Amplicon Merge recipe, which merges each pair so a read can span the 244-base DRB amplicons, longer than either mate. The genotyping workflow can merge unmerged pairs itself as a fallback, with different read counts, as [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#choosing-a-tool) explains. Merge Overlapping Pairs is not part of this route.

For the variant-calling route the rest of this manual follows with the same reads, map the imported pairs unmerged and untrimmed. BBTools, BBMerge, fastp, and vsearch are cited in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Reads demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` bundle, the `HG002.chrM.ont` bundle, and the `NC_012920.1` reference. The demo bundle holds the same reads as the practice files, so you can follow every step on it before you try your own bundle. To import the files yourself, follow the rest of this section.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The Orient Reads example uses two more files. Download `HG002.chrM.ont.fastq.gz`, HG002 mitochondrial reads from an Oxford Nanopore instrument, from [the hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads). Download `NC_012920.1.fasta`, the human mitochondrial reference sequence, from [the human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/human-mito). The version numbers in these addresses are file locations only and need not match your copy of LGE.

Import the two chromosome 20 files as one sample by following [Importing Sequencing Reads](01-importing-fastq.md), so a single `HG002.chr20.10.0-10.5Mb` bundle appears in the sidebar. The import stores the pair as one interleaved file, which is the form Merge Overlapping Pairs and Repair Paired-End Files expect. [Quality Control for Reads](03-quality-control.md) shows where to find the read counts that check each result below.

BBMerge, repair.sh, and Tadpole, three programs from the BBTools suite, and vsearch arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. To check that it is installed, open **Tools > Plugin Manager…** (Cmd-Shift-B), click the **Packs** tab, and look in the **Required Setup** section, where each tool of the pack reads **Ready**, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) describes. Reverse Complement and Translate are done by LGE itself. The BBTools figures in this chapter come from BBTools 40.02, the version LGE pins.

## Procedure

Every operation follows the same moves. Select the bundle in the sidebar, choose the operation from **Tools > Read Processing**, set the fields on the pane that opens, and click **Run**. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, and one window titled FASTQ/FASTA Operations serves all six operations. The readiness line at the foot of the window, beside **Run**, says what the run still needs before it can start.

### Merging the overlapping pairs

BBMerge takes each pair and slides the second mate, flipped onto the first mate's strand, along the first until the shared bases line up. When it finds an overlap it trusts, it writes one sequence that spans the whole fragment, and the length of that sequence is the insert size. When it finds none, it keeps both mates. [Reading the results](#reading-the-results) works through the average insert it estimates from the joined pairs.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar.
2. Choose **Tools > Read Processing > Merge Overlapping Pairs…**.
3. Leave **Strictness** on Normal and **Minimum Overlap** at 12, both under Primary settings. These are the defaults, and they produced the numbers in this chapter. Minimum Overlap is the fewest bases the two mates must share before they may join, and 12 is low enough to catch long fragments whose mates barely reach each other.
4. Leave **Output Strategy** on Per Input.
5. Click **Run**.

<!-- SHOT: merge-overlapping-pairs-pane -->

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. This run writes a bundle named `HG002.chr20.10.0-10.5Mb-pairedEndMerge`, the input's name with the operation added. The other five operations add `-pairedEndRepair`, `-errorCorrection`, `-reverseComplement`, `-translate`, and `-orient`.

<!-- SHOT: sidebar-after-merge -->

The result holds two kinds of read in one bundle. First come the merged reads, one for each joined pair, each carrying the quality scores BBMerge computed where the mates overlapped. After them come the pairs that did not join, with their own names and measured quality scores. A step you run on this bundle next works on both kinds. The window has no item for keeping only the merged reads. To get them, split the result in Terminal with `lungfish-cli fastq deinterleave`, which writes the reads that have no mate, the merged ones, to its `--unpaired` file. If you never open Terminal, use the bundle as it is. [Reading the results](#reading-the-results) shows what the merge does to the read count.

### Repairing paired-end files

Repair is a rescue step, so run it only when a paired file is broken. Every operation in the window except Orient Reads and Merge Overlapping Pairs keeps pairs together, as [Which operations keep pairs](01-importing-fastq.md#which-operations-keep-pairs) sets out, so a broken file usually comes from a program outside LGE, or from a command-line filter that treated paired reads as single reads. LGE's own import of two separate files refuses a pair that is out of step, with a message that begins "Paired FASTQ mates are out of step at record". In a healthy interleaved file the records run first mate, second mate, first mate, second mate, and each neighboring pair belongs to one fragment. A broken file can fail in two ways. One mate can be missing, so every record after the gap sits beside the wrong partner. Or all the mates can be present but in a different order, so neighbors are strangers.

To tell whether your bundle is broken, click it to open the FASTQ viewport and open its **Reads** tab, as [The FASTQ viewport's Reads tab](03-quality-control.md#the-fastq-viewports-reads-tab) describes. In a healthy file rows 1 and 2 show the same **Read ID**, and so do rows 3 and 4, though mates named with a /1 and /2 ending may differ in only that ending. Scroll well down the table too, because a gap far into the file leaves the top rows looking healthy. The first neighbors with unrelated names mark where the file slipped. The read count on the summary cards, which [Quality Control for Reads](03-quality-control.md#reading-the-results) explains, adds a clue. An odd count points to a missing mate, but an even count does not clear the file.

To repair, select the bundle, choose **Tools > Read Processing > Repair Paired-End Files…**, and click **Run**. The pane has no settings, only the Inputs and Output sections. repair.sh matches mates by read name, writes every complete pair first, and puts reads whose partner is missing at the end. BBTools' help for repair.sh says its default mode, which LGE uses, "fixes arbitrarily corrupted paired reads by using read names", so Repair should also put back mates that are all present but shuffled, at the cost of more memory on a large file. After the run, check the result's **Reads** tab the same way. Its read count equals the input's, because repair keeps the reads it cannot pair.

### Correcting sequencing errors

A [k-mer](../../GLOSSARY.md#k-mer) is a substring of exactly k bases, the unit many read tools match on, as [Three ways to match a read](../06-classification/01-what-is-classification.md#three-ways-to-match-a-read) shows. Tadpole counts every k-mer across the whole data set. A base that turns a k-mer seen hundreds of times into one seen only once is probably an instrument mistake, and Tadpole replaces it with the base the common k-mer carries.

Select the bundle, choose **Tools > Read Processing > Correct Sequencing Errors…**, leave **K-mer Size** at 50, and click **Run**. The default of 50 bases suits reads of 100 bases and longer, such as this fixture's 250-base reads. The output holds the same number of reads as the input, with some bases changed.

### Flipping and translating

Reverse Complement and Translate have nothing to set, so their panes show only the Inputs and Output sections. Select the bundle, choose **Tools > Read Processing > Reverse Complement All Sequences…** or **Tools > Read Processing > Translate All Sequences…**, and click **Run**. Translate always reads each sequence from its first base.

That gives a meaningful protein only when the first base of every read is the first base of a codon on the coding strand. Reads that start at a known point in a gene, such as amplicons whose primer begins at a codon, can meet that condition. Shotgun reads cannot, because each starts at a random base of either strand, so translating the HG002 reads shows what the output looks like and says nothing about biology.

### Orienting reads

Orient Reads runs on the mitochondrial files, because it is built for long reads from an Oxford Nanopore instrument, which can come off either strand. Do not run it on Illumina pairs such as the HG002 chr20 bundle. Their orientation is already known, since the two mates of a pair face each other by design, and Orient treats every read alone, so it can flip a mate and drops any mate it cannot place. The 12S matcher in [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) reads one strand only, so orient 12S amplicon reads against a 12S reference before matching them. Import `HG002.chrM.ont.fastq.gz` as a read bundle by following [Importing Sequencing Reads](01-importing-fastq.md). Import `NC_012920.1.fasta` as a reference with a different path from the one for reads. Choose **File > Import Center…** (Cmd-Shift-I), click the **Reference Sequences** tab, and drop the file on the **Reference Sequences** card, as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) shows.

1. Click the mitochondrial read bundle in the sidebar.
2. Choose **Tools > Read Processing > Orient Reads…**.
3. In the Inputs section, use the reference picker to choose `NC_012920.1` from the references in your project. Until you do, **Run** stays disabled and the readiness line reads "Select a reference sequence to continue."
4. Leave **Word Length** at 12 and **Database Mask** on dust, both under Primary settings. Word Length is how many bases a read and the reference must share exactly, and dust hides stretches of repeated bases from the matching.
5. Click **Run**.

<!-- SHOT: orient-reads-pane -->

Orient Reads keeps only the reads it could place on a strand and drops the rest, because LGE never asks vsearch to keep the unplaced ones. Against a reference that is one long sequence, such as the 500,001-base chromosome 20 slice, vsearch places no reads and the run still finishes with an empty bundle, a known defect listed in [Known defects in this release](../appendices/troubleshooting.md#defect-orient-long-reference). That entry names no length limit, so an empty bundle after a run is the test. The mitochondrial reference here is 16,569 bases long.

## Settings

Repair Paired-End Files, Reverse Complement, and Translate have no settings of their own, so their panes hold only the Inputs and Output sections. Every pane in this chapter carries Output Strategy. Orient Reads is the only pane with an Extra arguments field.

**Output Strategy.** Chooses how the results of several selected bundles are filed, offering Per Input and Grouped Result. The default is Per Input, which files each bundle's result as a bundle of its own and is right for most runs. It matters only when you select more than one bundle. Choose Grouped Result to keep a batch together in one folder, where each selected bundle still runs its own command and gets a sub-folder named for it, with `-2` added when two bundles share a name. This setting has no command-line flag.

**Strictness.** Chooses how much evidence BBMerge needs before it joins a pair, offering Normal and Strict, where Strict turns down overlaps that look marginal. The default is Normal, which merges more pairs and is the right start when you have no reason to doubt the joins. You cannot test the joins before mapping, so run on Normal first and switch to Strict only when mapped merged reads disagree with the reference in their joined middle, accepting that fewer pairs will merge. On the command line this is `--strict`.

**Minimum Overlap.** Sets the fewest bases the two mates must share before they may join, since a short overlap can occur by chance between unrelated sequence. The default is 12 bases, low enough to catch long fragments whose mates barely reach each other. Raise it when joined insert sizes in the stderr report fall far outside the fragment sizes your library preparation aimed for, and lower it only to rescue pairs that barely overlap. No cited value says how far, so raise it a little at a time. On the command line this is `--min-overlap`.

**K-mer Size.** Sets the k-mer length Tadpole counts across the data set to tell a real base from a sequencing error. The default is 50 bases, which suits reads of 100 bases and longer, such as this fixture's 250-base reads. Lower it for short reads or shallow data, because a k-mer longer than the read cannot be counted at all. On the command line this is `--kmer`.

The dialog accepts any positive whole number here, and otherwise the readiness line reads "Enter a positive k-mer size." The usable range is 1 to 62 bases. A larger value starts the run, and `lungfish-cli` then stops it with "K-mer size must be between 1 and 62". A failed run turns its row red in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it.

**Word Length.** Sets the length of the exact matching word vsearch uses to decide which strand a read came from, where longer words are more specific and slower. The default is 12 bases, short enough to find matches in nanopore reads despite their higher error rate. Shorten it when many reads come back unplaced, and lengthen it when reads land on the wrong strand, staying within the 3 to 15 bases that vsearch accepts. No cited step size exists, so move a base or two at a time. On the command line this is `--word-length`.

**Database Mask.** Chooses whether low-complexity stretches of the reference, such as long runs of one base, are hidden from matching, offering dust and none, where dust names the masking method. The default is dust, because a read that matches only a run of adenines says nothing about its strand. Choose none when your reference is short and masking hides the only usable match. On the command line this is `--db-mask`.

**Extra arguments.** Passes text straight to vsearch without LGE checking what it means. The default is empty, which is right for almost every run, so leave it blank if you are unsure. Use it only for a vsearch option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

The Translate pane offers no control for the [reading frame](../../GLOSSARY.md#reading-frame), which is where the reading of bases in threes begins. A sequence can be split into three-base [codons](../../GLOSSARY.md#codon) from its first base, its second, or its third, and each split gives a different protein. The dialog always uses frame 1, which starts at the first base, and the standard [genetic code](../../GLOSSARY.md#genetic-code). If your reads are in another frame, translate them on the command line instead.

## Reading the results

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains, and that record keeps the report each tool printed. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Select the result bundle, scroll the Inspector to its Provenance section, and click the row under **Lineage** that holds the tool's step. Click the step to open its rows, which run from **Command**, **Inputs**, and **Outputs** through **Exit Status** and **Wall Time** to the **stderr** row at the end. The row is named for [standard error](../../GLOSSARY.md#stderr), the channel where command-line programs print their messages. The merge rate and the other counts below sit there as text the tool printed.

### The merge report

On this fixture BBMerge saw 45,574 read pairs and joined 32,031 of them, which it reports as 70.283 percent. The 13,543 pairs it could not join appear on a line labeled "No Solution", the tool's wording for finding no overlap it believed in. Its estimate of the average insert was 371.5 bases, with a standard deviation of 63.9 bases and joined inserts from 64 to 482 bases. The standard deviation is a measure of spread, and here it is about a sixth of the average. A much wider spread would mean fragments of very mixed length.

The numbers explain each other. Many of the pairs that failed are probably the long tail of the distribution, fragments near or above 500 bases whose mates never met. A pair can also fail for another reason, such as an overlap too short to trust.

Merging keeps every read, and the read count shows it. Reads out equal joined pairs plus two times the unjoined pairs, so you can reuse the formula on your own counts. The 32,031 joined pairs became one merged read each. The 13,543 unjoined pairs kept both mates, contributing 27,086 reads. Together the result holds 59,117 reads, the merged reads first and the pairs after them, and none was thrown away.

A read longer than 250 bases, the longest input read, can only be a joined pair. The **Length** column of the **Reads** tab shows each read's length, as [Quality Control for Reads](03-quality-control.md#the-fastq-viewports-reads-tab) describes.

### The other reports

Tadpole reports errors and reads separately, and the two kinds of number should not be added. On this fixture it read 91,148 reads and wrote 91,148 reads. It detected 122,406 errors and corrected 42,033 of them. The gap is Tadpole declining to change a base when the evidence for a replacement was thin. By read, it found at least one suspect base in 30,929 reads, 33.93 percent of the data set. It fully corrected 24,219 of those reads, partly corrected 935 reads, and left the other 5,775 reads alone. No range is cited for a healthy share of corrected errors, so compare the figures only with a run on the same kind of data.

Repair reports the same way. The next numbers come from a copy of this fixture with 228 mates removed on purpose, which this chapter gives no command to make, so they only show what a repair report looks like. On that copy repair.sh read 90,920 records and wrote 90,920 records, of which 90,692 reads were paired and 228 reads were [singletons](../../GLOSSARY.md#singleton-read), reads whose partner no longer exists. Both groups go into the one output.

Orient Reads reports the split between strands. Of the 950 mitochondrial reads that went in, vsearch placed 439 reads on the forward strand and 488 reads on the reverse strand, which it flipped. That is 927 reads oriented, 97.58 percent, with 23 reads left unplaced. The output holds the 927 placed reads.

Reverse Complement changes every record and drops none. Reverse-complementing this fixture's R1 file gave 45,574 records from 45,574 reads, with each quality string reversed alongside its sequence, so every base keeps the score it was measured with. Translating the same file gave 45,574 protein sequences, most of them 83 amino acids long, which is 250 bases divided by three with one base left over. Shorter reads give shorter proteins, down to 16 amino acids here. Translate skips only a read too short to hold one codon, and this fixture has none.

Translate's output opens as a sequence bundle rather than a read bundle, because it holds protein FASTA. Click it in the sidebar to open it in the sequence viewport. Each protein keeps its read's name with the frame added, then the genetic code and the length, as in `_frame+1 [Standard] [83 aa]`. When the two mates of a pair share one name, as they do in the interleaved HG002 bundle, the first mate's protein adds `.1` right after the name and the second mate's adds `.2`. Other reads keep their names.

To judge whether a translation is noise, look for `*` in the protein text, the letter for a stop codon. The standard genetic code has 3 stop codons among its 64, so as a simplification that assumes the four bases are equally common, random sequence puts a `*` about once every 21 codons and holds about four in an 83-amino-acid protein. A real coding frame runs long with none. For reads whose frame you do not know, translate with `--frame` 1, 2, and 3 on the command line, and the frame with the fewest `*` is often the coding one.

## What good looks like

Check the merge rate first. It is the percentage of read pairs BBMerge joined, printed on the stderr row that [Reading the results](#reading-the-results) shows how to open. A pair can join only when its fragment is shorter than the two reads laid end to end, 500 bases here, so the rate cannot exceed the share of your fragments that short. Compare it with the fragment-size trace from your own library preparation. A rate near 70 percent, as here, means the insert sizes and the read length suit each other. No cited cutoff separates a low rate from a good one. A low rate means the inserts are mostly longer than the reads can span, so carry the pairs forward as they are, since mappers and assemblers accept pairs directly. On [shotgun](../../GLOSSARY.md#shotgun) data, where the DNA was broken at random, a rate close to 100 percent often means unusually short fragments. On [amplicon](../../GLOSSARY.md#amplicon) data, where every fragment is a designed PCR product of fixed length, it is normal.

Check the insert estimate next. The average BBMerge prints describes only the pairs that joined, so it leaves out every fragment too long to overlap. The library's true average is higher, and the lower the merge rate, the larger the gap.

Check the read count on every operation. Repair, Reverse Complement, and Correct Sequencing Errors write one record for every read they read, and Translate does the same for every read that holds at least one codon. Merge follows the formula in the merge report, and 2 times 32,031 plus 27,086 gives back 91,148 reads here. A shortfall means something failed. Orient Reads is the one operation here that discards reads on purpose, so compare its output count with its input count after every run, as the 927 of 950 reads above shows. No cited cutoff says how many lost reads is too many, so decide from what your next step needs. To lose fewer, shorten the word length and run it again.

Finally, check that error correction was worth running. It relies on seeing each true base many times and each error once, so it needs depth. [Depth](../../GLOSSARY.md#depth) is the number of reads covering one position. With only a handful of reads over each position, Tadpole may erase real variants, so skip the operation rather than tune it. Before mapping, estimate the depth as the total bases in the reads divided by the length of the sequence they cover, a simplification that assumes the reads are spread evenly. After mapping, the Inspector shows the measured Mean Depth of the alignment, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#reading-the-results) explains. No cited cutoff says how deep is deep enough, so compare your figure with this fixture's measured mean depth of 44.7x, which is comfortably enough.

## On the command line

This section is optional. Every step above works in the window, except keeping only the merged reads and translating in a frame other than 1, so skip it if you never open Terminal. To use it, open Terminal and paste the block, after reading [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), which explains Terminal, variables such as `PROJECT`, and `$HOME`. [Read processing](../appendices/cli-reference.md#read-processing) in the CLI Reference lists every flag of these commands. To see any run from this chapter as a command, right-click its row and choose **Copy CLI Command**, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes.

The block reproduces the procedure on the Human Reads demo project. Merge and repair need one interleaved file, which the bundle already holds, and the two mate files under `Practice Data` show the interleave step. Each command writes its output file where you name it.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Reads.lungfish"
READS="$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz"
PRACTICE="$PROJECT/Practice Data/hg002-chr20"

lungfish-cli fastq interleave \
  --in1 "$PRACTICE/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  --in2 "$PRACTICE/HG002.chr20.10.0-10.5Mb_R2.fastq.gz" \
  --output "$HOME/Desktop/HG002.interleaved.fastq"

lungfish-cli fastq merge "$READS" \
  --min-overlap 12 --output "$HOME/Desktop/HG002.merged.fastq"

lungfish-cli fastq repair "$READS" \
  --output "$HOME/Desktop/HG002.repaired.fastq"

lungfish-cli fastq error-correct "$READS" \
  --kmer 50 --output "$HOME/Desktop/HG002.corrected.fastq"

lungfish-cli fastq reverse-complement "$PRACTICE/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  --output "$HOME/Desktop/HG002.R1.rc.fastq"

lungfish-cli fastq translate "$PRACTICE/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  --frame 1 --output "$HOME/Desktop/HG002.R1.protein.fasta"

lungfish-cli fastq orient "$PROJECT/Imports/HG002.chrM.ont.lungfishfastq/HG002.chrM.ont.fastq.gz" \
  --reference "$PROJECT/Reference Sequences/NC_012920.1.lungfishref/genome/sequence.fa.gz" \
  --word-length 12 --db-mask dust --output "$HOME/Desktop/HG002.chrM.oriented.fastq"

lungfish-cli fastq deinterleave "$HOME/Desktop/HG002.interleaved.fastq" \
  --out1 "$HOME/Desktop/HG002.R1.fastq" --out2 "$HOME/Desktop/HG002.R2.fastq"
```

`fastq merge` writes what the window writes, the merged reads followed by the pairs that did not merge, 59,117 reads on this fixture. The window always translates in frame 1, while `fastq translate` accepts `--frame` from 1 to 6, where 4 to 6 are the three frames of the [reverse complement](../../GLOSSARY.md#reverse-complement), and `--table` for another genetic code, so other frames and codes are a command-line task.

Of the commands in this block, only `fastq merge` accepts `--compress`, which writes its output gzip-compressed. The others write plain text and stop with an error when given `--compress`, so leave it out of any script that runs them. `fastq interleave` writes a quality of 0 for every `N` base and raises a quality of 0 or 1 on any other base to 2, a known defect listed in [Known defects in this release](../appendices/troubleshooting.md#defect-interleave-q2). The bases themselves are untouched, so treat quality scores of 0 to 2 in that output as approximate.

For the curious only, `fastq merge` also has a `--count-duplicates` option, which the window never passes. It collapses identical sequences into one record each, named `u<number>;size=<reads>`, writes Q40 placeholder scores rather than measured ones, and leaves the unmerged mates without their pairing, so use it only to count distinct sequences and never before mapping.

## Next

This is the last chapter of the Reads part, which followed [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation) from import to clean reads. Continue to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md), the first chapter of Alignments, where the imported `HG002.chr20.10.0-10.5Mb` pairs are placed on the human reference so that variants can be called from them.

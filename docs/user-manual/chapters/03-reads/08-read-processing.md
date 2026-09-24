---
title: Read Processing
chapter_id: 03-reads/08-read-processing
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq, 03-reads/03-quality-control]
estimated_reading_min: 20
task: Merge overlapping pairs, repair desynchronized mates, correct sequencing errors, reverse-complement reads, orient reads against a reference, and translate reads to protein.
tags: [reads, merge, repair, error-correct, reverse-complement, orient, translate, interleave]
tools: [bbmerge, repair.sh, tadpole, reformat, vsearch]
parameters_refs: [fastq.merge-overlapping-pairs, fastq.repair-paired-end-files, fastq.reverse-complement, fastq.translate, fastq.orient-reads, fastq.correct-sequencing-errors]
entry_points:
  - "Tools > Read Processing > Merge Overlapping Pairs..."
  - "Tools > Read Processing > Repair Paired-End Files..."
  - "Tools > Read Processing > Reverse Complement..."
  - "Tools > Read Processing > Translate..."
  - "Tools > Read Processing > Orient Reads..."
  - "Tools > Read Processing > Correct Sequencing Errors..."
  - "CLI: lungfish-cli fastq merge, repair, reverse-complement, translate, orient, error-correct"
  - "CLI: lungfish-cli fastq interleave, deinterleave"
shots:
  - id: read-processing-menu
    caption: "The Tools > Read Processing submenu open, showing its six operations."
  - id: merge-overlapping-pairs-pane
    caption: "The Merge Overlapping Pairs pane of the FASTQ/FASTA Operations dialog, with the Strictness segments set to Normal and the Minimum Overlap field reading 12."
  - id: orient-reads-pane
    caption: "The Orient Reads pane, showing the Word Length field, the Database Mask segments, the Extra arguments field, and the reference chosen in the Inputs section."
  - id: sidebar-after-merge
    caption: "The sidebar after a merge run, showing the new bundle under Analyses."
illustrations: []
glossary_refs: [fastq, read, read-merging, insert-size, paired-end, interleaved-fastq, singleton-read, k-mer, phred-score, reverse-complement, reading-frame, codon, orient-reads, amplicon, shotgun, provenance, checksum, inspector, required-setup-pack, library-prep, depth, coverage-breadth, de-novo-assembly]
features_refs: [fastq.read-processing]
fixtures_refs: [hg002-chr20, hg002-long-reads, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A [read](../../GLOSSARY.md#read) is one stretch of DNA reported by a sequencing instrument, stored as a string of bases with a quality score for each base. [Phred scores](../../GLOSSARY.md#phred-score) are explained in [Quality Control for Reads](03-quality-control.md#q20-and-q30). The six operations under **Tools > Read Processing** in Lungfish Genome Explorer (LGE) rewrite or rearrange reads, and all but one of them keep every read. [Trimming and Filtering](04-trimming-and-filtering.md) does the opposite job and discards bases and reads that cannot be trusted. Read Processing changes the form of the reads instead, so that a later tool receives the reads the way it expects them.

A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. Two of the operations work on those pairs. Merge Overlapping Pairs performs [read merging](../../GLOSSARY.md#read-merging), joining the two mates of a fragment into one longer sequence where they overlap in the middle. Repair Paired-End Files puts mates back next to each other when an earlier program has pulled them out of step.

Two operations rewrite each read on its own. Reverse Complement flips every read onto the opposite DNA strand, which means reversing the bases and swapping A with T and C with G. Translate turns the bases into the protein they would encode. The last two use outside information. [Orient Reads](../../GLOSSARY.md#orient-reads) compares each read with a reference sequence, flips the reads that came off the other strand, and drops any read it cannot place. Correct Sequencing Errors compares every read with the rest of the data set to repair bases that look like instrument mistakes.

<!-- SHOT: read-processing-menu -->

[FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces. Five of the six operations write a new FASTQ file. Translate writes protein FASTA instead, the plain sequence format with no quality scores, here holding amino acid letters, because one amino acid comes from three bases and no single quality score describes three measurements honestly. No operation changes its input.

Two more utilities exist only on the command line. Interleave folds a separate R1 file and R2 file into one [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq), where the two mates of each fragment sit as neighbouring records, and Deinterleave splits such a file back into two. Importing a paired sample already stores it interleaved, so you never need either one inside the window.

So reach for this chapter when a later tool refuses your reads because of their form, and reach for the trimming chapter when it refuses them because of their quality.

## Why you would do this

The worked example is a slice of human chromosome 20 from HG002, a human genome from the Genome in a Bottle project whose true sequence is already known. The slice covers 500,001 bases, under one percent of the chromosome. Its two files hold 45,574 read pairs, which is 91,148 reads counted one mate at a time, most of them the full 250 bases long.

That combination is the case merging was invented for. [Library preparation](../../GLOSSARY.md#library-prep), the bench work that turns extracted DNA into something a sequencer can read, breaks the DNA at random into fragments a few hundred bases long. The sequencer then reads 250 bases inward from each end of a fragment, so the two mates point toward each other. The [insert size](../../GLOSSARY.md#insert-size) is the full length of the original fragment. When the insert is shorter than 500 bases, two 250-base reads must cover some of the same bases in the middle. On this fixture the average insert is about 371 bases, so the two reads together span 500 bases of a 371-base fragment and about 129 bases in the middle are read twice.

Merging buys two things. The joined sequence is longer than either mate, which helps any step that needs length, such as [de novo assembly](../../GLOSSARY.md#de-novo-assembly), where a program rebuilds a genome from overlapping reads without a reference. The middle of the joined sequence is also more accurate, because every base in the overlap was measured twice and the merger keeps the better-supported call.

The other five operations answer narrower questions. Correct Sequencing Errors is worth running before an assembly on deep data. Repair rescues a paired file that an earlier filter left out of step. Reverse Complement, Orient Reads, and Translate exist because a later tool sometimes cares about strand or about protein, and a read as sequenced makes no promise about either.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The Orient Reads example uses two more files. Download `HG002.chrM.ont.fastq.gz`, which holds HG002 mitochondrial reads from an Oxford Nanopore instrument, from [the hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads). Download `NC_012920.1.fasta`, the human mitochondrial reference sequence, from [the human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito).

Import the two chromosome 20 files as one sample by following [Importing Sequencing Reads](01-importing-fastq.md), so a single `HG002.chr20.10.0-10.5Mb` bundle appears in the sidebar. The import stores the pair as one interleaved file, which is the form Merge Overlapping Pairs and Repair Paired-End Files expect. Reading [Quality Control for Reads](03-quality-control.md) first helps, because the read counts it teaches you to find are how you check each result below.

bbmerge, repair.sh, and Tadpole, three programs from the BBTools suite, and vsearch arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. Reverse Complement and Translate are done by LGE itself. The BBTools figures in this chapter come from BBTools 40.02, the version LGE pins.

## Procedure

Every operation follows the same moves. Select the bundle in the sidebar, choose the operation from **Tools > Read Processing**, set the fields on the pane that opens, and click Run. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, and one window titled FASTQ/FASTA Operations serves all six operations. LGE runs each operation through its bundled `lungfish-cli` program and saves the result as a full bundle holding its own copy of the reads.

### Merging the overlapping pairs

bbmerge takes each pair and slides the second mate, flipped onto the first mate's strand, along the first until the shared bases line up. When it finds an overlap it trusts, it writes one sequence that spans the whole fragment, and the length of that sequence is the fragment's insert size. When it finds none, it keeps both mates as they were. The insert sizes of the joined pairs are how bbmerge estimates the library's average insert, which [Reading the results](#reading-the-results) works through.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar.
2. Choose **Tools > Read Processing > Merge Overlapping Pairs...**.
3. Leave **Strictness** on Normal and **Minimum Overlap** at 12. These are the defaults, and they produced the numbers in this chapter.
4. Click Run.

<!-- SHOT: merge-overlapping-pairs-pane -->

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. This run writes a bundle named `HG002.chr20.10.0-10.5Mb-pairedEndMerge`, the input's name with the operation added. The other five operations add `-pairedEndRepair`, `-errorCorrection`, `-reverseComplement`, `-translate`, and `-orient`.

<!-- SHOT: sidebar-after-merge -->

A merge run from this dialog does one more thing the pane mentions only in its Advanced Settings note. It collapses identical sequences in the output into one record and writes the number of reads behind that record into the record's name, as `size=` followed by the count. [Reading the results](#reading-the-results) shows what that does to the record count.

### Repairing a paired file whose mates fell out of step

Repair is a rescue step, so run it only when a paired file is broken. In a healthy interleaved file the records run first mate, second mate, first mate, second mate, and each neighbouring pair belongs to one fragment. In a broken file one mate is missing, and every record after the gap sits beside the wrong partner. The usual symptoms are a later tool complaining that mates do not match, or an odd-numbered read count in a file that should hold pairs. Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. The read count is on those cards.

To repair, select the bundle, choose **Tools > Read Processing > Repair Paired-End Files...**, and click Run. The pane says "No additional settings are required for paired-end repair." repair.sh matches mates by read name, writes every complete pair first, and puts reads whose partner is missing at the end.

### Correcting sequencing errors

A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases, and [Running Kraken 2](../06-classification/02-running-kraken2.md#what-it-is) shows how tools match on them. Tadpole counts every k-mer across the whole data set. A base that turns a k-mer seen hundreds of times into one seen only once is probably an instrument mistake, and Tadpole replaces it with the base the common k-mer carries.

Select the bundle, choose **Tools > Read Processing > Correct Sequencing Errors...**, leave **K-mer Size** at 50, and click Run. The output holds the same number of reads as the input, with some bases changed.

### Flipping and translating

Reverse Complement and Translate have nothing to set. Select the bundle, choose **Tools > Read Processing > Reverse Complement...** or **Tools > Read Processing > Translate...**, and click Run. Translate always reads each sequence from its first base, and its pane says "Frame 1 translation is used for this operation."

### Orienting long reads against a reference

Orient Reads runs on the mitochondrial files, because it is built for long reads from an Oxford Nanopore instrument, which can come off either strand. Import `HG002.chrM.ont.fastq.gz` as a read bundle by following [Importing Sequencing Reads](01-importing-fastq.md). It holds the same 950 reads as the `barcode01` bundle from [Oxford Nanopore Runs](07-ont-runs.md), so you can use that bundle instead if you already imported it. Import `NC_012920.1.fasta` as a reference by following [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md), which is a different import path from the one for reads.

1. Click the mitochondrial read bundle in the sidebar.
2. Choose **Tools > Read Processing > Orient Reads...**.
3. In the Inputs section, pick `NC_012920.1` from the references in your project. Until you do, the Run button stays disabled and the Readiness line says "Select a reference sequence to continue."
4. Leave **Word Length** at 12 and **Database Mask** on dust.
5. Click Run.

<!-- SHOT: orient-reads-pane -->

The dialog keeps only the reads it could place on a strand and drops the rest, and its Advanced Settings note says so. Against one very long reference record, such as the 500,001-base chromosome 20 slice, vsearch places no reads, and the run still reports success with an empty bundle. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## Settings

Repair Paired-End Files, Reverse Complement, and Translate have no settings of their own. Every pane in this chapter carries Output Strategy. Orient Reads is the only pane with an Extra arguments field.

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output. Leave it on Per Input, the default. [Trimming and Filtering](04-trimming-and-filtering.md#shared-settings) explains the two choices. This setting has no command-line flag.

**Strictness.** Chooses how much evidence bbmerge needs before it joins a pair, offering Normal and Strict, where Strict turns down overlaps that look marginal. The default is Normal, which merges more pairs and is the right start when you have no reason to doubt the joins. Switch to Strict when merged reads show mismatches in the joined middle, seen as unexpected disagreement with a reference after mapping, and accept that fewer pairs will merge. On the command line this is `--strict`.

**Minimum Overlap.** Sets the fewest bases the two mates must share before they may join, since a short overlap can occur by chance between unrelated sequence. The default is 12 bases, low enough to catch long fragments whose mates barely reach each other. Raise it when spurious merges produce wrong fragment lengths, and lower it only to rescue pairs that barely overlap. On the command line this is `--min-overlap`.

**K-mer Size.** Sets the k-mer length Tadpole counts across the data set to tell a real base from a sequencing error. The default is 50, which suits reads of 100 bases and longer, such as this fixture's 250-base reads. Lower it for short reads or shallow data, because a k-mer longer than the read cannot be counted at all. On the command line this is `--kmer`.

The dialog accepts any positive whole number here and shows "Enter a positive k-mer size." otherwise. The usable range is 1 to 62. A larger value starts the run, and `lungfish-cli` then stops it with the message "K-mer size must be between 1 and 62". A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it.

**Word Length.** Sets the length of the exact matching word vsearch uses to decide which strand a read came from, where longer words are more specific and slower. The default is 12 bases, short enough to find matches in nanopore reads despite their higher error rate. Shorten it when many reads come back unplaced, and lengthen it when reads land on the wrong strand, staying within the 3 to 15 that vsearch accepts. On the command line this is `--word-length`.

**Database Mask.** Chooses whether low-complexity stretches of the reference, such as long runs of one base, are hidden from matching, offering dust and none, where dust names the masking method. The default is dust, because a read that matches only a run of adenines says nothing about its strand. Choose none when your reference is short and masking hides the only usable match. On the command line this is `--db-mask`.

**Extra arguments.** Passes text straight to vsearch without LGE checking it. The default is empty, which is right for almost every run. Use it only for a vsearch option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

The Translate pane offers no control for the [reading frame](../../GLOSSARY.md#reading-frame), which is where the reading of bases in threes begins. A sequence can be split into three-base [codons](../../GLOSSARY.md#codon) from its first base, its second, or its third, and each split gives a different protein. The dialog always uses frame 1, which starts at the first base, and the standard genetic code. If your reads are in another frame, translate them on the command line instead.

## Reading the results

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains. That record also keeps the report each tool printed. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Select the result bundle, find the tool's step under Lineage in the Provenance section, and expand it. The report is on the stderr row, named for standard error, the channel where command-line programs print their messages. Most figures below come from it.

### The merge report

On this fixture bbmerge saw 45,574 pairs and joined 32,031 of them, which it reports as 70.283 percent. The 13,543 pairs it could not join appear on a line labelled "No Solution", the tool's wording for finding no overlap it believed in. Its estimate of the average insert was 371.5 bases, with a standard deviation of 63.9 and joined inserts from 64 to 482 bases. The standard deviation is a measure of spread, and a value near a sixth of the average is a tight distribution for randomly broken DNA.

The numbers explain each other. Two 250-base reads span 500 bases, so a 371-base fragment leaves about 129 bases read twice. The pairs that failed are mostly the long tail of the distribution, fragments near or above 500 bases whose mates never met. The longest joined insert, 482 bases, sits just under that ceiling, because no longer fragment can be measured by overlap at all.

Merging keeps every read, and the record count shows it. The 32,031 joined pairs became one record each. The 13,543 unjoined pairs kept both mates, contributing 27,086 records. Together that is 59,117 records, and none was thrown away. Because the dialog also collapses identical sequences, the dialog's output holds 58,915 records that between them stand for the same 59,117 reads, and a record that stands for three reads carries `size=3` in its name.

A record longer than 250 bases, the longest input read, can only be a joined pair.

### The other reports

Tadpole reports errors and reads separately, and the two kinds of number should not be added. On this fixture it read 91,148 reads and wrote 91,148 reads, having counted 1,485,830 distinct k-mers. It detected 122,406 errors and corrected 42,033 of them. The gap is Tadpole declining to change a base when the evidence for a replacement was thin, which is the behaviour you want. By read, it found at least one suspect base in 30,929 reads, 33.93 percent of the data set. It fully corrected 24,219 of those and partly corrected 935, and left the other 5,775 alone. On this run 4,121 of those were rollbacks, meaning Tadpole undid a correction it had started.

Repair reports the same way. The next numbers come from a copy of this fixture with 228 mates removed on purpose, a demonstration rather than a step to repeat. On that copy repair.sh read 90,920 records and wrote 90,920, of which 90,692 were paired and 228 were [singletons](../../GLOSSARY.md#singleton-read), reads whose partner no longer exists. Both groups go into the one output, pairs first, so no read is lost.

Orient Reads reports the split between strands. Of the 950 mitochondrial reads that went in, vsearch placed 439 on the forward strand and 488 on the reverse strand, which it flipped. That is 927 oriented, 97.58 percent, with 23 left unplaced. Because the dialog drops unplaced reads, the output holds 927 records, and the gap from 950 is what was dropped.

Reverse Complement and Translate change every record and drop none. Reverse-complementing this fixture's R1 file gave 45,574 records from 45,574 reads, with each quality string reversed alongside its sequence, so every base keeps the score it was measured with. Translating the same file gave 45,574 protein sequences, most of them 83 amino acids long, which is 250 bases divided by three with one base left over. Shorter reads give shorter proteins, and on this fixture the lengths run from 16 to 83.

Translate's output opens as a sequence bundle rather than a read bundle, because it holds protein FASTA. Click it in the sidebar to open it in the sequence viewport. Each record keeps the read's original name with the frame and code appended, as in `_frame+1 [Standard] [83 aa]`, where Standard names the genetic code that applies to nuclear genes in most organisms.

## What good looks like

Check the merge rate first. A rate near 70 percent, as here, means the insert sizes and the read length suit each other and merging is doing real work. A rate under about 5 percent means almost no pair overlapped, so the inserts are longer than the reads can span. Merging is the wrong step for that library, and you should carry the pairs forward as they are, since mappers and assemblers accept pairs directly. A rate close to 100 percent is worth a second look on [shotgun](../../GLOSSARY.md#shotgun) data, where the DNA was broken at random. It often means the fragments were unusually short, a library-preparation matter rather than a software one, and the data are still usable. For [amplicon](../../GLOSSARY.md#amplicon) data, where every fragment is a designed PCR product of fixed length, a rate near 100 percent is normal.

Check the insert estimate next. The average bbmerge prints describes only the pairs that joined, so it leaves out every fragment too long to overlap. The library's true average is higher. The gap is modest at a 70 percent merge rate and large at 20 percent.

Check the read count on every operation. Merge, Repair, Reverse Complement, Translate, and Correct Sequencing Errors account for every input read, so a shortfall there means something failed. Orient Reads is the one operation here that discards reads on purpose, so compare its output count with its input count after every run. If it lost more than you can accept, shorten the word length and run it again.

Finally, check that error correction was worth running. It relies on seeing each true base many times and each error once, so it needs depth. [Depth](../../GLOSSARY.md#depth) is the number of reads covering one position. With only a handful of reads over each position, Tadpole cannot tell a rare real variant from a mistake and may erase real variants, so skip the operation rather than tune it. A FASTQ file alone does not tell you the depth, so this check waits until you have mapped the reads, the subject of the next part of this manual. The Inspector's Est. Coverage is an estimate built on an assumed read length, so trust the measured mean depth instead, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#reading-the-results) explains. This fixture's measured mean depth is 44.7x, comfortably enough. As a rough rule, skip error correction below about 10x.

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

To see any run from this chapter as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. The block below reproduces the procedure on the downloaded files. Merge and repair need one interleaved file, so the pair is interleaved first. A backslash at the end of a line means the command continues on the next line.

```bash
lungfish-cli fastq interleave \
  --in1 HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --in2 HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --output HG002.interleaved.fastq

lungfish-cli fastq merge HG002.interleaved.fastq \
  --min-overlap 12 --count-duplicates --output HG002.merged.fastq

lungfish-cli fastq repair HG002.interleaved.fastq \
  --output HG002.repaired.fastq

lungfish-cli fastq error-correct HG002.interleaved.fastq \
  --kmer 50 --output HG002.corrected.fastq

lungfish-cli fastq reverse-complement HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --output HG002.R1.rc.fastq

lungfish-cli fastq translate HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --frame 1 --output HG002.R1.protein.fasta

lungfish-cli fastq orient HG002.chrM.ont.fastq.gz \
  --reference NC_012920.1.fasta --word-length 12 --db-mask dust \
  --output HG002.chrM.oriented.fastq

lungfish-cli fastq deinterleave HG002.interleaved.fastq \
  --out1 HG002.R1.fastq --out2 HG002.R2.fastq
```

Two command-line defaults differ from the window. The dialog always passes `--count-duplicates` to `fastq merge`, and the command leaves it off unless you add it, so a plain command-line merge of this fixture writes 59,117 records where the dialog writes 58,915. The dialog always translates in frame 1, while `fastq translate` accepts `--frame` from 1 to 6, where 4 to 6 are the three frames of the [reverse complement](../../GLOSSARY.md#reverse-complement), so other frames are a command-line task.

`fastq interleave` rewrites every base scored Phred 2 as Phred 0, which understates the lowest quality scores in the file it writes. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## Next

This is the last chapter in the Reads part of the manual, which began with [Importing Sequencing Reads](01-importing-fastq.md). Continue to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) to align your processed reads against a reference genome.

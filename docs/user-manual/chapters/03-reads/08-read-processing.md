---
title: Read Processing
chapter_id: 03-reads/08-read-processing
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq, 03-reads/03-quality-control]
estimated_reading_min: 30
task: Merge overlapping pairs, repair desynchronized mates, correct sequencing errors, reverse-complement reads, orient reads against a reference, and translate reads to protein.
tags: [reads, merge, repair, error-correct, reverse-complement, orient, translate]
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
glossary_refs: [fastq, read, read-merging, insert-size, paired-end, interleaved-fastq, singleton-read, k-mer, phred-score, reverse-complement, reading-frame, codon, orient-reads, amplicon, provenance, required-setup-pack, library-prep, coverage]
features_refs: [fastq.read-processing]
fixtures_refs: [hg002-chr20, hg002-long-reads, human-mito]
brand_reviewed: true
lead_approved: true
---

## What it is

A [read](../../GLOSSARY.md#read) is one fragment of DNA reported by a
sequencing instrument, stored as a string of bases with a quality score for
each base. The operations in this chapter rewrite or rearrange those reads
without throwing any away. Joining two reads into one longer sequence is a
typical example. Trimming and filtering, covered in
[Trimming and Filtering](04-trimming-and-filtering.md), do the opposite job.
They discard bases and reads that are untrustworthy. Read Processing keeps
everything, so that a downstream tool receives the reads in the form it
expects.

Lungfish Genome Explorer (LGE) groups six operations under
**Tools > Read Processing**. Two of them work on
[paired-end](../../GLOSSARY.md#paired-end) data, where the instrument reads
both ends of the same DNA fragment. The two reads from one fragment are
called mates. Merge Overlapping Pairs performs
[read merging](../../GLOSSARY.md#read-merging), joining the two mates of a
pair into one longer sequence when they overlap in the middle. Repair
Paired-End Files puts mates back into their proper order, which is the
forward read of a fragment followed immediately by its reverse read, when an
earlier step scrambled them. Two more operations rewrite each read on its
own. Reverse Complement flips a read onto the opposite DNA strand, and
Translate converts the bases into the protein sequence they would encode.
The last two use outside information.
[Orient Reads](../../GLOSSARY.md#orient-reads) compares each read to a
reference and flips the ones that came off the wrong strand, and Correct
Sequencing Errors uses the depth of the whole dataset, meaning how many
times each position was read across every read in the file, to fix bases
that look like instrument mistakes.

<!-- SHOT: read-processing-menu -->

Five of the six write a new [FASTQ](../../GLOSSARY.md#fastq) file, the
four-line-per-read text format that carries a name, the bases, and one
[Phred score](../../GLOSSARY.md#phred-score) per base. Translate is the
exception. It emits protein FASTA, which is the same FASTA format holding
amino acid letters instead of bases. It does so because an amino acid is
encoded by three bases, and averaging three per-base quality scores into one
number would give a residue a score that describes none of the three
measurements honestly. In every case LGE reads the input file and never
modifies it, so a run that goes wrong costs you nothing but the output.

Two more read-rewriting utilities exist only on the command line, with no
entry in the Tools menu. Interleave folds a separate R1 file and R2 file
into one [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq), where the
two mates of each fragment sit as consecutive records, and Deinterleave
splits an interleaved file back into two. If you work only in the window you
never need either one, because importing a paired sample already stores it
interleaved. So reach for this chapter when a tool downstream refuses your
reads because of their form, and reach for the trimming chapter when it
refuses them because of their quality.

## Why you would do this

The chapter's worked example is the HG002 chromosome 20 slice, the practice
dataset this chapter runs everything against. It is paired-end human data.
Its two files hold 45,574 read pairs, which is 91,148 individual reads
counted one mate at a time, of up to 250 bases each and most of them the
full 250. Every one came from a 500 kb region of chromosome 20, meaning
500,000 bases, which is under one percent of that chromosome. That
combination is exactly the case merging was invented for.

Think about what the instrument measured.
[Library preparation](../../GLOSSARY.md#library-prep), the bench work that
turns extracted DNA into something a sequencer can read, breaks human DNA at
random into fragments a few hundred bases long. The sequencer then reads 250
bases inward from each end of a fragment, so the two mates point toward each
other from opposite ends and meet in the middle if the fragment is short
enough. The [insert size](../../GLOSSARY.md#insert-size) is the full length
of that original fragment. When the insert is shorter than 500 bases, the
two 250 base reads have to cover some of the same bases in the middle, and
those shared bases are the evidence that lets you glue the pair into one
sequence. On this fixture the average insert is 371 bases. Subtracting 371
from the 500 bases the two reads span together leaves 129 bases measured
twice, so most pairs overlap comfortably and merge cleanly.

Merging buys you two things. The joined sequence is longer than either mate,
which helps anything that needs length, such as assembly, where a program
reconstructs long stretches of a genome from overlapping reads, or a search
against a database. It is also more accurate in the middle, because every
base in the overlap was measured twice and the merger can compare the two
measurements and keep the better-supported call.

The other five operations answer narrower questions. Correct Sequencing
Errors is worth running before an assembly on deep data. Repair rescues a
paired file left out of step by an earlier program, most often a filtering
step that dropped reads from one mate file without dropping their partners
from the other. Reverse Complement, Orient Reads, and Translate exist
because a downstream tool sometimes cares about strand or about protein, and
a read as sequenced carries no promise about either.

## Before you start

You need a project open. If you do not have one, choose
**File > New Project** (Cmd-N), or click Create Project on the Welcome
window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice. Download the files
`HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and
`HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's practice data files
on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. You need both files, because they are the
two halves of one paired sample. On that GitHub page, click a filename, then
click the download button on the page that opens. The Orient Reads section
uses two files from other practice folders instead. Download
`HG002.chrM.ont.fastq.gz` from

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-long-reads

and `NC_012920.1.fasta` from

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/human-mito

which are human mitochondrial nanopore reads and the mitochondrial reference
sequence they came from.

Import both read files first, following
[Importing Sequencing Reads](01-importing-fastq.md), so the bundle exists
before you process it. A bundle is a folder that LGE treats as one object,
holding the sample's reads together with the records of where they came
from, and the sidebar shows it as a single row. The import stores a
paired sample inside its bundle as one interleaved file, which matters here
because Merge Overlapping Pairs and Repair Paired-End Files both need their
input interleaved. Reading
[Quality Control for Reads](03-quality-control.md) first is worthwhile,
because the read counts it teaches you to find are how you will check each
result below.

None of these operations is written by LGE. Each one runs an outside program
on your behalf, and the names in the reports you will read below belong to
those programs. Merge Overlapping Pairs runs bbmerge, Repair Paired-End
Files runs repair.sh, and Correct Sequencing Errors runs Tadpole, all three
from the BBTools suite. Orient Reads runs vsearch. Reverse Complement and
Translate are done by LGE itself.

LGE pins BBTools at version 40.02, meaning it installs that exact version
and always uses it, so your results match the numbers in this chapter and
nothing about the version is yours to manage. BBTools and vsearch both come
from the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the
one pack LGE installs by itself the first time it needs it. Checking is
optional, and you only need it if an operation reports a missing tool. To
check, open **Tools > Plugin Manager...** (Cmd-Shift-B), where the pack
appears under the heading Required Setup. Nothing else needs installing.

## Procedure

Every operation in this chapter follows the same four moves. Select the
FASTQ bundle in the sidebar, choose the operation from
**Tools > Read Processing**, set the fields on the pane that opens, and
click Run. The dialog that opens is titled FASTQ/FASTA Operations, and only
the settings pane changes between operations. The Settings section below
describes every field on every pane. One field, **Output Strategy**, appears
on all six panes and decides whether several selected datasets each get
their own output or are pooled into one. Leave it on Per Input for
everything in this chapter, and see the Settings section for the full
description.

Results land under `Analyses/` in your project, in a bundle named from the
input file stem and the operation. The stem is the filename with its
extensions removed, so `HG002.chr20.10.0-10.5Mb.fastq.gz` has the stem
`HG002.chr20.10.0-10.5Mb`. The operation half of the name is LGE's internal
name for the job rather than the menu wording, so a merge of this fixture
writes `HG002.chr20.10.0-10.5Mb-pairedEndMerge`. The five siblings end in
`-pairedEndRepair`, `-reverseComplement`, `-translate`, `-orient`, and
`-errorCorrection`. The input bundle is left exactly as it was.

### Merging the overlapping pairs

1. Click the imported HG002 bundle in the sidebar so it is the selected
   dataset.
2. Choose **Tools > Read Processing > Merge Overlapping Pairs...**.
3. Leave **Strictness** on Normal, which accepts any overlap the merger
   finds convincing, and **Minimum Overlap** at 12 bases. These are the
   defaults, and they are the settings the numbers in this chapter came
   from.
4. Click Run.

<!-- SHOT: merge-overlapping-pairs-pane -->

The operation appears in the Operations panel, which you can open with
**Operations > Show Operations Panel** (Cmd-Shift-P) if it is not already
showing. When it finishes, the new bundle appears in the sidebar under
Analyses.

<!-- SHOT: sidebar-after-merge -->

### Repairing a paired file whose mates fell out of step

Repair is a rescue operation rather than a routine step, so run it only when
a paired file is actually broken. In a healthy interleaved file the records
run forward read, reverse read, forward read, reverse read, each adjacent
pair belonging to one fragment. A broken file has a forward read whose
partner was removed, so every record after it is paired with the wrong one.
The symptom is a downstream tool complaining that the mates do not line up,
or a read count that is not divisible by two when it should be. To see that
count, double-click the bundle in the sidebar to open its FASTQ viewport and
read the Reads card along the top. Then select the bundle, choose
**Tools > Read Processing > Repair Paired-End Files...**, and click Run.
The pane has no settings beyond the output strategy, because there is
nothing to tune. Repair only sorts records back into order.

### Correcting sequencing errors

A [k-mer](../../GLOSSARY.md#k-mer) is a short run of exactly k bases taken
from a read, and this operation works by counting how often each k-mer turns
up across the whole dataset. A k-mer seen thousands of times is real, and
one seen once is usually a misread base. The rule of thumb for choosing k is
to make it long enough to be unique in the genome and short enough to fit
comfortably inside a read, which for reads of 100 bases and longer puts it
around 50.

Select the bundle, choose
**Tools > Read Processing > Correct Sequencing Errors...**, leave
**K-mer Size** at 50, and click Run. The output holds the same number of
reads as the input, with individual bases changed.

### Flipping, orienting, and translating

Reverse Complement and Translate need no configuration at all beyond the
output strategy. Select the bundle, choose the operation, and click Run.

Orient Reads needs two more things, and it runs on the mitochondrial
practice files rather than the chromosome 20 slice. Import
`HG002.chrM.ont.fastq.gz` as a read bundle, following
[Importing Sequencing Reads](01-importing-fastq.md), and import
`NC_012920.1.fasta` as a reference, following
[Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md),
which is a different import path from the one that brings in reads. Because
the operation decides each read's strand by comparing it to something, it
asks for that reference in the Inputs section of the dialog, chosen from the
references already in your project. Until you pick one, the Run button stays
disabled and the dialog prints "Select a reference sequence to continue."
Select the mitochondrial read bundle, leave **Word Length** at 12 and
**Database Mask** on dust, then click Run.

Do not run it against the chromosome 20 slice and its reference. That
reference is one record 500,001 bases long, and against a single long record
vsearch orients nothing. In this release LGE then writes an empty bundle and
reports success without a warning, so a run like that looks finished and
holds no reads. Checking the output count against the input count is how
you catch it.

<!-- SHOT: orient-reads-pane -->

One behaviour of this pane is worth knowing before you rely on it. Reads
that vsearch cannot confidently place on either strand are discarded, and
the pane says so in its Advanced Settings section, further down the same
pane. If you need to keep them, run Orient Reads from the FASTQ viewport
instead. Double-click the bundle in the sidebar to open that viewport, go to
its Operations tab, and you will find a **Save unoriented reads** checkbox
that is on by default.

## Settings

All six panes carry **Output Strategy**, and it behaves the same way on each
of them. Per Input, the default, gives every dataset you selected its own
output bundle. Grouped Result pools them into one. With a single dataset
selected, which is the case throughout this chapter, the two choices produce
the same result. The entries below repeat the setting once per operation
because each pane shows it, and each entry notes anything specific to that
operation.

### Merge Overlapping Pairs

**Strictness.** Chooses how much evidence bbmerge demands before it joins a
read pair, offering exactly two settings, Normal and Strict, where Strict
rejects overlaps that look marginal. The default is Normal, which merges
more pairs and is the right starting point when you have no reason to
distrust the joins. Switch to Strict when merged reads are showing
mismatches in the joined region, which you would notice as unexpected
disagreement with a reference after mapping the merged reads, and accept
that you will merge fewer pairs in exchange. On the command line Normal is
the default and Strict is `--strict`, a switch with no value.

**Minimum Overlap.** The fewest bases the two mates must share before they
are allowed to join, since a short overlap can occur by chance between
unrelated sequence. The default is 12 bases, low enough to catch pairs from
long inserts that barely reach each other, and it counts shared bases
between two mates rather than the matching word length that **Word Length**
under Orient Reads counts. Raise it when spurious merges are producing wrong
fragment lengths, and lower it only to rescue pairs that barely overlap,
which a first run's reported insert size will tell you whether you have. On
the command line this is `--min-overlap`.

**Output Strategy.** Chooses whether each selected dataset is merged into
its own output bundle or all of them are pooled into one. The default is Per
Input, which keeps samples separate and is what you want unless the files
you selected are genuinely one library. Choose Grouped Result when several
files belong to one library. This setting has no command-line flag.

The pane exposes no control for one thing a dialog merge always does. It
collapses identical merged sequences into one record and writes the number
of reads behind that record into the record's name. The Reading the results
section below works through what that means for the record count you will
see.

### Repair Paired-End Files

**Output Strategy.** Chooses whether each selected dataset is repaired into
its own output bundle or all of them are pooled into one. The default is Per
Input, which is the safe choice because pooling two broken files makes the
pairing harder to reason about, not easier. Choose Grouped Result when
several files belong to one library. This setting has no command-line flag.

### Correct Sequencing Errors

**K-mer Size.** The word length Tadpole counts across the whole dataset to
tell a real base from a sequencing error, where a base that breaks an
otherwise common word is treated as a mistake and corrected. The default is
50, which suits reads of 100 bases and longer such as this fixture's 250
base reads. Lower it for short reads or shallow coverage, because a k-mer
longer than the read cannot be counted at all. On the command line this is
`--kmer`.

Useful values run from 1 to 62. The dialog itself only checks that you typed
a positive number, and refuses to run with the message "Enter a positive
k-mer size." if you did not. Type something above 62 and the dialog will
start the run and let Tadpole reject the value, which surfaces as a failed
operation in the Operations panel rather than as a warning in the dialog.
Your input bundle is never modified by a failed run, so a rejected value
costs you only the time of the attempt.

**Output Strategy.** Chooses whether each selected dataset is corrected into
its own output bundle or all of them are pooled into one. The default is Per
Input, one corrected bundle per sample. Choose Grouped Result when several
files belong to one library, because the deeper pooled coverage gives the
k-mer counts more to work with. This setting has no command-line flag.

### Reverse Complement

**Output Strategy.** Chooses whether each selected dataset is
reverse-complemented into its own output bundle or all of them are pooled
into one. The default is Per Input, which keeps the output parallel to the
input. Choose Grouped Result when several files belong to one library. This
setting has no command-line flag.

### Orient Reads

**Word Length.** The length of the exact word vsearch matches to decide
which strand a read came from, where longer words are more specific and
slower, and it counts a stretch of the reference rather than the shared
bases that **Minimum Overlap** counts. The default is 12 bases, chosen for
the long nanopore reads this operation is built for, where a short word
still finds a match through a high error rate. Shorten it when many reads
come back unoriented, and lengthen it when reads are being placed on the
wrong strand. On the command line this is `--word-length`.

**Database Mask.** Chooses whether repetitive stretches of the reference are
hidden from matching, where dust is the name of the masking algorithm and it
hides low-complexity sequence such as long runs of a single base. The
default is dust, because a read that matches only a poly-A tract, meaning a
long run of adenine bases, tells you nothing about its strand. Choose none
when your reference is short and masking is hiding the only usable match
region. On the command line this is `--db-mask`.

**Extra arguments.** Extra vsearch options passed straight through after
everything above, unchecked by LGE before vsearch sees them. The default is
empty, which is right unless you already know the vsearch option you want,
and an option vsearch does not recognise makes the run fail outright rather
than quietly producing a wrong answer. Use it only when you need a vsearch
feature the pane does not expose. On the command line this is
`--extra-args`.

**Output Strategy.** Chooses whether each selected dataset is oriented into
its own output bundle or all of them are pooled into one. The default is Per
Input, so selecting several bundles queues one orientation run per bundle.
Choose Grouped Result when several files belong to one library. This setting
has no command-line flag.

### Translate

**Output Strategy.** Chooses whether each selected dataset is translated
into its own output file or all of them are pooled into one. The default is
Per Input, which keeps one protein FASTA per sample. Choose Grouped Result
when several files belong to one library. This setting has no command-line
flag.

A [reading frame](../../GLOSSARY.md#reading-frame) matters because bases are
read three at a time, so a sequence can be split into codons starting at its
first base, its second, or its third, and each split gives a different
protein. Only one of the three is usually the real one, and a read carries
no marker saying which.

The dialog fixes the frame at 1, the frame that starts at the first base of
the read, and states so on the pane. It offers no control for the frame or
for the genetic code table. Both are available on the command line,
described in the last section of this chapter. If you know your reads are
not in frame 1, translate them there instead.

## Reading the results

Every one of these operations logs to the Operations panel and writes a
[provenance](../../GLOSSARY.md#provenance) record beside its output, holding
the settings you chose and a checksum of the input. That record is how you
answer, months later, which minimum overlap produced a given file.

Each operation also prints the report its tool wrote. To read it, find the
operation's row in the Operations panel and click the row to expand it. The
tool's own output appears there line by line, and every figure quoted below
comes from that expanded row.

The most informative result is the merge. Reading the run on this fixture
from the top, bbmerge saw 45,574 pairs and joined 32,031 of them, which it
reports as 70.283 percent. The 13,543 pairs it could not join are counted on
a line labelled "No Solution", which is the tool's own wording for finding
no overlap it believed in. Its estimate of the average insert was 371.5
bases with a standard deviation of 63.9, and the inserts it measured ranged
from 64 to 482 bases. A standard deviation near a sixth of the mean is a
tight distribution for a sheared library, which is what a well-controlled
fragmentation step produces.

Those numbers explain each other. Two 250 base reads span 500 bases, so a
fragment of 371 bases leaves about 129 bases measured twice, which is a
comfortable overlap. The pairs that failed are the long tail of the
distribution, the fragments near or above 500 bases where the two reads
never met. The maximum observed insert of 482 sits just under that ceiling
because the 500 bases the two reads span together is what causes the
ceiling. No fragment longer than that can be measured by this method at all.

The output file holds 59,117 records, and that arithmetic is worth doing
once because it tells you what merging actually did to your data. To see the
count for your own run, double-click the output bundle in the sidebar and
read the Reads card at the top of its FASTQ viewport. The 32,031 joined
pairs each became one record. The 13,543 unjoined pairs kept both mates,
contributing 27,086 records. Together that is exactly 59,117. Nothing was
discarded. The merged sequences are written first and the unmerged reads
follow, so the file is ordered rather than shuffled.

One thing will make a merge you run in the window report a slightly smaller
number. The dialog always collapses identical merged sequences into a single
counted record, so this same run through the dialog writes 58,915 records
that between them still stand for all 59,117 reads. The last section of this
chapter explains where that count is recorded.

The merged reads are also longer than what went in, which you can see by
looking at the first few sequences. The first three records of this run are
472, 411, and 311 bases against an input where no read exceeded 250. A
record longer than 250 bases is by definition a joined pair.

Correcting sequencing errors reports differently, because it changes bases
rather than counts. On this fixture Tadpole read 91,148 reads and wrote
91,148 reads, that figure being the 45,574 pairs counted as individual
mates, having counted 1,485,830 distinct k-mers across the dataset. It
detected 122,406 errors, a number that sounds alarming until you see that
one read can hold several, and corrected 42,033 of them. The gap between the
two is not a failure. It is the tool declining to change a base when the
evidence for the replacement was not strong enough, which is the behaviour
you want.

The rest of the report counts reads rather than errors, and the two kinds of
number should not be added together. It found at least one suspect base in
30,929 reads, which is 33.93 percent of the dataset. Of those it fully
corrected 24,219 and partly corrected 935. That leaves 5,775 reads where it
detected something and then left the bases alone, having judged the evidence
for a replacement too thin. On this run 4,121 of those were rollbacks, which
is the tool undoing a correction it had started to make.

Repair reports in the same shape. The numbers below come from a copy of this
fixture with 228 mates deliberately removed, which is a demonstration rather
than a step for you to repeat. On that copy repair.sh read 90,920 records
and wrote 90,920 records, of which 90,692 were paired and 228 were
[singletons](../../GLOSSARY.md#singleton-read), reads whose partner no longer
exists. Both groups go into the one output file, paired records first and
singletons after, so no read is silently lost.

Orient Reads reports the split between strands. The numbers here come from
the HG002 mitochondrial reads, which is the run the procedure above makes.
Orient Reads exists for long reads from an Oxford Nanopore instrument, whose
strand is not fixed by the protocol. Of the 950 reads that went in, it
placed 439 forward and 488 reverse, oriented 927 in total, which it prints
as 97.58 percent, and left 23 unoriented. Since the operations dialog
discards the unoriented reads, the output held 927 records, and comparing
that to the 950 that went in is how you measure what was dropped.

Reverse Complement and Translate change every record and drop none. A
reverse-complemented run of this fixture's R1 file produced 45,574 records
from 45,574 reads, with each quality string reversed alongside its sequence
so that every base keeps the score it was measured with. Translating the
same file produced 45,574 protein sequences, most of them 83 amino acids,
which is 250 bases divided by three with one base left over that is
discarded. Shorter reads give shorter proteins, and on this fixture the
lengths run from 16 to 83 residues.

Each translated record's name is the read's original name with the frame and
the code table appended, so nothing is lost and nothing is replaced. The
appended part reads `_frame+1 [Standard] [83 aa]`. A code table is the
mapping from three-base [codons](../../GLOSSARY.md#codon) to amino acids,
and Standard names the one that applies to nuclear genes in most organisms.
You can see these names by double-clicking the output bundle in the sidebar,
which opens it in the sequence viewport.

## What good looks like

Check the merge rate first, on the joined line of the expanded operation row
in the Operations panel. A percentage near 70, as here, means your insert
size and your read length are well matched, and merging is doing real work.
A rate under about 5 percent means almost no pair overlapped, so the inserts
are longer than the reads can span. Merging is not the right step for that
library, and you should carry the unmerged pairs forward as they are, since
mappers and assemblers both accept paired reads directly. A rate very close
to 100 percent, on the other hand, is worth a second look on shotgun data,
because it can mean the inserts are unusually short, which often points to
over-fragmentation during library preparation. That is a bench problem
rather than a software one, and the data is still usable. Merged reads
shorter than a single read length are the sign to watch for, and you would
fix it by shearing less on the next preparation. For
[amplicon](../../GLOSSARY.md#amplicon) data, where every fragment is the same
designed length, a rate near 100 percent is normal and expected.

Check the insert distribution next. The average and standard deviation
bbmerge prints describe only the pairs that merged, so they are a biased view
of the library that leaves out every fragment too long to overlap. Your true
average insert is higher than the printed one. How much higher depends on
how many pairs failed to merge, so treat a 70 percent merge rate as a modest
understatement and a 20 percent rate as a large one.

Check the read count on any operation that can drop records. Merge, repair,
reverse complement, translate, and error correction all account for every
input read, so a shortfall there means something failed. Orient Reads is the
one operation in this chapter that deliberately discards, so compare its
output count to its input count every time, and if the loss is larger than
you can accept, shorten the word length or run the operation from the FASTQ
viewport where the unoriented reads can be kept.

Finally, check that error correction was worth running at all. It depends on
seeing the same true base many times and the same error once, so it needs
[coverage](../../GLOSSARY.md#coverage), the number of reads sitting over
each position. On thin coverage there is not enough repetition to tell a
rare real variant from a mistake, and the correction can erase real
variants. When only a handful of reads cover each position, skip this
operation rather than tuning it. Coverage cannot be read from a FASTQ, so you learn it by mapping
the reads and reading the Est. Coverage figure that
[Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md)
describes. This fixture's 44.7 is comfortably above the line.

## On the command line

If you have never used a terminal, skip this whole section. Everything a
window user needs is above, including the k-mer range, the fixed reading
frame, and the record count a dialog merge produces. Nothing later in this
manual requires you to have run a command.

For readers who do want the terminal, the `lungfish-cli` program ships
inside the application, and the [CLI Reference](../appendices/cli-reference.md)
appendix says where it lives.

Every subcommand below takes one input file and requires `--output`. Add
`--force` to overwrite an output that already exists and `--compress` to
write the result gzip-compressed. The one exception is `fastq deinterleave`,
which writes two files and so takes `--out1` and `--out2` instead. A
backslash at the end of a line tells the shell that the command continues on
the next line, and if you retype a command on one long line you leave the
backslashes out.

```bash
# Merge and repair both want one interleaved file, so fold the pair first.
lungfish-cli fastq interleave \
  --in1 HG002.chr20.10.0-10.5Mb_R1.fastq \
  --in2 HG002.chr20.10.0-10.5Mb_R2.fastq \
  --output HG002.interleaved.fastq --force

# The merge, at the same defaults the dialog uses.
lungfish-cli fastq merge HG002.interleaved.fastq \
  --min-overlap 12 --output HG002.merged.fastq --force

# Put mates back in order and keep the orphans as singletons.
lungfish-cli fastq repair HG002.interleaved.fastq \
  --output HG002.repaired.fastq --force

# K-mer error correction over the whole dataset.
lungfish-cli fastq error-correct HG002.interleaved.fastq \
  --kmer 50 --output HG002.corrected.fastq --force

# Flip a file onto the opposite strand, qualities included.
lungfish-cli fastq reverse-complement HG002.chr20.10.0-10.5Mb_R1.fastq \
  --output HG002.R1.rc.fastq --force

# Translate to protein FASTA in frame 1 with the standard code.
lungfish-cli fastq translate HG002.chr20.10.0-10.5Mb_R1.fastq \
  --frame 1 --table 1 --output HG002.R1.protein.fasta --force

# Orientation needs a reference FASTA. This is the mitochondrial run.
lungfish-cli fastq orient HG002.chrM.ont.fastq.gz \
  --reference NC_012920.1.fasta \
  --word-length 12 --db-mask dust \
  --output HG002.chrM.oriented.fastq --force

# Split an interleaved file back into two.
lungfish-cli fastq deinterleave HG002.interleaved.fastq \
  --out1 HG002.R1.fastq --out2 HG002.R2.fastq
```

Four differences between the command line and the window are worth knowing.
The first concerns duplicate merged sequences. `fastq merge` carries a
`--count-duplicates` flag, off by default, that collapses identical merged
sequences into one record and writes the number of reads behind it into the
header as `size=N`. The dialog always passes that flag, so a dialog merge and
a plain command-line merge of the same file produce different record counts.
On this fixture the plain run wrote 59,117 records while the counted run
wrote 58,915 exemplars representing the same 59,117 reads, with headers
rewritten to the form `u000001;size=3`.

The second is the reading frame. `fastq translate` takes `--frame`, an
integer from 1 to 6 where 1 to 3 are the three frames on the forward strand
and 4 to 6 are the three on the
[reverse complement](../../GLOSSARY.md#reverse-complement), and `--table`,
the genetic code table where 1 is the standard code. The dialog fixes both
at 1 and offers no control for either, so translating in another frame is a
command-line-only operation. The output header records which frame was used,
and the reverse frames are renumbered from 1 on their own strand, so frames
4, 5, and 6 print as `_frame-1`, `_frame-2`, and `_frame-3`.

The third is orientation. `fastq orient` has no option to save the reads it
could not orient, so the command line behaves like the operations dialog and
unlike the FASTQ viewport, where the checkbox exists. Compare your output
count to your input count after every command-line orientation run. Against
a reference that is one long record, such as the chromosome 20 slice, the
command orients nothing, writes an empty file, exits without an error, and
prints nothing at all, which is a defect in this release rather than a
result.

The fourth is that interleave and deinterleave have no dialog at all. They
are the only way to move between the two-file layout and the one-file
layout from outside a bundle, and a paired sample imported into a project is
already stored interleaved, so you need them only for loose files.

One defect applies to `fastq interleave` in this release. It passes the
files through BBTools without pinning the quality encoding, and every base
scored Phred 2, written as `#`, comes out scored Phred 0, written as `!`.
The bases themselves are untouched, and on this fixture 3,522 quality
characters changed. Deinterleave is not affected. Treat the lowest quality
scores in a file made this way as understated until the defect is fixed.

## Next

This is the last chapter in the Reads (FASTQ) part of the manual, which
began with [Importing Sequencing Reads](01-importing-fastq.md). Continue to
[Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md)
to align your processed reads against a reference genome.

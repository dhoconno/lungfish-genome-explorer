---
title: Demultiplexing by Barcode
chapter_id: 03-reads/09-demultiplexing-barcodes
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 27
task: Split a pooled read bundle into one bundle per sample with Demultiplex Barcodes, on any sequencing platform.
tags: [reads, demultiplex, barcodes, dual-index, illumina, nanopore, cutadapt, chance-floor, barcode-scout]
tools: [cutadapt]
parameters_refs: [fastq.demultiplex-barcodes]
entry_points:
  - "Tools > Demultiplexing > Demultiplex Barcodes…"
  - "View > Show Drawer (Control-Command-B) > Demux > Detect, Demultiplex…"
  - "CLI: lungfish-cli fastq demultiplex"
  - "CLI: lungfish-cli fastq scout"
shots:
  - id: demux-tab-detect-barcodes
    caption: "The Demux tab of the FASTQ drawer for the Illumina pool after Detect and Proceed, with Advanced ticked so the plan table and its Output Name column show beside the Demultiplex… button."
  - id: demultiplex-barcodes-pane
    caption: "The Demultiplex Barcodes pane with ONT Native Barcoding V14 (SQK-NBD114-96, 96) chosen for the pooled NRG1 bundle, where a caption stands in place of the Location and distance controls."
  - id: demultiplex-chance-summary
    caption: "The Operations Panel row of the Exact Bare Barcode run on the pooled NRG1 bundle, whose line under the name says the run was not checked for chance matches."
illustrations: []
glossary_refs: [flow-cell, demultiplex, bundle, barcode, library-prep, fragment, barcode-kit, csv, tsv, adapter, fastq, dual-index, index-hopping, operations-panel, paired-end, hg002, accession, cutadapt, indel, chance-floor, reverse-complement, minknow, amplicon, mate, required-setup-pack, virtual-bundle, barcode-scout, terminal, provenance, derived-bundle, unclassified-reads]
features_refs: [fastq.demultiplex]
fixtures_refs: [nrg1-ont-barcoded, illumina-dual-index-pool]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Splitting a pooled read bundle into one bundle per sample with Demultiplex Barcodes, on every platform. -->

## What it is

Sequencing runs are usually shared. A lab tags each sample's DNA with a short marker of its own, mixes the samples in one tube, and sequences that pool on one [flow cell](../../GLOSSARY.md#flow-cell), the chip that holds the sample inside the instrument. The run returns one heap of reads in which every sample is mixed with every other. [Demultiplexing](../../GLOSSARY.md#demultiplex) sorts that heap back into samples, read by read, by reading each read's marker. This chapter covers Demultiplex Barcodes, the operation in Lungfish Genome Explorer (LGE) that splits one pooled read [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, into one bundle per sample, whatever instrument made the reads.

### Barcodes, kits, and dual indexes

The marker is a [barcode](../../GLOSSARY.md#barcode), a short synthetic DNA sequence, usually 8 to 24 bases long, that [library preparation](../../GLOSSARY.md#library-prep), the bench work that readies DNA for the instrument, attaches to every [fragment](../../GLOSSARY.md#fragment) of one sample, each piece of its DNA bound for the instrument. Barcodes come in commercial sets called [barcode kits](../../GLOSSARY.md#barcode-kit). LGE ships twenty, from Oxford Nanopore, Illumina, PacBio, and Fluidigm, plus the M13 primers. When your barcodes came from an index sheet, a plate layout, or primers your lab designed, you give LGE a Custom Definition instead. That is a plain text file with one row per barcode and the columns `id`, `sequence`, an optional `secondary_sequence`, and an optional `sample_name`. It may be a [CSV](../../GLOSSARY.md#csv) file, a [TSV](../../GLOSSARY.md#tsv) file, or text split by spaces, and a header line that names the columns lets you give sample names without second sequences.

Where the barcode ends up decides how LGE finds it. On a nanopore run the barcode is part of the read itself. It sits near each end of the read inside a stretch of [adapter](../../GLOSSARY.md#adapter), the fixed synthetic DNA that lets the instrument grab the molecule. On an Illumina run the barcode is called an index, and the instrument reads it in a short read of its own, apart from the read of the sample's DNA. The programs that turn an Illumina run into [FASTQ](../../GLOSSARY.md#fastq) files, the plain-text files that hold reads, bcl2fastq and BCL Convert, either split the reads by index themselves or write the index at the end of each read name, the header line that starts each FASTQ record. A read name that ends in `1:N:0:TCCGGAGA+ATAGAGGC` carries two indexes, `TCCGGAGA` and `ATAGAGGC`.

Two indexes per sample make a [dual index](../../GLOSSARY.md#dual-index). The first, called i7, is read from one end of the fragment and the second, called i5, from the other, and a sample is named by the pair rather than by either index alone. The pair guards against [index hopping](../../GLOSSARY.md#index-hopping), a known fault of pooled Illumina runs in which a read picks up an index that belongs to another library in the pool. When no two samples share an index, as in this chapter's Illumina pool, a hopped read carries a pair that no sample owns, so a split by pairs can set it aside. In a Custom Definition the first index goes in `sequence` and the second in `secondary_sequence`. When a search of the read bases looks for such pairs, you may write each second index as it appears at the end of the read or as the i5 primer's barcode, because the run checks which form the first 10,000 reads carry, uses it, and says which in the [Operations Panel](../../GLOSSARY.md#operations-panel), the window that lists LGE's running and finished operations.

Before you split a pool, find out which kit tagged it and whether its barcodes sit in the reads or only in the read names, because those two facts settle every choice in this chapter.

## Why you would do this

A pooled file says nothing about one sample until each read is assigned to its sample. The assignment also has to be right, because a wrong call fails silently. A read from one person filed under another person's name looks like any other read, so a variant or a transcript can turn up in the wrong sample with nothing on screen to say so. That is why LGE checks the barcodes it finds against chance, and why it stops a run in which no barcode turns up in more reads than chance alone would give, rather than hand you sample files made of accidents.

This chapter splits two pools. The Illumina pool is human, 9,958 [paired-end](../../GLOSSARY.md#paired-end) read pairs, each pair read from the two ends of one fragment, taken from the mitochondrial reads of [HG002](../../GLOSSARY.md#hg002), a Genome in a Bottle reference sample, filed under four library names, HG002-lib1 to HG002-lib4. The pool is constructed. Each read pair went to one library at random, its read names were given that library's dual index, and a few index errors and hopped indexes were planted on purpose. A truth table records the right library for every pair. All four libraries hold one person's DNA, so read no biology into a difference between them. They exist so that a split can be checked read by read.

The nanopore pool is real. It holds 2,400 reads of human NRG1 transcripts, the messages of a gene active in nerve and heart development, from six samples, 400 reads each. The samples were tagged with barcodes NB85 to NB91 of Oxford Nanopore's Native Barcoding Kit 96 V14, and the reads still carry those barcodes at their ends. Every read name begins with the [accession](../../GLOSSARY.md#accession) of the run it came from, the run's identifier in the public archive, which also names its true barcode, so this split can be checked too.

Plan how you will check a split before you run it, since the checks at the end of this chapter need the samples you expect and their rough sizes.

## Choosing a tool

Demultiplex Barcodes offers three engines, the part that finds each read's barcode. Which one fits depends on where the barcode sits, in the read name or in the read bases, and on how many errors the reads carry.

Read Names searches nothing. It reads the index that bcl2fastq or BCL Convert wrote in each read name and compares it with the kit's indexes, allowing at most one wrong base in each index, where an `N`, a base the instrument could not call, counts as wrong. A read gets a sample only when exactly one barcode matches. Instruments differ in which strand they read i5 from, so Read Names settles the direction of i5 for each file of a bundle by the majority of that file's first 1,000 read names. It keeps reads unchanged and keeps the two reads of a pair together. It is built for files from Illumina and Element Biosciences sequencers whose read names carry the index, which no search of the read bases can split, because those bases hold no barcode.

[Cutadapt](../../GLOSSARY.md#cutadapt) is an established program that searches the read bases for a known sequence by alignment. It tolerates a set share of wrong bases and small [indels](../../GLOSSARY.md#indel), bases missing or added, so it suits reads with errors. For a long-read kit, which means the nanopore and PacBio kits, LGE has it search each end of the read for the whole barcode construct, the adapter, the barcode, and the short flanking sequences the kit puts around it, in both orientations. When such a kit puts barcodes at both ends, as a native barcoding kit does, a read is assigned only when both ends carry the same barcode. For an Illumina-family kit or a Custom Definition, Cutadapt searches for the bare barcode alone, and a short barcode can turn up by chance in a read that carries none. LGE's [chance floor](../../GLOSSARY.md#chance-floor) guards that search, as [The chance floor and the run summary](#the-chance-floor-and-the-run-summary) explains. Cutadapt trims the matched barcode off unless you say otherwise. As the dialog's default engine with an Illumina-family kit or a Custom Definition, it first checks whether the read names carry the indexes of two or more of the kit's barcodes and hands such files to Read Names.

Exact Bare Barcode is matching LGE does itself, without an outside program. It searches the whole read and its [reverse complement](../../GLOSSARY.md#reverse-complement), the same sequence read from the other strand, for a letter-perfect copy of each barcode, and it never trims. It takes only the built-in Fluidigm Access Array kit or a Custom Definition with one barcode of 1 to 31 plain A, C, G, or T letters per row. It suits barcodes that sit at no fixed place in the read. It checks nothing against chance, so use it only on reads that carry the barcodes in their bases. On nanopore reads, which carry errors from basecalling, the step that turns the instrument's signal into bases, it misses every read whose barcode holds even one error at both ends.

Two more routes belong to [Oxford Nanopore Runs](07-ont-runs.md). [MinKNOW](../../GLOSSARY.md#minknow), the program that runs a nanopore sequencer, often splits a barcoded run into one folder per barcode as it goes, and for Oxford Nanopore's own kits that split is the one to keep. ONT Fluidigm Sample Split handles Fluidigm Access Array [amplicons](../../GLOSSARY.md#amplicon), stretches of DNA copied by PCR from chosen targets, in nanopore reads.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Read Names | Illumina and Element files whose read names carry the index | The read names end in indexes, such as `1:N:0:TCCGGAGA+ATAGAGGC` | The barcodes sit in the read bases |
| Cutadapt, long-read kit | Nanopore and PacBio reads tagged with a listed kit | You know the kit and want the barcode and adapter trimmed | The run was already split into barcode folders |
| Cutadapt, Illumina-family kit or Custom Definition | Barcodes in the read bases at or near a read end | The barcodes sit at a fixed place near the read ends | The index is only in the read names, or the barcodes are only a few bases long |
| Exact Bare Barcode | One plain barcode per sample, anywhere in a read | The reads carry the barcodes and you want no inexact match | The reads carry many errors, or the barcodes sit only in the read names |

The Illumina pool uses Read Names, because its indexes sit only in its read names. The nanopore pool uses Cutadapt with its built-in kit, then Exact Bare Barcode with a Custom Definition on the same reads. Cutadapt is cited in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge). Choose by where your barcodes sit, and change engines only when the reads say so, as when Detect reports that its counts came from the read names.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds the nanopore pool already imported as the `nrg1-pooled` bundle under `Imports`, and the Custom Definition `nrg1-barcodes.csv` under `Practice Data/nrg1-ont-barcoded`. Both come from the nrg1-ont-barcoded fixture, whose source and citation are in [the nrg1-ont-barcoded fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/nrg1-ont-barcoded).

The Illumina pool is the illumina-dual-index-pool fixture. Download `reads_R1.fastq.gz`, `reads_R2.fastq.gz`, and `kit.csv` from [the illumina-dual-index-pool fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/illumina-dual-index-pool), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The two read files hold the first and the second read of each pair, the two [mates](../../GLOSSARY.md#mate). Import both files together into the same project as one paired bundle, as [Importing Sequencing Reads](01-importing-fastq.md#procedure) shows. The command-line import names that bundle `reads` and counts 19,916 reads in 9,958 pairs. `kit.csv` is a Custom Definition that lists the four libraries' index pairs with their sample names.

Cutadapt arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. Read Names and Exact Bare Barcode need no outside program. A Cutadapt run can write its sample files uncompressed and compress them at the end, so keep free disk space for the reads at their uncompressed size.

The nanopore pool splits in well under a minute, and the Illumina pool, at 19,916 reads, probably splits as fast. Watch each run in the Operations Panel, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

## Procedure

### Check an Illumina pool with Detect Barcodes on the Demux tab

Detect Barcodes counts the barcodes of one kit in the first 10,000 reads of a bundle, so a wrong kit shows before a full run. For Illumina and Element kits it counts the index in the read names, and for other kits it searches the read bases. It sits on the Demux tab of the drawer under the reads viewer, where its button reads **Detect**.

1. Click the paired pool bundle in the sidebar, choose **View > Show Drawer** (Control-Command-B), and click the drawer's **Demux** tab.

2. Choose TruSeq HT Dual Index (96 combinations) in the **Kit** menu, the kit whose pairs D701-D501 to D704-D504 tagged the four libraries, and click **Detect**. The drawer's status line shows "Scouting barcodes..." as the count starts.

3. Read the Barcode Detection Results sheet that opens. It lists each index pair it found with its status, its hits, which are the reads that carry it, and its percent of the reads scanned. Click the status of any accepted pair that belongs to none of your samples, such as a hopped pair with a handful of reads, so that it shows rejected. Type a name under **Sample Name** for each pair you keep, such as HG002-lib1 for D701-D501, and click **Proceed**. The status line then reads "4 barcodes added to the plan. Demultiplex… opens Demultiplex Barcodes, which splits the reads by the index in their names."

4. Tick **Advanced** to see the plan as a table. Its **Output Name** column shows the name each sample's bundle will take, the typed name with spaces, commas, quotes, and slashes turned into underscores.

    <!-- SHOT: demux-tab-detect-barcodes -->

5. Click **Demultiplex…**. LGE writes the plan into the project's `Barcode Definitions` folder as a Custom Definition and opens Demultiplex Barcodes with that file chosen and **Engine** set to Read Names. Click **Run** there.

The command-line scout of this pool, which makes the same count, scanned the first 10,000 reads and assigned 9,924 of them (99.2 percent). It accepted the four true pairs, with 3,588, 2,736, 2,216, and 1,358 reads, and three hopped pairs, D701-D502 and D702-D503 with 6 reads each and D703-D501 with 4, each 0.04 to 0.06 percent of the reads. It rejected five more pairs with 2 reads each. Reject the three hopped pairs in step 3, since no library owns them. The **Accept ≥** and **Reject ≤** boxes of the sheet do nothing for a count from the read names, because such a count is accepted only above its chance bound.

### Demultiplex an Illumina dual-index pool with the Read Names engine

This route splits the same pool straight from the Tools menu, with `kit.csv` as the Custom Definition of the four index pairs.

1. Click the paired pool bundle and choose **Tools > Demultiplexing > Demultiplex Barcodes…**. The FASTQ/FASTA Operations dialog opens on its Demultiplex Barcodes pane, with the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

2. Set **Barcode Source** to Custom Definition. In the Inputs section, click **Choose…** on the **Barcode Definition** row and pick `kit.csv`. An info button beside **Barcode Source** explains the file's format.

3. Set **Engine** to Read Names. The pane shows no other barcode control, because a split by read names searches no bases and trims nothing.

4. Click **Run**.

Four bundles named for the `id` column, `D701-D501` to `D704-D504`, appear nested under the pool bundle with an `unassigned` bundle beside them, and each records its library's name from the `sample_name` column. Leaving **Engine** on Cutadapt would take the same route here, since Cutadapt reads the read names first, but choosing Read Names makes that choice yours.

### Demultiplex a pooled nanopore bundle with Cutadapt

MinKNOW usually splits a barcoded run for you, as [Oxford Nanopore Runs](07-ont-runs.md#procedure) shows. Three situations leave the split to you. MinKNOW may have written one undivided `fastq_pass` folder with no barcode folders. The run may have used barcodes MinKNOW does not know. Or the library may carry a second, inner barcode behind the outer one MinKNOW read. The `nrg1-pooled` bundle stands for the first case.

1. Click the `nrg1-pooled` bundle under `Imports` in the sidebar.

2. Choose **Tools > Demultiplexing > Demultiplex Barcodes…**.

3. Leave **Barcode Source** on Built-In Kit and change **Built-In Kit**, which starts on ONT Native Barcoding (NBD104/NBD114, 24) for nanopore reads, to ONT Native Barcoding V14 (SQK-NBD114-96, 96), the kit the library was made with. The pane hides **Location** and both distances and shows this caption in their place. "If the kit puts barcodes at both ends, both must carry the same barcode. Otherwise, one barcode at either end is enough. Location and distance settings do not apply."

    <!-- SHOT: demultiplex-barcodes-pane -->

4. Leave **Engine** on Cutadapt, **Error Rate** at 0.15, and **Trim Barcodes** on, then click **Run**.

When the run finishes, one bundle per barcode that received reads appears nested under `nrg1-pooled` in the sidebar, named by the barcode's identifier, from `NB85` to `NB91`, with an `unassigned` bundle beside them for reads that matched no barcode. On disk they sit in a `demux` folder inside the `nrg1-pooled` bundle. Running Demultiplex Barcodes on the same bundle again keeps the earlier split and writes the new one beside it in `demux-2`, then `demux-3`, and the sidebar lists the bundles of every run, with the folder name shown under the names from a later run. Each barcode bundle can be a [virtual bundle](../../GLOSSARY.md#virtual-bundle), which stores a recipe for its reads rather than a copy, as [Virtual bundles](06-subsetting-and-extraction.md#virtual-bundles) explains. A run writes its bundles into a hidden folder first and moves them into place only when it finishes, so a run that fails or that you cancel leaves no barcode bundle behind.

### Demultiplex with a custom definition and the Exact Bare Barcode engine

This run sends the same reads through the exact engine, with the six barcodes of `nrg1-barcodes.csv`.

1. With `nrg1-pooled` selected, choose **Tools > Demultiplexing > Demultiplex Barcodes…** and set **Barcode Source** to Custom Definition.

2. On the **Barcode Definition** row of the Inputs section, choose `nrg1-barcodes.csv` from the **Project File** menu, which lists the definition files already in the project, or click **Choose…** and pick it.

3. Set **Engine** to Exact Bare Barcode. The caption under it warns that this engine does not check for chance matches, so use it only on reads that carry the barcodes in their sequence.

4. Click **Run**.

The bundles take their names from the `id` column, `NB85` to `NB91`, and record the `sample_name` column, such as `IPSC-progenitors-long` for NB85, as each bundle's sample name. The engine never trims, so every read keeps its adapter and barcode.

### Demultiplex paired short reads

Demultiplex Barcodes keeps the two mates of each pair together on every engine, with one call for the whole fragment. A pair whose mates carry the same barcode goes to that barcode, and so does a pair in which only one mate carries a barcode. A pair whose mates carry different barcodes goes to `unassigned` whole, as the input held it, because its two mates name two different samples. Merged reads and reads whose mate is missing keep their own call. No pair is ever split between two bundles, whether the bundles hold their reads or are virtual.

The split of the Illumina pool called both mates alike in 9,838 pairs, the pairs of its four bundles. The command-line summary counts pairs called alike, placed by one mate, and sent to `unassigned` in its `Mate pairs` line, and `demux-manifest.json` records the same counts under `mateCalls`, as [File Formats](../appendices/file-formats.md#the-read-dataset-bundle) lists.

### Check barcodes with barcode scout before you commit

The [barcode scout](../../GLOSSARY.md#barcode-scout) is the count behind **Detect**, and `lungfish-cli fastq scout` runs it from [Terminal](../../GLOSSARY.md#terminal), the macOS window for typed commands, writing `scout-result.json` with each barcode's hits and a mark of accepted, rejected, or undecided. A count from the read names is accepted only above its chance bound, the most reads that chance alone would give that barcode. A search of the read bases accepts a barcode with 10 hits or more, rejects one with 3 or fewer, and leaves the rest undecided, which usually means a real sample with few reads. The command reads the first 10,000 reads unless `--read-limit` names another number, and it refuses Ultima and MGI kits, and a file whose read names hold no index, with words that say so. Run it to confirm the kit before a long demultiplex, as [On the command line](#on-the-command-line) shows.

## Settings

The pane shows only the controls that the chosen engine and kit use. **Location**, **5' Distance**, **3' Distance**, **Error Rate**, and **Trim Barcodes** appear only while **Engine** is Cutadapt, and a long-read kit hides **Location** and both distances too. **Keep Unchecked Samples** appears only for a run that the check for chance matches would otherwise refuse. With Read Names the pane shows nothing past **Engine** but **Output Strategy**.

**Barcode Source.** Chooses where the barcode sequences come from, offering Built-In Kit and Custom Definition. The default is Built-In Kit, which covers the commercial kits most libraries use. Pick Custom Definition when the barcodes came from an index sheet, a plate layout, or an in-house primer set, then choose the file on the **Barcode Definition** row of the Inputs section. On the command line this is `--kit`.

**Built-In Kit.** Names the commercial barcode set the library was tagged with, from twenty kits, a list that narrows with Exact Bare Barcode to the kits that engine can match. The default follows the reads' platform, so nanopore reads start on ONT Native Barcoding (NBD104/NBD114, 24), Illumina and PacBio reads start on their platform's first kit, and mixed or undetected reads start on TruSeq Single Index Set A (D701-D712). Set it to the kit named on the kit box or in the library preparation record, because a wrong kit sends almost every read to Unassigned, and use a Custom Definition of your index sheet in place of IDT for Illumina UD Indexes (96 pairs), which every route refuses until its built-in table is checked. On the command line this is `--kit`.

**Engine.** Chooses how each read's barcode is found, offering Cutadapt, Exact Bare Barcode, and Read Names, which the info button beside it compares. The default is Cutadapt, which tolerates errors and indels, and which first reads the read names of an Illumina-family kit or a Custom Definition and splits by them when they carry the indexes of two or more of the kit's barcodes. Choose Read Names for files whose index sits only in the read names, and Exact Bare Barcode for plain barcodes that sit at no fixed place in reads that carry them. On the command line this is `--engine`.

**Location.** Tells Cutadapt which end of the read a barcode may sit at, offering Both Ends, 5' End, and 3' End, where 5' is the start of the read and 3' its end. The default is Both Ends, the only choice that a dual-index kit or a Custom Definition with second sequences accepts, because such a pair is found with its first barcode at the start of the read and its second at the end. Narrow it to one end only for single barcodes that the library puts at that end. On the command line this is `--location`.

**5' Distance.** Sets how many bases in from the start of the read a barcode may begin. The default is 0, which means the barcode must start at the very first base, as it does in a clean short-read library. Raise it to the number of bases your barcodes sit in from the start, as when part of an adapter comes before them, and know that above 0 a read stays in a sample only when that sample's barcode fits it better than any other's, so a read that two samples fit equally well goes to Unassigned. On the command line this is `--max-distance-5prime`.

**3' Distance.** Sets how many bases in from the end of the read a barcode may end. The default is 0, which means the barcode must end at the very last base. Raise it to the number of bases that follow your barcodes, and for a dual-index Custom Definition, whose two distances serve both strands, use the longer of the two for both when the ends differ. On the command line this is `--max-distance-3prime`.

**Error Rate.** Sets the fraction of barcode bases that may be wrong in a match, so at 0.15 a 20-base barcode tolerates three wrong bases and an 8-base Illumina index tolerates one. The default is 0.15, loose enough for nanopore errors without letting similar barcodes blur together. Lower it toward 0.05 when samples cross-assign, and raise it when a large share of reads lands in Unassigned. On the command line this is `--error-rate`.

**Trim Barcodes.** Removes the matched barcode, and for a nanopore kit the adapter around it, from the start of each read before writing it out, while for a kit that tags both ends the copy at the far end of the read stays in it. It starts on, so each read begins with the sample's own sequence. Turn it off when a later step needs the barcode still in the read, such as a second demultiplex on an inner barcode, and every read then stays whole in every bundle, virtual bundles included. On the command line this is `--no-trim`.

**Keep Unchecked Samples.** Makes the sample files of a run that LGE would otherwise refuse because its check for chance matches cannot judge the samples, either a Cutadapt search whose barcodes match about half of all reads or more by chance, as the Fluidigm Access Array kit and very short custom barcodes do, or an Exact Bare Barcode run whose read names carry two or more of the kit's barcodes. It starts off, so such a run stops before it writes anything, and the caption under the box points to a better route, such as the Read Names engine or ONT Fluidigm Sample Split. Tick it only when you know the read bases carry these barcodes, then check every sample against your sample sheet. On the command line this is `--keep-unchecked-samples`.

**Output Strategy.** Chooses Per Input, which saves each selected bundle's split as a result of its own, or Grouped Result, which keeps the splits of all the selected bundles together in one result folder with one sub-folder for each input. The default is Per Input, and either way each bundle is split on its own, so reads from different bundles are never pooled. Keep Per Input unless you want the splits of a batch kept together in one place. This setting has no command-line flag.

## Reading the results

Click a barcode bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. The Operations Panel row of each run shows the command the run recorded, with your input and the run folder, and **Copy CLI Command** in the row's context menu copies a command you can run again, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. The run's [provenance](../../GLOSSARY.md#provenance) record names the bundle you picked. When that bundle is a [derived bundle](../../GLOSSARY.md#derived-bundle), such as a subsample or a trimmed set, each barcode bundle reads its reads from it, so keep the bundle you picked.

The Illumina pool's split with `kit.csv` read 19,916 reads. Each library's row counts its bundle in reads and in read pairs, and the Assigned row gives the share of all reads that reached a sample.

| Library | Index pair | Reads | Read pairs |
|---|---|---|---|
| HG002-lib1 | D701-D501 | 7,118 | 3,559 |
| HG002-lib2 | D702-D502 | 5,528 | 2,764 |
| HG002-lib3 | D703-D503 | 4,342 | 2,171 |
| HG002-lib4 | D704-D504 | 2,688 | 1,344 |
| Assigned | | 19,676 (98.8%) | 9,838 |
| Unassigned | | 240 | 120 |

Checked against the truth table, every read in each bundle belongs to the library the bundle is named for, so no read went to a wrong library. The bundles hold the pairs whose index was exact or one base off. The 240 unassigned reads are the 30 hopped pairs and the 90 pairs with two wrong bases in one index, which the one-mismatch rule cannot place. With the whole built-in TruSeq HT Dual Index (96 combinations) kit in place of `kit.csv`, the split gave the same four bundles with the same reads, plus ten small bundles of 2 to 12 reads named for the hopped combinations, such as `D701-D502` with 12 reads. Only the 180 reads of the two-mismatch pairs then stayed unassigned. A split by a whole kit therefore leaves small extra bundles to drop, and a split by your own list of pairs leaves them in Unassigned for you.

### The chance floor and the run summary

A search of the read bases can find a barcode in a read that carries none, by chance, the way a short word turns up inside a long text. The shorter the barcode and the higher the Error Rate, the more often that happens. For each barcode, the chance floor is the largest number of reads that chance alone would give it, worked out from the barcode and the Error Rate and measured on the first bases of the run's own unassigned reads, which carry no barcode. A barcode beats the floor only when its read count lies above that number at odds below one in a million for the whole kit. A run in which no barcode beats the floor stops and makes no sample files, with a message that starts "No barcode of" and names the kit. A barcode that has reads but does not beat the floor keeps its file, and the run names it as a possible chance match.

Each route checks chance in its own way.

| Route | What checks chance | What the run says |
|---|---|---|
| Cutadapt with an Illumina-family kit or a Custom Definition | The chance floor | The row's line starts "Some barcodes could be chance matches." when a barcode sits within the floor, and "Check samples with few reads against your sample sheet." otherwise |
| Cutadapt with a long-read kit | Nothing, since the adapter around each barcode makes a chance match far rarer than one read | No chance words |
| Read Names | Detect and the automatic choice of route count a barcode in the read names only above its chance bound | A run whose read names carry no index of the kit stops with no files |
| Exact Bare Barcode | Nothing | The row's line starts "Not checked for chance matches." |

A warning turns the finished row into Completed with Warnings, and the row's Log holds the warning in full. For a barcode within the floor, it starts `Could be chance matches:` and names each such barcode with its reads.

The floor has one limit it cannot close, which the Log of every run that passed it states. A barcode that is not in your pool can still pass as a sample, in about one run in 1,000 for each such barcode, and more often in an amplicon file, whose reads are PCR copies of a few targets and so share their first bases. Such a false sample holds a few reads, as a real small sample does, so check every sample with few reads against your sample sheet.

<!-- SHOT: demultiplex-chance-summary -->

The `lungfish-cli fastq demultiplex` summary prints the same chance lines after its `Barcodes with reads:` line, and its `Barcodes read from:` line names the route that ran, such as `the index in each read name, at most one mismatch in each index (header-index)`.

### The demultiplex of the pooled nanopore bundle

The pooled bundle holds 400 reads from each of the six samples. The Exact Bare Barcode run with `nrg1-barcodes.csv` gave these counts, in reads.

| Barcode | Sample name | Reads |
|---|---|---|
| NB85 | IPSC-progenitors-long | 339 |
| NB86 | IPSC-macrophages-long | 332 |
| NB87 | monocytes-long | 305 |
| NB89 | IPSC-progenitors-short | 348 |
| NB90 | IPSC-macrophages-short | 286 |
| NB91 | monocytes-short | 311 |
| Assigned | | 1,921 (80.0%) |
| Unassigned | | 479 |

Every one of the 2,400 reads is accounted for, as assigned or unassigned, and every assigned read went to the barcode its run accession names. The 479 unassigned reads carry at least one basecalling error in the barcode at both ends, which an exact search cannot forgive. The exact engine also left the adapter and barcode on every read. Read the Cutadapt run of the same reads the same way, barcode by barcode against the 400 reads each sample put in. Its error tolerance can place reads whose barcodes carry a few errors, and it trims the adapter and barcode off the start of each assigned read, while the copy at the far end stays.

### Unassigned reads and Keep Unchecked Samples

Keep `unassigned` distinct from [`unclassified`](../../GLOSSARY.md#unclassified-reads). MinKNOW writes `unclassified` during the run, while LGE writes `unassigned.lungfishfastq` during a demultiplex, so the two hold reads that failed at different steps. LGE keeps the `unassigned` bundle so you can look inside it, and what lands there depends on the engine.

| Engine | A read goes to `unassigned` when |
|---|---|
| Read Names | Its index matches no barcode or two of them, differs from a barcode by two or more bases in one index, or carries i5 in the other direction from most of its file |
| Cutadapt | No barcode fits within the Error Rate, or, with a distance above 0, two samples' barcodes fit it equally well |
| Exact Bare Barcode | No barcode appears in it letter for letter |
| Every engine | Its two mates name two different samples |

A run you kept with **Keep Unchecked Samples** makes its sample files with no chance check behind them. Its row says so, with "The check for chance matches could not check this kit." for a Cutadapt run or "Not checked for chance matches." for an Exact Bare Barcode run. Treat each of its samples as unchecked until it matches your sample sheet.

## What good looks like

Confirm the number of sample bundles against your sample sheet. Each barcode with reads gets a bundle, so a bundle for a barcode you never used holds hopped or chance-matched reads, like the ten small bundles of the Illumina pool's split by the whole kit.

Confirm that most reads were assigned. The Assigned share is the percent of all reads that reached a sample. The Illumina pool reached 98.8 percent, and the nanopore pool reached 80 percent with the exact engine, whose losses are basecalling errors in the barcodes. A large unassigned share points at the wrong kit, an Error Rate too strict for the reads, barcodes that sit further in than the distances allow, or reads that carry no barcode at all, and Detect or the scout tells those cases apart.

Confirm the sizes of the samples against the pooling plan. Samples pooled in equal amounts rarely come out even, but one sample far below the rest, or one holding almost everything, points at a failure at the bench or at the wrong kit. The Illumina libraries hold 1,344 to 3,559 pairs because they were drawn that way, and the six nanopore samples kept 286 to 348 of their 400 reads each.

Confirm that the run's row carries no chance warning, and check every barcode a warning names. Even an exact match is no proof of a sample. When the fixture's full 6,000 nanopore reads were pooled the same way, the exact engine assigned 4,733 of them and put one in the wrong sample.

### When a run stops

A run that stops publishes no sample file, so your project keeps no half-made split. Its message names the cause and what to try.

| The message says | What it means | What to change |
|---|---|---|
| No barcode of the kit matched more reads than chance alone gives | No barcode beat the chance floor | Choose the kit the library was made with, check the barcode sequences, or set the distances to where the barcodes sit |
| No read name carried an index of the kit | Read Names found no index of this kit in the names | Choose the kit the library was made with, or search the read sequences with Cutadapt |
| The kit has its first index at the start of a read and its second at the end, so it can be searched only at Both Ends | A dual-index kit or definition was set to one end | Set **Location** to Both Ends |
| The built-in sequences for IDT for Illumina UD Indexes (96 pairs) are being checked | That kit's table is off for now | Enter your index pairs in a Custom Definition |
| That is more than the 6,000 a run can take | Too many barcodes, strands, and distances to search at once, such as 96 pairs with both distances at 5 | Trim the adapter around the barcodes first, or lower the distances |
| The read names carry 2 of the barcodes of the kit | Exact Bare Barcode would find them in the bases only by chance | Choose Read Names |
| The check for chance matches cannot tell this pool from reads that carry no barcode, and nothing was run | The barcodes match about half of all reads or more by chance | Use ONT Fluidigm Sample Split or Read Names, or tick **Keep Unchecked Samples** |
| Barcodes A and B differ at 2 bases, so one read error could give a read the wrong sample | One read error could give a read the wrong sample | Correct the definition, or remove one of the two barcodes |

## On the command line

The block follows [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Demultiplexing and Oxford Nanopore runs](../appendices/cli-reference.md#demultiplexing-and-oxford-nanopore-runs) in the CLI Reference lists every flag of these commands. Set `POOL` to the folder that holds the Illumina fixture's files. If you already imported the pool in the window, skip the import and change `reads.lungfishfastq` to your bundle's name if it differs.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"
POOL="$HOME/Downloads/illumina-dual-index-pool"

# Import the Illumina pool as one paired bundle.
lungfish-cli import fastq "$POOL/reads_R1.fastq.gz" "$POOL/reads_R2.fastq.gz" \
  --project "$PROJECT"

# Count the kit's index pairs in the first 10,000 reads, as Detect does.
lungfish-cli fastq scout "$PROJECT/Imports/reads.lungfishfastq" --kit truseq-ht-dual \
  --output "$HOME/Desktop/pool-scout.json"

# Split the pool by the indexes in its read names.
lungfish-cli fastq demultiplex "$PROJECT/Imports/reads.lungfishfastq" \
  --kit "$POOL/kit.csv" --engine header-index -o "$PROJECT/Analyses/pool-read-names"

# Split the nanopore pool with the built-in kit.
lungfish-cli fastq demultiplex "$PROJECT/Imports/nrg1-pooled.lungfishfastq" \
  --kit ont-nbd114-96 -o "$PROJECT/Analyses/nrg1-cutadapt"

# Split it again with the custom definition and the exact engine.
lungfish-cli fastq demultiplex "$PROJECT/Imports/nrg1-pooled.lungfishfastq" \
  --kit "$PROJECT/Practice Data/nrg1-ont-barcoded/nrg1-barcodes.csv" \
  --engine exact-bare -o "$PROJECT/Analyses/nrg1-exact"
```

The engines are written `cutadapt`, `exact-bare`, and `header-index` on the command line. With no `--engine`, `fastq demultiplex` reads the first read names and splits by them when they carry the indexes of two or more of the kit's barcodes, and it searches the read bases with Cutadapt otherwise. Name `--engine cutadapt` to force the search of the read bases. A Cutadapt run needs its output folder inside a project, which is why the block writes into `$PROJECT/Analyses`. `fastq demultiplex` writes its bundles into the folder `-o` names rather than into the input bundle, and it refuses a folder that already holds files, naming them, unless you add `--replace`. Even then it refuses a folder that holds the input or anything else the run reads. With `--replace` it makes every check first, sets the old contents aside, removes them once the new bundles are in place, and puts them back if the run fails.

## Next

Continue to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md), the first chapter of the Alignments part, because lining each sample's reads up against a reference genome is where most analyses of a split pool go next. For run folders and the Fluidigm split, see [Oxford Nanopore Runs](07-ont-runs.md), and to merge or orient reads before mapping, see [Read Processing](08-read-processing.md).

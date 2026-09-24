---
title: Trimming and Filtering Reads
chapter_id: 03-reads/04-trimming-and-filtering
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq, 03-reads/03-quality-control]
estimated_reading_min: 21
task: Trim adapters, low-quality bases, primers, and fixed base counts from FASTQ reads, and filter the survivors by length.
tags: [reads, trim, adapter, primer, length, filter, fastp, bbduk, cutadapt, seqkit]
tools: [fastp, bbduk, cutadapt, seqkit]
parameters_refs: [fastq.fastp-trim, fastq.quality-trim, fastq.adapter-removal, fastq.primer-trimming, fastq.trim-fixed-bases, fastq.filter-by-read-length]
entry_points:
  - "Tools > Trimming & Filtering > (pick the operation)"
  - "CLI: lungfish-cli fastq trim, quality-trim, adapter-trim, primer-remove, fixed-trim, length-filter"
shots:
  - id: trimming-dialog
    caption: "The FASTQ/FASTA Operations window on the fastp Adapter + Quality Trim pane at its defaults, with Threshold 20, Window Size 4, Mode on Cut Right, and Adapter Mode on Auto-Detect."
  - id: primer-trimming-literal-pane
    caption: "The Primer Trimming pane with Primer Source on Literal Sequence, showing the Primer Sequence field above the three compact fields labelled k, mink, and hdist."
  - id: length-filter-readiness
    caption: "The Filter by Read Length pane with both bounds empty, showing the readiness line reading Enter a minimum, a maximum, or both."
illustrations: []
glossary_refs: [fastq, phred-score, basecaller, read-length, adapter, library-prep, fastp, bbduk, cutadapt, seqkit, sliding-window-trimming, k-mer, hamming-distance, umi, amplicon, shotgun, primer, primer-scheme, primer-trim, paired-end, mapping, variant-caller, required-setup-pack, provenance, checksum, bundle, chimera]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Trimming means cutting bases off the ends of reads. Filtering means throwing whole reads away. Both remove sequence that came from the laboratory rather than from the organism, and both happen before you [map](../../GLOSSARY.md#mapping) the reads, meaning before you match each read to the spot in a reference genome it came from.

Reads arrive carrying four kinds of unwanted sequence. The first is low-quality bases. [Phred scores](../../GLOSSARY.md#phred-score) are explained in [Quality Control for Reads](03-quality-control.md#q20-and-q30). The [base caller](../../GLOSSARY.md#basecaller), the instrument software that turns raw signal into letters, writes one beside every base, and on Illumina reads the scores fall toward the end of the read.

The second is adapter. [Library preparation](../../GLOSSARY.md#library-prep), the bench steps that turn extracted DNA into machine-ready fragments, attaches a short synthetic [adapter](../../GLOSSARY.md#adapter) to each end of every fragment. When a fragment is shorter than the [read length](../../GLOSSARY.md#read-length), the instrument reads past the end of the fragment and into the adapter, so adapter letters land in your data.

The third is [primer](../../GLOSSARY.md#primer) sequence, the short synthetic DNA that started each PCR product, which appears only in libraries built by PCR. The fourth is reads too short to place on a genome with confidence.

Lungfish Genome Explorer (LGE) gives each problem its own operation. Six operations sit under **Tools > Trimming & Filtering**. They are fastp Adapter + Quality Trim, Quality Trim, Adapter Removal, Primer Trimming, Trim Fixed Bases, and Filter by Read Length. Each reads a [FASTQ](../../GLOSSARY.md#fastq) bundle and writes a new one. The input is never changed, so a trim you regret costs disk space and nothing else.

Four programs do the work behind those six operations, which is why the settings change from one pane to the next.

| Program | What it does here |
|---|---|
| [fastp](../../GLOSSARY.md#fastp) | Quality trimming, adapter removal, and fixed-base trimming |
| [bbduk](../../GLOSSARY.md#bbduk) | Primer trimming when you type a primer sequence |
| [cutadapt](../../GLOSSARY.md#cutadapt) | Primer trimming when you choose a FASTA file of primers |
| [seqkit](../../GLOSSARY.md#seqkit) | The length filter |

So what should you do with this? Trim only what quality control showed you was there, then measure what the trim cost, because every operation removes some real sequence along with the artefact.

## Why you would do this

A read that ends in adapter may fail to map, or may map to the wrong place because the adapter happens to resemble some stretch of the genome. A low-quality tail produces false variant calls, because a [variant caller](../../GLOSSARY.md#variant-caller), the program that lists where a sample differs from the reference, counts a miscalled base as evidence just as readily as a real one. An untrimmed primer hides real variation, because primer sequence is synthetic and matches the reference whatever the sample carries at those positions.

Length filtering solves a different problem. Trimming shortens reads, and a very short read can match many places on a large genome equally well. Dropping those reads before mapping is cheaper than untangling ambiguous alignments afterwards.

This chapter works on a half-million-base slice of chromosome 20 from HG002, a human genome from the Genome in a Bottle project whose true sequence is already known. The reads are already good, which is deliberate. You need to know what a trim costs on clean data before you can recognise one that has gone wrong on bad data.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. Import both files as one sample by following [Importing Sequencing Reads](01-importing-fastq.md), so a single `HG002.chr20.10.0-10.5Mb` bundle appears in the sidebar.

fastp, bbduk, cutadapt, and seqkit arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. Reading [Quality Control for Reads](03-quality-control.md) first helps, because its summary cards are how you judge whether a trim helped.

## Procedure

The worked example runs the combined fastp pass on the imported bundle, then filters the result by length. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, and one window, titled FASTQ/FASTA Operations, serves all six operations.

### The combined adapter and quality trim

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar.

2. Choose **Tools > Trimming & Filtering > fastp Adapter + Quality Trim...**.

    <!-- SHOT: trimming-dialog -->

3. Leave **Threshold** at 20, **Window Size** at 4, **Mode** on Cut Right, and **Adapter Mode** on Auto-Detect. These defaults suit this data, and [Settings](#settings) explains when to change each one.

4. Leave **Output Strategy** on Per Input, which writes one trimmed bundle for the one bundle you selected.

5. Click Run.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. This run writes a bundle named `HG002.chr20.10.0-10.5Mb-fastpTrim`, the input's name with the operation added.

### The length filter

1. Click the new `HG002.chr20.10.0-10.5Mb-fastpTrim` bundle under `Analyses/` in the sidebar. The original bundle stays under `Imports/`.

2. Choose **Tools > Trimming & Filtering > Filter by Read Length...**.

3. Set **Min Length** to 50 and leave **Max Length** empty. Both fields start empty, and until one is filled the readiness line reads "Enter a minimum, a maximum, or both."

    <!-- SHOT: length-filter-readiness -->

4. Click Run.

The result, `HG002.chr20.10.0-10.5Mb-fastpTrim-lengthFilter`, also lands under `Analyses/`, and it is the bundle you hand to a mapper. Run the length filter last, because every other operation in this chapter can shorten reads and so change which reads fall below your minimum.

### Trimming a fixed number of bases

Use **Tools > Trimming & Filtering > Trim Fixed Bases...** when the library design puts the same number of unwanted bases on every read. A common case is a [UMI](../../GLOSSARY.md#umi), a short random barcode attached to each original molecule before amplification so that PCR copies of one molecule can later be told apart from separate molecules.

Set **5' Trim**, **3' Trim**, or both, then click Run. The 5' end is the start of the read and the 3' end is its end. This operation ignores quality and removes exactly the count you asked for from every read.

### Primer trimming at the read level

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome.

**Tools > Trimming & Filtering > Primer Trimming...** finds primer sequence in the text of each read and cuts it off, before any mapping. That fits a pipeline whose next tool reads FASTQ. When your next step is mapping and variant calling, [primer trimming](../../GLOSSARY.md#primer-trim) after mapping is the route [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) teaches.

<!-- SHOT: primer-trimming-literal-pane -->

The pane changes shape with **Primer Source**, and the two choices run different programs. Literal Sequence runs bbduk on one primer sequence you type, looking for exact matches of short words taken from the primer. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases, and [Running Kraken 2](../06-classification/02-running-kraken2.md#what-it-is) shows how tools match on them. The **k**, **mink**, and **hdist** fields tune that matching. Literal Sequence currently removes a read whose primer sits at its 5' start instead of trimming the primer off, so trim such primers after mapping instead. It still trims correctly when the primer sits at the 3' end of a read, because it cuts the match and everything after it. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

Reference FASTA runs cutadapt in linked mode on a FASTA file of primers, which you choose under **Primer Reference** in the Inputs section. Linked mode looks for the forward and reverse primer of one amplicon as a pair on the same read, which is what a tiled scheme of dozens of primers needs. The bbduk fields disappear, and the pane reads "Select the primer reference FASTA in the Inputs section."

The operation trims whatever sequence you give it, so a human amplicon panel works exactly as a viral one does. The HG002 reads are shotgun data with no primers in them, so this chapter has no worked primer-trimming result.

### Quality trimming and adapter removal on their own

The combined operation does both jobs in one fastp pass and is the right first choice. **Tools > Trimming & Filtering > Quality Trim...** trims quality and leaves adapters alone, and it is the only one of the six panes with an **Extra arguments** field. **Tools > Trimming & Filtering > Adapter Removal...** removes adapters and leaves quality alone.

### FASTA input

Adapter Removal, Primer Trimming, Trim Fixed Bases, and Filter by Read Length also accept FASTA files, which hold sequence without quality scores. When every file you selected is FASTA, fastp Adapter + Quality Trim and Quality Trim leave the list altogether, because there are no quality scores for them to read.

## Settings

Several labels appear on more than one pane. Each is described once, and the heading above it names the panes that show it.

### Quality settings (fastp Adapter + Quality Trim, Quality Trim)

**Threshold.** Sets the lowest Phred score a base may have before fastp treats it as unreliable. The default is 20, one expected error in a hundred bases, the usual floor for Illumina data. Raise it toward 30 when you need very clean bases for variant calling, and lower it when trimming discards too much of every read. On the command line this is `--threshold`.

**Window Size.** Sets how many neighbouring bases fastp averages before deciding to cut, which makes this [sliding-window trimming](../../GLOSSARY.md#sliding-window-trimming) rather than a base-by-base cut. The default is 4, wide enough that one bad base does not end an otherwise good read. Use a larger window for long reads whose quality drifts slowly, and a smaller one for a sharp quality drop at the read end. On the command line this is `--window`.

**Mode.** Chooses where fastp cuts, offering Cut Right, Cut Front, Cut Tail, and Cut Both. The default is Cut Right, which suits the usual Illumina pattern of good bases early and poor bases late. Switch to Cut Both when quality is poor at both ends of the read. On the command line this is `--mode`.

The names describe where the cut lands, not where the scan starts. Picture the read written left to right, with its start on the left.

| Mode | What it does |
|---|---|
| Cut Right | Walks from the start and cuts everything from the first bad window rightward |
| Cut Front | Cuts bad bases off the start and stops at the first good window |
| Cut Tail | Cuts bad bases off the end, working backwards from the last base |
| Cut Both | Applies Cut Front and then Cut Right, trimming both ends |

Threshold and Window Size must both be above 0. Otherwise the readiness line reads "Enter a positive quality threshold and window size."

### Adapter settings (fastp Adapter + Quality Trim, Adapter Removal)

**Adapter Mode.** Chooses whether fastp works out the adapter from the reads or uses a sequence you type, offering Auto-Detect and Manual Sequence. The default is Auto-Detect, which looks for sequence shared by many reads and is right whenever you do not know your kit's adapter. Use Manual Sequence when you know the exact adapter from the kit and auto-detection misses it. On the command line this is `--adapter`.

**Adapter Sequence.** Holds the one adapter sequence fastp removes, written in A, C, G, T and the IUPAC ambiguity letters, which stand for more than one base, such as N for any base. It starts empty and appears only while Adapter Mode is Manual Sequence. Fill it in from your kit's documentation when auto-detection does not find the adapter. On the command line this is `--adapter`.

While Manual Sequence is chosen and the field is empty, the readiness line reads "Enter an adapter sequence or switch to auto-detect." on the combined pane and "Enter an adapter sequence for manual adapter removal." on the Adapter Removal pane.

### Primer Trimming

**Primer Source.** Chooses between typing one primer and choosing a FASTA file that holds a whole primer set, offering Literal Sequence and Reference FASTA. The default is Literal Sequence, which runs bbduk. Pick Reference FASTA, which runs cutadapt, for a tiled amplicon scheme with dozens of primers. On the command line this is `--literal` or `--ref`.

**Primer Sequence.** Holds the primer bbduk removes, written in A, C, G, T and the IUPAC ambiguity letters. It starts empty, and while it is empty the readiness line reads "Enter a literal primer sequence or switch to reference mode." Type the primer exactly as your primer order sheet gives it. On the command line this is `--literal`.

**k.** Sets the length of the exact-match word bbduk uses to spot the primer. The default is 15, since four possible bases at fifteen positions give about a billion different words, so a chance match is unlikely, while the word is still short enough to fit inside most primers. Shorten it when short primers are being missed, and lengthen it when non-primer sequence is being trimmed. On the command line this is `--kmer`.

**mink.** Sets the shortest word bbduk still matches when only part of a primer sits at the very end of a read, so a primer that runs off the edge is still caught. The default is 11, comfortably below k, so partial primers are found without letting very short chance matches through. Lower it toward 8 when partial primers survive at read ends. On the command line this is `--mink`.

**hdist.** Sets how many mismatched bases a primer match may contain, the [Hamming distance](../../GLOSSARY.md#hamming-distance) between primer and read, which counts positions where two equal-length sequences differ. The default is 1, which tolerates one sequencing error or one real variant inside the primer. Raise it to 2 for noisy long reads, and drop it to 0 when trimming is removing real sequence. On the command line this is `--hdist`.

### Trim Fixed Bases

**5' Trim.** Sets how many bases are cut from the start of every read, whatever those bases are. The default is 0, so nothing is cut until you ask, because a fixed trim is right only when the library design says so. Set it when the design puts a fixed tag or a UMI at the start of each read. On the command line this is `--front`.

**3' Trim.** Sets how many bases are cut from the end of every read. The default is 0, for the same reason. Set it when a known number of trailing bases are unreliable. On the command line this is `--tail`.

While both are 0 the readiness line reads "Enter at least one fixed trim amount." There is no quality check and no length guard, so a 5' Trim of 40 on a 35-base read leaves nothing behind.

### Filter by Read Length

**Min Length.** Sets the shortest read kept, in bases. It starts empty, meaning no lower bound, so the filter does nothing until you fill in at least one of the two fields. Use 30 to 50 for general short-read work, and for an amplicon protocol use your amplicon length or a little below it, which drops adapter dimer, two adapters joined with no sample DNA between them. On the command line this is `--min`.

**Max Length.** Sets the longest read kept, in bases. It starts empty, meaning no upper bound, which is right for Illumina data because the instrument already caps read length. Set it on long-read data when reads far above the expected size appear, which are usually concatemers, several copies of one fragment joined end to end, or [chimeras](../../GLOSSARY.md#chimera), two unrelated fragments joined into one read. On the command line this is `--max`.

A minimum larger than the maximum makes the readiness line read "Minimum read length cannot exceed maximum read length." The filter judges each read on its own, so when one mate of a pair falls below the minimum the other can survive alone. Keep the minimum low enough that few pairs are broken.

### Shared settings

**Output Strategy.** Chooses whether each selected bundle gets its own output or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, which keeps samples apart and is right whenever the selected bundles are different samples. Choose Grouped Result only when the selected bundles are pieces of one library, as [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) explains. This setting has no command-line flag.

**Extra arguments.** Passes text straight to fastp without LGE checking it. The default is empty, which is right for almost every run. Use it only for a fastp option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

Only the Quality Trim pane shows Extra arguments. The combined pane has no such field, although the command-line `fastq trim` accepts `--extra-args`.

## Reading the results

Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. LGE computes the new bundle's summary as it writes the bundle, so the cards are filled when the bundle appears. Three cards matter here. Reads is how many records the bundle holds, Bases is the total number of letters across them, and Mean Length is Bases divided by Reads.

[Quality Control for Reads](03-quality-control.md) judged these reads fine, so the trim here is practice. You need to know what a trim costs on clean data before you can recognise one that has gone wrong. Run in the window on the paired bundle, the procedure above turns 91,148 reads and 22,662,846 bases into 90,898 reads and 20,295,478 bases, and the length filter then keeps 88,508 reads. The table below and the runs after it come from the R1 file alone, run with the commands in [On the command line](#on-the-command-line), so they count the first read of each pair only. Second reads carry lower quality, so the paired run loses a little more.

| Measure | Before | After fastp Adapter + Quality Trim |
|---|---|---|
| Reads | 45,574 | 45,534 |
| Bases | 11,331,492 | 10,540,866 |
| Mean read length | 248.6 bases | 231.5 bases |
| Shortest read | 50 bases | 1 base |

Read the table from top to bottom. 45,534 of 45,574 reads survived, which is 99.91 percent, so only 40 reads were removed outright. Bases fell to 93.0 percent of the original, so the trim cost 7.0 percent of the sequence while costing almost no reads.

The gap between those two survival figures is the sign of a healthy trim. A gap of 6.9 percentage points between reads kept and bases kept means the trim took a tail off many reads rather than removing many reads. The mean length says the same thing in a different unit. On a 250-base run the average read lost about seventeen bases, which is the low-quality tail the Phred scores had already flagged.

The shortest read shows the cost. It falls from 50 bases to 1. R1's shortest read is 50 bases, while the 35-base read that [Quality Control for Reads](03-quality-control.md) reports sits in R2. A one-base read is a read whose quality collapsed near its start, cut back to almost nothing and kept. 677 reads came out shorter than 50 bases, which is why the length filter exists and why it runs after the trim. Filtering at a 50-base minimum kept 44,857 reads, 98.51 percent of the 45,534 that went into the filter and 98.43 percent of the original 45,574.

Three more runs on the same file show what the settings do.

- Adapter Removal alone changed nothing, returning all 45,574 reads and all 11,331,492 bases, because these reads carry no adapter for auto-detection to find.
- Quality Trim alone gave exactly the combined operation's 45,534 reads and 10,540,866 bases, so every base the combined pass removed was removed for quality.
- Quality Trim at a Threshold of 30 kept 44,916 reads and 8,947,205 bases. Ten more points of threshold cost a further 1.59 million bases of real human sequence, 15.1 percent of what the Q20 trim had left.

Trim Fixed Bases with **5' Trim** set to 10 removed exactly 455,740 bases, ten bases times 45,574 reads, and kept every read.

To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains.

## What good looks like

Compare the trimmed bundle's cards and charts against the input's. The viewport shows one bundle at a time, so note the input's figures first, then click the output. Apply these checks in order.

**The quality chart.** The chart labelled Q / Position plots quality along the read. After a trim at a Threshold of 20 it should no longer dip below Q20 at the read end, where Q20 is the same Phred score of 20.

**Read survival.** For typical Illumina data expect 90 percent or more of reads to survive a quality trim, and this example's 99.91 percent sits well inside that. Survival below about 70 percent means the Threshold is too harsh for the data. Lower it rather than accept the loss.

**Bases against reads.** Reads surviving while bases fall is a trim working correctly. Reads and bases falling together in similar proportion means whole reads are being discarded, which points at a Threshold set for cleaner data than you have.

**The output location.** The trimmed bundle sits under `Analyses/`, named for its input and the operation. A result anywhere else came from a different route than the one you meant to take.

### When a trim goes wrong

**Too few reads survive.** When survival after quality trimming falls below about 70 percent, the Q20 floor is probably too harsh. Re-run at a Threshold of 15, which accepts bases expected to be wrong about once in 32, and compare the two. Long reads sit far lower on the Phred scale by nature and should never be trimmed against an Illumina threshold. When survival drops sharply after the length filter instead, the Min Length is too high for a run that made short reads on purpose, so lower it or skip the filter.

**Low quality persists after trimming.** When the Q / Position chart still dips below Q20 at the read ends, the four-base window probably averaged over isolated bad bases. A Window Size of 1 judges each base on its own and clears them, at the cost of a more aggressive cut. Use 1 as a diagnostic when the chart is flat and healthy apart from isolated downward spikes, and keep 4 when quality declines steadily toward the read end, the ordinary case.

**Adapter still suspected after Adapter Removal.** Auto-detection can miss an adapter it has too few examples of, and the app does not report which adapter fastp settled on. Re-run with **Adapter Mode** set to Manual Sequence and paste your kit's adapter.

**Primer bases visible after read-level primer trimming.** bbduk tolerates one mismatch by default, so a read carrying a real variant plus a sequencing error inside the primer can slip through untrimmed. Raising **hdist** helps a little and costs specificity. The lasting fix is primer trimming after mapping, covered in [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md), which matches on position rather than sequence.

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

Each command works on one file, so the block below trims R1 only. A backslash at the end of a line means the command continues on the next line.

```bash
# The combined adapter and quality pass, at the dialog's defaults.
lungfish-cli fastq trim HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --threshold 20 --window 4 --mode cut-right \
  --output R1.trim.fastq

# Drop everything under 50 bases, last of all.
lungfish-cli fastq length-filter R1.trim.fastq \
  --min 50 --output R1.trim.len50.fastq

# Primer trimming at the dialog's k. The sequence is illustrative only.
lungfish-cli fastq primer-remove HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --literal GCTGGGATTACAGGCATGAGCCACC \
  --kmer 15 --mink 11 --hdist 1 \
  --output R1.primer.fastq
```

Two command-line defaults for primer trimming differ from the window and change results. `fastq primer-remove` defaults `--kmer` to 23 where the dialog's **k** defaults to 15, so pass `--kmer 15` to match a dialog run. Giving `--ref` alone runs bbduk on the primer file, while the dialog's Reference FASTA choice runs cutadapt, so add `--engine cutadapt-linked` to match the window.

## Next

Continue to [Decontamination](05-decontamination.md) to remove host and ribosomal reads, or go to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) if your reads are clean and ready to map.

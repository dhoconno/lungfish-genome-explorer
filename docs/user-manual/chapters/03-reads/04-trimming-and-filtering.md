---
title: Trimming and Filtering Reads
chapter_id: 03-reads/04-trimming-and-filtering
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq, 03-reads/03-quality-control]
estimated_reading_min: 28
task: Trim adapters, low-quality bases, primers, and fixed base counts from FASTQ reads, and filter the survivors by length.
tags: [reads, trim, adapter, primer, length, filter, fastp, bbduk, cutadapt, seqkit]
tools: [fastp, bbduk, cutadapt, seqkit]
parameters_refs: [fastq.fastp-trim, fastq.quality-trim, fastq.adapter-removal, fastq.primer-trimming, fastq.trim-fixed-bases, fastq.filter-by-read-length]
entry_points:
  - "Tools > Trimming & Filtering > (pick the operation)"
  - "CLI: lungfish-cli fastq trim, quality-trim, adapter-trim, primer-remove, fixed-trim, length-filter"
shots:
  - id: trimming-dialog
    caption: "The FASTQ/FASTA Operations window on the fastp Adapter & Quality Trim pane at its defaults, with Threshold 20, Window Size 4, Mode on Cut Right, and Adapter Mode on Auto-Detect under Primary settings."
  - id: primer-trimming-literal-pane
    caption: "The Primer Trimming pane with Primer Source on Literal Sequence, showing the Primer Sequence field above the three compact fields labeled k, mink, and hdist."
  - id: length-filter-readiness
    caption: "The Filter by Read Length pane with both bounds empty and the readiness line at the foot of the window reading Enter a minimum, a maximum, or both."
illustrations: []
glossary_refs: [fastq, phred-score, basecaller, read-length, adapter, library-prep, fastp, bbduk, cutadapt, seqkit, sliding-window-trimming, k-mer, hamming-distance, umi, amplicon, shotgun, primer, primer-scheme, primer-trim, paired-end, mapping, variant-caller, required-setup-pack, provenance, checksum, bundle, chimera, ivar, soft-clip, three-prime-and-five-prime-ends, tiling, primer-dimer, iupac-ambiguity-code, mapper, bed]
features_refs: [fastq.trim-filter]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Trimming means cutting bases off the ends of reads. Filtering means throwing whole reads away. Both remove sequence that came from the laboratory rather than from the organism, and both happen before you [map](../../GLOSSARY.md#mapping) the reads, meaning before you match each read to the spot in a reference genome it came from.

Reads arrive carrying four kinds of unwanted sequence. The first is low-quality bases. The [base caller](../../GLOSSARY.md#basecaller), the instrument software that turns raw signal into letters, writes a [Phred score](../../GLOSSARY.md#phred-score) beside every base, a number saying how likely that letter is wrong, as [Quality Control for Reads](03-quality-control.md#q20-and-q30) explains. On Illumina reads the scores fall toward the end of the read.

The second is adapter. [Library preparation](../../GLOSSARY.md#library-prep), the bench steps that turn extracted DNA into machine-ready fragments, attaches a short synthetic [adapter](../../GLOSSARY.md#adapter) to each end of every fragment. When a fragment is shorter than the [read length](../../GLOSSARY.md#read-length), the instrument reads past the end of the fragment and into the adapter, so adapter letters land in your data.

The third is [primer](../../GLOSSARY.md#primer) sequence, the short synthetic DNA that started each PCR product, which appears only in libraries built by PCR. The fourth is reads too short to place on a genome with confidence.

Lungfish Genome Explorer (LGE) gives each problem its own operation. Eight operations sit under **Tools > Trimming & Filtering**, and this chapter covers the first six. They are fastp Adapter & Quality Trim, Quality Trim, Adapter Removal, Primer Trimming, Trim Fixed Bases, and Filter by Read Length. The last two, Remove Low-Complexity Reads and Remove Duplicate Reads, drop whole reads rather than trimming them, so [Decontamination](05-decontamination.md) covers them. Neither belongs in a standard clean-up before mapping. Low-complexity reads are those made almost entirely of one repeated unit, and removing them is optional. Duplicates are better marked after mapping when you will map the reads, and an amplicon run keeps them on purpose, as [Decontamination](05-decontamination.md#duplicates-before-or-after-mapping) explains. Remove host or contaminant reads only when the sample carries reads you must not analyze or share, such as a patient's own genome in a sample from another organism.

Each operation reads a [FASTQ](../../GLOSSARY.md#fastq) bundle and writes a new one. The input is never changed, so a trim you regret costs disk space and nothing else. Four programs do the work behind the six operations, which is why the settings change from one pane to the next.

| Program | Menu items it runs behind |
|---|---|
| [fastp](../../GLOSSARY.md#fastp) | fastp Adapter & Quality Trim, Quality Trim, Adapter Removal, and Trim Fixed Bases |
| [bbduk](../../GLOSSARY.md#bbduk) | Primer Trimming with Literal Sequence, and Filter by Read Length on read pairs |
| [Cutadapt](../../GLOSSARY.md#cutadapt) | Primer Trimming with Reference FASTA |
| [seqkit](../../GLOSSARY.md#seqkit) | Filter by Read Length on single reads |

Trim only what quality control showed you was there, then measure what the trim cost, because every operation removes some real sequence along with the artifact.

## Why you would do this

A read that ends in adapter may fail to map, or may map to the wrong place because the adapter happens to resemble some stretch of the genome. A low-quality tail produces false variant calls, because a [variant caller](../../GLOSSARY.md#variant-caller), the program that lists where a sample differs from the reference, counts a miscalled base as evidence just as readily as a real one. An untrimmed primer hides real variation, because primer sequence is synthetic and matches the reference whatever the sample carries at those positions.

Length filtering solves a different problem. Trimming shortens reads, and a very short read can match many places on a large genome equally well. Dropping those reads before mapping is cheaper than untangling ambiguous alignments afterwards.

This chapter works on a half-million-base slice of chromosome 20 from HG002, a human genome from the Genome in a Bottle project whose true sequence is already known. The reads are already good, which is deliberate. You need to know what a trim costs on clean data before you can recognize one that has gone wrong on bad data.

## Choosing a tool

Check whether your reads are short or long and amplicon or shotgun, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) describes. For adapters and poor read ends, the choice is between trimming here, where you can measure the cost, and trimming at import, which the import sheet offers as Trim Galore, described below. For primers, what matters is whether the next tool reads FASTQ or maps the reads for variant calling.

### Adapters and low-quality ends

**fastp** runs behind four of the six operations. Its quality trim cuts where the average score in a short sliding window drops below the Threshold. On a paired bundle LGE hands fastp both mates of each pair together, so fastp keeps or drops the two as one and finds adapter by lining the mates up against each other. Where two mates overlap past the end of their fragment, whatever hangs off the overlap must be adapter. For example, a 100-base fragment read for 150 bases leaves about 50 bases of adapter at the end of each mate. On a bundle of single reads LGE lets fastp guess nothing. Unless you type an adapter, it names the Illumina TruSeq Read 1 adapter and a bundled list of five common adapters (TruSeq Read 1 and Read 2, Nextera, and two small-RNA adapters), and the new bundle's record lists them. If you need to type one, the library preparation kit's documentation or your sequencing core gives its sequence.

**Trim Galore** runs on the import sheet, as [Importing Sequencing Reads](01-importing-fastq.md#choosing-a-tool) describes, and as the **Trim with Trim Galore** switch of Quantify RNA-seq Reads, though none of the six operations here uses it. It is a trimming program that recognizes common [adapter](../../GLOSSARY.md#adapter) types from the reads themselves, among them the standard Illumina and Nextera adapters, cuts low-quality bases from the [3' end](../../GLOSSARY.md#three-prime-and-five-prime-ends) of each read, meaning its tail, and drops reads left too short. Its cost is that the trim is baked into the only copy of the reads LGE stores, with settings the sheet does not let you change, so you cannot measure what it removed. It trims a single file that mixes read pairs with unpaired reads by splitting it by mate name, trimming the pairs as pairs and the unpaired reads on their own, and joining the two halves.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| fastp (this chapter) | Adapter and quality trimming of short reads | You want to trim and then measure the cost | You have long nanopore reads, which [Oxford Nanopore Runs](07-ont-runs.md#after-import) covers |
| Trim Galore (import sheet) | One standard trim applied as reads are stored | Every sample is known to need the same trim | You want to see the reads first, or to measure what a trim removed |

Whether to trim before mapping depends on the [mapper](../../GLOSSARY.md#mapper), the program that places each read on the genome. [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#choosing-a-tool) names four, minimap2, BWA-MEM2, Bowtie2, and BBMap, and minimap2 is the usual choice. Trim first when you map with Bowtie2, which aligns every read from end to end, or with BBMap, which aligns each read across its whole length. With minimap2 or BWA-MEM2, trimming is optional on clean whole-genome data.

For human or macaque whole-genome data headed for germline variant calling, a default fastp pass is fine and skipping it is defensible. Barbitoff and Predeus (2024) found that adapter trimming made no measurable difference to germline calls on human whole-genome data. Their result rests on mappers that [soft-clip](../../GLOSSARY.md#soft-clip) an unmatched read end, hiding leftover adapter. The HG002 fixture uses fastp at its defaults as practice, and the rest of this manual maps the untrimmed import, because minimap2 soft-clips what little adapter these reads carry.

### Primers

**bbduk**, the Literal Sequence choice, breaks the one primer you type into short words, finds the primer at the start of each read, and cuts it off with every base before it. A second bbduk pass then removes the copy of a primer that a read runs into at its 3' end, which happens when the fragment is shorter than the read. It cuts a pair where its two mates overlap, so each mate ends where its partner's primer began, and it cuts a single read where the primer's reverse complement ends within the read's last bases. A read that either pass leaves shorter than 10 bases, such as a [primer dimer](../../GLOSSARY.md#primer-dimer), two primers joined with no sample DNA between them, is dropped together with its mate. When the primers of a [tiled scheme](../../GLOSSARY.md#tiling), overlapping amplicons that together cover the target, are given as a file on the command line, the second pass can also cut real bases from a single read whose last bases happen to hold the reverse complement of another amplicon's primer. Pairs escape this. Because it matches by sequence, a primer can slip through, as [When a trim goes wrong](#when-a-trim-goes-wrong) explains.

**Cutadapt**, the Reference FASTA choice, finds primers by alignment that tolerates wrong, missing, or extra bases, up to an error rate of 0.12, which is 12 percent of the matched bases, with a match of at least 12 bases. LGE runs it in linked mode, which means looking for the forward and reverse primer of one amplicon on the same read. It pairs primers by name, so the names must end in `_F` and `_R` or a variant that the [Primer Trimming settings](#primer-trimming) list, and it discards every read in which no primer pair was found. Because a read must hold both primers of an amplicon to stay, this choice suits reads that span a whole amplicon, such as full-length Nanopore amplicon reads. Short reads of a longer amplicon rarely reach both primers, so most of them are dropped.

**iVar** trims after mapping, in [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md). It reads a [BED file](../../GLOSSARY.md#bed), a plain table of each primer's start and end on the reference, which the kit's maker or a public repository usually publishes, as [Primer Scheme Bundles](../appendices/primer-schemes.md#building-a-scheme-from-a-bed-file) shows. It [soft-clips](../../GLOSSARY.md#soft-clip) the primer bases of each mapped read, leaving them in the file but hidden from a variant caller. It matches by position, so a variant inside the primer cannot hide it. With LGE's settings it also trims bases below quality 20 and drops reads left under 30 bases.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| bbduk, Literal Sequence | One known oligo, no reference needed | The primer sits at the 5' start of the reads, whether or not reads also run into it at their 3' end | The scheme has many primers, or the next step is mapping and variant calling |
| Cutadapt, Reference FASTA | A primer scheme matched as forward and reverse pairs | Each read spans a whole amplicon and the next tool reads FASTQ | Reads are shorter than the amplicon, or the next step is mapping and variant calling |
| iVar trim, after mapping | Amplicon data headed for variant calling | You will call variants on an amplicon panel | You need primer-free FASTQ for a tool that never maps |

The shotgun HG002 fixture has no primers, so this chapter runs none of the three. Every read of an amplicon protocol begins inside a primer, and a shotgun library has none to trim. For an amplicon panel headed for variant calling, map first and trim with iVar, as the Viral Recon pipeline does and as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) teaches. All five tools are cited in the [Tool Bibliography](../appendices/bibliography.md), bbduk under BBTools, and the Barbitoff study in [Method comparisons cited in the manual](../appendices/bibliography.md#method-comparisons-cited-in-the-manual).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Reads demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` bundle this section imports, so go straight to the procedure. To import the pair yourself instead, follow the rest of this section. To use your own reads, import them first through **File > Import Center…**, the **Sequencing Reads** tab, and the **Sequencing Read Files** card, as [Importing Sequencing Reads](01-importing-fastq.md#procedure) shows.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. Importing both files as one sample leaves a single `HG002.chr20.10.0-10.5Mb` bundle in the sidebar that holds both mates. Every count in this chapter counts each mate as one read.

fastp, bbduk, Cutadapt, and seqkit arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. If you skipped it, **Tools > Plugin Manager…** on its **Packs** tab installs it, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. Reading [Quality Control for Reads](03-quality-control.md) first helps, because its summary cards are how you judge whether a trim helped.

A fastp trim of read pairs writes work files beside its output, and they need free disk space of about three times the size of the uncompressed reads. LGE checks the disk before it starts, and when the disk is short the trim writes nothing and its message says how much space it needs. The fixture needs very little.

## Procedure

This chapter's example runs the combined fastp pass on the imported bundle, then filters the result by length. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, and one window, titled FASTQ/FASTA Operations, serves all six operations. The readiness line at the foot of the window, beside **Run**, says what the run still needs before it can start. [What good looks like](#what-good-looks-like) says what to expect from your own reads.

For paired Illumina reads, run the operations in this order, each on the bundle the one before wrote. The length filter goes last because every other operation can shorten reads and so change which reads fall below your minimum.

| Order | Operation | What it removes |
|---|---|---|
| 1 | fastp Adapter & Quality Trim | Adapter and low-quality ends |
| 2 | Primer Trimming | Primers, only if your library was built with them |
| 3 | Filter by Read Length | Reads left too short |

For an amplicon library you will call variants from, skip step 2, map first, and trim the primers with iVar, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) teaches. [The length filter](#the-length-filter) ends with how to carry the cleaned bundle into the mapping dialog.

### The combined adapter and quality trim

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar. This one bundle holds both mates, so you never select the R1 and R2 files separately.

2. Choose **Tools > Trimming & Filtering > fastp Adapter & Quality Trim…**.

    <!-- SHOT: trimming-dialog -->

3. Leave **Threshold** at 20, **Window Size** at 4, **Mode** on Cut Right, and **Adapter Mode** on Auto-Detect, all under Primary settings. A Threshold of 20 is a Phred score of 20, one expected error in a hundred bases. These defaults suit this data, and [Settings](#settings) explains when to change each one.

4. Leave **Output Strategy**, in the Output section below Primary settings, on Per Input, which writes one trimmed bundle for the one bundle you selected.

5. Click **Run**.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands as a new bundle straight in `Analyses/`, a group in the sidebar, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. This run writes a bundle named `HG002.chr20.10.0-10.5Mb-fastpTrim`, the input's name with the operation added.

### The length filter

1. Click the new `HG002.chr20.10.0-10.5Mb-fastpTrim` bundle under `Analyses/` in the sidebar. The original bundle stays under `Imports/`.

2. Choose **Tools > Trimming & Filtering > Filter by Read Length…**.

3. Set **Min Length** to 50 and leave **Max Length** empty. A floor of 50 is far below a 100 to 150 base read, so it removes only reads that trimming cut to a fraction of their length. Both fields start empty, and until one is filled the readiness line reads "Enter a minimum, a maximum, or both."

    <!-- SHOT: length-filter-readiness -->

4. Click **Run**.

The result, `HG002.chr20.10.0-10.5Mb-fastpTrim-lengthFilter`, also lands under `Analyses/`. On data that needed trimming, this is the bundle you would hand to a mapper. To do that, click it under `Analyses/` in the sidebar and choose **Tools > Mapping > minimap2…**, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#map-the-hg002-reads-with-minimap2) does for the imported bundle. The mapping dialog works on the bundle you selected, and the one bundle holds both mates. This manual maps the untrimmed `HG002.chr20.10.0-10.5Mb` bundle instead, because these reads are clean, so treat the two bundles you made here as practice.

### Trimming a fixed number of bases

Use **Tools > Trimming & Filtering > Trim Fixed Bases…** when the library design puts the same number of unwanted bases on every read. A common case is a [UMI](../../GLOSSARY.md#umi), a short random barcode attached to each original molecule before amplification so that PCR copies of one molecule can later be told apart from separate molecules. Your kit's documentation says whether it adds a UMI and how many bases long it is.

Set **5' Trim**, **3' Trim**, or both, then click **Run**. The 5' end is the start of the read and the 3' end is its end. This operation ignores quality and removes exactly the count you asked for from every read.

### Primer trimming at the read level

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome.

**Tools > Trimming & Filtering > Primer Trimming…** finds primer sequence in the text of each read and cuts it off, before any mapping. That fits a pipeline whose next tool reads FASTQ. When your next step is mapping and variant calling, [primer trimming](../../GLOSSARY.md#primer-trim) after mapping is the route [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) teaches.

<!-- SHOT: primer-trimming-literal-pane -->

The pane changes shape with **Primer Source**, and the two choices run different programs. Literal Sequence runs bbduk on one primer sequence you type, looking for exact matches of short words taken from the primer. A [k-mer](../../GLOSSARY.md#k-mer) is a substring of exactly k bases, the unit many read tools match on, as [Three ways to match a read](../06-classification/01-what-is-classification.md#three-ways-to-match-a-read) shows. The **k**, **mink**, and **hdist** fields tune that matching, and you can leave them at 15, 11, and 1 unless [Settings](#primer-trimming) gives you a reason. Literal Sequence trims a primer at the 5' start of a read together with every base before it. It looks only within the primer's length plus 67 bases from the start, a limit LGE sets that the pane does not show. A second pass removes a primer that a read runs into at its 3' end, as [Primers](#primers) describes.

Reference FASTA runs Cutadapt in linked mode on a FASTA file of primers, which you choose under **Primer Reference** in the Inputs section. Linked mode looks for the forward and reverse primer of one amplicon as a pair on the same read, which is what a tiled scheme of dozens of primers needs. The primer names must follow the `_F` and `_R` pattern that [Primer Trimming](#primer-trimming) sets out, and reads with no primer pair are dropped. The bbduk fields disappear, and the pane reads "Select the primer reference FASTA in the Inputs section."

Both choices keep the mates of a pair together. In a bundle of pairs, a pair is kept or dropped whole, and in a bundle that mixes pairs with merged reads, the pairs are trimmed as pairs and the merged reads on their own.

The HG002 reads are shotgun data with no primers in them, so this chapter has no worked primer-trimming result.

### Quality trimming and adapter removal on their own

The combined operation does both jobs in one fastp pass and is the right first choice. **Tools > Trimming & Filtering > Quality Trim…** trims quality and leaves adapters alone, and it is the only one of the six panes with an **Extra arguments** field. **Tools > Trimming & Filtering > Adapter Removal…** removes adapters and leaves quality alone.

### FASTA input

Adapter Removal, Primer Trimming, Trim Fixed Bases, and Filter by Read Length also accept FASTA files, which hold sequence without quality scores. When every file you selected is FASTA, fastp Adapter & Quality Trim and Quality Trim leave the list altogether, because there are no quality scores for them to read.

## Settings

Several labels appear on more than one pane. Each is described once, and the heading above it names the panes that show it.

### Quality settings (fastp Adapter & Quality Trim, Quality Trim)

**Threshold.** Sets the lowest Phred score a base may have before fastp treats it as unreliable. The default is 20, one expected error in a hundred bases, the usual floor for Illumina data. Raise it toward 30 when you need very clean bases for variant calling, and lower it when trimming discards too much of every read. On the command line this is `--threshold`.

**Window Size.** Sets how many neighboring bases fastp averages before deciding to cut, which makes this [sliding-window trimming](../../GLOSSARY.md#sliding-window-trimming) rather than a base-by-base cut. The default is 4, wide enough that one bad base does not end an otherwise good read. Use a smaller window for a sharp quality drop at the read end. On the command line this is `--window`.

**Mode.** Chooses where fastp cuts, offering Cut Right, Cut Front, Cut Tail, and Cut Both. The default is Cut Right, which suits the usual Illumina pattern of good bases early and poor bases late. Switch to Cut Both when quality is poor at both ends of the read. On the command line this is `--mode`.

The names describe where the cut lands, not where the scan starts. Picture the read written left to right, with its start on the left.

| Mode | What it does |
|---|---|
| Cut Right | Walks from the start and cuts everything from the first bad window rightward |
| Cut Front | Cuts bad bases off the start and stops at the first good window |
| Cut Tail | Cuts bad bases off the end, working backwards from the last base |
| Cut Both | Applies Cut Front and then Cut Right, trimming both ends |

Threshold and Window Size must both be above 0. Otherwise the readiness line reads "Enter a positive quality threshold and window size."

Two fastp behaviors sit outside these controls. fastp trims poly-G tails on its own when the read names show a NextSeq or NovaSeq instrument, and LGE leaves that in place, so it needs no action from you. These instruments read the base G as the absence of light, so a read whose signal fades ends in a false run of Gs. LGE also switches off fastp's own minimum-length and read-quality filters, so that a trim changes bases and drops a read only when it is cut to nothing, along with its mate. That is why a trimmed bundle can hold one-base reads and why Filter by Read Length is a separate step.

### Adapter settings (fastp Adapter & Quality Trim, Adapter Removal)

**Adapter Mode.** Chooses whether LGE finds the adapter for you or uses a sequence you type, offering Auto-Detect and Manual Sequence. The default is Auto-Detect, which finds adapter on pairs where the mates overlap and trims TruSeq Read 1 and the five listed adapters from single reads, so it suits the common TruSeq and Nextera kits. Use Manual Sequence when your kit's adapter is not among those, or when adapter is still there after an auto-detected trim. On the command line this is `--adapter`.

**Adapter Sequence.** Holds the one adapter sequence fastp removes, written in A, C, G, T and the [IUPAC ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code), single letters that stand for more than one base, such as N for any base. It starts empty and appears only while Adapter Mode is Manual Sequence. Fill it in from your kit's documentation or your sequencing core when auto-detection does not find the adapter. On the command line this is `--adapter`.

While Manual Sequence is chosen and the field is empty, the readiness line reads "Enter an adapter sequence or switch to auto-detect." on the combined pane and "Enter an adapter sequence for manual adapter removal." on the Adapter Removal pane.

### Primer Trimming

**Primer Source.** Chooses between typing one primer and choosing a FASTA file that holds a whole primer set, offering Literal Sequence and Reference FASTA. The default is Literal Sequence, which runs bbduk. Pick Reference FASTA, which runs Cutadapt, for a tiled amplicon scheme with dozens of primers. On the command line this is `--literal` or `--ref`.

Reference FASTA pairs each forward primer with its reverse primer by name. A name counts as forward when it ends in `_F`, `-F`, `_FORWARD`, or `-FORWARD`, and as reverse when it ends in `_R`, `-R`, `_REVERSE`, or `-REVERSE`, in upper or lower case, and the part before the ending must match, so `amp1_F` pairs with `amp1_R`. Primers with any other ending, such as the `_LEFT` and `_RIGHT` of ARTIC schemes, are ignored, and a file with no pair at all makes the run fail with a message that no paired primers were found. Rename the records before you run. A FASTA file is plain text and each record's name is the line that starts with `>`, so a text editor can do it. Cutadapt then keeps only the reads in which it found a primer pair and discards the rest, so compare the read counts before and after.

**Primer Sequence.** Holds the primer bbduk removes, written in A, C, G, and T. bbduk stops the run with an error on an IUPAC ambiguity letter such as R or S, the letters a primer order sheet uses for a position that can hold more than one base. A primer with such a position cannot go through Literal Sequence, so use primer trimming after mapping, which matches by position. It starts empty, and while it is empty the readiness line reads "Enter a literal primer sequence or switch to reference mode." Type the primer exactly as your primer order sheet gives it. On the command line this is `--literal`.

**k.** Sets the length of the exact-match word bbduk uses to spot the primer. The default is 15, since four possible bases at fifteen positions give about a billion different words, so a chance match is unlikely, while the word is still short enough to fit inside most primers. Shorten it when short primers are being missed, which [When a trim goes wrong](#when-a-trim-goes-wrong) shows how to spot, and lengthen it when non-primer sequence is being trimmed. It may not be longer than the primer, and a longer value stops the run before bbduk starts, with a message that names the primer's length. On the command line this is `--kmer`, which also defaults to 15.

**mink.** Sets the shortest word bbduk still matches when only part of a primer sits at the edge of a read, so a primer that runs off the edge is still caught. The default is 11, comfortably below k, so partial primers are found without letting very short chance matches through. Lower it toward 8 when partial primers survive at read ends. On the command line this is `--mink`.

**hdist.** Sets how many mismatched bases a primer match may contain, the [Hamming distance](../../GLOSSARY.md#hamming-distance) between primer and read, which counts positions where two equal-length sequences differ. The default is 1, which tolerates one sequencing error or one real variant inside the primer. Raise it to 2 when primers with a variant plus a sequencing error slip through, and drop it to 0 when trimming is removing real sequence. On the command line this is `--hdist`.

### Trim Fixed Bases

**5' Trim.** Sets how many bases are cut from the start of every read, whatever those bases are. The default is 0, so nothing is cut until you ask, because a fixed trim is right only when the library design says so. Set it when the design puts a fixed tag or a UMI at the start of each read. On the command line this is `--front`.

**3' Trim.** Sets how many bases are cut from the end of every read. The default is 0, for the same reason. Set it when a known number of trailing bases are unreliable. On the command line this is `--tail`.

While both are 0 the readiness line reads "Enter at least one fixed trim amount." There is no quality check and no length guard, so a 5' Trim of 40 on a 35-base read leaves nothing behind.

### Filter by Read Length

**Min Length.** Sets the shortest read kept, in bases. It starts empty, meaning no lower bound, so the filter does nothing until you fill in at least one of the two fields. Use 30 to 50 for general short-read work, and for an amplicon protocol use your amplicon length or a little below it, for example 250 for a 300-base amplicon, which drops adapter dimer, two adapters joined with no sample DNA between them. On the command line this is `--min`.

**Max Length.** Sets the longest read kept, in bases. It starts empty, meaning no upper bound, which is right for Illumina data because the instrument already caps read length. Set it on long-read data when reads far above the expected size appear, which are usually concatemers, several copies of one fragment joined end to end, or [chimeras](../../GLOSSARY.md#chimera), two unrelated fragments joined into one read. [Oxford Nanopore Runs](07-ont-runs.md#after-import) uses it that way. On the command line this is `--max`.

A minimum larger than the maximum makes the readiness line read "Minimum read length cannot exceed maximum read length." On a paired bundle the filter drops both mates of a pair when either one falls outside the bounds, so the output stays paired. A bundle that holds merged reads beside its pairs is split by read name first, so its pairs are kept or dropped whole and each merged read is judged on its own. The command-line `fastq length-filter` runs the same commands and does the same.

### Shared settings

**Output Strategy.** Chooses how the results of several selected bundles are filed, offering Per Input and Grouped Result. The default is Per Input, which files each bundle's result as a bundle of its own and is right for most runs, including any run on one bundle. Choose Grouped Result to keep a batch together in one folder, where each selected bundle still runs its own command and gets a sub-folder named for it, with `-2` added when two bundles share a name. This setting has no command-line flag.

Neither choice pools the reads of several bundles into one bundle, so two runs of one library still give two trimmed results.

**Extra arguments.** Passes text straight to fastp without LGE checking it. The default is empty, which is right for almost every run. Use it only for a fastp option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

Only the Quality Trim pane shows Extra arguments. The combined pane has no such field, although the command-line `fastq trim` accepts `--extra-args`.

## Reading the results

Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. LGE computes the new bundle's summary as it writes the bundle, so the cards are filled when the bundle appears. Three cards matter here. Reads is how many records the bundle holds, and each mate of a pair counts as one read, so 91,148 reads are 45,574 pairs. Bases is the total number of letters across them, and Mean Length is Bases divided by Reads.

[Quality Control for Reads](03-quality-control.md) judged these reads fine, so the trim here is practice. The table gives the figures for the procedure's two steps on the paired bundle. They come from a run of the same fastp and bbduk commands the window runs, on the bundle's own file.

| Measure | Imported bundle | After fastp Adapter & Quality Trim | After Filter by Read Length, minimum 50 |
|---|---|---|---|
| Reads | 91,148 | 90,556 | 86,410 |
| Pairs | 45,574 | 45,278 | 43,205 |
| Bases | 22,662,846 | 20,236,175 | 19,841,490 |
| Mean read length | 248.6 bases | 223.5 bases | 229.6 bases |
| Shortest read | 35 bases | 1 base | 50 bases |

Read the table from left to right. The trim kept 90,556 of 91,148 reads, which is 99.35 percent, so it removed 296 whole pairs outright. fastp judges the two mates of a pair together, so when trimming leaves one mate with nothing its partner goes with it, and every read that survives still sits next to its mate. Bases fell to 89.3 percent of the original, so the trim cost about a tenth of the sequence while costing almost no reads.

The gap between those two survival figures is the sign of a healthy trim. Reads kept and bases kept differ by about ten percentage points, so the trim took a tail off many reads rather than removing many reads. The mean length says the same thing, since the average read lost about 25 bases.

The shortest read shows the cost. It falls from 35 bases to 1. A one-base read is a read whose quality collapsed near its start, cut back to almost nothing and kept, because LGE switches off fastp's own length filter. That is why the length filter exists and why it runs after the trim. At a 50-base minimum it removed 4,146 reads, 2,073 whole pairs, because it drops both mates when either one is too short. It kept 95.42 percent of the reads it was given and 94.8 percent of the original 91,148.

Four more runs on the same bundle show what the settings do.

| Operation and setting | Reads kept | Bases kept |
|---|---|---|
| Adapter Removal alone | 91,148 | 22,641,285 |
| Quality Trim alone, Threshold 20 | 90,658 | 20,264,772 |
| Quality Trim, Threshold 30 | 87,834 | 16,595,750 |
| Trim Fixed Bases, 5' Trim of 10 | 91,148 | 21,751,366 |

Adapter Removal kept every read and removed 21,561 bases of adapter from 829 reads, under 1 percent of the reads. [Subsetting and Extraction](06-subsetting-and-extraction.md#select-reads-by-sequence) finds a similar share, 518 reads, when it searches the reads for the Illumina TruSeq adapter directly. So these reads do carry adapter, at a frequency too low to matter for mapping. Quality Trim alone kept 102 more reads than the combined operation and about 29,000 more bases, mostly the adapter the combined pass also took. Ten more points of threshold, Q30 instead of Q20, cost a further 3.67 million bases of real human sequence, 18 percent of what the Q20 trim had left. Trim Fixed Bases removed exactly 911,480 bases, ten bases times 91,148 reads, and kept every read.

Each run's row in the Operations Panel ran a `lungfish-cli fastq` command. Seeing it is optional and useful only for repeating a run later. To see it, right-click the row and choose **Copy CLI Command**, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes.

## What good looks like

Compare the trimmed bundle's cards and charts against the input's. The viewport shows one bundle at a time, so note the input's figures first, then click the output. Apply these checks in order.

**The quality chart.** The chart labeled Q / Position, one of the small charts below the cards as [Quality Control for Reads](03-quality-control.md#the-fastq-viewports-sparkline-charts) shows, plots quality along the read. After a trim at a Threshold of 20 it should no longer dip below Q20 at the read end, where Q20 is the same Phred score of 20.

**Read survival.** For typical Illumina data expect 90 percent or more of reads to survive a quality trim, and this example's 99.35 percent sits well inside that. Survival below about 70 percent means the Threshold is too harsh for the data. Compare with the input's cards first, because reads that were poor before the trim lose more. Lower the Threshold rather than accept a loss it does not explain.

**Bases against reads.** Reads surviving while bases fall is a trim working correctly. Reads and bases falling together in similar proportion means whole reads are being discarded, so lower the Threshold.

**The output location.** The trimmed bundle sits under `Analyses/`, named for its input and the operation.

LGE records every trim in the new bundle's [provenance](../../GLOSSARY.md#provenance), as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows.

### When a trim goes wrong

**Too few reads survive.** When survival after quality trimming falls below about 70 percent, the Q20 floor is probably too harsh. Re-run at a Threshold of 15, which accepts bases expected to be wrong about once in 32, since the error probability is 10^(-15/10), about 0.032, and compare the two. On this fixture Threshold 15 kept 91,112 reads and 21,817,532 bases. Long reads sit far lower on the Phred scale by nature and should never be trimmed against an Illumina threshold. When survival drops sharply after the length filter instead, the Min Length is too high for a run that made short reads on purpose, so lower it or skip the filter.

**Low quality persists after trimming.** When the Q / Position chart still dips below Q20 at the read ends, the four-base window probably averaged over isolated bad bases. A Window Size of 1 judges each base on its own and clears them, at the cost of a more aggressive cut. Use 1 as a diagnostic when the chart is flat and healthy apart from isolated downward spikes, and keep 4 when quality declines steadily toward the read end, the ordinary case.

**Adapter still suspected after Adapter Removal.** On a bundle of single reads Auto-Detect trims only TruSeq Read 1 and the five listed adapters, so a library made with another adapter keeps it. Re-run with **Adapter Mode** set to Manual Sequence and paste your kit's adapter.

**Primer bases visible after read-level primer trimming.** bbduk tolerates one mismatch by default, so a read carrying a real variant plus a sequencing error inside the primer can slip through untrimmed, and you see it as primer letters at the start of reads in the output. Raising **hdist** helps a little and costs specificity. The second pass, at the 3' end of a read, matches by sequence in the same way and misses the same primers. The lasting fix for both is primer trimming after mapping, covered in [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md), which matches on position rather than sequence.

## On the command line

This section is optional. It repeats the procedure without the window, for readers who work in a terminal, and you can skip it if you work in the app. The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Read processing](../appendices/cli-reference.md#read-processing) in the CLI Reference lists every flag of these commands. Each command reads one FASTQ file, here the file inside the Human Reads demo project's bundle, and writes its output where you name it. `$HOME` stands for your home folder.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Reads.lungfish"
READS="$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz"

# The combined adapter and quality pass, at the dialog's defaults.
lungfish-cli fastq trim "$READS" \
  --threshold 20 --window 4 --mode cut-right --adapter-trimming \
  --output "$HOME/Desktop/hg002.trim.fastq"

# Drop everything under 50 bases, last of all, keeping mates together.
lungfish-cli fastq length-filter "$HOME/Desktop/hg002.trim.fastq" \
  --min 50 --pairing interleaved --output "$HOME/Desktop/hg002.trim.len50.fastq"

# Primer trimming at the dialog's k. The sequence is illustrative only.
lungfish-cli fastq primer-remove "$READS" \
  --literal GCTGGGATTACAGGCATGAGCCACC \
  --kmer 15 --mink 11 --hdist 1 \
  --output "$HOME/Desktop/hg002.primer.fastq"
```

The trim and the length filter give the window's numbers, because the window's rows run these same commands. `fastq trim` splits the bundle's pairs into two files and runs fastp on them as a pair. It hands fastp the pairs in a fixed shuffled order, so the adapter guess does not depend on how the import stored the reads, and it keeps 90,556 reads and 20,236,175 bases. The trimmed file sits outside any bundle, so `--pairing interleaved` states that its records alternate between mates. `fastq length-filter` then runs bbduk, which keeps or drops both mates together, and keeps 86,410 reads, 43,205 whole pairs. `fastq primer-remove` reads the pairing from the read names and keeps the mates of a pair together in the same way. One behavior differs from the window and changes results. `--ref` alone runs bbduk on the primer file, while the dialog's Reference FASTA choice runs cutadapt, so add `--engine cutadapt-linked` to match the window.

## Next

Continue to [Decontamination](05-decontamination.md) to remove host and ribosomal reads, the next step in [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation). Human reads in a human study need no host removal, so the reads in this chapter need none, and [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) maps the untrimmed `HG002.chr20.10.0-10.5Mb` bundle.

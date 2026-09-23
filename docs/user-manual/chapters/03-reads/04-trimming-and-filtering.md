---
title: Trimming and Filtering Reads
chapter_id: 03-reads/04-trimming-and-filtering
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq, 03-reads/03-quality-control]
estimated_reading_min: 30
task: Trim adapters, low-quality bases, primers, and fixed base counts from FASTQ reads, and filter the survivors by length.
tags: [reads, trim, adapter, primer, length, filter, fastp, bbduk, seqkit]
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
  - id: trim-operation-row
    caption: "The Operations Panel with the finished trim row expanded, showing its state, elapsed time, and command line."
illustrations: []
glossary_refs: [fastq, phred-score, basecaller, read-length, adapter, library-prep, fastp, bbduk, seqkit, sliding-window-trimming, k-mer, hamming-distance, umi, amplicon, shotgun, primer, primer-scheme, primer-trim, soft-clip, pileup, bam, mapping, variant-caller, sparkline, required-setup-pack, operations-panel, provenance, bundle]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Trimming means cutting bases off the ends of reads. Filtering means throwing whole reads away. Both are ways of removing unwanted sequence that came from the laboratory rather than from the organism, and both happen before you [map](../../GLOSSARY.md#mapping) reads to a reference genome. Mapping means matching each read to the spot in the genome it came from.

Reads arrive carrying four kinds of unwanted sequence. The first is low-quality bases at the read ends, where a [Phred score](../../GLOSSARY.md#phred-score) is the number the [base caller](../../GLOSSARY.md#basecaller) records beside each base saying how confident it is in that base. The base caller is the instrument software that turns raw signal into letters. Phred scores fall toward the end of almost every Illumina read, so the last bases are the least trustworthy ones.

The second kind comes from a mismatch between fragment and read. [Library preparation](../../GLOSSARY.md#library-prep), the bench steps that turn extracted DNA into machine-ready pieces, cuts the DNA into fragments and attaches a short piece of synthetic DNA to each end so the fragment can stick to the sequencer's flow cell. That synthetic piece is the [adapter](../../GLOSSARY.md#adapter). When a fragment is shorter than the [read length](../../GLOSSARY.md#read-length), the instrument runs off the end of the fragment and carries on reading into the adapter on the far side, so adapter letters land in your data.

The third is [primer](../../GLOSSARY.md#primer) sequence, present only in [amplicon](../../GLOSSARY.md#amplicon) data, which is data from targeted PCR products rather than from randomly broken DNA. Short synthetic pieces of DNA called primers started each PCR product, and a fixed set of them designed to tile a genome is a [primer scheme](../../GLOSSARY.md#primer-scheme). The fourth is reads that are simply too short to place anywhere on a genome with confidence.

Lungfish Genome Explorer (LGE) gives each of these its own operation. Six operations sit under **Tools > Trimming & Filtering**, and they are fastp Adapter + Quality Trim, Quality Trim, Adapter Removal, Primer Trimming, Trim Fixed Bases, and Filter by Read Length. Every one of them reads a [FASTQ](../../GLOSSARY.md#fastq) [bundle](../../GLOSSARY.md#bundle) and writes a new one. A bundle is a real folder on disk that LGE treats as one sample's reads, and you can open it in Finder by right-clicking the sidebar item and choosing **Show in Finder**. The input bundle is never modified, so a trim you regret costs you disk space and nothing else.

The chapter's example uses Illumina reads, which are short reads of a few hundred bases each. These operations also accept long reads, meaning the much longer reads an Oxford Nanopore or PacBio instrument produces, and the chapter says where the advice differs for them.

Four separate programs do the actual work behind those six operations, and knowing which is which explains why the settings change from one pane to the next. All four ship inside the application.

| Program | What it does here |
|---|---|
| [fastp](../../GLOSSARY.md#fastp) | Quality trimming, adapter removal, fixed-base trimming |
| [bbduk](../../GLOSSARY.md#bbduk) | Primer trimming when you type a primer sequence in |
| cutadapt | Primer trimming when you point at a FASTA file of primers |
| [seqkit](../../GLOSSARY.md#seqkit) | The length filter |

So what should you do with this? Trim only what quality control told you was there, then measure the result. Trimming is never free, because every operation removes real sequence alongside the artefact, meaning sequence that did not come from the sample, and a threshold set too aggressively removes more biology than laboratory residue.

## Why you would do this

An untrimmed read that ends in adapter will not map at all. Worse, it can map to the wrong place, because the adapter happens to resemble something in the genome. An untrimmed low-quality tail produces false variant calls, since a [variant caller](../../GLOSSARY.md#variant-caller), the program that lists where a sample differs from the reference, counts miscalled bases as evidence just as readily as real ones. An untrimmed amplicon primer hides real variation, because the primer sequence is synthetic and always matches the reference no matter what the sample actually carries at those positions.

Length filtering solves a different problem. Trimming shortens reads, and a read short enough will match many places on a large genome equally well. Dropping those reads before mapping is cheaper than untangling ambiguous alignments afterwards.

This chapter works through the HG002 chromosome 20 slice, a pair of Illumina read files from a human genome whose true sequence is already known. HG002 is a standard reference human sample that many laboratories sequence to check their own methods, and the slice here is half a megabase of chromosome 20 so the runs finish quickly. The teaching point is deliberately a clean dataset. You will see exactly what a good trim costs on reads that were already good, which is the baseline you need before you can recognise a trim that has gone wrong on a bad dataset.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice. Download the files `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's practice data files on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. You need both files, because they are the two halves of one paired sample. On that GitHub page, click a filename, then click the download button on the page that opens.

Import both files first, following [Importing Sequencing Reads](01-importing-fastq.md), so the bundle exists before you trim it. The import stores a paired sample as one bundle holding both mates, so the sidebar shows one item and every operation in this chapter runs on that one item.

These operations use tools from the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself the first time it needs it. You do not install it yourself, and you can confirm it is present in **Tools > Plugin Manager...** (Cmd-Shift-B), where it appears under the heading Required Setup. Nothing else needs installing for this chapter. Reading [Quality Control for Reads](03-quality-control.md) first is worthwhile, because it teaches the summary you will use to judge whether a trim helped.

## Procedure

The worked example runs the combined fastp pass on the imported bundle, then filters the result by length. Every number quoted below came from a real run against the R1 file you downloaded, on 2026-09-06. Your own run on the same file will reproduce these counts exactly, because these operations are deterministic. A count that differs means a different file or a different setting, not a mistake in how you clicked.

### The combined adapter and quality trim

Before the steps, one thing to look for. Every pane in this window carries a readiness line at the bottom. It reads "Ready to configure output." when nothing is missing, which means the pane is ready and Run will work. When something is missing it names the missing piece instead, and Run will do nothing. Each operation words its own version differently, and the Settings section below quotes the wording where it matters. Glance at that line before you click Run in any of the procedures in this chapter.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar to select it.

2. Choose **Tools > Trimming & Filtering > fastp Adapter + Quality Trim...**. A window titled FASTQ/FASTA Operations opens on that operation. One shared window serves all six operations, so its title does not repeat the menu item you chose, and its left-hand list holds all six so you can switch to another one without closing the window and starting again.

    <!-- SHOT: trimming-dialog -->

3. Leave **Adapter Mode** on Auto-Detect, **Threshold** at 20, and **Window Size** at 4. Leave **Mode** on Cut Right. These four defaults are the right ones for this practice data. The Settings section below explains what each one does, which is where to go when you come to choose them for data of your own.

4. Leave **Output Strategy** on Per Input. That writes one trimmed bundle for the one bundle you selected.

5. Click Run.

The result lands directly under `Analyses/` as a new bundle named for the input and the operation, so this run writes `HG002.chr20.10.0-10.5Mb-fastpTrim`. There is no dated subfolder for these operations. Only a run by a named tool such as a mapper or an assembler gets one. The [Operations Panel](../../GLOSSARY.md#operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), shows the run while it happens and keeps the finished row afterwards.

<!-- SHOT: trim-operation-row -->

### The length filter

1. Click the trimmed bundle in the sidebar to select it. The run added a new item to the sidebar and left the original one in place, so you now have two. The new one is named `HG002.chr20.10.0-10.5Mb-fastpTrim`, the input's name with the operation added, and it sits under `Analyses/` rather than beside the imported reads.

2. Choose **Tools > Trimming & Filtering > Filter by Read Length...**.

3. Set **Min Length** to 50 and leave **Max Length** empty. Fifty bases is the usual floor for short-read work, because a read shorter than that rarely matches one spot on a human genome rather than many. Both bounds start empty, and while both are empty the readiness line reads "Enter a minimum, a maximum, or both." and the operation will not run.

    <!-- SHOT: length-filter-readiness -->

4. Click Run.

This is the bundle you hand to a mapper. Run the length filter last, after every other operation in this chapter, because each of the others can shorten reads and so change which reads fall below your minimum.

### Trimming a fixed number of bases

Use **Tools > Trimming & Filtering > Trim Fixed Bases...** when you know exactly how many bases to cut and it is the same count on every read. That happens when the library design puts a fixed tag at the start of each read, such as a [UMI](../../GLOSSARY.md#umi). A UMI is a short random barcode added to each original molecule before amplification, so that PCR copies of one molecule can be told apart from genuinely separate molecules later.

Set **5' Trim**, **3' Trim**, or both, then click Run. Both start at 0, and while both are 0 the readiness line reads "Enter at least one fixed trim amount." A 0 in this operation means the same thing as an empty field, which is that nothing is cut from that end. This operation ignores quality entirely and removes the count you asked for from every read alike.

### Primer trimming at the read level

Primer trimming removes primer-derived bases from amplicon reads. The operation is **Tools > Trimming & Filtering > Primer Trimming...**, and its pane changes shape depending on **Primer Source**.

<!-- SHOT: primer-trimming-literal-pane -->

The HG002 practice data is [shotgun](../../GLOSSARY.md#shotgun) human data, meaning randomly broken DNA rather than PCR products, so it has no primers in it and this chapter has no honest worked example for the operation. The operation itself has no organism restriction. It trims whatever sequence you give it, so human amplicon primers work exactly as viral ones do. What is viral is the set of ready-made primer schemes LGE ships, which are SARS-CoV-2 and other viral schemes. For a human amplicon panel you supply your own primer sequence or your own FASTA file of primers. The worked amplicon example belongs to [Primer Trimming](../04-alignments/03-primer-trimming.md) in the alignments part, where a SARS-CoV-2 dataset and a bundled scheme are on hand. What this chapter can tell you is which settings govern which engine, and that is in the Settings section below.

One structural point belongs here rather than there. LGE offers [primer trimming](../../GLOSSARY.md#primer-trim) at two levels, and they work on different evidence. Read-level primer trimming, the subject of this chapter, matches primer sequence against the read text. Alignment-level primer trimming, the subject of that later chapter, instead uses each read's mapped position to decide which primer it came from. It then marks the primer bases as [soft-clipped](../../GLOSSARY.md#soft-clip) rather than deleting them, meaning the bases stay in the record but are excluded from the [pileup](../../GLOSSARY.md#pileup) a variant caller reads.

Position beats sequence whenever a read carries a real variant inside the primer footprint. The reason is that a variant changes the letters, so the sequence stops matching, while the read's position on the genome does not move. That is why the variant-calling workflow in this manual trims primers at the alignment level, and why read-level primer trimming is for the narrower case where the next tool in your pipeline reads FASTQ rather than [BAM](../../GLOSSARY.md#bam), the compressed file of reads after they have been mapped.

### Quality trimming and adapter removal on their own

The combined operation runs adapter detection and quality trimming in one fastp pass, and it is the right first choice. The two single-purpose operations exist for when you want only one of the two jobs done. **Tools > Trimming & Filtering > Quality Trim...** trims quality and leaves adapters alone, and it carries an **Extra arguments** field the combined pane does not have. That field is offered on the pane that does one job, where an extra fastp option has one obvious target. The combined pane omits it because an option typed there would apply to the adapter pass and the quality pass at once, with no way to say which you meant. **Tools > Trimming & Filtering > Adapter Removal...** removes adapters and leaves quality alone.

### FASTA input

Four of these six operations also accept FASTA files, which hold sequence without quality scores. The four are Adapter Removal, Primer Trimming, Trim Fixed Bases, and Filter by Read Length. The two fastp quality operations, fastp Adapter + Quality Trim and Quality Trim, do not, because a FASTA file has no quality scores for them to read.

When every file you selected is FASTA, the window relabels itself and the subtitle under its title reads FASTA rather than FASTQ. The two quality operations do not fail or grey out on that input. They are removed from the left-hand list altogether, so the list you see holds four operations rather than six.

## Settings

Every setting of all six operations is documented below, grouped by operation. The same label sometimes appears under more than one operation, and where it does the paragraph is repeated because the surrounding controls differ. **Output Strategy** is the one setting that behaves identically in all six, so read it once under the first operation and skim it afterwards.

Each entry ends with a short sentence naming the setting's command-line flag. Those sentences belong to the optional command-line path at the end of the chapter. If you work only in the window, skip them.

### fastp Adapter + Quality Trim

**Threshold.** The lowest Phred quality score a base may have before fastp treats it as unreliable. The default is 20, which means the base caller expects to be wrong about once in a hundred, and it is the conventional floor for Illumina data. Raise it toward 30 when you need very clean bases for variant calling, and lower it when trimming is discarding too much of every read. On the command line this is `--threshold`.

The scale behind that number is worth stating once, because every threshold in this chapter uses it. Each step of ten in the Phred score means ten times fewer expected errors. A score of 10 is one wrong base in ten, 20 is one in a hundred, and 30 is one in a thousand. Steps in between fall between those figures, so 15 is one wrong base in about 32.

**Window Size.** How many neighbouring bases fastp averages before deciding to cut, which is what makes this [sliding-window trimming](../../GLOSSARY.md#sliding-window-trimming) rather than a per-base cut. The default is 4, wide enough to smooth over a single bad base so one miscall does not truncate an otherwise good read. Use a larger window for long reads whose quality drifts slowly, and a smaller one for a sharp quality cliff at the read end. On the command line this is `--window`.

**Mode.** Chooses which end of the read is scanned and in which direction, offering Cut Right, Cut Front, Cut Tail, and Cut Both. The default is Cut Right, which suits the usual Illumina pattern of good bases early and poor bases late. Switch to Cut Both when quality is poor at both ends, which is common in older Illumina runs. On the command line this is `--mode`.

The four names describe where the cut lands, not where the scan starts, which is why Cut Right walks from the start of the read. Picture the read written left to right, with its start on the left.

| Mode | What it does |
|---|---|
| Cut Right | Walks from the start toward the end and cuts everything from the first bad window rightward |
| Cut Front | Cuts bad bases off the start only, and stops at the first good window |
| Cut Tail | Cuts bad bases off the end only, working backwards from the last base |
| Cut Both | Applies Cut Front and Cut Tail, trimming both ends |

**Adapter Mode.** Chooses whether fastp works out the adapter sequence from the data itself or uses a sequence you type in, offering Auto-Detect and Manual Sequence. The default is Auto-Detect, which looks for sequence shared across many reads and is right whenever you do not know your kit's adapter by heart. Use Manual Sequence when you know the exact adapter from the library kit and auto-detection is missing it. On the command line this is `--adapter`, where giving a sequence is Manual Sequence and omitting the flag is Auto-Detect.

**Adapter Sequence.** The literal adapter sequence fastp removes from the end of each read, accepting A, C, G, T and the IUPAC ambiguity codes. It starts empty and appears on the pane only while Adapter Mode is Manual Sequence, so the default state of this operation never uses it. Fill it in when your kit documentation gives an adapter that auto-detection does not find, and note that the field takes one sequence rather than a file of them. On the command line this is `--adapter`.

IUPAC ambiguity codes are extra letters that each stand for more than one base, agreed on by the International Union of Pure and Applied Chemistry. The letter N stands for any base at all, R stands for A or G, and Y stands for C or T. Kit documentation uses them where a position in a synthetic sequence was made with a mixture rather than one base. The same codes are accepted wherever this chapter names them again.

**Output Strategy.** Chooses whether each selected dataset is trimmed into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, which keeps every library separate and is what you want whenever the selected bundles are different samples. Choose Grouped Result when several files belong to the same library and you want one trimmed bundle out of them. This setting has no command-line flag.

With one bundle selected, as in this chapter's procedure, the two choices produce the same single output and the setting changes nothing. It matters only when you have selected several. The risk to know about is selecting several by accident with Grouped Result chosen, which silently pools separate samples into one bundle. This setting behaves identically in all six operations, so the five entries below simply point back here.

### Quality Trim

**Threshold.** The lowest Phred quality score a base may have before fastp treats it as unreliable. The default is 20, meaning about one wrong base in a hundred, the same floor the combined operation uses. Raise it toward 30 for variant calling, and lower it when too much of every read is being cut away. On the command line this is `--threshold`.

**Window Size.** How many neighbouring bases fastp averages before deciding to cut. The default is 4, a window large enough that a single bad base does not end the read. Use a larger window for long reads with slowly drifting quality. On the command line this is `--window`.

**Mode.** Chooses which end is scanned and in which direction, offering Cut Right, Cut Front, Cut Tail, and Cut Both. The default is Cut Right, which walks from the start and truncates at the first bad window. Switch to Cut Both when quality is poor at both ends of the read. On the command line this is `--mode`.

**Extra arguments.** Extra fastp options passed straight through after the settings above, and they are not checked by the app before fastp sees them. It starts empty, because the four controls above already cover what most runs need. Use it only when you need a fastp feature the dialog does not expose, and expect the operation to fail rather than warn you if you mistype something here. On the command line this is `--extra-args`.

**Output Strategy.** Chooses whether each selected dataset is trimmed into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, and it behaves here exactly as described under fastp Adapter + Quality Trim above. Read that entry for when to choose Grouped Result and what a single selection changes. This setting has no command-line flag.

### Adapter Removal

**Adapter Mode.** Chooses whether fastp works out the adapter from the data or uses the sequence you type in, offering Auto-Detect and Manual Sequence. The default is Auto-Detect, which looks for sequence shared across many reads. Use Manual Sequence when your kit documents the adapter and auto-detection misses it. On the command line this is `--adapter`, with the sequence given for Manual Sequence and the flag omitted for Auto-Detect.

**Adapter Sequence.** The literal adapter sequence removed from the end of each read, accepting A, C, G, T and IUPAC ambiguity codes. It starts empty and appears only while Adapter Mode is Manual Sequence, and while Manual Sequence is chosen and this field is empty the readiness line reads "Enter an adapter sequence for manual adapter removal." Fill it in when you know the exact adapter from the library kit. On the command line this is `--adapter`.

**Output Strategy.** Chooses whether each selected dataset is trimmed into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, and it behaves here exactly as described under fastp Adapter + Quality Trim above. Read that entry for when to choose Grouped Result and what a single selection changes. This setting has no command-line flag.

### Primer Trimming

**Primer Source.** Chooses whether you type one primer sequence or point at a FASTA file holding a whole primer set, offering Literal Sequence and Reference FASTA. The default is Literal Sequence. Pick Reference FASTA for tiled amplicon schemes, which have dozens of primers, and pick the file itself under **Primer Reference** in the Inputs section, where LGE accepts only FASTA-like extensions such as `.fa`, `.fasta`, and `.fna`, along with `.lungfishref`, which is LGE's own reference bundle format described in [File Formats](../appendices/file-formats.md). On the command line this is `--literal` or `--ref`.

This control does more than change the input shape. The two choices run different programs, bbduk for Literal Sequence and cutadapt for Reference FASTA, which is why the four settings below vanish when you switch.

**Primer Sequence.** The primer sequence bbduk removes from the reads, accepting A, C, G, T and IUPAC ambiguity codes. It starts empty and appears only while Primer Source is Literal Sequence, and while it is empty the readiness line reads "Enter a literal primer sequence or switch to reference mode." Type the primer your PCR used, exactly as the order sheet gives it. On the command line this is `--literal`.

**k.** The length of the exact-match [k-mer](../../GLOSSARY.md#k-mer) bbduk uses to spot the primer, where a k-mer is a stretch of exactly that many bases. The default is 15, short enough to survive a primer that runs partway off the read and long enough to be specific. Shorten it when short primers are being missed, and lengthen it when non-primer sequence is being trimmed. On the command line this is `--kmer`.

Fifteen is specific because there are four possible bases at each of fifteen positions, which is about a billion different fifteen-base k-mers. A named one turning up by chance in a few million bases of reads is unlikely, and the figure does not depend on how large your genome is. The command line defaults `--kmer` to 23 rather than 15. That difference is by design and not a manual error, so the dialog default of 15 is the one to use when you work in the window.

**mink.** The shortest k-mer bbduk will still match when only part of the primer sits at the very end of a read, which is how a primer that runs off the edge still gets caught. The name is short for minimum k. The default is 11, comfortably below k so that partial primers are found without letting very short chance matches through. Lower it toward 8 when partial primers survive at read ends, and raise it toward k when short stretches of real sequence are being trimmed off read ends by mistake. Leave it alone when you change k, since 11 stays comfortably below any k you are likely to set. On the command line this is `--mink`.

**hdist.** How many mismatched bases a primer match may contain, which is the [Hamming distance](../../GLOSSARY.md#hamming-distance) between the primer and the read. Hamming distance counts the positions at which two strings of the same length hold different letters, so a distance of 1 means exactly one base differs. The default is 1, which tolerates a single sequencing error or a single real variant inside the primer footprint without letting unrelated sequence match. Leave it at 1 for Illumina data, which is accurate enough that a second mismatch is rarely a sequencing error, and raise it to 2 only for noisy data, meaning reads whose per-base error rate runs to several percent, as older Nanopore runs do. On the command line this is `--hdist`.

**Output Strategy.** Chooses whether each selected dataset is trimmed into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, and it behaves here exactly as described under fastp Adapter + Quality Trim above. Read that entry for when to choose Grouped Result and what a single selection changes. This setting has no command-line flag.

Primer Sequence, k, mink, and hdist all disappear from the pane when Primer Source is Reference FASTA, because that path runs cutadapt in linked mode rather than bbduk and none of those four values reaches it. In their place the pane reads "Select the primer reference FASTA in the Inputs section."

### Trim Fixed Bases

**5' Trim.** How many bases are cut from the start of every read, no matter what those bases are. The default is 0, so the operation does nothing until you set at least one of the two trim amounts, which is deliberate because a fixed trim is only ever correct when the library design says so. Set it when the library design puts a fixed tag or a UMI at the start of the read. On the command line this is `--front`.

**3' Trim.** How many bases are cut from the end of every read, applied to every read alike. The default is 0, for the same reason **5' Trim** defaults to 0. Set it when a fixed number of trailing bases are known to be unreliable. On the command line this is `--tail`.

**Output Strategy.** Chooses whether each selected dataset is trimmed into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, and it behaves here exactly as described under fastp Adapter + Quality Trim above. Read that entry for when to choose Grouped Result and what a single selection changes. This setting has no command-line flag.

There is no quality check and no minimum-length guard on this operation. The counts are applied exactly as entered, so a 5' Trim of 40 on a 35-base read leaves nothing behind.

### Filter by Read Length

**Min Length.** The shortest read kept, in bases, with reads below it discarded. It starts empty, which means no lower bound at all rather than a hidden default, so the filter does nothing until you fill in at least one of the two. For general shotgun short-read work such as this chapter's example, a value between 30 and 50 is the usual choice, and on an amplicon protocol set it to your amplicon length or a little below, which drops the short fragments that are only adapter dimer. On the command line this is `--min`.

Adapter dimer is what you get when two adapters join to each other with no sample DNA in between. It sequences as a very short read of pure adapter, so a length floor removes it.

**Max Length.** The longest read kept, in bases, with reads above it discarded. It also starts empty, meaning no upper bound. Leave it empty for ordinary Illumina work, where the instrument already caps read length, and set it on long-read data when reads far above the expected size are inflating your data. Two things produce those, a concatemer, which is several copies of the same fragment joined end to end, and a chimaera, which is two unrelated fragments joined into one read. On the command line this is `--max`.

**Output Strategy.** Chooses whether each selected dataset is filtered into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, and it behaves here exactly as described under fastp Adapter + Quality Trim above. Read that entry for when to choose Grouped Result and what a single selection changes. This setting has no command-line flag.

This filter works one read at a time. It has no option to drop a whole pair when only one mate falls below the bound, so when one mate is too short the other survives on its own and the bundle ends up holding some reads whose partner is missing. Whether a downstream tool accepts a bundle with orphaned reads depends on the tool, so keep the minimum low enough that few pairs are broken. Setting a minimum larger than the maximum makes the readiness line read "Minimum read length cannot exceed maximum read length." and the operation will not run.

## Reading the results

Select the trimmed bundle in the sidebar and the main viewport switches to the FASTQ viewport. Its top pane holds nine summary cards and three [sparkline](../../GLOSSARY.md#sparkline) charts, and that is where you read the effect of a trim. A sparkline is a small chart drawn without axes or labels, meant to show the shape of a distribution at a glance rather than exact values. This chapter uses three of the nine cards, Reads, Bases, and Mean Length, and two of the three charts, Q / Position and Length Dist. There is no separate QC tab. [Quality Control for Reads](03-quality-control.md) explains the whole pane in detail, and [Sequencing Reads](../01-foundations/02-sequencing-reads.md) explains the individual cards.

Here is what the combined fastp pass did to the R1 file, measured before and after a real run on 2026-09-06.

| Measure | Before | After |
|---|---|---|
| Reads | 45,574 | 45,534 |
| Bases | 11,331,492 | 10,540,866 |
| Mean read length | 248.6 bp | 231.5 bp |
| Shortest read | 50 bp | 1 bp (expected, and kept) |

Read the table this way. Reads is how many records the file holds, and 45,534 of the original 45,574 survived, which is 99.91 percent. Only 40 reads were removed outright, because a read is discarded only when trimming leaves nothing usable behind. Bases is the total sequence, and 10,540,866 divided by 11,331,492 is 93.0 percent, so 93.0 percent of the sequence survived and the trim cost 7.0 percent of it while costing almost no reads.

The gap between those two survival figures is the signature of a healthy trim. Here it is 99.91 percent of reads against 93.0 percent of bases, a gap of 6.9 percentage points. A gap that size means the trim removed a tail from many reads rather than removing many reads.

Mean read length falling from 248.6 to 231.5 says the same thing in a different unit. On a 250-base run the average read lost about seventeen bases off its end, which is the low-quality tail that Phred scores were already flagging before you ran anything.

The shortest read is the number that shows the cost. It falls from 50 bases to 1. A one-base read is not a bug and not a typo. It is a read whose quality collapsed near its start, cut back to almost nothing rather than thrown away, and the file keeps it. 677 reads came out shorter than 50 bases. That is why the length filter exists and why it runs after the trim.

Filtering the trimmed file at a 50-base minimum kept 44,857 reads. Against the 45,534 reads that went into the filter, that is 98.51 percent. Against the 45,574 reads of the original file, it is 98.43 percent. Quote the second figure when you want the survival across the whole chapter's work, and the first when you want the cost of the filter alone.

Two more runs against the same file make the settings concrete. Running Adapter Removal on its own changed nothing at all, giving back all 45,574 reads and all 11,331,492 bases, because these reads carry no adapter for auto-detection to find. Running Quality Trim on its own gave exactly the same 45,534 reads and 10,540,866 bases as the combined operation, which confirms that every base the combined pass removed was removed for quality. Running Quality Trim at a Threshold of 30 instead of 20 dropped both figures, to 44,916 reads and 8,947,205 bases. Raising the threshold by ten points therefore cost a further 1.59 million bases of real human sequence, which is 15.1 percent of what the Q20 trim had left. That is the trade the Threshold setting makes, shown on data where you know the answer.

Trim Fixed Bases with **5' Trim** set to 10 removed exactly 455,740 bases, which is ten bases times 45,574 reads, and kept every read. That is the operation behaving as its name promises, with no quality judgement anywhere in it.

The Operations Panel row records what ran. Right-click a finished row and choose **Copy CLI Command** to put the exact command on the clipboard, which is the item that matters when you want to see or repeat what ran. The durable record of [provenance](../../GLOSSARY.md#provenance) lives in the bundle's `provenance/` folder, which stores the resolved settings, the command, the checksums, and the runtime. To reach that folder without a terminal, right-click the bundle in the sidebar, choose **Show in Finder**, and open `provenance` inside the folder that opens. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) covers what that record holds.

## What good looks like

The summary on a new bundle does not refresh itself, so run **Tools > QC & Reporting > Refresh QC Summary...** on the trimmed bundle before you compare its top pane against the input's. Then apply these four checks in order.

**Check one, the charts.** The chart labelled Q / Position, which plots mean quality against position along the read, should no longer dip below Q20 at the read end. Q20 written this way is the same number as the **Threshold** of 20 you set in the dialog, a Phred score of 20. The chart labelled Length Dist. should tighten around the expected fragment size with most reads still standing. Both names are given here exactly as they appear on screen.

**Check two, the read survival rate.** For typical Illumina data expect 90 percent or more of reads to survive a quality trim, and this example's 99.91 percent sits comfortably inside that. A survival rate below about 70 percent means the Threshold is too harsh for the data, and the fix is to lower it rather than to accept the loss.

**Check three, the base survival, read separately from the read survival.** Reads surviving while bases fall is a trim working correctly. Reads and bases falling together in similar proportion means whole reads are being discarded, which points at a Threshold set for cleaner data than you have. To compare the two, select the input bundle in the sidebar and note its Bases card, then select the output bundle and note its Bases card, since the viewport shows one bundle at a time.

**Check four, the output location.** A trimmed bundle from the operations window lands directly under `Analyses/`, named for its input and the operation. A result anywhere else came from a different route than the one you thought you took.

### When a trim goes wrong

**Too few reads survive.** When survival after quality trimming falls below about 70 percent, the Q20 floor is probably too harsh. Re-run at a Threshold of 15 and compare the two. By the scale given in the Settings section, a threshold of 15 accepts bases the base caller expects to be wrong about once in 32, against once in a hundred at 20. Long-read data sits far lower by nature and should never be quality-trimmed against an Illumina threshold at all. When survival drops sharply after the length filter instead, the Min Length is too high for a run that made short reads on purpose, so lower it or skip the filter.

**Low quality persists after trimming.** When the Q / Position chart still dips below Q20 at the read ends after a Q20 trim, fastp's sliding window probably stepped over isolated bad bases inside an otherwise clean window. Dropping **Window Size** from 4 to 1 judges each base on its own and will clear them, at the cost of speed and a more aggressive cut.

A window of 1 is a diagnostic setting, not the normal recommendation, and it does not contradict the default of 4. The two settings suit two different chart shapes. A window of 4 is right when the chart shows quality declining steadily toward the read end, which is the ordinary case, because averaging over four bases keeps one unlucky miscall from truncating a good read early. A window of 1 is right when the chart is otherwise flat and healthy but carries isolated spikes downward, since those are exactly the bases a four-base average hides. Set it back to 4 once you have seen which shape you have.

**Adapter still suspected after Adapter Removal.** Auto-detection can miss an adapter it has too few examples of. The adapter fastp settled on is not reported anywhere in the app's summary, so you cannot check it there. Re-run with **Adapter Mode** set to Manual Sequence and paste your kit's adapter sequence instead.

**Primer bases visible after read-level primer trimming.** bbduk matches primer k-mers against the read text with a mismatch tolerance of one base by default. A read carrying a real variant inside the primer footprint can fall outside that tolerance and slip through untrimmed. Raising **hdist** helps a little and costs specificity. The structural fix is the alignment-level trim covered in [Primer Trimming](../04-alignments/03-primer-trimming.md), which matches on position rather than sequence.

## On the command line

If you have never used a terminal, skip this whole section. Nothing in it is needed to use the operations in the window, and nothing later in this manual requires you to have run a command. The short command-line sentences inside the Settings entries above can be skipped for the same reason. The `lungfish-cli` program ships inside the application, and the [CLI Reference](../appendices/cli-reference.md) appendix says where it lives.

Each subcommand takes one input file and requires `--output`. Add `--force` to overwrite an output that already exists, and `--compress` to write the result gzip-compressed. Both are available on every subcommand below. A backslash at the end of a line is formatting rather than something you type. It tells the shell that the command continues on the next line, and if you retype a command on one long line you leave the backslashes out.

```bash
# The combined adapter and quality pass, at the same defaults the dialog uses.
lungfish-cli fastq trim HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --threshold 20 --window 4 --mode cut-right --adapter-trimming \
  --output R1.trim.fastq --force

# Quality only, leaving adapters alone.
lungfish-cli fastq quality-trim HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --threshold 20 --window 4 --mode cut-right \
  --output R1.qtrim.fastq --force

# Adapters only, auto-detected.
lungfish-cli fastq adapter-trim HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --output R1.adapt.fastq --force

# Ten bases off the 5' end of every read.
lungfish-cli fastq fixed-trim HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --front 10 --output R1.front10.fastq --force

# Primer trimming at the dialog's k default rather than the CLI's.
# The sequence below is an illustrative example, not a primer from any kit.
# This data has no primers, so the command is safe to run but shows the
# shape of the call rather than a result worth keeping.
lungfish-cli fastq primer-remove HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --literal GCTGGGATTACAGGCATGAGCCACC \
  --kmer 15 --mink 11 --hdist 1 \
  --output R1.primer.fastq --force

# Drop everything under 50 bases, last of all.
lungfish-cli fastq length-filter R1.trim.fastq \
  --min 50 --output R1.trim.len50.fastq --force
```

Three differences between the command line and the window are worth knowing. `fastq trim` carries an `--adapter-trimming` and `--no-adapter-trimming` pair, defaulting to `--adapter-trimming`, and the negative form has no counterpart in the dialog because the combined operation always trims adapters. `fastq trim` and `fastq quality-trim` both take `--extra-args` for fastp options passed through verbatim, while only the Quality Trim pane offers that field in the window. `fastq primer-remove` defaults `--kmer` to 23 where the dialog defaults **k** to 15, so a command copied out of the help text will not match a dialog run unless you say `--kmer 15`, as the block above does.

`fastq primer-remove` also exposes the second engine, which the dialog reaches only by switching **Primer Source** to Reference FASTA. Pass `--engine cutadapt-linked` to select it. Linked mode means cutadapt looks for the forward and reverse primer of an amplicon as a linked pair on the same read, rather than for each primer on its own, which is what a tiled amplicon scheme calls for. Tune it with `--minimum-overlap`, which defaults to 12 and is a number of bases, and `--error-rate`, which defaults to 0.12 and is the fraction of the primer's own length allowed to mismatch, so 0.12 on a 25-base primer permits three mismatched bases. Both of those apply to the cutadapt engine alone and are ignored by the bbduk default.

## Next

Continue to [Decontamination](05-decontamination.md) to remove host and ribosomal reads, or go to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) if your reads are clean and ready to map.

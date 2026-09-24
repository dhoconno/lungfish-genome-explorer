---
title: Subsetting and Extraction
chapter_id: 03-reads/06-subsetting-and-extraction
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 19
task: Cut a read bundle down to a smaller one, either by drawing a random sample or by keeping only the reads that match a name, a sequence motif, or an adapter.
tags: [reads, subsample, extract, motif, sequence-filter, virtual-bundle]
tools: [seqkit, bbduk, reformat]
parameters_refs: [fastq.subsample-by-proportion, fastq.subsample-by-count, fastq.extract-reads-by-id, fastq.extract-reads-by-motif, fastq.select-reads-by-sequence]
entry_points:
  - "Tools > Search & Subsetting > Subsample by Proportion..."
  - "Tools > Search & Subsetting > Subsample by Count..."
  - "Tools > Search & Subsetting > Extract Reads by ID..."
  - "Tools > Search & Subsetting > Extract Reads by Motif..."
  - "Tools > Search & Subsetting > Select Reads by Sequence..."
  - "CLI: lungfish-cli fastq subsample, search-text, search-motif, sequence-filter"
shots:
  - id: search-subsetting-menu
    caption: "The Tools > Search & Subsetting submenu, listing the five subsetting and extraction operations."
  - id: select-reads-by-sequence-pane
    caption: "The Select Reads by Sequence pane at its defaults, showing Search End on 5' End, Min Overlap 16, Error Rate 0.15, and Keep Matched Reads on."
  - id: subsample-by-count-pane
    caption: "The Subsample by Count pane with its single Count field and the Output Strategy picker below it."
illustrations: []
glossary_refs: [fastq, bundle, sidebar, provenance, checksum, adapter, barcode, depth, shotgun, reverse-complement, seqkit, cutadapt, bbduk, subsampling, virtual-bundle, materialization, sequence-motif, alu-element, read-identifier, regular-expression, required-setup-pack]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Subsetting means making a smaller read bundle out of a larger one. A [bundle](../../GLOSSARY.md#bundle) is a folder Lungfish Genome Explorer (LGE) treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. A bundle of reads has a name ending in `.lungfishfastq`. Every operation in this chapter reads one bundle and writes a new one. The bundle you started from is never altered, so a subset that turns out wrong costs you nothing but the time it took.

There are two reasons to make a smaller bundle, and LGE keeps them apart because they call for different tools.

The first reason is size. You want fewer reads, and you do not care which ones, so long as the smaller set still looks like the larger one. That is [subsampling](../../GLOSSARY.md#subsampling), drawing reads at random. A random draw keeps the composition of the original, because every read has the same chance of being picked. Subsample by Proportion keeps a fraction of the reads, and Subsample by Count keeps a fixed number.

The second reason is identity. You want particular reads, and you can say what makes them particular, either something in the read's name line or something in its bases. Every read in a [FASTQ](../../GLOSSARY.md#fastq) file starts with a name line, the line beginning with `@` that identifies that read. One from this chapter's example data looks like this.

```
@HISEQ1:93:H2YHMBCXX:1:1101:1457:14988
```

Three operations work on identity. Extract Reads by ID matches text against the name line. Extract Reads by Motif matches a short stretch of bases, called a [sequence motif](../../GLOSSARY.md#sequence-motif), against each read's own bases. Select Reads by Sequence matches an [adapter](../../GLOSSARY.md#adapter) or a [barcode](../../GLOSSARY.md#barcode), the short tag added during library preparation so pooled samples can be told apart. It allows some mismatches, looks at one end of the read, and can keep either the reads that match or the reads that do not.

| Operation | What you give it | What comes back |
|---|---|---|
| Subsample by Proportion | A fraction such as 0.1 | Roughly that share of the reads, drawn at random |
| Subsample by Count | A number such as 10000 | That many reads, drawn at random |
| Extract Reads by ID | Text to find in the read's name line | The reads whose name line matched |
| Extract Reads by Motif | A short sequence of bases | The reads whose sequence contains it |
| Select Reads by Sequence | An adapter or barcode, plus how strictly to match | The reads that carry it, or the reads that do not |

If you want a smaller version of the same data, subsample. If you want a specific set of reads and you can describe them, extract or select.

## Why you would do this

Three situations account for most subsetting.

The first is testing. A full run can take hours to assemble or classify. Cutting it to ten thousand reads first tells you in minutes whether the pipeline runs and whether the output has the shape you expected.

The second is fair comparison. [Depth](../../GLOSSARY.md#depth) is how many reads cover the thing you are measuring. If one sample came back with four times as many reads as another, any measure that grows with depth will favour the deeper sample for a reason that has nothing to do with biology. Cutting both to the same count with Subsample by Count removes that bias.

The third is asking a direct question of the reads. Did the library pick up the primer we designed? Which reads came from the run that failed quality control? The three extraction operations answer such questions by handing you the matching reads.

This chapter works on the HG002 chromosome 20 slice. HG002 is a human genome from the Genome in a Bottle project whose true sequence is already known. The bundle holds 91,148 reads in 45,574 pairs, up to 250 bases long, and every count in this chapter is measured against that number. The reads came off two instruments, which name themselves in every read name as `HISEQ1` and `D00360`, so Extract Reads by ID has something real to sort on. Being human, the reads are full of [Alu elements](../../GLOSSARY.md#alu-element), the most abundant repeat in the human genome, which gives Extract Reads by Motif a genuine target. And a small number of reads run into the sequencing adapter. That happens when a DNA fragment is shorter than 250 bases, so the instrument reads past its end and into the adapter attached during library preparation. Finding those reads is what Select Reads by Sequence was built for.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the pair following [Importing Sequencing Reads](01-importing-fastq.md), so it becomes the bundle `HG002.chr20.10.0-10.5Mb`, which holds 91,148 reads. Every operation here starts from a bundle in the sidebar rather than a file on disk. The worked counts in this chapter come from the bundle's own file, run from the command line, and a run from the Tools menu gives the same counts. On a paired bundle every operation keeps or drops the two mates of a pair together, so each count is even.

These operations use seqkit, reformat, and bbduk. Each arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

The result is a new read bundle written straight into `Analyses/`, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Subsampling the bundle by count gives you `HG002.chr20.10.0-10.5Mb-subsampleCount.lungfishfastq`.

## Procedure

All five operations work the same way. Select the read bundle in the [sidebar](../../GLOSSARY.md#sidebar), choose the operation from the **Tools > Search & Subsetting** submenu, fill in its fields, and click Run. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

<!-- SHOT: search-subsetting-menu -->

Follow these steps to make a ten-thousand-read test slice, the most common of the five jobs.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar to select it.
2. Choose **Tools > Search & Subsetting > Subsample by Count...** from the menu bar.
3. Type `10000` into the **Count** field. While the field is empty the Run button is disabled and the dialog reads "Enter a positive read count." That message is a prompt, not an error.
4. Leave **Output Strategy** on Per Input. With one bundle selected it makes no difference.
5. Click Run.

<!-- SHOT: subsample-by-count-pane -->

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The new bundle appears in the sidebar when the run finishes.

The other four operations follow the same five steps with different fields in step 3. Extract Reads by ID takes a **Query**, a **Field** choice, and a switch for pattern matching that the Settings below explain. Extract Reads by Motif takes a **Pattern** and the same switch. Subsample by Proportion takes a **Proportion** between 0 and 1. Select Reads by Sequence takes a sequence and five more controls, which set where and how strictly to match it and which reads to keep.

<!-- SHOT: select-reads-by-sequence-pane -->

## Settings

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output. Leave it on Per Input, the default. [Trimming and Filtering](04-trimming-and-filtering.md#shared-settings) explains the two choices. This setting has no command-line flag.

### Subsample by Proportion

**Proportion.** The share of reads to keep, so 0.1 keeps roughly one read in ten. The field starts empty and accepts a fraction above 0 and up to 1, and the Run button stays disabled with "Enter a proportion between 0 and 1." until you supply one. Use it when you want each library cut by the same factor, so a library that started twice as deep as another ends up twice as deep. On the command line this is `--proportion`.

The word roughly matters. The operation decides pair by pair whether to keep each one, so the count that comes back is close to the fraction rather than exactly on it. A tenth of 91,148 is about 9,115, and three runs at 0.1 on the fixture returned 9,152, 9,240, and 9,304 reads. Each run draws a fresh random sample, which is why the counts differ.

### Subsample by Count

**Count.** The number of reads to keep. The field starts empty and accepts a whole number above 0, showing "Enter a positive read count." until you enter one. Use it when you want two or more libraries cut to the same depth so a comparison between them is not decided by which one was sequenced harder. On the command line this is `--count`.

Count is exact. Asking for 10,000 reads from the fixture returned exactly 10,000, which is 5,000 pairs. On a paired bundle an odd count is rounded down to keep whole pairs, so asking for 10,001 also returns 10,000. If the bundle holds fewer reads than you asked for, you get all of them rather than an error.

Both subsample operations draw a new random sample every run and write the random seed they used, the number that fixes which reads are drawn, into the result's provenance record. The window has no seed field, so to repeat a draw exactly, pass that seed to `--seed` on the command line.

### Extract Reads by ID

**Query.** The text matched against each read's name line, which carries the [read identifier](../../GLOSSARY.md#read-identifier). Reads whose chosen field matches are written out. The field starts empty, with "Enter a read ID or search pattern." shown until you fill it. Set it to one exact read name to pull out a single read, or, with **Use Regular Expression** on, to the instrument name, run, or lane that marks the reads you want. On the command line this is `--query`.

A plain query must match the whole identifier, not a piece of it. Searching the fixture for `HISEQ1` with **Use Regular Expression** off returns zero reads, even though 21,244 identifiers begin with `HISEQ1`, because no read is named exactly `HISEQ1`. Searching for the complete identifier `HISEQ1:93:H2YHMBCXX:1:1101:1457:14988` returns two reads, the pair that shares that name. Exact matching is the safer default, because a query cannot quietly return far more reads than you meant. The first colon-separated field of an Illumina identifier is the instrument name, so a search for `HISEQ1` is a search for one instrument's reads.

**Field.** Chooses which part of the name line is searched, offering ID and Description. The default is ID, the first word after the `@`, because that is where the identifier lives. Choose Description to search the whole name line, the identifier plus any free text after the first space, such as `1:N:0:ATCACG`, which records which read of the pair this is and the sample's index sequence. A plain query must then equal the entire line, so turn on **Use Regular Expression** to find a label inside it. On the command line this is `--field`, which takes `id` or `description`.

Many FASTQ files, the HG002 slice among them, have no description at all, so searching either field gives the same answer on them. Leave this on ID unless you have looked at your headers and seen a description.

**Use Regular Expression.** Treats the query as a pattern rather than as literal text, which lets it match part of an identifier or several identifiers at once. It is off by default, so a query is an exact whole-identifier match until you turn this on. Turn it on whenever you are matching a prefix, a lane, or anything short of a complete read name. On the command line this is `--regex`.

A [regular expression](../../GLOSSARY.md#regular-expression) is a small pattern language, but plain text with this switch on already means "contains this anywhere". Searching the fixture for `HISEQ1` with it on returns all 21,244 reads from that instrument. The characters `. * + ? [ ] ( ) { } ^ $ | \` become pattern instructions once the switch is on, so a period, for instance, comes to mean any single character. Colons and digits are unaffected, so an Illumina identifier can be pasted in as it stands.

### Extract Reads by Motif

**Pattern.** The sequence motif searched for inside each read's bases, and reads containing it are written out. The field starts empty and shows "Enter a motif or search pattern." until filled. Set it to a primer's sequence, a restriction site, a repeat, or any short sequence whose presence in a read is what you want to test. On the command line this is `--pattern`.

This operation searches both strands. A read carrying the [reverse complement](../../GLOSSARY.md#reverse-complement) of your pattern, the same sequence read backwards on the opposite strand, matches just as a read carrying the pattern itself does. Searching the fixture for the 26-base Alu motif `GCCTCCCAAAGTGCTGGGATTACAGG` returned 1,780 reads, which is 890 pairs. Of those reads, 528 carry the motif as written, 539 carry its reverse complement, and the other 713 are mates kept with them. That near-even split is expected on [shotgun](../../GLOSSARY.md#shotgun) data, a library made by breaking DNA at random, where a fragment is equally likely to be read from either end.

**Use Regular Expression.** Treats the pattern as an expression rather than as a literal run of bases, so it can allow more than one base at a position. It is off by default, and with it off the pattern must appear letter for letter. Turn it on when the motif has a degenerate position, a position where the base varies. On the command line this is `--regex`.

Square brackets are the piece of pattern syntax worth learning here. Writing `GCCTCCCAAAGTGCTGGGATTACAG[GA]` means "G or A in the final position". That pattern returned 1,936 reads from the fixture against the literal pattern's 1,780, picking up 78 more pairs whose Alu copy differs at that base. IUPAC ambiguity codes such as `R` for A or G are read as the letter `R` itself, so write the alternatives out in brackets instead, as `[AG]`.

### Select Reads by Sequence

This operation exists because the other two searches match exactly and biology rarely does. It allows a stated fraction of the matched bases to be wrong, it looks at one end of the read, and it can return either the reads that matched or the reads that did not. Those three abilities make it the right tool for an adapter or a barcode. It runs [bbduk](../../GLOSSARY.md#bbduk), which is why the settings below behave as they do.

**Sequence or FASTA Path.** What the reads are matched against. Type a run of bases to match that one sequence, or give the full path to a FASTA file, a plain text file of named sequences without quality scores, to match any sequence in it. To get a file's full path, select it in the Finder, hold Option, and choose Copy as Pathname from the Edit menu. LGE treats the text as a path when it contains a slash or ends in `.fa`, `.fasta`, `.fna`, or `.fas`, so a typed sequence is never mistaken for a file. The field starts empty and shows "Enter a literal sequence or FASTA path." until filled. Use a file when you are screening against a set of adapters or barcodes. On the command line these are two options, `--sequence` and `--fasta-path`.

**Search End.** Chooses which end of the read is searched, offering 5' End and 3' End. It defaults to 5' End, the first bases of the read as it appears in the file, which is where a barcode sits. Choose 3' End for a read-through adapter, the usual case, since an adapter shows up at the far end of a read when the fragment was shorter than the read. On the command line this is `--search-end`, where `left` is the 5' end and `right` is the 3' end.

**Min Overlap.** The number of consecutive bases of your sequence that must line up inside a read, allowing the differences Error Rate permits, before the read counts as a hit. It defaults to 16 in the window, long enough that a match means something on 250-base reads. Lower it only when you expect a short adapter remnant. To raise it, lower Error Rate at the same time, for the reason given under Error Rate. On the command line this is `--min-overlap`, which defaults to 8 rather than 16.

The gap between 16 and 8 matters more than it sounds. Searching the fixture for the Illumina TruSeq adapter `AGATCGGAAGAGCACACGTC` at the 3' end matched 518 reads at an overlap of 16, 40,456 reads at 12, and 89,592 reads at 8. There are not tens of thousands of adapter-contaminated reads in this fixture. An 8-base match turns up by chance in almost any 250-base read. Treat a result that keeps most of your reads as a sign the overlap is too low, not as a sign of contamination.

**Error Rate.** The fraction of the matched bases allowed to differ, which lets a real adapter with a sequencing error in it still match. It defaults to 0.15 in the window. LGE multiplies it by Min Overlap and rounds to the nearest whole number of differences, counting a substituted, missing, or extra base as one and never allowing fewer than one, so 16 times 0.15 allows two. Lower it when false matches are the worry. On the command line this is `--error-rate`, which defaults to 0.1.

bbduk accepts at most two differences, so Min Overlap times Error Rate must stay below 2.5. At the default Error Rate of 0.15 that means a Min Overlap of 16 at most, and at 0.1 it allows up to 24. A pair whose product rounds to three or more, such as 18 with 0.15, makes the run stop with an error and write nothing. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

**Keep Matched Reads.** Decides which half of the split you get back. It starts on in the window, so the operation keeps the reads that carry the sequence. Turn it off to keep the reads without the sequence, which is what you want when you are using an adapter to remove reads rather than to find them. On the command line this is `--keep-matched`, which is off unless you type it, so a command meant to reproduce a window run has to include it.

The two halves add up, which makes a useful check. On the fixture, keeping matched reads returned 518, turning the switch off returned 90,630, and the two sum to 91,148.

**Search Reverse Complement.** Asks for the reverse complement of your sequence to be searched as well. It is off by default. bbduk already searches both strands, so on the fixture the adapter search returned the same 518 reads with this switch on or off, and you can leave it at the default. In the current release the switch changes nothing. On the command line this is `--search-rc`.

## Reading the results

Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. The cards on a result are measured over the result, not over its parent, the bundle it was made from. Reads is the card to look at first, because it is the direct answer to what the operation did.

Here is what each operation returned on the bundle's 91,148 reads.

| Operation and setting | Reads out | Share of the input |
|---|---|---|
| Subsample by Proportion, 0.1 | 9,152 to 9,304 across three runs | about 10% |
| Subsample by Count, 10000 | 10,000 | 11.0% |
| Extract Reads by ID, `HISEQ1` with the regex switch on | 21,244 | 23.3% |
| Extract Reads by Motif, the 26-base Alu motif | 1,780 | 2.0% |
| Select Reads by Sequence, TruSeq adapter at the 3' end | 518 | 0.6% |

The first two rows are requests, and they say only that the sampler did what it was told. The last three are findings about the data. The third says 21,244 reads, 10,622 pairs, came off the `HISEQ1` instrument and the remaining 69,904 came off `D00360`. The fourth counts whole pairs, and the 1,067 reads that carry the motif themselves make about one read in eighty-five carrying this stretch of an Alu element, which fits a human shotgun library, since Alu elements make up about a tenth of the genome and only 26 bases of each copy are being matched. The fifth says about half of one percent of pairs, 259 of 45,574, had a read that ran into the adapter, a healthy figure for 250-base reads. A figure in the tens of percent would mean much of the library was shorter than the read length, and the thing to check then is the fragment size the library was built to.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains.

### Virtual bundles and materialization

A result from the **Tools > Search & Subsetting** menu holds its reads as an ordinary compressed FASTQ file inside the bundle, so it can be copied or shared on its own like any other read bundle.

Some read bundles are a lighter kind, a [virtual bundle](../../GLOSSARY.md#virtual-bundle). Demultiplexing a run into one bundle per barcode, which [Oxford Nanopore Runs](07-ont-runs.md) covers, writes virtual bundles, and so did subsetting in earlier versions of LGE. A virtual bundle stores a recipe for its reads rather than a copy. For a subset the recipe is a list of the chosen read names, `read-ids.txt`, plus a manifest naming the parent bundle. Beside the recipe sits `preview.fastq`, the first thousand or so reads, which is what the viewport draws. If you choose **Show in Finder** on a virtual bundle and find `preview.fastq` as its only FASTQ file, that is correct, not a truncated result. The Reads card still shows the real count, taken from the manifest.

No reads are lost by this arrangement. Every read the virtual bundle names is still in the parent, so ten test slices of one bundle cost about as much disk as one. The catch is that a virtual bundle means nothing without its parent. Copying it alone to another computer, or sending it to a colleague, carries the recipe without the reads it points at.

When a later step needs the actual reads, LGE performs [materialization](../../GLOSSARY.md#materialization). It rebuilds the full reads from the parent as the first step of that job and clears them away at the end. You never ask for this, and there is no button for it, so a virtual bundle can be selected for mapping or classification exactly like any other.

To get the reads of any bundle as an ordinary FASTQ file, for a program outside LGE or for a colleague, select the bundle and choose **File > Export > FASTQ...**, or right-click it in the sidebar and choose **Export as FASTQ...**. LGE rebuilds the full reads on the way out, so a virtual bundle exports every read it names, not just the preview.

## What good looks like

Four checks catch nearly every subsetting mistake.

Check the read count against what you asked for. A count subsample should return exactly your number, or every read if the input held fewer. A proportion subsample lands near your fraction rather than on it, within about one percent of the input on a file this size.

Check that a subsample kept the shape of the original. The fixture's reads are 76.7 percent `D00360` and 23.3 percent `HISEQ1`, and one 0.1 subsample came back 76.4 percent and 23.6 percent. The quality and length cards should track the parent's just as closely. A subset whose cards differ noticeably from the parent's was not drawn the way you think.

Check that an extraction returned a plausible number. Zero reads usually means the match was stricter than you intended, most often an Extract Reads by ID query that needed **Use Regular Expression** turned on. Nearly all the reads usually means the opposite, most often a Min Overlap low enough to match by chance.

Check the search before trusting an absence. Finding no reads with your primer is evidence the primer is absent only if the search would have found it. Run the same search first for something you know is present, a positive control. On human data the Alu motif in this chapter serves, since a human shotgun library should return several hundred reads per fifty thousand. If the Alu search also comes back empty, the problem is the search, not your primer. Extract Reads by Motif demands a letter-for-letter match, so a single sequencing error hides a read from it. Select Reads by Sequence allows some mismatches, so prefer it whenever a negative result would change your conclusion.

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

The commands read the FASTQ file inside the imported bundle, so they reproduce the counts above. The first line stores its path in a shortcut name. Replace the path with your own, keeping the double quotes.

```bash
READS="MyProject.lungfish/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz"

# Subsample a fraction, then a fixed count. --seed repeats an earlier draw.
lungfish-cli fastq subsample "$READS" \
  --proportion 0.1 --seed 1 --output subset-10pct.fastq
lungfish-cli fastq subsample "$READS" \
  --count 10000 --output subset-10k.fastq

# Extract by name line. Without --regex the query must match the whole identifier.
lungfish-cli fastq search-text "$READS" \
  --query HISEQ1 --regex --output hiseq-reads.fastq

# Extract by sequence motif. Both strands are searched.
lungfish-cli fastq search-motif "$READS" \
  --pattern GCCTCCCAAAGTGCTGGGATTACAGG --output alu-reads.fastq

# Select by adapter presence, at the window's defaults rather than the command line's.
lungfish-cli fastq sequence-filter "$READS" \
  --sequence AGATCGGAAGAGCACACGTC \
  --search-end right --min-overlap 16 --error-rate 0.15 --keep-matched \
  --output adapter-reads.fastq
```

Each command reads the pairing the bundle records and keeps mates together, as the window does. `--pairing` overrides that choice, taking `interleaved`, `single`, or `auto`, the default, which reads the bundle's record first and then the read names. A bundle written by a merge recipe holds merged single reads between the pairs that did not merge. The two search commands match reads by name, so on such a file they still return both mates of a matching pair and a matching merged read on its own. The filters and `subsample` cannot pair such a file safely, so they treat every record as a single read and say so on standard error.

Four defaults of `sequence-filter` differ from the window and change the result, which is why the last command states every setting. `--search-end` defaults to `both`, an option the window does not offer, `--min-overlap` defaults to 8 instead of 16, `--error-rate` defaults to 0.1 instead of 0.15, and `--keep-matched` is off unless you type it, the opposite of the window. To pull reads from an explicit list of read names rather than a pattern, `lungfish-cli extract reads --by-id` does it, and its options are listed in the [CLI Reference](../appendices/cli-reference.md).

## Next

Continue to [Oxford Nanopore Runs](07-ont-runs.md) for importing and demultiplexing a nanopore run, or jump to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) to align the subset you just made. Select the subset bundle there as you would any other.

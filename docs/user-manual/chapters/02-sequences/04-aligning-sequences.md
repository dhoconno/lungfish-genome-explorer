---
title: Aligning Sequences
chapter_id: 02-sequences/04-aligning-sequences
audience: analyst
prereqs: [01-foundations/01-what-is-a-genome, 02-sequences/01-importing-and-viewing]
estimated_reading_min: 19
task: Align a set of related sequences with MAFFT, read the alignment in the alignment viewport, and export the result.
tags: [sequences, msa, mafft, alignment, conservation, export]
tools: [mafft]
parameters_refs: [msa.mafft, msa.view, msa.export, import.msa]
entry_points:
  - Tools > Multiple Sequence Alignment > MAFFT...
  - Right-click a FASTA selection > Align with MAFFT...
  - File > Import Center... > Alignments > Multiple Sequence Alignments
  - "CLI: lungfish-cli align mafft"
  - "CLI: lungfish-cli msa export"
shots:
  - id: mafft-dialog
    caption: "The MAFFT pane of the operations dialog, with the scope summary line above the Strategy popup and the collapsed Advanced Options group."
  - id: alignment-viewport-primate-mito
    caption: "The primate mitochondrial alignment open in the alignment viewport, showing the resizable name gutter, the pinned comparison row above the five sequences, the column header, and the conservation overview strip."
  - id: export-alignment-sheet
    caption: "The Export Alignment sheet, with its Destination choices above the Sequences gap choice and the Format popup."
illustrations:
  - id: msa-column-homology
    caption: "Three sequences before and after alignment, showing how MAFFT inserts gaps so homologous bases share a column."
glossary_refs: [msa, mafft, alignment-column, gap, conservation, consensus-sequence, homologous, fasta, accession, mitochondrial-genome, p-distance, percent-identity, plugin-pack, provenance, checksum, bundle, sidebar, inspector, operations-panel, import-center, variable-site, reverse-complement]
features_refs: []
fixtures_refs: [primate-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A [multiple sequence alignment](../../GLOSSARY.md#msa), or MSA, takes a set of related sequences and lines them up so that positions descended from the same ancestral position sit in the same column. Two positions that share an ancestor this way are [homologous](../../GLOSSARY.md#homologous). The result is a rectangle. Each row is one input sequence, and each column is one inferred homologous position.

Sequences of the same gene are rarely the same length. One lineage gains bases that another never had, and one lineage loses bases the other kept. To keep the rectangle square, the aligner writes a [gap](../../GLOSSARY.md#gap) character, the `-` symbol, into a row that has nothing to put in that column. A row's length in the alignment is therefore its own length plus the gaps added to it.

![Three short sequences before and after gap insertion so homologous bases share columns](../../assets/illustrations-imagegen/02-sequences/04-aligning-sequences/msa-column-homology.png)

Once the rectangle exists, a column is something you can count. A residue is one unit of the sequence, a single base in DNA or a single amino acid in a protein. Take a column of five rows where four read `A` and one reads `G`. Four of the five agree, so that column scores 4 divided by 5, or 0.8. That number is [conservation](../../GLOSSARY.md#conservation), the share of the non-gap rows that carry the column's most common residue. A column where every row reads `A` scores 1 and is fully conserved. The disagreement in the other columns is the signal that later analyses read.

Lungfish Genome Explorer (LGE) aligns with [MAFFT](../../GLOSSARY.md#mafft), a widely used alignment program, and stores the result as a `.lungfishmsa` [bundle](../../GLOSSARY.md#bundle). A bundle is a folder that the Finder shows as one file, so you can copy, move, and back it up like any other file. The alignment bundle holds the aligned sequences, the unaligned input they came from, and a record of how the run was made. In practice, build the alignment first, check its columns, and only then hand it to whatever comes next.

A [consensus sequence](../../GLOSSARY.md#consensus-sequence) is one sequence built from the alignment by writing down each column's most common residue. Where the rows agree too weakly, it writes a mask character such as `N` instead of a base. LGE draws the consensus as a row pinned above the sequences, so you can see at a glance where each row departs from the majority.

## Why you would do this

This chapter aligns five primate [mitochondrial genomes](../../GLOSSARY.md#mitochondrial-genome). The mitochondrial genome is the small circular DNA inside the mitochondrion, separate from the chromosomes in the nucleus. It is a common choice for comparing species because every cell carries many copies of it, it is short enough to sequence whole, and it changes faster than most nuclear DNA.

The five are human, chimpanzee, gorilla, rhesus macaque, and cynomolgus macaque. All five sit one after another in the one fixture file, `primate-mito.fasta`. The table lists the label each record carries in the file, its [accession](../../GLOSSARY.md#accession) (the stable identifier NCBI gives a record), and its length.

| Label in the file | Accession | Species | Length in bases |
|---|---|---|---|
| `Human_NC_012920.1` | `NC_012920.1` | Human | 16,569 |
| `Chimp_NC_001643.1` | `NC_001643.1` | Chimpanzee | 16,554 |
| `Gorilla_NC_011120.1` | `NC_011120.1` | Gorilla | 16,412 |
| `RhesusMacaque_NC_005943.1` | `NC_005943.1` | Rhesus macaque | 16,564 |
| `CynomolgusMacaque_NC_012670.1` | `NC_012670.1` | Cynomolgus macaque | 16,575 |

The gorilla is the shortest at 16,412 bases and the cynomolgus macaque the longest at 16,575, a spread of 163 bases. No two are the same length, so none of them can be compared position by position until they are aligned. Their relationships are settled science, which makes them a good teaching set. You know before you start that the two macaques should look most alike, and that the human and the chimpanzee should look more alike than either looks to a macaque. An alignment that says otherwise is telling you something went wrong with the run, not something new about primates.

Alignment is also the step most later work depends on. Column-by-column conservation is how you find a stretch steady enough to design a primer against. Column-by-column disagreement is what tree building reads. A pairwise identity matrix, which asks how similar every pair of sequences is, is computed straight off the aligned columns. None of those questions can be asked of unaligned sequences.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the primate-mito fixture. Download `primate-mito.fasta` from [primate-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/primate-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `multiple-sequence-alignment` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The pack ships MAFFT 7.526, the version that produced the numbers in this chapter. Docker Desktop is not needed.

Import the FASTA the way [Importing and Viewing a Sequence](01-importing-and-viewing.md#procedure) describes, so the five records sit in the project as one `.lungfishref` reference bundle. [FASTA](../../GLOSSARY.md#fasta) is the plain-text sequence format in which each record is a `>` name line followed by its bases. The alignment itself takes well under a minute on a current Mac.

## Procedure

### Align the five genomes

1. Click the imported bundle in the sidebar under `Reference Sequences/`. The viewport opens on a table with one row per sequence and Sequence, Length, and Role columns, so the five primates are listed there. Click the first row and Shift-click the last to select all five, so the run covers every sequence.
2. Choose **Tools > Multiple Sequence Alignment > MAFFT...**. The FASTQ/FASTA Operations dialog opens on the MAFFT pane. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.
3. Read the line at the top of the pane. Because you are aligning the whole file, it states what will run, either "Aligning all 5 sequences." or "Aligning the 5 sequences you selected." A **Sequences to align** choice takes its place only when you select some but not all of a file's sequences.
4. Leave **Strategy** on **Automatic**, leave the Advanced Options group collapsed, and click **Run**. MAFFT is the only aligner in LGE, so there is no aligner to pick.

    <!-- SHOT: mafft-dialog -->

5. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). When it finishes, click the new bundle under `Analyses/Multiple Sequence Alignments/` to open the alignment viewport.

The bundle is named after the input, so this run writes `Analyses/Multiple Sequence Alignments/primate-mito.lungfishmsa`. Run it again and LGE adds a counter, giving `primate-mito-2.lungfishmsa`, so the first result is never overwritten. The dialog has no Output Strategy choice, because MAFFT always writes one alignment. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

A multi-sequence FASTA file opened from the sidebar also lists its sequences as table rows. Select some of those rows, right-click them, and choose **Align with MAFFT...** to open the same dialog with those sequences already chosen. The alignment viewport does not offer that item, because realigning sequences that already carry gaps is a different job from aligning raw sequences. When a run's input already contains gaps, LGE records a warning that the result is unreliable and that the gaps should be removed first.

### Import an alignment built elsewhere

An alignment made by another program can come in as a `.lungfishmsa` bundle and use every viewport control in this chapter. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Open the Alignments tab and drop the file on the Multiple Sequence Alignments card. The card has no settings, it detects the format by itself, and each accepted file becomes one bundle. It reads aligned FASTA, Clustal, PHYLIP, NEXUS, Stockholm, a2m, and a3m, which are the text formats other alignment and tree programs write.

## Settings

The MAFFT pane holds eleven settings. The first five below sit in plain view. The last six, from Direction Adjustment through MAFFT Parameters, sit inside the collapsed Advanced Options group, which opens when you click its triangle.

**Sequences to align.** Chooses whether the run covers every sequence in the source file or only the sequences you highlighted, with the count in each label, such as All sequences (5). The default is All sequences, and the choice appears only when you have selected some but not all of the file's sequences, since otherwise there is nothing to choose between. Pick the selected scope when the file holds a sequence you do not want in the alignment, such as a failed sample. On the command line this is `--sequence`.

**Batch Output.** States that every input file is pooled into one alignment, because an alignment has no meaning file by file. The default and only choice is Combine all inputs, run once (1 result), locked with the reason "Alignment requires all sequences in one run", and the row appears only when you give the dialog two or more files. There is nothing to change. This setting has no command-line flag.

**Strategy.** Picks how hard MAFFT works to place gaps, from Automatic, L-INS-i, G-INS-i, E-INS-i, FFT-NS-2, and PartTree. The default is Automatic, which lets MAFFT choose from the number and length of your sequences and suits this chapter's five genomes. Move to L-INS-i, a slower and more careful method, when you have under about 200 sequences of similar length and the automatic result leaves ragged gap columns, meaning gaps scattered one or two at a time instead of falling into clean blocks. On the command line this is `--strategy`.

**Sequence Type.** Tells MAFFT whether the letters are DNA or amino acids, which decides how it scores a match, and offers Auto, Nucleotide, and Protein. The default is Auto, which guesses from the letters and is reliable on a full mitochondrial genome. Set it by hand when a short or unusual sequence makes the guess wrong, which shows up as scattered gaps and uncoloured letters in the viewport. On the command line this is `--sequence-type`.

**Output Order.** Chooses the order of rows in the finished alignment, either Input Order or Aligned Order. The default is Input Order, which keeps the order of your source file so the primate rows stay where the FASTA lists them. Switch to Aligned Order when you want similar sequences next to each other, so shared differences line up on screen. On the command line this is `--output-order`.

**Direction Adjustment.** Lets MAFFT [reverse-complement](../../GLOSSARY.md#reverse-complement) a sequence submitted on the wrong strand, that is, read it backwards along the other strand of the DNA, offering Off, Adjust Direction, and Adjust Direction Accurately. The default is Off, which trusts the strand you gave, and the five RefSeq records all come on the same strand. Turn it on when inputs came from a source that does not fix the strand and one row of the alignment is nearly all gaps. On the command line this is `--adjust-direction`.

**Symbol Policy.** Decides what MAFFT does with letters outside the standard DNA or protein alphabet, offering Strict Alphabet and Allow Any Symbol. The default is Strict Alphabet, which stops on an unexpected character rather than aligning something you did not mean to align. Choose Allow Any Symbol when protein sequences carry stop codons or rare amino acids such as selenocysteine. On the command line this is `--symbols`.

**Threads.** Sets how many processor cores MAFFT uses at once. The default is blank, which lets LGE pick a count for your Mac, and a typed value must be a whole number of 1 or more. Enter a small number such as `2` to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Deterministic threading.** Keeps MAFFT's final refinement pass on one thread so that the same input always gives the same alignment. The default is on, because a result you cannot reproduce is hard to defend in a methods section. Clear it only when a large alignment is too slow and a few shifted gaps between reruns do not matter. On the command line this is `--allow-nondeterministic-threads`, which turns it off.

**Treat FASTQ records as assembled or consensus sequences.** Lets MAFFT take FASTQ files, the format sequencers write, by converting each record to FASTA first. The default is off, and the dialog then refuses FASTQ input, because aligning raw sequencing reads to each other is almost never what anyone wants. Tick it when the FASTQ holds finished assembled or consensus sequences rather than raw reads. On the command line this is `--allow-fastq-assembly-inputs`.

**MAFFT Parameters.** Passes text straight to MAFFT after the chosen strategy. The default is empty, which is right for almost every run, and the dialog will not run until the text reads as valid command-line options. Use it only for a MAFFT option the dialog does not show, such as a custom gap-opening penalty, after reading MAFFT's own documentation. On the command line this is `--extra-mafft-options`.

### Viewport display controls

These nine controls change what you see and never change the bundle on disk. Numbering, Low support, High gap, Mask, Reference, and Display sit in the [Inspector](../../GLOSSARY.md#inspector) on its **View** tab. Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. All Sites, the colour scheme, and the name gutter sit on the viewport itself.

**All Sites / Variable Sites.** Chooses whether the viewport draws every column or only the [variable sites](../../GLOSSARY.md#variable-site), the columns where the rows disagree. The default is All Sites, which shows the conserved stretches as well as the differences. Switch to Variable Sites on a long alignment of close relatives, where differences would otherwise be thousands of columns apart. This setting has no command-line flag.

**Nucleotide / Conservation.** Chooses how residues are coloured. The default is Nucleotide, which gives each base its own colour so you read the letters directly. Switch to Conservation, which shades each column by how many rows share its most common residue, when you care about which regions stay constant. This setting has no command-line flag.

**Numbering.** Chooses which positions the column header labels, from Alignment + Source, Alignment Columns, Source Coordinates, and Hidden. The default is Alignment + Source, which shows both, because an alignment column counts gaps while a source coordinate counts only the bases of the original sequence, so the two drift apart wherever a gap sits. Choose Source Coordinates when you need a position you can look up in the original record, and Hidden when the numbers crowd a narrow window. This setting has no command-line flag.

**Low support (of non-gap residues).** Sets the share of a column's non-gap residues that must agree before the consensus row shows a base there, and below it the position is masked. It is a slider from 0 to 100 percent in steps of 5 with a typed number field beside it, and the default is 50, a simple majority. Raise it when you want a consensus that only shows positions where the sequences strongly agree. This setting has no command-line flag.

**High gap.** Sets the share of rows that may be gaps before the consensus masks that column. It is a slider from 0 to 100 percent in steps of 5 with a typed number field beside it, and the default is 50, so a column more than half gaps is masked. Lower it when partial sequences are letting mostly empty columns into the consensus. This setting has no command-line flag.

**Mask.** Picks the character that stands in for a masked consensus position, from Auto, N, and X. The default is Auto, which writes `X`, the protein code for any amino acid, in protein alignments and `N`, the DNA code for any base, everywhere else. Set it by hand when the automatic choice picks the wrong letter for your alphabet. This setting has no command-line flag.

**Reference.** Names the row every other row is compared against. The default is Consensus, a sequence LGE computes from each column's most common residue, which favours none of your inputs. Pick a named row, such as `Human_NC_012920.1`, when you want every difference reported relative to that sequence. This setting has no command-line flag.

**Display.** Chooses whether matching residues are spelled out or replaced by dots, from Letters, Dots to Consensus, and Dots to Reference. The default is Letters, and Dots to Reference stays greyed out until a Reference row is chosen. Switch to a dots mode when the alignment is mostly identical, so the differences are the only letters left on screen. This setting has no command-line flag.

**Name gutter width.** Sets how much room the sequence names get on the left, changed by dragging the handle between the names and the residues. The default is the shipped width, and LGE remembers your width between sessions within a range of 160 to 640 points, the unit macOS measures screen widths in. Widen it when a long label such as `CynomolgusMacaque_NC_012670.1` is cut off. This setting has no command-line flag.

### Export Alignment sheet

**Destination.** Chooses where the export goes, from Save as Bundle, Save to File..., and Copy to Clipboard. The default is Save to File..., which writes a plain file anywhere on disk. Choose Save as Bundle when the result feeds another LGE step, and Copy to Clipboard for a quick paste into a message or notebook. This setting has no command-line flag.

**Sequences.** Decides whether the export keeps the gap characters, from Aligned FASTA (keep gaps) and Unaligned FASTA (remove gaps). The default keeps gaps, so the receiving program sees the same columns you did. Remove gaps when the destination wants plain sequences at their original lengths, such as a BLAST search or a primer design tool. On the command line this is `--output-format` for a file export and `--output-kind` for a bundle export.

**Format.** Picks the file format of a file export, from `aligned-fasta`, `phylip`, `nexus`, `clustal`, `stockholm`, `a2m`, and `a3m`, and appears only for Save to File... with gaps kept. The default is `aligned-fasta`, which every alignment reader accepts. Change it to match the program that will read the file, since a tree builder that wants PHYLIP will not accept FASTA. On the command line this is `--output-format`.

**Scope.** Chooses whether the export covers the whole alignment or only the rows and columns you selected, and appears only when a selection exists. The default is Selected subalignment whenever rows are selected, with live counts in the labels such as Selected subalignment (3 rows) and Entire alignment (5). Switch to Entire alignment when the selection was only for looking and you want every row. On the command line this is `--rows` and `--columns`.

**Bundle name.** Names the new bundle and appears only for Save as Bundle. The default is the current alignment name, and the Create Bundle button stays greyed out while the field is blank. Change it whenever the export is a subset, so the name says what the subset is. On the command line this is `--name`.

The Multiple Sequence Alignments import card has no settings.

## Reading the results

<!-- SHOT: alignment-viewport-primate-mito -->

### The shape of the viewport

Four regions surround the residues. On the left, the name gutter lists every sequence in alignment order. Click a name to select that row, Command-click to add rows, and Shift-click for a range. Across the top, a column header carries the numbering, and below it a conservation overview strip draws a bar at each column whose height is that column's conservation. Above the sequence rows sits the pinned comparison row, which holds the current Reference and stays put while the rows below it scroll.

The residues fill the middle, coloured by the Nucleotide scheme unless you chose Conservation. An annotation is a labelled feature over a stretch of sequence, such as a gene, and any annotations the source sequences carried draw as tracks over the alignment. The plain FASTA fixture carries none, so nothing extra is drawn here.

The toolbar holds the working controls. The `Find sequence or column` field matches a sequence name, and a bare number jumps to that column, switching back to All Sites first if Variable Sites was hiding it. **Previous Variable** and **Next Variable** step between variable columns, and they grey out on an alignment with none. Icon buttons zoom in, zoom out, and fit the columns to the window.

### The numbers on this alignment

The primate alignment is 5 rows by 17,247 columns. Every row is now 17,247 characters wide, so a row's own length tells you how many gaps it received. The cynomolgus macaque, at 16,575 bases, received 672 gaps, and the gorilla, at 16,412, received 835. A column count close to the longest input is what related sequences should give. As a rough rule, up to about 10 percent above the longest input is normal for sequences this closely related, and 17,247 is about 4 percent above 16,575. A column count several times the longest input means the aligner found little shared structure, and the usual cause is an input that is not what you thought it was.

Of those 17,247 columns, 5,053 are variable, meaning they hold more than one distinct non-gap residue. That is 5,053 divided by 17,247, or about 29 percent, which is what species separated by tens of millions of years look like in mitochondrial DNA. Under a few percent means the sequences are nearly identical and the alignment will struggle to tell them apart. Over about half means they may be too distantly related for column-by-column comparison to mean much.

The consensus row is 17,247 characters long with 479 of them masked as `N` at the default thresholds. A masked position is one where the rows did not agree strongly enough. Here 479 out of 17,247 is under 3 percent, and a share in the low single digits means the sequences broadly agree. A tenth of the alignment or more means they do not.

### Pairwise identity

The clearest single check is a pairwise identity matrix, which reports for every pair of rows the fraction of compared positions at which they agree. It is the same arithmetic as [percent identity](../../GLOSSARY.md#percent-identity), taken across the whole alignment. No window in LGE draws this matrix. It comes from the command `lungfish-cli msa distance`, shown at the end of this chapter, and the numbers below are its output on the primate bundle.

The two macaques come out at 0.926, or 92.6 percent identical, the highest pair in the matrix. Human and chimpanzee come out at 0.913, and human and gorilla at 0.894. Human against either macaque falls to about 0.789.

Those numbers are the finding. The pair within one genus is most alike, human and chimpanzee come next, gorilla sits a little further from both, and the ape-to-monkey pairs are lowest. That ordering is the known primate relationship recovered from the alignment alone, which tells you the run worked. A matrix where the two macaques were not the closest pair would point to a mislabelled input, not a discovery.

### Acting on a selection

Select rows by clicking their names in the gutter, and select columns by dragging across the residues from the first column you want to the last. The two together define a block. Right-click inside the alignment, or Control-click on a trackpad, for the items that act on that block.

**Copy Subalignment** puts the block on the clipboard as FASTA. **Extract Selection to New Bundle...** writes the block, with gaps removed, as a new `.lungfishref` reference bundle, and **Export Selected Residues...** writes it to a file. **Export Alignment...** opens the export sheet described in Settings.

<!-- SHOT: export-alignment-sheet -->

**Use as Reference** makes the row you right-clicked the pinned comparison row, and **Use Consensus** puts the consensus back. Pair either with a dots mode in Display, and every matching position collapses to a dot so only the differences stay as letters.

**Add Annotation from Selection...** records a named feature over the selected columns of one row. **Apply Annotation to Selected Rows** copies an existing annotation onto the other selected rows, and it works only when more than one row is selected and the selected columns cover an existing annotation. **Build Tree with IQ-TREE...** stays greyed out until at least two rows are selected, and the next chapter covers it.

Copy to Clipboard on the export sheet greys itself out with an explanation when the alignment text would exceed 5 MB, rather than failing after you commit. One character of the alignment is about one byte, so 5 MB is roughly 300 rows the length of these genomes. The five primate rows come to under 90 KB.

## What good looks like

Four checks are worth running before you trust an alignment.

Confirm the row count matches your input. Five sequences in should give five rows out, with the names unchanged. A missing row means an input was excluded, and the run's row in the Operations Panel holds the reason.

Confirm the column count sits within about 10 percent of the longest input, as 17,247 does against 16,575 here. A count far above that means the aligner found little shared structure.

Confirm the conservation overview strip is mostly tall bars. Every column that is not variable, 12,194 of the 17,247 here or about 70 percent, has a conservation of 1, so most of the strip should sit at or near full height, broken by shorter stretches. The strip packs many columns into each bar at full width, so expect a mostly tall strip rather than an exact count. An even wash of low bars across the whole width means the rows are not meaningfully aligned.

Confirm the pairwise identities put the pairs in the order biology predicts, as the two macaques lead this matrix at 0.926. When they do not, suspect the inputs before the aligner.

When a run does go wrong, the input is usually the cause. Sequences in mixed orientation align as though unrelated, and **Direction Adjustment** fixes that. Sequences from different genes, or of wildly different lengths, give mostly-gap alignments, so check a few names and lengths before blaming the run. Very distantly related sequences sit at the edge of what Automatic handles well, and **L-INS-i** buys accuracy at the cost of time. If none of that explains it, expand the run's row in the Operations Panel, which holds MAFFT's own log.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The block aligns the fixture, writes the identity matrix quoted above, and exports the alignment for a tree program. It assumes the fixture sits in your Downloads folder and the project is a `.lungfish` folder you already created.

```bash
# Align the five genomes into the project.
lungfish-cli align mafft ~/Downloads/primate-mito.fasta \
  --project ~/Documents/primates.lungfish \
  --name primate-mito \
  --strategy auto

# Write the pairwise identity matrix as a table.
lungfish-cli msa distance \
  ~/Documents/primates.lungfish/Analyses/"Multiple Sequence Alignments"/primate-mito.lungfishmsa \
  --output primate-mito-identity.tsv

# Export the alignment as PHYLIP for a tree program.
lungfish-cli msa export \
  ~/Documents/primates.lungfish/Analyses/"Multiple Sequence Alignments"/primate-mito.lungfishmsa \
  --output-format phylip --output primate-mito.phy
```

One default differs from the app. The export sheet keeps gaps by default, but `msa export` defaults to plain `fasta`, which strips them, so an aligned FASTA export on the command line needs `--output-format aligned-fasta` written out.

## Next

Continue to [Building Trees](05-building-trees.md), which takes this alignment and infers a family tree of the five primates from it with IQ-TREE.

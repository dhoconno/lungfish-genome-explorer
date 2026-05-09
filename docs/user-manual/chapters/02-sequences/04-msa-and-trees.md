---
title: Multiple Sequence Alignments and Phylogenetic Trees
chapter_id: 02-sequences/04-msa-and-trees
audience: analyst
prereqs: [01-foundations/01-what-is-a-genome, 02-sequences/01-importing-and-viewing]
estimated_reading_min: 12
task: Build a multiple sequence alignment with MAFFT and infer a phylogenetic tree with IQ-TREE.
tags: [sequences, msa, mafft, phylogenetics, iqtree, tree]
tools: [mafft, iqtree]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Multiple Sequence Alignment"
  - "Open an MSA bundle, then Tools > Infer Tree"
  - "CLI: lungfish msa, lungfish tree"
shots:
  - id: msa-viewport
    caption: "An MSA viewport showing aligned sequences with a column ruler."
  - id: tree-viewport
    caption: "A phylogenetic tree viewport showing a rectangular tree with annotated tips."
planned_shots: []
illustrations:
  - id: msa-column-homology
    caption: "Three sequences before and after alignment, showing how MAFFT inserts gaps so homologous bases share a column."
  - id: tree-anatomy
    caption: "Anatomy of a rectangular phylogram: tips, internal nodes, branch lengths, and support values."
glossary_refs: [msa, mafft, iqtree, newick, clade, phylogram, support-value]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A multiple sequence alignment (MSA) takes a set of related sequences and arranges them so homologous positions sit in the same column. Where one sequence has an insertion that the others lack, MAFFT pads the others with `-` gap characters. The result is a rectangular block: rows are sequences, columns are inferred homologous sites, and conservation at any column is a column-wise count of how many rows agree.

Lungfish runs MAFFT under `Tools > FASTQ/FASTA Operations > Multiple Sequence Alignment` and writes the result as a `.lungfishmsa` bundle that opens in the MSA viewport. From that bundle, `Tools > Infer Tree` runs IQ-TREE to estimate a maximum-likelihood phylogenetic tree, written as a `.lungfishtree` bundle that opens in the tree viewport. Both bundles carry a provenance sidecar recording the exact tool version and command line.

This chapter is more advanced than the rest of Part II because it assumes you already have a reason to align: comparing related viral isolates, tracing transmission, or designing diagnostic primers across variants. MAFFT and IQ-TREE are well-documented academic standards, and this chapter teaches the Lungfish workflow around them, not the algorithm internals.

So what should you do with this? When you have a handful of related FASTAs and a question about how they relate, build the MSA first, look at conservation, then infer a tree only if topology genuinely matters for the question.

<!-- ILLUSTRATION: msa-column-homology -->

## What you will learn

By the end of this chapter you will assemble a set of related sequences into a single FASTA, run MAFFT to align them, read the alignment in the MSA viewport, run IQ-TREE on that alignment to infer a maximum-likelihood phylogeny, read the tree in the tree viewport, and export a Newick file for use in external tools.

## Why MAFFT

Lungfish defaults to MAFFT because for the inputs this manual targets (tens to a few hundred viral or bacterial sequences of comparable length), MAFFT's default `--auto` mode picks a sensible algorithm, runs in seconds, and produces alignments that downstream tools agree with. The other common choices are MUSCLE and Clustal Omega.

| Tool | Speed on ~100 viral genomes | Default in Lungfish | Strengths | Weaker on |
|---|---|---|---|---|
| MAFFT | Seconds | Yes | Auto-selects algorithm by input size, handles ragged ends well | Very large (>10k) divergent inputs without `--parttree` |
| MUSCLE | Seconds to minutes | No | Often slightly higher accuracy on small protein sets | Slower than MAFFT at scale |
| Clustal Omega | Minutes | No | Scales to thousands of sequences via HMM seeding | Less accurate than MAFFT on closely related nucleotide sets |

If you need MUSCLE or Clustal Omega specifically (for example, to reproduce a published methods section), install the plugin pack that provides them and select the tool in the MSA wizard's `Aligner` dropdown. Provenance records the actual tool used, so later readers can tell which engine produced the bundle.

## Procedure: build an MSA with MAFFT

The worked example assumes you have ten SARS-CoV-2 S-gene FASTAs in one folder, each from a different lineage (a mix of Alpha, Delta, and Omicron). The exact accessions do not matter; what matters is that each FASTA contains a single S-gene sequence with a header line that names the lineage, for example `>BA.2_OQ123456`.

1. Drop the ten FASTAs into your project's `Imports/` folder, or use `File > Import` and select them together. Each lands as its own item in the sidebar.
2. Choose `Tools > FASTQ/FASTA Operations > Multiple Sequence Alignment`. The MSA wizard opens.
3. In the wizard's `Inputs` list, add all ten FASTAs. Lungfish concatenates them into a single multi-FASTA before passing to MAFFT.
4. Leave `Aligner` set to MAFFT and `Mode` set to Auto. For inputs under a few hundred viral-scale sequences, the auto mode is what you want.
5. Name the output bundle (for example, `S-gene-10-isolates.lungfishmsa`) and click `Run`.

MAFFT typically finishes in under a minute on this input size. The new bundle appears in the sidebar; double-click to open the MSA viewport.

<!-- SHOT: msa-viewport -->

## Interpretation: reading the MSA viewport

The MSA viewport has three regions. The row picker on the left lists every input sequence in alignment order, with a checkbox to hide any row from the column ruler's conservation calculation. The main pane is the alignment grid, with one row per sequence and one column per alignment position; bases use the standard four-color nucleotide palette and gaps render as light dashes on the Cream background. The column ruler across the top shows two tracks: a 1-based column index and a conservation track whose height at each column is the fraction of non-gap rows that share the modal base.

Three patterns are worth looking for. First, blocks where every row agrees: these are conserved regions, useful as primer-design targets. Second, columns where one or two rows disagree: these are lineage-defining substitutions, the signal phylogenetic inference will lean on. Third, ragged stretches of gaps: these are insertion/deletion events, often clustered at recombination breakpoints or in repetitive regions where the aligner is uncertain.

If you have a reference annotation already loaded (for example, the SARS-CoV-2 GFF3 from your Reference Sequences folder), the viewport's `Annotations` toggle projects gene boundaries onto the column ruler so you can tell at a glance whether a divergent column falls inside the receptor-binding domain or the signal peptide.

For the ten-isolate worked example, you should see a strongly conserved 5' block (the S1 signal region), a band of lineage-defining columns clustered in the receptor-binding domain (positions roughly 319 to 541 in the S-gene reference frame), and a shorter conserved 3' block. Omicron rows will carry a visible insertion near position 214 that Alpha and Delta rows lack; that insertion appears in the MSA as a column block where eight of ten rows are gap characters.

## Procedure: infer a tree with IQ-TREE

With the MSA bundle still open, run `Tools > Infer Tree`. The tree wizard opens, pre-populated with the current MSA bundle as input.

1. Confirm the MSA bundle is selected as the input alignment.
2. Leave `Method` set to IQ-TREE and `Substitution model` set to `MFP` (ModelFinder Plus). IQ-TREE will pick the best-fitting model from the data.
3. Set `Bootstrap replicates` to `1000` for ultrafast bootstrap support values. Lower values run faster; higher values rarely change conclusions for inputs this size.
4. Optionally set an outgroup tip from the dropdown. For SARS-CoV-2 lineage trees, the earliest available isolate (often a Wuhan-Hu-1 reference) makes a sensible outgroup.
5. Name the output bundle (for example, `S-gene-10-isolates.lungfishtree`) and click `Run`.

IQ-TREE on ten sequences finishes in seconds to a minute. The new bundle appears in the sidebar; double-click to open the tree viewport.

<!-- SHOT: tree-viewport -->

<!-- ILLUSTRATION: tree-anatomy -->

## Interpretation: reading the tree viewport

The tree viewport renders a rectangular phylogram by default. Branch length encodes inferred substitutions per site, so longer horizontal branches mean more accumulated change. Tip labels come straight from the FASTA header lines; if you named your inputs with lineage prefixes, the lineage groupings are visible at a glance.

Three things to read off the tree. First, the topology: which tips group with which other tips. For the worked example, you should see Alpha tips form one clade, Delta tips form a separate clade, and Omicron tips form a third clade well separated from the other two by a long internal branch. Second, the support values: numbers at each internal node give the percentage of bootstrap replicates that recovered that exact split. Values above 95 are strong; values below 70 mean the split is uncertain and you should not draw fine-grained conclusions from it. Third, the root: if you set an outgroup, the tree is rooted there; if not, the tree is unrooted and the apparent root position is a display convention only.

The tree viewport's toolbar offers a few controls. `Layout` switches between rectangular, circular, and unrooted radial; rectangular is the most readable for under fifty tips. `Tip labels` toggles label visibility for dense trees. `Support` toggles the numeric support annotations on internal nodes. `Export Newick` writes a plain `.nwk` file alongside the bundle, suitable for FigTree, iTOL, or any other downstream viewer.

## What this chapter does not cover

Phylogenetics is a deep field and Lungfish ships only the inference workflow most viral-genomics analysts need day to day. The following are deliberately out of scope and are not in the app today.

- Ancestral state reconstruction (inferring sequences at internal nodes).
- Time-calibrated trees in the BEAST or TreeTime style, where branch lengths represent calendar time rather than substitutions per site.
- Recombination detection (RDP, GARD, 3SEQ) for sequences with mosaic ancestry.
- Coalescent population-genetic inference such as effective population size over time.
- Phylogeographic inference that maps tree branches onto geographic locations.

If your question requires any of those, export the Newick or the MSA FASTA from the bundle and run the appropriate external tool. The provenance sidecar records the Lungfish-side inputs so the external analysis remains reproducible.

## Troubleshooting

When MAFFT produces a poor alignment, the cause is almost always the input. Sequences in mixed orientation (some forward strand, some reverse complement) align as if they were unrelated; reorient them with `Tools > Orient` against a shared reference before aligning. Sequences from different genes or wildly different lengths produce mostly-gap alignments; check that every input is what you think it is by spot-reading a few headers and lengths in the sidebar inspector. Very divergent sequences (below ~50% pairwise identity) are at the edge of MAFFT's default settings; switch the wizard's `Mode` from Auto to `L-INS-i` for higher accuracy at the cost of runtime, or accept that an MSA is not the right tool for that data.

When IQ-TREE struggles, it usually says so in its log. Identical or near-identical sequences collapse into zero-length branches and produce trees with low support across the board; deduplicate the input FASTA first if that is the case. Very short alignments (under a few hundred informative columns) carry too little signal for confident bootstrap support; expect support values in the 50s to 70s and do not over-interpret them. If IQ-TREE warns that ModelFinder selected a model with very few parameters, your data is probably too uniform for the question you are asking; consider whether a tree is the right summary at all.

For the ten-isolate S-gene worked example, both tools should run cleanly. If they do not, check the operation's log link in the Operations Panel; the full MAFFT or IQ-TREE stderr is preserved there along with the resolved command line.

## Next

This is the last chapter in [Sequences](.). Continue to [Reads (FASTQ)](../03-reads/) for sequencing data workflows, or [Variants](../05-variants/) for variant calling against a reference.

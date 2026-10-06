---
title: Building Trees
chapter_id: 02-sequences/05-building-trees
audience: analyst
prereqs: [01-foundations/01-what-is-a-genome, 02-sequences/04-aligning-sequences]
estimated_reading_min: 24
task: Infer a maximum-likelihood tree from an alignment with IQ-TREE, rooted on an outgroup, read it and its support values in the tree viewport and the Inspector, and re-root it, extract a clade from it, or relabel it.
tags: [sequences, phylogenetics, iqtree, tree, newick, bootstrap, sh-alrt, outgroup]
tools: [iqtree]
parameters_refs: [tree.iqtree, tree.reroot, tree.extract-subtree, import.tree]
entry_points:
  - Tools > Alignment & Phylogenetics > Build Tree with IQ-TREE...
  - Right-click in the alignment viewport > Build Tree with IQ-TREE...
  - Selection > Tree Node > Root on Selected Branch
  - File > Import Center... > Alignments > Phylogenetic Trees
  - "CLI: lungfish-cli tree infer iqtree"
  - "CLI: lungfish-cli tree reroot"
  - "CLI: lungfish-cli tree extract-subtree"
shots:
  - id: iqtree-dialog
    caption: "The Build Tree with IQ-TREE dialog on the primate alignment, with the Inputs, Model, Branch Support, Rooting, Output and Run groups, both macaques ticked as the outgroup, and the Advanced group collapsed."
  - id: tree-viewport-primate-mito
    caption: "The primate mitochondrial tree rooted on the macaques, with the summary line, the support pairs on the canvas, the Phylogram and Cladogram control, and the Nodes drawer with its SH-aLRT and UFBoot columns."
illustrations:
  - id: tree-anatomy
    caption: "Anatomy of a rectangular phylogram, showing tips, internal nodes, branch lengths, and support values."
  - id: tree-unrooted-to-rooted
    brief: "The five-tip primate tree drawn twice, side by side. Left panel, unrooted, as IQ-TREE returns it: human and chimpanzee meeting at one internal node, gorilla joining next, and the two macaques (rhesus and cynomolgus) joined to the rest by one long branch, with no root marked. Right panel, the same tree rooted on the branch to the macaque clade, as Root on Selected Branch draws it: a new root point placed at the midpoint of that long branch, the two macaques as one clade on one side of the root, and the three apes as the other clade with human and chimpanzee paired inside it. Label the long branch 0.8982 in the left panel and its two halves 0.4491 each in the right panel, and mark the root with a small filled circle. Use Deep Ink for branches and labels, Lungfish Creamsicle for the root marker and the split branch, IBM Plex Mono for the numbers and tip names."
glossary_refs: [upgma, jukes-cantor, iqtree, modelfinder, phylogram, cladogram, clade, newick, support-value, sh-alrt, bootstrap, maximum-likelihood, substitution-model, tip, internal-node, branch-length, topology, rooting, outgroup, msa, alignment-column, codon, genetic-code, thread, mitochondrial-genome, accession, plugin-pack, provenance, checksum, bundle, sidebar, inspector, operations-panel, import-center, p-distance]
features_refs: [tree.infer, viewport.phylogenetic-tree, tree.transform]
fixtures_refs: [primate-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A phylogenetic tree is a diagram of inferred ancestry. Each sequence you put in becomes a [tip](../../GLOSSARY.md#tip), a point at the end of a branch. Every place where branches meet is an [internal node](../../GLOSSARY.md#internal-node), which stands for an ancestor that was never sequenced. An internal node is a calculated guess, not a sample you could look up. The pattern of which tips join which is the [topology](../../GLOSSARY.md#topology), and the topology is the main result of a tree run.

A tree also has lengths. On the default drawing, the horizontal length of a branch is its [branch length](../../GLOSSARY.md#branch-length), the estimated number of base changes per site along that branch. A site is one [alignment column](../../GLOSSARY.md#alignment-column), meaning one position compared across all your sequences. A branch length of 0.06 therefore means about six changes for every hundred sites. A tree drawn with its branch lengths to scale is called a [phylogram](../../GLOSSARY.md#phylogram).

![Rectangular phylogram with tips, internal nodes, branch lengths, and support values](../../assets/illustrations-imagegen/02-sequences/05-building-trees/tree-anatomy.png)

Lungfish Genome Explorer (LGE) builds trees with [IQ-TREE](../../GLOSSARY.md#iqtree) version 3, a program that uses [maximum likelihood](../../GLOSSARY.md#maximum-likelihood). The alignment is the fixed evidence, and each candidate tree is scored against it. Maximum likelihood keeps the tree under which the observed columns are most probable, given an assumed [substitution model](../../GLOSSARY.md#substitution-model), a set of rates for turning one base into another. Models differ because real DNA does not change evenly. An A-to-G change is more common than an A-to-T change, for example, and a model that ignores this tends to underestimate how much change a long branch carries. IQ-TREE can test many models and choose one for you.

Confidence is measured separately from the tree. A [support value](../../GLOSSARY.md#support-value) is a number on an internal node that says how consistently the data recover that grouping. LGE asks IQ-TREE for two kinds by default. The [ultrafast bootstrap](../../GLOSSARY.md#bootstrap), called UFBoot, rebuilds the tree from many resampled copies of the alignment and counts how often each grouping comes back. [SH-aLRT](../../GLOSSARY.md#sh-alrt) tests each internal branch against the other ways of joining the groups around it. The topology looks equally crisp whether the data supported it strongly or barely, so the support values are the only way to tell the two apart.

Trees are stored as [Newick](../../GLOSSARY.md#newick) text, a single line in which brackets group the tips that share an ancestor and a number after each name gives its branch length. Nearly every tree program reads and writes it.

A tree is only a summary of the alignment it came from. It cannot see anything the columns do not contain, and a poor alignment gives a confident-looking poor tree. In practice, check the alignment first, as [Aligning Sequences](04-aligning-sequences.md) describes, and then read the topology and its support values as two separate results.

## Why you would do this

This chapter builds a tree from the five primate [mitochondrial genomes](../../GLOSSARY.md#mitochondrial-genome) that the previous chapter aligned. They are human, chimpanzee, gorilla, rhesus macaque, and cynomolgus macaque.

The previous chapter ended with a pairwise identity matrix on the Distances tab under the alignment, which says how similar each pair of sequences is. A matrix is not a history. It shows that the two macaques are the most similar pair, but it cannot say in what order the lineages split. Branching order is what a tree answers.

The known primate relationships make this a good teaching set, because you can check the answer. The two macaques should be sisters, meaning two tips that meet at the same internal node with nothing else between them. The human and the chimpanzee should be closer to each other than either is to the gorilla. All three apes should sit apart from the two monkeys. A tree that says otherwise is reporting a problem with the run, not news about primates.

On its own, IQ-TREE returns an unrooted tree, which shows the groupings but not which lineage branched off first. [Rooting](../../GLOSSARY.md#rooting) the tree on an [outgroup](../../GLOSSARY.md#outgroup), a lineage known to sit outside the group you are studying, adds that direction. For the three apes, the two macaques are the natural outgroup. The root then sits on the branch between the macaques and the apes, not inside either group, so each side of the root is one clade. Choosing the outgroup sets only where the root goes. It does not change which sequences IQ-TREE groups together.

## Choosing a tool

A tree starts from an alignment of finished sequences, never from raw reads, and [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows how to tell which you hold. LGE builds trees one way, by maximum likelihood with IQ-TREE 3. The choices left to you are which substitution model to use and how to measure support, and the size of the alignment and what you will claim from the tree decide both.

Tree-building methods fall into four families. Distance methods, such as neighbour joining and [UPGMA](../../GLOSSARY.md#upgma), reduce the alignment to one number per pair of sequences and join the closest pairs step by step. If human and chimpanzee differ at ten columns, a distance method keeps the number ten and forgets which ten, so it cannot notice that the gorilla shares some of those changes with one of them. Parsimony methods choose the tree that needs the fewest base changes, but they can group two fast-changing lineages only because both changed a lot. Maximum likelihood keeps every column and models unequal rates of change. Bayesian methods, such as MrBayes and BEAST, use the same models but return many trees weighted by probability, at far greater computing cost. For very large sets, FastTree and VeryFastTree approximate maximum likelihood quickly, and UShER places new SARS-CoV-2 genomes onto an existing tree of millions. Only maximum likelihood runs inside LGE.

**IQ-TREE with ModelFinder** is the default. With the Model pop-up left at Find best model (ModelFinder), which is `MFP` on the command line, IQ-TREE first runs [ModelFinder](../../GLOSSARY.md#modelfinder). It fits many substitution models and keeps the one that balances fit against the number of rates it has to estimate, judged by a score called BIC. The simplest DNA model, [Jukes-Cantor](../../GLOSSARY.md#jukes-cantor) (`JC` in the pop-up), uses one rate for every kind of change, while GTR estimates six, one for each pair of bases, so GTR is chosen only when it fits clearly better. IQ-TREE then searches for the tree under that model. It suits almost any alignment from a handful of sequences to a few thousand, and its cost is the time model testing adds.

**IQ-TREE with a fixed model** skips model testing and uses the model you pick from the pop-up, such as `GTR+F+I+G4`, or one you type under Custom…. It suits a replication of a published analysis, or a large alignment where testing takes too long. A model poorly matched to your data can shorten long branches and misplace fast-changing lineages.

**A pairwise distance matrix**, on the Distances tab under the alignment or from `lungfish-cli msa distance`, reports for every pair of rows the share of positions that agree (identity), the share that differ ([p-distance](../../GLOSSARY.md#p-distance)), or a corrected distance, Jukes-Cantor or Kimura 2-parameter for DNA and Poisson for protein. It checks that the alignment behaves as biology predicts, but it is not a tree. Its Average linkage (UPGMA) order puts similar rows next to each other, yet that order is only a way of sorting the matrix, and LGE saves no tree from it and has no command that turns the matrix into one.

| Option | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| IQ-TREE with ModelFinder | Most alignments, up to a few thousand sequences | You want a defensible tree without choosing a model | A published method fixes the model, or testing is too slow |
| IQ-TREE with a fixed model | Replicating a stated method, or very large alignments | You must match a model someone else used | You have no reason to prefer one model |
| `msa distance` matrix | A quick similarity check | You only need to know which pairs are closest | You need branching order or support values |

Support is the second choice, and both tests are on when the dialog opens, each at 1000 replicates. That pair is IQ-TREE's own recommendation. For the branch that pairs human with chimpanzee, SH-aLRT compares it with the two alternatives, pairing human with gorilla or chimpanzee with gorilla. The dialog's caption gives the guidance IQ-TREE's documentation uses, that UFBoot 95 or higher and SH-aLRT 80 or higher indicate a well-supported clade. Leave both on for any tree you will interpret. Each internal node then carries two numbers, which LGE shows in two columns.

This chapter's alignment has five sequences, so the default settings run in a few seconds, and that is what the Procedure uses. Keep them for human or macaque alignments of up to a few thousand sequences. For tens of thousands, build the tree from a representative subsample, or export the alignment as PHYLIP from the [Export Alignment sheet](04-aligning-sequences.md#export-alignment-sheet) for a faster program. Citations for IQ-TREE 3, ModelFinder, UFBoot, and SH-aLRT are in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack) and its [Method papers](../appendices/bibliography.md#method-papers).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Genes and Sequences demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds the `primate-mito` reference bundle but no alignment, so run [Aligning Sequences](04-aligning-sequences.md) in it first. To import the FASTA yourself instead, follow the rest of this section.

This chapter uses the primate-mito fixture. Download `primate-mito.fasta` from [primate-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/primate-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The FASTA file is the input to the previous chapter, not to this one. This chapter starts from the `.lungfishmsa` [bundle](../../GLOSSARY.md#bundle) that [Aligning Sequences](04-aligning-sequences.md) leaves under `Analyses/Multiple Sequence Alignments/`, so work through that chapter first.

Install the `phylogenetics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The pack provides IQ-TREE 3.1.3, the version that produced this chapter's tree. No container and no internet connection are needed once the pack is installed.

## Procedure

### Infer the tree

1. Click the `primate-mito.lungfishmsa` bundle in the sidebar to open it in the alignment viewport, then choose **Tools > Alignment & Phylogenetics > Build Tree with IQ-TREE...**. The item acts on the alignment in the viewport, or on one alignment selected in the sidebar, and stays greyed out with neither. You can also right-click inside the alignment and choose **Build Tree with IQ-TREE...** there, which opens the same dialog.

2. The **Build Tree with IQ-TREE** dialog opens. It follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, with its settings in labelled groups. In the Inputs group, **Build from** should read `Whole alignment (5 sequences, 17247 columns)`. If you had rows or columns selected in the alignment, a second choice, Selected rows and columns, appears beside it, so pick Whole alignment.

3. Leave **Model** at Find best model (ModelFinder) and **Sequence type** at Detect automatically. In the Branch Support group, leave **Ultrafast bootstrap (UFBoot)** and **SH-aLRT test** ticked, each with 1000 replicates.

    <!-- SHOT: iqtree-dialog -->

4. In the Rooting group, tick `RhesusMacaque_NC_005943.1` and `CynomolgusMacaque_NC_012670.1` under **Outgroup**.

5. Leave **Name** as `primate-mito`. In the Run group, type `1` into **Seed** so your tree matches the one in Reading the results, and leave **Threads** at 1. The line at the foot of the dialog should read `Ready to build a tree.` Click **Build Tree**.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Its row logs `Seed 1 was set in the dialog.` and `IQ-TREE runs with 1 thread.` before IQ-TREE starts. When the row finishes, the new bundle appears in the sidebar under `Phylogenetic Trees/`. That is a top-level project folder LGE creates the first time it writes a tree, one of the fixed homes [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) mentions. Click the bundle to open the tree viewport.

With the Seed field left blank, LGE draws a random seed before the run, logs it as `Random seed N was drawn for this run and recorded in the command.`, and records it, so any run can be repeated later with the seed from its row or its Inspector.

### Root a finished tree on another branch

The outgroup boxes root the tree as it is built. A tree built with no outgroup ticked, or one imported from another program, can be rooted afterwards. Build a second tree with the same settings but no outgroup ticked and the name `primate-mito-unrooted`, and its summary line ends in `Unrooted (drawn root is arbitrary)`.

Click the internal node where the rhesus macaque and cynomolgus macaque branches join, so the detail line below the tree names it. Then right-click the node and choose **Root on Selected Branch**, or choose **Selection > Tree Node > Root on Selected Branch**. No dialog opens, and a new bundle named `primate-mito-unrooted-rerooted` appears under `Phylogenetic Trees/`, leaving the original tree as it was.

LGE places the new root on the branch above the node you chose, halfway along it. On this tree that is the long branch between the macaques and the apes. The macaque clade, the outgroup, becomes one side of the root and everything else becomes the other, which is the outgroup root a textbook draws. Branch lengths and support values are kept, and the two halves of the split branch add back up to its old length.

<!-- ILLUSTRATION: tree-unrooted-to-rooted -->

The unrooted tree's long branch is 0.8982, and the rerooted copy splits it into two branches of 0.4491. The rooted Newick, rounded to four places, reads as follows.

```text
((RhesusMacaque_NC_005943.1:0.0650,CynomolgusMacaque_NC_012670.1:0.0299)100/100:0.4491,(Gorilla_NC_011120.1:0.0740,(Human_NC_012920.1:0.0601,Chimp_NC_001643.1:0.0589)100/100:0.0296)100/100:0.4491);
```

This copy groups the sequences exactly as the tree rooted in the dialog does. Its branch lengths differ from that tree's in the third or fourth decimal place, because the two came from separate IQ-TREE runs, one given an outgroup and one not. Choosing a single tip instead roots the tree on that tip's own branch, which makes one sequence the outgroup.

### Extract the macaque clade

A [clade](../../GLOSSARY.md#clade) is an internal node together with everything descended from it. Go back to the `primate-mito` tree, click the macaque node to select it, then right-click it and choose **Extract Subtree as New Bundle...**. No dialog opens. A new two-tip bundle appears under `Phylogenetic Trees/`, named from the clade's tips joined by `+` with `-subtree` added, so this one is `RhesusMacaque_NC_005943.1+CynomolgusMacaque_NC_012670.1-subtree`. A clade of more than three tips is named after its first tip and a count, as in `<first tip>+3-more-subtree` for a clade of four tips. To hand the clade to a program outside LGE instead, choose **Export Subtree...**, which writes a plain `.nwk` Newick file through a save panel. The new bundle keeps the support values but has no Inference section in the Inspector, because the model, seed and log-likelihood describe the whole tree IQ-TREE built and not the clade on its own. A re-rooted tree keeps its Inference section and drops only the outgroup row.

### Import a tree built elsewhere

A tree made by another program can come in as a `.lungfishtree` bundle and use every viewport control in this chapter. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. On the Alignments tab, click **Import...** on the Phylogenetic Trees card, or drop the files onto the card. It accepts Newick and Nexus files, Nexus being a structured text format that can wrap a Newick tree, which covers IQ-TREE `.treefile` and `.contree` outputs and results from RAxML-NG and FastTree. Each file becomes one bundle under `Phylogenetic Trees/`.

## Settings

The Build Tree with IQ-TREE dialog holds seventeen settings in seven groups, Inputs, Model, Branch Support, Rooting, Output, Run, and Advanced. Two of them, Custom model and Genetic code, appear only when another choice calls for them. The four Advanced settings sit inside the collapsed Advanced group. Rooting and subtree extraction show no dialog, so their settings are fixed by the node you select before you right-click. The Phylogenetic Trees import card has no settings at all.

### Build Tree with IQ-TREE

**Build from.** Chooses which sequences and columns IQ-TREE sees. Whole alignment is the only choice when nothing is selected, and its label gives the sequence and column counts. Selected rows and columns appears when the alignment has a selection, and it is the default when the dialog opens from a selection of 3 or more rows. IQ-TREE needs at least 3 sequences, so a smaller scope blocks Build Tree, and with fewer than 4 the Branch Support group turns off with the caption `Bootstrap and SH-aLRT need at least 4 sequences.` Choose Selected rows and columns to build a tree from one region or a subset of samples. On the command line this is `--rows` and `--columns`, which a whole-alignment run leaves out.

**Model.** Chooses the substitution model. The default is Find best model (ModelFinder), which tests many models and uses the best fit by BIC. Below it the pop-up lists fixed models for the alignment's alphabet, `JC`, `HKY+F+G4`, `GTR+F+I+G4`, and `GTR+F+R4` for DNA, or `LG+G4`, `WAG+G4`, `JTT+G4`, and `LG+F+R4` for protein, and then Custom…. Pick a fixed model when a published method names it or when model testing takes too long on a large alignment. On the command line this is `--model`, where ModelFinder is `MFP`.

**Custom model.** Takes any model string IQ-TREE accepts, and appears only when Model is Custom…. The default is empty, with `GTR+F+I+G4` shown as an example. `MF`, `TESTONLY`, and other strings ending in `ONLY` are refused, because they choose a model and then stop without building a tree. Use it for a model the pop-up does not list, such as a [codon](../../GLOSSARY.md#codon) model. On the command line this is also `--model`.

**Sequence type.** Tells IQ-TREE what the alignment characters are. The default is Detect automatically, which is right for this alignment. A nucleotide alignment also offers DNA and Codon, and a protein alignment offers Protein. Codon reads each block of three columns as one codon, so the number of columns in scope must be a multiple of 3, and choose it only for an in-frame coding alignment. Binary, morphological, and translated runs are available only on the command line. On the command line this is `--sequence-type`.

**Genetic code.** Chooses the codon table, the [genetic code](../../GLOSSARY.md#genetic-code) that maps codons to amino acids, and appears only when Sequence type is Codon. The default is Standard. Choose Vertebrate mitochondrial for the coding genes of a human or macaque mitochondrial genome, whose code reads some codons differently. On the command line Standard is `--sequence-type CODON1` and Vertebrate mitochondrial is `CODON2`.

**Ultrafast bootstrap (UFBoot).** Turns on ultrafast bootstrap support for every internal branch. The default is on. A value of 95 or higher marks a well-supported clade. Turn it off only for a quick look at the topology, since a tree without support cannot be read for confidence. On the command line this is `--bootstrap`, which takes the replicate count.

**UFBoot replicates.** Sets how many bootstrap replicates IQ-TREE builds, in a whole-number field with a stepper that moves in steps of 1000. The default is 1000, and the caption beneath it reads `IQ-TREE requires at least 1000.` The field is greyed out while its box is unticked. Raise it rarely. On the command line this is the number given to `--bootstrap`.

**SH-aLRT test.** Turns on the SH-aLRT test for every internal branch. The default is on, because IQ-TREE recommends reading SH-aLRT and UFBoot together. A value of 80 or higher marks a well-supported clade. On the command line this is `--alrt`.

**SH-aLRT replicates.** Sets how many replicates the SH-aLRT test uses. The default is 1000, and any whole number of 1 or more is accepted. The field is greyed out while its box is unticked. Change it rarely. On the command line this is the number given to `--alrt`.

**Outgroup.** Lists every sequence in scope with a box beside it. The default is none ticked, which leaves the tree unrooted. Tick the sequences known to sit outside the group you study, such as the two macaques for a tree of apes, and the saved tree is rooted on them. The caption reads `The outgroup sets where the tree is rooted. It does not change the inferred relationships.` At least one sequence must stay outside the outgroup. If the ticked sequences do not form one group on the finished tree, LGE keeps the tree unrooted and records a warning in the Inspector. On the command line this is `--outgroup`.

**Name.** Names the `.lungfishtree` bundle the run writes into `Phylogenetic Trees/`, and Build Tree stays disabled while the field is empty. The default is the alignment's name, and if a bundle of that name already exists LGE adds `-2`, `-3`, and so on rather than overwrite it. Change it when you build several trees from one alignment and want names that say how they differ. On the command line this is `--name`.

**Seed.** Fixes the starting point of the random choices IQ-TREE makes, so the same alignment, settings, and seed give the same tree. The default is blank, shown as `Random`, and the caption reads `A random seed is drawn and recorded in the command.` Type a whole number, such as 1, to repeat an earlier run or to match a published tree. Text that is not a whole number blocks Build Tree. On the command line this is `--seed`, from 1 to 2147483647.

**Threads.** Sets how many processor cores IQ-TREE uses at once, each running one [thread](../../GLOSSARY.md#thread). The default is 1, and the caption explains why. `One thread gives the same tree on every run. More threads can be faster on large alignments, but IQ-TREE then gives slightly different branch lengths each run.` Raise it only for a large alignment when speed matters more than an exact rerun. LGE always records the count, and on the command line this is `--threads`.

**Safe numerical mode.** Makes IQ-TREE use slower arithmetic that avoids numerical underflow, a failure in which multiplied probabilities become too small for the computer to hold. The default is off, because the slower arithmetic is wasted on runs that do not need it. Turn it on after IQ-TREE reports numerical underflow, which happens most often on very long alignments. On the command line this is `--safe`.

**Keep identical sequences.** Keeps every copy of an identical sequence in the search. The default is off, and the caption explains what IQ-TREE does then. `When off, IQ-TREE drops third and later identical copies from the search and adds them back as zero-length tips.` Turn it on when every copy must take part in the search. On the command line this is `--keep-identical`.

**IQ-TREE executable.** Points the run at a specific IQ-TREE program file instead of the one LGE manages. The default is empty, shown as `Bundled iqtree3`, meaning the `iqtree3` program from the `phylogenetics` pack. Set it only when you must reproduce a result with a particular IQ-TREE version. On the command line this is `--iqtree-path`.

**Additional IQ-TREE parameters.** Passes text directly to IQ-TREE after the options above. The default is empty, which is right for almost every run. A flag that one of the controls above already sets, such as `-m`, `-T`, `-B`, `--alrt`, `-o`, or `--seed`, blocks Build Tree with a message such as `Remove -T from the additional parameters. Use Threads instead.` Use the field only for an IQ-TREE option the dialog does not show, such as the standard bootstrap `-b`, after reading IQ-TREE's own documentation. A tree built with `-b` records no support labels. On the command line this is `--extra-args`, and [Multiple sequence alignments and trees](../appendices/cli-reference.md#multiple-sequence-alignments-and-trees) in the CLI Reference lists every refused flag.

### Root on Selected Branch

**Node to root on.** Sets the node whose branch carries the new root, which LGE places halfway along the branch between that node and its parent, so every branch is drawn leading away from it. The default is the selected node, since rooting has no dialog. Select the outgroup before you right-click, such as the macaque clade when the question is about the apes. On the command line this is `--on`.

**Output bundle name.** Names the new `.lungfishtree` bundle written into `Phylogenetic Trees/`, leaving the original tree untouched. The default is the source bundle's name with `-rerooted` added, and a repeat run adds `-2`, `-3`, and so on. The viewport offers no way to change it, so set a different name only on the command line, where you give the path yourself. On the command line this is `--output`.

### Extract subtree

**Node to extract.** Chooses the clade that becomes the new tree, meaning that node and everything descended from it. The default is the selected node, and everything outside the clade is left behind. Pick the node whose descendants form the group you want to study on its own, such as one well supported lineage inside a large tree. On the command line this is `--node`.

**Output bundle name.** Names the bundle that **Extract Subtree as New Bundle...** writes into `Phylogenetic Trees/`. The default joins the clade's tip labels with `+` and adds `-subtree`, naming a clade of more than three tips after its first tip and a count, and a repeat run adds `-2`, `-3`, and so on. The viewport offers no way to change it, so set a different name only on the command line. On the command line this is `--output`.

**Export file name.** Names the plain Newick file that **Export Subtree...** writes through a save panel. The default is the node's label with `.nwk` added. Change it in the save panel when another program expects a particular file name. On the command line this is `--output` on `tree export subtree`.

## Reading the results

<!-- SHOT: tree-viewport-primate-mito -->

### The shape of the viewport

The summary line runs above the toolbar. It gives the bundle name, the tip count, the internal node count, and whether the tree is rooted, separated by wide spaces. On the primate tree it reads `primate-mito   5 tips   4 internal nodes   Rooted`.

The tree fills the canvas, drawn as a rectangular phylogram with a scale bar in substitutions per site. Each internal node shows its support as IQ-TREE wrote it, such as `99/100`. Below the canvas a detail line describes the selected node. A `Nodes` drawer across the bottom of the window lists every tip and internal node in the columns `Node`, `Type`, `Tips`, and `Branch`, then one column for each support test the run asked for, here `SH-aLRT` and `UFBoot`. Clicking a row selects that node on the canvas, and clicking a node on the canvas selects its row.

The toolbar holds the working controls. A segmented control, a button divided into labelled parts, switches the drawing between `Phylogram` and `Cladogram`. A [cladogram](../../GLOSSARY.md#cladogram) sets every tip at the same depth and shows only who joins whom, which helps when one long branch squashes the rest. A second segmented control colours branches by `None`, `Support`, or `Branch`, meaning by nothing, by support value, or by branch length. The `Tip labels` menu lists `Original` and any extra column from a `metadata.tsv` file in the bundle, and it stays unavailable when the bundle has no such file. The `Find tip or node` field selects and centres the first node whose label or metadata contains what you type, after you press Return. Four icon buttons zoom out, zoom in, fit the tree to the window, and reset the view.

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Selecting a node fills it with detail rows. Every node reports `Node`, `Type`, and `Descendant Tips`. Every node except the root also reports `Branch Length` and `Cumulative Divergence`, the sum of branch lengths from the root to that node. Nodes with support values add `Support`, the pair as written, and `Support Type`, here `SH-aLRT/UFBoot`.

### The numbers on this tree

The primate tree has 5 tips and 4 internal nodes. Five sequences in always give five tips out. A rooted tree with five tips has at most four internal nodes, the number of tips minus one, so four means IQ-TREE resolved every grouping it could, and one of the four is the root itself. Fewer would mean the alignment could not separate some of the sequences.

Here is the tree the Procedure's settings give, ModelFinder with both support tests at 1000 replicates, the macaques as the outgroup, Seed 1, and one thread, as Newick with branch lengths rounded to four places. The pair right after a closing bracket is that grouping's support, SH-aLRT first and UFBoot second. With the same seed and one thread your tree matches this one byte for byte.

```text
(((Human_NC_012920.1:0.0601,Chimp_NC_001643.1:0.0589)99/100:0.0296,Gorilla_NC_011120.1:0.0740)100/100:0.4476,(RhesusMacaque_NC_005943.1:0.0650,CynomolgusMacaque_NC_012670.1:0.0299)100/100:0.4476);
```

With the Seed field blank, LGE draws a new seed for each run and the support values can move by a fraction of a point. Other runs have given the human and chimpanzee pair 99.2/100 and 99.3/100, for example. The topology stays the same.

ModelFinder chose `TPM2u+F+I` on this fixture. The `+F` means base frequencies counted from the data, and `+I` means a share of sites is allowed never to change. On a 14-core Apple M4 Pro Mac the whole run, model testing and both support tests included, took a few seconds.

Read the rooted tree from the root outwards. The root splits the tips into two groups, the two macaques on one side and the three apes on the other. Inside the apes, the gorilla branches off first, and the human and the chimpanzee pair up last. That answers the checks set out earlier. The macaques are sisters, the human and the chimpanzee are closer to each other than to the gorilla, and the apes sit apart from the monkeys. The order in which tips are written carries no meaning.

The branch lengths tell the same story. The macaques sit on tip branches of 0.0650 and 0.0299 changes per site, and two branches of 0.4476 run from the root to the macaque clade and to the ape clade. Together they make one branch of 0.8953 between apes and Old World monkeys, about 12 times the longest tip branch, the gorilla's 0.0740. That reflects tens of millions of years of separation in mitochondrial DNA. One branch dominating a small tree this way is expected on a set that spans that much time. The root sits at its midpoint because an outgroup says which branch carries the root, not where along it, so the two halves are equal by construction.

Select the cynomolgus macaque tip and the Inspector reports a cumulative divergence of about 0.478, while the human tip reports about 0.537. On a rooted tree this sum runs back to the root. Because the root's place on its branch is a convention, compare these sums within one tree rather than reporting them as ages.

### Support values

Each internal node except the root carries two numbers. The `SH-aLRT` column gives the SH-aLRT value and the `UFBoot` column the ultrafast bootstrap value, the percentage of resampled trees that recovered that grouping. On this tree the human and chimpanzee pair scores 99 and 100, and the ape clade and the macaque clade both score 100 and 100. Those last two are one result read twice, since they are the two halves of the branch the root split, and both halves keep its support. The root itself carries no number, because it is a choice of outgroup, not a grouping the data chose. Treat a node as well supported when UFBoot is 95 or more and SH-aLRT is 80 or more, and anything lower as not established.

Switch the colour control to `Support` to shade branches by these numbers. Branches with UFBoot of 95 or higher turn blue, weaker ones orange, and any branch with no value grey. A legend at the right end of the summary line names the three shades and reads `Color shows UFBoot (95 or higher strong). SH-aLRT 80 or higher also indicates strong support.` The legend shows only in Support mode.

A run with only one test ticked gives one support column and one number per node. A tree imported from another program carries no record of which test made its numbers, so it keeps a single `Support` column, and `Support Type` is LGE's guess from the values, which can read `unknown`.

### Rooted and unrooted

The summary line's last part says whether the tree has a root. A tree built with an outgroup reads `Rooted`. A tree built without one reads `Unrooted (drawn root is arbitrary)`, and the Inspector's Rooting row says the same. On an unrooted tree, the apparent root at the left edge of the canvas is a drawing convention with no biological meaning, and only a tree rooted on an outgroup can say which lineage branched off first. A bundle made by extracting a clade or relabelling tips keeps the rooting its source tree had. **Root on Selected Branch** gives a tree a root after the fact.

### The Inference section

A tree LGE built carries an Inference section in the Inspector, above the Tree Summary section. It records how the tree was made, one row per fact, and every value can be selected and copied. On the primate tree it reads as follows.

| Row | Value |
|---|---|
| Program | IQ-TREE 3.1.3 |
| Model requested | MFP (ModelFinder) |
| Best-fit model | TPM2u+F+I (BIC) |
| Substitution model | TPM2u+F+I |
| Sequence type | Detected automatically |
| Branch support | SH-aLRT 1000, UFBoot 1000. Node labels read SH-aLRT/UFBoot. |
| Outgroup | RhesusMacaque_NC_005943.1, CynomolgusMacaque_NC_012670.1 |
| Seed | 1 |
| Threads | 1 |
| Input | primate-mito, 5 of 5 sequences, all columns |
| Log-likelihood | -47913.8807 (s.e. 246.1459) |
| Branch lengths | substitutions per site |

Best-fit model appears only when ModelFinder ran, and a fixed model shows only Model requested and Substitution model. An Outgroup warning row appears when the outgroup did not form one group and the tree was left unrooted. The log-likelihood is the score of the final tree, and it is useful only for comparing trees built from the same alignment. Two rows at the end, IQ-TREE Report and IQ-TREE Log, name IQ-TREE's own report and log inside the bundle, and clicking either shows the file in the Finder. The report holds the full ModelFinder table and the counts of constant and parsimony-informative sites.

A rerooted copy keeps the Inference section, but its Outgroup row reads None, since the root came from a later step. An extracted clade has no Inference section, because IQ-TREE never saw that clade on its own.

### Tip names

Tips carry the alignment's row names exactly, even names with spaces or brackets. LGE hands IQ-TREE short stand-in names and maps them back afterwards, and the file `artifacts/iqtree/tip-map.tsv` inside the bundle pairs each stand-in with its row. Because a tree cannot hold two tips of the same name, two rows in scope that share a name block Build Tree with a message naming both rows.

### Acting on a node

Right-click the canvas or the Nodes drawer for ten items that act on the selected node, so click the node first. The same ten sit under **Selection > Tree Node** in the menu bar, where they work while the canvas or the Nodes drawer has focus and a node is selected. VoiceOver offers them as actions on each node of the canvas. **Show in Inspector**, **Copy Name**, and **Center Node** do what their names say. **Copy Subtree as Newick** puts that clade's Newick text on the clipboard. **Root on Selected Branch**, **Extract Subtree as New Bundle...**, and **Export Subtree...** are the operations in the Procedure.

**Collapse Clade** folds an internal node's descendants into a single point on screen, and the same item then reads **Expand Clade** to undo it. It changes the drawing only, never the saved tree, and it is unavailable on a tip. To copy several names, click a tip, Shift-click more tips, and choose **Copy Selected Tip Names**, which puts one name per line on the clipboard.

**Reveal Provenance** shows how the bundle was made, which the last check in What good looks like reads.

### Relabelling tips from metadata

Tip labels come from the alignment's row names, which often carry an [accession](../../GLOSSARY.md#accession), the database identifier of each record. To show friendlier names, add a tab-separated file named `metadata.tsv` inside the tree bundle. A bundle looks like one file in the Finder but is really a folder, so right-click it in the Finder, choose Show Package Contents, and save the file at the top level. Name the identifier column `id`, `sample`, `sample_id`, `name`, or `tip`, written in lowercase, and every other column becomes a labelling choice.

```tsv
id	species
Human_NC_012920.1	Human
Chimp_NC_001643.1	Chimpanzee
Gorilla_NC_011120.1	Gorilla
RhesusMacaque_NC_005943.1	Rhesus macaque
CynomolgusMacaque_NC_012670.1	Cynomolgus macaque
```

Reopen the bundle and pick `species` from the `Tip labels` menu. This changes only what is drawn. To write a new bundle whose Newick carries the new names, run `tree relabel` as the last section shows, because the window has no control for it. In the relabelled Newick, names containing a space are wrapped in single quotes, such as `'Rhesus macaque'`.

## What good looks like

Confirm the tip count. Five sequences in should give five tips out with the alignment's row names unchanged. An extracted clade bundle should hold the clade's own tip count, two for the macaques.

Confirm the tree is rooted where you meant. The summary line should end in `Rooted`, and the root should separate the outgroup from everything else. If it reads `Unrooted (drawn root is arbitrary)` after you ticked an outgroup, the Inspector's Outgroup warning row says the outgroup did not form one group on the tree.

Confirm the topology matches what is already known. The two macaques are sisters, the human and the chimpanzee are sisters, and the apes and monkeys sit on opposite sides of the long branch. When a set with known relationships comes back rearranged, suspect a mislabelled input before you suspect a discovery.

Confirm the support values are present and high. Both support columns should be filled for every internal node but the root. A node with UFBoot below 95 or SH-aLRT below 80 marks a grouping the alignment did not establish.

Confirm the Inference section and the tree's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, name the model, both replicate counts, the outgroup, the seed, and the thread count you meant to use. With one thread and that seed, the recorded command rebuilds the same tree byte for byte.

Confirm no branch is unexpectedly long. The 0.8953 total between apes and monkeys is expected here. An unexplained branch that long usually means one input is far more distant than the others, or is not the same gene at all.

When a run goes wrong, the alignment is the usual cause. Identical or near-identical sequences give zero-length branches and low support everywhere. A short alignment carries too little signal, so expect lower support and do not over-read it. What counts is parsimony-informative sites, columns where at least two different bases each appear in at least two sequences. The IQ-TREE Report counts them, 2,709 on this alignment, and the fewer there are, the less the tree can resolve. A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it. IQ-TREE prints the line that stopped it last, beginning with the word ERROR, so read its output from the bottom.

## On the command line

The block below follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and every flag of the `tree` commands is listed in [Multiple sequence alignments and trees](../appendices/cli-reference.md#multiple-sequence-alignments-and-trees) in the CLI Reference. It reproduces the Procedure on the alignment from the previous chapter and adds `tree relabel`, which has no window equivalent.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Genes and Sequences.lungfish"
MSA="$PROJECT/Analyses/Multiple Sequence Alignments/primate-mito.lungfishmsa"
TREES="$PROJECT/Phylogenetic Trees"

# Infer the tree rooted on the macaques, with both support tests,
# a fixed seed, and one thread so a rerun gives the same tree.
lungfish-cli tree infer iqtree "$MSA" \
  --project "$PROJECT" \
  --output "$TREES/primate-mito.lungfishtree" \
  --name primate-mito --model MFP \
  --bootstrap 1000 --alrt 1000 \
  --seed 1 --threads 1 \
  --outgroup RhesusMacaque_NC_005943.1,CynomolgusMacaque_NC_012670.1

# The same run with no outgroup gives an unrooted tree.
lungfish-cli tree infer iqtree "$MSA" \
  --project "$PROJECT" \
  --output "$TREES/primate-mito-unrooted.lungfishtree" \
  --name primate-mito-unrooted --model MFP \
  --bootstrap 1000 --alrt 1000 \
  --seed 1 --threads 1

# Internal nodes have no unique name, so select them by node ID.
# The app does not show node IDs. In the Finder, right-click the tree bundle,
# choose Show Package Contents, and open tree/primary.normalized.json in TextEdit.
# Find the entry whose displayLabel is RhesusMacaque_NC_005943.1 and copy its
# parentID, which is the ID of the node where the two macaques join.
MACAQUE_NODE=node-xxxxxxxxxxxxxxxx

# Root the unrooted tree on the branch above the macaque clade.
lungfish-cli tree reroot \
  --bundle "$TREES/primate-mito-unrooted.lungfishtree" \
  --on "$MACAQUE_NODE" \
  --output "$TREES/primate-mito-unrooted-rerooted.lungfishtree"

# Extract the macaque clade as its own bundle.
lungfish-cli tree extract-subtree \
  --bundle "$TREES/primate-mito-unrooted.lungfishtree" \
  --node "$MACAQUE_NODE" \
  --output "$TREES/macaques.lungfishtree"

# Write a new bundle with tips relabelled from metadata.tsv.
lungfish-cli tree relabel \
  --bundle "$TREES/primate-mito.lungfishtree" \
  --column species \
  --output "$TREES/primate-mito-species.lungfishtree"

# Bring a tree built elsewhere into the project.
lungfish-cli import tree "$HOME/Desktop/my-tree.nwk" --project "$PROJECT"
```

The window records this same command in the Operations Panel, always with `--threads` and `--seed`, so a run made with a blank Seed field still names the seed it drew. A whole-alignment run passes no `--rows` or `--columns`, and a run on Selected rows and columns passes both. Without `--seed` the command lets IQ-TREE draw a seed, and the provenance records it as `effectiveSeed`. Without `--threads` IQ-TREE runs with `-T AUTO`, which gives slightly different branch lengths from run to run, so give `--threads 1` and a seed whenever a rerun must match. `tree reroot` also takes a tip label for `--on`, which roots the tree on that one sequence's branch, and it places the root at the midpoint of the branch exactly as **Root on Selected Branch** does.

## Next

This is the last chapter in Sequences, which worked on finished sequences, records someone already assembled and checked. Continue to [Importing Sequencing Reads](../03-reads/01-importing-fastq.md), the first chapter of Reads (FASTQ), where the data are the raw reads a sequencer writes, which have to be checked and cleaned before they can be mapped to a reference like the ones this part imported.

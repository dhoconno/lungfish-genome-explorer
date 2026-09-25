---
title: Building Trees
chapter_id: 02-sequences/05-building-trees
audience: analyst
prereqs: [01-foundations/01-what-is-a-genome, 02-sequences/04-aligning-sequences]
estimated_reading_min: 18
task: Infer a maximum-likelihood tree from an alignment with IQ-TREE, read it in the tree viewport, and re-root, extract a clade from, or relabel it.
tags: [sequences, phylogenetics, iqtree, tree, newick, bootstrap]
tools: [iqtree]
parameters_refs: [tree.iqtree, tree.reroot, tree.extract-subtree, import.tree]
entry_points:
  - Right-click in the alignment viewport > Build Tree with IQ-TREE...
  - File > Import Center... > Alignments > Phylogenetic Trees
  - "CLI: lungfish-cli tree infer iqtree"
  - "CLI: lungfish-cli tree reroot"
  - "CLI: lungfish-cli tree extract-subtree"
shots:
  - id: iqtree-dialog
    caption: "The Phylogenetic Tree Operations dialog, with the Output Name and Model fields above the Branch Support group and the collapsed Advanced Options group."
  - id: tree-viewport-primate-mito
    caption: "The primate mitochondrial tree open in the tree viewport, with the summary line, the Phylogram and Cladogram control, and the Nodes drawer showing the visible subset of the tree’s nodes."
illustrations:
  - id: tree-anatomy
    caption: "Anatomy of a rectangular phylogram, showing tips, internal nodes, branch lengths, and support values."
glossary_refs: [iqtree, phylogram, cladogram, clade, newick, support-value, sh-alrt, bootstrap, maximum-likelihood, substitution-model, tip, internal-node, branch-length, topology, rooting, outgroup, msa, alignment-column, mitochondrial-genome, accession, plugin-pack, provenance, checksum, bundle, sidebar, inspector, operations-panel, import-center]
features_refs: []
fixtures_refs: [primate-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A phylogenetic tree is a diagram of inferred ancestry. Each sequence you put in becomes a [tip](../../GLOSSARY.md#tip), a point at the end of a branch. Every place where branches meet is an [internal node](../../GLOSSARY.md#internal-node), which stands for an ancestor that was never sequenced. An internal node is a calculated guess, not a sample you could look up. The pattern of which tips join which is the [topology](../../GLOSSARY.md#topology), and the topology is the main result of a tree run.

A tree also has lengths. On the default drawing, the horizontal length of a branch is its [branch length](../../GLOSSARY.md#branch-length), the estimated number of base changes per site along that branch. A site is one [alignment column](../../GLOSSARY.md#alignment-column), meaning one position compared across all your sequences. A branch length of 0.06 therefore means about six changes for every hundred sites. A tree drawn with its branch lengths to scale is called a [phylogram](../../GLOSSARY.md#phylogram).

![Rectangular phylogram with tips, internal nodes, branch lengths, and support values](../../assets/illustrations-imagegen/02-sequences/05-building-trees/tree-anatomy.png)

Lungfish Genome Explorer (LGE) builds trees with [IQ-TREE](../../GLOSSARY.md#iqtree), a program that uses [maximum likelihood](../../GLOSSARY.md#maximum-likelihood). The alignment is the fixed evidence, and each candidate tree is scored against it. Maximum likelihood keeps the tree under which the observed columns are most probable, given an assumed [substitution model](../../GLOSSARY.md#substitution-model), a set of rates for turning one base into another. Models differ because real DNA does not change evenly. An A-to-G change is more common than an A-to-T change, for example, and a model that ignores this tends to underestimate how much change a long branch carries. IQ-TREE can test many models and choose one for you.

Confidence is measured separately from the tree. A [support value](../../GLOSSARY.md#support-value) is a number from 0 to 100 on an internal node that says how consistently the data recover that grouping. The usual kind is the [bootstrap](../../GLOSSARY.md#bootstrap), which rebuilds the tree many times from resampled alignment columns and counts how often each grouping comes back. The topology looks equally crisp whether the data supported it strongly or barely, so the support values are the only way to tell the two apart.

Trees are stored as [Newick](../../GLOSSARY.md#newick) text, a single line in which brackets group the tips that share an ancestor and a number after each name gives its branch length. Nearly every tree program reads and writes it.

A tree is only a summary of the alignment it came from. It cannot see anything the columns do not contain, and a poor alignment gives a confident-looking poor tree. In practice, check the alignment first, as [Aligning Sequences](04-aligning-sequences.md) describes, and then read the topology and its support values as two separate results.

## Why you would do this

This chapter builds a tree from the five primate [mitochondrial genomes](../../GLOSSARY.md#mitochondrial-genome) that the previous chapter aligned. They are human, chimpanzee, gorilla, rhesus macaque, and cynomolgus macaque.

The previous chapter ended with a pairwise identity matrix, which says how similar each pair of sequences is. A matrix is not a history. It shows that the two macaques are the most similar pair, but it cannot say in what order the lineages split. Branching order is what a tree answers.

The known primate relationships make this a good teaching set, because you can check the answer. The two macaques should be sisters, meaning two tips that meet at the same internal node with nothing else between them. The human and the chimpanzee should be closer to each other than either is to the gorilla. All three apes should sit apart from the two monkeys. A tree that says otherwise is reporting a problem with the run, not news about primates.

IQ-TREE returns an unrooted tree, which shows the groupings but not which lineage branched off first. [Rooting](../../GLOSSARY.md#rooting) the tree on an [outgroup](../../GLOSSARY.md#outgroup), a lineage known to sit outside the group you are studying, adds that direction. For the three apes, the two macaques are the natural outgroup.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Genes and Sequences demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds the `primate-mito` reference bundle but no alignment, so run [Aligning Sequences](04-aligning-sequences.md) in it first. To import the FASTA yourself instead, follow the rest of this section.

This chapter uses the primate-mito fixture. Download `primate-mito.fasta` from [primate-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/primate-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The FASTA file is the input to the previous chapter, not to this one. This chapter starts from the `.lungfishmsa` [bundle](../../GLOSSARY.md#bundle) that [Aligning Sequences](04-aligning-sequences.md) leaves under `Analyses/Multiple Sequence Alignments/`, so work through that chapter first.

Install the `phylogenetics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The pack provides IQ-TREE 3.1.3, the version that produced this chapter's tree. No container and no internet connection are needed once the pack is installed. Model testing runs as part of every inference, so expect the tree to take longer than the alignment did.

## Procedure

### Infer the tree

1. Click the `.lungfishmsa` bundle in the sidebar to open it in the alignment viewport.

2. Click the first sequence name in the name gutter, the column of sequence names at the left of the alignment, then Shift-click the last name so all five rows are selected. **Build Tree with IQ-TREE...** stays unavailable until at least two rows are selected.

3. Right-click inside the alignment and choose **Build Tree with IQ-TREE...**. The **Phylogenetic Tree Operations** dialog opens, and it follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. The Scope line in its Inputs section should read `Selected 5 rows`. A smaller number means the selection did not take, so go back to step 2.

4. Leave **Output Name** as `primate-mito` and **Model** as `MFP`.

    <!-- SHOT: iqtree-dialog -->

5. Tick **Ultrafast Bootstrap** in the Branch Support group, leave its **Replicates** field at 1000, and click Run. The bootstrap is off by default, and a tree built without it carries no support values at all.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). When the row finishes, the new bundle appears in the sidebar under `Phylogenetic Trees/`. That is a top-level project folder LGE creates the first time it writes a tree, one of the fixed homes [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) mentions. Click the bundle to open the tree viewport.

The dialog has no outgroup field. Rooting is a separate step you take on the finished tree.

### Root the tree on the macaques

Click the internal node where the rhesus macaque and cynomolgus macaque branches join, so the detail line below the tree names it, then right-click the node and choose **Re-root Here**. No dialog opens, and a new bundle named `primate-mito-rerooted` appears under `Phylogenetic Trees/`, leaving the original tree as it was.

Click the new bundle and read its summary line. It should report the same 5 tips and 3 internal nodes as the original and end in `rooted`. The root now sits at the node where the two macaques join, so the canvas draws the three apes as one group on a single branch, with the human and the chimpanzee paired inside it.

### Extract the macaque clade

A [clade](../../GLOSSARY.md#clade) is an internal node together with everything descended from it. Go back to the original `primate-mito` tree, click the same macaque node to select it, then right-click it and choose **Extract Subtree as New Bundle...**. No dialog opens. A new two-tip bundle appears under `Phylogenetic Trees/`, named after the node's label with `-subtree` added. An internal node's label is its support value, the number the Nodes drawer shows in its `Node` column. The macaque node usually scores 100 with the bootstrap on, which gives a bundle named `100-subtree`. A node with no support value is labelled `Internal node`, which gives `Internal node-subtree`. To hand the clade to a program outside LGE instead, choose **Export Subtree...**, which writes a plain `.nwk` Newick file through a save panel.

### Import a tree built elsewhere

A tree made by another program can come in as a `.lungfishtree` bundle and use every viewport control in this chapter. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. On the Alignments tab, click **Import...** on the Phylogenetic Trees card, or drop the files onto the card. It accepts Newick and Nexus files, Nexus being a structured text format that can wrap a Newick tree, which covers IQ-TREE `.treefile` and `.contree` outputs and results from RAxML-NG and FastTree. Each file becomes one bundle under `Phylogenetic Trees/`.

## Settings

The Phylogenetic Tree Operations dialog holds thirteen settings. Eleven sit in plain view, and two, IQ-TREE Executable and IQ-TREE Parameters, sit inside the collapsed Advanced Options group. Re-rooting and subtree extraction show no dialog, so their settings are fixed by the node you select before you right-click. The Phylogenetic Trees import card has no settings at all.

### Build Tree with IQ-TREE

**Output Name.** Names the `.lungfishtree` bundle the run writes into `Phylogenetic Trees/`, and Run stays disabled while the field is empty. The default is the alignment bundle's name, and if a bundle of that name already exists LGE adds `-2`, `-3`, and so on rather than overwrite it. Change it when you build several trees from one alignment and want names that say how they differ. On the command line this is `--name`.

**Model.** Names the substitution model. The default is `MFP`, short for ModelFinder Plus, which is not a model but an instruction to test many models on your data and use the best fit, so you do not have to choose. Type a model name such as `GTR+G`, a model that gives every kind of base change its own rate and lets some sites change faster than others, when a published method requires that exact model or when model testing takes too long on a large alignment. On the command line this is `--model`.

**Sequence Type.** Tells IQ-TREE what the alignment characters are, choosing from Auto, DNA, Amino Acid, Codon, Binary, Morphological, and NT to AA. The default is Auto, which lets IQ-TREE decide from the characters it sees and is right for this alignment. Choose Codon for an alignment built in three-base blocks so each block stays one codon, or NT to AA to translate a nucleotide alignment and build a protein tree from it. On the command line this is `--sequence-type`.

**Ultrafast Bootstrap.** Turns on support values from resampled alignments, in which columns are drawn again at random with replacement, so some appear twice and others not at all, and the tree is rebuilt from each copy. The default is off, which keeps a first run fast but leaves the tree with no support values. Turn it on for any tree you plan to interpret or publish. On the command line this is `--bootstrap`, which takes the replicate count and so does the work of this box and the next field together.

**Replicates (Ultrafast Bootstrap).** Sets how many resampled alignments the ultrafast bootstrap builds, in the field labelled `Replicates` directly beside Ultrafast Bootstrap. The default is 1000, the smallest number IQ-TREE's ultrafast method accepts, and the dialog will not run with fewer. Raise it only if the support values change noticeably between repeat runs. On the command line this is the number given to `--bootstrap`.

**SH-aLRT.** Turns on a second, faster support test that compares each branch with the alternative arrangements immediately around it. The default is off, because the bootstrap alone answers whether a grouping is trustworthy. Turn it on alongside the bootstrap when you want two independent support measures on every branch. On the command line this is `--alrt`.

**Replicates (SH-aLRT).** Sets how many replicates the [SH-aLRT](../../GLOSSARY.md#sh-alrt) test uses, in the `Replicates` field beside SH-aLRT. The default is 1000, and as with the bootstrap more replicates cost time and steady the numbers. Change it rarely. On the command line this is the number given to `--alrt`.

**Seed.** Fixes the starting point of the random choices IQ-TREE makes, so the same alignment and the same seed give the same tree. The default is blank, which lets IQ-TREE take a new seed from the clock on every run, so two runs can differ slightly. Type any whole number, such as 1, whenever you need a rerun to reproduce your tree exactly. On the command line this is `--seed`.

**Threads.** Sets how many processor cores IQ-TREE uses at once. The default is blank, which lets IQ-TREE choose a count for your Mac. Type a small number, such as 2, to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Safe numerical mode.** Makes IQ-TREE use slower arithmetic that avoids numerical underflow, a failure in which multiplied probabilities become too small for the computer to hold. The default is off, because the slower arithmetic is wasted on runs that do not need it. Turn it on after a run stops with a message about a likelihood that is not finite, which happens most often on very long alignments. On the command line this is `--safe`.

**Keep identical sequences.** Keeps sequences that exactly match another sequence as separate tips through the whole analysis. The default is off, because IQ-TREE otherwise sets duplicates aside, builds the tree faster, and adds them back afterwards on zero-length branches beside their twins. Turn it on when every input name must appear as its own tip with its own branch length. On the command line this is `--keep-identical`.

**IQ-TREE Executable.** Points the run at a specific IQ-TREE program file instead of the one LGE manages. The default is empty, meaning the `iqtree3` program from the `phylogenetics` pack. Set it only when you must reproduce a result with a particular IQ-TREE version. On the command line this is `--iqtree-path`.

**IQ-TREE Parameters.** Passes text straight to IQ-TREE after the settings above, and LGE checks only that the text splits into valid command-line words. The default is empty, which is right for almost every run. Use it only for an IQ-TREE option the dialog does not show, after reading IQ-TREE's own documentation. On the command line this is `--extra-iqtree-options`.

### Re-root

**Node to root on.** Sets which node the new tree is rooted on, so every branch is drawn leading away from it. The default is the selected node, since re-rooting has no dialog. Select a known outgroup before you right-click, such as the macaque clade when the question is about the apes. On the command line this is `--on`.

**Output bundle name.** Names the new `.lungfishtree` bundle written into `Phylogenetic Trees/`, leaving the original tree untouched. The default is the source bundle's name with `-rerooted` added, and a repeat run adds `-2`, `-3`, and so on. The viewport offers no way to change it, so set a different name only on the command line, where you give the path yourself. On the command line this is `--output`.

### Extract subtree

**Node to extract.** Chooses the clade that becomes the new tree, meaning that node and everything descended from it. The default is the selected node, and everything outside the clade is left behind. Pick the node whose descendants form the group you want to study on its own, such as one well supported lineage inside a large tree. On the command line this is `--node`.

**Output bundle name.** Names the bundle that **Extract Subtree as New Bundle...** writes into `Phylogenetic Trees/`. The default is the node's label with `-subtree` added, and a repeat run adds `-2`, `-3`, and so on. The viewport offers no way to change it, so set a different name only on the command line. On the command line this is `--output`.

**Export file name.** Names the plain Newick file that **Export Subtree...** writes through a save panel. The default is the node's label with `.nwk` added. Change it in the save panel when another program expects a particular file name. On the command line this is `--output` on `tree export subtree`.

## Reading the results

<!-- SHOT: tree-viewport-primate-mito -->

### The shape of the viewport

The summary line runs above the toolbar. It gives the bundle name, the tip count, the internal node count, and the word rooted or unrooted, separated by wide spaces. On the primate tree it reads `primate-mito   5 tips   3 internal nodes   unrooted`.

The tree fills the canvas, drawn as a rectangular phylogram. Below the canvas a detail line describes the selected node. A `Nodes` drawer across the bottom of the window lists every tip and internal node in five columns, `Node`, `Type`, `Tips`, `Branch`, and `Support`. Clicking a row selects that node on the canvas, and clicking a node on the canvas selects its row.

The toolbar holds the working controls. A segmented control, a button divided into labelled parts, switches the drawing between `Phylogram` and `Cladogram`. A [cladogram](../../GLOSSARY.md#cladogram) sets every tip at the same depth and shows only who joins whom, which helps when one long branch squashes the rest. A second segmented control colours branches by `None`, `Support`, or `Branch`, meaning by nothing, by support value, or by branch length. The `Tip labels` menu lists `Original` and any extra column from a `metadata.tsv` file in the bundle, and it stays unavailable when the bundle has no such file. The `Find tip or node` field selects and centres the first node whose label or metadata contains what you type, after you press Return. Four icon buttons zoom out, zoom in, fit the tree to the window, and reset the view.

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Selecting a node fills it with detail rows. Every node reports `Node`, `Type`, and `Descendant Tips`. Every node except the root also reports `Branch Length` and `Cumulative Divergence`, the sum of branch lengths from the root to that node. Nodes with support values add `Support` and `Support Type`.

### The numbers on this tree

The primate tree has 5 tips and 3 internal nodes. Five sequences in always give five tips out. An unrooted tree with five tips can have at most three internal nodes, the number of tips minus two, so three means IQ-TREE resolved every grouping it could. Fewer would mean the alignment could not separate some of the sequences.

Here is the fixture's reference tree as Newick, with branch lengths rounded to four places. The tree below has no support values, because it was built without the bootstrap. Yours will have them, because you ticked Ultrafast Bootstrap, so your Newick also carries a number right after each closing bracket, which is that grouping's support value. Your branch lengths may differ from these in the last decimal places.

```text
(Human_NC_012920.1:0.0601,Chimp_NC_001643.1:0.0589,(Gorilla_NC_011120.1:0.0740,(RhesusMacaque_NC_005943.1:0.0650,CynomolgusMacaque_NC_012670.1:0.0299):0.8982):0.0296);
```

On an unrooted tree, read the topology as a set of splits, the two groups of tips you get by cutting one branch. The innermost bracket holds the two macaques, and cutting the branch below it separates the macaques from the three apes. The next bracket out appears to add the gorilla to the macaques, but on an unrooted tree that nesting is only a way of writing the tree down. What it records is a branch with the gorilla and the macaques on one side and the human and the chimpanzee on the other. Read from the other end, that branch is what makes the human and the chimpanzee each other's closest relatives. The outermost bracket splits three ways, into human, chimpanzee, and the rest, and a three-way split at the top is what unrooted looks like in Newick. The order in which tips are written carries no meaning.

Those two splits answer the checks set out earlier. The macaques are sisters, the human and the chimpanzee are closer to each other than to the gorilla, and the apes sit on one side of a branch with the monkeys on the other. The gorilla appearing beside the macaques on the canvas comes from drawing an unrooted tree from an arbitrary starting point. It is not a claim that gorillas group with monkeys.

The branch lengths tell the same story. The macaques sit on tip branches of 0.0650 and 0.0299 changes per site, and a branch of 0.8982 separates them from everything else. That long branch is the split between apes and Old World monkeys, and at about 12 times the longest tip branch, the gorilla's 0.0740, it reflects tens of millions of years of separation in mitochondrial DNA. One branch dominating a small tree this way is expected on a set that spans that much time.

Select the cynomolgus macaque tip and the Inspector reports a cumulative divergence of about 0.958, while the human tip reports about 0.060. On an unrooted tree this sum runs back to the drawing's left edge rather than to a real ancestor, so treat it as a picture of distance from an arbitrary point, not as a result to report.

### Support values

With Ultrafast Bootstrap ticked, each internal node carries a number, the percentage of resampled trees that recovered that grouping. The bootstrap number appears as the node's label in the Nodes drawer and in the `Support` column. A value at or above 95 is usually treated as well supported, and one below 70 should not be relied on. Between 70 and 95 the grouping is likely but unsettled, so report it as provisional. Switch the colour control to `Support` to shade branches by these numbers.

If the `Support` column is empty from top to bottom, the bootstrap box was left unticked. That is a run to redo, not a sign the data were uninformative. If both tests were on, IQ-TREE writes two numbers per node joined by a slash, the SH-aLRT value first and the bootstrap value second, and `Support Type` reads `unknown` because LGE expects a single number.

### Rooted and unrooted

The summary line's last word says whether the tree has a root. IQ-TREE produces unrooted trees, so `unrooted` on a freshly built tree is the expected outcome, not a failure. The apparent root at the left edge of the canvas is a drawing convention with no biological meaning. Only a tree rooted on an outgroup can say which lineage branched off first. A bundle made by extracting a clade or relabelling tips keeps the word its source tree had, so a clade taken from the unrooted tree reads `unrooted` and one taken from the re-rooted tree reads `rooted`. Only **Re-root Here** gives an unrooted tree a root.

### Acting on a node

Right-click the canvas or the Nodes drawer for ten items that act on the selected node, so click the node first. **Show in Inspector**, **Copy Node Label**, and **Center Node** do what their names say. **Copy Subtree as Newick** puts that clade's Newick text on the clipboard. **Re-root Here**, **Extract Subtree as New Bundle...**, and **Export Subtree...** are the operations in the Procedure.

**Collapse Clade** folds an internal node's descendants into a single point on screen, and the same item then reads **Expand Clade** to undo it. It changes the drawing only, never the saved tree, and it is unavailable on a tip. To copy several names, click a tip, Shift-click more tips, and choose **Copy Selected Tip Names**, which puts one name per line on the clipboard.

**Reveal Provenance** shows how the bundle was made. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

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

Confirm the tip count. Five sequences in should give five tips out with unchanged names. A missing tip usually means IQ-TREE set aside an identical sequence, which **Keep identical sequences** prevents, and IQ-TREE's own output in the Operations Panel names the sequence it removed. An extracted clade bundle should hold the clade's own tip count, two for the macaques.

Confirm the topology matches what is already known. The two macaques are sisters, the human and the chimpanzee are sisters, and the apes and monkeys sit on opposite sides of the long branch. When a set with known relationships comes back rearranged, suspect a mislabelled input before you suspect a discovery.

Confirm the support values are present and high. An empty `Support` column means the bootstrap was off. With it on, values below 70 mark groupings the alignment did not settle.

Confirm no branch is unexpectedly long. The 0.8982 branch between apes and monkeys is expected here. An unexplained branch that long usually means one input is far more distant than the others, or is not the same gene at all.

When a run goes wrong, the alignment is the usual cause. Identical or near-identical sequences give zero-length branches and low support everywhere. A short alignment carries too little signal, so expect support in the 50s to 70s and do not over-read it. What counts is parsimony-informative sites, columns where at least two different bases each appear in at least two sequences, and IQ-TREE reports their number in its output, where fewer than a few hundred is thin. A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it. IQ-TREE prints the line that stopped it last, beginning with the word ERROR, so read its output from the bottom.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The block below reproduces the Procedure and adds `tree relabel`, which has no window equivalent. The project is a `.lungfish` folder that already holds the alignment from the previous chapter.

```bash
PROJECT=~/Documents/primates.lungfish
MSA="$PROJECT/Analyses/Multiple Sequence Alignments/primate-mito.lungfishmsa"
TREES="$PROJECT/Phylogenetic Trees"

# Infer the tree with 1000 ultrafast bootstrap replicates and a fixed seed.
lungfish-cli tree infer iqtree "$MSA" \
  --project "$PROJECT" \
  --output "$TREES/primate-mito.lungfishtree" \
  --name primate-mito \
  --model MFP \
  --bootstrap 1000 \
  --seed 1

# Internal nodes have no unique name, so select them by node ID.
# The app does not show node IDs. In the Finder, right-click the tree bundle,
# choose Show Package Contents, and open tree/primary.normalized.json in TextEdit.
# Find the entry whose displayLabel is RhesusMacaque_NC_005943.1 and copy its
# parentID, which is the ID of the node where the two macaques join.
MACAQUE_NODE=node-xxxxxxxxxxxxxxxx

# Re-root on the macaque clade. The new bundle keeps all 5 tips.
lungfish-cli tree reroot \
  --bundle "$TREES/primate-mito.lungfishtree" \
  --on "$MACAQUE_NODE" \
  --output "$TREES/primate-mito-rerooted.lungfishtree"

# Extract the macaque clade as its own bundle.
lungfish-cli tree extract-subtree \
  --bundle "$TREES/primate-mito.lungfishtree" \
  --node "$MACAQUE_NODE" \
  --output "$TREES/macaques.lungfishtree"

# Write a new bundle with tips relabelled from metadata.tsv.
lungfish-cli tree relabel \
  --bundle "$TREES/primate-mito.lungfishtree" \
  --column species \
  --output "$TREES/primate-mito-species.lungfishtree"

# Bring a tree built elsewhere into the project.
lungfish-cli import tree my-tree.nwk --project "$PROJECT"
```

The window always passes the rows you selected as `--rows`, while a command without `--rows` uses every row in the alignment, which gives the same tree here because all five rows were selected. Leaving out `--seed` behaves like the blank Seed field, so drop it only if you accept a slightly different tree on every run.

## Next

This is the last chapter in Sequences. Continue to [Importing FASTQ](../03-reads/01-importing-fastq.md), the first chapter of Reads, for work that starts from raw sequencing data.

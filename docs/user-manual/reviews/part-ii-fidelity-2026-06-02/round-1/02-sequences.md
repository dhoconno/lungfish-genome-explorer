# Round 1 focus group + synthesis: 02-sequences (Sequences)

Round 1 focus-group review + synthesis. Personas cross-checked against the ground-truth reality map.

**Section:** Part II, Sequences (four chapters: importing/viewing, downloading from NCBI, extracting/comparing, MSAs and trees).
**Audience tiers declared:** bench-scientist (chapters 01, 02, 03), analyst (chapter 04).
**Method:** Four named biologist personas spanning the section's audience range read the four chapters cold and reacted, quoting specific lines. Each persona attempted the documented steps, so fidelity breaks (missing menu items, rejected CLI flags, absent dialog fields) surface as lived friction, not abstract notes. Reactions are then synthesized into a prioritized revision plan. Every fidelity claim is tied back to a finding in `ground-truth/02-sequences.md`.

---

# PART 1: PERSONA REACTIONS

## Persona A: Nadia Okonkwo, first-year virology grad student (novice, bench-scientist tier)

**Background.** Wet-lab molecular biologist, three months into a SARS-CoV-2 surveillance rotation. Comfortable with pipettes and Geneious-style point-and-click, has never opened a terminal on purpose. Reads chapters 01 to 03 as her on-ramp; skips most of 04 as "too advanced for now" but skims it.

**First reaction (chapter 01).** "This is the friendliest part of the whole manual. The opening explains a reference bundle as 'a folder with the `.lungfishref` extension that the Finder shows as a single icon' and that 'Your original file stays where it was.' That second sentence is exactly the reassurance I needed. I was afraid importing would move or eat my Desktop file."

**Where she got stuck (fidelity).**

- She tried the menu the chapter told her to use. "Step 2 says 'From the menu bar, choose **File > Import Center**.' I looked under File and the actual item reads `Import Center…` with the three dots, and it also lists a shortcut. The chapter never tells me the shortcut exists, and the name looked slightly different so I second-guessed whether I was in the right place." (Ground truth, ch01 finding 3: the real item is "Import Center…" with Cmd-Shift-I; the doc omits both the ellipsis and the shortcut.) "For a beginner, a shortcut like Cmd-Shift-I is a gift. Please put it in."

- The GFF3 row in the formats table confused her badly. "The table says GFF3 'Must be paired with a matching FASTA in the same import.' So I dragged a FASTA and a GFF3 in together and it did not do what I expected. Later I found out annotations actually attach to an *existing* bundle as a separate step. The table told me to do something the app does not support." (Ground truth, ch01 finding 2: there is no combined FASTA+GFF3 import; GFF3/GTF/BED is a separate "Annotation Track" importer that attaches to an existing reference bundle.) "This is the kind of thing that makes a beginner think they broke the software."

- She does not use the CLI, so `lungfish import path/to/MN908947.3.gb` did not bite her directly, but she noticed: "If I ever did try the terminal line in the box, my labmate says it would error because it needs to be `lungfish import fasta`. Good to know the GUI is the safe path for me." (Ground truth, ch01 finding 1: `lungfish import` has no default subcommand; the runnable form is `lungfish import fasta`.)

**Accessibility friction.**

- "Chapter 01 uses 'contig' and immediately defines it inline: 'a single contig (one continuous stretch of sequence).' That worked. But chapter 03 opens with 'scan a contig for every open reading frame above 100 codons' and assumes I already know what an ORF and a codon are. I half-know, but a one-line gloss the first time 'ORF' appears would help. The chapter is tagged bench-scientist, so it should not assume I can read 'open reading frame' as obvious."

- "The viewport section says the annotation track draws features 'as Creamsicle-coloured blocks.' I had to go look up what colour Creamsicle is. Most beginners will not know the brand palette. 'Orange blocks' would just work." (Note: this is a house-color reference; it reads as jargon to a first-time user.)

- "The 'Go to Location' instructions say a range like `21563-25384` zooms to fit. When I typed `21563-25384` into the bar at the top of the viewport, I was not sure if I needed a chromosome name in front. The example does not show whether bare numbers are enough." (Ground truth, ch01 finding 5 / NEEDS-HUMAN-CHECK: the ruler field placeholder is `chr:start-end`, so the bare-range syntax is unverified.)

**What she would lift into her SOP.** The "When import fails" section. "The two failure cases, missing `>` and 'a file that looks like a FASTA but was saved from a word processor such as Microsoft Word,' are exactly the mistakes I have already made once. I am pasting that whole section into my lab notebook." The plain-FASTA example block with the `>MN908947.3` header is also going in her notes as a reference for "what a valid file looks like."

---

## Persona B: Marcus Bell, research associate running surveillance pipelines (intermediate, bench-scientist / analyst tier)

**Background.** Two years in a public-health-adjacent lab. Runs other people's Snakemake pipelines, fetches references from NCBI weekly, does light command-line work but copies most commands from internal wikis. Lives in chapters 02 and 03.

**First reaction (chapter 02).** "The conceptual framing is strong. The line 'some callers (iVar in particular) need annotations to translate nucleotide changes into amino-acid changes; without bundled annotations, the AA columns in your VCF will be empty' is the single best justification for choosing GenBank I have read anywhere. I finally understand *why* my AA columns kept coming up blank."

**Where he got stuck (fidelity). This chapter broke for him repeatedly.**

- The whole GUI procedure does not match the app. "Step 1 says 'Choose `Tools > Search Online Databases > Search NCBI`. The database search dialog opens.' Fine. Then step 2: 'In the **Accession** field, type or paste the accession.' Step 3: 'From the **Format** menu, choose `GenBank`.' Step 4: 'Click `Run`.' I opened the dialog and there is no Format menu with FASTA/GenBank/GFF3/XML, and there is no `Run` button. What I actually see is a search box, a Mode picker, two checkboxes, and a button that says Download Selected after I pick a result." (Ground truth, ch02 findings 1, 2: the GUI has a "Mode" picker with Nucleotide/Genome/Virus plus "RefSeq Only" and "Include GFF3 Annotations" checkboxes, no four-way Format menu; the primary button is "Search" then "Download Selected", never "Run". The four-format choice is CLI-only via `--fetch-format`.) "Steps 2 through 4 are fiction for the GUI. I had to reverse-engineer the real flow: search, select a record, Download Selected."

- The download/import two-step is wrong for the GUI too. "Step 5 says 'When the row turns green, the file is on disk. Import that GenBank file as a reference bundle.' But the GUI never made me import anything. The download produced a `.lungfishref` bundle directly. The worked example even lists both `Downloads/MN908947.3.gb` *and* a separate `Reference Sequences/MN908947.3.lungfishref` as if I did two operations. I only did one." (Ground truth, ch02 finding 4: nucleotide and virus downloads "always end as .lungfishref bundles"; the two-step model is literally true only for the CLI.)

- The assembly-accession claim is backwards. "Line 49 says 'If you paste an assembly accession into the NCBI dialog covered here, the dialog will refuse it.' I pasted `GCF_009858895.2` to test the warning and it did NOT refuse it. The dialog has a Genome mode that handles assemblies as a first-class thing." (Ground truth, ch02 finding 5: the GenBank pane supports a "Genome" mode; assembly accessions are not refused, the claim is inverted.) "A doc that tells me the app will stop me, when the app happily proceeds, is worse than saying nothing."

- The menu/tab naming tripped him. "The chapter keeps calling it the 'Search NCBI' dialog and refers to a 'Pathoplexus tab.' In the app the menu items are `Search NCBI...`, `Search SRA...`, `Search Pathoplexus...`, and inside the one dialog the tabs are titled 'GenBank & Genomes', 'SRA Runs', and 'Pathoplexus'. So 'Search NCBI' actually drops me onto a tab called 'GenBank & Genomes'. The names not matching made me think I had the wrong window." (Ground truth, ch02 finding 3.)

**Where the CLI saved him (fidelity, positive).** "Interestingly the CLI block in the worked example is the part I trust. `lungfish fetch ncbi MN908947.3 --fetch-format genbank --save-to ./Downloads/MN908947.3.gb` followed by `lungfish import fasta ... --output-dir . --name ...` reads correct and the ground truth agrees it matches the code. So the irony is the 'advanced' CLI section is more accurate than the 'beginner' GUI clickthrough." (Ground truth, ch02 finding 6: the CLI block is accurate.)

**Chapter 03 friction.**

- "The Extract procedure step 4 says 'name the new bundle and confirm the start and end coordinates. Click `Extract`.' When I opened the real dialog, titled 'Extract Sequence', there were no start/end fields to confirm. Just a Destination radio group and a Name field. The coordinates are whatever was visible before I opened it. I spent a minute hunting for coordinate boxes that are not there." (Ground truth, ch03 finding 1: the sheet is "Extract Sequence" with only Destination and Name; no coordinate fields; coordinates come from the visible region.)

**Accessibility friction.**

- "Chapter 02 is dense for a bench-scientist tier. The provenance section throws 'INSDC', 'SHA-256 checksum', 'eutils.ncbi.nlm.nih.gov', and 'exponential backoff' at me in two paragraphs. I can follow it, but a true bench scientist would drown. At minimum gloss 'checksum' once as 'a fingerprint of the file's exact bytes'."
- "The 'Next' link at the bottom of chapter 02 jumps to 'MSAs and Trees (04)' and skips chapter 03 entirely. That is a confusing reading order. I would expect Next to go to the chapter that is literally next."

**What he would lift.** The provenance sidecar use cases. "'if a colleague hands you a FASTA and you want to know where it came from, the sidecar answers that question' and the checksum-mismatch-flags-a-changed-upstream point. That is going straight into our team's data-handling SOP." Also the format-choice table, "once the GUI procedure is fixed."

---

## Persona C: Dr. Priya Raghavan, postdoc fluent in command-line genomics (advanced, analyst tier)

**Background.** Computational postdoc, builds her own MAFFT/IQ-TREE pipelines from the shell, reads methods sections for reproducibility. Goes straight to chapter 04 and the CLI blocks throughout. Treats the GUI as optional.

**First reaction (chapter 04).** "Good conceptual writing. The MSA-as-rectangular-block framing and the 'conservation at any column is a column-wise count of how many rows agree' definition are crisp. The MAFFT-vs-MUSCLE-vs-Clustal table is a sensible orientation. I would happily hand chapter 04's first two sections to a rotation student."

**Where it broke for her (fidelity). The tree workflow is the worst offender in the section.**

- `Tools > Infer Tree` does not exist. "The chapter says, three times, to use `Tools > Infer Tree`: in the frontmatter, in 'What it is' ('`Tools > Infer Tree` runs IQ-TREE'), and in the procedure ('With the MSA bundle still open, run `Tools > Infer Tree`. The tree wizard opens'). There is no such menu item. I opened the Tools menu and it is not there. The real entry point is a right-click *inside the MSA viewport* called 'Build Tree with IQ-TREE…', which opens a dialog titled 'Phylogenetic Tree Operations'. A reader following this chapter literally cannot start a tree." (Ground truth, ch04 finding 1, flagged as "the single most consequential error in the chapter.") "This is a hard stop. Everything after it in the procedure is unreachable by the documented path."

- The CLI frontmatter conflates two different commands. "Frontmatter says 'CLI: lungfish msa, lungfish tree'. But `lungfish msa` does not build an alignment, it is a transform/inspect command. Building an MSA from FASTA is `lungfish align mafft <inputs> --project <dir>`. I tried `lungfish msa` expecting to align and got a subcommand list." (Ground truth, ch04 finding 4: the builder is `lungfish align mafft`; `lungfish msa` is transform/inspect only.)

- There is no CLI tree-inference example at all, and the one implied form is incomplete. "The chapter documents `tree reroot`, `tree relabel`, and `tree extract-subtree` CLI blocks, but never shows how to *infer* a tree from the shell, even though the frontmatter advertises 'lungfish tree'. When I derived it myself, `lungfish tree infer iqtree` requires `--project <dir>` and `--output`, which no example mentions." (Ground truth, ch04 finding 5: `tree infer iqtree` requires `--project`; the chapter gives no inference CLI example, an omission given it documents the other tree subcommands.)

- The MSA wizard control names are wrong. "Step 4: 'Leave `Aligner` set to MAFFT and `Mode` set to Auto.' Troubleshooting: 'switch the wizard's `Mode` from Auto to `L-INS-i`.' There is no 'Aligner' dropdown and no 'Mode' control. The picker is labeled 'Strategy', and that is where Auto and L-INS-i live. MAFFT is the only aligner, so there is nothing to select." (Ground truth, ch04 finding 2: pickers are "Strategy", "Sequence Type", "Output Order"; no "Aligner" or "Mode".)

- MUSCLE/Clustal selectability is a promise the app does not keep. "The chapter says to 'install the plugin pack that provides them and select the tool in the MSA wizard's `Aligner` dropdown.' There is no aligner dropdown and MAFFT is the only wired tool. So the comparison table sets up a choice the UI cannot deliver." (Ground truth, ch04 finding 3.)

- Bootstrap default is misrepresented. "Step 3 says 'Set `Bootstrap replicates` to `1000` for ultrafast bootstrap support values,' phrased as confirming a pre-filled default. In the real dialog bootstrap is OFF by default; the 1000 only takes effect after you tick the 'Ultrafast Bootstrap' checkbox. I ran it as written, did not tick the box, and got a tree with no support values. Then the Interpretation section tells me to read 'support values' that are not there." (Ground truth, ch04 finding 6: `bootstrapEnabled` defaults to false; the chapter's later reliance on support values assumes bootstrap was enabled.) "That is a silent failure, the most dangerous kind."

- Dialog field labels are off. "'Leave `Method` set to IQ-TREE and `Substitution model` set to `MFP`.' There is no 'Method' field, IQ-TREE is the only method. The model field is labeled 'Model', not 'Substitution model'. And there is no 'Outgroup' dropdown in the inference dialog at all; rooting on an outgroup is a separate post-inference `tree reroot` step." (Ground truth, ch04 findings 7, 8.)

- The cross-reference to reorient is mis-pathed and mis-scoped. "Troubleshooting says 'reorient them with `Tools > Orient` against a shared reference before aligning.' There is no `Tools > Orient`. Orientation is 'Orient Reads', a FASTQ operation under `Tools > FASTQ/FASTA Operations`, and it is scoped to *reads*, not the reference FASTA records I am about to align." (Ground truth, ch04 finding 11.)

**What she found accurate (and was relieved by).** "The post-inference CLI blocks are solid. `tree reroot --bundle --on --output`, `tree relabel --bundle --column --output`, and `tree extract-subtree --bundle --node --output` all match what I ran, including `--node node-12` as a normalized id. The `metadata.tsv` relabel format with the `id/sample/sample_id/name/tip` id column worked. So the chapter is accurate the moment it stops describing the GUI and the inference entry point." (Ground truth, ch04 finding 9: these match code.)

**Coverage gaps she immediately noticed.** "As a CLI user I expected the `lungfish msa` transform family, consensus, distance matrix, mask, trim, multi-format export, and `lungfish import msa` / `lungfish import tree` for bringing in a pre-built alignment or Newick. None of it is here. The chapter assumes I always build in-app, but half my trees come from external pipelines I want to import." (Ground truth, ch04 missing-features 1, 2, 5.)

**Accessibility note.** "For an analyst-tier chapter this is mostly well pitched. One nit: 'MFP (ModelFinder Plus)' is stated as if ModelFinder behavior is obvious. One clause, 'ModelFinder Plus tests substitution models and picks the best-fitting one before inferring the tree,' would close it for an analyst who knows trees but not IQ-TREE specifically."

**What she would lift.** The "What this chapter does not cover" list (ancestral states, time-calibrated trees, recombination, coalescent, phylogeography) "is an honest scope fence I respect, and I would cite it when colleagues ask whether Lungfish does BEAST-style dating." And the MAFFT troubleshooting on mixed-orientation inputs, "minus the broken `Tools > Orient` path."

---

## Persona D: Dr. James Whitfield, sequencing core-facility lead and pipeline developer (domain power-user, power-user-adjacent)

**Background.** Runs a genomics core, evaluates tools for institutional adoption, writes wrapper scripts, validates reproducibility for clinical-adjacent work. Reads all four chapters as an adoption due-diligence pass, with a hard eye on CLI parity, provenance, and batch capability. Notes that none of these chapters is tagged `power-user`, but he is the reader who will script against them.

**First reaction.** "The provenance story is the reason I would pilot this. Chapter 02's sidecar description (resolved endpoint, checksum, retry count, `apiKeyProvided` boolean that 'never writes the key itself') and chapter 03's extract-provenance ('source bundle path, the extracted range, and the Lungfish version') are exactly what I need for an auditable pipeline. This is more provenance discipline than most tools in this space."

**Fidelity issues that would block his adoption write-up.**

- Every GUI fidelity break the other personas hit, he logs as a documentation-reliability risk. "If I hand chapter 02's GUI steps to a new hire, steps 2 to 5 fail. If I hand chapter 04's tree procedure to anyone, `Tools > Infer Tree` does not exist. A manual that cannot be followed verbatim fails my evaluation regardless of how good the underlying app is. The CLI blocks are the saving grace because those are accurate."

- He immediately probes CLI surface and finds the docs undersell the tool. "The docs treat `fetch ncbi` as single-accession, but the command accepts MULTIPLE accessions in one call and a `--db nucleotide|protein` flag, plus an `--api-key` flag in addition to the env var. For a core that batch-fetches references, multi-accession fetch is the headline feature, and it is invisible in the manual." (Ground truth, ch02 missing-features 3, 4.) "There is also a `lungfish fetch search` subcommand and `lungfish fetch ena {search,reads,fasta}` that the chapter never mentions, and a GUI 'import accession LIST from a CSV' batch path. For my use case those are the most important capabilities in the chapter, and they are absent." (Ground truth, ch02 missing-features 1, 2, 6.)

- Extract/compare CLI parity is entirely missing. "Chapter 03 is GUI-only. But `lungfish extract sequence` exists with `--flank`, `--flank-5`, `--flank-3`, `--reverse-complement`, and `--line-width`, and it can emit either a plain FASTA or a `.lungfishref` depending on output extension. Extracting a region with flanks is a daily bench need for primer design, and there is no CLI path documented for it. Same for the standalone `lungfish translate` (with `--frame`, `--table`, `--trim-to-stop`, `--longest-orf`) and `lungfish sequence delete-annotations` / `delete-annotation-track`." (Ground truth, ch03 missing-features 1, 2, 3, 5.) "The chapter even says the ORF track 'persists with the bundle until you remove it' and never tells me how to remove it. The CLI command to do that exists; cite it."

- The MSA transform surface is a major omission. "The entire `lungfish msa` family, consensus, distance matrix, extract, mask columns, trim, annotate, and multi-format export (phylip, nexus, clustal, stockholm, a2m, a3m), is undocumented. `lungfish msa distance` writing an identity or p-distance TSV matrix is something my analysts ask for constantly. The chapter mentions exporting only 'the MSA FASTA' and a Newick. There is a `lungfish convert` command relevant to import/extract too." (Ground truth, ch04 missing-features 1, 2; section-wide 1, 3.)

- Subset-to-tree is undocumented despite being a real workflow. "Tree inference can be scoped with `--rows`/`--columns`, which mirrors the MSA viewport's select-then-build flow. For anyone trimming an alignment to informative columns before inferring, this is essential and unmentioned." (Ground truth, ch04 missing-features 6.)

**Reproducibility / batch verdict.** "The section reads as single-bundle, interactive. My world is 96-sample batches and scripted reference setup. The accurate CLI exists for most of this (multi-accession fetch, extract with flanks, msa transforms), but the manual hides it behind GUI procedures that do not even work. The fix is not to invent features; it is to surface the CLI that already ships. The ground truth confirms these commands are real."

**Accessibility note (his lens is the analyst/power-user split).** "Chapters 01 to 03 are tagged bench-scientist and chapter 04 analyst, but chapter 04's CLI blocks and chapter 02's provenance internals are power-user material. Either the tiers are mislabeled or there should be a clearly fenced 'Power-user CLI' subsection at the end of each chapter so a bench scientist can skip it and I can jump straight to it."

**What he would lift.** "The 'What these operations are not' section in chapter 03 (single-sequence tools do not align, do not call variants, do not build trees, with the explicit 'extract the same region from each bundle, gather into an MSA' recipe) is the clearest scope statement in the section. I would adopt that framing in our own internal docs. And the entire provenance-sidecar concept, assuming the field lists are verified against a real produced file."

---

# PART 2: SYNTHESIS AND REVISION PLAN

Four personas spanning novice to power-user converged on one dominant theme: **the GUI procedures are substantially fictional while the CLI blocks are largely accurate.** A reader who follows the click-throughs in chapters 02 and 04 cannot complete the task as written. The CLI is both more correct and, paradoxically, under-documented. This plan fixes fidelity first, then surfaces real-but-hidden features, then addresses accessibility.

## Critical fidelity fixes (the app does not work as written)

These are described-but-nonexistent features, wrong menu paths, wrong CLI commands/flags/defaults, and wrong tool names. Top priority. Ordered by reader impact.

1. **Remove `Tools > Infer Tree` everywhere; it does not exist.** (Ground truth ch04 finding 1, the section's most consequential error.) Replace all three occurrences (frontmatter `entry_points`, "What it is", and the "Procedure: infer a tree" opener) with: tree inference is launched by right-clicking inside the open MSA viewport and choosing **"Build Tree with IQ-TREE…"**, which opens the dialog titled **"Phylogenetic Tree Operations"** (subtitle "Configure IQ-TREE for the selected multiple sequence alignment"). The procedure step "With the MSA bundle still open, run `Tools > Infer Tree`. The tree wizard opens" becomes "With the MSA bundle open in the MSA viewport, right-click and choose **Build Tree with IQ-TREE…**. The Phylogenetic Tree Operations dialog opens, pre-populated with the current MSA bundle."

2. **Fix the entire NCBI GUI procedure (chapter 02, steps 1 to 5 and the worked example).** (Ground truth ch02 findings 1, 2, 4.) The real flow is search-then-download, not accession+format+Run:
   - There is no "Format" menu with FASTA/GenBank/GFF3/XML in the GUI. The four-format choice is CLI-only (`--fetch-format`). The GUI offers a **"Mode"** picker (Nucleotide / Genome / Virus) plus two checkboxes, **"RefSeq Only"** and **"Include GFF3 Annotations"**.
   - The primary button is **"Search"**, and after a record is selected it becomes **"Download Selected"**. It is never labeled "Run".
   - The download produces a `.lungfishref` bundle directly. Delete the separate "Import that GenBank file as a reference bundle" step from the GUI procedure; that two-step model is true only for the CLI. The worked-example sidebar listing should not imply both a loose `.gb` and a separate manual import for the GUI path.
   - Rewrite steps as: (1) `Tools > Search Online Databases > Search NCBI` opens the dialog on its "GenBank & Genomes" tab. (2) Type the accession in the search field, set Mode to Nucleotide, tick "Include GFF3 Annotations" if you want them. (3) Click Search. (4) Select the record in the results. (5) Click Download Selected; Lungfish builds the `.lungfishref` bundle in one action.

3. **Fix the menu/tab names in chapter 02.** (Ground truth ch02 finding 3.) The menu items are `Search NCBI...`, `Search SRA...`, `Search Pathoplexus...`. They all open one dialog whose tabs are titled **"GenBank & Genomes"**, **"SRA Runs"**, and **"Pathoplexus"**. State explicitly that `Search NCBI` lands on the "GenBank & Genomes" tab, not a tab named "Search NCBI". Replace "Pathoplexus tab" references accordingly (the tab title is "Pathoplexus", reached via the `Search Pathoplexus...` menu item).

4. **Reverse the assembly-accession claim in chapter 02.** (Ground truth ch02 finding 5.) Delete line 49's "If you paste an assembly accession into the NCBI dialog covered here, the dialog will refuse it." The dialog has a first-class **"Genome" mode** that handles assembly accessions. Replace with: "Assembly accessions (`GCF_`/`GCA_`) are handled by the dialog's Genome mode, or from the CLI via `lungfish fetch genome` (see the Genomes chapter)." Do not tell the reader the app will block them when it does not.

5. **Fix the MSA wizard control names in chapter 04.** (Ground truth ch04 finding 2.) There is no "Aligner" dropdown and no "Mode" control. The pickers are **"Strategy"**, **"Sequence Type"**, and **"Output Order"**. Rewrites: "Leave `Aligner` set to MAFFT and `Mode` set to Auto" becomes "Leave **Strategy** on **Auto** (MAFFT is the only aligner)." In troubleshooting, "switch the wizard's `Mode` from Auto to `L-INS-i`" becomes "switch **Strategy** from Auto to **L-INS-i**."

6. **Drop the MUSCLE/Clustal Omega "select in the Aligner dropdown" instruction (chapter 04).** (Ground truth ch04 finding 3.) MAFFT is the only wired aligner in GUI and CLI; there is no aligner-selection affordance. Either remove the "install the plugin pack ... and select the tool in the MSA wizard's `Aligner` dropdown" sentence, or reframe the comparison table as background ("Lungfish ships MAFFT; MUSCLE and Clustal Omega are listed for context") with no false UI promise.

7. **Fix the IQ-TREE bootstrap default (chapter 04).** (Ground truth ch04 finding 6.) Bootstrap is OFF by default; the 1000 value only applies after the **"Ultrafast Bootstrap"** checkbox is ticked. Rewrite step 3 to: "Tick **Ultrafast Bootstrap** to enable support values, then set replicates to 1000. If you skip this, IQ-TREE runs without bootstrap and the tree will have no support values to read in the next section." This prevents the silent failure where the Interpretation section asks readers to read support values that were never computed.

8. **Fix the IQ-TREE dialog field labels (chapter 04).** (Ground truth ch04 findings 7, 8.) There is no "Method" field (IQ-TREE is the only method). The model field is labeled **"Model"**, not "Substitution model"; its default is "MFP". There is **no "Outgroup" dropdown** in the inference dialog. Rewrites: drop "Leave `Method` set to IQ-TREE"; change "`Substitution model` set to `MFP`" to "leave **Model** on **MFP**"; replace step 4's "Optionally set an outgroup tip from the dropdown" with a note that outgroup rooting is a separate post-inference step (right-click "Re-root Here" in the tree viewport, or `lungfish tree reroot`).

9. **Fix the `lungfish import` CLI command across chapters 01 and 02.** (Ground truth ch01 finding 1; ch02 finding 6 confirms the corrected form.) `lungfish import` has no default subcommand. Change `lungfish import path/to/MN908947.3.gb` to `lungfish import fasta path/to/MN908947.3.gb`. Update chapter 01 frontmatter `entry_points` "CLI: lungfish import" to "CLI: lungfish import fasta". (Chapter 02's CLI block already uses the correct `lungfish import fasta`; keep it.)

10. **Fix the CLI frontmatter and add a tree-inference CLI example (chapter 04).** (Ground truth ch04 findings 4, 5.) Frontmatter "CLI: lungfish msa, lungfish tree" is wrong: building an MSA is `lungfish align mafft <inputs> --project <dir>`, and `lungfish msa` is a transform/inspect command that cannot align unaligned FASTA. Change frontmatter to "CLI: lungfish align mafft, lungfish tree infer iqtree". Add an inference CLI block to the "infer a tree" procedure, including the required `--project` and `--output`, for example: `lungfish tree infer iqtree S-gene-10-isolates.lungfishmsa --project . --output S-gene-10-isolates.lungfishtree --model MFP`. The chapter currently documents reroot/relabel/extract-subtree CLI but omits inference, which is the one readers most need.

11. **Fix the `Tools > Orient` cross-reference (chapter 04 troubleshooting).** (Ground truth ch04 finding 11.) There is no `Tools > Orient`. Orientation is **"Orient Reads"** under `Tools > FASTQ/FASTA Operations`, and it is scoped to FASTQ reads, not reference FASTA records destined for an MSA. Reword to point at the correct item and flag the scope caveat, or replace with the accurate remedy for mis-oriented FASTA inputs (the `lungfish align mafft --adjust-direction` option, per ground-truth ch04 missing-feature 3).

12. **Fix the GFF3 "must be paired with a matching FASTA in the same import" claim (chapter 01).** (Ground truth ch01 finding 2.) No combined FASTA+GFF3 import exists. GFF3/GTF/BED is a separate Import Center importer ("Annotation Track") that attaches to an **existing** reference bundle. Rewrite the table Notes cell and the "Accepted formats" prose: import the FASTA first to create the bundle, then attach the GFF3/GTF/BED as an annotation track to that bundle. Remove "in the same import".

13. **Fix the Extract dialog description (chapter 03).** (Ground truth ch03 finding 1.) The sheet is titled **"Extract Sequence"** and contains only a **Destination** radio group and a **Name** field. There are no start/end coordinate fields to "confirm"; coordinates come from the visible region set before opening the dialog. Rewrite step 4 ("name the new bundle and confirm the start and end coordinates") to "set the destination and name the new bundle" and note that the extracted range is the currently visible region. Correct the title from "Extract Visible Region" to "Extract Sequence" where the dialog itself is referenced.

14. **Correct minor menu-title and label mismatches (chapters 01, 03).**
   - Chapter 01: "File > Import Center" should read "Import Center…" and state the Cmd-Shift-I shortcut (ground truth ch01 finding 3).
   - Chapter 03: the operations table should reflect the real titles with ellipses, "Reverse Complement…" (Cmd-Shift-R) and "Translate…" (Cmd-Shift-T), and the Find ORFs dialog field names: "Minimum ORF length" (not "minimum nucleotide length"), and "Output" is two fields, **"Track name"** and **"Track ID"** (not a single "output track"). (Ground truth ch03 findings 3, 4.) These are accurate-enough that a reader can muddle through, but exact labels prevent the "am I in the right dialog" friction Persona A and B reported.

## Coverage gaps (real app features missing from the docs)

Features the ground truth confirms exist but the chapters omit. Personas C and D wanted most of these; they are real CLI surface, not invention. Recommendation: surface them, mostly as fenced "From the command line" subsections so bench-tier readers can skip them.

1. **Multi-accession and search fetch (chapter 02).** `lungfish fetch ncbi` accepts multiple accessions in one call plus `--db nucleotide|protein` and `--api-key`; `lungfish fetch search` lists matching accessions; `lungfish fetch ena {search,reads,fasta}` is a direct ENA path; the GUI can import an accession LIST from a CSV for batch download. (Ground truth ch02 missing-features 1, 2, 3, 4, 6.) Add a short "Batch and search fetching" subsection to chapter 02; Persona D rated multi-accession fetch the chapter's headline capability.

2. **`lungfish msa` transform/inspect family (chapter 04).** consensus, distance (identity/p-distance TSV matrix), extract, mask columns, trim, annotate, and multi-format export (fasta, aligned-fasta, phylip, nexus, clustal, stockholm, a2m, a3m). (Ground truth ch04 missing-features 1, 2; section-wide 1.) Add a "Working with an alignment after you build it" subsection. At minimum document `msa consensus` and `msa distance`, the two Persona C and D named.

3. **Importing pre-built alignments and trees (chapter 04).** `lungfish import msa` and `lungfish import tree` import existing MSA/Newick/Nexus files as native bundles. (Ground truth ch04 missing-feature 5; section-wide 2.) The chapter assumes everything is built in-app; add a note that external alignments and trees can be imported as bundles.

4. **CLI parity for the Sequence menu (chapter 03).** `lungfish extract sequence` (with `--flank`, `--flank-5`, `--flank-3`, `--reverse-complement`, `--line-width`; outputs FASTA or `.lungfishref` by extension), `lungfish translate` (with `--frame`, `--table`, `--trim-to-stop`, `--no-stop-asterisk`, `--longest-orf`), and `lungfish sequence {annotate-orfs, delete-annotations, delete-annotation-track}`. (Ground truth ch03 missing-features 1, 2, 3, 5; section-wide 5.) Add a "From the command line" subsection. Critically, the chapter says the ORF track "persists ... until you remove it" but never says how: cite `sequence delete-annotation-track`.

5. **Subset-to-tree (`--rows`/`--columns`) (chapter 04).** Tree inference can be scoped to a row/column subset, mirroring the MSA viewport's select-then-build flow. (Ground truth ch04 missing-feature 6.) Add one sentence in the infer-a-tree procedure: you can select rows/columns in the MSA viewport (or pass `--rows`/`--columns`) to build a tree from a subset.

6. **`Sequence > Add Annotation…` (chapter 01 or 03).** A real menu item the chapters never list. (Ground truth ch01 missing-feature 1.) Add it to chapter 03's operations inventory, since that chapter enumerates the Sequence menu.

7. **Wider import format/compression support (chapter 01).** `lungfish import fasta` also accepts `.embl`, `.gbff`, and `.bgz/.bz2/.xz/.zst` compression beyond the table's listed formats; GenBank import names the materialized track `imported_annotations`. (Ground truth ch01 missing-features 2, 3.) Add the extra formats to the table's compressed-FASTA/GenBank rows, and name the `imported_annotations` track, since chapter 02 relies on it.

8. **`lungfish convert` (chapters 01, 03).** FASTA/GenBank/GFF3/FASTQ interconversion with `--include-annotations`. (Ground truth section-wide 3.) Worth a one-line mention where formats are discussed; lower priority than the above.

## Accessibility fixes

Per audience tier. Chapters 01 to 03 are `bench-scientist`; chapter 04 is `analyst`.

1. **Gloss biology vocabulary at first use (chapter 03, bench-scientist).** "ORF" / "open reading frame" and "codon" appear in the opening sentence ("scan a contig for every open reading frame above 100 codons") with no inline gloss. Persona A (novice) flagged this. Add a one-line gloss at first use, consistent with the foundations rule "no vocabulary load-bearing without inline gloss."

2. **Replace or gloss brand-color names in reader-facing prose (chapter 01).** "Creamsicle-coloured blocks" reads as jargon to a first-time user (Persona A). In prose that tells a reader what they will see on screen, say "orange" (or "the accent orange") rather than the internal palette name. The STYLE palette governs SVG fills and design, not what a novice is told to look for.

3. **Soften the provenance/networking density in chapter 02 for the bench tier.** "INSDC", "SHA-256 checksum", "eutils.ncbi.nlm.nih.gov", "exponential backoff" arrive fast (Persona B). Gloss "checksum" once ("a fingerprint of the file's exact bytes") and consider moving the deepest provenance internals into a fenced subsection so the core download task stays bench-accessible.

4. **Gloss "MFP / ModelFinder Plus" in chapter 04 (analyst).** Persona C wanted one clause: ModelFinder Plus tests candidate substitution models and picks the best-fitting one before inferring the tree. Analysts know trees; not all know IQ-TREE's model selector by name.

5. **Fix the reading-order / "Next" links.** Chapter 02's "Next" jumps to chapter 04 (MSAs and Trees) and skips chapter 03 (Persona B). Either point Next at chapter 03, or add a one-line signpost explaining the intentional skip. Chapter 01's Next correctly goes to 02; keep that.

6. **Signpost the bench-vs-CLI split (Persona D, tier coherence).** Chapters 01 to 03 are bench-scientist but carry CLI blocks and (in 02) power-user provenance internals. Fence CLI/power-user content under a clearly labeled subsection per chapter so a bench scientist can skip it and a power user can jump to it. This also makes the coverage-gap additions above land cleanly without raising the apparent tier of the whole chapter.

7. **Confirm and, if needed, document the coordinate-field syntax (chapters 01, 03).** Persona A and the ground truth both flag uncertainty over whether the ruler position field accepts a bare `21563-25384` or expects a `chr:` prefix (placeholder is `chr:start-end`). This is a NEEDS-HUMAN-CHECK item; once verified at runtime, state the accepted syntax explicitly, since multiple worked examples depend on typing a bare range.

## What to keep

Strengths every persona praised; they must survive revision.

1. **The reference-bundle framing in chapter 01.** "a folder with the `.lungfishref` extension that the Finder shows as a single icon" and "Your original file stays where it was" reassured the novice immediately. Keep verbatim.

2. **The "When import fails" section (chapter 01).** The missing-`>` and Microsoft-Word-formatting-characters failure modes, plus the valid-FASTA example block, were the single most SOP-worthy passage for the novice. Keep, including the example.

3. **The "why GenBank" justification in chapter 02.** "without bundled annotations, the AA columns in your VCF will be empty" was the clearest motivation in the section for the intermediate reader. Keep.

4. **The provenance-sidecar use cases (chapters 02 and 03).** The "where did this FASTA come from" and "checksum mismatch flags a changed upstream record" framings, and the extract sidecar recording source path + range + version, are the standout adoption argument for the power-user. Keep (and verify the exact field lists against a produced file per the NEEDS-HUMAN-CHECK notes).

5. **The "What these operations are not" section (chapter 03).** The explicit single-sequence scope fence, with the concrete "extract the same region from each bundle, gather into an MSA" recipe, was praised by the power-user as the clearest scope statement in the section and a model for the rest of the manual. Keep.

6. **The "What this chapter does not cover" list (chapter 04).** The honest out-of-scope fence (ancestral states, time-calibrated trees, recombination, coalescent, phylogeography) earned the advanced reader's trust. Keep.

7. **The accurate post-inference tree CLI blocks (chapter 04).** `tree reroot`, `tree relabel`, `tree extract-subtree`, and the `metadata.tsv` relabel format all match code and were the one part Persona C trusted on sight. Keep exactly as written.

8. **The MSA conceptual opening and conservation definition (chapter 04).** "conservation at any column is a column-wise count of how many rows agree" and the MAFFT gap-insertion framing are clean teaching prose the analyst would hand to a rotation student. Keep.

---

## Cross-cutting theme for the editor

The defining pattern of this section is **inverted reliability**: the GUI click-throughs (the path bench scientists take) are the most broken, while the CLI blocks (the path power users take) are the most accurate. Chapter 04's tree workflow and chapter 02's NCBI procedure are unusable verbatim. The fix is overwhelmingly corrective, not generative: name the menu items and dialog fields that actually exist, remove the two that do not (`Tools > Infer Tree`, `Tools > Orient`), correct the bootstrap and assembly-accession defaults, and then surface the substantial, accurate CLI surface the chapters currently hide. Almost nothing here requires new app behavior; it requires the docs to describe the app that shipped.

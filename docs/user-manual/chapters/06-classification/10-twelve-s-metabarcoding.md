---
title: 12S Amplicon Metabarcoding
chapter_id: 06-classification/10-twelve-s-metabarcoding
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification, 03-reads/01-importing-fastq, 01-foundations/07-plugin-packs]
estimated_reading_min: 22
task: Build a 12S reference bundle, match a simulated human and macaque 12S amplicon mixture against it, read the species roster and its alternates against the known truth, review unresolved clusters, and export species rows.
tags: [classification, metabarcoding, twelve-s, amplicon, blast, export, simulated]
tools: [blast, vsearch]
parameters_refs: [classify.twelve-s-match]
entry_points:
  - "Tools > Workflows > Workflow Library…"
  - "Tools > Classification > 12S Amplicon Matching…"
  - "CLI: lungfish-cli fastq 12s-match"
shots:
  - id: twelve-s-workflow-library
    caption: "The Workflow Library window with the 12S Amplicon Matching card under Specialized Workflows and its Classification heading, showing its Specialized badge, its one-line description, its dependency row for the Third-Party Tools pack, and the Enabled switch."
  - id: twelve-s-dialog-inputs
    caption: "The Workflow Operations dialog on 12S Amplicon Matching, showing the Reference picker with its Create 12S Reference button, the Analysis Metadata picker with its Choose Metadata button, and the FASTQ Bundles list."
  - id: twelve-s-dialog-options
    caption: "The same dialog's Primary settings section with the Read Platform segmented picker, Result Name field, and Min Soft Clip field, above the Advanced settings section with its Advanced Options disclosure expanded to show Max Indels, Run vsearch chimera review, and the note about merged reads and unmerged pairs."
  - id: twelve-s-result-species-table
    caption: "The 12S viewport on its Targets view for the SIMULATED-12S-mixture-oriented reads, showing three rows, Homo sapiens with 1,235 exact reads and 68.0% of Sample, Macaca mulatta with 491 and 27.0% and Alternates 1, and Macaca fascicularis with 91 and 5.0%, under the Sample, Scientific Name, Common Names, Group, Tax ID, Exact Reads, % of Sample, Refs, and Alternates columns."
  - id: twelve-s-unresolved-clusters
    caption: "The viewport's Unresolved view, showing the Sequence, Reads, Samples, Chimera, and Bases columns for the clusters that matched no reference."
  - id: twelve-s-blast-review
    caption: "An unresolved cluster sent to NCBI with the Verify with BLAST button, with the returned hits in the BLAST Results drawer below the table."
  - id: twelve-s-export
    caption: "The viewport's Export menu offering Export as CSV, Export as TSV, and Export as Excel."
illustrations: []
glossary_refs: [amplicon, blast, bundle, checksum, chimera, deduplicated-reference, fastq, fragment, inspector, mate, metabarcoding, provenance, read, read-orientation, orient-reads, required-setup-pack, soft-clip, taxonomy-id, twelve-s, virtual-bundle, vsearch, workflow-library, relative-abundance, contamination, lowest-common-ancestor, kraken2, terminal, tsv, interleaved-fastq, negative-control, workflow-package, read-merging]
features_refs: [classify.twelve-s, workflow.library]
fixtures_refs: [primate-12s]
brand_reviewed: false
lead_approved: false
---

## What it is

[12S metabarcoding](../../GLOSSARY.md#metabarcoding) identifies which vertebrate species are present in a mixed sample. The [12S](../../GLOSSARY.md#twelve-s) ribosomal RNA gene sits in the mitochondrial genome, the small loop of DNA every animal cell carries outside its nucleus. Primers, short synthetic DNA pieces that mark where copying starts, bind sites that are the same across vertebrates and copy a short slice of the gene by PCR. That slice is an [amplicon](../../GLOSSARY.md#amplicon), a defined stretch of DNA amplified between two known primer sites. The primer sites are shared, but the bases between them differ from species to species, so reading the interior tells you which animal the DNA came from. Metabarcoding sequences that one marker across a whole mixed sample, so the answer is a roster of species rather than a single name.

Lungfish Genome Explorer (LGE) resolves a 12S run by exact matching. Each [read](../../GLOSSARY.md#read), the record a sequencer writes for one DNA [fragment](../../GLOSSARY.md#fragment), is checked against a [deduplicated reference](../../GLOSSARY.md#deduplicated-reference). That is a FASTA file, a plain-text list of named sequences, where each record is one known 12S sequence labeled with its species and identical sequences have been collapsed so each appears once.

The matching rule is one sentence. Each reference record is a target, a short stretch cut from inside the amplicon rather than the whole gene, such as the 60 bases this chapter's reference uses, so that a read can contain it whole. A target must appear inside the read as an unbroken run of identical bases, with at least one of the read's own bases left over at each end, and the read is then assigned to that target's species. A species missing from the reference can never be reported, however many reads it contributed, so the reads that match nothing are kept aside for you to review.

Every count is a count of fragments, the DNA molecules the library copied. A [merged read](../../GLOSSARY.md#read-merging) or a single read is one fragment, and so is an unmerged pair whose two [mates](../../GLOSSARY.md#mate), the reads from the two ends of one fragment, give the same call. This chapter's practice data holds single reads only, so here each fragment is one read, and the screen and this chapter both say reads.

In practice, build a reference that holds every animal you expect, orient the reads, and treat the species table as the answer and the unresolved clusters as the questions left over.

## Why you would do this

Run 12S matching when your sample is a mixture and the question is which vertebrates are in it. A gut-content sample, a water sample, a swab from a surface, or a pooled field collection all carry DNA from several animals at once. So can a primate facility's environmental swab, which may hold human DNA from the people who handle the animals beside rhesus and cynomolgus macaque DNA from the animals themselves.

A broad classifier such as [Kraken 2](../../GLOSSARY.md#kraken2) cannot answer this question, for the reason [What Is Read Classification](01-what-is-classification.md#the-tools) gives. Its Standard database holds no vertebrate but human, so a macaque read can probably reach only a human row or a wider group's row. A marker gene matched against a reference built for the animals you expect is the tool that fits. Exact matching adds a second benefit. When the evidence is thin, a broad classifier steps back to the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor), the narrowest group holding every candidate, and exact matching does not. A read either contains a known 12S sequence or it does not, so each species on the roster is one the reads name, except where two species share a sequence and the [abundance rule](#alternates-and-the-abundance-rule) gives the read to the species with more reads.

This chapter works through a SIMULATED mixture of human, rhesus macaque, and cynomolgus macaque 12S reads. Simulated means the reads were generated by a computer program from the three species' published mitochondrial genomes, copying each species' amplicon with random single-base changes at 0.2 percent per base, rather than sequenced from a real sample. No public 12S run we found holds human and macaque reads at proportions anyone knows, so a simulation is the only way to give you a mixture whose true answer is known to the read. The truth is 1,400 human reads, 500 rhesus reads, and 100 cynomolgus reads, 70, 25, and 5 percent of 2,000. A real library adds PCR bias, chimeras, and other kinds of sequencing error, such as inserted and deleted bases, that this one lacks, so treat it as a check of how the tool reads a mixture, not of how a real mixture behaves.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the 12S Metabarcoding demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds two read bundles, `SIMULATED-12S-mixture-oriented` and `HG002-12S-oriented`, and keeps the reference FASTA and its species table as files under `Practice Data/primate-12s`, where the procedure picks them. To import the files yourself instead, follow the rest of this section.

This chapter uses the primate 12S fixture. Download `primate-12s-dedup.fasta`, `primate-12s-midori.tsv`, `SIMULATED-12S-mixture-oriented.fastq.gz`, and `HG002-12S-oriented.fastq` from [the primate-12s fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/primate-12s), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The first file is the deduplicated reference, six primate 12S targets of 60 bases each, cut from public mitochondrial genomes. The second labels each reference sequence with its species. The third holds the simulated mixture, and the fourth holds real reads from HG002, a public reference human sample, picked from a whole-mitochondrion library because they cover the 12S region and used later as a single-species contrast. The fixture's README records how every file was made. Import the two read files into the project as read bundles, following [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

The matcher reads one strand only, so every read must run in the same direction as your targets. Orienting turns each read that runs the other way into its reverse complement, and leaves out reads that match neither strand, as [Orienting reads](../03-reads/08-read-processing.md#orienting-reads) describes. Your own reads need this, and [Prepare your own reads](#prepare-your-own-reads) gives the order. Both fixture read sets are already oriented single reads, so there is nothing to merge or orient.

12S Amplicon Matching is a specialized workflow, so **Tools > Classification** shows it as **Enable 12S Amplicon Matching…** until you turn it on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows. Its card there reads "Review unresolved 12S sequences". The run dialog is the Workflow Operations window, which **Tools > Workflows** also opens for [workflow packages](../../GLOSSARY.md#workflow-package), and it preselects the reference bundle you selected in the sidebar, as [Running External Workflows](../08-workflows/03-running-external-workflows.md#open-the-workflow-and-set-its-inputs) shows. Its chimera check uses [vsearch](../../GLOSSARY.md#vsearch), a sequence-comparison program that arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Workflow Library card lists as Third-Party Tools and the Welcome window offers to install on first launch.

<!-- SHOT: twelve-s-workflow-library -->

Six of this workflow's settings live in the Inspector rather than the run dialog. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Every run in this chapter takes under a second.

## Procedure

### Build a 12S reference bundle

The workflow takes its reference in either of two forms. A plain deduplicated FASTA works, and you can point a run at it directly. A `.lungfish12sref` bundle holds the sequences and their species table together, and in the dialog only the bundle fills the species table's Tax ID and Group columns, though the command line can fill them for a plain FASTA. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. This chapter builds the bundle, because a roster without taxonomy IDs is harder to report.

Choose **Tools > Classification > 12S Amplicon Matching…** and click **Create 12S Reference…** beside the Reference picker. The sheet asks for a **Name**, the **Deduplicated FASTA**, the **Target Metadata** table, and an **Output Bundle**, which defaults to `12S reference.lungfish12sref` in the project's `Reference Sequences` folder. A **Source Files** row for extra files to copy in, which can stay empty, and a **Replace Existing Bundle** checkbox sit below them. Type `Primate 12S` as the name, pick `primate-12s-dedup.fasta` and `primate-12s-midori.tsv` from `Practice Data/primate-12s` with the **Choose…** buttons, and click **Create**.

Each FASTA name line must read as a common name followed by the scientific name in parentheses, for example `>Rhesus macaque (Macaca mulatta)`. One of the fixture's six records carries a second species after the name, `>Rhesus macaque (Macaca mulatta)|also_matches=Japanese macaque (Macaca fuscata)`, because its 60 bases occur in both macaques. That is how a deduplicated reference records a sequence two species share, and it is the source of the Alternates figure you read later. The metadata table is a [tab-separated](../../GLOSSARY.md#tsv) text file in the MIDORI style, named after [MIDORI](https://www.reference-midori.info/), a public set of mitochondrial reference sequences that includes the 12S gene. Save a spreadsheet as tab-delimited text with the ending `.tsv`. It needs all seven of these columns, shown with spaces for tabs and with the first two rows of the practice table:

```text
seq_id  common_name  latin_name  group  taxid  name_source  taxonomy
Homo_sapiens  Human  Homo sapiens  Mammal  9606  NCBI  Chordata;Mammalia;Primates;Homo sapiens
Pan_troglodytes  Chimpanzee  Pan troglodytes  Mammal  9598  NCBI  Chordata;Mammalia;Primates;Pan troglodytes
```

`seq_id` is a label for the row, and `name_source` says where the name came from. `common_name` and `latin_name` are the everyday and scientific names, `group` is a label such as Mammal or Fish, `taxid` is the [taxonomy ID](../../GLOSSARY.md#taxonomy-id), the number NCBI's taxonomy database gives the species, and `taxonomy` is the lineage with a semicolon between ranks. A species named only after `also_matches`, such as the Japanese macaque, needs its own row too, which supplies the second taxonomy ID in the rhesus row's Tax ID cell.

LGE joins each FASTA record to its metadata row by the scientific name inside the parentheses. A name line without parentheses, such as `>Homo_sapiens`, joins to nothing, and the reference is still written with empty common name, taxid, group, and taxonomy fields and no warning, so after your first run check that the **Tax ID** and **Group** cells of the species table are filled in. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

### Make a reference for your own animals

LGE does not pick targets or collapse duplicates for you, so you make the FASTA by hand.

1. Collect a 12S sequence for each animal, from NCBI as [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md#procedure) shows, or from [MIDORI](https://www.reference-midori.info/). A whole 12S gene is about 950 bases in human, longer than any read, so you cut a target from it.
2. Pick a stretch inside your amplicon, a few bases in from each primer site, where your animals differ, using [Aligning Sequences](../02-sequences/04-aligning-sequences.md) to compare them. For each record, type the stretch's range in the location box and copy it with **Sequence > Copy Visible Region as FASTA**, as [Copy the visible region without a sheet](../02-sequences/03-extracting-and-comparing.md#copy-the-visible-region-without-a-sheet) shows.
3. Paste the copies into one text file under name lines like `>Common name (Scientific name)`. When two animals share a stretch, keep one record and add `|also_matches=` and the other animal's name, written the same way, to its name line.
4. Give each animal a row in the metadata table, including any named after `also_matches`.

### Prepare your own reads

For paired reads, merge first, orient second, and match last. A merged read counts once, while an unmerged pair with an error inside the target on one mate counts nowhere. Orient Reads is built for single reads and can drop one mate of a pair, so run it only on merged reads.

Merge with **Tools > Read Processing > Merge Overlapping Pairs…**, as [Merging the overlapping pairs](../03-reads/08-read-processing.md#merging-the-overlapping-pairs) shows. Then choose **Tools > Read Processing > Orient Reads…** and pick the FASTA of targets you built the bundle from, which the dialog lists when the file sits inside the project folder. Orient Reads flips each read that runs the other way and drops every read it cannot place, which can include reads of an animal your targets lack, with no copy kept, so compare the read counts before and after. If many reads vanish, orient against the longer 12S records instead. Skip Remove Duplicate Reads, because the matcher counts repeated copies.

### Set the inputs and run the match

Choose **Tools > Classification > 12S Amplicon Matching…** again if the dialog closed. The Workflow Operations dialog opens with the workflow selected, laid out as [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. Its right side holds the **Overview**, **Inputs**, **Primary settings**, **Advanced settings**, and **Output** sections, and the Readiness line sits at the foot beside **Cancel** and **Run**.

1. Under **Reference**, open the **Project Reference** menu and choose the bundle you built. The menu lists it by its path, `Reference Sequences/12S reference.lungfish12sref`, not by the name you typed. It lists only reference bundles already saved in the project. The button beside the path reads **Choose…** until a reference is selected and **Replace…** after, and picks a plain FASTA or a bundle.
2. Leave **Analysis Metadata** reading "No analysis metadata selected". The fixture does not need it.
3. Under **FASTQ Bundles**, make sure only the `SIMULATED-12S-mixture-oriented` bundle is listed. The list is what was selected in the sidebar when the dialog opened, so for several samples Cmd-click them all there first.
4. Leave **Read Platform** on **Illumina exact**. **Result Name** arrives filled in as the read bundle's name followed by `-12s`, and every other field already holds the value this example used.
5. Click **Run**, and watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A clean run's row reads **Completed**.

<!-- SHOT: twelve-s-dialog-inputs -->

The workflow matches the reads, settles any read whose sequence is shared by two species, checks the unmatched clusters for chimeras, and writes a `.lungfish12s` result bundle. Any read bundle works as input, including a [virtual bundle](../../GLOSSARY.md#virtual-bundle), which stores a recipe and a preview rather than the reads themselves, as one barcode of a demultiplexed run does, so LGE rebuilds its reads first. A bundle whose full reads are gone is refused with a message to import the FASTQ file again. Two inputs that would share a sample name, such as `barcode01` bundles from two folders, are refused before anything is written, with a line that names both. Selecting two or more read bundles adds a **Run Mode** choice, fixed on "Combine all inputs, run once (1 result)" with the note "They will run as one batch." One result does not mean one pooled sample. LGE counts every bundle as its own sample, with its own rows.

<!-- SHOT: twelve-s-dialog-options -->

### Read the species table

The result lands in `Analyses/12S amplicon results`, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Click it to open the 12S viewport. It opens on the **Targets** view, the species table, which adds up the reference targets by species, so each row is one species in one sample. [Reading the results](#reading-the-results) explains each column.

Sort by **Exact Reads** to put the dominant species at the top. The **Filter species or matches** field narrows the table by scientific name, common name, group, taxid, or alternate-match text.

<!-- SHOT: twelve-s-result-species-table -->

Right-click a species row for two lookups at the bottom of the menu. **Learn More About** opens that species' NCBI taxonomy page in your browser, and **View Photo of** opens its Wikipedia article. Both open the browser at once, without asking first, by design.

### Review the unresolved clusters

Click **Unresolved** in the Targets and Unresolved switch at the top of the result. An unresolved cluster is a group of reads that all carry the same sequence and matched no reference record, or matched several species that the abundance rule, explained under Reading the results, could not choose between.

Sort by **Reads**. A cluster with many reads and a Chimera status of Not Detected is the interesting case, because your sample produced that sequence in quantity and it matched nothing you supplied. It is often a species the reference lacks. Many means well above the largest cluster of the oriented practice mixture, 3 reads of 2,000. A [chimera](../../GLOSSARY.md#chimera) is an artifact formed when two real templates join during PCR, so clusters marked Candidate can usually be set aside.

<!-- SHOT: twelve-s-unresolved-clusters -->

### Verify a cluster with BLAST

Select the clusters to check, or none to check every cluster the table shows, and click **Verify with BLAST…** in the action bar along the bottom of the viewport. The button is dimmed on the Targets view and active on the Unresolved view whenever the table shows a cluster. A sheet titled **Run BLAST at NCBI?** asks first, and **Run BLAST** sends the chosen clusters as one search, shown as a row in the Operations Panel whose **Cancel** stops it. The sequences leave your Mac for NCBI's servers, so check your laboratory's data-handling rules first. The hits land in the **BLAST Results** drawer below the table, the search is saved in the project's `blast-verifications` folder, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage. If BLAST names an animal your reference lacks, add its target and table row, build the bundle again with **Replace Existing Bundle** ticked, and match again.

<!-- SHOT: twelve-s-blast-review -->

### Export the table

Click **Export** in the action bar and choose **Export as CSV…**, **Export as TSV…**, or **Export as Excel…**. The Inspector's **12S Results** section ends with an **Export** menu offering the same three formats as **CSV**, **TSV**, and **Excel**. The export runs as a row in the Operations Panel, and the Excel file carries the unresolved clusters on a second sheet. Every export honors the Inspector filters described in Settings, and all of them are off on a fresh result, so a first export carries every row.

A result can change on disk while it is open, when another run writes over it. Export then stops before it writes anything and says "This 12S result changed on disk after it opened, so the rows on screen are not the rows in the result. No file was written." It asks you to select another item in the sidebar, select the result again, and export again. **Verify with BLAST…** stops the same way and sends nothing to NCBI. When the Unresolved view cannot read the result's sequences, it shows an empty table with a message that says so, and an empty table then does not mean the result has none.

To get the unresolved sequences as FASTA, select two or more clusters on the Unresolved view, right-click, and choose **Copy Sequences**. With one cluster selected, **Copy Sequence** copies the bases without a FASTA name line. The workflow also writes every cluster to `unresolved-sequences.fasta` inside the result bundle, which you reach by right-clicking the result in the sidebar and choosing **Show in Finder**, where the bundle opens as an ordinary folder.

<!-- SHOT: twelve-s-export -->

## Settings

The dialog holds eight controls. The Inspector's **12S Results** section holds six more, which change only what the viewport shows and exports, never the stored result.

**Reference.** Names the known 12S sequences every read is matched against, as a deduplicated FASTA or a `.lungfish12sref` bundle. It starts on the first reference bundle LGE finds in the project, or empty if there is none, so check it before you click Run, because this is the choice that decides what can be found. A genome `.lungfishref` bundle is also accepted, so a wrong preselection can still run. Use a reference built for the animals you expect, since a fish-only reference will not name the mammals in a gut sample. On the command line this is `--reference`.

**Analysis Metadata.** Stores a copy of a per-sample CSV or TSV table inside the result, so the viewport can show its fields as extra columns. It starts empty, reading "No analysis metadata selected", because the match does not need it. Supply one, with a `sample_id` column whose values match the read bundle names, when you want collection site or date beside the counts. A column named `sample`, `sample_name`, or `id` works in place of `sample_id`. On the command line this is `--sample-metadata`.

**Read Platform.** Chooses how strict the match is, as a two-way picker. The default is **Illumina exact**, which accepts only reads containing a reference sequence with no changed bases, right for Illumina's very low error rate. Switch to **ONT indel-tolerant** for Oxford Nanopore reads, whose usual error is an inserted or deleted base. On the command line this is `--matching-mode`.

**Result Name.** Names the `.lungfish12s` result bundle. It arrives filled in as the first selected read bundle's name followed by `-12s`, or `12s-amplicons` with no bundle selected. Change it when that name will not identify the run later. On the command line this is `--output-name`.

**Min Soft Clip.** Sets how many of the read's own bases, a [soft clip](../../GLOSSARY.md#soft-clip), must sit beyond each end of the matched target. The default is 1, the rule stated under What it is, so a read that ends exactly at a target's edge is rejected, and the field accepts 0 or more. Raise it, to 5 for example, to demand more flanking sequence on both sides, and set 0 only when reads may legitimately end exactly at the target's edge. On the command line this is `--min-soft-clip`.

**Max Indels.** Sets how many inserted or deleted bases a read may carry and still match, in the field behind the **Advanced Options** triangle of the **Advanced settings** section. The default is 3, and the field is grayed out and ignored under Illumina exact, since only the ONT setting allows indels. Raise it for noisier Nanopore chemistry and lower it for stricter matches. On the command line this is `--max-indels`.

**Run vsearch chimera review.** Checks each unresolved cluster for chimeras with vsearch and marks it Not Detected or Candidate. It is ticked by default because a chimera looks like a new species until something checks it. Untick it only to shorten a run whose unresolved clusters you will not read, and every cluster then shows Not Reviewed. On the command line this is `--chimera-review`, and `--no-chimera-review` turns it off.

**Directory.** Chooses where the result bundle is written. The default is the project's `Analyses/12S amplicon results` folder, which keeps results inside the project. Change it only when the result belongs elsewhere. On the command line this is `--output-dir`.

The remaining six are Inspector filters. **Minimum Exact Reads**, the **Attributes** pills, and the **Taxon Groups** pills sit under **Target Rows**. **Minimum Unresolved Reads** and **Chimera** sit under **Unmatched Reads**, which starts collapsed. Each filter's flag belongs to the export command, `12s-export`, not to the match. For a result that read unmerged pairs, the labels say Fragments where they say Reads here, such as **Minimum Exact Fragments** and **Unmatched Fragments**, as [Fragments and unmerged pairs](#fragments-and-unmerged-pairs) explains.

**Minimum Exact Reads.** Hides species rows with fewer exact reads than this, set with a number field and a stepper. The default is 0, so every row with a read shows. Raise it to drop the one-read and two-read hits that are usually noise. On the command line this is `--min-exact-reads`.

**Exclude Human.** A pill under **Attributes** that hides Homo sapiens rows, matched by that name or by taxid 9606. It is off by default, so human reads show like any other species. Turn it on for diet or environmental work, where human reads are usually [contamination](../../GLOSSARY.md#contamination) from whoever handled the sample, and leave it off for this chapter's example, where human is one of the species you are looking for. On the command line this is `--exclude-human`.

**Only With Alternates.** A pill under **Attributes** that shows only species whose matched sequence is shared with another species. It is off by default, so every species shows. Turn it on to review which calls are ambiguous before you report them. On the command line this is `--require-alternate-matches`.

**Taxon Groups.** A row of pills, one per group such as Mammal, Fish, or Bird, that each cycle through neutral, included, and excluded as you click. Every pill starts neutral, which places no limit, so all groups show. Include a group to keep only the included groups, or exclude one to hide it, for example to keep a diet study to fish. On the command line this is `--taxon-group` to keep a group and `--exclude-taxon-group` to drop one.

**Minimum Unresolved Reads.** Hides unresolved clusters with fewer reads than this, in the Unresolved table and the Excel sheet, set with a number field and a stepper. The default is 0, so every cluster shows. Raise it to 2 to skip single-read clusters, which are far more often sequencing error than an unknown species. On the command line this is `--min-unresolved-reads`.

**Chimera.** Limits the unresolved clusters to one verdict, from All, Not Reviewed, Not Detected, Candidate, and Confirmed, which this release's chimera check never assigns, so it shows no rows. The default is All. Choose Not Detected to see only clusters that may be real sequence rather than PCR artifacts. On the command line this is `--chimera-status`.

## Reading the results

The summary line above the table gives four figures, samples, exact reads, percent unresolved, and chimera candidates. For a run that read unmerged pairs the second figure counts exact fragments instead, as [Fragments and unmerged pairs](#fragments-and-unmerged-pairs) explains. On the simulated mixture it reads:

```text
1 samples | 1817 exact reads | 9.2% unresolved | 0 chimera candidates
```

The mixture holds 2,000 reads. 1,817 matched exactly and 183 did not, so 9.15 percent are unresolved, shown rounded to 9.2, and 90.85 percent matched. Both figures divide by the same 2,000 reads, so they add to 100 unless reads were reassigned, as described below. Quote either figure, and say which one it is.

### The species table

The species table has nine columns. **Sample**, **Scientific Name**, and **Common Names** identify the row. **Group** is the label from the reference metadata, such as Mammal, and **Tax ID** is the NCBI taxid. **Exact Reads** is the number of reads in that sample assigned to the species.

**% of Sample** is a [relative abundance](../../GLOSSARY.md#relative-abundance), the species' exact reads as a percentage of all exact-matched reads in that sample. Unresolved reads are left out of the denominator, which is why the rows add to 100 percent although a tenth of the reads matched nothing. It is the figure to compare across samples, because a deeply sequenced sample yields more reads of everything. A species at 40 percent in one sample and 2 percent in another differs in share, while 100 reads against 10 may only reflect depth.

**Refs** is how many reference records carry that species' name. A species can have several when the reference holds more than one 12S variant for it, and the number is neither good nor bad. **Alternates** is how many other species share the matched sequence. A nonzero value means the name is one of several the evidence allows, so treat that row with more caution and say so in a report.

The simulated mixture gives three rows.

| Scientific Name | Common Names | Tax ID | Exact Reads | % of Sample | Refs | Alternates |
|---|---|---|---|---|---|---|
| Homo sapiens | Human | 9606 | 1,235 | 68.0% | 1 | 0 |
| Macaca mulatta | Rhesus macaque | `9544; 9542` | 491 | 27.0% | 2 | 1 |
| Macaca fascicularis | Cynomolgus macaque | 9541 | 91 | 5.0% | 1 | 0 |

The table lists only species with at least one read, so the chimpanzee and gorilla do not appear. An export, from the window or the command line, still lists them with 0 exact reads. Every row carries Group Mammal. The rhesus row's Tax ID cell holds two taxonomy IDs, 9544 for the rhesus macaque and 9542 for the Japanese macaque it shares a sequence with, on screen and in an export, and an export also has an Other Potential Matches column that names Japanese macaque (*Macaca fuscata*).

### Checking the roster against the truth

Because the mixture is simulated, you can check each figure against the answer. The truth was 1,400 human, 500 rhesus, and 100 cynomolgus reads. Every exact match went to the species its read was made from, so the matcher named no species wrongly. What differs is how many reads of each species matched at all. 1,235 of 1,400 human reads matched, 88.2 percent. 491 of 500 rhesus reads matched, 98.2 percent, and 91 of 100 cynomolgus reads matched.

The difference comes from the reference. A read matches only when its copy of a 60-base target carries no error, and the simulation put random errors into every species at the same rate of 0.2 percent per base. The rhesus macaque has two targets in this reference, so a rhesus read with an error in one target can still match the other, while each other species has one. That extra chance is why the shares came out at 68.0, 27.0, and 5.0 percent against a truth of 70, 25, and 5. A real run behaves the same way, and a species with more reference records, or shorter ones, is more likely to be counted, since each extra base is another place for an error. Read % of Sample as a close estimate of each species' share, not as an exact count of the DNA in the tube.

### Alternates and the abundance rule

The rhesus row's Alternates of 1 comes from the one record the rhesus macaque shares with the Japanese macaque. 48 of the 491 rhesus reads matched that shared record, and 443 matched the rhesus-only record. A read that holds both rhesus records counts once, on the rhesus-only record, so the 48 are reads whose rhesus-only target carried an error. The reads on the shared record could in principle have come from either macaque. The roster names rhesus because the shared record carries the rhesus name, and the Alternates column is how the table admits the other possibility. Nothing in this sample supports a Japanese macaque, because no read matched a record unique to it.

LGE does not collapse duplicates in a reference, so two species can carry an identical 12S sequence under two separate records, and a read matching it is settled by abundance. LGE gives the read to whichever candidate has more unambiguous reads in that sample, and any lead wins by default, so one read can decide a call. The window has no control for this. On the command line, `--ambiguity-resolution conservative` requires the winner to hold at least twice the runner-up and at least ten reads, and leaves the read unresolved otherwise. Each move is written to `reassignments.tsv` inside the result bundle, and the summary line's exact-read count leaves moved reads out. The species table counts a moved read for the species that received it, so its **Exact Reads** add up to that figure plus the moved reads. The fixture never triggers the rule, because its shared record is one record under one name rather than two, so `reassignments.tsv` stays empty. If your question depends on telling two such species apart, the 12S amplicon cannot do it.

### The unresolved clusters

In the Unresolved view, read **Reads** and **Chimera** together. **Sequence** is a label for the cluster, and **Bases** holds its DNA. **Samples** counts the samples that contributed reads. The simulated mixture has 143 clusters holding 183 reads, all Not Detected. 108 hold one read, 30 hold two, and 5 hold three. Many single-read clusters and no chimeras is ordinary noise, here from reads whose copy of a target carried a simulated error, so they overlapped a target without containing it whole.

### Fragments and unmerged pairs

12S matching counts fragments, the DNA molecules the library copied, rather than records. A merged read, a read whose mate is missing, and a read from a single-end run each count once. A pair that was not merged counts once when both of its mates give the identical call, which means the same reference record, the same set of candidate records, or no match at all. The second mate is read as its reverse complement, so that it runs along the same strand as the first, and the pair then counts as its first mate, toward a species, toward the abundance rule, or toward an unresolved cluster. Such a cluster shows the first mate's sequence, and its row in `unresolved-sequences.tsv` carries the note `unmerged pairs, R1 shown`, or `merged reads and unmerged pairs` when merged reads share it.

A read whose mate is missing is read as its reverse complement as well when its name marks it as the second mate, with `/2` or an Illumina comment that starts `2:`, unless its file holds merged reads or the reads come from a Nanopore or PacBio run. In a bundle that keeps its mates in separate R1 and R2 files, mates named with `/1` and `/2`, with Illumina comments, or with `.1` and `.2` or `_1` and `_2` after one shared name are read as pairs. A bundle that stores its pairs as one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, as an import makes it, is read as pairs too, taking each record with the one after it, and the run stops with a message that names both records when two neighbours are not mates. Mates whose numbers contradict each other stop the run. Mates whose names are the same and carry no mate number, as the SRA writes them, are read as pairs with no warning. Mates whose names carry no mate number and differ from each other are paired by position, the first record of R1 with the first of R2 and so on, and the run warns that it did so. The warning counts the record pairs that carry no mate number and names the first of them. It appears in the Operations Panel row, in the result's `metadata/sample-metadata-manifest.json`, and under **Warnings** in the Inspector's **Samples & Metadata** section.

A pair whose mates disagree is left out of every count except the sample's input total, and tallied by its reason.

| Reason | What the two mates did |
|---|---|
| different targets | Each matched one reference record exactly, and the records differ |
| different candidates | Each matched several records, and the two sets differ |
| one mate unresolved | One gave a call and the other matched nothing |
| one mate ambiguous | One matched a single record and the other matched several |

When a run read unmerged pairs, the viewport and the Inspector call its counts fragments. The summary line reads exact fragments, the tables' count columns read **Exact Fragments** and **Fragments**, the [provenance](../../GLOSSARY.md#provenance) popover and the Inspector say Exact Fragments, the Inspector's filters read **Minimum Exact Fragments**, **Unmatched Fragments** and **Minimum Unresolved Fragments**, and Copy Rows uses the same headings. A result from merged or single reads alone keeps the reads wording this chapter shows. The tables that **Export** writes keep the headings Exact Reads and Reads whatever the run read, so read those columns as fragments for a run of pairs.

When a run leaves pairs out, the summary line ends with a figure such as "2 discordant pairs left out (1 pair with different targets, 1 pair with one mate unresolved)", the provenance popover adds a Left Out row, and the `discordant_pairs` column of `samples.tsv` and the `read-fate.json` file inside the result bundle record the count. The fixture holds no pairs, so its figures are the ones above and its summary line has no left-out figure. A result from merged or single reads alone never leaves a pair out, since each of its reads is one fragment. So if many pairs are left out, merge the pairs first, as [Prepare your own reads](#prepare-your-own-reads) says.

### A single-species contrast and an unoriented run

Run the same match on the `HG002-12S-oriented` bundle, 186 real human reads, and the table shows one row, Homo sapiens, with 110 exact reads and 100.0 percent of the sample. The summary line reads 40.9 percent unresolved, and the Unresolved view holds 69 clusters of 76 reads, 64 of them single reads. The reads came from a whole-mitochondrion library rather than an amplicon library, so many of them cover the 12S region without containing a target whole, which is the rule working as designed. One species holding every matched read while its close relatives hold none is what a single-species sample looks like.

The demo project also keeps the mixture before orientation, `SIMULATED-12S-mixture.fastq.gz` under `Practice Data/primate-12s`, in which about half the reads run along the opposite strand. Import and match it, and only 935 of the 2,000 reads match, with 53.2 percent unresolved. The Unresolved view then opens on three large clusters of 448, 153, and 32 reads, the reverse-strand copies of the human, rhesus, and cynomolgus amplicons. That is the signature of an unoriented run, and orienting the reads first is the fix.

Click the information button at the right of the action bar for the provenance popover, which gives the analysis name, sample count, exact reads, unmatched percent, and creation time.

## What good looks like

The 12S viewport answers two questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) on screen. Exact Reads says how many reads support each species, and Alternates says whether another species could explain the same reads. Controls are yours to add, so run a [negative control](../../GLOSSARY.md#negative-control) as another bundle and compare its rows with each sample's. **Verify with BLAST…** answers the last question for the unresolved sequences.

A healthy run puts its matched reads on a few species and leaves an unresolved tail you can explain. Judge the match rate against what the reference covers, not against a fixed number. A reference holding every species in the sample should match most reads, as the simulated mixture's 90.85 percent shows. A lower rate needs an explanation, such as the HG002 reads' whole-mitochondrion origin or an unoriented run.

The species table should hold a few rows with large counts. Twenty or more rows with only a few reads each usually mean the reference and the sample do not fit each other, though pond water can hold twenty species.

A row with a nonzero Alternates count is a species the evidence allows rather than one it proves. Report it with its alternate named, as the rhesus row's Japanese macaque shows.

The unresolved tail should be mostly single reads or chimera candidates. One or two large Not Detected clusters are normal and are the ones to send to BLAST. Many large Not Detected clusters mean the reference is missing species, or, when the clusters are the reverse complements of your targets, that the reads were not oriented, which orienting them and matching again will show. The result's provenance record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, holds the reference and settings for a methods section.

## On the command line

These commands repeat the procedure in the [Terminal](../../GLOSSARY.md#terminal) app, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of these commands is listed in [12S amplicon matching](../appendices/cli-reference.md#12s-amplicon-matching) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/12S Metabarcoding.lungfish"
DATA="$PROJECT/Practice Data/primate-12s"

# Package the reference and its seven-column metadata as a bundle
lungfish-cli fastq 12s-reference-bundle \
  --dedup-fasta "$DATA/primate-12s-dedup.fasta" \
  --midori-metadata "$DATA/primate-12s-midori.tsv" \
  --output "$PROJECT/Reference Sequences/primate-12s.lungfish12sref" \
  --name "Primate 12S"

# Match the simulated mixture
lungfish-cli fastq 12s-match \
  "$PROJECT/Imports/SIMULATED-12S-mixture-oriented.lungfishfastq/SIMULATED-12S-mixture-oriented.fastq.gz" \
  --reference "$PROJECT/Reference Sequences/primate-12s.lungfish12sref" \
  --output-dir "$PROJECT/Analyses/12S amplicon results" \
  --output-name SIMULATED-12S-mixture-oriented

# Export the species rows, then the unresolved clusters as FASTA
RESULT="$PROJECT/Analyses/12S amplicon results/SIMULATED-12S-mixture-oriented.lungfish12s"
lungfish-cli fastq 12s-export --bundle "$RESULT" \
  --export-format tsv --output species.tsv
lungfish-cli fastq 12s-export-unresolved --bundle "$RESULT" \
  --min-reads 1 --output unresolved.fasta
```

The first line stores the project's folder as `PROJECT`, and `DATA` and `RESULT` store the practice-data folder and the result bundle in the same way. Two points need care. `12s-export-unresolved` skips clusters under 5 reads by default, so on the mixture it writes an empty file unless you pass `--min-reads 1` as above, which writes all 143 clusters. The help text for `12s-reference-bundle` and `12s-reference-metadata` names only five metadata columns, but both stop with a missing-column error unless all seven are present, which is a known defect listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release). `12s-reference-metadata` joins a FASTA to the table and writes a target table that `12s-match` takes as `--reference-metadata`, which fills Tax ID and Group for a plain FASTA.

`12s-match` takes read bundles as well as FASTQ files, and it reads the pairs of a bundle as pairs, by the naming rules in [Fragments and unmerged pairs](#fragments-and-unmerged-pairs). Each file named on the command line is one sample, so two loose files named as the R1 and R2 of one sample are two samples of single reads to it, and such a pair belongs in one bundle first. A path inside a bundle, such as `SampleA.lungfishfastq/merged.fastq`, is read alone, without the rest of the bundle. With `--force` the earlier result is moved to a hidden folder in the output folder when the new result is ready to be written. It is deleted once the new result is complete and moved back if the run fails. If it cannot be moved back, the error names the hidden folder, whose name starts with `.` and the result's name, and renaming that folder to `<name>.lungfish12s` restores it.

## Next

Continue to [Running Freyja](07-running-freyja.md), which returns to the SARS-CoV-2 run from [Running EsViritu](03-running-esviritu.md) and estimates which lineages its reads hold, a mixture question of a different kind. [BLAST Verification](06-blast-verification.md) covers checking an unresolved cluster against NCBI, and [What Is Read Classification](01-what-is-classification.md) sets 12S matching beside the taxonomic classifiers.

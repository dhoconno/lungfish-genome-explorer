---
title: 12S Amplicon Metabarcoding
chapter_id: 06-classification/10-twelve-s-metabarcoding
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification, 03-reads/01-importing-fastq]
estimated_reading_min: 18
task: Match merged 12S amplicon reads to a deduplicated reference FASTA, review unresolved clusters, and export species rows.
tags: [classification, metabarcoding, twelve-s, amplicon, blast, export]
tools: [blast, vsearch]
parameters_refs: [classify.twelve-s-match]
entry_points:
  - "Tools > Workflows > Workflow Library..."
  - "Tools > Genotyping > 12S Amplicon Matching..."
  - "CLI: lungfish-cli fastq 12s-match"
shots:
  - id: twelve-s-workflow-library
    caption: "The Workflow Library window with the 12S Amplicon Matching card under Specialized Workflows, showing its Specialized badge, its dependency row for the Third-Party Tools pack, and the Enabled switch."
  - id: twelve-s-dialog-inputs
    caption: "The Workflow Operations dialog on 12S Amplicon Matching, showing the Reference picker with its Create 12S Reference... button, the Analysis Metadata picker with its Choose Metadata... button, and the FASTQ Bundles list."
  - id: twelve-s-dialog-options
    caption: "The same dialog's Read Platform segmented picker, Result Name field, and Min Soft Clip number field, with the Advanced Options disclosure expanded to show Max Indels, Run vsearch chimera review, and the note that inputs must already be merged."
  - id: twelve-s-result-species-table
    caption: "The 12S viewport on its Targets view for the HG002 reads, showing one Homo sapiens row with 110 exact reads and 100.0% of Sample under the Sample, Scientific Name, Common Names, Group, Tax ID, Exact Reads, % of Sample, Refs, and Alternates columns."
  - id: twelve-s-unresolved-clusters
    caption: "The viewport's Unresolved view, showing the Sequence, Reads, Samples, Chimera, and Bases columns for the clusters that matched no reference."
  - id: twelve-s-blast-review
    caption: "An unresolved cluster sent to NCBI BLAST with the BLAST Verify button, with the returned Organism, Identity, and Accession hits in the drawer below the table."
  - id: twelve-s-export
    caption: "The viewport's Export menu offering Export as CSV..., Export as TSV..., and Export as Excel..."
illustrations: []
glossary_refs: [amplicon, blast, bundle, checksum, chimera, deduplicated-reference, fastq, inspector, metabarcoding, provenance, read, read-orientation, required-setup-pack, soft-clip, taxonomy-id, twelve-s, vsearch, workflow-library]
features_refs: [classify.twelve-s]
fixtures_refs: [primate-12s]
brand_reviewed: false
lead_approved: false
---

## What it is

[12S metabarcoding](../../GLOSSARY.md#metabarcoding) identifies which vertebrate species are present in a mixed sample. The [12S](../../GLOSSARY.md#twelve-s) ribosomal RNA gene sits in the mitochondrial genome, the small loop of DNA every animal cell carries outside its nucleus. Primers, short synthetic DNA pieces that mark where copying starts, bind sites that are the same across vertebrates and copy a short slice of the gene by PCR. That slice is an [amplicon](../../GLOSSARY.md#amplicon), a defined stretch of DNA amplified between two known primer sites. The primer sites are shared, but the bases between them differ from species to species, so reading the interior tells you which animal the DNA came from. Metabarcoding sequences that one marker across a whole mixed sample, so the answer is a roster of species rather than a single name.

Lungfish Genome Explorer (LGE) resolves a 12S run by exact matching. Each [read](../../GLOSSARY.md#read), one stretch of sequence the instrument produced, is checked against a [deduplicated reference](../../GLOSSARY.md#deduplicated-reference). That is a FASTA file, a plain-text list of named sequences, where each record is one known 12S sequence labelled with its species and identical sequences have been collapsed so each appears once.

The matching rule is one sentence. Each reference record is a short target stretch, shorter than the reads. A reference record must appear inside the read as an unbroken run of identical bases, with at least one of the read's own bases left over at each end, and the read is then assigned to that record's species. A species missing from the reference can never be reported, however many reads it contributed, so the reads that match nothing are kept aside for you to review.

## Why you would do this

Run 12S matching when your sample is a mixture and the question is which vertebrates are in it. A gut-content sample, a water sample, a swab from a surface, or a pooled field collection all carry DNA from several animals at once.

A broad classifier such as Kraken 2 is built to place every read somewhere in the tree of life, so it will report a genus, a group of related species, when the evidence is thin. For a species roster that is a problem, because the value of the result is that each named species is really there. Exact matching against a curated reference refuses to guess. A read either contains a known 12S sequence or it does not.

This chapter works through a human example, matching mitochondrial reads from one person against a small reference holding five primates.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the primate 12S fixture. Download `primate-12s-dedup.fasta`, `primate-12s-midori.tsv`, and `HG002-12S-oriented.fastq` from [the primate-12s fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/primate-12s), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The first file is the deduplicated reference, the second is the table that labels each reference sequence with its species, and the third holds the reads. The reference holds five primate 12S sequences cut from public mitochondrial genomes. The reads are 12S reads from HG002, a public reference human sample, so they should match Homo sapiens and nothing else. About a third of them still come back unresolved, which is expected for this fixture, as Reading the results explains.

Import `HG002-12S-oriented.fastq` into the project as a read bundle, following [Importing FASTQ Files](../03-reads/01-importing-fastq.md).

The matcher reads one strand only and does not merge read pairs. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. Orienting flips every read so that all of them run in the same direction along the gene. So orient your own reads with Orient Reads and merge their overlapping pairs first, as [Merging the overlapping pairs](../03-reads/08-read-processing.md#merging-the-overlapping-pairs) shows. The fixture's reads are already oriented, and they are single reads from the first end of each fragment, known as R1, so there is nothing to merge.

12S Amplicon Matching is a specialized workflow, so the Tools menu shows it as "12S Amplicon Matching (not enabled)" until you turn it on. Turn the workflow on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Running External Workflows](../08-workflows/03-running-external-workflows.md#procedure) shows. The Workflow Library opens from **Tools > Workflows > Workflow Library...**. Its chimera check uses [vsearch](../../GLOSSARY.md#vsearch), a sequence-comparison program, and vsearch arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

<!-- SHOT: twelve-s-workflow-library -->

Six of this workflow's settings live in the Inspector rather than the run dialog. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

## Procedure

### 1. Choose or build a 12S reference

The workflow takes its reference in either of two forms. A plain deduplicated FASTA is what the fixture ships, and you can point the run at it directly. A `.lungfish12sref` bundle holds the sequences and their species labels together so later runs need only one item. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains.

For the fixture, skip to step 2. Build a bundle when you will reuse a reference often. Choose **Tools > Genotyping > 12S Amplicon Matching...** and click **Create 12S Reference...** beside the Reference picker. The sheet asks for a **Name**, the **Deduplicated FASTA**, the **Target Metadata** table, and an **Output Bundle**, which defaults to `12S reference.lungfish12sref` in the project's `Reference Sequences` folder. A **Source Files** row and a **Replace Existing Bundle** checkbox sit below them.

Each FASTA name line must read as a common name followed by the scientific name in parentheses, for example `>Rhesus macaque (Macaca mulatta)`. The metadata table is a tab-separated file in the MIDORI style, named after a public database of animal mitochondrial marker sequences. It needs all seven of these columns:

```text
seq_id  common_name  latin_name  group  taxid  name_source  taxonomy
```

The `taxid` column holds the [taxonomy ID](../../GLOSSARY.md#taxonomy-id), the number NCBI's taxonomy database gives each species, and `group` holds a label such as Mammal or Fish. LGE joins each FASTA record to its metadata row by the scientific name inside the parentheses. A name line without parentheses, such as `>Homo_sapiens`, joins to nothing, and the reference is still written with empty common name, taxid, group, and taxonomy fields and no warning, so check that a reference you built carries species names. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

### 2. Open the workflow and set its inputs

Choose **Tools > Genotyping > 12S Amplicon Matching...**. The Workflow Operations dialog opens with the workflow selected, laid out as [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

1. Under **Reference**, click **Choose...**, or **Replace...** when a reference is already filled in, and pick `primate-12s-dedup.fasta`. The **Project Reference** menu above it lists only reference bundles already saved in the project.
2. Leave **Analysis Metadata** reading "No analysis metadata selected". The fixture does not need it.
3. Under **FASTQ Bundles**, confirm the `HG002-12S-oriented` bundle is listed.

Selecting two or more read bundles adds a **Run Mode** choice, fixed on "Combine all inputs, run once (1 result)" with the note "They will run as one batch." One result does not mean one pooled sample. LGE counts every bundle as its own sample, with its own rows.

<!-- SHOT: twelve-s-dialog-inputs -->

### 3. Set the platform and run

Leave **Read Platform** on **Illumina exact**, which the fixture needs. **Result Name** arrives filled in from the read bundle's name. Every other field already holds the value this example used.

Click **Run**. The workflow matches the reads, settles any read whose sequence is shared by two species, checks the unmatched clusters for chimeras, and writes a `.lungfish12s` result bundle. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

<!-- SHOT: twelve-s-dialog-options -->

### 4. Read the species table

The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes, here inside `Analyses/12S amplicon results`. Click it to open the 12S viewport. It opens on the **Targets** view, the species table, where each row is one species in one sample. Reading the results below explains each column.

Sort by **Exact Reads** to put the dominant species at the top. The **Filter species or matches** field narrows the table by scientific name, common name, group, taxid, or alternate-match text.

<!-- SHOT: twelve-s-result-species-table -->

Right-click a species row for two lookups at the bottom of the menu. **Learn More About** opens that species' NCBI taxonomy page in your browser, and **View Photo of** opens its Wikipedia article. Both open the browser at once, without asking first, by design.

### 5. Review the unresolved clusters

Click **Unresolved** in the Targets and Unresolved switch at the top of the result. An unresolved cluster is a group of reads that all carry the same sequence and matched no reference record, or matched several species that the abundance rule, explained under Reading the results, could not choose between.

Sort by **Reads**. A cluster with many reads and a Chimera status of Not Detected is the interesting case, because your sample produced that sequence in quantity and it matched nothing you supplied. It is often a species the reference lacks. A [chimera](../../GLOSSARY.md#chimera) is an artifact formed when two real templates join during PCR, so clusters marked Candidate can usually be set aside.

<!-- SHOT: twelve-s-unresolved-clusters -->

### 6. Verify a cluster with BLAST

Select one or more unresolved clusters and click **BLAST Verify** in the action bar along the bottom of the viewport. The button is active only on the Unresolved view. The sequence leaves your Mac for NCBI's servers, so check your laboratory's data-handling rules first. The hits appear in a drawer below the table.

[BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage.

<!-- SHOT: twelve-s-blast-review -->

### 7. Export the table

Click **Export** in the action bar and choose **Export as CSV...**, **Export as TSV...**, or **Export as Excel...**. The Inspector's **12S Results** section ends with an **Export** menu offering the same three formats as **CSV**, **TSV**, and **Excel**. The Excel file carries the unresolved clusters on a second sheet. Every export honours the Inspector filters described in Settings, and all of them are off on a fresh result, so a first export carries every row.

To get the unresolved sequences as FASTA, select two or more clusters on the Unresolved view, right-click, and choose **Copy Sequences**. With one cluster selected, **Copy Sequence** copies the bases without a FASTA name line. The workflow also writes every cluster to `unresolved-sequences.fasta` inside the result bundle, which you reach by right-clicking the result in the sidebar and choosing **Show in Finder**.

<!-- SHOT: twelve-s-export -->

## Settings

The dialog holds eight controls. The Inspector's **12S Results** section holds six more, which change only what the viewport shows and exports, never the stored result.

**Reference.** Names the known 12S sequences every read is matched against, as a deduplicated FASTA or a `.lungfish12sref` bundle. It starts on the first reference bundle LGE finds in the project, or empty if there is none, so check it before you click Run, because this is the choice that decides what can be found. A genome `.lungfishref` bundle is also accepted, so a wrong preselection can still run. Use a reference built for the animals you expect, since a fish-only reference will not name the mammals in a gut sample. On the command line this is `--reference`.

**Analysis Metadata.** Stores a copy of a per-sample CSV or TSV table inside the result, so the viewport can show its fields as extra columns. It starts empty, reading "No analysis metadata selected", because the match does not need it. Supply one, with a `sample_id` column whose values match the read bundle names, when you want collection site or date beside the counts. A column named `sample`, `sample_name`, or `id` works in place of `sample_id`. On the command line this is `--sample-metadata`.

**Read Platform.** Chooses how strict the match is, as a two-way picker. The default is **Illumina exact**, which accepts only reads containing a reference sequence with no changed bases, right for Illumina's very low error rate. Switch to **ONT indel-tolerant** for Oxford Nanopore reads, whose usual error is an inserted or deleted base. On the command line this is `--matching-mode`.

**Result Name.** Names the `.lungfish12s` result bundle. It arrives filled in from the first selected read bundle's name. Change it when that name will not identify the run later. On the command line this is `--output-name`.

**Min Soft Clip.** Sets how many of the read's own bases must sit beyond each end of the matched reference stretch. The default is 1, so a read that only grazes a target, rather than containing it, is rejected. The number field accepts 0 or more. This leftover is a [soft clip](../../GLOSSARY.md#soft-clip). Raise it when partial overlaps give matches you do not trust, and set 0 only when reads may legitimately end exactly at the target's edge. On the command line this is `--min-soft-clip`.

**Max Indels.** Sets how many inserted or deleted bases a read may carry and still match. The default is 3, and the field is greyed out and ignored under Illumina exact, since only the ONT setting allows indels. Raise it for noisier Nanopore chemistry and lower it for stricter matches. It sits inside **Advanced Options**, which opens with the arrow beside its name. On the command line this is `--max-indels`.

**Run vsearch chimera review.** Checks each unresolved cluster for chimeras with vsearch and marks it Not Detected or Candidate. It is ticked by default because a chimera looks like a new species until something checks it. Untick it only to shorten a run whose unresolved clusters you will not read, and every cluster then shows Not Reviewed. It sits inside **Advanced Options**, beside a note that inputs must already be merged. The fixture's single reads already span the whole amplicon, so the note does not apply to them. On the command line this is `--chimera-review`, and `--no-chimera-review` turns it off.

**Directory.** Chooses where the result bundle is written. The default is the project's `Analyses/12S amplicon results` folder, which keeps results inside the project. Change it only when the result belongs elsewhere. On the command line this is `--output-dir`.

The remaining six are Inspector filters. **Minimum Exact Reads**, the **Attributes** pills, and the **Taxon Groups** pills sit under **Target Rows**. **Minimum Unresolved Reads** and **Chimera** sit under **Unmatched Reads**, which starts collapsed. Each filter's flag belongs to the export command, `12s-export`, not to the match.

**Minimum Exact Reads.** Hides species rows with fewer exact reads than this, set with a number field and a stepper. The default is 0, so every row with a read shows. Raise it to drop the one-read and two-read hits that are usually noise. On the command line this is `--min-exact-reads`.

**Exclude Human.** A pill under **Attributes** that hides Homo sapiens rows, matched by that name or by taxid 9606. It is off by default, so human reads show like any other species. Turn it on for diet or environmental work, where human reads are usually contamination from whoever handled the sample, and leave it off for this chapter's example. On the command line this is `--exclude-human`.

**Only With Alternates.** A pill under **Attributes** that shows only species whose matched sequence is shared with another species. It is off by default, so every species shows. Turn it on to review which calls are ambiguous before you report them. On the command line this is `--require-alternate-matches`.

**Taxon Groups.** A row of pills, one per group such as Mammal, Fish, or Bird, that each cycle through neutral, included, and excluded as you click. Every pill starts neutral, which places no limit, so all groups show. Include a group to keep only the included groups, or exclude one to hide it, for example to keep a diet study to fish. On the command line this is `--taxon-group` to keep a group and `--exclude-taxon-group` to drop one.

**Minimum Unresolved Reads.** Hides unresolved clusters with fewer reads than this, in the Unresolved table and the Excel sheet, set with a number field and a stepper. The default is 0, so every cluster shows. Raise it to 2 to skip single-read clusters, which are far more often sequencing error than an unknown species. On the command line this is `--min-unresolved-reads`.

**Chimera.** Limits the unresolved clusters to one verdict, from All, Not Reviewed, Not Detected, Candidate, and Confirmed. The default is All. Choose Not Detected to see only clusters that may be real sequence rather than PCR artifacts. On the command line this is `--chimera-status`.

## Reading the results

The summary line above the table gives four figures, samples, exact reads, percent unresolved, and chimera candidates. The worked example reads:

```text
1 samples | 110 exact reads | 36.4% unresolved | 0 chimera candidates
```

The fixture holds 173 reads. 110 matched exactly and 63 did not, so 36.4 percent are unresolved and 63.6 percent matched. Both figures divide by the same 173 reads, so they add to 100 unless reads were reassigned, as described below. Quote either figure, and say which one it is.

The species table has nine columns. **Sample**, **Scientific Name**, and **Common Names** identify the row. **Group** is the label from the reference metadata, such as Mammal, and **Tax ID** is the NCBI taxid. **Exact Reads** is the number of reads in that sample assigned to the species.

**% of Sample** is the species' exact reads as a percentage of all exact-matched reads in that sample. Unresolved reads are left out of the denominator, which is why a species can hold 100 percent of a sample whose match rate is 63.6 percent. It is the figure to compare across samples, because a deeply sequenced sample yields more reads of everything. A species at 40 percent in one sample and 2 percent in another differs in share, while 100 reads against 10 may only reflect depth.

**Refs** is how many reference records carry that species' name. A species can have several when the reference holds more than one 12S variant for it, and the number is neither good nor bad. **Alternates** is how many other species share the matched sequence. A nonzero value means the name is one of several the evidence allows, so treat that row with more caution and say so in a report.

In the worked example the table shows one row, Homo sapiens, with 110 exact reads and 100.0 percent of the sample. The table lists only species with at least one read, so the chimpanzee, gorilla, and two macaques do not appear. An export, from the window or the command line, still lists them with 0 exact reads. One species holding every matched read while its close relatives hold none is what a single-species sample looks like.

When two species in the reference carry an identical 12S sequence, a read matching it is settled by abundance. LGE gives the read to whichever candidate has more unambiguous reads in that sample, and any lead wins by default, so one read can decide a call. The window has no control for this. On the command line, `--ambiguity-resolution conservative` requires the winner to hold at least twice the runner-up and at least ten reads, and leaves the read unresolved otherwise. Each move is written to `reassignments.tsv` inside the result bundle, and the summary line's exact-read count leaves moved reads out. If your question depends on telling two such species apart, the 12S amplicon cannot do it. The fixture's five sequences are all distinct, so it never triggers.

In the Unresolved view, read **Reads** and **Chimera** together. **Sequence** is a label for the cluster, and **Bases** holds its DNA. **Samples** counts the samples that contributed reads. The worked example has 56 clusters holding 63 reads, all Not Detected. 51 hold one read, four hold two, and one holds four. Many single-read clusters and no chimeras is ordinary noise from reads that overlapped a target without containing it whole.

Click the information button at the right of the action bar for the provenance popover, which gives the analysis name, sample count, exact reads, unmatched percent, and creation time. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

## What good looks like

A healthy run puts its matched reads on a few species and leaves an unresolved tail you can explain.

Judge the match rate against what the reference covers, not against a fixed number. A reference holding every species in the sample should match most reads. The fixture's reference holds five short primate targets, and its 36.4 percent unresolved reads fall in the 12S region without containing a target whole, which is the rule working as designed.

The species table should hold a few rows with large counts. Twenty or more rows, none above a handful of reads, usually means the reference and the sample do not fit each other.

The unresolved tail should be mostly single reads or chimera candidates. One or two large Not Detected clusters are normal and are the ones to send to BLAST. Many large Not Detected clusters mean the reference is missing species, and the fix is to add them and run again.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
# Package the reference and its seven-column metadata as a bundle
lungfish-cli fastq 12s-reference-bundle \
  --dedup-fasta primate-12s-dedup.fasta \
  --midori-metadata primate-12s-midori.tsv \
  --output primate-12s.lungfish12sref --name "Primate 12S"

# Match the merged reads
lungfish-cli fastq 12s-match HG002-12S-oriented.fastq \
  --reference primate-12s.lungfish12sref \
  --output-dir results --output-name HG002-12S-oriented

# Export the species rows, then the unresolved clusters as FASTA
lungfish-cli fastq 12s-export \
  --bundle results/HG002-12S-oriented.lungfish12s \
  --export-format tsv --output species.tsv
lungfish-cli fastq 12s-export-unresolved \
  --bundle results/HG002-12S-oriented.lungfish12s \
  --min-reads 1 --output unresolved.fasta
```

Three differences change results. The help text for `12s-reference-bundle` and `12s-reference-metadata` names only five metadata columns, but both commands stop with a missing-column error unless all seven listed in step 1 are present. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release). `--ambiguity-resolution conservative` exists only here. `12s-export-unresolved` skips clusters under 5 reads by default, so on the fixture it writes an empty file unless you pass `--min-reads 1` as above.

## Next

See [BLAST Verification](06-blast-verification.md) for checking an unresolved cluster against NCBI, or return to [What Is Read Classification](01-what-is-classification.md) for how 12S matching sits beside the taxonomic classifiers.

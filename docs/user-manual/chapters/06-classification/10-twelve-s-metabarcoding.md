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
  - "Tools > Workflows > Workflow Library..."
  - "Tools > Classification > 12S Amplicon Matching..."
  - "CLI: lungfish-cli fastq 12s-match"
shots:
  - id: twelve-s-workflow-library
    caption: "The Workflow Library window with the 12S Amplicon Matching card under Specialized Workflows and its Classification heading, showing its Specialized badge, its dependency row for the Third-Party Tools pack, and the Enabled switch."
  - id: twelve-s-dialog-inputs
    caption: "The Workflow Operations dialog on 12S Amplicon Matching, showing the Reference picker with its Create 12S Reference... button, the Analysis Metadata picker with its Choose Metadata... button, and the FASTQ Bundles list."
  - id: twelve-s-dialog-options
    caption: "The same dialog's Read Platform segmented picker, Result Name field, and Min Soft Clip number field, with the Advanced Options disclosure expanded to show Max Indels, Run vsearch chimera review, and the note that inputs are FASTQ files or bundles of merged reads, unmerged pairs or both."
  - id: twelve-s-result-species-table
    caption: "The 12S viewport on its Targets view for the SIMULATED-12S-mixture-oriented reads, showing three rows, Homo sapiens with 1,235 exact reads and 68.0% of Sample, Macaca mulatta with 491 and 27.0% and Alternates 1, and Macaca fascicularis with 91 and 5.0%, under the Sample, Scientific Name, Common Names, Group, Tax ID, Exact Reads, % of Sample, Refs, and Alternates columns."
  - id: twelve-s-unresolved-clusters
    caption: "The viewport's Unresolved view, showing the Sequence, Reads, Samples, Chimera, and Bases columns for the clusters that matched no reference."
  - id: twelve-s-blast-review
    caption: "An unresolved cluster sent to NCBI BLAST with the BLAST Verify button, with the returned Organism, Identity, and Accession hits in the drawer below the table."
  - id: twelve-s-export
    caption: "The viewport's Export menu offering Export as CSV..., Export as TSV..., and Export as Excel..."
illustrations: []
glossary_refs: [amplicon, blast, bundle, checksum, chimera, deduplicated-reference, fastq, inspector, metabarcoding, provenance, read, read-orientation, orient-reads, required-setup-pack, soft-clip, taxonomy-id, twelve-s, vsearch, workflow-library, relative-abundance, contamination, lowest-common-ancestor]
features_refs: [classify.twelve-s]
fixtures_refs: [primate-12s]
brand_reviewed: false
lead_approved: false
---

## What it is

[12S metabarcoding](../../GLOSSARY.md#metabarcoding) identifies which vertebrate species are present in a mixed sample. The [12S](../../GLOSSARY.md#twelve-s) ribosomal RNA gene sits in the mitochondrial genome, the small loop of DNA every animal cell carries outside its nucleus. Primers, short synthetic DNA pieces that mark where copying starts, bind sites that are the same across vertebrates and copy a short slice of the gene by PCR. That slice is an [amplicon](../../GLOSSARY.md#amplicon), a defined stretch of DNA amplified between two known primer sites. The primer sites are shared, but the bases between them differ from species to species, so reading the interior tells you which animal the DNA came from. Metabarcoding sequences that one marker across a whole mixed sample, so the answer is a roster of species rather than a single name.

Lungfish Genome Explorer (LGE) resolves a 12S run by exact matching. Each [read](../../GLOSSARY.md#read), the record a sequencer writes for one DNA fragment, is checked against a [deduplicated reference](../../GLOSSARY.md#deduplicated-reference). That is a FASTA file, a plain-text list of named sequences, where each record is one known 12S sequence labelled with its species and identical sequences have been collapsed so each appears once.

The matching rule is one sentence. Each reference record is a short target stretch, shorter than the reads. A reference record must appear inside the read as an unbroken run of identical bases, with at least one of the read's own bases left over at each end, and the read is then assigned to that record's species. A species missing from the reference can never be reported, however many reads it contributed, so the reads that match nothing are kept aside for you to review.

## Why you would do this

Run 12S matching when your sample is a mixture and the question is which vertebrates are in it. A gut-content sample, a water sample, a swab from a surface, or a pooled field collection all carry DNA from several animals at once. So can a primate facility's environmental swab, which may hold human DNA from the people who handle the animals beside rhesus and cynomolgus macaque DNA from the animals themselves.

A broad classifier cannot answer this question, for the reason [What Is Read Classification](01-what-is-classification.md#the-tools) gives. Kraken 2's Standard database holds no vertebrate but human, so a macaque read has nowhere to go but a human or primate row. A marker gene matched against a reference built for the animals you expect is the tool that fits. Exact matching adds a second benefit. Where a broad classifier steps back to a genus, the [lowest common ancestor](../../GLOSSARY.md#lowest-common-ancestor) of the candidates, when the evidence is thin, exact matching refuses to guess. A read either contains a known 12S sequence or it does not, so each species on the roster is one the reads really name.

This chapter works through a SIMULATED mixture of human, rhesus macaque, and cynomolgus macaque 12S reads. Simulated means the reads were generated by a computer program from the three species' published mitochondrial genomes, copying each species' amplicon with a small rate of random base errors, rather than sequenced from a real sample. No public 12S run holds human and macaque reads at proportions anyone knows, so a simulation is the only way to give you a mixture whose true answer is known to the read. The truth is 1,400 human reads, 500 rhesus reads, and 100 cynomolgus reads, 70, 25, and 5 percent of 2,000. A real library adds PCR bias, chimeras, and sequencing error that this one lacks, so treat it as a check of how the tool reads a mixture, not of how a real mixture behaves.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the 12S Metabarcoding demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds two read bundles, `SIMULATED-12S-mixture-oriented` and `HG002-12S-oriented`, and keeps the reference FASTA and its species table as files under `Practice Data/primate-12s`, where the procedure picks them. To import the files yourself instead, follow the rest of this section.

This chapter uses the primate 12S fixture. Download `primate-12s-dedup.fasta`, `primate-12s-midori.tsv`, `SIMULATED-12S-mixture-oriented.fastq.gz`, and `HG002-12S-oriented.fastq` from [the primate-12s fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/primate-12s), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The first file is the deduplicated reference, six primate 12S sequences of 60 bases each cut from public mitochondrial genomes. The second labels each reference sequence with its species. The third holds the simulated mixture, and the fourth holds real 12S reads from HG002, a public reference human sample, used later as a single-species contrast. The fixture's README records how every file was made. Import the two read files into the project as read bundles, following [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

The matcher reads one strand only. Orienting flips every read so that all of them run in the same direction along the gene, and [Orienting reads](../03-reads/08-read-processing.md#orienting-reads) shows how to do it for short amplicon reads against a 12S reference. Orient your own reads before you match them. They may be merged or single reads, unmerged pairs, or both. Merging joins the two overlapping [mates](../../GLOSSARY.md#mate) of a pair into one read that spans the amplicon, as [Merging the overlapping pairs](../03-reads/08-read-processing.md#merging-the-overlapping-pairs) shows, and it is not required. A merged or single read counts once, and so does an unmerged pair whose two mates agree, as [Fragments and unmerged pairs](#fragments-and-unmerged-pairs) explains. A pair whose mates disagree counts nowhere, which is what becomes of a pair with an error inside the target on one mate. Both fixture read sets are already oriented single reads that each span the whole amplicon, so there is nothing to merge.

12S Amplicon Matching is a specialized workflow, so **Tools > Classification** shows it as **Enable 12S Amplicon Matching...** until you turn it on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows. Its chimera check uses [vsearch](../../GLOSSARY.md#vsearch), a sequence-comparison program that arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE.

<!-- SHOT: twelve-s-workflow-library -->

Six of this workflow's settings live in the Inspector rather than the run dialog. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Every run in this chapter takes under a second.

## Procedure

### Build a 12S reference bundle

The workflow takes its reference in either of two forms. A plain deduplicated FASTA works, and you can point a run at it directly. A `.lungfish12sref` bundle holds the sequences and their species table together, and only the bundle fills the species table's Tax ID and Group columns for every species. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. This chapter builds the bundle, because a roster without taxonomy IDs is harder to report.

Choose **Tools > Classification > 12S Amplicon Matching...** and click **Create 12S Reference...** beside the Reference picker. The sheet asks for a **Name**, the **Deduplicated FASTA**, the **Target Metadata** table, and an **Output Bundle**, which defaults to `12S reference.lungfish12sref` in the project's `Reference Sequences` folder. A **Source Files** row and a **Replace Existing Bundle** checkbox sit below them. Type `Primate 12S` as the name, pick `primate-12s-dedup.fasta` and `primate-12s-midori.tsv` from `Practice Data/primate-12s`, and create the bundle.

Each FASTA name line must read as a common name followed by the scientific name in parentheses, for example `>Rhesus macaque (Macaca mulatta)`. One of the fixture's six records carries a second species after the name, `>Rhesus macaque (Macaca mulatta)|also_matches=Japanese macaque (Macaca fuscata)`, because its 60 bases occur in both macaques. That is how a deduplicated reference records a sequence two species share, and it is the source of the Alternates figure you read later. The metadata table is a tab-separated file in the MIDORI style, named after a public database of animal mitochondrial marker sequences. It needs all seven of these columns:

```text
seq_id  common_name  latin_name  group  taxid  name_source  taxonomy
```

The `taxid` column holds the [taxonomy ID](../../GLOSSARY.md#taxonomy-id), the number NCBI's taxonomy database gives each species, and `group` holds a label such as Mammal or Fish. LGE joins each FASTA record to its metadata row by the scientific name inside the parentheses. A name line without parentheses, such as `>Homo_sapiens`, joins to nothing, and the reference is still written with empty common name, taxid, group, and taxonomy fields and no warning, so check that a reference you built carries species names. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

### Set the inputs and run the match

Choose **Tools > Classification > 12S Amplicon Matching...** again if the dialog closed. The Workflow Operations dialog opens with the workflow selected, laid out as [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

1. Under **Reference**, open the **Project Reference** menu and choose the bundle you built. The menu lists it by its path, `Reference Sequences/12S reference.lungfish12sref`, not by the name you typed. It lists only reference bundles already saved in the project, and **Choose...** picks a plain FASTA instead.
2. Leave **Analysis Metadata** reading "No analysis metadata selected". The fixture does not need it.
3. Under **FASTQ Bundles**, make sure only the `SIMULATED-12S-mixture-oriented` bundle is listed.
4. Leave **Read Platform** on **Illumina exact**. **Result Name** arrives filled in from the read bundle's name, and every other field already holds the value this example used.
5. Click **Run**, and watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

<!-- SHOT: twelve-s-dialog-inputs -->

The workflow matches the reads, settles any read whose sequence is shared by two species, checks the unmatched clusters for chimeras, and writes a `.lungfish12s` result bundle. Any read bundle works as input, including a [virtual bundle](../../GLOSSARY.md#virtual-bundle) such as one barcode of a demultiplex, whose reads LGE rebuilds first. A bundle that holds only its preview, with its full reads missing, is refused with a message to re-import the FASTQ file. Two inputs that would share a sample name, such as `barcode01` bundles from two folders, are refused before anything is written, with a line that names both. Selecting two or more read bundles adds a **Run Mode** choice, fixed on "Combine all inputs, run once (1 result)" with the note "They will run as one batch." One result does not mean one pooled sample. LGE counts every bundle as its own sample, with its own rows.

<!-- SHOT: twelve-s-dialog-options -->

### Read the species table

The result lands in `Analyses/12S amplicon results`, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Click it to open the 12S viewport. It opens on the **Targets** view, the species table, where each row is one species in one sample. [Reading the results](#reading-the-results) explains each column.

Sort by **Exact Reads** to put the dominant species at the top. The **Filter species or matches** field narrows the table by scientific name, common name, group, taxid, or alternate-match text.

<!-- SHOT: twelve-s-result-species-table -->

Right-click a species row for two lookups at the bottom of the menu. **Learn More About** opens that species' NCBI taxonomy page in your browser, and **View Photo of** opens its Wikipedia article. Both open the browser at once, without asking first, by design.

### Review the unresolved clusters

Click **Unresolved** in the Targets and Unresolved switch at the top of the result. An unresolved cluster is a group of reads that all carry the same sequence and matched no reference record, or matched several species that the abundance rule, explained under Reading the results, could not choose between.

Sort by **Reads**. A cluster with many reads and a Chimera status of Not Detected is the interesting case, because your sample produced that sequence in quantity and it matched nothing you supplied. It is often a species the reference lacks. A [chimera](../../GLOSSARY.md#chimera) is an artifact formed when two real templates join during PCR, so clusters marked Candidate can usually be set aside.

<!-- SHOT: twelve-s-unresolved-clusters -->

### Verify a cluster with BLAST

Select one or more unresolved clusters and click **BLAST Verify** in the action bar along the bottom of the viewport. The button is active only on the Unresolved view. The sequence leaves your Mac for NCBI's servers, so check your laboratory's data-handling rules first. The hits appear in a drawer below the table, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage.

<!-- SHOT: twelve-s-blast-review -->

### Export the table

Click **Export** in the action bar and choose **Export as CSV...**, **Export as TSV...**, or **Export as Excel...**. The Inspector's **12S Results** section ends with an **Export** menu offering the same three formats as **CSV**, **TSV**, and **Excel**. The Excel file carries the unresolved clusters on a second sheet. Every export honours the Inspector filters described in Settings, and all of them are off on a fresh result, so a first export carries every row.

To get the unresolved sequences as FASTA, select two or more clusters on the Unresolved view, right-click, and choose **Copy Sequences**. With one cluster selected, **Copy Sequence** copies the bases without a FASTA name line. The workflow also writes every cluster to `unresolved-sequences.fasta` inside the result bundle, which you reach by right-clicking the result in the sidebar and choosing **Show in Finder**. The viewport has no **Extract FASTQ** button, because the matched reads are a roster rather than a set you would map or assemble.

<!-- SHOT: twelve-s-export -->

## Settings

The dialog holds eight controls. The Inspector's **12S Results** section holds six more, which change only what the viewport shows and exports, never the stored result.

**Reference.** Names the known 12S sequences every read is matched against, as a deduplicated FASTA or a `.lungfish12sref` bundle. It starts on the first reference bundle LGE finds in the project, or empty if there is none, so check it before you click Run, because this is the choice that decides what can be found. A genome `.lungfishref` bundle is also accepted, so a wrong preselection can still run. Use a reference built for the animals you expect, since a fish-only reference will not name the mammals in a gut sample. On the command line this is `--reference`.

**Analysis Metadata.** Stores a copy of a per-sample CSV or TSV table inside the result, so the viewport can show its fields as extra columns. It starts empty, reading "No analysis metadata selected", because the match does not need it. Supply one, with a `sample_id` column whose values match the read bundle names, when you want collection site or date beside the counts. A column named `sample`, `sample_name`, or `id` works in place of `sample_id`. On the command line this is `--sample-metadata`.

**Read Platform.** Chooses how strict the match is, as a two-way picker. The default is **Illumina exact**, which accepts only reads containing a reference sequence with no changed bases, right for Illumina's very low error rate. Switch to **ONT indel-tolerant** for Oxford Nanopore reads, whose usual error is an inserted or deleted base. On the command line this is `--matching-mode`.

**Result Name.** Names the `.lungfish12s` result bundle. It arrives filled in from the first selected read bundle's name. Change it when that name will not identify the run later. On the command line this is `--output-name`.

**Min Soft Clip.** Sets how many of the read's own bases must sit beyond each end of the matched reference stretch. The default is 1, so a read that only grazes a target, rather than containing it, is rejected. The number field accepts 0 or more. This leftover is a [soft clip](../../GLOSSARY.md#soft-clip). Raise it when partial overlaps give matches you do not trust, and set 0 only when reads may legitimately end exactly at the target's edge. On the command line this is `--min-soft-clip`.

**Max Indels.** Sets how many inserted or deleted bases a read may carry and still match. The default is 3, and the field is greyed out and ignored under Illumina exact, since only the ONT setting allows indels. Raise it for noisier Nanopore chemistry and lower it for stricter matches. It sits inside **Advanced Options**, which opens with the arrow beside its name. On the command line this is `--max-indels`.

**Run vsearch chimera review.** Checks each unresolved cluster for chimeras with vsearch and marks it Not Detected or Candidate. It is ticked by default because a chimera looks like a new species until something checks it. Untick it only to shorten a run whose unresolved clusters you will not read, and every cluster then shows Not Reviewed. It sits inside **Advanced Options**, beside a note that inputs are FASTQ files or bundles of merged reads, unmerged pairs or both, and that a merged read counts once, as does an unmerged pair whose mates agree. On the command line this is `--chimera-review`, and `--no-chimera-review` turns it off.

**Directory.** Chooses where the result bundle is written. The default is the project's `Analyses/12S amplicon results` folder, which keeps results inside the project. Change it only when the result belongs elsewhere. On the command line this is `--output-dir`.

The remaining six are Inspector filters. **Minimum Exact Reads**, the **Attributes** pills, and the **Taxon Groups** pills sit under **Target Rows**. **Minimum Unresolved Reads** and **Chimera** sit under **Unmatched Reads**, which starts collapsed. Each filter's flag belongs to the export command, `12s-export`, not to the match. For a result that read unmerged pairs, the labels say Fragments where they say Reads here, such as **Minimum Exact Fragments** and **Unmatched Fragments**, as [Fragments and unmerged pairs](#fragments-and-unmerged-pairs) explains.

**Minimum Exact Reads.** Hides species rows with fewer exact reads than this, set with a number field and a stepper. The default is 0, so every row with a read shows. Raise it to drop the one-read and two-read hits that are usually noise. On the command line this is `--min-exact-reads`.

**Exclude Human.** A pill under **Attributes** that hides Homo sapiens rows, matched by that name or by taxid 9606. It is off by default, so human reads show like any other species. Turn it on for diet or environmental work, where human reads are usually [contamination](../../GLOSSARY.md#contamination) from whoever handled the sample, and leave it off for this chapter's example, where human is one of the species you are looking for. On the command line this is `--exclude-human`.

**Only With Alternates.** A pill under **Attributes** that shows only species whose matched sequence is shared with another species. It is off by default, so every species shows. Turn it on to review which calls are ambiguous before you report them. On the command line this is `--require-alternate-matches`.

**Taxon Groups.** A row of pills, one per group such as Mammal, Fish, or Bird, that each cycle through neutral, included, and excluded as you click. Every pill starts neutral, which places no limit, so all groups show. Include a group to keep only the included groups, or exclude one to hide it, for example to keep a diet study to fish. On the command line this is `--taxon-group` to keep a group and `--exclude-taxon-group` to drop one.

**Minimum Unresolved Reads.** Hides unresolved clusters with fewer reads than this, in the Unresolved table and the Excel sheet, set with a number field and a stepper. The default is 0, so every cluster shows. Raise it to 2 to skip single-read clusters, which are far more often sequencing error than an unknown species. On the command line this is `--min-unresolved-reads`.

**Chimera.** Limits the unresolved clusters to one verdict, from All, Not Reviewed, Not Detected, Candidate, and Confirmed. The default is All. Choose Not Detected to see only clusters that may be real sequence rather than PCR artifacts. On the command line this is `--chimera-status`.

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
| Macaca mulatta | Rhesus macaque | 9544 | 491 | 27.0% | 2 | 1 |
| Macaca fascicularis | Cynomolgus macaque | 9541 | 91 | 5.0% | 1 | 0 |

The table lists only species with at least one read, so the chimpanzee and gorilla do not appear. An export, from the window or the command line, still lists them with 0 exact reads. Every row carries Group Mammal. The rhesus row carries two taxonomy IDs in an export, 9544 for the rhesus macaque and 9542 for the Japanese macaque it shares a sequence with, and its Other Potential Matches column names Japanese macaque (*Macaca fuscata*).

### Checking the roster against the truth

Because the mixture is simulated, you can check each figure against the answer. The truth was 1,400 human, 500 rhesus, and 100 cynomolgus reads. Every exact match went to the species its read was made from, so the matcher named no species wrongly. What differs is how many reads of each species matched at all. 1,235 of 1,400 human reads matched, 88.2 percent. 491 of 500 rhesus reads matched, 98.2 percent, and 91 of 100 cynomolgus reads matched.

The difference comes from the reference. A read matches only when its copy of a 60-base target carries no error, and the simulation put random errors into every species at the same low rate. The rhesus macaque has two targets in this reference, so a rhesus read with an error in one target can still match the other, while each other species has one. That extra chance is why the shares came out at 68.0, 27.0, and 5.0 percent against a truth of 70, 25, and 5. A real run behaves the same way, and a species with more reference records, or longer ones, is more likely to be counted. Read % of Sample as a close estimate of each species' share, not as an exact count of the DNA in the tube.

### Alternates and the abundance rule

The rhesus row's Alternates of 1 comes from the one record the rhesus macaque shares with the Japanese macaque. 48 of the 491 rhesus reads matched that shared record, and 443 matched the rhesus-only record. The reads on the shared record could in principle have come from either macaque. The roster names rhesus because the shared record carries the rhesus name, and the Alternates column is how the table admits the other possibility. Nothing in this sample supports a Japanese macaque, because no read matched a record unique to it. In a real sample, an alternate becomes a question only when the reads that name it all sit on shared records.

When two species in the reference carry an identical 12S sequence under two separate records, a read matching it is settled by abundance. LGE gives the read to whichever candidate has more unambiguous reads in that sample, and any lead wins by default, so one read can decide a call. The window has no control for this. On the command line, `--ambiguity-resolution conservative` requires the winner to hold at least twice the runner-up and at least ten reads, and leaves the read unresolved otherwise. Each move is written to `reassignments.tsv` inside the result bundle, and the summary line's exact-read count leaves moved reads out. The fixture never triggers the rule, because its shared record is one record under one name rather than two, so `reassignments.tsv` stays empty. If your question depends on telling two such species apart, the 12S amplicon cannot do it.

### The unresolved clusters

In the Unresolved view, read **Reads** and **Chimera** together. **Sequence** is a label for the cluster, and **Bases** holds its DNA. **Samples** counts the samples that contributed reads. The simulated mixture has 143 clusters holding 183 reads, all Not Detected. 108 hold one read, 30 hold two, and 5 hold three. Many single-read clusters and no chimeras is ordinary noise, here from reads whose copy of a target carried a simulated error, so they overlapped a target without containing it whole.

### Fragments and unmerged pairs

12S matching counts fragments, the DNA molecules the library copied, rather than records. A merged read, a read whose mate is missing, and a read from a single-end run each count once. A pair that was not merged counts once when both of its mates give the identical call, which means the same reference record, the same set of candidate records, or no match at all. The second mate is read as its reverse complement, so that it runs along the same strand as the first, and the pair then counts as its first mate, toward a species, toward the abundance rule, or toward an unresolved cluster. Such a cluster shows the first mate's sequence, and its row in `unresolved-sequences.tsv` carries the note `unmerged pairs, R1 shown`, or `merged reads and unmerged pairs` when merged reads share it.

A read whose mate is missing is read as its reverse complement as well when its name marks it as the second mate, with `/2` or an Illumina comment that starts `2:`, unless its file holds merged reads or the reads come from a Nanopore or PacBio run. So a file of second mates matched on its own counts on the forward strand of its fragments. Names that end `.1` and `.2`, the way the SRA numbers single reads, are read as sequenced. In a bundle that keeps its mates in separate R1 and R2 files, mates named with `/1` and `/2`, with Illumina comments, or with `.1` and `.2` or `_1` and `_2` after one shared name are read as pairs. Mates whose names carry no mate number are paired by position, with a warning in the Operations Panel row, and mates whose numbers contradict each other stop the run.

A pair whose mates disagree is left out of every count except the sample's input total, and tallied by its reason.

| Reason | What the two mates did |
|---|---|
| different targets | Each matched one reference record exactly, and the records differ |
| different candidates | Each matched several records, and the two sets differ |
| one mate unresolved | One gave a call and the other matched nothing |
| one mate ambiguous | One matched a single record and the other matched several |

When a run read unmerged pairs, the viewport and the Inspector call its counts fragments. The summary line reads exact fragments, the tables' count columns read **Exact Fragments** and **Fragments**, the provenance popover and the Inspector say Exact Fragments, the Inspector's filters read **Minimum Exact Fragments**, **Unmatched Fragments** and **Minimum Unresolved Fragments**, and Copy Rows uses the same headings. A result from merged or single reads alone keeps the reads wording this chapter shows. The tables that **Export** writes keep the headings Exact Reads and Reads whatever the run read, so read those columns as fragments for a run of pairs. `read-fate.json` records the number of pairs a run read as `pairedFragments`, 0 for merged or single reads alone.

When a run leaves pairs out, the summary line ends with a figure such as "2 discordant pairs left out (1 pair with different targets, 1 pair with one mate unresolved)", the provenance popover adds a Left Out row, and `samples.tsv` and `read-fate.json` inside the result bundle record the count. The Operations Panel row logs the count as the run goes, for example "Counted 8 fragments, 4 merged or single reads and 4 pairs. Left out 2 discordant pairs (1 pair with different targets, 1 pair with one mate unresolved)." The fixture holds no pairs, so its figures are the ones above and its summary line has no left-out figure. Results from merged reads alone count exactly as they did before LGE counted fragments.

### A single-species contrast and an unoriented run

Run the same match on the `HG002-12S-oriented` bundle, 186 real human reads, and the table shows one row, Homo sapiens, with 110 exact reads and 100.0 percent of the sample. The summary line reads 40.9 percent unresolved, and the Unresolved view holds 69 clusters of 76 reads, 64 of them single reads. The reads came from a whole-mitochondrion library rather than an amplicon library, so many of them cover the 12S region without containing a target whole, which is the rule working as designed. One species holding every matched read while its close relatives hold none is what a single-species sample looks like.

The demo project also keeps the mixture before orientation, `SIMULATED-12S-mixture.fastq.gz` under `Practice Data/primate-12s`, in which about half the reads run along the opposite strand. Import and match it, and only 935 of the 2,000 reads match, with 53.3 percent unresolved. The Unresolved view then opens on three large clusters of 448, 153, and 32 reads, the reverse-strand copies of the human, rhesus, and cynomolgus amplicons. That is the signature of an unoriented run, and orienting the reads first is the fix.

Click the information button at the right of the action bar for the provenance popover, which gives the analysis name, sample count, exact reads, unmatched percent, and creation time.

## What good looks like

The 12S viewport answers two questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) on screen. Exact Reads says how many reads support each species, and Alternates says whether another species could explain the same reads. Controls are yours to add, and BLAST Verify answers the last question for the unresolved sequences.

A healthy run puts its matched reads on a few species and leaves an unresolved tail you can explain. Judge the match rate against what the reference covers, not against a fixed number. A reference holding every species in the sample should match most reads, as the simulated mixture's 90.85 percent shows. A lower rate needs an explanation, such as the HG002 reads' whole-mitochondrion origin or an unoriented run.

The species table should hold a few rows with large counts. Twenty or more rows, none above a handful of reads, usually means the reference and the sample do not fit each other.

A row with a nonzero Alternates count is a species the evidence allows rather than one it proves. Report it with its alternate named, as the rhesus row's Japanese macaque shows.

The unresolved tail should be mostly single reads or chimera candidates. One or two large Not Detected clusters are normal and are the ones to send to BLAST. Many large Not Detected clusters mean the reference is missing species, or, when the clusters are the reverse complements of your targets, that the reads were not oriented. The result's provenance record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, holds the reference and settings for a methods section.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of these commands is listed in [12S amplicon matching](../appendices/cli-reference.md#12s-amplicon-matching) in the CLI Reference.

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

The second line stores the practice-data folder in a variable named `DATA`, and `RESULT` later stores the result bundle, in the same way as `PROJECT`. Three differences change results. The help text for `12s-reference-bundle` and `12s-reference-metadata` names only five metadata columns, but both commands stop with a missing-column error unless all seven listed in the procedure are present. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release). `--ambiguity-resolution conservative` exists only here, and gives the same counts on the simulated mixture. `12s-export-unresolved` skips clusters under 5 reads by default, so on the mixture it writes an empty file unless you pass `--min-reads 1` as above, which writes all 143 clusters.

`12s-match` takes read bundles as well as FASTQ files, and it reads the pairs of a bundle as pairs. Two loose files named as the R1 and R2 of one sample are two samples of single reads to it, so import such a pair as one bundle first. A file named inside a bundle, such as a merge bundle's `merged.fastq`, is read alone, without the rest of its bundle, while the preview file of a virtual bundle stands for its bundle, with a note that says so. With `--force` the earlier result stays in place, hidden in the output folder, until the new one is complete, and comes back if the run fails. If it cannot be moved back, the error ends by saying where it waits, a hidden folder whose name starts with `.` and the result's name, and renaming that folder to `<name>.lungfish12s` restores it.

## Next

Continue to [Running Freyja](07-running-freyja.md), which returns to the SARS-CoV-2 run from [Running EsViritu](03-running-esviritu.md) and estimates which lineages its reads hold, a mixture question of a different kind. [BLAST Verification](06-blast-verification.md) covers checking an unresolved cluster against NCBI, and [What Is Read Classification](01-what-is-classification.md) sets 12S matching beside the taxonomic classifiers.

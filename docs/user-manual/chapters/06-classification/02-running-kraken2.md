---
title: Running Kraken2
chapter_id: 06-classification/02-running-kraken2
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 10
task: Classify reads with Kraken2 and read the resulting taxonomy viewport.
tags: [classification, kraken2, taxonomy, sunburst]
tools: [kraken2]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Classification…"
  - "CLI: lungfish conda classify"
shots: []
planned_shots:
  - id: kraken2-wizard
    caption: "The Classification wizard with Kraken2 selected, showing the database picker and the FASTQ bundle input."
  - id: kraken2-plugin-manager
    caption: "Plugin Manager with the Kraken2 Viral database listed as installed."
  - id: kraken2-taxonomy-viewport
    caption: "Taxonomy viewport after classifying SRR36291587, with the sunburst at top, table below, and Riboviria highlighted."
  - id: kraken2-drilldown-coronaviridae
    caption: "Sunburst drilled into Coronaviridae after a click, with the breadcrumb bar showing the path."
  - id: kraken2-extract-reads
    caption: "Right-click menu on a taxon row, with Extract Reads as FASTQ Bundle selected."
illustrations: []
glossary_refs: [FASTQ, plugin pack, conda]
features_refs: []
fixtures_refs: [SRR36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Kraken2 is a fast k-mer-based classifier that assigns each read to a
taxonomic node by exact k-mer matching against a database. Lungfish labels
the tool "Classify & Profile (Kraken2)", because it runs Kraken2 to assign
the reads and then Bracken to estimate community abundance from those
assignments. You launch it from the run wizard, choosing a FASTQ bundle and
a Kraken2 database. The result lands as a taxonomy bundle in the project and
opens in the taxonomy viewport: a sunburst on the left, a sortable table on
the right, and a breadcrumb bar naming the selected taxon.

The k-mer in "k-mer-based" is a short fixed-length substring of a read, 35
bases by default in Kraken2. The classifier slides a window across each
read, looks up every k-mer in the database, and assigns the read to the
lowest taxonomic node the matches will support. Because every lookup is
exact-match, Kraken2 is quick: a million reads against the Viral database
finish in seconds on a laptop. The catch is that Kraken2 sees only what its
database holds. Reads from a virus the database has never met either settle
at a higher, less specific node or fail to classify at all.

In practice: pick a database that fits your question, run it, read both the
per-read assignments and the Bracken abundance estimates, and treat any
single hit as a hypothesis to verify rather than a final identification.

### Database choices

Kraken2 databases are pre-built indexes that ship separately from the
classifier. The choice matters: a database that omits your organism cannot
identify it, and a database that carries too much wastes disk and memory.
Lungfish manages databases through the Plugin Manager, which downloads each
one as a plugin pack and registers it with the Classification wizard.

| Database | Size on disk | Minimum RAM to plan | Scope | Use when |
|---|---|---|---|---|
| Viral | ~0.5 GB | 1 GB | Viral RefSeq genomes only | You expect a viral signal and want a fast, lightweight classification |
| Standard-8 | ~8 GB | 8 GB | Standard database capped by minimizer-space subsampling | You are on a 16 GB Mac and want a broader screen than Viral |
| Standard-16 | ~16 GB | 16 GB | Standard database capped less aggressively | You have at least 16 GB RAM and want the default laptop-friendly broad screen |
| Standard | ~67 GB | 67 GB | Archaea, bacteria, viruses, plasmid, human, UniVec | You are doing general microbiome or contamination screening on a workstation with enough RAM |
| PlusPF-8 / PlusPF-16 | ~8-16 GB | 8-16 GB | PlusPF capped for smaller machines | You want protozoa and fungi represented on a laptop-class machine |
| PlusPF | ~72 GB | 72 GB | Standard plus protozoa and fungi | You want eukaryotic pathogens included, and have enough RAM available |
| Custom | varies | At least the uncompressed index size plus working headroom | User-built from selected RefSeq taxa | None of the above match your sample and you have built (or imported) your own index |

Kraken2 loads the whole database into memory at run time, so RAM, not disk,
is the binding constraint. The full Standard and PlusPF builds will not run
on a laptop with 16 GB of memory. On a 16 GB Mac, the capped Standard-8,
Standard-16, and PlusPF builds are your broader-than-Viral path, and Viral
itself fits comfortably on any modern Mac. When RAM falls short of the
database requirement, Lungfish can fall back to Kraken2 memory mapping where
supported, but the run crawls compared with an in-RAM classification.

### What "hit confidence" means in Kraken2

Each read in the Kraken2 output carries a confidence score built from the
fraction of its k-mers that mapped to the assigned taxon. This is a k-mer
match confidence: of the k-mers in this read, what fraction agree with the
assignment? It is not a BLAST e-value, which asks how unlikely an alignment
is by chance against the search space. A read with 100% k-mer agreement to
one Kraken2 reference can still make a poor BLAST hit when that reference is
itself short or divergent. Treat Kraken2 confidence as an internal
consistency check, not as proof the read is biologically what the label
says. When a hit matters, verify it with BLAST. See [BLAST
Verification](06-blast-verification.md).

## What you will learn

Work through this chapter and you will be able to install a Kraken2
database, run the wizard with Kraken2 selected, set the Sensitivity preset,
navigate the taxonomy viewport, drill into a taxon by clicking the sunburst,
and extract the reads assigned to a taxon as a new FASTQ bundle. You will
also know the headless CLI form and when to build a custom database.

## Procedure

### 1. Install a Kraken2 database

The first time you run Kraken2 in Lungfish, the wizard's database picker is
empty. Open the Plugin Manager from `Tools > Plugin Manager…` (Cmd-Shift-B),
find the Kraken2 row, and click **Install** next to the database scope you
want. For a worked example on a viral sample, start with the Viral database:
it downloads in under a minute on a typical home connection and runs on any
Mac.

The Plugin Manager fetches the index from the Kraken2 maintainers' public
mirror, verifies its checksum, and installs it under the Lungfish conda root
at `~/.lungfish/conda`. When the row turns green and shows a size, the
database is ready; the same row reports the install date and update status.
From the CLI, run `lungfish conda db info Viral`, or swap `Viral` for the
database name you installed, to see the local version, install date,
available update, disk path, and RAM requirement.

<!-- planned: kraken2-plugin-manager -->

### 2. Open the run wizard

With a FASTQ bundle selected in the project sidebar, open
`Tools > FASTQ/FASTA Operations > Classification…`. It is one menu item, not
a submenu. The run wizard appears. In the **Classifier** picker, choose
**Kraken2**. The wizard reshapes itself around Kraken2's options: a
**Sensitivity** preset picker (Sensitive, Balanced, or Precise; default
Balanced), a **Database** dropdown listing every Kraken2 database registered
through the Plugin Manager, and an Advanced section holding a **Confidence**
threshold (default 0.2) and a **Minimum hit groups** field (default 2).

The Sensitivity preset is the simple control. Balanced suits most samples.
Sensitive recovers more low-abundance hits and pays for them in false
positives; Precise does the reverse. The Advanced thresholds are the
underlying knobs those presets turn, exposed for fine control. Confidence
asks what fraction of a read's k-mers must agree before Kraken2 keeps the
assignment, so a higher value is stricter. On a first run, leave the preset
on Balanced and the thresholds at their defaults. They filter the output
rather than shape the search, and you can re-filter the table inside the
viewport without rerunning the classifier.

<!-- planned: kraken2-wizard -->

### 3. Pick the input FASTQ and the database

The **Input FASTQ** field is pre-filled with whatever bundle was selected
when you opened the wizard. To change it, click the picker and choose
another bundle from the project. Paired-end reads are detected
automatically: when the bundle holds a `_R1`/`_R2` pair, both files feed the
same Kraken2 run.

In the **Database** dropdown, choose **Viral** for the worked example
below. Click **Run**.

### 4. Watch the run in the Operations Panel

Kraken2 runs as a background operation. The Operations Panel (open it with
`Cmd-Shift-P` if hidden) shows a progress row labelled `Kraken2:
<bundle>`. A few hundred thousand reads against the Viral database take
under a minute. The row turns green when the classification finishes, and a
new taxonomy bundle appears in the sidebar under the source FASTQ.

## Worked example: classifying SRR36291587

The fixture `SRR36291587` is a SARS-CoV-2 wastewater FASTQ that ships with
the Lungfish documentation tests. {{ fixtures_refs[] | cite }}

Open the project holding the SRR36291587 import and select the FASTQ bundle
in the sidebar. Run the Classification wizard with Kraken2 selected, the
Viral database, and default thresholds. Under a minute later, a
`SRR36291587.kraken2.viral.lungfishtax` bundle appears in the sidebar.

Double-click the new bundle. The taxonomy viewport opens.

<!-- planned: kraken2-taxonomy-viewport -->

The sunburst on the left centres on the root of the tree of life. Its
largest wedge is **Riboviria**, the realm of RNA viruses. Inside Riboviria
the dominant child is **Orthornavirae**, and the chain narrows from there:
**Pisuviricota**, **Pisoniviricetes**, **Nidovirales**, **Coronaviridae**,
**Orthocoronavirinae**, **Betacoronavirus**, and finally **Severe acute
respiratory syndrome-related coronavirus**. The table on the right mirrors
the sunburst, one row per taxon, with columns for taxon name, rank, read
count, and percentage of total classified reads.

Click the **Coronaviridae** wedge. The sunburst re-centres on Coronaviridae
and the breadcrumb bar at the top of the viewport updates to read
`root > Riboviria > ... > Coronaviridae`. The table filters to taxa under
Coronaviridae, and the per-genus breakdown inside the family comes into
view.

<!-- planned: kraken2-drilldown-coronaviridae -->

To back up, click any earlier breadcrumb segment. To pull out every read
classified under a taxon for downstream work (mapping to a reference,
assembling de novo, BLASTing the consensus), right-click the taxon row in
the table and choose **Extract Reads as FASTQ Bundle**. Lungfish writes a
new virtual FASTQ bundle into the project holding only the reads assigned to
that taxon or any of its descendants.

<!-- planned: kraken2-extract-reads -->

For the SRR36291587 run, extracting reads under SARS-CoV-2-related
coronavirus yields a FASTQ bundle ready to map against the MN908947.3
reference, exactly the workflow the variant-calling chapters walk through.

## Interpretation

A Kraken2 result tells you which k-mers in your reads matched which
references in the database, summarised as a per-taxon read count. Read it
in three passes.

Start with the dominant signal. Find the largest wedge in the sunburst at
the rank you care about, usually genus or family for a viral sample. When
one wedge dwarfs the rest, the sample probably contains that organism. For
SRR36291587, Coronaviridae dominates: the sample is a SARS-CoV-2 sequencing
run, and the result is consistent.

Next, scan the long tail. Sort the table by descending read count and
scroll past the top hit. Low-abundance hits are usually one of three
things: real minor taxa in a mixed sample, mis-classifications from k-mers
shared between unrelated organisms, or contamination from the lab or the
database itself (human reads in a microbiome database, for example). A
handful of reads against an unrelated taxon is often noise. A few thousand
reads is worth a look.

Finally, weigh the unclassified bin. The table's top row is usually
**unclassified**: reads with no database hit at the configured confidence.
A large unclassified fraction means the sample is heavy with host or
contaminant (typical for wastewater) or the organism simply is not in the
database. When that fraction runs high and you suspect a specific virus,
switch to a viral-specialist classifier such as EsViritu or run BLAST on a
subset.

### When Kraken2 misses

Kraken2 fails quietly. A read it cannot place simply drops into
`unclassified` or settles at a higher rank than you expected. The pattern
turns up in three situations.

A novel virus, by definition, is missing from the database. Much of its
reads hit nothing, or catch only the family-level k-mers shared with known
relatives, so the strongest signal sits at family rather than species level.
A highly diverged member of a known family (a new coronavirus found in a bat
survey, for example) shows the same shape. And reads from a sample type the
database underrepresents (an environmental fungus against a bacteria-heavy
database) fail to hit at the rank you wanted.

In every case the move is the same: find the rank where the signal peaks,
extract those reads, and verify with BLAST or a focused mapper against a
candidate reference. Kraken2 is a screening step, not a final
identification.

## Running Kraken2 from the command line

The same classification runs headless for scripting and pipeline
integration. The command lives under `conda`, not as a top-level verb:

```bash
lungfish conda classify reads.fastq.gz --db Viral
```

The useful options mirror the wizard and add the abundance step.
`--preset sensitive|balanced|precise` sets the Sensitivity preset,
`--confidence` and `--min-hit-groups` set the Advanced thresholds, and
`--profile` turns on Bracken abundance estimation (tuned with
`--bracken-read-length`, `--bracken-level`, and `--bracken-threshold`).
`--memory-mapping` runs the database from disk when it will not fit in RAM,
and `--quick` stops at the first hit group for a faster, coarser pass.

Two neighbouring commands round out the headless path. `lungfish import
kraken2 <kreport-file>` brings a Kraken2 report you generated elsewhere into
a project. `lungfish build-db kraken2 <result-dir>` builds a SQLite database
from a Kraken2 result directory (with `--force` to overwrite and
`--no-cleanup` to keep intermediates), the power-user route when you need a
custom database the Plugin Manager does not offer.

## Next

Continue to [Running EsViritu](03-running-esviritu.md) for viral-focused
classification with strain-level resolution, or jump to [BLAST
Verification](06-blast-verification.md) to confirm a Kraken2 hit against
NCBI BLAST.

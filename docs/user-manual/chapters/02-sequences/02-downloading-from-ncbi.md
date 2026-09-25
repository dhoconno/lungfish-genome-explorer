---
title: Downloading from NCBI
chapter_id: 02-sequences/02-downloading-from-ncbi
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 02-sequences/01-importing-and-viewing]
estimated_reading_min: 17
task: Search a public sequence database by accession and download the record into the project as a reference bundle.
tags: [sequences, ncbi, download, fasta, gff3, genbank, accession, pathoplexus, sra]
tools: []
parameters_refs: [fetch.ncbi, fetch.pathoplexus]
entry_points:
  - Tools > Search Online Databases > Search NCBI...
  - Tools > Search Online Databases > Search SRA...
  - Tools > Search Online Databases > Search Pathoplexus...
  - "CLI: lungfish-cli fetch ncbi <accession>"
  - "CLI: lungfish-cli fetch search <query>"
  - "CLI: lungfish-cli fetch genome <accession>"
shots:
  - id: ncbi-search-dialog
    caption: "The database search dialog on its GenBank & Genomes pane, with the Mode picker on Nucleotide, the RefSeq Only and Include GFF3 Annotations checkboxes below it, the accession typed into the query field, and the one matching record listed under Results."
  - id: ncbi-advanced-filters
    caption: "The Advanced Search Filters panel expanded under the query field, showing the Organism, Location, Gene, Author, and Journal fields alongside the Molecule Type, Sequence Length, Publication Date, and Sequence Properties controls."
  - id: ncbi-results-download-selected
    caption: "The results list with the NC_012920.1 record ticked and the primary button reading Download Selected instead of Search."
  - id: ncbi-bundle-in-sidebar
    caption: "The downloaded NC_012920 reference bundle under the project's Downloads folder, open with sequence version NC_012920.1 and its NCBI GFF3 Annotations track."
  - id: pathoplexus-pane
    caption: "The Pathoplexus pane after the access and benefit sharing notice is accepted, showing the organism chips above the shared query field."
illustrations:
  - id: ncbi-accession-anatomy
    caption: "How an NCBI accession decomposes into prefix, number, and version, and which download path handles each kind."
glossary_refs: [accession, reference-genome, reference-bundle, gff, refseq, mitochondrial-genome, assembly, required-setup-pack, inspector, provenance, checksum, insdc, pathoplexus, sra]
features_refs: [fetch.ncbi, database.pathoplexus]
fixtures_refs: [human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A public sequence database holds sequences that other people have already read, checked, and deposited. Each deposited sequence gets an [accession](../../GLOSSARY.md#accession), a permanent identifier that always points at the same record. The National Center for Biotechnology Information, written NCBI, runs the largest of these collections. Lungfish Genome Explorer (LGE) searches NCBI from inside the app, so a sequence named in a paper becomes a file in your project without a web browser.

The record you want is often a [reference genome](../../GLOSSARY.md#reference-genome), the fixed sequence that every sample of a species is compared against. LGE reaches NCBI through a database search dialog. You type an accession, tick the record that comes back, and download it. What arrives is a [reference bundle](../../GLOSSARY.md#reference-bundle), a folder ending in `.lungfishref` that holds the sequence, its index, and its annotations together. An index is a small lookup file that lets LGE jump straight to any position without reading everything before it.

An annotation is a labelled feature on a sequence, such as a gene or a stretch that codes for a protein. NCBI serves a record's annotations as [GFF](../../GLOSSARY.md#gff), a plain-text table with one feature per line, and GFF3 is the third version of that format. LGE turns the table into an annotation track inside the bundle, so the genes draw below the bases. Annotations matter later on, because a variant caller, the program that lists where a sample differs from the reference, can name the protein a change falls in only when it knows where the proteins are.

The same dialog also searches two other collections. The Sequence Read Archive holds raw reads, the short stretches a sequencing machine produces, and [Pathoplexus](../../GLOSSARY.md#pathoplexus) holds pathogen genomes that may never have reached NCBI.

Download each reference once, with its annotations and its version number, and reuse that one bundle in every later chapter.

## Why you would do this

This chapter downloads the human mitochondrial genome, `NC_012920.1`. A [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome) is the small circle of DNA carried inside the mitochondrion, the compartment that makes most of a cell's chemical energy. The human one is 16,569 bases long, against roughly 3.1 billion bases in the nuclear genome, so it downloads in seconds.

The record is the revised Cambridge Reference Sequence, usually shortened to rCRS, and human mitochondrial studies number their positions against it. It is also densely annotated for its size. Its 16,569 bases hold 13 protein-coding genes, 22 transfer RNA genes, and 2 ribosomal RNA genes, so nearly every base sits inside a labelled feature. That makes it a clear first look at what an annotation track is for.

The accession begins with `NC_`, which marks it as [RefSeq](../../GLOSSARY.md#refseq), the reviewed collection in which NCBI staff keep one curated record per sequence. Ordinary GenBank records are whatever submitters deposited, and one gene may have hundreds of them. A RefSeq record at a fixed version does not change, which is why this chapter can promise you exact numbers. Later chapters map reads to this reference, extract regions from it, and call variants against it.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the human-mito fixture. Nothing needs downloading from it, because the chapter fetches the same record live from NCBI. The fixture's `NC_012920.1.fasta`, in [the human-mito folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito), is the frozen copy the numbers here were checked against, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The Genes and Sequences demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds the same frozen `NC_012920.1.fasta` under `Practice Data/human-mito`. The download itself is the procedure, so run it in that project or in any other.

You also need an internet connection, since every step talks to a public server. The `samtools` program that indexes the downloaded sequence arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. Docker Desktop is not needed. On a typical connection the download finishes in well under a minute.

One habit is worth forming now. Type the version suffix, the `.1` in `NC_012920.1`, every time. Curators revise records and the version number goes up when they do, so a bare accession can give you a different sequence from the one a colleague downloaded last year.

## Procedure

1. Choose **Tools > Search Online Databases > Search NCBI...**. The database search dialog slides down over the project window, open on its GenBank & Genomes pane. Leave **Mode** on Nucleotide and leave **Include GFF3 Annotations** ticked, which are both the defaults.

    <!-- SHOT: ncbi-search-dialog -->

2. Type `NC_012920.1` into the query field and click **Search**. A search on a full accession returns one result, or a few when related records share the identifier. The Advanced Search Filters panel under the field stays closed until you click **Show**, and you do not need it when you already hold the accession. The picture below shows it open, for reference only.

    <!-- SHOT: ncbi-advanced-filters -->

3. Tick the matching record in the results list. The dialog's primary button changes from **Search** to **Download Selected**.

    <!-- SHOT: ncbi-results-download-selected -->

4. Click **Download Selected**. The dialog closes and the download carries on in the background. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

5. When the row finishes, LGE selects the new bundle in the sidebar under `Downloads/`, a folder inside your project and not the Mac's own Downloads folder. The sequence fills the viewport and the annotation features draw below the bases.

    <!-- SHOT: ncbi-bundle-in-sidebar -->

There is no separate import step, because the download builds the bundle itself. Ticking more than fifty records raises a confirmation with **Download All** and **Cancel** before anything starts, so a large batch never begins by accident.

## Settings

The query field and its scope popup are shared by every pane of the dialog. The Advanced Search Filters panel below them changes with the pane and, on the GenBank & Genomes pane, with **Mode**. The entries are grouped by pane. Organism, Host, and Sequence Length appear on both panes and have an entry in each group, while the scope popup behaves the same on both and has one entry.

### The GenBank & Genomes pane

**Mode.** Chooses which NCBI collection the search reads, where Nucleotide holds single records, Genome holds whole [assemblies](../../GLOSSARY.md#assembly) with every chromosome of an organism, and Virus reaches NCBI's virus collection with filters of its own. The default is Nucleotide, the collection that holds single-molecule records such as this chapter's mitochondrial genome. Switch to Genome for a whole human or macaque reference, and to Virus for a curated set of viral records. On the command line this is `--db`.

**RefSeq Only.** Keeps only RefSeq records, the reviewed subset, and appears only in Nucleotide and Virus modes. The default is off, so every deposited record comes back. Turn it on when you want one reviewed sequence per organism, and leave it off when you are after one submitter's sequence, which RefSeq will not hold. This setting has no command-line flag.

**Include GFF3 Annotations.** Fetches the record's GFF3 feature table and builds the bundle's annotation track from it, and like RefSeq Only it appears only in Nucleotide and Virus modes. The default is on, because the GFF3 table is NCBI's standard feature set and a bundle with annotations works everywhere a bare one does. Turn it off when you want the features exactly as the GenBank record lists them, since LGE then builds the track from the record's own feature table and still builds the bundle. This setting has no command-line flag.

**(search scope).** Limits the query text to one field of each record, through the unlabelled popup at the left end of the query field, among All Fields, Accession, Organism, Title, BioProject (NCBI's identifier for one study), and Author. The default is All Fields, which suits a search word whose place in the record you do not yet know. Choose Accession when you already hold the identifier, so a common word in some other record's title cannot swamp the results. This setting has no command-line flag.

**Organism.** In Nucleotide and Genome modes, adds an organism name to the query so that only records from that species or group come back. The default is empty, because most searches start from an accession or a title. Fill it with a name such as `Homo sapiens` when your query word, a gene name for instance, occurs in many species. On the command line this is `--organism`.

**Location.** Adds a place name to the query, matching where the sample was collected. The default is empty, because references are rarely found by collection site. Fill it when you are gathering sequences from one region. This setting has no command-line flag.

**Gene.** Adds a gene symbol to the query, so that only records annotated with that gene come back. The default is empty, which lets whole genomes and single genes come back together. Fill it, for example with `MT-CO1`, when you want one gene rather than whole genomes. This setting has no command-line flag.

**Author.** Adds an author name to the query, matching the people credited on the submission. The default is empty, since a record's authors are rarely how you find it. Fill it when you want the sequences behind one paper. This setting has no command-line flag.

**Journal.** Adds a journal name to the query, matching where the record was published. The default is empty, for the same reason as Author. Fill it together with Author to pin down one publication. This setting has no command-line flag.

**Molecule Type.** Keeps only records of one molecule type, such as Genomic DNA or mRNA, where mRNA is the spliced RNA copy a cell makes from a gene. The default is Any, so nothing is excluded before you have seen what came back. Choose mRNA for a gene's spliced transcript, or Genomic DNA for the gene as it sits in the genome with its introns. This setting has no command-line flag.

**Sequence Length.** On this pane, keeps only records whose length in bases falls between the Min and Max you type. Both boxes start empty, so no length limit applies. Type a Min of 16000 to keep complete human mitochondrial genomes and drop the many partial ones. This setting has no command-line flag.

**Publication Date.** Keeps only records published between the From and To dates you type. Both boxes start empty, so the whole history of the database is searched. Set From to leave out older records that newer ones have replaced. This setting has no command-line flag.

**Sequence Properties.** Keeps only records carrying every feature type you tick, among Has CDS, Has Gene, Has Source, Has tRNA, and Has rRNA, where CDS is a protein-coding stretch and Source is the record's description of its sample. Nothing is ticked by default, so records without annotations still appear. Tick Has CDS when you need protein-coding regions and a bare sequence is no use to you. This setting has no command-line flag.

The next five filters replace the ones above when **Mode** is set to Virus.

**Host.** In Virus mode, keeps only records whose sample came from that host, such as `Homo sapiens`. The default is empty, so isolates from every host come back. Fill it to separate human isolates from animal ones for a virus that crosses between species. This setting has no command-line flag.

**Geographic Location.** In Virus mode, keeps only records collected in that place. The default is empty, so every place is included. Fill it when you are building a regional set of viral genomes. This setting has no command-line flag.

**Completeness.** In Virus mode, keeps only complete genomes or only partial ones, offering Any, Complete, and Partial. The default is Any, which returns both kinds. Choose Complete when partial sequences would leave gaps in an alignment. This setting has no command-line flag.

**Released Since.** In Virus mode, keeps only records released on or after the date you type, written as year, month, and day (`YYYY-MM-DD`). The default is empty, so the whole collection is searched. Fill it when you are adding new records to a set you downloaded earlier. This setting has no command-line flag.

**Annotated Only.** In Virus mode, keeps only records that carry gene annotations. The default is off, so records without annotations still appear. Turn it on when later steps need gene positions rather than sequence alone. This setting has no command-line flag.

### The Pathoplexus pane

**Organism.** On this pane, the row of organism buttons above the query field chooses which pathogen's collection is searched. The default is Mpox virus, and choosing another organism clears the current results because Pathoplexus keeps one collection per organism. Change it whenever you move to a different pathogen, since one search cannot span them all. This setting has no command-line flag.

**Country.** Keeps only records whose sample was collected in that country. The default is empty, so every country is included. Fill it when you are building a national or regional set. This setting has no command-line flag.

**Host.** On this pane, keeps only records whose sample came from that host species. The default is empty, so every host is included. Fill it to separate human cases from animal samples. This setting has no command-line flag.

**Clade.** Keeps only records assigned to that clade, a named branch of the pathogen's family tree. The default is empty, so every branch is included. Fill it when one clade is your subject and the rest are background. This setting has no command-line flag.

**Lineage.** Keeps only records assigned to that lineage, a finer division inside a clade. The default is empty, so every lineage is included. Fill it when you are following one descendant group. This setting has no command-line flag.

**Nucleotide Mutations.** Keeps only records carrying every base change you list, each written as reference base, position, and new base, such as `C180T`, with commas between entries. The default is empty, so no mutation filter applies. Fill it when you are following one defining change through a population. This setting has no command-line flag.

**Amino Acid Mutations.** Keeps only records carrying every protein change you list, each written as a gene name and a change, such as `GP:440G`, with commas between entries. The default is empty, so no protein filter applies. Fill it when the change you care about is in a protein, such as a known antibody-escape site. This setting has no command-line flag.

**Collection Date.** Keeps only records whose sample was collected between the From and To dates, which is the sampling date and not the publication date. Both boxes start empty, so every date is included. Set it when you are studying one season or one outbreak. This setting has no command-line flag.

**Sequence Length.** On this pane, keeps only records whose length in bases falls between the Min and Max you type. Both boxes start empty, so no length limit applies. Set a Min to drop fragments too short to be worth aligning. This setting has no command-line flag.

**INSDC Source.** Keeps records by whether they also sit in [INSDC](../../GLOSSARY.md#insdc), the shared system of the American, European, and Japanese sequence databases, offering Any, INSDC Only, and Non-INSDC Only. The default is Any, which mixes both kinds. Choose Non-INSDC Only for records deposited to Pathoplexus alone, which no NCBI search can find. This setting has no command-line flag.

## Reading the results

The new bundle is named `NC_012920`, without the `.1`. LGE names a downloaded bundle from the accession line of the GenBank record, and that line carries no version. The version is still kept inside the bundle, where the Inspector shows it. Download the same record a second time and the new copy is named `NC_012920_1`, so the first is never overwritten. That `_1` is a copy counter LGE adds to keep the two names apart, not a version number, and the copy's Version row still reads `NC_012920.1`.

The viewport shows the sequence with its annotation track below the bases. The track is named NCBI GFF3 Annotations when LGE built it from NCBI's GFF3 table. If that fetch fails, or comes back with no features, LGE falls back to the feature table inside the GenBank record and names the track NCBI GenBank Annotations instead. Nothing warns you when that happens. Both tracks work everywhere a track is used, but the two sources can label the same feature differently, so the track name tells you which one you are reading.

Select the bundle and look at the Inspector's **Document** tab, which LGE brings forward by itself after a download. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. The rows worth reading for this record are these.

| Group | Row | What it holds | This record |
|---|---|---|---|
| Source | Database | The service the record came from | NCBI |
| Source | Accession | The accession the bundle is named from | `NC_012920` |
| Source | Downloaded | The date of the download | the day you ran it |
| Genome | Total Length | The sequence length, rounded to one decimal place | 16.6 Kb, which is 16,569 bases rounded |
| Genome | Chromosomes | How many separate sequences the bundle holds, of any kind, so a mitochondrial genome counts here too | 1 |
| Genome | Annotations | How many tracks, and how many features across them | 1 track, with its feature count |
| Record | Version | The accession with its version, as NCBI served it | `NC_012920.1` |
| Record | Topology | Whether the molecule is a line or a circle | circular |

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

## What good looks like

Four checks are worth making before you build anything on a downloaded reference.

Confirm the version. The Record group's Version should read `NC_012920.1`, the accession you typed. If it reads anything else, read the next section before going further.

Confirm the length and shape. Total Length should read 16.6 Kb and Topology should read circular. A Total Length clearly below 16.6 Kb means you ticked a partial record rather than the complete genome, so delete the bundle and download again with a Min of 16000 in **Sequence Length**.

Confirm the annotations. Features should draw below the bases, the Annotations row should read 1 track, and the track should be named NCBI GFF3 Annotations. A track named NCBI GenBank Annotations means the fallback ran, probably because NCBI's server was briefly unavailable. If you want the GFF3 track, delete the bundle and download the record again.

Confirm the folder. The bundle should sit under the project's `Downloads/` folder, which keeps records fetched from the internet apart from files you brought in from your own disk. If it is missing, look at the download's row in the Operations Panel. A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it.

## When a download returns a different accession

NCBI keeps two collections that matter here. The nucleotide collection holds one record per molecule, such as `NC_012920.1`. The assembly collection holds whole genomes, and its accessions begin with `GCF_` for RefSeq assemblies or `GCA_` for GenBank ones. The assembly collection has no record for a single nucleotide accession. Ask it for one anyway and it returns the assembly that contains that sequence, which may name the sequence differently.

The bases then match, but the name does not, and anything that finds a sequence by its name fails against a bundle that looks entirely healthy. The best-known case is a SARS-CoV-2 genome that comes back under its RefSeq accession, which [Primer Scheme Bundles](../appendices/primer-schemes.md) covers.

![How an NCBI accession decomposes into prefix, number, and version](../../assets/illustrations-imagegen/02-sequences/02-downloading-from-ncbi/ncbi-accession-anatomy.png)

LGE keeps each kind of accession on the collection that holds it. The dialog's Nucleotide mode always fetches from the nucleotide collection. On the command line, `lungfish-cli fetch genome` reads the accession's prefix first. It sends `GCF_` and `GCA_` accessions to the assembly collection and every other accession to the nucleotide collection, and it names the bundle from the record's own header. Both paths return the record you asked for.

One route still reaches the assembly collection with whatever you type. The dialog's Genome mode searches assemblies, so a nucleotide accession typed there lists the assembly that contains it, under that assembly's own `GCF_` or `GCA_` accession. That listing is your warning. Switch **Mode** back to Nucleotide when you want one record, and compare the Version row in the Inspector with the accession you asked for every time.

## Searching Pathoplexus

Pathoplexus is an open database for pathogen genomes. Choose **Tools > Search Online Databases > Search Pathoplexus...** to open the same dialog on its Pathoplexus pane. It is viral by design and holds ten pathogens, which are Crimean-Congo hemorrhagic fever, Sudan ebolavirus, Zaire ebolavirus, Human metapneumovirus, Marburg virus, Measles virus, Mpox virus, RSV-A, RSV-B, and West Nile virus. Reach for it when a genome has not reached NCBI, or when you want the surveillance details Pathoplexus keeps, such as clade and collection date.

The first time you open the pane it shows a notice titled Pathoplexus Access and Benefit Sharing, and nothing else on the pane works until you click **I Understand and Agree**. LGE remembers your answer. The notice exists because submitters share these genomes on stated terms, which ask you to use the data as the terms allow and to credit the people who generated it.

<!-- SHOT: pathoplexus-pane -->

Mpox virus is already chosen when the pane opens, so pick a different organism button first if you need one. The filters in the Advanced Search Filters panel combine, so each one you fill in narrows the results. LGE retrieves only records marked OPEN, a status the submitter sets, so restricted sequences never appear.

What arrives is a `.lungfishref` bundle like the one this chapter's procedure produced. When a record also carries an INSDC accession, LGE downloads the GenBank record for it and adds the Pathoplexus details to the bundle. When that download fails, or the record has no INSDC accession, LGE builds the bundle from the Pathoplexus sequence alone. There is no command-line equivalent for Pathoplexus.

## Searching SRA

**Tools > Search Online Databases > Search SRA...** opens the same dialog on its SRA Runs pane, which [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) covers in full.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The command below reproduces the procedure. Run it from inside your project folder, and it builds the same reference bundle under `Downloads/`.

```bash
lungfish-cli fetch genome NC_012920.1 --output-dir Downloads
```

Two differences change what you get. The command names the bundle `NC_012920.1`, with the version, because it reads the name from the sequence's own header line rather than from the GenBank accession line. It also builds the annotation track only from NCBI's GFF3 table, under a different track name, and it has no GenBank fallback, so when the GFF3 fetch fails it prints a warning and builds the bundle without annotations.

## Next

Continue to [Extracting Sequences](03-extracting-and-comparing.md) to cut a region out of the reference you just downloaded.

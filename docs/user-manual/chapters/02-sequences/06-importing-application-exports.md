---
title: Importing Application Exports
chapter_id: 02-sequences/06-importing-application-exports
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 02-sequences/01-importing-and-viewing]
estimated_reading_min: 14
task: Import a Geneious archive or another application's export folder as reference and annotation bundles.
tags: [import, geneious, application-export, reference, annotation, migration]
tools: []
parameters_refs: []
entry_points:
  - "File > Import Center… (Cmd-Shift-I) > Application Exports > Geneious Export"
  - "CLI: lungfish-cli import geneious"
  - "CLI: lungfish-cli import application-export"
shots:
  - id: application-export-card
    caption: "The Import Center on its Application Exports tab, showing the Geneious Export card."
  - id: application-export-result
    caption: "The sidebar after the command-line import of the application export fixture, with its collection open under Application Exports."
illustrations: []
glossary_refs: [application-export, archive, geneious, bundle, project-collection, project, fasta, genbank, embl, reference-bundle, annotation-track, binary-artifact, fixture, refseqgene, vcf, csv, export-kind, msa, gff, bam, fastq, required-setup-pack, import-center, operations-panel, sidebar, sequence-viewport, terminal, command-line-flag, json, provenance, checksum, variant-track]
features_refs: [import.application-export]
fixtures_refs: [application-export-hbb]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Importing a Geneious archive or another application's export folder as reference and annotation bundles. -->

## What it is

Lungfish Genome Explorer (LGE) can bring in work you saved in another sequence analysis program. An [application export](../../GLOSSARY.md#application-export) is the set of files another program writes when you export records or a whole project from it. One example is an [archive](../../GLOSSARY.md#archive), a single file that packs a folder of files together, written by [Geneious](../../GLOSSARY.md#geneious), a desktop program for sequence analysis that keeps each sequence or set of sequences as a document. Another is a folder exported from CLC Workbench or Benchling. LGE reads the export, turns each file it can into a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, and gathers everything in one [project collection](../../GLOSSARY.md#project-collection), the folder in your [project](../../GLOSSARY.md#project) that holds what one export import made.

The import works by file type. A [FASTA](../../GLOSSARY.md#fasta) file holds bases only, and a [GenBank](../../GLOSSARY.md#genbank) or [EMBL](../../GLOSSARY.md#embl) record holds bases together with a table of features. Each becomes a [reference bundle](../../GLOSSARY.md#reference-bundle), the `.lungfishref` folder in which LGE keeps a sequence and everything attached to it. A feature is a labeled stretch of the sequence, such as a gene or a coding sequence, and a record's features arrive as an [annotation track](../../GLOSSARY.md#annotation-track), one named set of features drawn together as one layer. The general importer also turns alignment files, which line related sequences up column by column, and tree files, which hold a family tree of sequences, into bundles of their own. A Geneious export gets one extra step, because Geneious stores sequences in a format of its own. LGE decodes the nucleotide sequences in each Geneious document, with their annotations, into a reference bundle.

A file with no automatic place in a bundle is reported, not converted. A variant file, a read file, a table, or another program's own project file is either copied into the collection unchanged, as a [binary artifact](../../GLOSSARY.md#binary-artifact), or left out, depending on the importer and its settings. Every collection holds a report and an inventory that name each file of the export and say where it went. Put simply, LGE reads the files of an export and never runs or reads the other program, so its settings, its saved workflows, and anything it keeps only inside itself stay behind.

In practice, import the export, then read its report to see what came across and what did not.

## Why you would do this

A lab that kept its references and annotations in another program can move them into LGE without retyping them or exporting each record by hand. They arrive as the same reference bundles every LGE tool accepts, so a record you annotated elsewhere can serve as the reference when you map reads or call variants.

The practice export is the application-export-hbb [fixture](../../GLOSSARY.md#fixture), a small folder named `hbb-sequence-library` in the shape a sequence library program writes. It holds 3 files. `HBB_region.gb` is a GenBank record of 3,000 bases of the human beta-globin (HBB) region with 42 features, cut from the [RefSeqGene](../../GLOSSARY.md#refseqgene) record `NG_000007.3`, a curated slice of human chromosome 11 from the National Center for Biotechnology Information (NCBI). HBB encodes the beta chain of adult hemoglobin. `HBB_region.vcf` is a [VCF](../../GLOSSARY.md#vcf) file, the standard table of positions where a sample differs from a reference, and it holds one variant, the sickle cell change that turns the `A` at position 614 of the record into a `T`. `index.csv` is a one-row index of the library in [CSV](../../GLOSSARY.md#csv), a plain text table with commas between its columns. A script cut these files from the public record, so the folder is not a file set from any vendor's program. The same 3 files also come packed in one zip archive.

Importing this folder shows both halves of an export import. The GenBank record becomes a reference bundle carrying its 42 features. The variant file and the index are not converted, because an export import never attaches a variant file or a table to a reference. The general importer keeps them as copies with one warning each, and the Geneious importer leaves them out unless you ask for copies.

## Choosing a tool

Two importers read exports, and the program that wrote the export settles which one to use. The app has a card for only one of them.

The **Geneious Export** card sits on the **Application Exports** tab of the [Import Center](../../GLOSSARY.md#import-center), the window that brings files into the open project. It runs the command `lungfish-cli import geneious`, where `lungfish-cli` is the command-line program that ships inside LGE, and you can type the same command yourself. It is built for an export from Geneious, either a `.geneious` archive or a folder that Geneious exported, and on the command line it also takes one exported file. It decodes the nucleotide sequences stored in Geneious documents together with their annotations, and it turns any FASTA, GenBank, or EMBL file in the export into a reference bundle. By default it keeps no copy of the export and leaves every other file out, listing each one in the inventory. That keeps the collection small, and it means you read the report for what it skipped.

`lungfish-cli import application-export` takes exports from other programs, and you name the program with an [export kind](../../GLOSSARY.md#export-kind), a short name such as `clc-workbench` typed before the export's path. The export can be a folder, a `.zip`, `.qza`, or `.qzv` archive that LGE unpacks first, or a single file. The importer sorts files by type. It turns FASTA, GenBank, and EMBL files into reference bundles, alignment files into `.lungfishmsa` bundles that each hold one [multiple sequence alignment](../../GLOSSARY.md#msa), and tree files into `.lungfishtree` bundles. By default it copies every other file into the collection with one warning each and keeps a full copy of the export, so nothing is lost, and the collection takes more disk space than the export itself. It has no card in the app and runs only from the command line.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| **Geneious Export** card, `import geneious` | `.geneious` archives and Geneious export folders | The export came from Geneious, or you want to stay in the app | The export came from another program |
| `import application-export` | Exports of the 9 kinds in the next table | The export came from CLC Workbench, Benchling, QIIME 2, or another program the table names | The export is a Geneious archive, whose sequences only the Geneious importer decodes |

The kind names the collection and its report. For seven of the nine kinds it changes nothing else, since the importer sorts by file type whatever the kind. The other two, `alignment-tree` and `phylogenetics-result-set`, look for alignments and trees first. They also read a FASTA file of two or more sequences of equal length as an alignment rather than a reference when its sequences contain a gap character, `-` or `.`, or when its name contains `align`, `msa`, `mafft`, or `muscle`. They copy no other file and make no copy of the export, and the import fails when an alignment or a tree cannot be read.

| Kind | Meant for | Collection name ends with |
|---|---|---|
| `clc-workbench` | A CLC Workbench export folder, archive, or project file | `CLC Workbench Import` |
| `dnastar-lasergene` | A DNASTAR Lasergene or GenVision export folder or file | `DNASTAR Lasergene Import` |
| `benchling-bulk` | A Benchling bulk export archive, folder, or exported file | `Benchling Bulk Import` |
| `sequence-design-library` | A sequence design library export folder, archive, or file | `Sequence Library Import` |
| `alignment-tree` | An alignment or tree export | `Alignment Tree Import` |
| `sequencing-platform-run-folder` | A sequencing run folder or a downloaded analysis export | `Sequencing Run Import` |
| `phylogenetics-result-set` | A phylogenetics result folder, archive, or file | `Phylogenetics Import` |
| `qiime2-archive` | A QIIME 2 archive or exported folder | `QIIME 2 Import` |
| `igv-session-track-set` | An IGV session file or a folder of local tracks | `IGV Session Import` |

A run folder's reads are copied and never become read bundles, so import reads as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes.

This chapter's fixture uses `sequence-design-library`, a kind that names no vendor, because the fixture comes from none. For your own data, choose the kind that names the program that wrote the export, or `alignment-tree` when the export holds only alignments and trees. The same fixture folder also works on the **Geneious Export** card for practice, because the Geneious importer reads plain sequence files in any folder.

## Before you start

You need a project open in LGE that you can write to, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows, since a read-only project cannot take an import. For the command-line procedure, create the project in LGE first with **File > New Project**, because `lungfish-cli` never creates the project store, as [On the command line](../01-foundations/06-the-lungfish-project.md#on-the-command-line) in that chapter explains.

Each sequence file becomes a reference bundle through the same import the **Reference Sequences** card runs, so the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) must be installed, as [Importing and Viewing a Sequence](01-importing-and-viewing.md#before-you-start) explains. Nothing else needs installing, and no container runtime is involved.

The fixture lives in the [application-export-hbb](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/application-export-hbb) folder on GitHub, whose README gives its source, license, and citation. Open `hbb-sequence-library.zip` there, click **Download raw file**, and save it in `~/Desktop/lge-docs/`, as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) describes. Double-click the downloaded zip in Finder to unpack it, which gives a folder named `hbb-sequence-library`. Keep both, since the command line takes either one. The fixture's files come to 24 KB, so each import probably takes a few seconds.

## Procedure

### Import a Geneious archive with the Geneious Export card

No Geneious archive ships with this manual, since a real one comes from Geneious itself. The steps work the same for your own `.geneious` file or Geneious export folder. For practice, use the fixture's `hbb-sequence-library` folder, which the Geneious importer reads like any folder of sequence files.

1. Open the Import Center with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Click the **Application Exports** tab. It holds one card, **Geneious Export**, with the hint `.geneious archive or Geneious export folder` below its description.

    <!-- SHOT: application-export-card -->

2. Drag the `.geneious` file or the export folder from Finder onto the card. If you prefer a file panel, click the card's **Import…** button and choose it there. The card takes one archive or one folder at a time.

3. Watch the import in the [Operations Panel](../../GLOSSARY.md#operations-panel), the list of jobs LGE runs, which **Operations > Show Operations Panel** (Cmd-Shift-P) opens. The row is titled **Geneious Import**. Its detail line names the file or folder, shows each step as the import runs, and ends with `Imported` and the collection's name, followed by the number of warnings when there are any. Each warning is a line of the row's log. **Cancel** on the row stops the import, and the partial collection folder stays in the project.

4. Find the new collection in the [sidebar](../../GLOSSARY.md#sidebar), the project list on the left of the window, where LGE selects it when the import ends. It sits under `Geneious Imports/`, and its reference bundles are in its `LGE Bundles/` folder. Click one to open it in the [sequence viewport](../../GLOSSARY.md#sequence-viewport), the center pane that draws a sequence with its features.

For the practice folder, the collection is `Geneious Imports/hbb-sequence-library Geneious Import/`, and its `LGE Bundles/` folder holds one reference bundle, `HBB_region`. The row reports no warnings, because with the card's defaults the Geneious importer leaves the variant file and the index out without copying them, as [What an export import keeps and leaves out](#what-an-export-import-keeps-and-leaves-out) explains.

### Import another application's export folder with import application-export

The other kinds have no card, so this route uses [Terminal](../../GLOSSARY.md#terminal), the macOS program in which you type commands. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains how to read the lines below.

1. In LGE, create the project with **File > New Project**, name it `Export Practice`, save it in `~/Desktop/lge-docs/`, and close its window.

2. Open Terminal and type the commands below. The first line stores the project's location in `PROJECT`. The command after it names the kind, the export folder, and the project, and it names the collection with `--collection-name`, an [option](../../GLOSSARY.md#command-line-flag), which is a named switch typed after the command. If Terminal answers that it cannot find `lungfish-cli`, [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to fix that.

    ```bash
    PROJECT="$HOME/Desktop/lge-docs/Export Practice.lungfish"
    lungfish-cli import application-export sequence-design-library \
      "$HOME/Desktop/lge-docs/hbb-sequence-library" \
      --project "$PROJECT" --collection-name "HBB sequence library"
    ```

3. Read what the command prints. Two lines begin with `Warning:`, one for `HBB_region.vcf` and one for `index.csv`, each saying that the file was recognized but not converted and was kept as a binary artifact. The last line begins with `Imported` and gives the path of the new collection.

4. In LGE, reopen the project with **File > Open Recent** or **File > Open Project Folder…**, and open the `Application Exports` folder in the sidebar to see the collection.

## Settings

The **Geneious Export** card has no settings. It takes one archive or folder and runs `import geneious` with that command's defaults. The command line adds four options, and the two commands start from different defaults, as the table shows.

| What it controls | `import geneious` and the card | `import application-export` |
|---|---|---|
| The collection's name | The export's own name | The export's own name |
| A full copy of the export in `Source/` | Off, and `--preserve-raw-source` turns it on | On, and `--no-preserve-raw-source` turns it off |
| FASTA, GenBank, and EMBL files become reference bundles | On, and `--no-import-references` turns it off | On, and `--no-import-references` turns it off |
| Copies of the files it does not convert, in `Binary Artifacts/` | Off, and `--preserve-unsupported` turns it on | On, and `--no-preserve-unsupported` turns it off |

`--collection-name` sets the first part of the collection folder's name, which LGE completes with the kind's name and the word Import. The default is the export's own name, which is the folder's name or the archive's file name without its ending, `.geneious` for the Geneious importer and `.zip`, `.qza`, or `.qzv` for the general one, so each collection is easy to match to its source. Give a name when that one is unclear, and expect LGE to turn any character other than a letter, a digit, a space, a hyphen, or an underscore into a space.

`--preserve-raw-source` and `--no-preserve-raw-source` decide whether the collection gets a full copy of the export in its `Source` folder. `import geneious` and the card leave the copy out by default, and `import application-export` makes it, except for `alignment-tree` and `phylogenetics-result-set`, which never make it. Keep the copy when the original export is kept nowhere else, and leave it out when the export is large and safe where it is, since the copy takes as much disk space as the export.

`--no-import-references` keeps FASTA, GenBank, and EMBL files as plain copies instead of turning them into reference bundles. Both commands convert them by default, because a reference bundle is what every LGE tool reads. Use it only when the project already holds those references, and with `import geneious` add `--preserve-unsupported` too, or those files are left out entirely. It never affects the sequences decoded from Geneious documents, which always become reference bundles.

`--preserve-unsupported` and `--no-preserve-unsupported` decide whether every file the import does not convert, such as a VCF, an annotation file, or a report, is copied into the collection's `Binary Artifacts` folder with one warning each. `import geneious` and the card leave such files out by default, and `import application-export` copies them, except for the two alignment and tree kinds, which never copy them. Turn copies on for a Geneious export that holds files you mean to attach later, and turn them off for another program's export when you want only the bundles.

## Reading the results

### The project collection an export import writes

Every export import writes one collection folder at the top of the project, under `Geneious Imports/` for the Geneious importer and under `Application Exports/` for the general one. The folder's name joins the collection name, the kind's name, and the word Import, as in `HBB sequence library Sequence Library Import`. A second import under the same name adds a counter, as in `HBB sequence library Sequence Library Import 2`, so nothing is overwritten.

| Inside the collection | What it holds |
|---|---|
| `LGE Bundles/` | The reference bundles, and with `import application-export` the alignment and tree bundles |
| `Binary Artifacts/` | Unchanged copies of the files that were not converted, when copies are on |
| `Source/` | A full copy of the export, when that setting is on |
| `import-report.md` | A plain text report of what the import found and where each file went |
| `inventory.json` | The same list in [JSON](../../GLOSSARY.md#json), a structured text format programs read, with one entry per file |

The collection also holds a [provenance](../../GLOSSARY.md#provenance) record, the file in which LGE notes how a result was made, including the command that repeats the import. The sidebar hides it.

<!-- SHOT: application-export-result -->

For the fixture imported from the command line, `Application Exports/HBB sequence library Sequence Library Import/` holds the reference bundle `HBB_region` in `LGE Bundles/`, copies of `HBB_region.vcf` and `index.csv` in `Binary Artifacts/`, the original `hbb-sequence-library` folder with its 3 files in `Source/`, and the report and the inventory. Click `HBB_region` to open it. It holds one sequence named `HBB_region`, 3,000 bases long, and its annotation track carries the record's 42 features, among them the HBB gene from position 545 to 2,152. Each position in this record is its position in `NG_000007.3` minus 70,000, so the sickle cell codon, the 3 bases that code for the amino acid the change alters, `GAG` at 70,613 to 70,615 in [Importing and Viewing a Sequence](01-importing-and-viewing.md#go-to-a-position), sits here at 613 to 615.

The report has five parts. For the fixture they read as the table shows.

| Part of `import-report.md` | What it says for the fixture |
|---|---|
| The opening lines | The source path, the source kind `folder`, the application export `Sequence Library`, and `Items: 3` |
| Counts | 1 file for each kind it recognized, `report`, `standaloneReferenceSequence`, and `variantTrack` |
| Native bundles | The path of `HBB_region.lungfishref` |
| Preserved artifacts | The paths of the copies of `HBB_region.vcf` and `index.csv` |
| Warnings | 1 line for each of those 2 files, saying it was recognized but not converted |

A Geneious report has the same parts, with the Geneious version the export recorded, or `unknown`, in place of the application export line.

In `inventory.json`, each file has its path inside the export, its kind, its size in bytes, its SHA-256 [checksum](../../GLOSSARY.md#checksum), a fingerprint of its exact bytes, and `lgeDestination`, the place in the collection it went to. For the fixture the sizes are 19,739 bytes for the GenBank record, 296 bytes for the VCF, and 128 bytes for the index. A file with no `lgeDestination` was left out.

### What an export import keeps and leaves out

The table lists what each importer does with each kind of file under its default settings.

| File in the export | `import geneious` and the card | `import application-export` |
|---|---|---|
| Nucleotide sequences inside a Geneious document | One reference bundle for each document, with its annotations as a track | Not decoded, so the `.geneious` file is copied like any other file it does not convert |
| A Geneious document with no nucleotide sequence, such as a protein | Left out | Not decoded, and copied |
| A FASTA, GenBank, or EMBL file, compressed or not | A reference bundle | A reference bundle |
| An alignment file, such as `.aln`, `.phy`, or `.sto` | Left out | A `.lungfishmsa` bundle |
| A tree file, such as `.nwk`, `.tre`, or `.treefile` | Left out | A `.lungfishtree` bundle |
| A standalone annotation file, a table of features with no bases such as [GFF3](../../GLOSSARY.md#gff) or BED | Left out | Copied into `Binary Artifacts/` with a warning |
| A VCF, a [BAM](../../GLOSSARY.md#bam) file of aligned reads, [FASTQ](../../GLOSSARY.md#fastq) reads, a table, or a report | Left out | Copied into `Binary Artifacts/` with a warning |
| Another program's own project file, such as a `.clc` file | Left out | Copied, and not read |
| The export itself | Not copied | Copied into `Source/` |

Left out means not copied and still listed in the inventory. With `--preserve-unsupported`, `import geneious` copies each of those files into `Binary Artifacts/` with a warning instead.

Files that belong inside a reference bundle never get there by themselves, whichever importer you use. A standalone annotation file is never attached, even when it sits beside its sequence in the export, so attach it afterwards, from the copy or from your original, with the **Annotation Track** card, as [Attach a standalone annotation file](01-importing-and-viewing.md#attach-a-standalone-annotation-file) shows. A VCF never becomes a [variant track](../../GLOSSARY.md#variant-track), the named set of variant calls inside a reference bundle, so open the bundle and import the VCF as [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md#open-the-bundle-the-variants-belong-to) shows. A BAM never becomes an alignment track, and reads never become read bundles, so import those as their own chapters describe.

A Geneious document's annotations come across only for the sequences LGE decodes. When a document's annotations cannot be read, a warning names the document, and its sequences arrive without those features.

## What good looks like

Check these four things before you work with the bundles.

1. The Operations Panel row, or the command's last line, reads `Imported`. Most warnings are one for each file kept as a copy or skipped, so the fixture gives 2 warnings with `import application-export` and none with the card.
2. `Items` in the report equals the number of files in the export, 3 for the fixture. Both importers skip hidden files, whose names start with a dot, so those are never counted.
3. Every sequence file you expected has a bundle under `LGE Bundles/`. Open one and check a position you know. For the fixture, **Sequence > Go to Location…** (Cmd-L) with `HBB_region:613-615` shows `GAG`.
4. Every file you still need that has no bundle is in `Binary Artifacts/`, or you know where else to find it.

Importing the zip instead of the folder gives the same bundle and the same 2 warnings.

A failed or cancelled import leaves its partial collection folder in the project. Delete that folder before you import again, or the next import writes a second collection with a counter after its name.

### When the import leaves out more than you expected

A Geneious collection whose inventory lists files with no `lgeDestination` skipped them under its default. Import the export again with `--preserve-unsupported` to keep copies of them.

An `alignment-tree` or `phylogenetics-result-set` import that fails names each alignment or tree file it could not read, and its collection and report stay in the project for you to read. Fix or remove the file it names, or import with a general kind such as `sequence-design-library`, under which a file that cannot be read gives a warning instead of a failure.

## On the command line

The flags of both commands are listed under [`import geneious`](../appendices/cli-reference.md#import-geneious) and [`import application-export`](../appendices/cli-reference.md#import-application-export) in the CLI Reference. The block repeats both procedures on the fixture.

```bash
# 1. In LGE, File > New Project, name it Export Practice, save it in ~/Desktop/lge-docs, then close it.
PROJECT="$HOME/Desktop/lge-docs/Export Practice.lungfish"

# 2. The general importer on the folder, as in the procedure.
lungfish-cli import application-export sequence-design-library \
  "$HOME/Desktop/lge-docs/hbb-sequence-library" \
  --project "$PROJECT" --collection-name "HBB sequence library"

# 3. The same export as a zip, which gives the same bundle and the same 2 warnings.
lungfish-cli import application-export sequence-design-library \
  "$HOME/Desktop/lge-docs/hbb-sequence-library.zip" \
  --project "$PROJECT" --collection-name "HBB sequence library zip"

# 4. The Geneious importer on the same folder, as the Geneious Export card runs it.
lungfish-cli import geneious "$HOME/Desktop/lge-docs/hbb-sequence-library" \
  --project "$PROJECT"
```

Add `--preserve-unsupported` to the last command to keep copies of the VCF and the CSV, as `import application-export` does by default.

## Next

Continue to [Downloading from NCBI](02-downloading-from-ncbi.md), which fetches a record from NCBI straight into the project when you have no export to bring in. To give the copied VCF a place in its bundle, see [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md), and for reads that came with an export, see [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

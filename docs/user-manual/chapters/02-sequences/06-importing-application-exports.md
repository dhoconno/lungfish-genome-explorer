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

Lungfish Genome Explorer (LGE) can bring in work you saved in another sequence analysis program. An [application export](../../GLOSSARY.md#application-export) is the set of files another program writes when you export records or a whole project from it. One example is a `.geneious` [archive](../../GLOSSARY.md#archive), a single file that packs a folder of files together, written by [Geneious](../../GLOSSARY.md#geneious), a program that stores sequences, alignments, and trees as documents. Another is a folder exported from CLC Workbench or Benchling. LGE reads the export, turns each file it can into a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, and gathers everything in one [project collection](../../GLOSSARY.md#project-collection), the folder in your [project](../../GLOSSARY.md#project) that holds what one export import made.

The import works by file type. A [FASTA](../../GLOSSARY.md#fasta) file holds bases only, and a [GenBank](../../GLOSSARY.md#genbank) or [EMBL](../../GLOSSARY.md#embl) record holds bases together with a table of features. Each becomes a [reference bundle](../../GLOSSARY.md#reference-bundle), the `.lungfishref` folder in which LGE keeps a sequence and everything attached to it. A feature is a labeled stretch of the sequence, such as a gene or a coding sequence, and a record's features arrive as an [annotation track](../../GLOSSARY.md#annotation-track), one named set of features drawn together as one layer. Two importers do this work. The Geneious importer, `import geneious`, is the one behind the **Geneious Export** card. The general importer, `import application-export`, has no card and runs only from the command line, which means typing it into [Terminal](../../GLOSSARY.md#terminal), the macOS program for typing commands. It also turns alignment files, which line related sequences up column by column, and tree files, which hold a family tree of sequences, into bundles of their own. Because Geneious stores sequences in a format of its own, the Geneious importer decodes the nucleotide sequences of Geneious sequence lists, documents that hold lists of sequences, with their annotations, into reference bundles, and it decodes no other kind of document.

A file with no automatic place in a bundle is reported, not converted. A variant file, a read file, a table, or another program's own project file is either copied into the collection unchanged, as a [binary artifact](../../GLOSSARY.md#binary-artifact) (LGE's name for any untouched copy, even of a plain text file), or left out, depending on the importer and its settings. Every collection holds a report that counts what the import found and an inventory that names each file of the export and says where it went. Put simply, LGE reads the files of an export and never runs or reads the other program, so its settings, its saved workflows, and anything it keeps only inside itself stay behind. [What an export import keeps and leaves out](#what-an-export-import-keeps-and-leaves-out) lists what stays behind from a Geneious archive.

In practice, import the export, then read its report and its inventory to see what came across and what did not.

## Why you would do this

A lab that kept its references and annotations in another program can move them into LGE without retyping them or exporting each record by hand. They arrive as the same reference bundles every other import route makes, so a record you annotated elsewhere can serve as the reference when you map reads or call variants.

The practice export is the application-export-hbb [fixture](../../GLOSSARY.md#fixture), a small folder named `hbb-sequence-library` that imitates an export from a sequence library program. No such program wrote it. It holds 3 files. `HBB_region.gb` is a GenBank record of 3,000 bases of the human beta-globin (HBB) region with 42 features, cut from the [RefSeqGene](../../GLOSSARY.md#refseqgene) record `NG_000007.3`, a curated slice of human chromosome 11 from the National Center for Biotechnology Information (NCBI). HBB encodes the beta chain of adult hemoglobin. `HBB_region.vcf` is a [VCF](../../GLOSSARY.md#vcf) file, the standard table of positions where a sample differs from a reference, and it holds one variant, the sickle cell change that turns the `A` at position 614 of the record into a `T`. `index.csv` is a one-row index of the library in [CSV](../../GLOSSARY.md#csv), a plain text table with commas between its columns. A script cut the GenBank record from the public record and wrote the other two files itself. The same 3 files also come packed in one zip archive.

Importing this folder shows both halves of an export import. The GenBank record becomes a reference bundle carrying its 42 features. The variant file and the index are not converted, because an export import never attaches a variant file or a table to a reference. The general importer keeps them as copies with one warning each, and the Geneious importer leaves them out unless you ask for copies.

## Choosing a tool

Two importers read exports, and the program that wrote the export settles which one to use. The app has a card for only one of them.

The **Geneious Export** card sits on the **Application Exports** tab of the [Import Center](../../GLOSSARY.md#import-center), the window that brings files into the open project. It runs the command `lungfish-cli import geneious` for you, a line you could also type in Terminal, where `lungfish-cli` is the command-line program that ships inside LGE. It is built for an export from Geneious, either a `.geneious` archive or a folder that Geneious exported, and it also takes one exported file, which you can drop on the card or give to the command. It decodes the nucleotide sequences stored in Geneious sequence lists together with their annotations, and it turns any FASTA, GenBank, or EMBL file in the export into a reference bundle. By default it keeps no copy of the export and leaves every other file out, listing each one in the inventory. That keeps the collection small, and it means you read the inventory for what it skipped.

`lungfish-cli import application-export` takes exports from other programs, and you name the program with an [export kind](../../GLOSSARY.md#export-kind), a short name such as `clc-workbench` typed before the export's path. The export can be a folder, a `.zip`, `.qza`, or `.qzv` archive that LGE unpacks first, or a single file. The importer sorts files by type. It turns FASTA, GenBank, and EMBL files into reference bundles, alignment files into `.lungfishmsa` bundles that each hold one [multiple sequence alignment](../../GLOSSARY.md#msa), and tree files into `.lungfishtree` bundles. By default it copies every other file into the collection with a warning that names it and keeps a full copy of the export, so nothing is lost. It has no card in the app and runs only from the command line.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| **Geneious Export** card, `import geneious` | `.geneious` archives and Geneious export folders | The export came from Geneious | The export came from another program |
| `import application-export` | Exports of the 9 kinds in the next table | The export came from CLC Workbench, Benchling, QIIME 2, or another program the table names | The export is a Geneious archive, whose sequences only the Geneious importer decodes |

The kind names the collection and its report. For seven of the nine kinds it changes nothing else, since the importer sorts by file type whatever the kind. The other two, `alignment-tree` and `phylogenetics-result-set`, look for alignments and trees first. They also read a FASTA file as an alignment rather than a reference when it holds two or more sequences of equal length and either a sequence contains a gap character, `-` or `.`, or the file's name contains `align`, `msa`, `mafft`, or `muscle`, the last two being alignment programs. They copy no other file and make no copy of the export, and the import fails when an alignment or a tree cannot be read.

| Kind | Meant for | Collection name ends with |
|---|---|---|
| `clc-workbench` | A CLC Workbench export | `CLC Workbench Import` |
| `dnastar-lasergene` | A DNASTAR Lasergene or GenVision export | `DNASTAR Lasergene Import` |
| `benchling-bulk` | A Benchling bulk export | `Benchling Bulk Import` |
| `sequence-design-library` | A sequence design library export | `Sequence Library Import` |
| `alignment-tree` | An alignment or tree export | `Alignment Tree Import` |
| `sequencing-platform-run-folder` | A sequencing run folder or a downloaded analysis export | `Sequencing Run Import` |
| `phylogenetics-result-set` | A phylogenetics result set | `Phylogenetics Import` |
| `qiime2-archive` | A QIIME 2 archive or exported folder | `QIIME 2 Import` |
| `igv-session-track-set` | An IGV session file or a folder of local tracks | `IGV Session Import` |

A run folder's reads are copied and never become read bundles, so import reads as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes.

This chapter's fixture uses `sequence-design-library`, a kind that names no vendor. For your own data, choose the kind that names the program that wrote the export, or `alignment-tree` when the export holds only alignments and trees. The same fixture folder also works on the **Geneious Export** card for practice, because the Geneious importer reads plain sequence files in any folder.

## Before you start

You need a project open in LGE that you can write to, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows, since a read-only project, one whose window title says `(Read Only)`, cannot take an import. For the command-line procedure, create the project in LGE first with **File > New Project**, because `lungfish-cli` never creates the project store, the part of a project only LGE makes, as [On the command line](../01-foundations/06-the-lungfish-project.md#on-the-command-line) in that chapter explains.

Each sequence file, and each Geneious sequence list LGE decodes, becomes a reference bundle through the same import the **Reference Sequences** card runs, so the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) must be installed, as [Importing and Viewing a Sequence](01-importing-and-viewing.md#before-you-start) explains. Nothing else needs installing.

The fixture lives in the [application-export-hbb](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/application-export-hbb) folder on GitHub, whose README gives its source, license, and citation. Open `hbb-sequence-library.zip` there, click **Download raw file**, and save it in `~/Desktop/lge-docs/`, as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) describes. The `~` stands for your home folder, so make a folder named `lge-docs` on your Desktop in Finder first if it is missing. Double-click the downloaded zip in Finder to unpack it, which gives a folder named `hbb-sequence-library`. Keep both, since the command line takes either one. The fixture's files come to 24 KB.

## Procedure

### Import a Geneious archive with the Geneious Export card

No Geneious archive ships with this manual, since a real one comes from Geneious itself. The steps work the same for your own `.geneious` file or a folder of files exported from Geneious. How to write them is Geneious's business, so see [Importing and Exporting Data](https://manual.geneious.com/en/latest/ImportExport.html) in Geneious's own manual. For practice, use the fixture's `hbb-sequence-library` folder, which the Geneious importer reads like any folder of sequence files.

1. Open the Import Center with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Click the **Application Exports** tab. It holds one card, **Geneious Export**, with the hint `.geneious archive or Geneious export folder` below its description.

    <!-- SHOT: application-export-card -->

2. Drag the `.geneious` file or the export folder from Finder onto the card. If you prefer a file panel, click the card's **Import…** button and choose it there. The card takes one archive or one folder at a time.

3. Watch the import in the [Operations Panel](../../GLOSSARY.md#operations-panel), the list of jobs LGE runs, which **Operations > Show Operations Panel** (Cmd-Shift-P) opens. The row is titled **Geneious Import**. Its detail line names the file or folder and ends with `Imported` and the collection's name, followed by the number of warnings when there are any. Each warning is a line of the row's log, which its **Log** button opens. **Cancel** on the row stops the import, and the partial collection folder stays in the project.

4. Find the new collection in the [sidebar](../../GLOSSARY.md#sidebar), the project list on the left of the window, where LGE selects it when the import ends. It sits under `Geneious Imports/`, and its reference bundles are in its `LGE Bundles/` folder. Click one to open it in the [sequence viewport](../../GLOSSARY.md#sequence-viewport), the center pane that draws a sequence with its features.

For the practice folder, the collection is `Geneious Imports/hbb-sequence-library Geneious Import/`, and its `LGE Bundles/` folder holds one reference bundle, `HBB_region`. The row reports no warnings, because with the card's defaults the Geneious importer leaves the variant file and the index out without copying them, as [What an export import keeps and leaves out](#what-an-export-import-keeps-and-leaves-out) explains.

### Import another application's export folder with import application-export

The other kinds have no card, so this route uses Terminal. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains how to read the lines below.

1. In LGE, create the project with **File > New Project**, name it `Export Practice`, save it in `~/Desktop/lge-docs/`, and close its window so the command line can fill it. LGE saves the project as a folder named `Export Practice.lungfish`.

2. Open Terminal, in the Utilities folder inside Applications, and type the commands below. The first line stores the project's location in `PROJECT`, a name Terminal remembers, where `$HOME` is your home folder. The command after it names the kind, the export folder, and the project, and it names the collection with `--collection-name`, an [option](../../GLOSSARY.md#command-line-flag), which is a named switch typed after the command. A backslash at a line's end joins it to the next, so the command is one line. If Terminal answers that it cannot find `lungfish-cli`, [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to fix that.

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

`--preserve-raw-source` and `--no-preserve-raw-source` decide whether the collection gets a full copy of the export in its `Source` folder. `import geneious` and the card leave the copy out by default, and `import application-export` makes it, except for `alignment-tree` and `phylogenetics-result-set`, which never make it. Keep the copy when the original export is kept nowhere else, and leave it out when the export is large and safe where it is, since the copy duplicates every file of the export inside the project.

`--no-import-references` keeps FASTA, GenBank, and EMBL files as plain copies instead of turning them into reference bundles. Both commands convert them by default, because a reference bundle is what LGE's mapping and variant tools read. Use it only when the project already holds those references, and with `import geneious` add `--preserve-unsupported` too, or those files are left out entirely. It never affects the sequences decoded from Geneious sequence lists, which always become reference bundles.

`--preserve-unsupported` and `--no-preserve-unsupported` decide whether every file the import does not convert, such as a VCF, an annotation file, or a report, is copied into the collection's `Binary Artifacts` folder with a warning that names it. `import geneious` and the card leave such files out by default, and `import application-export` copies them, except for the two alignment and tree kinds, which never copy them. Turn copies on, from the command line, for a Geneious export that holds files you mean to attach later, and turn them off for another program's export when you want only the bundles.

## Reading the results

### The project collection an export import writes

Every export import writes one collection folder at the top of the project, under `Geneious Imports/` for the Geneious importer and under `Application Exports/` for the general one. The folder's name joins the collection name, the kind's name, and the word Import, as in `HBB sequence library Sequence Library Import`. A second import under the same name adds a counter, as in `HBB sequence library Sequence Library Import 2`, so nothing is overwritten.

| Inside the collection | What it holds |
|---|---|
| `LGE Bundles/` | The reference bundles, and with `import application-export` the alignment and tree bundles |
| `Binary Artifacts/` | Unchanged copies of the files that were not converted, when copies are on |
| `Source/` | A full copy of the export, when that setting is on |
| `import-report.md` | A plain text summary with the count of files of each kind, the bundles made, the copies kept, and the warnings |
| `inventory.json` | A list in [JSON](../../GLOSSARY.md#json), a structured text format programs read, with one entry per file and the place it went |

Both files show in the sidebar beside `LGE Bundles/`. Click one to preview it in the viewport, or right-click it and choose **Show in Finder** to find it on disk.

The collection also holds a [provenance](../../GLOSSARY.md#provenance) record, the file in which LGE notes how a result was made, including the command that repeats the import. The sidebar hides it, because it is the hidden file `.lungfish-provenance.json` in the collection folder.

<!-- SHOT: application-export-result -->

For the fixture imported from the command line, `Application Exports/HBB sequence library Sequence Library Import/` holds the reference bundle `HBB_region` in `LGE Bundles/`, copies of `HBB_region.vcf` and `index.csv` in `Binary Artifacts/`, the original `hbb-sequence-library` folder with its 3 files in `Source/`, and the report and the inventory. Click `HBB_region` to open it. It holds one sequence named `HBB_region`, 3,000 bases long, and its annotation track carries the record's 42 features, among them the HBB gene from position 545 to 2,152. The drawer along the bottom counts them, as [The table drawer](01-importing-and-viewing.md#the-table-drawer) shows. Each position in this record is its position in `NG_000007.3` minus 70,000, so the sickle cell codon, the 3 bases that code for the amino acid the change alters, sits here at 613 to 615 and reads `GAG`, as it does at 70,613 to 70,615 in [Importing and Viewing a Sequence](01-importing-and-viewing.md#go-to-a-position).

The report has five parts. For the fixture they read as the table shows.

| Part of `import-report.md` | What it says for the fixture |
|---|---|
| The opening lines | The source path, the source kind `folder` because you gave a folder, the application export `Sequence Library`, and `Items: 3`, the number of files |
| Counts | 1 file of each kind it recognized, `standaloneReferenceSequence` for `HBB_region.gb`, `variantTrack` for `HBB_region.vcf`, and `report` for `index.csv` |
| Native bundles | The path of `HBB_region.lungfishref` |
| Preserved artifacts | The paths of the copies of `HBB_region.vcf` and `index.csv` |
| Warnings | 1 line for each of those 2 files, saying it was recognized but not converted |

A Geneious report has the same parts, with the Geneious version the export recorded, or `unknown`, in place of the application export line.

In `inventory.json`, each file has its path inside the export, its kind, its size in bytes, its SHA-256 [checksum](../../GLOSSARY.md#checksum), a fingerprint of its exact bytes, and `lgeDestination`, the place in the collection it went to. For the fixture the sizes are 19,739 bytes for the GenBank record, 296 bytes for the VCF, and 128 bytes for the index. A file with no `lgeDestination` was left out.

### What an export import keeps and leaves out

The table lists what each importer does with each kind of file under its default settings. A Geneious data file is a file in a `.geneious` archive or a Geneious export folder that holds its documents.

| File in the export | `import geneious` and the card | `import application-export` |
|---|---|---|
| Nucleotide sequences in a Geneious sequence list | One reference bundle for each Geneious data file that holds sequence lists, with their annotations as a track | Not decoded, so the `.geneious` file is copied like any other file it does not convert |
| A Geneious document that is not a sequence list, or a sequence list with no nucleotide sequence, such as a protein list | Left out | Not decoded, and copied |
| A FASTA, GenBank, or EMBL file, compressed or not | A reference bundle | A reference bundle |
| An alignment file, such as `.aln`, `.phy`, or `.sto` | Left out | A `.lungfishmsa` bundle |
| A tree file, such as `.nwk`, `.tre`, or `.treefile` | Left out | A `.lungfishtree` bundle |
| A standalone annotation file, a table of features with no bases such as [GFF3](../../GLOSSARY.md#gff) or BED | Left out | Copied into `Binary Artifacts/` with a warning |
| A VCF, a [BAM](../../GLOSSARY.md#bam) file of aligned reads, [FASTQ](../../GLOSSARY.md#fastq) reads, a table, or a report | Left out | Copied into `Binary Artifacts/` with a warning |
| Another program's own project file, such as a `.clc` file | Left out | Copied, and not read |
| The export itself | Not copied | Copied into `Source/` |

Left out means not copied and still listed in the inventory, file by file. With `--preserve-unsupported`, `import geneious` copies each of those files into `Binary Artifacts/` with a warning instead.

LGE makes one bundle for each Geneious data file that holds sequence lists, and the bundle holds every nucleotide sequence of those lists that LGE can read, so a list of several sequences, or several lists in one file, still gives one bundle, which opens as [A FASTA file with several records](01-importing-and-viewing.md#a-fasta-file-with-several-records) describes. The bundle takes the name Geneious stored for the first list, or the file's name when none is stored, cleaned the way `--collection-name` is under [Settings](#settings), and its folder turns each space into an underscore.

LGE decodes only sequence lists, and from them only the sequences, their names, and their annotations. Every other kind of Geneious document stays in your original export, among them the alignment, assembly, tree, and note documents that Geneious's manual describes. The report names no skipped document. In `inventory.json`, a file with no `lgeDestination` was left out, and its `geneiousDocumentName` and `geneiousDocumentClass` give the name and class of its first document. The `documentClasses` entry lists every class in the archive, so any class that does not contain `DefaultSequenceListDocument` marks documents LGE did not decode.

Files that belong inside a reference bundle never get there by themselves, whichever importer you use. A standalone annotation file is never attached, even when it sits beside its sequence in the export, so attach it afterwards, from the copy or from your original, with the **Annotation Track** card, as [Attach a standalone annotation file](01-importing-and-viewing.md#attach-a-standalone-annotation-file) shows. A VCF never becomes a [variant track](../../GLOSSARY.md#variant-track), the named set of variant calls inside a reference bundle, so open the bundle and import the VCF as [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md#open-the-bundle-the-variants-belong-to) shows. A BAM never becomes an alignment track, the reads drawn on a bundle, so import it as [Import an alignment somebody else made](../04-alignments/01-mapping-reads-to-a-reference.md#import-an-alignment-somebody-else-made) shows. Reads never become read bundles, so import them as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows.

A Geneious document's annotations come across only for the sequences LGE decodes. An annotation arrives with its type, name, positions, strand, and qualifiers, the labeled notes a feature carries, and no other field. When a document's annotations cannot be read, a warning names the document, and its sequences arrive without those features.

## What good looks like

Check these four things before you work with the bundles.

1. The Operations Panel row, or the command's last line, reads `Imported`. A warning names each file kept as a copy, and a file the card leaves out gets no warning, only a line in the inventory, so the fixture gives 2 warnings with `import application-export` and none with the card.
2. `Items` in the report equals the number of files in the export, 3 for the fixture. Both importers skip hidden files, whose names start with a dot, so those are never counted. For a `.geneious` archive it counts the files LGE finds after unpacking it, both the Geneious data files and the `fileData` files that hold the documents' stored data, so it is not the number of documents.
3. Every sequence file you expected has a bundle under `LGE Bundles/`. Open one and check a position you know. For the fixture, **Sequence > Go to Location…** (Cmd-L) with `HBB_region:613-615` shows `GAG`.
4. Every file you still need that has no bundle is in `Binary Artifacts/`, or you know where else to find it.

Importing the zip instead of the folder with `import application-export` gives the same bundle and the same 2 warnings.

A failed or cancelled import leaves its partial collection folder in the project. Delete that folder, by right-clicking it in the sidebar and choosing **Move to Trash**, before you import again, or the next import writes a second collection with a counter after its name.

### When the import leaves out more than you expected

A Geneious collection whose inventory lists files with no `lgeDestination` skipped them under its default. Import the export again with `--preserve-unsupported` to keep copies of them, as the fifth command in [On the command line](#on-the-command-line) shows.

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

# 5. The Geneious importer again, keeping copies of the VCF and the CSV. Put your own export's path where the folder's is.
lungfish-cli import geneious "$HOME/Desktop/lge-docs/hbb-sequence-library" \
  --project "$PROJECT" --preserve-unsupported
```

## Next

Continue to [Downloading from NCBI](02-downloading-from-ncbi.md), which fetches a record from NCBI straight into the project when you have no export to bring in. To give the copied VCF a place in its bundle, see [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md), and for reads that came with an export, see [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

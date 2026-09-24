---
title: Primer Scheme Bundles
chapter_id: appendices/primer-schemes
audience: power-user
prereqs: [01-foundations/03-amplicon-vs-shotgun, 04-alignments/03-primer-trimming]
estimated_reading_min: 16
task: Read what a `.lungfishprimers` bundle holds, list the schemes Lungfish Genome Explorer ships, and build one of your own from a BED file.
tags: [reference, primer-scheme, amplicon, bed, provenance, sars-cov-2]
tools: []
entry_points:
  - "File > Import Center..."
  - "CLI: lungfish-cli primers import"
shots:
  - id: primer-scheme-import-card
    caption: "The Import Center on its Reference Sequences tab, with the Primer Scheme card and its file hint reading .bed (+ optional .fasta/.fa/.fna)."
  - id: primer-scheme-import-sheet
    caption: "The Import Primer Scheme sheet, showing the Files section with its BED and FASTA rows and the Identity section with its four text fields."
  - id: primer-scheme-inspector
    caption: "A primer scheme selected in the sidebar, with the Inspector showing the display name, the primer and amplicon counts, and the reference and equivalent accessions."
illustrations: []
glossary_refs: [amplicon, bed, boolean, canonical-accession, checksum, contig, equivalent-accession, exit-status, ivar, json, manifest, primer-pool, primer-scheme, primer-trim, provenance, shotgun, snake-case, tiling]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-primer-schemes"></a>

## What it is

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome.

Lungfish Genome Explorer (LGE) packages a primer scheme as a `.lungfishprimers` bundle. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. This one holds the primer coordinates, a [manifest](../../GLOSSARY.md#manifest) naming the protocol and the reference the coordinates were written against, and a record of where the scheme came from. The Primer Trim dialog and the Viral Recon wizard both read the bundle rather than a loose coordinate file, so the scheme name you pick cannot disagree with the coordinates the [primer trim](../../GLOSSARY.md#primer-trim) uses.

This appendix covers the `.lungfishprimers` format, the schemes LGE ships, and building a scheme from a BED file. To pick a shipped scheme, read [Shipped schemes](#shipped-schemes) and stop there. To use a kit LGE does not ship, such as a human or macaque amplicon panel, follow [Building a scheme from a BED file](#building-a-scheme-from-a-bed-file).

## Shipped schemes

LGE ships eight SARS-CoV-2 schemes inside the application. You never browse to them, because every one already appears in the **Primer Scheme** menu of the Primer Trim dialog and of the Viral Recon wizard. The schemes are viral because these kits are, and the format itself assumes nothing about the organism.

All eight target SARS-CoV-2 with [canonical accession](../../GLOSSARY.md#canonical-accession) `MN908947.3` and [equivalent accession](../../GLOSSARY.md#equivalent-accession) `NC_045512.2`. An accession is the identifier a public sequence database gives one record. The canonical accession is the one the coordinates were written against, and an equivalent accession names the same sequence deposited under a second identifier.

| Display name | Manifest `name` | Primers | Amplicons |
|---|---|---|---|
| ARTIC SARS-CoV-2 V4 | `ARTIC-SARS-CoV-2-V4` | 198 | 99 |
| ARTIC SARS-CoV-2 V4.1 | `ARTIC-SARS-CoV-2-V4.1` | 209 | 99 |
| ARTIC SARS-CoV-2 V5.3.2 | `ARTIC-SARS-CoV-2-V5.3.2` | 192 | 96 |
| ARTIC SARS-CoV-2 V3 | `ARTIC-nCoV-2019-V3` | 218 | 98 |
| Midnight 1200 bp V1 | `Midnight-1200-V1` | 58 | 29 |
| NEB VarSkip Long v1 | `NEB-VarSkip-Long-vsl1` | 50 | 29 |
| NEB VarSkip Short v1 | `NEB-VarSkip-vss1` | 148 | 74 |
| QIAseq Direct SARS-CoV-2 with Booster A | `QIASeqDIRECT-SARS2` | 563 | 223 |

The display name is what the menu shows. The manifest `name` is the file-safe identifier, which is also the folder name and the key the Primer Trim menu sorts on, which is why ARTIC V3 sits fourth there. The Viral Recon wizard sorts by display name instead.

Each amplicon needs a primer at each end, so the primer count should run to about twice the amplicon count. QIAseq Direct, ARTIC V4.1, and ARTIC V3 sit above that on purpose, because they carry extra primers. QIAseq Direct's 563 primers over 223 amplicons include its Booster A primers, added on top of the base design. The two ARTIC versions carry spare primers that restore amplicons the original design lost as the virus mutated where those primers bind. Both NEB VarSkip schemes carry spare primers too, but their manifests count some spares as amplicons of their own, so NEB VarSkip Long reads 29 amplicons where it has 25.

The right scheme is the one your wet-lab protocol used, read off the kit box rather than picked from the menu. Amplicon length is the practical difference between them. The four ARTIC versions and NEB VarSkip Short make amplicons of a few hundred bases, which suits short Illumina reads. Midnight 1200 bp V1 and NEB VarSkip Long make amplicons over a thousand bases, which suits the longer reads Oxford Nanopore produces.

## Bundle layout

To look inside a bundle, right-click it in Finder and choose **Show Package Contents**. A bundle the importer wrote has this shape.

```text
MacaqueMHC-v1.lungfishprimers/
  manifest.json
  primers.bed
  primers.fasta        # only when you supplied a primer FASTA
  attachments/         # only when you supplied documentation files
  PROVENANCE.md
  provenance/
  .lungfish-provenance.json   # hidden, a record of the import itself
```

`manifest.json`, `primers.bed`, and `PROVENANCE.md` are required. A bundle missing any of them is left out of the Primer Scheme menus without a message. The error appears only when you pick the bundle with **Choose Scheme...** or pass it to the command line, reading "Bundle is missing manifest.json.", "Bundle is missing primers.bed.", or "Bundle is missing PROVENANCE.md.". A manifest that is present but unreadable gives a message naming the parse failure instead. You meet these messages only if you assembled a bundle by hand, which works because the format is plain files, but the importer is the supported route.

`primers.fasta` holds the primer sequences and is optional, because the coordinates plus the reference genome already say what each primer's sequence is. Both routes can add it. `attachments/` holds vendor documentation, source spreadsheets, or lab notes that should travel with the scheme, and only the command line can add it.

`PROVENANCE.md` is the record you read yourself, and `provenance/` holds the machine-readable records, one per file the import wrote plus a `bundle.lungfish-provenance.json` for the run as a whole. [What the provenance records](#what-the-provenance-records) describes both.

The eight shipped schemes hold only `manifest.json`, `primers.bed`, and `PROVENANCE.md`. None ships a primer FASTA or a `provenance/` folder.

## BED expectations

`primers.bed` is a [BED](../../GLOSSARY.md#bed) file, a plain-text table with one primer per line and a tab character between columns. BED counts from 0 and GFF3 counts from 1, as [Standard annotation formats](file-formats.md#standard-annotation-formats) explains. Tabs and spaces look the same on screen, so if you edited your file by hand, turn on your text editor's show-invisibles view and check that each gap is one tab.

```text
MN908947.3	30	54	nCoV-2019_1_LEFT	1	+
MN908947.3	385	410	nCoV-2019_1_RIGHT	1	-
MN908947.3	320	342	nCoV-2019_2_LEFT	2	+
MN908947.3	704	726	nCoV-2019_2_RIGHT	2	-
```

The six columns are read as follows.

| Column | Holds | Rule |
|---|---|---|
| 1 | Contig name | Must equal the manifest's canonical accession. At trim time LGE renames it to match an alignment that uses one of the equivalent accessions. |
| 2 and 3 | Start and end | BED coordinates, so the first row's primer is 54 minus 30, or 24 bases. |
| 4 | Primer name | Must end in `_LEFT` or `_RIGHT` for the amplicon count to work, as described below. |
| 5 | [Primer pool](../../GLOSSARY.md#primer-pool) | The number of the PCR tube the primer belongs to, copied from your vendor's own numbering. |
| 6 | Strand | `+` for the forward primer of a pair and `-` for the reverse. |

In a [tiling](../../GLOSSARY.md#tiling) scheme, meaning one whose amplicons overlap end to end to cover a whole region, the pool alternates between 1 and 2. Neighbouring amplicons are then made in separate tubes, because two overlapping amplicons in one tube both amplify poorly.

### How LGE counts primers and amplicons

LGE counts every non-empty row that does not begin with `#` as one primer. It counts amplicons by removing the ending `_LEFT` or `_RIGHT` from each name in column 4 and counting the distinct names left.

After removing that ending it also drops a dash followed by one or two digits, so a spare primer named `QIAseq_221-2_LEFT` counts as the same amplicon as `QIAseq_221_LEFT`. The dash must come before `_LEFT` or `_RIGHT`, as it does in the QIAseq scheme. The other shipped schemes name spare primers with suffixes such as `_LEFT_alt1`, which this rule would count as separate amplicons, so their manifest counts came from the tool that built them rather than from this rule. A name such as `QIAseq_221_LEFT-1`, or a dash followed by three or more digits, counts as an amplicon of its own and inflates the count without a warning.

A scheme whose names follow neither convention still imports. Names such as `panel_fwd_01` and `panel_rev_01` give an amplicon count equal to the primer count, which is the sign the naming did not parse. Rename column 4 to the `NAME_LEFT` and `NAME_RIGHT` form in a text editor and import again. The Inspector shows the two counts side by side, so a count you did not expect points at the names rather than the coordinates.

### Matching the scheme to your alignment

The scheme has to name the same reference sequence as the alignment you trim. At trim time LGE compares the scheme's canonical and equivalent accessions with the sequence names in the alignment's header, first exactly and then ignoring a trailing version number and letter case, so `NC_045512` matches `NC_045512.2`. When nothing matches, the trim stops with an error that names the accessions the scheme expects and the names the alignment holds. The fix is to import the scheme again with the alignment's own sequence name as its canonical accession, or to override the match with `--target-reference` on the command line, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) describes.

## Building a scheme from a BED file

Both routes write the same bundle through the same code. The window route is complete for work inside a project. The command line adds attachments and suits a script.

### In the LGE window

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

<!-- SHOT: primer-scheme-import-card -->

1. Choose **File > Import Center...** and click the **Reference Sequences** tab.
2. Click the **Primer Scheme** card, whose file hint reads `.bed (+ optional .fasta/.fa/.fna)`. A sheet titled **Import Primer Scheme** opens.
3. In the **Files** section, click **Choose…** on the **BED** row and pick your BED file. If your vendor supplied a FASTA of the primer sequences, pick it on the **FASTA (optional)** row.
4. In the **Identity** section, fill the four fields as the table below describes.
5. Click **Import**, which stays disabled until a BED file, a name, and a canonical accession are set. LGE writes `Primer Schemes/<name>.lungfishprimers` into the project.

<!-- SHOT: primer-scheme-import-sheet -->

| Field | What to type |
|---|---|
| Name | A file-safe identifier such as `MacaqueMHC-v1`, which becomes the folder name. Use letters, digits, hyphens, and underscores. A slash is replaced with an underscore. |
| Display name | The label you want in the Primer Scheme menu. Leave it empty to use the name for both. |
| Canonical reference accession | The sequence name exactly as the alignment you will trim spells it. |
| Equivalent accessions | Other names for the same sequence, separated by commas. Leave it empty when your reference has only one name. |

To find how your alignment spells its sequence name, select the reference bundle in the sidebar and read the sequence name the Inspector shows. A filled-in set for the Midnight scheme reads `Midnight-1200-V1`, `Midnight 1200 bp V1`, `MN908947.3`, and `NC_045512.2`.

The sheet writes no description, organism, source link, or version into the manifest, so an imported scheme shows fewer fields in the Inspector than a shipped one. Those fields are labels only and change no trimming result.

<!-- SHOT: primer-scheme-inspector -->

<!-- FIXED-IN-2026.9.41: 1 -->
The new scheme appears in the sidebar under **Primer Schemes**, without its `.lungfishprimers` extension. Clicking it shows the scheme in the Inspector, with the display name at the top, the description when there is one, the primer and amplicon counts side by side, the reference accession and any equivalents, the organism, source, and version when the manifest has them, and a list of attachments at the foot. If clicking it raises "Failed to Open File" instead, that is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

The Inspector only displays a scheme. To change a field, import the scheme again under a new name, or open the bundle with **Show Package Contents** and edit `manifest.json` in a text editor.

## Manifest fields

`manifest.json` is a [JSON](../../GLOSSARY.md#json) file, plain text holding named fields that a program reads directly. Its keys are [snake_case](../../GLOSSARY.md#snake-case), meaning lowercase words joined by underscores.

| Field | Meaning |
|---|---|
| `schema_version` | Version of the bundle format, currently `1`. |
| `name` | File-safe bundle name, matching the folder name without its extension. |
| `display_name` | Label shown in the Primer Scheme menu and at the top of the Inspector. |
| `description` | Free-text description of the scheme. |
| `organism` | Target organism. |
| `reference_accessions` | List of accession records, described below. |
| `primer_count` | Number of primer rows in the BED. |
| `amplicon_count` | Number of distinct amplicon names in BED column 4. |
| `source` | `built-in` for the shipped schemes and `imported` for the importer's. |
| `version` | Scheme version text. |
| `created` | When the bundle was written. |
| `imported` | When the scheme was imported into a project, a separate event from `created`. |
| `attachments` | List of `{path, description}` records naming the files under `attachments/`. |
| `source_url` | Link to the scheme's upstream source. |

Only `schema_version`, `name`, `display_name`, `reference_accessions`, `primer_count`, and `amplicon_count` are required, and the importer also always writes `source`, `created`, and `imported`. LGE accepts a manifest without the rest, which is why an imported manifest is shorter than a shipped one. The order of the keys means nothing.

Each record in `reference_accessions` carries an `accession` and two [boolean](../../GLOSSARY.md#boolean) flags, values that are either true or false.

```json
"reference_accessions": [
  { "accession": "MN908947.3", "canonical": true },
  { "accession": "NC_045512.2", "equivalent": true }
]
```

The square brackets hold the list and each pair of curly braces holds one record. The canonical accession is the one the BED coordinates are defined against, and the equivalent accessions let LGE match an alignment that names the same sequence differently. A missing flag counts as false. If a hand-written manifest marks nothing canonical, LGE treats the first entry as canonical without a warning, so mark the flags rather than relying on the order.

## What the provenance records

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

An imported scheme's `PROVENANCE.md` has nine lines under its heading, naming the workflow, the tool version, the command, the start time, the BED source, the FASTA source or the words "not provided", the output bundle, the reference accession, and the exit status. A window import records the command as the app ran it rather than as you typed it. The `provenance/` folder holds the same run in machine-readable form, with a checksum and byte size for every input and output. It also records your macOS user name and macOS version, which is worth knowing before you share a bundle outside your group.

A shipped scheme's `PROVENANCE.md` was written by a different program and is longer. Its Reference Verification table gives a checksum of each declared accession's sequence as fetched from NCBI, and matching checksums on the canonical and equivalent rows show the two accessions hold the same sequence.

To confirm that two copies of a scheme are the same, compare the checksum of `primers.bed` in their provenance records, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#what-good-looks-like) describes. Compare `primers.bed` rather than `manifest.json`, because the importer copies the BED unchanged while the manifest's `created` and `imported` times differ on every import.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli primers import \
  --bed macaque-mhc.bed \
  --fasta macaque-mhc-primers.fasta \
  --output MacaqueMHC-v1 \
  --project "My Project.lungfish" \
  --reference-accession MHC-reference-v1 \
  --display-name "Macaque MHC panel v1" \
  --attachment kit-notes.txt
```

The file names and the accession here stand in for your own kit's. Only `--bed` and `--output` are required. Left off, `--reference-accession` is taken from the BED file's first column, and `--display-name` defaults to the output name. `--equivalent-accession` and `--attachment` may each be given more than once. With `--project`, a relative `--output` lands in that project's `Primer Schemes/` folder, which is where the Primer Scheme menus look, and `.lungfishprimers` is added when you leave it off.

A second import to the same place does not overwrite the first. It stops with a message that a primer scheme bundle already exists there, so a rerun of a setup script cannot replace a scheme other results were trimmed against. `lungfish-cli primers` has no subcommand that lists or prints a scheme, so read `manifest.json` directly.

## Next

Go to [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) to apply a scheme to a mapped alignment, or to [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) to run one through the whole SARS-CoV-2 pipeline.

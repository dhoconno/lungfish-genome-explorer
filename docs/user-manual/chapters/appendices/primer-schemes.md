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
  - "File > Import Center…"
  - "CLI: lungfish-cli primers import"
shots:
  - id: primer-scheme-import-card
    caption: "The Import Center on its Reference Sequences tab, with the Primer Scheme card and its file hint reading .bed (+ optional .fasta/.fa/.fna)."
  - id: primer-scheme-import-sheet
    caption: "The Import Primer Scheme sheet, showing the Files section with its BED and FASTA rows and the Identity section with its four text fields."
  - id: primer-scheme-inspector
    caption: "A primer scheme selected in the sidebar, with the Inspector showing the display name, the primer and amplicon counts, and the reference and equivalent accessions."
illustrations: []
glossary_refs: [allele, amplicon, bed, boolean, bundle, canonical-accession, checksum, contig-reference, coordinate, design-reference, equivalent-accession, exit-status, fasta, inspector, iupac-ambiguity-code, ivar, json, manifest, mapper, mhc, msa, operations-panel, primer-pool, primer-scheme, primer-trim, probe, provenance, reference-bundle, refseq, shotgun, sidebar, snake-case, subcommand, terminal, tiling]
features_refs: [import.primer-scheme, primer-analysis.scheme-from-analysis]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-primer-schemes"></a>

## What it is

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome.

Lungfish Genome Explorer (LGE) packages a primer scheme as a `.lungfishprimers` bundle. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. This one holds the primer [coordinates](../../GLOSSARY.md#coordinate), meaning start and end positions on one named reference sequence, a [manifest](../../GLOSSARY.md#manifest) naming the protocol and that reference, and a record of where the scheme came from. The Primer Trim dialog ([Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md)) and the Viral Recon wizard ([The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md)) both read the bundle rather than a loose coordinate file, so the scheme name you pick cannot disagree with the coordinates the [primer trim](../../GLOSSARY.md#primer-trim) uses.

A scheme can come from three places. Eight ship inside the application, you can import one from a kit's [BED](../../GLOSSARY.md#bed) file, which its maker usually publishes, and LGE's own design tools can save one from a tiled design, as [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) does. To pick a shipped scheme, read [Shipped schemes](#shipped-schemes) and stop there. To use a kit LGE does not ship, such as a human or macaque amplicon panel, follow [Building a scheme from a BED file](#building-a-scheme-from-a-bed-file). For one you designed in LGE, read [Saving a designed scheme](#saving-a-designed-scheme).

## Shipped schemes

LGE ships eight SARS-CoV-2 schemes inside the application. You never browse to them, because every one already appears in the **Primer Scheme** menu of the Primer Trim dialog and in the **Scheme** menu of the **Primer scheme** section of the Viral Recon wizard. The schemes are viral because these kits are, and the format itself assumes nothing about the organism.

All eight target SARS-CoV-2 with [canonical accession](../../GLOSSARY.md#canonical-accession) `MN908947.3` and [equivalent accession](../../GLOSSARY.md#equivalent-accession) `NC_045512.2`. An accession is the identifier a public sequence database gives one record. The canonical accession is the one the coordinates were written against, and an equivalent accession names the same sequence deposited under a second identifier. Here `MN908947.3` is the GenBank record and `NC_045512.2` is NCBI's curated [RefSeq](../../GLOSSARY.md#refseq) copy, and only matching [checksums](../../GLOSSARY.md#checksum) show that two names hold one sequence.

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

The display name is what the menu shows. The manifest `name` is the file-safe identifier, which is also the folder name.

Each amplicon needs a primer at each end, so the primer count should run to about twice the amplicon count. QIAseq Direct, ARTIC V4.1, and ARTIC V3 sit above that on purpose, because they carry extra primers. QIAseq Direct's 563 primers over 223 amplicons include its Booster A primers, which its manifest calls "additional spike/N-region primers for variant coverage". The NEB VarSkip schemes add no extra primers, because an alternate primer, marked `_alt` in its name, replaces the standard one at some amplicon ends, 4 in Long and 15 in Short, and the Long manifest reads 29 amplicons where its primer file defines 25.

The right scheme is the one your wet-lab protocol used, read off the kit box rather than picked from the menu. Amplicon length is the practical difference between them. The four ARTIC versions and NEB VarSkip Short make amplicons of a few hundred bases, which suits short Illumina reads. Midnight 1200 bp V1 and NEB VarSkip Long make amplicons over a thousand bases, which suits the longer reads Oxford Nanopore produces.

## Bundle layout

To look inside a bundle, right-click it in the [sidebar](../../GLOSSARY.md#sidebar), choose **Show in Finder**, and open the folder that Finder selects. A bundle the importer wrote has this shape.

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

`manifest.json`, `primers.bed`, and `PROVENANCE.md` are required. A bundle missing any of them is left out of the Primer Scheme menus without a message. The error appears only when you pick the bundle with **Choose Scheme…**, the button beside the **Primer Scheme** menu, or pass it to the [command line](cli-reference.md#before-you-type-anything), reading "Bundle is missing manifest.json.", "Bundle is missing primers.bed.", or "Bundle is missing PROVENANCE.md.". A manifest that is present but unreadable gives a message that begins "manifest.json is invalid" instead. You meet these messages only if you assembled a bundle by hand, and the importer is the supported route.

`primers.fasta` holds the primer sequences in [FASTA](../../GLOSSARY.md#fasta) form and is optional, because the coordinates plus the reference genome already say what each primer's sequence is. Every route can add it. `attachments/` holds files that should travel with the scheme, vendor documentation, source spreadsheets or lab notes on an imported scheme, and on a designed scheme the [design reference](../../GLOSSARY.md#design-reference) the coordinates belong to. The import sheet cannot add attachments, while the command line can and **Save as Primer Scheme…** always adds the design reference.

`PROVENANCE.md` is the [provenance](../../GLOSSARY.md#provenance) record you read yourself, and `provenance/` holds the same facts in a form a program reads, one record per file the import wrote plus a `bundle.lungfish-provenance.json` for the run as a whole. You can leave the hidden `.lungfish-provenance.json` alone. [What the provenance records](#what-the-provenance-records) describes both.

The eight shipped schemes hold only `manifest.json`, `primers.bed`, and `PROVENANCE.md`. None ships a primer FASTA or a `provenance/` folder.

## BED expectations

`primers.bed` is a [BED](../../GLOSSARY.md#bed) file, a plain-text table with one primer per line and a tab character between columns. BED counts from 0, so a start of 30 is the 31st base, and an end of 54 is the last base, the 54th, as [Standard annotation formats](file-formats.md#standard-annotation-formats) explains. Tabs and spaces look the same on screen, but LGE splits columns only at tabs, so a file with spaces between columns imports without an error and shows 0 for **Amplicons** in the [Inspector](../../GLOSSARY.md#inspector).

```text
MN908947.3	30	54	nCoV-2019_1_LEFT	1	+
MN908947.3	385	410	nCoV-2019_1_RIGHT	1	-
MN908947.3	320	342	nCoV-2019_2_LEFT	2	+
MN908947.3	704	726	nCoV-2019_2_RIGHT	2	-
```

The six columns are read as follows.

| Column | Holds | Rule |
|---|---|---|
| 1 | Name of the [contig](../../GLOSSARY.md#contig-reference) the primer sits on | Must equal the manifest's canonical accession, so copy that name into the import sheet. At trim time LGE renames rows that carry exactly that name to match an alignment that uses an equivalent accession. |
| 2 and 3 | Start and end | BED coordinates, so the first row's primer covers the 31st to the 54th base, which is 54 minus 30, or 24 bases. |
| 4 | Primer name | Must carry `_LEFT` or `_RIGHT` after the amplicon name, with an optional suffix such as `_alt1`, for the amplicon count to work, as described below. |
| 5 | [Primer pool](../../GLOSSARY.md#primer-pool) | The number of the PCR tube the primer belongs to, copied from your vendor's own numbering, with any letters changed to whole numbers. |
| 6 | Strand | `+` for the forward primer of a pair and `-` for the reverse. |

In a [tiling](../../GLOSSARY.md#tiling) scheme, meaning one whose amplicons overlap end to end to cover a whole region, the pool usually alternates between 1 and 2, and seven of the eight shipped schemes use those two pools while NEB VarSkip Short writes 0 on every row. Where it alternates, neighboring amplicons are made in separate tubes, because two overlapping amplicons in one tube both amplify poorly. LGE reads only columns 1 and 4 when it imports, so no pool value stops an import, and it hands column 5 to the trimmer [iVar](../../GLOSSARY.md#ivar) unchanged, so use whole numbers as the shipped schemes do.

If you start from a vendor's table, put one primer on each row with no header row. If the table counts from 1 and includes both ends, subtract 1 from each start and keep each end, so 31 to 54 becomes `30` and `54` in the BED. Save the sheet as tab-delimited text with the ending `.bed`.

### How LGE counts primers and amplicons

LGE counts every non-empty row that does not begin with `#` as one primer. It counts amplicons by removing the role tag from each name in column 4, which is `_LEFT` for a forward primer, `_RIGHT` for a reverse one, or `_PROBE` for a [probe](../../GLOSSARY.md#probe) oligo, together with any underscore-separated suffix after the tag, such as `_alt1` or `_2`, and counting the distinct names left.

After removing the tag it also drops a dash followed by one or two digits. A name such as `QIAseq_221_LEFT-1`, or a dash followed by three or more digits, counts as an amplicon of its own and inflates the count without a warning. The table shows how five names count.

| Name in column 4 | Counts as | Why |
|---|---|---|
| `nCoV-2019_1_LEFT` | `nCoV-2019_1` | The tag goes. |
| `nCoV-2019_2_LEFT_alt1` | `nCoV-2019_2` | The suffix after the tag goes too. |
| `QIAseq_221-2_LEFT` | `QIAseq_221` | The dash before the tag goes too. |
| `QIAseq_221_LEFT-1` | `QIAseq_221_LEFT` | The dash comes after the tag, so the tag stays. |
| `panel_fwd_01` | `panel_fwd_01` | No tag, so its own amplicon. |

A scheme whose names carry neither a tag nor a dash number still imports. Names such as `panel_fwd_01` and `panel_rev_01` give an amplicon count equal to the primer count, which is the sign LGE found no tag to remove. Rename column 4 to the `NAME_LEFT` and `NAME_RIGHT` form in a text editor and import again under a new name. The Inspector shows both counts. They are labels, since a trim does not use them.

### Matching the scheme to your alignment

The scheme has to name the same reference sequence as the alignment you trim. At trim time LGE compares the scheme's canonical and equivalent accessions with the sequence names in the alignment's header, the list of sequences at the top of a BAM file, first exactly and then ignoring a trailing version number and letter case, so `NC_045512` matches `NC_045512.2`. When nothing matches, the trim stops with an error in the **Primer Trim Failed** alert that names the accessions the scheme expects and the names the alignment holds. The fix is to import the scheme again under a new name, filling the two accession fields as [In the LGE window](#in-the-lge-window) describes. On the command line, `--target-reference` only picks which of the scheme's own names to look for, and the Primer Trim dialog has no such control.

A matching name does not prove that the bases match, and a new version number means a revised sequence, so read the trim rate in the [Operations Panel](../../GLOSSARY.md#operations-panel) log after every trim. It is the share of reads in which iVar found a primer to clip, and [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md#what-good-looks-like) expects the high nineties on a well-tiled library and calls anything below about 90 percent a reason to stop.

For a designed scheme the match is easier to get right, because the sequence the coordinates belong to travels inside the bundle. Import `attachments/design-reference.fasta` as a [reference bundle](../../GLOSSARY.md#reference-bundle), as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md#import-the-record) shows, map the reads to it, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, and the names agree because the scheme was designed on that sequence. Mapping to a different copy of the same gene, even the accession the design started from, shifts every position by however many bases the two differ by, and the trim then removes the wrong bases or none at all.

## Building a scheme from a BED file

The window and the typed command `lungfish-cli primers import` write the same bundle. The window route is complete for work inside a project. The command line adds attachments and suits a script, a saved list of commands.

### In the LGE window

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows, because the scheme is written into the project's `Primer Schemes` folder. Without one, the card shows an alert titled **No Project Open** in place of the sheet.

<!-- SHOT: primer-scheme-import-card -->

1. Choose **File > Import Center…** and click the **Reference Sequences** tab.
2. Click the **Primer Scheme** card, whose file hint reads `.bed (+ optional .fasta/.fa/.fna)`. A sheet titled **Import Primer Scheme** opens. Dropping a BED file on the card opens the same sheet with that file already chosen.
3. In the **Files** section, click **Choose…** on the **BED** row and pick your BED file, which [BED expectations](#bed-expectations) shows how to make. If your vendor supplied a FASTA of the primer sequences, pick it on the **FASTA (optional)** row.
4. In the **Identity** section, fill the four fields as the table below describes.
5. Click **Import**, which stays disabled until a BED file, a name, and a canonical accession are set. LGE writes `Primer Schemes/<name>.lungfishprimers` into the project. A name already used there is refused with a message under the fields, so an earlier scheme is never replaced.

<!-- SHOT: primer-scheme-import-sheet -->

| Field | What to type |
|---|---|
| **Name (file-safe, e.g. QIASeqDIRECT-SARS2)** | A file-safe identifier such as `MacaqueMHC-v1`, which becomes the folder name. Use letters, digits, hyphens, and underscores. A slash is replaced with an underscore. |
| **Display name (e.g. QIAseq Direct SARS-CoV-2)** | The label you want in the Primer Scheme menu. Leave it empty to use the name for both. |
| **Canonical reference accession (e.g. MN908947.3)** | The sequence name exactly as column 1 of your BED spells it. For a panel on several chromosomes, first edit column 1 to the alignment's spelling, then give the first row's name. |
| **Equivalent accessions**, which the sheet marks comma-separated and optional | The name your alignment uses when it differs from the BED's, separated by commas. Leave it empty when they agree. |

To read how your alignment spells its sequence name, click its reference bundle in the sidebar, open the Inspector's **Bundle** tab, and read **Name** under **Chromosome**, which shows the first sequence. [Bundle and contig names by route](file-formats.md#bundle-and-contig-names-by-route) lists the names each import route gives.

| Field | Midnight 1200 bp V1, shipped | Macaque panel, stand-in values |
|---|---|---|
| Name | `Midnight-1200-V1` | `MacaqueMHC-v1` |
| Display name | `Midnight 1200 bp V1` | `Macaque MHC panel v1` |
| Canonical reference accession | `MN908947.3` | `chr1`, the first row's name after column 1 is edited to match the alignment |
| Equivalent accessions | `NC_045512.2` | none |

The sheet writes no description, organism, source link, or version into the manifest, so an imported scheme shows fewer fields in the Inspector than a shipped one. Those fields are labels only and change no trimming result.

<!-- SHOT: primer-scheme-inspector -->

The new scheme appears in the sidebar under **Primer Schemes**, without its `.lungfishprimers` extension. Clicking it shows the scheme in the Inspector, with the display name at the top, the description when there is one, the primer and amplicon counts side by side, the reference accession and any equivalents, the organism, source, and version when the manifest has them, and a list of attachments at the foot. Compare the **Primers** and **Amplicons** counts with your kit's datasheet totals, since a header row left in adds one to both. The scheme then appears under **In This Project** in the Primer Trim dialog's **Primer Scheme** menu and, as "(Project)" after its name, in the Viral Recon wizard's **Scheme** menu.

The Inspector only displays a scheme. To change a field, import the scheme again under a new name, or open the bundle in Finder and edit `manifest.json` in a text editor.

## Saving a designed scheme

A tiled design made in LGE becomes a scheme without a kit's BED file, since LGE writes the BED itself. In the Results tab of the primer analysis viewer, which [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md) describes, or in the Inspector's View tab, **Save as Primer Scheme…** writes `Primer Schemes/<scheme name>.lungfishprimers` into the same project, and `lungfish-cli primers scheme-from-analysis` writes the same bundle. **Copy CLI Command**, where CLI is short for command-line interface, on the save's row in the [Operations Panel](../../GLOSSARY.md#operations-panel) gives that command. [Save a tiled scheme as a primer scheme](../10-primer-design/05-reviewing-and-ordering-primers.md#save-a-tiled-scheme-as-a-primer-scheme) is the procedure.

Only a tiled result can be saved. PrimalScheme, Olivar and tiled varVAMP designs qualify, as [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md#choosing-a-tool) compares them, and Primer3 candidate pairs and varVAMP qPCR assays do not, because they are alternatives rather than one scheme, which is what the caption beside the dimmed button says. A result whose primers sit on more than one reference, such as a combined PrimalScheme panel, is refused, because a bundle names one reference, so save each single-reference result instead. Probe oligos are left out of the BED, because trimming applies to primers only, and a note in the result says how many were left out.

A designed scheme differs from an imported one in at least four ways.

- Its manifest `source` reads `designed`, beside `built-in` for the shipped schemes and `imported` for the importer's.
- Its `display_name` joins the analysis name and the result's label with a centered dot, as in `Mamu-A1 tiled PrimalScheme · mamu-a1-panel`, and the **Scheme name** field sets the folder name.
- It always carries `attachments/design-reference.fasta`, the sequence the engine designed on, with the description "Design reference the BED coordinates belong to. Map reads to this sequence before primer trimming."
- Its canonical accession is that design reference's own name, which is the name of the first row of the [multiple sequence alignment](../../GLOSSARY.md#msa) for PrimalScheme and a generated name for the other two, such as `varVAMP_ambiguous_consensus`.

That last point is the one to act on. An imported kit's coordinates belong to a database accession you can fetch, while a designed scheme's coordinates belong to whatever the engine designed on. For PrimalScheme that is the first row of the alignment without its gaps, so the scheme also records the row's internal identifier as an equivalent accession. For Olivar it is a reference Olivar generated, which is no single input sequence. For varVAMP it is an ambiguous consensus carrying [IUPAC ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code), which matches no real sequence at all, so a [mapper](../../GLOSSARY.md#mapper) scores those positions as mismatches. Import `attachments/design-reference.fasta` and map your reads to it before trimming, as [Matching the scheme to your alignment](#matching-the-scheme-to-your-alignment) describes.

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
| `source` | `built-in` for the shipped schemes, `imported` for the importer's, and `designed` for one saved from an LGE design. |
| `version` | Scheme version text. |
| `created` | When the bundle was written. |
| `imported` | When the scheme was imported into a project, a separate event from `created`. |
| `attachments` | List of `{path, description}` records naming the files under `attachments/`. |
| `source_url` | Link to the scheme's upstream source. |

Only `schema_version`, `name`, `display_name`, `reference_accessions`, `primer_count`, and `amplicon_count` are required, and the importer also always writes `source`, `created`, and `imported`. LGE accepts a manifest without the rest, which is why an imported manifest is shorter than a shipped one. The order of the keys means nothing.

Each record in `reference_accessions` carries an `accession` and two [boolean](../../GLOSSARY.md#boolean) flags, `canonical` and `equivalent`, each true or false and counted as false when left out, so the example sets one per record.

```json
"reference_accessions": [
  { "accession": "MN908947.3", "canonical": true },
  { "accession": "NC_045512.2", "equivalent": true }
]
```

The square brackets hold the list and each pair of curly braces holds one record. The canonical accession is the one the BED coordinates are defined against, and the equivalent accessions let LGE match an alignment that names the same sequence differently. If a hand-written manifest marks nothing canonical, LGE treats the first entry as canonical without a warning, so mark the flags rather than relying on the order.

## What the provenance records

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

An imported scheme's `PROVENANCE.md` has nine lines under its heading, naming the workflow (the operation that wrote the bundle), the tool version, the command, the start time, the BED source, the FASTA source or the words "not provided", the output bundle, the reference accession, and the [exit status](../../GLOSSARY.md#exit-status), which reads 0 for an import that worked. A window import has no command you typed, so LGE writes a stand-in that names the Import Center. The `provenance/` folder holds the same run in machine-readable form, with a checksum and byte size for every input and output. It also records your macOS version and processor type but never your account name. `PROVENANCE.md` does list the full path of your BED file and of the bundle, which usually holds your account name, so read it before you share a bundle outside your group.

Seven of the eight shipped schemes have a `PROVENANCE.md` that was written by a different program and is longer. Its Reference Verification table gives a checksum of each declared accession's sequence as fetched from NCBI, and matching checksums on the canonical and equivalent rows show the two accessions hold the same sequence. The QIAseq Direct file is a short prose note with no such table.

To confirm that two copies of a scheme are the same, compare the checksum of `primers.bed` in their provenance records, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#what-good-looks-like) describes. Compare `primers.bed` rather than `manifest.json`, because the importer copies the BED unchanged while the manifest's `created` and `imported` times differ on every import.

## On the command line

The window route above does everything this one does for a scheme inside a project except add attachments, so read this section only if you script your imports or need a bundle outside a project. The `lungfish-cli` program ships inside LGE. [Before you type anything](cli-reference.md#before-you-type-anything) shows how to open [Terminal](../../GLOSSARY.md#terminal) and [Finding the program](cli-reference.md#finding-the-program) how to run it.

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

The file names and the accession here stand in for your own kit's. Only `--bed` and `--output` are required. Left off, `--reference-accession` is taken from the BED file's first column, and `--display-name` defaults to the output name. `--equivalent-accession` and `--attachment` may each be given more than once. With `--project`, an `--output` given as a bare name, meaning a name with no folder in front, lands in that project's `Primer Schemes/` folder, which is where the Primer Scheme menus look, and `.lungfishprimers` is added when you leave it off.

A second import to the same place does not overwrite the first. It stops with a message that a primer scheme bundle already exists there, so a rerun of a setup script cannot replace a scheme other results were trimmed against. `lungfish-cli primers` has no [subcommand](../../GLOSSARY.md#subcommand) that lists or prints a scheme, so read `manifest.json` directly.

## Next

To apply a scheme to a mapped alignment, click the mapping result under **Analyses** in the sidebar, open the Inspector's **Analysis** tab, click its **Primer Trim** tab, and click **Primer-trim BAM…**, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows. Go to [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) to run one through the whole SARS-CoV-2 pipeline. To design a scheme of your own rather than import one, see [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md).

A designed viral scheme leads to that trimming chapter and then [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), because amplicon reads need trimming before variants are called. A designed [MHC](../../GLOSSARY.md#mhc) panel leads to [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md), which reads amplicons against an [allele](../../GLOSSARY.md#allele) library and needs no primer scheme, so save a scheme there only if you also want the primer positions trimmed out of the reads first.

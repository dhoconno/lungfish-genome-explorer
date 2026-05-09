---
title: Downloading from NCBI
chapter_id: 02-sequences/02-downloading-from-ncbi
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 02-sequences/01-importing-and-viewing]
estimated_reading_min: 8
task: Download a reference sequence and its annotations from NCBI by accession.
tags: [sequences, ncbi, download, fasta, gff3, genbank, accession]
tools: []
entry_points:
  - "Tools > Search Online Databases > Search NCBI"
  - "CLI: lungfish fetch ncbi"
shots: []
planned_shots:
  - id: ncbi-search-dialog
    caption: "The NCBI search dialog with an accession entered and a format selected."
  - id: ncbi-bundle-prompt
    caption: "The post-download prompt offering to assemble a reference bundle from a FASTA and matching GFF3."
illustrations:
  - id: ncbi-accession-anatomy
    caption: "How an NCBI accession decomposes into prefix, number, and version, and which fetch path to use."
glossary_refs: [reference-genome, reference-bundle, GFF, SRA]
features_refs: [fetch.ncbi]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

NCBI hosts public reference sequences for every well-studied organism, identified by accession numbers like `MN908947.3` (a SARS-CoV-2 isolate) or `NC_045512.2` (the RefSeq record for the same isolate). Lungfish fetches these directly through `Tools > Search Online Databases > Search NCBI`. The dialog accepts an accession, a format (FASTA, GenBank, GFF3, or XML), and a save location. The Operations Panel runs the fetch and writes the file plus a provenance sidecar to the project's `Downloads/` folder.

For variant-calling workflows you usually want both the FASTA (the sequence) and the GFF3 (the annotations), fetched as two separate operations against the same accession. Lungfish then offers to bundle them together as a reference bundle, attaching the annotations to the FASTA so downstream tools can use both. This matters because some callers (iVar in particular) need annotations to translate nucleotide changes into amino-acid changes; without a bundled GFF3, the AA columns in your VCF will be empty.

So what should you do with this? When you start a project against a known reference, fetch the FASTA and GFF3 once, accept the bundle prompt, and reuse the resulting `.lungfishref` for every downstream operation in the project.

## What you will learn

By the end of this chapter you will be able to download a sequence by accession, choose between FASTA, GenBank, and GFF3 format depending on what your workflow needs, find the file in the `Downloads/` folder, and bundle a FASTA + GFF3 pair into a reference bundle that downstream chapters can use.

## Accession types: when to use which fetch path

NCBI uses different accession schemes for different kinds of records, and they go through different Lungfish commands. The two you will see most often are nucleotide accessions (one molecule, one record) and assembly accessions (a whole genome with chromosomes, scaffolds, and annotation packaged together).

<!-- ILLUSTRATION: ncbi-accession-anatomy -->

A nucleotide accession looks like `MN908947.3`: a two-letter prefix, a number, a dot, and a version. These are the records that come back from `Tools > Search Online Databases > Search NCBI` and from `lungfish fetch ncbi`. Almost every viral reference in common use is a nucleotide accession, because viral genomes are usually one molecule.

An assembly accession looks like `GCF_009858895.2` (RefSeq) or `GCA_009858895.3` (GenBank). These are not single records; they are bundles of FASTA, annotation, and metadata for an entire assembled genome. Lungfish handles them through a different command, `lungfish fetch genome`, which is documented in the Genomes chapter. If you paste an assembly accession into the NCBI dialog covered here, the dialog will refuse it.

The rest of this chapter covers nucleotide accessions only.

## Format choices: what each one contains

The dialog gives you four format choices. They differ in what is in the file, and therefore in what you can do with it next.

| Format | What is in the file | When to choose it |
|---|---|---|
| FASTA | The raw sequence and a one-line header. No annotations. | Mapping reads, calling variants, any workflow that only needs the bases. |
| GenBank | The sequence plus a curated, human-readable annotation block (genes, products, references). | Browsing a record manually; reading the curator's notes; one-stop view of a small genome. |
| GFF3 | A tab-separated table of features (gene, CDS, mat_peptide) with start, end, strand, and attributes. No sequence. | Pairing with a FASTA so a variant caller can translate to amino-acid changes. |
| XML | The full INSDC XML record, all fields, machine-readable. | Power-user pipelines that parse fields the GUI does not surface. |

For most variant-calling work the right pair is FASTA + GFF3. GenBank is convenient for one-off browsing but Lungfish does not currently extract annotations from a GenBank file into a bundle, so for downstream tooling the GFF3 is the format that carries forward.

## Procedure: download a reference by accession

The steps below assume you have an open project. If you do not, create one first via `File > New Project`.

<!-- planned: ncbi-search-dialog -->

1. Choose `Tools > Search Online Databases > Search NCBI`. The database search dialog opens.
2. In the **Accession** field, type or paste the accession (for example, `MN908947.3`).
3. From the **Format** menu, choose `FASTA`. Leave the save location at its default, which is the project's `Downloads/` folder.
4. Click `Run`. The dialog closes and a row appears in the Operations Panel showing the fetch in progress.
5. When the row turns green, the file is on disk. Repeat steps 1 to 4 with the same accession but Format set to `GFF3`.

After the second download finishes, Lungfish detects that you now have a FASTA and a matching GFF3 for the same accession in `Downloads/` and shows a prompt offering to assemble them into a reference bundle. Accepting the prompt writes a `.lungfishref` to `Reference Sequences/` with the FASTA as the primary sequence and the GFF3 attached as the annotation track.

<!-- planned: ncbi-bundle-prompt -->

If you decline the prompt, the two files stay loose in `Downloads/` and you can bundle them later from the Inspector by selecting the FASTA and choosing `Make Reference Bundle`.

## Worked example: SARS-CoV-2 reference (MN908947.3)

This is the most common starting point for a viral variant-calling project, and most chapters later in the manual assume you have it.

1. With your project open, choose `Tools > Search Online Databases > Search NCBI`.
2. Type `MN908947.3` into the **Accession** field. Choose `FASTA` from the **Format** menu. Click `Run`.
3. Wait for the Operations Panel row "Fetch NCBI: MN908947.3 (fasta)" to turn green. This usually takes a second or two for a viral genome over a normal connection.
4. Open the dialog again, paste `MN908947.3` into **Accession**, choose `GFF3`, and click `Run`.
5. When the second fetch completes, Lungfish shows the prompt: "A FASTA and GFF3 for MN908947.3 are now in Downloads. Assemble a reference bundle?" Click `Bundle`.

You should now see, under the project sidebar:

- `Downloads/MN908947.3.fasta` and its `.lungfish-provenance.json` sidecar
- `Downloads/MN908947.3.gff3` and its sidecar
- `Reference Sequences/MN908947.3.lungfishref` containing both, plus a `provenance/` subdirectory recording the bundle assembly step

The bundle is what later chapters will refer to when they say "select the SARS-CoV-2 reference".

The same operation runs from the command line as two `lungfish fetch ncbi` invocations followed by a bundle assembly. The CLI form is useful for scripted setup or for reproducing a colleague's project from a methods paragraph:

```sh
lungfish fetch ncbi MN908947.3 \
  --fetch-format fasta \
  --save-to ./Downloads/MN908947.3.fasta

lungfish fetch ncbi MN908947.3 \
  --fetch-format gff3 \
  --save-to ./Downloads/MN908947.3.gff3
```

Each invocation writes its own provenance sidecar next to the output file, recording the resolved endpoint, the accession, the output checksum, the file size, and the exact command line.

## Interpretation: what the provenance sidecar tells you

Every NCBI fetch writes a `<filename>.lungfish-provenance.json` next to the output. Open one and you will see the source URL it actually hit (so you can confirm whether you fetched from `eutils.ncbi.nlm.nih.gov` or a mirror), the accession you asked for, the format the server returned, the SHA-256 checksum of the bytes that landed on disk, the size, and the timestamp.

Two practical uses for this. First, if a colleague hands you a FASTA and you want to know where it came from, the sidecar answers that question. Second, if a project is rebuilt later and the upstream record at NCBI has changed (versions go from `.3` to `.4`, for example), the checksum mismatch flags the change before it propagates into your variant calls.

## Pathoplexus and SRA: when not to use this dialog

Two adjacent workflows live in different places and are worth flagging so you do not get lost.

The same dialog has a `Pathoplexus` tab for pathogen-genomics submissions that are mirrored at Pathoplexus rather than NCBI. The mechanics are the same (accession, format, save location), but the underlying source is different. Use Pathoplexus when an outbreak record is hosted there but not yet on NCBI.

For raw sequencing reads (FASTQs from the SRA), use the SRA chapter ([R02, Importing reads from SRA](../03-reads/02-importing-from-sra.md)) instead. SRA accessions begin with `SRR`, `ERR`, or `DRR` and route through `lungfish fetch sra`, which uses an ENA mirror and falls back to the SRA Toolkit. The NCBI dialog covered in this chapter does not handle them.

## Troubleshooting

A few failure modes account for almost every problem with NCBI fetches.

- **Accession not found.** NCBI returned an empty record for the accession you typed. Double-check the version suffix (the `.3` in `MN908947.3`) and confirm the record exists by pasting the accession into a browser at `https://www.ncbi.nlm.nih.gov/nuccore/`. If the record is an assembly accession (starts with `GCF_` or `GCA_`), use `lungfish fetch genome` instead.
- **Rate limit (HTTP 429).** NCBI's eutils endpoint throttles unauthenticated traffic to roughly three requests per second. If you scripted a batch of fetches and several rows in the Operations Panel turn yellow with a 429, wait a minute and re-run; Lungfish does not currently auto-retry rate-limited fetches.
- **Network failure.** A red row with a connection-reset or DNS error usually means a transient outage. Retry the same fetch; if the second attempt also fails, check whether your machine can reach `https://eutils.ncbi.nlm.nih.gov/` at all before assuming a Lungfish bug.
- **Wrong format returned.** If you asked for GFF3 and got an XML error document, the upstream record probably does not have annotations in GFF3 form. Fall back to GenBank, which is annotated for almost every record but cannot be auto-attached to a bundle.

If a fetch leaves a partial file behind after a crash or cancel, the provenance sidecar will be missing or marked incomplete; delete both files and re-run the fetch rather than trying to repair in place.

## Next

Continue to [MSAs and Trees](04-msa-and-trees.md) for multiple-sequence-alignment workflows, or jump to [Reads (FASTQ)](../03-reads/) to start working with sequencing data against the reference you just downloaded.

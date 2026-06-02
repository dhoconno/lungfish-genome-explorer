---
title: Importing Existing VCFs
chapter_id: 05-variants/06-importing-existing-vcfs
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/02-reading-the-variant-browser]
estimated_reading_min: 5
task: Import a VCF produced by an external pipeline and view it in Lungfish.
tags: [variants, vcf, import, viewport]
tools: []
entry_points:
  - "File > Import Center > Variants"
  - "Drag-drop a VCF into the sidebar"
  - "CLI: lungfish import vcf"
shots: []
planned_shots:
  - id: import-center-variants
    caption: "The Variants tab of the Import Center, with a chosen VCF and the inferred reference bundle shown."
  - id: imported-vcf-track-sidebar
    caption: "The sidebar after a successful VCF import, with the new variant track nested under its matched reference bundle."
illustrations: []
glossary_refs: [VCF, reference-bundle, tabix, alias-map]
features_refs: [import.vcf]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Many users come to Lungfish with a VCF produced somewhere else: a published study's supplementary file, a clinical sequencing report, the output of `nf-core/viralrecon`, or GATK on a bacterial isolate. Lungfish accepts these files through three doors, but the doors do different amounts of work. The Import Center under the File menu is the guided path, and it is the one that matches the VCF to a reference bundle and attaches it as a variant track you read in the browser. Drag-drop onto the sidebar is the fast version of that same guided path. The `lungfish import vcf` CLI command is a lighter scripted path: it validates the header, prints a summary, and copies the file into an output directory; it does not infer a reference or attach a track. Reference matching and attachment are GUI-only, so read this chapter's CLI section with that boundary in mind.

The hard part of import is not parsing the VCF. The hard part is deciding which reference the VCF is keyed against. A VCF identifies its reference only by the names that appear in its `CHROM` column, and those names are not standardised across communities. The same SARS-CoV-2 reference appears in published VCFs as `MN908947.3` (GenBank), `NC_045512.2` (RefSeq), `chrCOV19` (a UCSC convention), and `SARS-CoV-2-WH01` (some clinical pipelines). Lungfish ships an alias map that recognises these as the same sequence and matches the VCF to whatever reference bundle in your project carries that sequence under any of those names.

Compressed and indexed VCFs (`.vcf.gz` paired with a `.tbi` tabix index) are the standard form for anything beyond a few thousand rows, and Lungfish prefers them. A plain `.vcf` works too. When you import a plain `.vcf` through the Import Center, the guided path compresses and indexes it as part of attaching the track.

The practical takeaway: drop your external VCF into the Import Center, confirm that Lungfish picked the right reference bundle, and open the resulting track in the variant browser.

## What you will learn

By the end of this chapter you will be able to import a plain VCF or a bgzipped+tabix-indexed VCF, recognise when reference inference picked the right bundle, force a different bundle if inference was wrong, and read the imported VCF in the variant browser.

## Accepted formats

| Format | File extension | Index | Notes |
|---|---|---|---|
| Plain VCF | `.vcf` | None required | The Import Center bgzips and indexes it while attaching the track. |
| Bgzipped VCF | `.vcf.gz` | `.tbi` recommended | If the index is missing, the Import Center builds one. |
| Bgzipped VCF, indexed | `.vcf.gz` plus `.vcf.gz.tbi` | Tabix index alongside | Preferred form. Imports without modification. |
| BCF | `.bcf` | None required | Accepted by the reader; the CLI also accepts `.bcf`. |

Lungfish reads modern VCF (4.x). Multi-sample VCFs are supported: each sample column becomes a separately filterable set of genotype fields in the variant browser. Very old VCFv3 files predate the modern spec; whether the GUI reader rejects them outright was not confirmed for this chapter, so if you have a v3 file, convert it first with [bcftools convert](https://samtools.github.io/bcftools/bcftools.html#convert) or `vcf-convert` from [vcftools](https://vcftools.github.io/perl_module.html) (see Troubleshooting) rather than relying on a specific rejection message.

## Procedure

This procedure walks the Import Center path. The drag-drop and CLI paths are summarised at the end.

1. Open the Import Center with `File > Import Center`, then click the **Variants** tab.

   <!-- planned: import-center-variants -->

2. Click **Choose File** and select your VCF. If you have a `.vcf.gz` plus a `.tbi` in the same folder, choose the `.vcf.gz`. The Import Center will pick up the index automatically.
3. Read the **Inferred reference** field. Lungfish reads the VCF's `CHROM` column, applies its alias map, and lists the reference bundle in your project that matches. If no bundle matches, the field reads "No matching bundle" and the **Import** button is disabled.
4. If the inferred reference is correct, click **Import**. If it is wrong (for example, two of your bundles share a chromosome name), open the **Reference** dropdown and pick the right one by hand.
5. Wait for the progress bar to finish, then close the Import Center. As it imports, the Import Center copies the VCF into the project, bgzips and indexes it if needed, and writes a provenance entry recording the source path and the matched reference. When it finishes, the new variant track appears in the sidebar, nested under the matched reference bundle.

   <!-- planned: imported-vcf-track-sidebar -->

For the drag-drop path, drag a `.vcf` or `.vcf.gz` from Finder onto the sidebar. Lungfish runs the same inference and import logic as the Import Center. If inference is unambiguous, the import completes silently and the track appears. If inference is ambiguous or fails, the Import Center opens with the file pre-selected.

The CLI path is narrower than the GUI path, and the difference matters. The command is:

```bash
lungfish import vcf calls.vcf.gz --output-dir ./imported
```

Its only arguments are the positional input file and `--output-dir` (short `-o`). It has no `--project` and no `--reference` flag. It reads the VCF header, prints a summary (the format, the variant count, the variant-type breakdown, the sample list, and the contig count), and copies the VCF (and any companion `.tbi` or `.csi`) into the output directory. It does not infer a reference, apply the alias map, build a bundle, bgzip a plain VCF, or attach a track. To match a VCF to a reference bundle and read it in the browser, use the Import Center, not the CLI. To validate a VCF's format on its own first, `lungfish analyze validate <vcf>` is the companion check.

Because the CLI import does not build a bundle variant database, you cannot chain it straight into the bundle-scoped query commands below. `lungfish variants extract-sample` and `lungfish variants query` operate on a bundle that already has a SQLite variant database, which the GUI import creates and the CLI import does not. Import through the GUI first; then, against that bundle, you can extract one sample's calls:

```bash
lungfish variants extract-sample ./Project.lungfish/References/Cohort.lungfishref \
  --sample NA12878 \
  --output NA12878.vcf
```

or export a smart-filtered subset:

```bash
lungfish variants query ./Project.lungfish/References/Cohort.lungfishref \
  --filter "Sample[NA12878].GT=1/1" \
  --output NA12878-hom-alt.vcf
```

The query filter accepts the same per-sample syntax as the browser, including `Sample[NA12878].AF>=0.5`, `Sample[NA12878].DP>=30`, `count(Sample[*].GT=1/1) >= 5`, and `Sample[NA12878].GT != Sample[NA12879].GT`. Both commands write a `.lungfish-provenance.json` sidecar beside the output VCF with the command, options, bundle path, database path, output checksum, exit status, and wall time.

## Worked example

Suppose you are following up on a wastewater study that published a supplementary VCF named `study42_lineage_calls.vcf.gz` along with its tabix index. The VCF was produced by an iVar-based pipeline keyed against the RefSeq SARS-CoV-2 record, so its `CHROM` column reads `NC_045512.2`. Your Lungfish project already contains a reference bundle built from the GenBank record `MN908947.3`, which is the same sequence under a different accession.

Open the Import Center, choose the Variants tab, and select `study42_lineage_calls.vcf.gz`. The **Inferred reference** field reads `MN908947.3 (SARS-CoV-2 reference)`, with a small caption noting that the VCF's `CHROM` value `NC_045512.2` matched through the RefSeq alias. Click **Import**. The progress bar finishes within a second or two for a typical viral VCF. The sidebar now shows a variant track named `study42_lineage_calls` under the SARS-CoV-2 reference bundle.

Click that track. The variant browser opens, showing the genome track at the top and the variants from the published study in the table at the bottom. Sort, filter, and inspect rows the same way you would for a Lungfish-produced track. Cross-reference the published variants against your own samples by opening both tracks at once, or export the table for a side-by-side comparison.

## Interpretation

A successful import puts a new variant track in your sidebar under exactly one reference bundle. If the inferred reference matches what you expected from the publication or pipeline, you can read the imported variants the same way you read your own. If the inferred reference is wrong, the variants will plot at positions that do not correspond to anything biologically meaningful, so always sanity-check the inferred bundle before clicking Import.

A common sanity check is to look at the first few `POS` values in the imported track and compare them against known landmarks. For SARS-CoV-2, variants in the spike gene fall roughly between positions 21,500 and 25,400. If your imported variants cluster around positions that make sense for the organism described in the study, the import worked. If they cluster in nonsense regions, you probably matched the wrong bundle.

## Troubleshooting

**Chromosome name mismatch.** If the Import Center reports "No matching bundle", the VCF's `CHROM` value is not present (under any known alias) in any reference bundle in your project. Two fixes apply. The first is to add the matching reference: import or download the FASTA the VCF was called against and let the alias map find it on a second attempt. The second is to accept that the VCF cannot be displayed without that reference. Lungfish will not silently re-coordinate variants onto a different sequence, because that would corrupt every position.

**Missing index.** A `.vcf.gz` without a `.tbi` is fine. The Import Center builds the index during import. If a `.vcf.gz` carries a `.tbi` that is older than the data file (the index has gone stale), the safe fix is to delete the stale `.tbi` and re-import so a fresh index is built.

**Very old VCFv3 files.** VCFv3 was superseded in 2011. If an import of an ancient file fails to parse, convert it first with [bcftools convert](https://samtools.github.io/bcftools/bcftools.html#convert) or `vcf-convert` from [vcftools](https://vcftools.github.io/perl_module.html), then import the converted VCF 4.x file. Lungfish does not perform this conversion for you, and `lungfish convert` does not handle VCF, so do the conversion in `bcftools` or `vcftools`. Doing it explicitly is the right call anyway, because VCFv3-to-VCFv4 conversion can change how multi-allelic sites are represented, and that is a decision the user should own.

## Next

This is the last chapter in [Variants](.). Continue to [Classification](../06-classification/) for taxonomy workflows, or revisit [Reading the Variant Browser](02-reading-the-variant-browser.md).

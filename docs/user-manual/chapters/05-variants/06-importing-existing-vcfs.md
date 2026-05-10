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

Many users come to Lungfish with a VCF produced somewhere else: a published study's supplementary file, a clinical sequencing report, the output of `nf-core/viralrecon`, or GATK on a bacterial isolate. Lungfish accepts these files through three doors. The Import Center under the File menu is the guided path. Drag-drop onto the sidebar is the fast path. The `lungfish import vcf` CLI command is the scripted path. All three end at the same place: the VCF becomes a variant track on a matched reference bundle, and you read it in the variant browser exactly the way you read tracks Lungfish produced itself (covered in [Reading the Variant Browser](02-reading-the-variant-browser.md)).

The hard part of import is not parsing the VCF. The hard part is deciding which reference the VCF is keyed against. A VCF identifies its reference only by the names that appear in its `CHROM` column, and those names are not standardised across communities. The same SARS-CoV-2 reference appears in published VCFs as `MN908947.3` (GenBank), `NC_045512.2` (RefSeq), `chrCOV19` (a UCSC convention), and `SARS-CoV-2-WH01` (some clinical pipelines). Lungfish ships an alias map that recognises these as the same sequence and matches the VCF to whatever reference bundle in your project carries that sequence under any of those names.

Compressed and indexed VCFs (`.vcf.gz` paired with a `.tbi` tabix index) are the standard form for anything beyond a few thousand rows, and Lungfish prefers them. A plain `.vcf` works, and Lungfish will compress and index it for you on import.

So what should you do with this? Drop your external VCF into the Import Center, confirm that Lungfish picked the right reference bundle, and open the resulting track in the variant browser.

## What you will learn

By the end of this chapter you will be able to import a plain VCF or a bgzipped+tabix-indexed VCF, recognise when reference inference picked the right bundle, force a different bundle if inference was wrong, and read the imported VCF in the variant browser.

## Accepted formats

| Format | File extension | Index | Notes |
|---|---|---|---|
| Plain VCF | `.vcf` | None required | Lungfish bgzips and indexes it on import. |
| Bgzipped VCF | `.vcf.gz` | `.tbi` recommended | If the index is missing, Lungfish builds one. |
| Bgzipped VCF, indexed | `.vcf.gz` plus `.vcf.gz.tbi` | Tabix index alongside | Preferred form. Imports without modification. |

Lungfish reads VCF 4.0, 4.1, 4.2, 4.3, and 4.4. Older VCFv3 files are not accepted directly; convert them first with [bcftools convert](https://samtools.github.io/bcftools/bcftools.html#convert) or `vcf-convert` from [vcftools](https://vcftools.github.io/perl_module.html) (see Troubleshooting). Multi-sample VCFs are supported: each sample column becomes a separately filterable source in the variant browser.

## Procedure

This procedure walks the Import Center path. The drag-drop and CLI paths are summarised at the end.

1. Open the Import Center with `File > Import Center`, then click the **Variants** tab.

   <!-- planned: import-center-variants -->

2. Click **Choose File** and select your VCF. If you have a `.vcf.gz` plus a `.tbi` in the same folder, choose the `.vcf.gz`. The Import Center will pick up the index automatically.
3. Read the **Inferred reference** field. Lungfish reads the VCF's `CHROM` column, applies its alias map, and lists the reference bundle in your project that matches. If no bundle matches, the field reads "No matching bundle" and the **Import** button is disabled.
4. If the inferred reference is correct, click **Import**. If it is wrong (for example, two of your bundles share a chromosome name), open the **Reference** dropdown and pick the right one by hand.
5. Wait for the progress bar to finish. The Import Center copies the VCF into the project, bgzips and indexes it if needed, and writes a provenance entry recording the source path and the matched reference.
6. Close the Import Center. The new variant track appears in the sidebar, nested under the matched reference bundle.

   <!-- planned: imported-vcf-track-sidebar -->

For the drag-drop path, drag a `.vcf` or `.vcf.gz` from Finder onto the sidebar. Lungfish runs the same inference and import logic. If inference is unambiguous, the import completes silently and the track appears. If inference is ambiguous or fails, the Import Center opens with the file pre-selected.

For the CLI path, run `lungfish import vcf <path-to-vcf> --project <path-to-project>`. Pass `--reference <bundle-name>` to skip inference and force a specific bundle.

## Worked example

Suppose you are following up on a wastewater study that published a supplementary VCF named `study42_lineage_calls.vcf.gz` along with its tabix index. The VCF was produced by an iVar-based pipeline keyed against the RefSeq SARS-CoV-2 record, so its `CHROM` column reads `NC_045512.2`. Your Lungfish project already contains a reference bundle built from the GenBank record `MN908947.3`, which is the same sequence under a different accession.

Open the Import Center, choose the Variants tab, and select `study42_lineage_calls.vcf.gz`. The **Inferred reference** field reads `MN908947.3 (SARS-CoV-2 reference)`, with a small caption noting that the VCF's `CHROM` value `NC_045512.2` matched through the RefSeq alias. Click **Import**. The progress bar finishes within a second or two for a typical viral VCF. The sidebar now shows a variant track named `study42_lineage_calls` under the SARS-CoV-2 reference bundle.

Click that track. The variant browser opens, showing the genome track at the top and the variants from the published study in the table at the bottom. Sort, filter, and inspect rows the same way you would for a Lungfish-produced track. Cross-reference the published variants against your own samples by opening both tracks at once, or export the table for a side-by-side comparison.

## Interpretation

A successful import puts a new variant track in your sidebar under exactly one reference bundle. If the inferred reference matches what you expected from the publication or pipeline, you can read the imported variants the same way you read your own. If the inferred reference is wrong, the variants will plot at positions that do not correspond to anything biologically meaningful, so always sanity-check the inferred bundle before clicking Import.

A common sanity check is to look at the first few `POS` values in the imported track and compare them against known landmarks. For SARS-CoV-2, variants in the spike gene fall roughly between positions 21,500 and 25,400. If your imported variants cluster around positions that make sense for the organism described in the study, the import worked. If they cluster in nonsense regions, you probably matched the wrong bundle.

## Troubleshooting

**Chromosome name mismatch.** If the Import Center reports "No matching bundle", the VCF's `CHROM` value is not present (under any known alias) in any reference bundle in your project. Two fixes apply. The first is to add the matching reference: import or download the FASTA the VCF was called against and let the alias map find it on a second attempt. The second is to accept that the VCF cannot be displayed without that reference. Lungfish will not silently re-coordinate variants onto a different sequence, because that would corrupt every position.

**Missing index.** A `.vcf.gz` without a `.tbi` is fine. Lungfish builds the index during import. A `.vcf.gz` with a `.tbi` that is older than the `.vcf.gz` (the index has gone stale) is rejected with a warning. Delete the stale `.tbi` and re-import.

**Very old VCFv3 files.** VCFv3 was superseded in 2011 and is not accepted directly. Convert it first with [bcftools convert](https://samtools.github.io/bcftools/bcftools.html#convert) or `vcf-convert` from [vcftools](https://vcftools.github.io/perl_module.html), then import the converted VCF 4.x file. Lungfish will not perform this conversion automatically because VCFv3-to-VCFv4 conversion can change how multi-allelic sites are represented, and that is a decision the user should make explicitly.

## Next

This is the last chapter in [Variants](.). Continue to [Classification](../06-classification/) for taxonomy workflows, or revisit [Reading the Variant Browser](02-reading-the-variant-browser.md).

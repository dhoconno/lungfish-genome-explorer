# Alignments and Variants

## What it is

Alignment and variant workflows turn reads into mapped evidence and candidate variants. The reference, BAM track, primer scheme, caller, thresholds, and runtime environment all affect the result.

Use dialog help to confirm that each setting matches the assay and sequencing chemistry.

## Procedure

1. Select a reference bundle or alignment result.
2. Choose the mapping, primer-trim, or variant-calling workflow.
3. Select the analysis-ready BAM track or reference input.
4. Confirm primer trimming for iVar only when primers were removed from the exact BAM.
5. Run the workflow and inspect the resulting VCF or variant track.

## Interpretation

Minimum depth and allele-frequency thresholds change which variants appear. Blank fields can mean caller defaults, while explicit fields record user choices.

For ONT callers, the Medaka or Clair3 model should match the basecaller chemistry. A mismatched model may change sensitivity and error profiles.

## Provenance

Alignment and variant outputs must record the command, caller version, reference, BAM track, model, primer scheme, thresholds, inputs, checksums, status, and runtime. Use provenance before comparing calls across tools.

# AI Haplotyping Knowledge Packs

This directory contains bundled prompt knowledge packs for AI-assisted MHC
haplotyping. The JSON keeps human-facing report labels such as `M1A`,
`A008.01`, and `DR01.01`, while giving the prompt richer internal structure for
species, population, assay resolution, marker roles, and analyst guidance.

Version `macaque-mhc-v1.json` is a compact seed pack built from the current
human-maintained MiSeq haplotyping definitions and report conventions. It is
prompt context only; it does not replace `.lungfishmhcref` haplotype definition
sets used by deterministic analysis.

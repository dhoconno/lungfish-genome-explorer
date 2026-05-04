# SARS-CoV-2 MAFFT End-to-End Fixture

This fixture is a small Lungfish project-style artifact used for testing the
MAFFT-backed multiple-sequence alignment workflow.

## Inputs

- `Inputs/sars-cov-2-genomes.fasta`: five SARS-CoV-2 genome records.
- `Inputs/source-metadata.tsv`: source and edit metadata for each record.

The first FASTA record is copied from `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/alignment-tree-viewers/Tests/Fixtures/sarscov2/genome.fasta`:

`>MT192765.1 Severe acute respiratory syndrome coronavirus 2 isolate SARS-CoV-2/human/USA/PC00101P/2020, complete genome`

Records B-E are deterministic synthetic derivatives of that local source
sequence. They exist only to exercise alignment, import, viewer, and
provenance paths; they are not biological observations or lineage labels.

## Generated Outputs

`Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa` is created
by running `lungfish align mafft` against the input FASTA. The native MSA bundle
contains its own `.lungfish-provenance.json` with the MAFFT command, runtime,
input checksums, output checksums, exit status, and wall time.

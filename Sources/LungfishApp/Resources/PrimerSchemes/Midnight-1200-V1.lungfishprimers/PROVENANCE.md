# PROVENANCE - Midnight 1200 bp V1

## Workflow

| Field | Value |
|---|---|
| Tool/workflow | `scripts/build-primer-bundle.swift` |
| Tool version | `1.1.0` |
| Bundle schema version | `1` |
| Bundle content version | `1.0.0` |
| Started | `2026-09-01T22:13:10Z` |
| Completed | `2026-09-01T22:13:11Z` |
| Wall time | `1.092 seconds` |
| Exit status | `0` after validation, NCBI equivalence checks, and file writes completed |
| Runtime | `Version 26.6.2 (Build 25G83)` |
| Conda environment | `(not set)` |
| Container | `(not applicable)` |
| Bundle created timestamp | `2026-09-01T22:13:11Z` |

## Command

```sh
scripts/build-primer-bundle.swift --name Midnight-1200-V1 --display-name 'Midnight 1200 bp V1' --description 'Freed/Silander Midnight 1200 bp amplicon scheme for SARS-CoV-2, designed for Oxford Nanopore rapid-barcoding workflows.' --organism 'Severe acute respiratory syndrome coronavirus 2' --canonical MN908947.3 --equivalent NC_045512.2 --bed scripts/inputs/artic-midnight-1200-V1-primers.bed --source-url https://github.com/nf-core/test-datasets/tree/viralrecon/genome/MN908947.3/primer_schemes/artic/nCoV-2019/V1200 --output Sources/LungfishApp/Resources/PrimerSchemes/Midnight-1200-V1.lungfishprimers
```

## Options

| Option | Resolved value |
|---|---|
| --name | Midnight-1200-V1 |
| --display-name | Midnight 1200 bp V1 |
| --description | Freed/Silander Midnight 1200 bp amplicon scheme for SARS-CoV-2, designed for Oxford Nanopore rapid-barcoding workflows. |
| --organism | Severe acute respiratory syndrome coronavirus 2 |
| --canonical | MN908947.3 |
| --equivalent | NC_045512.2 |
| --bed | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/scripts/inputs/artic-midnight-1200-V1-primers.bed |
| --fasta | (not supplied) |
| --source-url | https://github.com/nf-core/test-datasets/tree/viralrecon/genome/MN908947.3/primer_schemes/artic/nCoV-2019/V1200 |
| --source | built-in |
| --version | 1.0.0 |
| --output | /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/Midnight-1200-V1.lungfishprimers |

## Reference Verification

| Accession | Role | Sequence SHA-256 |
|---|---|---|
| MN908947.3 | canonical | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |
| NC_045512.2 | equivalent | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |

## Computed Counts

| Field | Value |
|---|---|
| Primers | `58` |
| Amplicons | `29` |

## Inputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Source BED | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/scripts/inputs/artic-midnight-1200-V1-primers.bed` | 2579 | `f46125b0ca73f7ef4269c29c74246da5fde45753ade905928ec7427688e6b20a` |

## Outputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Bundle directory | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/Midnight-1200-V1.lungfishprimers` | 0 | `(directory)` |
| Manifest | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/Midnight-1200-V1.lungfishprimers/manifest.json` | 736 | `e0d44aae5dd9e5dc118b37549bf6fa9f7104f46564ea1f115bd6daa6855fe1a3` |
| Bundled BED | `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/viral-recon-primer-schemes-fed991/Sources/LungfishApp/Resources/PrimerSchemes/Midnight-1200-V1.lungfishprimers/primers.bed` | 2579 | `f46125b0ca73f7ef4269c29c74246da5fde45753ade905928ec7427688e6b20a` |

## Stderr

Successful runs write NCBI fetch progress and reference SHA-256 lines to stderr.
No warning or error stderr was emitted for this completed bundle.
## Source and license

Retrieved from the nf-core/viralrecon test-datasets primer scheme collection (https://github.com/nf-core/test-datasets/tree/viralrecon), the copy the pipeline itself resolves. Licensed MIT by nf-core. Retrieval date: 2026-09-01.

Primer coordinates anchored to a public reference are not independently copyrightable. Verify against the upstream scheme before clinical or production use.

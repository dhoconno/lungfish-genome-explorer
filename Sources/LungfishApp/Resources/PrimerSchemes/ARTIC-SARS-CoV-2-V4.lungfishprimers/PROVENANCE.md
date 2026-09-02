# PROVENANCE - ARTIC SARS-CoV-2 V4

## Workflow

| Field | Value |
|---|---|
| Tool/workflow | `scripts/build-primer-bundle.swift` |
| Tool version | `1.1.0` |
| Bundle schema version | `1` |
| Bundle content version | `1.0.0` |
| Started | `2026-09-01T22:12:55Z` |
| Completed | `2026-09-01T22:12:56Z` |
| Wall time | `0.811 seconds` |
| Exit status | `0` after validation, NCBI equivalence checks, and file writes completed |
| Runtime | `Version 26.6.2 (Build 25G83)` |
| Conda environment | `(not set)` |
| Container | `(not applicable)` |
| Bundle created timestamp | `2026-09-01T22:12:56Z` |

## Command

```sh
scripts/build-primer-bundle.swift --name ARTIC-SARS-CoV-2-V4 --display-name 'ARTIC SARS-CoV-2 V4' --description 'ARTIC Network SARS-CoV-2 400 bp amplicon scheme, version 4. Redesigned for improved coverage of Delta-era lineages.' --organism 'Severe acute respiratory syndrome coronavirus 2' --canonical MN908947.3 --equivalent NC_045512.2 --bed scripts/inputs/artic-ncov2019-V4-primers.bed --source-url https://github.com/artic-network/artic-ncov2019/tree/master/primer_schemes/nCoV-2019/V4 --output Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V4.lungfishprimers
```

## Options

| Option | Resolved value |
|---|---|
| --name | ARTIC-SARS-CoV-2-V4 |
| --display-name | ARTIC SARS-CoV-2 V4 |
| --description | ARTIC Network SARS-CoV-2 400 bp amplicon scheme, version 4. Redesigned for improved coverage of Delta-era lineages. |
| --organism | Severe acute respiratory syndrome coronavirus 2 |
| --canonical | MN908947.3 |
| --equivalent | NC_045512.2 |
| --bed | scripts/inputs/artic-ncov2019-V4-primers.bed |
| --fasta | (not supplied) |
| --source-url | https://github.com/artic-network/artic-ncov2019/tree/master/primer_schemes/nCoV-2019/V4 |
| --source | built-in |
| --version | 1.0.0 |
| --output | Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V4.lungfishprimers |

## Reference Verification

| Accession | Role | Sequence SHA-256 |
|---|---|---|
| MN908947.3 | canonical | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |
| NC_045512.2 | equivalent | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |

## Computed Counts

| Field | Value |
|---|---|
| Primers | `198` |
| Amplicons | `99` |

## Inputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Source BED | `scripts/inputs/artic-ncov2019-V4-primers.bed` | 9045 | `0be25749d5c615ad8550f5d748b3a13ab381db30be70511c6e1b526f31bfa00a` |

## Outputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Bundle directory | `Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V4.lungfishprimers` | 0 | `(directory)` |
| Manifest | `Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V4.lungfishprimers/manifest.json` | 712 | `214d5e788e33137582ef9c00afbafbe25580d3299c2a9c5c992fe2d37f425169` |
| Bundled BED | `Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V4.lungfishprimers/primers.bed` | 9045 | `0be25749d5c615ad8550f5d748b3a13ab381db30be70511c6e1b526f31bfa00a` |

## Stderr

Successful runs write NCBI fetch progress and reference SHA-256 lines to stderr.
No warning or error stderr was emitted for this completed bundle.
## Source and license

Retrieved from the ARTIC Network `artic-ncov2019` repository (https://github.com/artic-network/artic-ncov2019), which the nf-core/viralrecon pipeline resolves for its bundled ARTIC primer sets. Licensed CC-BY-4.0 by the ARTIC Network. Retrieval date: 2026-09-01.

Primer coordinates anchored to a public reference are not independently copyrightable. Verify against the upstream scheme before clinical or production use.

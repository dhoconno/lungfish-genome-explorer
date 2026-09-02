# PROVENANCE - ARTIC SARS-CoV-2 V3

## Workflow

| Field | Value |
|---|---|
| Tool/workflow | `scripts/build-primer-bundle.swift` |
| Tool version | `1.1.0` |
| Bundle schema version | `1` |
| Bundle content version | `1.0.0` |
| Started | `2026-09-01T22:12:53Z` |
| Completed | `2026-09-01T22:12:54Z` |
| Wall time | `0.869 seconds` |
| Exit status | `0` after validation, NCBI equivalence checks, and file writes completed |
| Runtime | `Version 26.6.2 (Build 25G83)` |
| Conda environment | `(not set)` |
| Container | `(not applicable)` |
| Bundle created timestamp | `2026-09-01T22:12:54Z` |

## Command

```sh
scripts/build-primer-bundle.swift --name ARTIC-nCoV-2019-V3 --display-name 'ARTIC SARS-CoV-2 V3' --description 'ARTIC Network nCoV-2019 400 bp amplicon scheme, version 3. The most widely used SARS-CoV-2 tiling scheme.' --organism 'Severe acute respiratory syndrome coronavirus 2' --canonical MN908947.3 --equivalent NC_045512.2 --bed scripts/inputs/artic-ncov2019-V3-primers.bed --source-url https://github.com/artic-network/artic-ncov2019/tree/master/primer_schemes/nCoV-2019/V3 --output Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-nCoV-2019-V3.lungfishprimers
```

## Options

| Option | Resolved value |
|---|---|
| --name | ARTIC-nCoV-2019-V3 |
| --display-name | ARTIC SARS-CoV-2 V3 |
| --description | ARTIC Network nCoV-2019 400 bp amplicon scheme, version 3. The most widely used SARS-CoV-2 tiling scheme. |
| --organism | Severe acute respiratory syndrome coronavirus 2 |
| --canonical | MN908947.3 |
| --equivalent | NC_045512.2 |
| --bed | scripts/inputs/artic-ncov2019-V3-primers.bed |
| --fasta | (not supplied) |
| --source-url | https://github.com/artic-network/artic-ncov2019/tree/master/primer_schemes/nCoV-2019/V3 |
| --source | built-in |
| --version | 1.0.0 |
| --output | Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-nCoV-2019-V3.lungfishprimers |

## Reference Verification

| Accession | Role | Sequence SHA-256 |
|---|---|---|
| MN908947.3 | canonical | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |
| NC_045512.2 | equivalent | `7d5621cd3b3e498d0c27fcca9d3d3c5168c7f3d3f9776f3005c7011bd90068ca` |

## Computed Counts

| Field | Value |
|---|---|
| Primers | `218` |
| Amplicons | `98` |

## Inputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Source BED | `scripts/inputs/artic-ncov2019-V3-primers.bed` | 9839 | `6e98d7d5d1c6edac8ef0bac70d698e0828ae42bafe8f3bda0a6257d00ce414b5` |

## Outputs

| Label | Path | Size bytes | SHA-256 |
|---|---|---:|---|
| Bundle directory | `Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-nCoV-2019-V3.lungfishprimers` | 0 | `(directory)` |
| Manifest | `Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-nCoV-2019-V3.lungfishprimers/manifest.json` | 701 | `b23c1aa7a1bb1698c108d4c88b7b9c892e325019a606b2ee23f8e2996867cce7` |
| Bundled BED | `Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-nCoV-2019-V3.lungfishprimers/primers.bed` | 9839 | `6e98d7d5d1c6edac8ef0bac70d698e0828ae42bafe8f3bda0a6257d00ce414b5` |

## Stderr

Successful runs write NCBI fetch progress and reference SHA-256 lines to stderr.
No warning or error stderr was emitted for this completed bundle.
## Source and license

Retrieved from the ARTIC Network `artic-ncov2019` repository (https://github.com/artic-network/artic-ncov2019), which the nf-core/viralrecon pipeline resolves for its bundled ARTIC primer sets. Licensed CC-BY-4.0 by the ARTIC Network. Retrieval date: 2026-09-01.

Primer coordinates anchored to a public reference are not independently copyrightable. Verify against the upstream scheme before clinical or production use.

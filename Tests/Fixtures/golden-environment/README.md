# Golden environment lock

These files pin the managed tools and databases the golden captures in `Tests/Fixtures/golden` run against. `scripts/golden/environment.py provision` builds them at `/Users/Shared/lungfish-golden/storage`, and `docs/contracts/MACHINES.md` says who runs it and when.

## Files

| File | What it pins |
|---|---|
| `lock.json` | The micromamba binary, each environment's manifest pin and explicit file, and each database |
| `<environment>-osx-arm64-explicit.txt` | Every package of one environment, one URL and MD5 per line, in install order. micromamba installs this list as written and resolves nothing. |

## lock.json

| Field | Meaning |
|---|---|
| `micromamba` | The version and SHA-256 of `Sources/LungfishWorkflow/Resources/Tools/micromamba`, the same values as `bootstrap` in the managed-tools manifest |
| `environments[].packageSpec` | The pin from `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. A test fails when the two differ, except for a `testOnly` environment. |
| `environments[].testOnly` | True for an environment that a test needs and the manifest does not pin. Its `packageSpec` lists the specs it was solved from, separated by spaces, and `lock` rewrites it only when it is named. |
| `environments[].explicit`, `sha256`, `packages` | The explicit file, its SHA-256 and its package count |
| `databases[].path` | The folder under `storage/databases`, as the goldens record it |
| `databases[].source.url` | The archive `provision` downloads. An optional `source.sha256` also pins the archive. |
| `databases[].files` | Size and SHA-256 of the files the goldens fingerprint. With `exactFiles` the folder may hold no other file. |
| `databases[].payloadDigest` | Optional, and only the Kraken2 Viral database has one. The payload digest that LGE's installer recorded when it installed the database. `verify` then checks that the registry row holds it, that the row's `canonicalReceiptSHA256` is the SHA-256 of the install receipt `.lungfish-provenance.json`, that the receipt names the digest and the folder, and that the folder's files, without the receipt, add up to it. `provision` never writes it, and rule 5 of `docs/contracts/MACHINES.md` says how LGE installs the database. |
| `databases[].registry` | The rest of the row `provision` writes into `metagenomics-db-registry.json`, which the CLI reads to find the database |

## How the first lock was made

On 2026-10-08 the explicit files were written with `environment.py lock --from-storage` from the `conda-meta` records of the laptop's `~/.lungfish-stable`, the environments the goldens were first captured with. A resolve of the same pins that day gave different dependencies in seven of the eight environments, among them polars 2.0.0 under EsViritu, which stops EsViritu from running. The database files are the fingerprints the goldens recorded on the laptop, and `provision` checks the downloaded archives against them.

## The ivar-oracle environment

`ivar-oracle` is the one environment here that is not a managed tool. It holds the Python that runs `Tests/Fixtures/ivar-converter-parity/ivar_variants_to_vcf.py`, the viralrecon script that `IVarConverterViralReconParityTests` compares the Swift converter against. The test looks for it under the conda root of the managed storage and then under `/Users/Shared/lungfish-golden/storage`, so it runs after `provision` whatever `LUNGFISH_STORAGE_ROOT` says. Without it the test skips with its reason, and under `LUNGFISH_REQUIRE_TOOLS=1` it fails.

Its `packageSpec` lists the specs it was solved from, Python 3.12 with numpy, scipy, pandas and biopython from conda-forge, because the managed-tools manifest has no pin for it. On 2026-10-16 the explicit file was written from a micromamba dry-run solve of those specs. To relock it run `python3 scripts/golden/environment.py lock --solve --env ivar-oracle` and read the diff of its explicit file. A relock of the managed environments leaves it alone.

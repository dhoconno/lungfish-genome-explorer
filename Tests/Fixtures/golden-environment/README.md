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
| `environments[].packageSpec` | The pin from `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. A test fails when the two differ. |
| `environments[].explicit`, `sha256`, `packages` | The explicit file, its SHA-256 and its package count |
| `databases[].path` | The folder under `storage/databases`, as the goldens record it |
| `databases[].source.url` | The archive `provision` downloads. An optional `source.sha256` also pins the archive. |
| `databases[].files` | Size and SHA-256 of the files the goldens fingerprint. With `exactFiles` the folder may hold no other file. |
| `databases[].registry` | The rest of the row `provision` writes into `metagenomics-db-registry.json`, which the CLI reads to find the database |

## How the first lock was made

On 2026-10-08 the explicit files were resolved with `environment.py lock --solve` from the manifest pins of that day. The database files are the fingerprints the goldens recorded on the laptop, and `provision` checks the downloaded archives against them. `environment.py lock --from-storage ~/.lungfish-stable` on the laptop shows whether its installed environments match this lock.

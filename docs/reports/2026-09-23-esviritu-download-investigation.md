# EsViritu Preview download investigation

Investigated 2026-09-23 on macOS 26.6.2 arm64, against checkout `a1f439076`.
The locally installed Preview reports version 2026.9.37, build 4964; the reporters' exact builds are unknown.

## Conclusion

The reported `Prepared database payload is invalid: missing or empty hash.k2d` error is an LGE regression. The hosted EsViritu archive downloads intact, but the shared installer applies Kraken2 validation to it. EsViritu archives do not contain Kraken2's `hash.k2d`.

## Live download and integrity tests

Tested the exact URL configured in `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`:

https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz

- Full curl GET: HTTP 200, 447,285,297 bytes, 329.888 seconds, no redirect.
- Separate macOS Foundation URLSession HEAD: HTTP 200, Content-Length 447,285,297.
- Zenodo API published size: 447,285,297 bytes.
- Published and downloaded MD5 both: `24d85c1ec3cbffff12e921d2f39c91b2`.
- Downloaded SHA-256: `7a4001b0a1baf1933e89c6870ac6ae6d2f04b8e964cf6f076d1f8567a89a2ac5`.
- `gzip -t`, `tar tzf`, and `tar xzf ... -C ...`: all exit 0, empty stderr.

Archive members:

```text
v3.2.4/
v3.2.4/virus_pathogen_database.all_metadata.tsv
v3.2.4/virus_pathogen_database.fna
v3.2.4/virus_pathogen_database.mmi
```

## Reproduction and source trace

The Plugin Manager Download action calls `MetagenomicsDatabaseRegistry.downloadDatabase`, which unconditionally calls `MetagenomicsDatabaseInstaller.prepareInstallation`.

In `MetagenomicsDatabaseInstaller.swift`, line 600 requires `hash.k2d`, `opts.k2d`, `taxo.k2d`, and `database150mers.kmer_distrib` for every archive, without checking `database.tool`. Line 420 also hardcodes the `kraken2` destination directory.

A standalone Swift probe compiled the unchanged current archive file-check loop and its `validateRegularNonempty` method, together with the historical tool-aware validation method from the parent of `50e73dcf4`. Against the same fully extracted archive it printed:

```text
Historical tool-aware validation missing files: []
Current validation: Prepared database payload is invalid: missing or empty hash.k2d
```

This isolates the validation failure using production source; it is not a full GUI installation test or a scientific pipeline execution.

Commit `50e73dcf47e95619fd0105b53633a6198ab9dab1` (2026-08-12), `feat: publish metagenomics databases transactionally`, changed the shared download route to the new installer. Previously it chose a directory using the tool identity and called `missingRequiredFiles(in:tool:)`. The Kraken2-only installer originated in `2d65cda88` earlier that day. The old tool-aware checker remains in the current registry, but initial downloads no longer use it.

## Required repair

Restore tool-aware validation and installation destinations within the transactional installer, preserving checksum verification, rollback, and canonical provenance at durable payload paths. Account for the archive's version subdirectory. Align the destination with EsViritu discovery: `EsVirituDatabaseManager` currently looks under `esviritu/esviritu-viral-db`, whereas the new installer would choose `kraken2/esviritu-viral-v3`.

Add a regression test for an EsViritu-shaped archive through the shared registry/installer path, covering validation, discovery, catalog version, and final-path provenance. Keep Kraken2 validation strict. Retrying this download on an affected build will not correct the format mismatch.

No application source or installed database was changed during this investigation. These tests establish current endpoint health and the cause of this exact error; they do not rule out unrelated intermittent server/network failures.

## Diagnostic artifacts

Temporary artifacts are in `/tmp/lungfish-esviritu-download-check/`: `transfer.txt`, `urlsession-check.txt`, `verification.json` (commands, exit statuses, timings, archive and extracted-file hashes), `verification.log`, `validation-probe.swift`, `build-probe.py`, and `verify-download.py`. The archive and extracted files are also retained there for follow-up testing.

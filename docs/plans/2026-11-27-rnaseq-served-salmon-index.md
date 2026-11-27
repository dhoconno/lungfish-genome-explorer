# Serve the salmon index of each catalog set (plan, 2026-11-27)

## Owner direction

On 2026-11-27 the owner asked whether LGE can stage prebuilt salmon indexes on LabKey, then said: "Then we could serve the indices instead of requiring users to build it." This direction overrides item 5 of `docs/reports/2026-11-26-rnaseq-novice-path/ruling-BIO.md` ("Build the index on the Mac, never download one") for the four sets in `ReferenceSetCatalog`. A set built from other files still builds its index on the Mac.

## Why

- **Smaller Macs can count.** The build is checked against 16.6 GB of memory (`SalmonIndexNeed`), and a count against 6.4 GB (`SalmonQuantNeed`). With a served index, a 16 GB Mac can count the catalog's species. Today Download is off on that Mac.
- **Much faster installs.** galah built the indexes in 18 to 20 minutes of salmon time (human, rhesus, cynomolgus), and each install took 29 to 63 minutes. A served index is one download of about 8 to 10 GB.
- **Allowed.** GENCODE and Ensembl release their files without restriction, and RefSeq is public domain. Salmon's GPL covers its code, not the index files it writes. Other projects already host prebuilt salmon indexes.

## The one rule that makes it safe

A served index is used only when the set built on the Mac has the same id the index was built for, and the Mac's salmon is the same build. Otherwise LGE builds the index as it does today. The set id already hashes the input files and the gffread and derive versions (BIO trap 4). The index key holds the salmon version (`SalmonIndexCache.swift:35`). So a match means the index is the one this Mac would build. That needs builds to give the same bytes, so a rebuild of the rhesus index on galah is compared below.

## Design

1. **Catalog row.** Each `ReferenceSetCatalogEntry` gains an optional `servedIndex`: the URL, byte count and sha256 of one archive, plus the set id, salmon build, k and decoys it was built for. These are copied from the `index-key.json` of the build that made it.
2. **Archive.** One zip per index, holding the key folder's `index/` and `index-key.json` and nothing else. Its `provenance/` and `uses/` name the building Mac's paths, so the cache writes a new record on adopt. The download and checks reuse the demo project route: `DemoProjectArchiveLoading`, a size and sha256 check, then `SafeZipExtractor`, which reads Zip64 for the 4.5 GB `refseq.bin`.
3. **Install order.** `ReferenceSetInstall.install` does preflight, downloads, then the set, as today. Then:
   - If the row has `servedIndex`, the set's id equals its id, and the local salmon build equals its build: download the archive into the cache's `.work` stage, check the archive's sha256, unpack, and check `index-key.json` and `info.json` with `SalmonIndexCache.settled`. Then rename it into place with `RENAME_EXCL`.
   - Otherwise: `SalmonIndexCache.ensure`, as today.

   One new method, `SalmonIndexCache.adopt(archive:expected:)`, is the only new writer. The cache keeps a single owner.
4. **Preflight.** On the served path, check `SalmonQuantNeed` memory (6.4 GB) and the archive's size plus its unpacked size of free disk, not the build's 16.6 GB and 64 GB. The row's words and `memoryRefusal` follow which path the row will take.
5. **Provenance.** The cache writes the index's record on adopt, named "RNA-seq salmon index, served", with the archive's URL and sha256 and this Mac's paths, so a result's record shows the index was downloaded (`docs/contracts/RECORDING-PROVENANCE.md`).
6. **CLI parity.** `rnaseq install-reference` takes the same path, with `--build-index` to force a local build. `rnaseq index` is unchanged.
7. **Making the archives.** A script, `scripts/rnaseq/serve-index.py`, zips a published key folder, prints the row's fields and checks that a second unpack equals the first. It runs on galah only, from the locked environment.

## Tests, each written to fail first

- A row whose set id or salmon build differs builds locally and downloads nothing.
- An archive whose sha256 differs is deleted and named, and nothing is published.
- An archive whose `index-key.json` names another key is refused by `settled`, and nothing is published.
- A matching archive publishes a key folder that `published(_:)` returns, with the adopted step in its provenance.
- On a Mac smaller than 16.6 GB but at least 6.4 GB, a row with a served index has Download on, and one without has it off.
- The replay of `install-reference` events carries the new log line, "Downloading the salmon index".

## Where to host

The owner directed on 2026-11-27: "We already have a public LabKey folder that we use for screencast public sharing. We should use this folder to distribute the databases too."

That is the public area of `docs/development/large-files.md`, `https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/`. Anyone can read it without signing in, and LGE writes to it only through `scripts/lge-files/lge-files.sh`, never with a raw key.

- **Folder.** Each archive goes in `databases/rnaseq-index/<set id>/salmon-2.11.0-k31-genome-decoys/`. Rule 6 applies: a file a row pins is never overwritten or removed while a supported build pins it, and a new salmon or set gets a new folder.
- **Manifest.** A committed `scripts/rnaseq/large-files.tsv` lists the area, remote path, bytes, sha256 and URL of each archive (rule 4).
- **Checks.**
  - The server answers HEAD with 401, so the loader and every check use GET.
  - Before the first upload, a test must show that an anonymous GET of a file over 8 GB streams to the end. Neither `put` nor a download of that size has been tried here.
  - If it fails, split each archive into parts under 4 GB, listed in the row.
- **Owner's yes.** Uploading is publishing, so the first upload of the four archives waits for the owner's yes on the list of files and sizes.

## Determinism check (2026-11-27)

The rhesus index of `macaca_mulatta-Mmul_10-ensembl116-lge-3f0fee25ce9e` was built a second time on galah, with `lungfish-cli rnaseq index` and the same locked salmon 2.11.0 (`salmon-2.11.0-hfc06a8d_0`), from an APFS clone of the set in a fresh storage root (`/Volumes/lge_scratch/lge/rnaseq/lge-installs/novice-path/determinism-root`). It took 1,173 s.

- All nine files of `index/` have the same sha256 as the first build's: `duplicate_clusters.tsv`, `index.ctab`, `index.ectab`, `index.refinfo`, `index.ssi`, `index.ssi.mphf`, `info.json`, `refseq.bin` and `refseq_offsets.json`.
- `index-key.json` is the same, byte for byte.

So a served index equals the one the Mac would build, given the same set id and salmon build, and the rule above holds. The archive still gets its own sha256, because `provenance/` holds times and paths that differ between builds.

## Archives built (2026-11-27)

`scripts/rnaseq/serve-index.py` zipped each index on galah from the storage root `/Volumes/lge_scratch/lge/rnaseq/lge-installs/novice-path/root`, into `/Volumes/lge_scratch/lge/rnaseq/served-index/databases/rnaseq-index/`. Each archive is deflated with a fixed time and mode on every entry, read back entry by entry against the published files' sha256, and checked for local paths. All four were built by `salmon-2.11.0-hfc06a8d_0` at k 31 with genome decoys.

| Set | Archive bytes | Unpacked bytes | Archive sha256 |
|---|---|---|---|
| `homo_sapiens-GRCh38-gencode50-lge-c287524e9a53` | 5,817,381,408 | 10,505,298,684 | `b0d09323c726c37a…` |
| `mus_musculus-GRCm39-gencodem39-lge-398effa30daf` | 4,398,536,780 | 8,694,199,814 | `457e140292832440…` |
| `macaca_mulatta-Mmul_10-ensembl116-lge-3f0fee25ce9e` | 5,275,380,007 | 8,449,585,883 | `c870d7d3338c499a…` |
| `macaca_fascicularis-T2T-MFA8v1.1-refseqrs_2025_03-lge-b514efeeb33d` | 5,875,003,363 | 9,602,008,677 | `e7e702bab69248a4…` |

The full fields of each row are in `served-index/<species>.json` beside the archives. Together they are 21.4 GB.

**End-to-end check (rhesus).** The archive was served from galah over HTTP on 127.0.0.1, and a test build of the CLI pointed the rhesus row at it (the change was not committed). The install ran into a fresh storage root that held only the conda link and the kept genome and GTF downloads:
- `rnaseq install-reference --default rhesus/ensembl-116` built the set, which got the served id, and downloaded and adopted the index.
- It took 472 s with a peak resident set of 0.8 GB, against 2,427 s and 18.9 GB for the local build.
- It removed the archive afterwards.
- The adopted `index/` and `index-key.json` were byte-identical to the local build.
- The record was "RNA-seq salmon index, served", with the URL and sha256, and named no path of the building root.
- Counting the same 1M SRR34827382 pairs against it gave a `genes.counts.tsv` byte-identical to the count against the local index.

The mouse set and index were installed for this step: 3,325 s, exit 0, set `mus_musculus-GRCm39-gencodem39-lge-398effa30daf`.

The largest archive is 5.9 GB, so the open hosting check is now that an anonymous GET of a file of about 6 GB from the public LabKey area streams to the end.

## Uploaded (2026-11-27)

On the owner's "Yes, upload", the four archives went to the public LGE LabKey area with `scripts/lge-files/lge-files.sh put`, taking 78 to 111 s each. Each remote size matched. `scripts/rnaseq/large-files.tsv` lists them.

An anonymous `curl` of each, with no credentials, streamed the whole file to `shasum -a 256`. Every sha256 matched the catalog pin:

| Archive | Time | Rate |
|---|---|---|
| Human | 657 s | 8.9 MB/s |
| Mouse | 554 s | 7.9 MB/s |
| Rhesus | 719 s | 7.3 MB/s |
| Cynomolgus | 814 s | 7.2 MB/s |

So the hosting check is met at 5.9 GB, the largest archive, and no archive needs splitting. `ReferenceSetCatalog.entries` now names each served index.

**Real install from LabKey (mouse).** The committed catalog's CLI ran `rnaseq install-reference --default mouse/gencode-M39` into a fresh storage root, which held only the conda link and the kept genome and GTF downloads.
- It built the set, downloaded the 4.4 GB archive from the public area and adopted it, with no salmon build.
- It took 2,157 s with a peak resident set of 1.3 GB, against 3,325 s and 20.3 GB for the local build.
- The adopted `index/` and `index-key.json` were byte-identical to galah's build.
- The archive was removed afterwards, and only the genome and GTF stayed in the downloads folder.

## Order of work

1. The tests and `SalmonIndexCache.adopt`, `servedIndex`, and the install branch, with no URL in any row. The served path is tested on file URLs. Done 2026-11-27: `SalmonIndexCache+Adopt.swift`, `ReferenceSetCatalogEntry.servedIndex` and `memoryNeedBytes`, the install branch, `--build-index`, the app's per-row memory check and words. The archive holds no `provenance/`, since that names the building Mac's paths. The cache writes the record on adopt.
2. Build the four archives on galah with the script (mouse needs its index built first). Done 2026-11-27, above.
3. Done 2026-11-27, above. Upload to the public LabKey area after the owner's yes on the file list, then put the URLs and pins in the rows, in one commit with a real install on a smaller-memory path (galah with the memory check set to a 16 GB host).
4. Manual: the row's words, and the memory table in `02-counting-bulk-reads.md`.

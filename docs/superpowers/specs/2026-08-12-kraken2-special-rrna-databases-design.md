# Kraken2 SILVA and Greengenes Database Installation

**Date:** 2026-08-12
**Status:** Approved design, pending implementation-plan review

## Objective

Add SILVA and Greengenes to Lungfish's existing Kraken2 database catalog. Users download, remove, and select them exactly like existing Kraken2 databases. Lungfish hides the implementation distinction that these two entries are built with Kraken2's special-database workflow instead of unpacked from a prebuilt archive.

The resulting databases must work with the current Kraken2 classification and Bracken profiling flow, and every installation must carry complete, final-path reproducibility provenance.

## User Experience

- Add ordinary catalog rows named **SILVA** and **Greengenes** to the current database selection interface.
- Use the same Download action, progress presentation, ready/error states, removal behavior, storage location, and classifier picker as every other Kraken2 database.
- Keep progress phase-oriented and generic: Downloading, Preparing, and Verifying. Do not expose archive-versus-build implementation details in the UI.
- Keep the classifier workflow unchanged. Selecting either database continues to run Kraken2 and, for the existing profile goal, Bracken.
- Database descriptions may identify the upstream source and citation/licensing expectations. They do not introduce a separate warning or configuration surface.
- Do not add RDP or any other Kraken2 special database.

## Catalog and Model

`MetagenomicsDatabaseInfo` gains an explicit, Codable installation recipe while preserving compatibility with persisted entries that only contain a download URL:

- `archive(url:)` represents the existing prebuilt-tarball installation path.
- `kraken2Special(type:)` represents either `silva` or `greengenes`.

`DatabaseCollection` remains the AWS/prebuilt collection model and is not overloaded with Kraken2 special-source values. Built-in catalog identity is stable independently of `DatabaseCollection`, so catalog reset, removal, and reconciliation work for SILVA and Greengenes even though they have no AWS collection.

The catalog version describes the recipe until installation. After a successful special build, the installed record uses a reproducible version identity: a parsed upstream release when Kraken2 exposes one reliably, otherwise `built-YYYYMMDD-<digest-prefix>`. The complete deterministic payload digest remains in provenance, so classification records can distinguish exact database builds even when an upstream source is mutable.

Existing decoded database records infer `archive(url:)` from `downloadURL`; no current installation or preference is invalidated.

## Unified Installation Architecture

The public `MetagenomicsDatabaseRegistry.downloadDatabase(name:)` workflow remains the single entry point used by the Plugin Manager and CLI. Internally, it delegates to a recipe-aware installer with injected download, process-running, filesystem, clock, and provenance dependencies so tests never require the network or a multi-gigabyte database build.

Both recipes follow the same transaction:

1. Resolve all options, managed-tool identities, destination paths, and a unique sibling staging directory.
2. Perform the recipe in staging while reporting generic progress.
3. Validate the complete Kraken2 and Bracken payload.
4. Compute deterministic file descriptors and a database-wide digest.
5. Atomically promote staging to the final database directory.
6. Rehydrate and write provenance against final stored paths.
7. Mark the registry entry ready only after provenance succeeds.

If promotion or provenance fails, the installer rolls back the new directory (and restores a prior ready installation during replacement). Cancellation terminates the active process tree, checks cancellation between phases, removes staging, and leaves no ready partial database. A failed-operation receipt with exit status and useful stderr is retained in the registry's installation-history area; no staging path is presented as a scientific output.

Archive recipes continue to download, extract, and validate the existing tarballs through this transaction. This brings the existing database workflow under the same provenance contract rather than creating a provenance exception for older catalog entries.

## SILVA and Greengenes Build Recipe

For either special source, Lungfish resolves the managed Kraken2 and Bracken environments from the existing Metagenomics plugin pack. The pack declares `kraken2-build` and `bracken-build` as required executables in addition to the executables already used for classification.

The installer runs the equivalent of:

```text
kraken2-build --db <staging-database> --special silva
kraken2-build --db <staging-database> --special greengenes
```

Only the command matching the selected catalog entry runs. After Kraken2 succeeds, it builds the Bracken distribution required by the current classifier default:

```text
bracken-build -d <staging-database> -t <resolved-threads> -k 35 -l 150 \
  -x <managed-kraken2-bin-directory> -y kraken2
```

The Bracken process runs in its managed environment while receiving the managed Kraken2 binary directory explicitly. This avoids relying on the user's shell `PATH` or on both tools sharing one conda environment.

The initial scope generates the 150-base distribution because 150 is the classifier's current resolved default. Supporting multiple selectable Bracken read lengths is a separate feature. A missing managed build executable produces an actionable plugin-installation error through the existing database error presentation.

## Validation and Publication

Before publication, every recipe must contain readable, non-empty Kraken2 files:

- `hash.k2d`
- `opts.k2d`
- `taxo.k2d`

SILVA and Greengenes must additionally contain the expected non-empty Bracken 150-base distribution and the taxonomy/library inputs needed to substantiate the build. Validation rejects symlinks or paths that escape the staging root.

The database-wide digest is calculated deterministically from sorted relative paths, file sizes, and SHA-256 checksums. The provenance sidecar and transient files are excluded to avoid self-referential hashing. A ready entry always names the final directory and this exact payload identity.

## Provenance Contract

Every successful archive or special-database installation writes `.lungfish-provenance.json` in the final database directory before the registry reports ready. The record includes:

- Lungfish database-install workflow name and version;
- recipe and source (`archive`, `silva`, or `greengenes`);
- exact executed argv plus a durable replay command with final paths;
- explicit user options, defaults, and resolved defaults, including threads, k-mer length 35, and read length 150 where applicable;
- Lungfish, plugin-pack, conda environment/prefix, Kraken2, Bracken, downloader, extractor, OS, and architecture identities as applicable;
- source URLs or logical upstream source identity;
- archive checksum and size before extraction for prebuilt recipes;
- final input/output paths, file sizes, individual SHA-256 checksums, and deterministic aggregate database digest;
- per-step exit status, wall time, and bounded useful stderr;
- overall exit status and wall time.

The provenance implementation extends or composes the existing `ProvenanceEnvelope` APIs so resolved option sets and runtime identities are serialized rather than hidden in ad hoc metadata. Any record initially produced in staging is rehydrated after promotion so commands and descriptors point to the final stored payload. Provenance failure is a publication failure, not a warning.

Failed and cancelled attempts write a retained failure receipt outside the unpublished staging directory containing the resolved recipe, command, runtime identity, exit/cancellation status, wall time, and useful stderr. They do not claim final scientific outputs.

Classification provenance remains unchanged structurally, but its selected database descriptor now captures the installed version and digest-backed final database identity.

## Error Handling and Lifecycle

- A download/build error uses the existing error state and retry action.
- Retry creates a fresh staging directory; it never reuses an unvalidated partial build.
- Removing SILVA or Greengenes uses the same confirmation and deletion workflow as existing databases.
- Catalog reset restores both special entries as missing without deleting unrelated custom databases.
- Reconciliation marks a database ready only when payload validation and final-path provenance both succeed.
- Replacement preserves the previous ready database until the new payload and provenance commit successfully.

## Test Strategy

Implementation is test-driven and uses fakes for process execution, network transfer, clocks, and large database payloads.

Model and registry tests cover:

- built-in SILVA and Greengenes entries and the absence of RDP;
- backward-compatible decoding of existing archive entries;
- stable built-in identity, reset, removal, and reconciliation for non-AWS entries;
- recipe dispatch while keeping the public download API unchanged;
- generic state/progress transitions for both recipe types.

Installer tests cover:

- exact SILVA and Greengenes `kraken2-build` argv;
- exact Bracken 150-base build argv, resolved defaults, and managed executable paths;
- ordering, validation, deterministic digesting, atomic promotion, replacement rollback, retry, and cancellation;
- missing executables, command failure, malformed/escaping payloads, missing Kraken2 files, and missing Bracken distribution;
- no ready or partial database after any failure boundary;
- success and failure provenance, final-path rehydration, checksums, sizes, runtime identity, stderr, exit status, and wall time;
- provenance failure rolling back publication.

App and CLI tests cover:

- both entries appearing in the existing Databases tab with the same controls as archive entries;
- ready SILVA and Greengenes entries appearing in the unchanged Kraken2 classifier picker;
- classification dispatch using their final database directories;
- CLI list/download behavior reaching the same registry workflow;
- plugin-pack validation requiring both build executables.

Focused tests are added to the existing metagenomics registry, Plugin Manager, classification wizard, plugin-pack, CLI, and provenance suites as appropriate. No test contacts the live Kraken2 endpoints.

## Non-goals

- RDP, GTDB, custom Kraken2 libraries, or arbitrary `--special` values.
- A UI choice between prebuilt and locally built databases.
- User-configurable Kraken2 build parameters.
- Multiple Bracken read-length distributions or a new read-length selector.
- Background database updates or automatic rebuild scheduling.
- Changes to Kraken2 classification thresholds or result presentation.

## Acceptance Criteria

1. SILVA and Greengenes appear as normal downloadable Kraken2 databases everywhere the existing catalog is shown; RDP does not appear.
2. The same registry API installs archive entries and transparently builds special entries in staging.
3. Special installs execute the correct Kraken2 special type and produce the Bracken 150-base distribution required by the current profile workflow.
4. Only fully validated, provenance-complete final directories can become ready; failure and cancellation publish nothing partial and replacement is rollback-safe.
5. Users can select either ready database in the current classifier UI and run the existing Kraken2-plus-Bracken profile workflow without special configuration.
6. Successful provenance contains exact commands, resolved defaults, managed runtime identities, final paths, checksums, sizes, exit status, wall time, and useful stderr. Failure receipts retain equivalent attempted-operation context without claiming outputs.
7. Existing persisted databases and prebuilt archive downloads remain compatible and gain the unified provenance behavior.
8. Focused unit/UI/CLI tests pass with no live network or full database build, followed by the repository's required verification suite.

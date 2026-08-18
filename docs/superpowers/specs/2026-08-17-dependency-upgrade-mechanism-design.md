# Dependency Upgrade Mechanism Design

**Date:** 2026-08-17
**Status:** Approved in discussion (defaults accepted); spec for review
**Scope:** A durable, semiannual mechanism for upgrading every external dependency Lungfish Genome Explorer (LGE) pins (bioconda tools, plugin packs, Nextflow pipelines, reference databases, bootstrap binary, Swift packages), a regression strategy that makes upgrades safe, and the first upgrade sweep (2026.2).

## 1. Goal

LGE pins every external dependency, which is right for reproducibility but has produced five unrelated pinning systems, no on-disk record of what was installed, no upgrade path for existing users, and a test suite that goes green when tools are absent. The goal is:

1. One dependency manifest, one dependency-set version, recorded in provenance.
2. One reconciler that brings any machine (fresh or previously installed) to the manifest state, safely and visibly.
3. A maintainer workflow (`scripts/deps/`) that discovers upstream versions, bumps the manifest, and verifies with tiered regression tests that fail rather than skip.
4. A first sweep to the versions current as of 2026-08-17.

Users do not need to run new analyses with superseded tool versions. Superseded environments and databases are removed after successful replacement. Existing project bundles keep their recorded provenance and remain readable.

## 2. Non-goals

- Upgrading `apple/containerization` (0.24.5 to 0.33.x). Its `Package.swift` comment says it needs a deliberate runtime migration; that is a separate task.
- Side-by-side installation of multiple tool versions.
- Runtime download of plugin packs from GitHub (packs remain compiled into the app; only their pins move into the manifest).
- Reworking the Sparkle app-update path.
- Reviving `containers/Dockerfile.*` (vestigial; they are marked as such and left out of the runtime path).

## 3. Current state (verified 2026-08-17)

Pin surfaces:

| Surface | Location | Problem |
|---|---|---|
| Managed tools lock (17 tools, full build strings) | `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` | `version` equals app version, so every beta bump rewrites it |
| Optional plugin packs (~23 tools) | `Sources/LungfishWorkflow/Conda/PluginPack.swift:344-900` Swift literals | Mostly no build strings; invisible to scripts; hand-mirrored in ~7 test files |
| Duplicated literals | `FullLengthONTMHCGenotypingRunRequest.swift:20-22`, `SavontClusteringRunRequest.swift:34`, `ONTBarcodeDemuxGenotypingPipeline.swift:5547`, `ONTGenotypingPipeline.swift:617,622`, `EsVirituPipeline.swift:321` | Lockstep edits |
| TaxTriage revision | `TaxTriageConfig.swift:240-253` (commit `8fd1fb5` = v3.3.6) | Compile-time constant |
| nf-core catalog | `NFCoreSupportedWorkflowCatalog.swift:123` (viralrecon 3.0.0) | Compile-time |
| Kraken2 catalog | `MetagenomicsDatabaseInfo.swift:274` `latestBuildDate = "20240904"`; `MetagenomicsModels.swift:162-175` URL prefixes | Shared date; upstream renamed 8/16 GB archives (`_08gb_` to `_08_GB_`); EuPathDB `20240904` URL is a 404 (only `20230407` exists) |
| EsViritu DB v3.2.4 | `EsVirituDatabaseManager.swift:92,101`, `MetagenomicsDatabaseInfo.swift:326-332` | Three sites |
| NCBI taxonomy | `MetagenomicsDatabaseInfo.swift:348-355` | Rolling `taxdump.tar.gz` labelled "2025-03" |
| Bundled DB manifests (deacon-panhuman, deacon-ribokmers, human-scrubber) | `Sources/LungfishWorkflow/Resources/Databases/<id>/manifest.json`, `DatabaseRegistry.swift` | Only human-scrubber checksummed; no staleness detection |
| micromamba 2.0.5-0 | `Resources/Tools/tool-versions.json`, `ToolManifest.swift:333`, `scripts/bundle-native-tools.sh` | No download checksum; `update-tool-versions.sh --check` always says "up to date" |
| Swift packages | `Package.swift` (Sparkle 2.9.1 exact, containerization 0.24.5 exact) | Manual |

Mechanism gaps: no on-disk receipt of what produced `~/.lungfish/conda/envs/*` (envs keyed by name only); the only staleness check (`PluginPackStatusService.swift:955-990`) compares version strings, ignores build strings, is reactive, and never removes retired envs; no first-launch-after-update hook; database update detection exists only for the metagenomics registry (`isUpdateAvailable`, badge in Plugin Manager, `lungfish-cli db info`) and no subsystem prunes old copies.

Test gaps: CI (`.github/workflows/ci.yml`) provisions only brew samtools/htslib/seqkit for a narrow filter; the full suite is dispatch-only and provisions nothing; tool-executing tests `XCTSkip` when tools are absent and `scripts/full-suite-gate.sh` treats skips as passes; `LUNGFISH_LIVE_PIPELINE_TESTS` and `LUNGFISH_VIRALRECON_PARITY` are set nowhere. Zero live coverage for kraken2/bracken (effectively), spades/megahit, minimap2, blast, iqtree, vsearch, deacon, sra-tools, pysam, and every Nextflow pipeline. Fragile parsers: `EsVirituDetectionParser` (`expectedColumnCount = 23`, positional, silently drops rows), samtools flagstat free text, kreport 8-column sniff, SPAdes `NODE_` regex, seqkit stats header-count. Frozen tool outputs in `Tests/Fixtures/analyses/*` and `Tests/Fixtures/*-mini/*` exist and carry provenance, but nothing regenerates and diffs them.

## 4. Design

### 4.1 Dependency manifest (single source of truth)

`third-party-tools-lock.json` grows into the dependency manifest. Path and filename stay the same to avoid churn in `RuntimeResourceLocator`, scripts, and docs; the top-level shape gains sections. `ManagedToolLock` is extended (not replaced) with optional sections so decoding old shapes still works. The JSON below is illustrative; angle-bracket values are filled by `scripts/deps/bump.py`.

```jsonc
{
  "packID": "lungfish-tools",
  "displayName": "Third-Party Tools",
  "version": "0.5.0-beta30",          // app version at time of edit (kept for compatibility, no longer authoritative)
  "dependencySet": "2026.2",          // NEW: semiannual identifier, authoritative
  "dependencySetDate": "2026-08-17",  // NEW
  "tools": [ ...unchanged 17 entries..., each may add "buildString" derived from packageSpec ],
  "packTools": [                       // NEW: pins for optional packs, keyed by pack id
    { "packID": "read-mapping", "id": "minimap2", "environment": "minimap2",
      "packageSpec": "bioconda::minimap2=2.31=h6bd33b9_0", "executables": ["minimap2"], "version": "2.31",
      "license": "MIT", "sourceUrl": "https://github.com/lh3/minimap2" },
    ...
  ],
  "pipelines": [                       // NEW
    { "id": "taxtriage", "repository": "jhuapl-bio/taxtriage",
      "revision": "e10bfebda32a62711f38a4e23ab03b61725a9675", "releaseVersion": "v3.3.8" },
    { "id": "nf-core-viralrecon", "repository": "nf-core/viralrecon", "revision": "3.0.0", "releaseVersion": "3.0.0" }
  ],
  "databases": [                       // NEW: catalog versions + URLs + checksums where published
    { "id": "kraken2-standard-16", "tool": "kraken2", "version": "20260626",
      "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_16_GB_20260626.tar.gz", "sha256": null },
    { "id": "esviritu-viral-v3", "tool": "esviritu", "version": "v3.2.4",
      "url": "https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz", "md5": "<from zenodo>" },
    { "id": "ncbi-taxonomy", "tool": "taxonomy", "version": "2026-08-01",
      "url": "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump_archive/taxdmp_2026-08-01.zip", "md5": "<published>" },
    { "id": "human-scrubber", "version": "20260706v2", "filename": "human_filter.db.20260706v2", "md5Sidecar": true },
    { "id": "deacon-panhuman", "version": "panhuman-1", "filename": "panhuman-1.k31w15.idx", "indexFormat": 3 },
    { "id": "deacon-ribokmers", "version": "bbmap-ribokmers-k31w15", "filename": "ribokmers.k31w15.idx", "indexFormat": 3 }
  ],
  "bootstrap": { "micromamba": { "version": "2.9.0-0", "sha256": { "osx-arm64": "<hash>" } } },
  "managedData": [ ...unchanged... ]
}
```

Rules:

- Every conda spec carries a full build string. The manifest is the only place a spec is written. `PluginPack.builtIn` requirements resolve their `installPackages`/`version` from `packTools` by `(packID, id)`; the Swift literal keeps only display metadata, executables, smoke tests, and hooks. A pack tool with no manifest entry is a build-time test failure.
- Duplicated literals (savont, minimap2 provenance strings, EsViritu release tag, TaxTriage revision, Kraken2 date, EsViritu DB URL, taxonomy URL, bundled DB manifests, micromamba version) become lookups. The bundled `Resources/Databases/<id>/manifest.json` files are folded into `databases` and deleted; `DatabaseRegistry` reads the manifest.
- Kraken2 catalog entries carry explicit URLs per collection (no shared date), because upstream naming is not uniform across dates.
- Test files that mirror pins are deleted or rewritten to read the manifest and assert invariants (build string present, spec parses, executables non-empty), never literal versions. The one exception is `AppVersionTests`, which continues to assert the app version.
- The `dependencySet` value is `YYYY.N` (N = 1 or 2). It changes only when a dependency changes. `version` continues to be rewritten by the release script for compatibility but nothing reads it for decisions; a follow-up may drop it.

### 4.2 Provenance

`ProvenanceRuntimeIdentity` (`Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift:598`) gains an optional `dependencySet: String?`. `ProvenanceRunBuilder` populates it from the loaded manifest. Existing envelopes decode with `nil`. Fixture-provenance tooling (`scripts/testing/fixture_provenance.py`) records `dependencySet` for regenerated fixtures.

### 4.3 Install receipt

At the storage root (`ManagedStorageLocation`, default `~/.lungfish/`), the reconciler maintains `~/.lungfish/dependency-receipt.json`:

```jsonc
{
  "schemaVersion": 1,
  "dependencySet": "2026.2",
  "appVersion": "0.5.0-beta30",
  "updatedAt": "2026-08-20T14:00:00Z",
  "environments": {
    "samtools": { "packageSpec": "bioconda::samtools=1.24=h36b3a25_1", "packID": "lungfish-tools", "installedAt": "...", "specHash": "sha256:..." },
    "minimap2": { "packageSpec": "bioconda::minimap2=2.31=h6bd33b9_0", "packID": "read-mapping", ... }
  },
  "databases": {
    "human-scrubber": { "version": "20260706v2", "path": "...", "installedAt": "..." },
    "deacon-panhuman": { "version": "panhuman-1", ... }
  },
  "pipelines": { "taxtriage": { "revision": "e10bfeb...", "prefetchedAt": "..." } },
  "bootstrap": { "micromamba": "2.9.0-0" }
}
```

- Written atomically (temp file + rename) after each successful env install, DB install, or removal. `CondaRootMutationLock` guards it like other conda-root mutations.
- Metagenomics databases keep their own registry (`metagenomics-db-registry.json`); the receipt does not duplicate them. The reconciler reads the registry for that class.
- Bootstrapping an existing machine with no receipt: the reconciler synthesizes one from `conda-meta/*.json` (name, version, build) for every env in `envs/`, then diffs. That covers every current user (beta29 and earlier) with no manual step.

### 4.4 Reconciler

New actor `DependencyReconciler` in `Sources/LungfishWorkflow/Dependencies/`. Inputs: manifest, receipt (or synthesized receipt), metagenomics registry, `PluginPack.builtIn` (which packs are installed = which have envs present). Output: a `ReconciliationPlan`, pure data, testable without conda:

```swift
struct ReconciliationPlan: Sendable, Codable {
    var reinstallEnvironments: [EnvironmentChange]   // spec differs (any difference incl. build string), or conda-meta missing/mismatched
    var removeEnvironments: [String]                 // env present, tool no longer in manifest for any pack (named envs only; hex Nextflow caches are handled by existing orphan logic)
    var installEnvironments: [EnvironmentChange]     // required pack tool missing entirely
    var databaseUpdates: [DatabaseChange]            // installed version != manifest version; each flagged advisory | required
    var pipelinePrefetch: [PipelineChange]           // revision differs from receipt
    var bootstrapUpdate: BootstrapChange?            // micromamba version differs
    var estimatedDownloadBytes: Int64
    var isEmpty: Bool
}
```

Policy:

- **Required pack** (`lungfish-tools`): any change is applied before new analyses can start (Welcome window gate, same as today's required setup). Reinstall = remove env dir, create from manifest spec, run smoke test, update receipt. Failure leaves the receipt entry absent so the next launch retries; the old env is not restored (old-version analyses are not required).
- **Optional packs**: only packs that are currently installed (env present) are planned. Their reinstalls run in the same operation after the required pack.
- **Removals**: envs whose name matches no manifest tool in any pack. Removed after reinstalls succeed.
- **Databases**: `advisory` by default (badge + one-click update; large downloads are the user's call). `required` when the manifest marks a database as incompatible with the new tool (field `minimumToolVersion` / `indexFormat` on the entry; e.g. a future deacon index-format bump). Required database updates block the tool that needs them, not the whole app. Update = download to `<id>.staging-<version>`, verify checksum where published, atomic swap, remove old, update registry/receipt. Existing `isUpdateAvailable` logic in `MetagenomicsDatabaseInfo` becomes a view over the manifest instead of `builtInCatalog` literals.
- **Pipelines**: TaxTriage revision change is not an on-disk change; the plan records it and pre-fetches the repository snapshot when network is available (best effort, non-blocking) so the first run does not stall.
- **Bootstrap**: micromamba binary comes from the app bundle; the reconciler copies the bundled binary over `conda/bin/micromamba` when the version differs (checksum-verified against the manifest).
- Every step is an `OperationCenter` operation with `.update()` and `.log()` calls and a provenance envelope of `workflowKind: .metadataOnly` written under the storage root's `provenance/dependencies/`.

Trigger points:

1. **Launch**: `AppDelegate.applicationDidFinishLaunching` reads `UserDefaults` `com.lungfish.lastLaunchedDependencySet` and `com.lungfish.lastLaunchedAppVersion`. If either differs from the running values, or the receipt is missing, or the manifest hash differs from the receipt's recorded manifest hash, it runs the reconciler and, if the plan is non-empty, presents the Update Tools sheet. If the plan is empty, it silently stamps the defaults. Cost when nothing changed: read two JSON files.
2. **Plugin Manager**: "Check for tool updates" button runs the same reconciler and opens the same sheet.
3. **CLI**: `lungfish-cli tools update --plan` prints the plan (JSON with `--json`); `--apply` executes it non-interactively; `--required-only`, `--include-databases`, `--yes`. `lungfish-cli db update <id|--all>` applies database updates. Both share the reconciler; the GUI sheet is a view over the same plan.

### 4.5 Update Tools sheet (GUI)

One SwiftUI sheet, 480 to 520 px wide, following the wizard-sheet conventions. Sections: Required tools (count, size, always checked, cannot uncheck), Optional tools (checked by default), Databases (unchecked unless required; each row shows installed vs available version and download size), Removals (informational). Buttons: "Update" (primary, Lungfish Orange), "Later" (allowed only when nothing required is pending; otherwise "Quit"). Progress goes to OperationCenter and the sheet shows a compact per-item status list. On completion the Welcome window's required-setup gate re-evaluates.

### 4.6 Maintainer sweep tooling (`scripts/deps/`)

- `check-upstream.py`: reads the manifest, queries bioconda/conda-forge repodata for `osx-arm64` and `noarch` via the local micromamba (`micromamba search --json`), GitHub releases/tags for TaxTriage, EsViritu, deacon, micromamba, Sparkle; HEAD-probes Kraken2 archive URLs on the S3 mirror using both naming forms and reads the aws-indexes page for the newest date; lists NCBI `human_filter` and `taxdump_archive` directories; reports a candidate table (current, latest, build string, published date, release-notes URL) as Markdown and JSON. Read-only; no writes to the manifest.
- `bump.py --set 2026.2 --from candidates.json [--only id,...] [--hold id,...]`: rewrites the manifest with new specs (full build strings resolved from repodata), sets `dependencySet`/`dependencySetDate`, records checksums it can fetch (Zenodo/NCBI md5 files, GitHub release assets, micromamba release sha256), and regenerates derived files (`Resources/Tools/tool-versions.json`, `VERSIONS.txt`, `THIRD-PARTY-NOTICES` tool table, `docs/user-manual` tool table if present). Idempotent.
- `verify.sh --tier 1|2|3 [--require-tools]`: provisions envs from the manifest into an isolated storage root, then runs the regression tiers below and prints a pass/fail summary. Refuses to run tier 1 with skips. Isolation uses a new `LUNGFISH_STORAGE_ROOT` environment override honored by `ManagedStorageConfigStore.currentLocation()` (today only `LUNGFISH_CONDA_ROOT` exists, covering the conda root but not `databases/` or the receipt); the existing `~/.config/lungfish/storage-location.json` remains the persistent user setting.
- `scripts/update-tool-versions.sh` is retired (its `--rebuild` micromamba path moves into `bump.py`; `bundle-native-tools.sh` gains sha256 verification from the manifest).
- `docs/release/dependency-sweep.md` documents the semiannual checklist: run `check-upstream`, decide bumps/holds, `bump`, `verify --tier 1,2,3`, GUI walkthroughs, release notes section "Updated tools and databases", bump app version, release. The releasing skill (`docs/superpowers/specs/2026-08-05-reproducible-lungfish-release-skill-design.md`) gets a pointer so release preparation checks that `dependencySet` in the manifest matches the receipt produced by `verify`.

### 4.7 Regression tiers

**Tier 0 (existing, unchanged):** unit tests with fixture strings for every parser.

**Tier 1, toolset conformance (new mode for existing tests + new tests):**

- Environment variable `LUNGFISH_REQUIRE_TOOLS=1` turns every tool-availability `XCTSkip` into `XCTFail`. Implemented once in a shared helper (`Tests/Support/LungfishTestSupport/ToolAvailability.swift`) that all tool-executing tests call instead of ad hoc skips. `full-suite-gate.sh --require-tools` sets it and treats skips in the conformance allowlist as failures.
- Existing live tests keep their fixtures; assertions are tightened where they are only "exit 0" (e.g. `seqkit stats` parsed as TSV by header name, fastp read counts asserted from the output FASTQ).
- New live tests, all on `Tests/Fixtures/sarscov2/` unless noted, all under `Tests/LungfishWorkflowTests/Conformance/`: `--version`/smoke output for every manifest tool equals the manifest version; kraken2 + bracken classify against the 0.5 GB viral DB (downloaded once into the isolated root; kreport parsed with the real parser and asserted structurally: root/unclassified lines, rank letters, at least one SARS-CoV-2 hit); minimap2 map reads and samtools flagstat/idxstats parse; spades and megahit assemble the paired reads and produce contigs whose headers match the parsers; iqtree on `phylogenetics/known-sarcopterygian/alignment.fasta` produces `run.treefile` with the expected leaf set (topology compared to `expected.nwk` with tolerance for branch lengths); blastn outfmt 6 with the 14 declared fields against the reference; vsearch dereplicate/cluster on reads and parse the `--uc`-free outputs actually used; deacon `index build` on the reference then `filter` depletes spiked reads (no 3.3 GB download); bcftools/htslib bgzip+tabix round trip; ivar trim + variants on the fixture BAM (already exists behind `LUNGFISH_LIVE_PIPELINE_TESTS`, now part of tier 1); mafft, savont `--help` contract, sra-tools `fasterq-dump --version`, pysam import.
- Reconciler unit tests without conda: fake storage roots with synthetic `conda-meta` and receipts covering fresh install, same-set no-op, spec change, build-string-only change, retired env, database advisory vs required, missing receipt synthesis, corrupt receipt, storage root relocated.

**Tier 2, golden regeneration diff:**

- `scripts/deps/regenerate-goldens.sh` re-runs the recorded commands (from each fixture's `.lungfish-provenance.json` `reproducibleCommand`) with the candidate toolset into a scratch dir.
- `scripts/deps/diff-goldens.py` compares against `Tests/Fixtures/analyses/*`, `kraken2-mini`, `esviritu-mini`, `taxtriage-mini`, `naomgs`, `nvd`, `ivar-converter*`, `phylogenetics` with per-format rules: exact match on column headers/count and row keys; numeric tolerance (configurable, default 1e-6 relative for coverage/abundance, exact for counts); ignore version strings, dates, paths. Any header change is a hard failure that must be resolved by a parser change plus a deliberate golden update, never by loosening the rule.
- Fixture provenance is updated with the new `dependencySet` when goldens are intentionally regenerated.

**Tier 3, pipeline runs (manual during a sweep):** TaxTriage at the pinned revision on the `taxtriage-mini` inputs (needs network, Apple Containers, Kraken2 DB), EsViritu at the pinned tool + DB on `esviritu-mini`, diffed with the tier 2 tool. Documented in the sweep checklist with expected runtimes; not part of CI.

**Tier 4, GUI walkthroughs (Computer Use, per project rules):** fresh install into an empty storage root; upgrade from a seeded root containing a beta29-shaped `envs/` (real conda-meta from a previous install) and no receipt; upgrade from a root with a receipt one set behind; each verifies the sheet contents, OperationCenter entries, receipt after completion, and that a representative analysis (FASTQ QC, kraken2 viral classification) runs afterwards.

**CI:** a new `toolset-conformance` job in `ci.yml`, `workflow_dispatch` only, on `macos-26`: provisions envs from the manifest with the bundled micromamba into `$HOME/.lungfish` (cache keyed by manifest sha256), downloads the Kraken2 viral DB (cached), and runs `full-suite-gate.sh --require-tools --filter Conformance|Recipe|FASTQToolIntegration|NativeToolRunner|ReadsToVariants|BAMPrimerTrim|MAFFT`. Not on every PR (macOS minute cost); the sweep checklist and the release skill require a green run of this job at the manifest hash being released.

**Parser hardening (part of tier 2 enablement):** `EsVirituDetectionParser` becomes header-driven with required-column validation and a hard error (not silent drop) on missing columns; kreport parser validates column count explicitly instead of the 8-column sniff; samtools flagstat parsing prefers `samtools flagstat -O json` when the installed version supports it (1.24 does), falling back to text; seqkit stats parsed by header name; SPAdes contig header regex validated in tier 1. NAO-MGS's alias-driven parser is the model.

### 4.8 Compatibility and migration

- Old manifest shapes decode: new sections are optional. Old receipts: schema-versioned; unknown versions cause receipt synthesis from disk.
- Users on beta29 or earlier: first launch after the app update reconciles from synthesized receipt; every managed env is reinstalled where the spec changed (build string included), retired envs removed, `dependencySet` stamped. Because bbmap, samtools/bcftools/htslib, nextflow, and others change in the first sweep, essentially the whole required pack reinstalls (~2.7 GB download). The sheet says so before starting.
- Metagenomics registry entries whose `installationRecipe` URL no longer exists (EuPathDB `20240904`) are corrected on load with a logged note; installed copies are untouched.
- Storage relocation (`StorageSettingsTab`) moves the receipt with the root.
- CLI and GUI share the reconciler; the CLI never presents a sheet and requires `--yes` for `--apply`.

### 4.9 Error handling

- Network failure mid-plan: completed items are recorded; the plan is resumable on next launch (receipt records per-item state, not a single flag).
- Checksum mismatch: item fails, staging dir removed, old copy retained (databases) or env absent (tools), surfaced in OperationCenter with a Retry action.
- Manifest unloadable: existing fallback required-setup pack behavior stays; reconciler is skipped and an error operation is logged.
- Insufficient disk: plan estimates bytes; if free space is below estimate plus 10 percent the sheet warns and disables Update until the user frees space or unchecks optional items.
- Concurrent mutation: `CondaRootMutationLock` serializes reconciler runs; a second trigger while one runs attaches to the running operation.

## 5. First sweep: dependency set 2026.2 (as of 2026-08-17)

Bumps:

| Group | Current | Target |
|---|---|---|
| nextflow | 25.10.4 | 26.04.6 |
| snakemake | 9.19.0 | 9.25.1 |
| bbmap (bbtools) | 39.80 | 40.02 |
| fastp | 1.3.2 | 1.3.6 |
| deacon | 0.15.0 | 0.16.0 (index format 3 unchanged) |
| samtools / bcftools / htslib | 1.23.1 | 1.24 (as a trio) |
| vsearch | 2.30.5 | 2.31.0 |
| minimap2 | 2.30 | 2.31 |
| bowtie2 | 2.5.4 | 2.5.5 |
| savont | 0.5.0 | 0.6.3 |
| medaka | 2.1.1 | 2.2.2 |
| clair3 | 2.0.0 | 2.0.2 |
| spades | 4.2.0 | 4.3.0 |
| iqtree | 3.1.1 | 3.1.3 |
| esviritu (tool) | 1.3.1 | 1.3.3 |
| freyja (experimental) | 2.0.0 | 2.0.3 |
| TaxTriage | v3.3.6 `8fd1fb5` | v3.3.8 `e10bfebda32a62711f38a4e23ab03b61725a9675` |
| Kraken2 catalog | 20240904 | 20260626 (per-collection URLs, `_08_GB_`/`_16_GB_` naming; EuPathDB corrected to `20230407`) |
| NCBI taxonomy | rolling, labelled 2025-03 | `taxdmp_2026-08-01.zip` (dated archive) |
| human-scrubber | 20250916v2 | 20260706v2 |
| micromamba | 2.0.5-0 | 2.9.0-0 |
| Sparkle | 2.9.1 | 2.9.6 |
| SwiftPM minor updates | Package.resolved | `swift package update` within existing constraints |

Holds (already current or deliberately deferred): seqkit 2.13.0, cutadapt 5.2 (take the newer build string only), trim-galore 2.3.0, pigz 2.8, sra-tools 3.4.1, ucsc-bedgraphtobigwig 482, pysam 0.24.0 (newer build only), openpyxl 3.1.5, bwa-mem2 2.3, blast 2.16.0, lofreq 2.1.5, ivar 1.4.4, megahit 1.2.9, skesa 2.5.1, flye 2.9.6, hifiasm 0.25.0, mafft 7.526, kraken2 2.17.1, bracken 1.0.0, ribodetector 0.3.3, gatk4/whatshap (experimental packs), viralrecon 3.0.0, EsViritu DB v3.2.4, deacon panhuman-1 and ribokmers, apple/containerization 0.24.5 (deferred), Xcode 26.4.1 in CI.

Sweep-specific risks to verify in tiers 1 to 3: bbmap 40.x behavior in FASTQ ingestion (clumpify/bbduk/bbmerge/repair defaults); savont 0.6.x output contract for full-length MHC genotyping (two literal sites plus pipeline parsing); samtools 1.24 flagstat/idxstats text unchanged (JSON path added); micromamba 2.9 env creation flags and `--platform` handling; TaxTriage v3.3.8 report and `multiqc_confidences.txt` shape; Kraken2 20260626 kreport shape with kraken2 2.17.1; nextflow 26.04 conda/container profile behavior with `NXF_CONDA_CACHEDIR`.

## 6. Execution model

Implementation is overseen by Fable. Fable orchestrates via subagent-driven development, chooses the model per task, reviews every subagent diff and test output, and runs the gate before marking any task complete. Bounded mechanical tasks (moving literals into the manifest, deleting mirror tests, boilerplate conformance tests, docs) may go to Sonnet or Haiku. Design-sensitive tasks (reconciler and plan policy, receipt synthesis, parser hardening, sheet UX, provenance changes, anything that changes scientific outputs or goldens) go to Opus or stay with Fable. Swift builds are serialized (single `.build/.lock`). GUI verification uses Computer Use, not code reading.

## 7. Acceptance criteria

1. One manifest file holds every conda spec (with build strings), pipeline revision, database version/URL/checksum, and the micromamba version; no other file in `Sources/` or `Tests/` contains a literal conda spec or pinned dependency version except `AppVersion.swift`.
2. `dependencySet` appears in the manifest, the receipt, `lungfish-cli version --tools`, the About window tool list, and every new provenance envelope.
3. A fresh storage root and a beta29-shaped storage root both reach the manifest state through the same reconciler, verified by unit tests and by Computer Use walkthroughs.
4. Superseded envs and databases are removed after successful replacement; retired tools do not leak envs.
5. `full-suite-gate.sh --require-tools` fails on any skipped conformance test; the `toolset-conformance` CI job passes at the released manifest hash.
6. Tier 2 diff passes (or goldens are deliberately regenerated with recorded justification) for the 2026.2 set.
7. `scripts/deps/check-upstream.py` reports the same candidates that this spec lists when run against the 2026.1 manifest.
8. Existing project bundles open unchanged; provenance from before 2026.2 decodes with `dependencySet == nil`.
9. Release notes for the release that ships 2026.2 list every bumped tool and database with old and new versions.

## 8. Open items deferred to follow-ups

- Dropping the compatibility `version` field from the manifest once nothing reads it.
- apple/containerization migration.
- Retiring `containers/` and `DefaultContainerImages.swift` entries that no runtime path uses.
- Automatic (unattended) advisory database updates for small databases (taxonomy, human-scrubber) if users ask for it.

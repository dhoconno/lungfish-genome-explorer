# v1.0.4 Managed Third-Party Tools Release Design

Date: 2026-04-16
Status: Approved in conversation, written for implementation planning
Target release: v1.0.4

## Summary

`v1.0.4` will move Lungfish away from shipping most third-party bioinformatics binaries inside the app bundle. Instead, Lungfish will bundle `micromamba` as the bootstrap installer, then install pinned third-party tools and required managed data into `~/.lungfish` on first launch or whenever required dependencies are missing or unhealthy.

The primary user-facing required pack will be renamed from `Lungfish Tools` to `Third-Party Tools` so the UI does not imply Lungfish authored those dependencies. The app should assume internet access on first launch for this release. Offline-first installation is explicitly out of scope.

The release should prioritize graceful behavior on any supported macOS machine with network access, avoid brittle bundled-binary portability problems, eliminate Homebrew-path leakage from bundled tools, reduce app size, and ensure that every user on `v1.0.4` installs the same pinned dependency versions.

## Goals

- Replace near-total bundled third-party bioinformatics tooling with pinned `micromamba`-managed installs.
- Keep `micromamba` bundled as the bootstrap dependency manager.
- Rename the required user-facing pack to `Third-Party Tools`.
- Pin exact dependency versions for the release so every `v1.0.4` user gets the same managed tool versions.
- Move `samtools` into the required managed set and restore miniBAM plus all other `samtools`-dependent app and CLI flows.
- Audit app and CLI paths so they resolve managed tools consistently rather than using bundled paths, PATH lookups, or Homebrew-oriented fallbacks.
- Speed up or at least make explicit the startup and Plugin Manager status-check experience:
  - shared cached status evaluation
  - in-flight refresh deduplication
  - visible loading indicators while checks run
- Remove retired bundled tools from the release bundle and release scripts.
- Produce a notarized `v1.0.4` DMG from a cleaned `main` checkout after old build/release artifacts are removed.

## Non-Goals

- Offline-first installation or offline dependency mirroring.
- Shipping prepacked conda environments on physical media.
- A complete redesign of the plugin/dependency UI beyond what is needed for clarity, responsiveness, and ownership framing.
- A full package-management rewrite that replaces all existing runtime integration abstractions at once.

## User Experience

### First Launch

- The welcome window should remain usable and visually polished, but it must not appear frozen while dependency checks are running.
- While required dependency checks are in progress:
  - show an explicit loading state
  - disable project actions until required checks complete
  - avoid presenting an empty or misleading setup card
- Once checks complete, show the required pack as `Third-Party Tools`.
- Copy should make ownership clear, for example:
  - title: `Third-Party Tools`
  - subtitle: `Needed before you can create or open a project`
  - body: `Lungfish uses several third-party tools and reference files for analysis. Install them once to get started.`

### Plugin Manager

- The Packs tab must also show an explicit loading state while pack statuses are being evaluated.
- Welcome and Plugin Manager should use the same shared cached status source so opening the Plugin Manager immediately after launch does not trigger a second long blocking refresh.

### Setup Details

- Per-tool and per-required-data rows remain available behind details/disclosure UI.
- The surfaced required pack remains single-unit and non-technical by default.
- Per-tool installation and required-data installation should report item-level progress during install or reinstall.

## Dependency Model

### Bundled Bootstrap

- Bundle `micromamba`.
- Treat `micromamba` as the only default bundled third-party executable unless a later audit finds a true exception:
  - the tool is not available through conda for `osx-arm64`
  - the tool is still required in `v1.0.4`
  - the tool has a stable redistributable arm64 binary

### Required User-Facing Pack

- Keep the stable internal pack identifier if helpful for migration safety, but present the required pack to users as `Third-Party Tools`.
- This pack expands internally to pinned managed environments and required managed data.

### Required Managed Tools

The required managed set should include at least:

- `nextflow`
- `snakemake`
- `bbtools` via `bbmap`
- `fastp`
- `deacon`
- `samtools`
- `bcftools`
- `htslib` tools as needed, including `bgzip` and `tabix`
- `seqkit`
- `cutadapt`
- `vsearch`
- `pigz`
- `sra-tools` including `prefetch` and `fasterq-dump`
- `ucsc-bedtobigbed`
- `ucsc-bedgraphtobigwig`

Required managed data should continue to include:

- `deacon-panhuman`

If an audit finds other actively used bundled tools on app or CLI paths, they should move into this managed set when conda provides `osx-arm64` packages.

## Version Pinning

`v1.0.4` must not install floating package names for required tools.

Add a checked-in release-owned lock manifest that records, for each required managed dependency:

- package name
- exact version
- exact build string when practical
- channel
- environment name
- expected executable names
- any fallback executable paths
- smoke-check configuration

The setup installer should install from those pinned specs. Updating the app to a new release may intentionally change the pins, but every user on a given release should resolve the same managed dependency versions.

## Runtime Resolution

### Rule

Any tool that has moved to managed installation must resolve through one shared managed-tool lookup path across both app and CLI code.

### Required Audit Areas

- app runtime tool launch paths
- CLI command tool launch paths
- miniBAM and other `samtools`-dependent views
- markdup flows
- BAM/FASTQ extraction
- import/materialization services
- SRA download flows
- workflow launchers and prerequisite checks
- any helper/locator utilities that still look in:
  - bundled `Resources/Tools`
  - ambient `PATH`
  - `/opt/homebrew`
  - `/usr/local`

### Compatibility Direction

- Replace bundled resolution and PATH fallbacks for migrated tools with shared managed resolution.
- Keep bootstrap-specific logic isolated to `micromamba`.
- Legacy compatibility code should be removed where it would misroute execution away from the pinned managed installs.

## Bundled Tool Audit And Removal

Audit every currently bundled third-party tool under `Sources/LungfishWorkflow/Resources/Tools` and classify it:

- moved to required managed set
- retired entirely
- temporary bundled exception with documented reason

Expected removals from the bundle include most or all of:

- `samtools`
- `bcftools`
- `bgzip`
- `tabix`
- `seqkit`
- `cutadapt`
- `vsearch`
- `pigz`
- `sra-tools`
- UCSC tools

Already-retired or replaced tools should remain absent:

- bundled `bbtools`
- bundled `jre`
- `aligns_to`

## Status Checks And Performance

The existing health-check model uses real tool smoke tests, which is correct semantically but currently feels slow and duplicated.

For `v1.0.4`:

- keep real smoke checks for health semantics
- add shared caching with a short TTL in the status service
- deduplicate in-flight refreshes so multiple screens reuse the same ongoing evaluation
- use explicit loading UI while checks are pending
- prefer lighter smoke probes when they still validate correct launch semantics

Examples:

- use help/version invocations where sufficient
- keep stronger smoke checks where simple launch is not enough, such as BBTools functional invocation

## Testing

### Dependency And Status

- required pack installs pinned versions instead of floating package names
- welcome and Plugin Manager share cached status evaluation
- loading states appear while checks are pending
- repeated opens do not re-trigger redundant long-running checks within the cache window

### Managed Tool Functional Coverage

At minimum, smoke coverage should include:

- `nextflow`
- `snakemake`
- `bbtools`
- `fastp`
- `deacon`
- `samtools`
- `bcftools`
- `seqkit`
- `cutadapt`
- `vsearch`
- `pigz`
- `prefetch`
- `fasterq-dump`
- UCSC conversion tools that remain on active app/CLI paths

### App And CLI Parity

- miniBAM works with managed `samtools`
- markdup and extraction flows work with managed `samtools`
- SRA paths use managed `sra-tools`
- app and CLI both resolve the same managed tools
- no active path still requires a retired bundled binary

### Release

- release smoke tests fail if retired bundled tools reappear
- release smoke tests fail on Homebrew path leakage
- notarized `v1.0.4` DMG succeeds
- release timing is recorded

## Release Execution Order

1. Implement shared cached status checks and loading indicators.
2. Add pinned managed lock manifest and rename the user-facing required pack to `Third-Party Tools`.
3. Move required bundled tools into managed installs, starting with `samtools` and other active-path tools.
4. Audit and redirect all app/CLI call sites to shared managed resolution.
5. Remove retired bundled tools and update release scripts/smoke tests.
6. Clean `build/` and old release artifacts on `main`.
7. Bump version to `1.0.4`.
8. Run the notarized release build from clean `main`.

## Risks

- Some current app or CLI code paths may still have hidden bundled or PATH assumptions.
- Moving many tools in one release increases integration surface area.
- Version pinning requires careful lock-manifest maintenance so installs remain reproducible.
- Some tool-specific smoke checks may still be too slow or too weak and need adjustment during implementation.

## Success Criteria

The work is complete only if:

- `Third-Party Tools` installs from pinned specs
- startup and Packs-tab checks no longer feel frozen
- miniBAM and `samtools`-dependent flows work
- managed-tool resolution is consistent across app and CLI
- near-total de-bundling is in place for tools available via conda on `osx-arm64`
- the release bundle no longer ships retired bundled tools
- old build and release artifacts are cleaned from `main`
- a notarized `v1.0.4` DMG is produced successfully

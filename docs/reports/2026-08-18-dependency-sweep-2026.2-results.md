# Dependency sweep 2026.2 results

Tracks the 2026.1 -> 2026.2 dependency bump (Plan C). This file starts with the
2026.1 baseline (Task C4); later sections will be appended as the bump groups
(C5-C8) and the final gate (C9-C12) complete.

## Baseline (2026.1)

Purpose: prove the verify harness itself (`scripts/deps/verify.sh`, tier 1
conformance gate, tier 2 golden diff) is trustworthy before touching any pin.
Manifest: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`,
dependencySet `2026.1`, dependencySetDate `2026-08-17`,
sha256 `9cc89ad002b92885a702947cded5722d16784ed59331c3eab7028951f93cfc4d`.

### Harness fixes landed first (commit dd53f49b)

A prior agent's C3 work (`scripts/deps/verify.sh`, commit 438f9eef) left three
uncommitted, deliberate edits that this task finished, tested, and committed
as `dd53f49b`:

- `CoreToolLocator.condaRoot(homeDirectory:)`: an explicitly injected
  non-default home now wins over ambient `LUNGFISH_CONDA_ROOT` /
  `LUNGFISH_STORAGE_ROOT` env overrides. Tests that build stub tools under a
  temp home were silently escaping to the real managed tools whenever a
  storage-root override was set process-wide.
- `NativeToolRunnerTests.testCutadaptVersion`: now runs against the real
  managed home and asserts the manifest-pinned version via
  `ConformanceFixtures.textReportsVersion`, replacing a stale `"4."`
  substring check that only passed by falling through to a system cutadapt.
- `scripts/deps/verify.sh`: no longer exports `LUNGFISH_CONDA_ROOT`
  process-wide (that broke tier 1's stub isolation); it is scoped to the
  tier-2 golden-regeneration command only. Added `rewrite_database_registry`
  to repoint the cloned `metagenomics-db-registry.json` `file://` paths at
  the isolated root after seeding, and a post-provisioning
  `tools update --apply --yes` pass to reconcile pack tools (not just
  required-only tools) against the manifest.

Verification before commit:

- `bash -n scripts/deps/verify.sh` - OK.
- `swift test --skip-update --filter 'NativeToolRunnerTests|CondaManagerTests|CoreToolLocator'`
  - 110 XCTest tests, 0 failures, 0 swift-testing tests, ~25.3s.
- `python3 -B -m unittest scripts/tests/test_verify_script.py` - 14 tests, OK,
  0.446s.

### Tier 1: `bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify --seed-from ~/.lungfish`

First run (root pre-seeded from `~/.lungfish`, so cloning was skipped for
`conda` and `databases`; the registry rewrite reported 0 paths repointed
because nothing needed to move) provisioned cleanly ("Nothing to do" on both
`tools update --apply --yes --required-only` and the post-pack-install
`tools update --apply --yes` reconcile pass, confirming the isolated root
already matched the manifest's conda-meta records) and then ran the tier 1
gate. Total wall time: 2:04.83 (provisioning near-instant, gate 76.1s of that).

Result: **GATE FAIL**, not zero skips. Two real, non-harness failures:

1. `ToolVersionConformanceTests.testEveryInstalledPackToolReportsPinnedVersion`
   - `bwa-mem2: expected 2.3 in: 2.2.1`. The manifest pins
     `bioconda::bwa-mem2=2.3=hda5e58c_0`; conda-meta in both the isolated root
     and the source `~/.lungfish` root correctly records this build as
     installed, but the built binary's own `bwa-mem2 version` output reports
     `2.2.1`. This is an upstream/build version-string defect in the bioconda
     `2.3=hda5e58c_0` arm64 build itself, not local drift: a full removal and
     fresh network reinstall of the environment inside the isolated root
     (`lungfish-cli conda remove bwa-mem2 bracken` then
     `tools update --apply --yes`, pulling 314.6 MB fresh from bioconda)
     reproduced the identical `2.2.1` report.
2. `Kraken2BrackenConformanceTests.testClassifyFixtureReadsAgainstViralDB`
   - fails because the installed `bracken=1.0.0=1` package's `bracken`
     executable is a trivial passthrough wrapper
     (`exec "$TOOL_BIN/python" "$TOOL_BIN/est_abundance.py" "$@"`) rather than
     the real bracken CLI that translates `-d/-i/-o/-r/-l/-t` into an
     `est_abundance.py` invocation with a derived `-k KMER_DISTR`. Called with
     the pipeline's actual arguments, `est_abundance.py` errors with `the
     following arguments are required: -k/--kmer_distr` and produces no
     `reads.bracken` output, which `BrackenParser` then reports as a missing
     file. Same fresh-reinstall test confirmed this is reproducible from a
     clean network pull, not local corruption.

Both defects are present identically in the developer's real `~/.lungfish`
root (verified: `~/.lungfish/conda/envs/bwa-mem2/bin/bwa-mem2 version` also
reports `2.2.1`; `~/.lungfish` was never modified by this task) and are the
kind of upstream tool/build defect a dependency sweep is meant to catch and
fix by re-pinning to a working build/version in a later Plan C step, not
something fixable in `verify.sh` or the reconciler: the reconciler correctly
trusts conda-meta bookkeeping (which matches the manifest for both packages)
and has no way to detect that the shipped binary itself is broken.

Second run after the clean reinstall
(`bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify`, no
`--seed-from`, so provisioning was again "Nothing to do" against the
already-current conda-meta) reproduced the exact same two failures. Total
wall time: 2:04.83. Gate: 187 tests, 3 failures (1 unexpected), 80.5s.

No harness fix was made for either failure, per instructions: these are real
product/tool defects unrelated to the verify harness, not something to patch
around.

### Tier 2: `bash scripts/deps/verify.sh --tier 2 --root ~/.lungfish-verify`

Provisioning again "Nothing to do" (isolated root already matches manifest).
Golden regeneration and diff against `Tests/Fixtures/conformance/2026.1`:

| recipe | output | status |
| --- | --- | --- |
| kraken2-mini-SRR35517702 | classification.kreport | same |
| kraken2-mini-SRR35517702 | classification.kraken | same |
| sarscov2-flagstat | flagstat.json | same |
| sarscov2-idxstats | idxstats.tsv | same |
| sarscov2-seqkit-stats | stats.tsv | same |
| sarscov2-fastp | summary.json | same |
| sarscov2-minimap2 | flagstat.json | same |
| sarscov2-spades | contigs-stats.tsv | same |
| sarscov2-megahit | contigs-stats.tsv | same |
| sarscov2-vsearch-derep | count.txt | same |
| sarscov2-deacon | summary.json | same |
| sarscov2-bcftools | calls.vcf | same |
| iqtree-known-sarcopterygian | tree.nwk | same |

**13 same, 0 different, 0 missing.** Total wall time: 42.6s.

Tier 2's golden recipe set does not exercise bracken, so it passed cleanly
despite the tier 1 bracken failure; kraken2's own classification report
(`classification.kreport` / `classification.kraken`, produced before bracken
abundance re-estimation runs) matched exactly.

### Baseline conclusion

- Harness (verify.sh + CoreToolLocator + conformance fixtures): proven
  correct. Unit/script tests green; tier 2 all-same; tier 1 correctly
  surfaces two genuine tool defects with zero false positives or false
  negatives from the harness side.
- Tier 1 is **BLOCKED / FAILING at baseline** for reasons unrelated to this
  sweep's harness work: `bwa-mem2=2.3=hda5e58c_0` misreports its own version
  as `2.2.1`, and `bracken=1.0.0=1` ships a broken CLI wrapper that cannot
  run a classification. Both need to be addressed by re-pinning to a
  different build/version during the 2026.1 -> 2026.2 bump (Plan C, tasks
  C5-C8) rather than by editing the verify harness.
- Tier 2 is **PASS**, 0 differences against the recorded 2026.1 goldens.

## Baseline defects found and fixed

The two tier-1 baseline failures above were investigated and fixed in place.
Neither needed a pin change, so the 2026.1 baseline is now green and the
2026.1 -> 2026.2 bump starts from a clean gate.

### Defect 1 (product, user facing): Bracken abundance estimation was broken on Apple Silicon

The only arm64-installable bioconda build, `bioconda::bracken=1.0.0=1`, ships
no Bracken driver at all. Its package contents under `bin/` are exactly
`est_abundance.py`, `generate_kmer_distribution.py`, and
`count-kmer-abundances.pl`, with no `bracken` entry point.

The `bin/bracken` that ends up in the environment is therefore not upstream's:
Lungfish synthesizes it. `CondaManager.ensureBrackenLauncher`
(`Sources/LungfishWorkflow/Conda/CondaManager.swift`) writes a passthrough
launcher (`exec "$TOOL_BIN/python" "$TOOL_BIN/est_abundance.py" "$@"`) whenever
`bin/bracken` is absent and `est_abundance.py` is present, so that the tool is
invokable under its expected name. That inner script takes a different command
line from the real driver: `-i INPUT -k KMER_DISTR -o OUTPUT [-l LEVEL]
[-t THRESH]`, with no `-d` and no `-r`. Production built the real driver's
`-d <db> ... -r <len>` form, so every abundance run against a synthesized
launcher failed with `est_abundance.py: error: the following arguments are
required: -k/--kmer_distr`. Bracken profiling therefore always degraded on such
an install, and users never got abundance estimates. The launcher is fully
functional once called with the inner CLI.

This matters for how the defect is classified. It is not an upstream packaging
bug awaiting a fixed build, and **no bioconda re-pin can remove it** on arm64:
the package has no driver to ship, so the launcher is required for `bracken` to
be runnable at all. Supporting the inner CLI correctly is a permanent
requirement of the app, not a temporary workaround. A machine that has a real
Bracken driver from some other source keeps using it unchanged, because the
dialect is detected per environment rather than assumed.

Three further problems surfaced while fixing the first:

1. `est_abundance.py` assigns its `u_reads` counter only while parsing an
   unclassified (`U`) report line, then prints it unconditionally in the run
   summary. A Kraken report in which every read classified has no `U` line, so
   the script raises `UnboundLocalError` and exits non-zero, after it has
   already written and closed the complete abundance table. The shared
   SARS-CoV-2 fixture classifies 100 percent against the Viral database and hits
   this on every run.
2. The launcher has no version flag at all, so `bracken -v` prints an argparse
   usage error. The pipeline's generic version detector would have recorded
   digits scraped out of that usage text as the tool version in provenance.
3. `est_abundance.py` accepts only `K,P,C,O,F,G,S` for `-l`. The real driver
   also accepts `D`, and `BrackenDatabaseCapabilities.levelCode` maps domain to
   `D`, so a domain-rank profile would have died at argument parsing. `D` is
   deliberately **not** rewritten to `K`: domain and kingdom are distinct levels
   in both Kraken2 reports and `est_abundance.py`'s own level list, and a single
   report routinely carries both. On the shared SARS-CoV-2 fixture, `D` is
   Viruses (taxid 10239) while `K` is Orthornavirae (taxid 2732396), and running
   the launcher with `-l K` returns Orthornavirae. Substituting one for the
   other would silently profile a different taxon and label it as the rank the
   caller asked for. Domain now degrades through the existing
   `.unsupportedRank` path with a diagnostic that names the accepted codes.

The fix adds `Sources/LungfishWorkflow/Metagenomics/BrackenInvocationForm.swift`,
which isolates four decisions behind a conda-free, unit-testable surface:
detecting the CLI dialect from `bracken --help` usage text, resolving the
`database<N>mers.kmer_distrib` file (exact read length preferred, else the
nearest available N, with a clear error naming the database path when the
directory has none), deciding whether a level code is accepted by that dialect,
and building the argument vector. `ClassificationPipeline` probes the dialect
once per environment and caches it, passes it to both preflight and execution,
keeps the historical argument form unchanged for a real Bracken driver, reads
the version from conda-meta when the launcher cannot self-report, tolerates only
the specific `u_reads` crash signature when the output file exists, and records
both the dialect and the effective argv in the step's resolved options so a
provenance reader can see exactly which form ran. The recorded tool name stays
`bracken` and the step semantics are unchanged.

`MetagenomicsDatabaseInstaller` also drives `bracken-build` for the Kraken2
special recipes, but that path needs no dialect detection: this build ships no
`bracken-build` executable at all, so the installer already fails earlier and
explicitly with `missingManagedTool(bracken-build)` before any argument vector
is constructed. Detection there would have nothing to probe.

### Defect 2 (upstream packaging, test side only): bwa-mem2 self-reports the wrong version

`bioconda::bwa-mem2=2.3=hda5e58c_0` prints `2.2.1` for `bwa-mem2 version`. The
build ships 2.3 binaries and its own conda-meta correctly records 2.3; the
version string baked into the binary is simply stale, and no newer arm64 build
exists. This one is genuinely an upstream packaging defect.

`bracken=1.0.0=1` reaches the same test-side conclusion by a different route,
and is not an upstream defect: as described under Defect 1, the package ships
no driver, so what runs is Lungfish's own synthesized launcher, and
`est_abundance.py` has no version flag to report. In both cases the tool cannot
be trusted to state its own version while conda-meta records it correctly.

`ToolVersionConformanceTests` now carries a narrow, named exception list of
exactly these two tool ids. For them, and only them, the installed version is
asserted against the environment's conda-meta record via `CondaMetaReader`
instead of the self-reported string. The assertion is not weakened: a
conda-meta version that disagrees with the manifest pin still fails, under the
same `LUNGFISH_REQUIRE_TOOLS=1` contract every other tool follows. A guard test
asserts the list stays exactly these two entries and that each is still a
pinned pack tool, so a stale exception cannot silently stop checking a tool
that upstream has since fixed. Both entries are commented with the defect and
the condition for removal.

### Re-run result

`bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify` is now
**GATE PASS**: 189 tests executed, 0 failures, 0 skips.

The filtered suite
(`Kraken2BrackenConformanceTests|ToolVersionConformanceTests|ClassificationPipeline|Metagenomics|BrackenInvocationForm`)
is green in default mode (251 XCTest, 0 failures, plus 44 swift-testing) and
under `LUNGFISH_REQUIRE_TOOLS=1 LUNGFISH_STORAGE_ROOT=$HOME/.lungfish-verify`
(53 XCTest, 0 failures). Tier 2 remains unaffected, since its golden recipe set
does not exercise bracken.

The single default-mode skip is worth spelling out, because the two roots
exercise different code paths and that is the point of the detection. Against
the developer's own `~/.lungfish`, `ToolVersionConformanceTests` reports exactly
one drift entry, `clair3: expected 2.0.0 in: Clair3 v2.0.1`, and nothing about
bracken. That root has a genuine upstream Bracken driver (`bracken.sh`, the
2016-2023 shell driver) which advertises `-d`, so it is classified as the real
CLI, takes the self-reported version path, and never consults conda-meta. The
isolated verify root has no driver and therefore a synthesized launcher, which
is classified as the inner CLI and does consult conda-meta. Both roots pass, by
different routes, which is the behaviour the per-environment probe is meant to
produce. An earlier draft of this section predicted a bracken conda-meta drift
entry in default mode; that prediction was wrong and this paragraph records the
measured result instead.


## Group 1 (task C5)

Applied at commit `b59126ab`, on top of the repaired `bump.py` (`78ad27e8`).
Twenty-two low-risk ids moved and `dependencySet` advanced to 2026.2 dated
2026-08-18.

An earlier attempt at this task was reverted rather than committed, because the
then-current `bump.py` rewrote digests for ids it had not bumped: held
micromamba 2.0.5-0 was paired with 2.9.0-0's sha256, and the held rolling
ncbi-taxonomy entry grew an md5 key. That defect is fixed in `78ad27e8`
(checksum refetch scoped to bumped ids, micromamba addressed by pinned version,
dry runs network-free), and this run re-verified both guards after applying.

### Commands

```
python3 scripts/deps/check-upstream.py --json /tmp/candidates.json --markdown /tmp/candidates.md
python3 scripts/deps/bump.py --set 2026.2 --date 2026-08-18 --from /tmp/candidates.json --only <22 ids>
swift package update Sparkle
bash scripts/check-package-resolved-consistency.sh --repair
swift build
swift test --skip-update --filter 'Dependency|Manifest|PluginPack|CondaManager|TaxTriage|Metagenomics|Provenance|NoLiteral'
bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify
bash scripts/deps/verify.sh --tier 2 --root ~/.lungfish-verify
```

### What moved

Tools: fastp 1.3.2 to 1.3.6, vsearch 2.30.5 to 2.31.0, minimap2 2.30 to 2.31,
bowtie2 2.5.4 to 2.5.5, medaka 2.1.1 to 2.2.2, clair3 2.0.0 to 2.0.2, iqtree
3.1.1 to 3.1.3, esviritu 1.3.1 to 1.3.3, freyja 2.0.0 to 2.0.3, snakemake
9.19.0 to 9.25.2, nextflow 25.10.4 to 26.04.6, deacon 0.15.0 to 0.16.0.
Pipelines: taxtriage v3.3.6 to v3.3.8, revision
`e10bfebda32a62711f38a4e23ab03b61725a9675` recorded as the resolved commit sha
rather than the tag. Databases: the eight Kraken2 catalog entries 20240904 to
20260626, human-scrubber 20250916v2 to 20260706v2. Sparkle 2.9.1 to 2.9.6 as an
exact pin, `Package.resolved` moved that one package and nothing else.

### Held, and why

`ncbi-taxonomy` stays at 2025-03. The dated candidate is
`taxdmp_2026-08-01.zip`, and the archive path handles only gzipped tar in more
than one file: `MetagenomicsDatabaseInstaller.swift:222` runs `/usr/bin/tar xzf`
and reports a tar-specific `toolVersion` plus `argv` into the provenance record,
lines 216 and 274 name the downloaded temp file `...tar.gz` unconditionally, and
`MetagenomicsDatabaseRegistry.swift:1838` holds a second independent
`extractTarball` that also hardcodes `tar xzf`. Adding zip support means two
files, a format-dispatch decision, and a change to what provenance reports as
the extraction tool, which exceeds the one-file bar the ruling set.
`BinaryDownloadProvisioner.swift:98-104` already dispatches `.tar.gz` versus
`.zip` and is the natural model for a dedicated task.

`bracken` and `blast` were skipped by `check-upstream` as `no-arm64-build`,
confirmed in the dry run, so neither can move by accident. EuPathDB reports
`same` at 20230407. micromamba, samtools/bcftools/htslib/spades, bbmap/savont,
and cutadapt/pysam belong to groups 2 through 4.

### Held-pin guards

Re-checked against the written manifest after the run:

- `bootstrap.micromamba` reads version `2.0.5-0` with sha256
  `a8d78f72db1bdcd24e7758551006610a15beb40a34006b3e3e176085a0dbc780`, which is
  the digest that genuinely belongs to 2.0.5-0.
- `ncbi-taxonomy` carries no `md5` key.

No checksum lines were emitted at all, which is correct: none of the 22 bumped
ids has a digest resolver, since the three that do (esviritu-viral-v3,
ncbi-taxonomy, micromamba) are all held.

### Build and unit gate

`swift build` completes. The filtered suite passes: 192 swift-testing tests in
15 suites, 0 failures. No test mirrors needed fixing, as Plan A predicted.

### Tier 1

`verify.sh --tier 1 --root ~/.lungfish-verify`: **GATE PASS**, 189 tests
executed, 0 failures, 0 skips
(`.build/gate-logs/gate-20260818-151654-8403ff22.log`). The reconciler
reinstalled the changed environments (iqtree, bracken, esviritu, medaka, clair3
and the rest) in the isolated root.

### Tier 2

All 13 recipes executed successfully against the newly installed tools. The
comparison against the committed 2026.1 goldens is **12 same, 1 different, 0
missing**.

Goldens have not been regenerated, and `Tests/Fixtures/conformance/2026.2/` does
not exist, so a comparison keyed to set 2026.2 reports all 13 as `missing` by
construction. That is C9's work, not a result. The meaningful comparison is
against 2026.1, reported here.

The single difference, verbatim:

| recipe | output | status | first difference |
| --- | --- | --- | --- |
| sarscov2-deacon | summary.json | different | `$.check_pairs: only in candidate` |

deacon 0.16.0 adds one key to its summary JSON, `"check_pairs": false`. Every
numeric field is bit-for-bit identical to the 0.15.0 golden: `bp_in` 13897,
`bp_out` 307, `bp_removed` 13590, `seqs_in` 100, `seqs_out` 3, `seqs_removed`
97, and both proportions to full precision
(`bp_out_proportion` 0.022091098798301793,
`bp_removed_proportion` 0.9779089012016982). The depletion result is unchanged;
this is an additive schema field sitting at its default. The other twelve
recipes, including the iqtree topology and the bcftools call set, are unchanged.

### Database update path

`tools update --plan` in the isolated root listed exactly one pending item,
`database human-scrubber unknown -> 20260706v2 [advisory]`, and no taxonomy
entry, which is correct given the hold.

`tools update --apply --yes --include-databases` applied it successfully. The
directory afterwards holds only `human_filter.db.20260706v2`; the previous
`20250916v2` file is gone. `tools update --plan` then reports `Nothing to do.`
and exits 0.

`Kraken2BrackenConformanceTests` under `LUNGFISH_REQUIRE_TOOLS=1` and
`LUNGFISH_STORAGE_ROOT=$HOME/.lungfish-verify` passes 2 of 2, still detecting
SARS-CoV-2 with kraken2 2.17.1.

### Defect found: catalog database updates cannot be applied

The Kraken2 viral database update could **not** be exercised, because of a
product defect this task surfaced. It is pre-existing and not caused by the
bump.

`db info Viral` and `db list` both report the update correctly
(`Available update: 20260626` for Viral and Standard-16). But every route to
apply it fails:

```
lungfish-cli conda db update kraken2-viral --yes
  -> Failed 'kraken2-viral': Database 'kraken2-viral' not found in registry
lungfish-cli conda db update Viral --yes
  -> Failed 'Viral': Database 'Viral' not found in registry
lungfish-cli conda db update --all --yes
  -> No databases have an update available.   (exit 0)
```

The cause is that the installed registry rows carry no catalog identity. In
`~/.lungfish-verify/databases/metagenomics-db-registry.json`, the installed
`Viral` and `Standard-16` rows both have `catalogID: null`; only the special
databases (SILVA, written by a different code path) carry one.
`updateDatabase(catalogID:)` selects with
`$0.value.catalogID == catalogID && $0.value.path != nil`
(`MetagenomicsDatabaseRegistry.swift:1088`), which no null row can satisfy, so
the named form throws `databaseNotFound` and the `--all` form resolves an empty
target list.

The `--all` behaviour is the more dangerous of the two: it prints "No databases
have an update available" and exits 0, so a user or a script sees success while
nothing was updated, even though `db list` in the same session advertises the
update.

That the registry knows about this class of row makes the gap clearer. The
freshness matcher at lines 1597-1602 explicitly tolerates the legacy shape
("Old manifests have no catalogID. An exact built-in display name is the ..."),
so the reporting path handles null identity and the update path does not.

Pre-existing, not a bump artifact: the pre-bump backup
`metagenomics-db-registry.pre-special-version-fix-20260815.json` already shows
`Viral` and `Standard-16` with `catalogID: null`.

Consequence for this sweep: the viral index in the verify root remains at
20240904, so the conformance re-run above validates kraken2 2.17.1 against the
old index rather than 20260626. The 20260626 index cannot be exercised until the
lookup is fixed. Suggested fix, for whoever owns it: fall back to matching the
built-in display name when `catalogID` is null, the way the freshness matcher
already does, and backfill `catalogID` on load for rows that resolve to a known
catalog entry.

### Tier 3: BLOCKED

`bash scripts/deps/run-pipelines.sh --which all --out .build/pipelines-2026.2`
ran under a 15 minute bound and failed fast on prerequisites rather than
hanging. Both pipelines are blocked, for two distinct environmental reasons:

- **TaxTriage**: `FAIL TaxTriage: exit 1`. Apple Containers is not installed on
  this machine (`container` is not on PATH), so the script fell back to its
  `docker` profile, and the Docker daemon is not reachable:
  `Cannot connect to the Docker daemon at unix:///Users/dho/.docker/run/docker.sock`.
  The Docker CLI 28.3.2 is present but has no running server.
- **EsViritu**: `FAIL EsViritu: exit 3`,
  `Database directory not found: /Users/dho/.lungfish/databases/esviritu/v3.2.4`.
  Note the path: `run-pipelines.sh` never sets `LUNGFISH_STORAGE_ROOT`, so tier
  3 resolves against the developer's real `~/.lungfish` rather than the isolated
  verify root. Provisioning that database would mean writing to `~/.lungfish`,
  which this sweep must not touch. Teaching the script to honour the verify root
  is a prerequisite for running tier 3 in isolation at all.

The structural diff therefore reports `0 same, 0 different, 4 missing`, with all
four missing on the candidate side because neither pipeline produced output.
Tier 3 is manual and advisory this sweep, so this is recorded as BLOCKED with
specifics rather than treated as a regression. The TaxTriage v3.3.8 report
schema is consequently unverified, and `TaxTriageReportParser` and
`TaxTriageMetricsParser` remain unexercised against the new release.

### Cosmetic note

`human-scrubber` moved to version `20260706v2` but its `releaseDate` field still
reads `2025-09-16`. `bump.py` does not refresh `releaseDate`. This is display
metadata only, with no effect on resolution, download, or verification, and is
left for whoever owns the bump tooling to decide.

## Group 1 follow-up (task C5 fixes)

The four items the group 1 run left open are now closed. Each was recorded above
as a finding rather than a result; this section records what changed and what
the fix was verified against.

### 1. Catalog database updates now apply to rows registered from disk

The defect recorded above under "Defect found" is fixed.
`MetagenomicsDatabaseRegistry.updateDatabase` resolved the installed row by
`catalogID` alone, but rows created by `registerExisting` carry none, which is
what a real user's registry looks like: in this machine's own `~/.lungfish`,
`Viral`, `Standard-16`, `EsViritu Viral DB` and `NCBI Taxonomy` all persist with
`catalogID: null`. Meanwhile `db list` and `db info` advertise updates through
`availableUpdateVersion`, which falls back to a name-and-tool match against the
built-in catalog, so the commands that advertise an update and the command that
applies one disagreed about which rows exist.

Resolution now applies that same two-step match, an identifier may be either a
catalog id or the display name `db list` prints, and a row resolved by name is
stamped with the identity it just proved it has.

`--all` no longer reports success for a run that changed nothing. Two routes led
there and both are closed: selecting no targets while `db list` advertises
updates, and selecting targets that are all then skipped as `updateNotSupported`
(the locally built SILVA and Greengenes databases, which are refreshed by
reinstalling rather than updated in place). Either exits non-zero naming the
databases and the reason; a run that updates at least one database still exits 0.

The regression tests for this are offline. The CLI-level tests seed the locally
built Kraken2 special databases, whose catalog entries carry a `kraken2Special`
recipe and no URL, so target resolution and the exit contract are observable
without any download: an `--all` run over a seeded SILVA row completes in 0.06
seconds and writes nothing. The download and swap path is covered separately in
`DatabaseUpdateFlowTests` against a stub archive installer.

The live update against the isolated verify root:

```
LUNGFISH_STORAGE_ROOT=$HOME/.lungfish-verify \
  .build/debug/lungfish-cli conda db update kraken2-viral --yes

Updating kraken2-viral
[0%] Downloading Viral...
[77%] Extracting...
[88%] Verifying Viral...
[92%] Installing Viral...
[100%] Updated Viral
Database 'kraken2-viral' updated
exit 0
```

`db info Viral` afterwards reports `Current version: 20260626`,
`Available update: none`, installed 2026-08-18T23:24:08Z, 1.17 GB at
`~/.lungfish-verify/databases/kraken2/viral`. The superseded copy is gone: the
parent directory holds only `viral`, with no `.staging-*` or `.old-*` sibling.
The registry row now carries `catalogID: kraken2-viral`, so the next update
resolves it directly rather than by name.

### 2. SARS-CoV-2 species rename in the 20260626 index

Running `Kraken2BrackenConformanceTests` against the newly installed index
failed, and the cause is worth recording because it is a real upstream change
rather than a tooling problem:

```
XCTAssertNotNil failed - Bracken should report an abundance row for SARS-CoV-2
```

Classification itself is perfect. All 100 fixture reads classify, and Kraken2
reports them under a species NCBI has renamed. In the 20260626 index the level-S
row is `Betacoronavirus pandemicum` (taxid 3418604), with
`Severe acute respiratory syndrome coronavirus 2` (taxid 2697049) demoted to the
S1 rank beneath it. Bracken aggregates at level S and therefore emits only the
new name, so the test's substring match on "Severe acute respiratory syndrome"
found nothing.

Both the kreport and the Bracken assertions now match on taxonomy id rather than
display name, against one shared set. Checking the old index turned up a third id
in play: 20240904 rolls the same fixture up to `Severe acute respiratory
syndrome-related coronavirus` (taxid 694009), which the old substring match
covered only by accident. All three ids are accepted.

Verified in both modes:

- default (`~/.lungfish`, 20240904 index): 2 of 2 passed
- `LUNGFISH_REQUIRE_TOOLS=1 LUNGFISH_STORAGE_ROOT=$HOME/.lungfish-verify`
  (20260626 index): 2 of 2 passed

Consumers that key on the SARS-CoV-2 species by name rather than taxid should be
reviewed before this index ships to users. The parsers themselves are unaffected,
since they carry the taxid through.

### 3. verify.sh plan gate no longer trips on advisory updates

The gate read `tools update --plan`'s exit status, which is 10 for any pending
work at all, so the advisory `human-scrubber` update recorded above failed the
exit-65 gate on a root that was otherwise correctly provisioned. The gate now
reads `--plan --json` and judges the contents: pending environment installs,
reinstalls, removals, a bootstrap update, or a database update with policy
`required` still fail; advisory-only is printed and the run continues.

### 4. Tier 3 honours the isolated root

`run-pipelines.sh` never set `LUNGFISH_STORAGE_ROOT`, which is why the EsViritu
failure recorded above named a path under the developer's real `~/.lungfish`. It
now takes `--root` (defaulting to an exported `LUNGFISH_STORAGE_ROOT`), exports
it for both CLI pipelines, derives the conda root the read-fetch and subsample
steps use from the same place, and has a `--dry-run` that prints the resolved
commands and environment. `verify.sh` passes its isolated root through
explicitly. The pipelines themselves were not run here; the two blockers
recorded above (no container runtime, and the EsViritu database absent from the
verify root) are unchanged.

### 5. Database releaseDate now follows a dated version pin

The cosmetic note above is closed. `bump.py` derives `releaseDate` from the new
version whenever the version encodes a date (`YYYYMMDD`, `YYYY-MM-DD`, or either
with a trailing rebuild counter), and reports the move in the change log.
Versions carrying no date, and eight-digit strings that are not real dates, are
left alone. The shipped `human-scrubber` entry is corrected to `2026-07-06`, and
a guard asserts the committed manifest holds no `releaseDate` its own version
contradicts.

### Verification

```
swift build                                                       clean
swift test --filter 'DbCommand|DatabaseUpdateFlowTests|
  MetagenomicsDatabase|Kraken2BrackenConformanceTests'             149 tests, 0 failures
Kraken2BrackenConformanceTests, default mode                       2 of 2 passed
Kraken2BrackenConformanceTests, require + verify root              2 of 2 passed
python3 -B -m unittest discover -s scripts/tests                   393 tests, OK
bash -n scripts/deps/verify.sh scripts/deps/run-pipelines.sh       clean
```

## Group 2 (task C6)

Applied at commit `aaf492fa`. Four medium-risk ids moved: the htslib family
(samtools, bcftools, htslib) from 1.23.1 to 1.24, and SPAdes from 4.2.0 to
4.3.0. `dependencySet` was already 2026.2 dated 2026-08-18 from group 1, so it
did not move again.

### Commands

```
python3 scripts/deps/check-upstream.py --json /tmp/candidates.json
python3 scripts/deps/bump.py --set 2026.2 --date 2026-08-18 --from /tmp/candidates.json \
  --only samtools,bcftools,htslib,assembly/spades --dry-run
python3 scripts/deps/bump.py --set 2026.2 --date 2026-08-18 --from /tmp/candidates.json \
  --only samtools,bcftools,htslib,assembly/spades
swift build
swift test --skip-update --filter 'Dependency|Manifest|PluginPack|CondaManager|BAMImport|
  AlignmentMetadata|VCF|BAMPrimerTrim|MappingViewer|ReadsToVariants|SPAdes|Assembly'
bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify
bash scripts/deps/verify.sh --tier 2 --root ~/.lungfish-verify
python3 scripts/deps/diff_goldens.py --candidate .build/goldens-2026.2 --set 2026.1
```

### What moved

```
samtools        1.23.1 -> 1.24     bioconda::samtools=1.24=h36b3a25_1
bcftools        1.23.1 -> 1.24     bioconda::bcftools=1.24=h6bd33b9_2
htslib          1.23.1 -> 1.24     bioconda::htslib=1.24=hd3c6ec9_0
assembly/spades 4.2.0  -> 4.3.0    bioconda::spades=4.3.0=hd468e49_1
```

A semantic diff of the manifest before and after the write confirms exactly
these four entries changed and nothing else. Every other tool, pack tool,
pipeline, database, and the bootstrap block are byte-identical, and no checksum
lines were emitted, which is correct since none of the four has a digest
resolver. The derived files moved with them: `THIRD-PARTY-NOTICES`,
`third-party-tools-lock.json`, and the timestamp in
`Tools/tool-versions.json` and `VERSIONS.txt`. That last pair is the micromamba
bootstrap manifest, whose only content change is `lastUpdated`, since micromamba
is held for group 4.

### Build and unit gate

`swift build` clean. The filtered suite finished at 1162 XCTest plus 16
swift-testing tests, with one remaining failure, described under live checks
below.

Five test cases failed on the first run. Four were stale mirrors already failing
at HEAD before this bump, verified by stashing the manifest change and
re-running: `PluginPackRegistryTests` still asserted nextflow 25.10.4,
`DatabaseRegistryTests` and `HumanScrubberDatabaseTests` still asserted the
`human_filter.db.20250916v2` filename, release date, and download URLs. All are
group 1 pins that C5 moved without updating the mirrors. They were corrected to
the manifest values. The fifth mirror, bcftools 1.23.1 in
`PluginPackRegistryTests`, belongs to this group and moved to 1.24.

`NoLiteralDependencyPinsTests` also failed at HEAD, flagging
`ClassificationPipeline.swift` and `BrackenInvocationForm.swift`. All three
matches are comment prose documenting the upstream bracken packaging defect
found in C4, not pins an installer can drift away from. The guard now strips
comment lines before matching, which keeps it strict about real code rather than
allowlisting two whole files.

### Tier 1

`verify.sh --tier 1 --root ~/.lungfish-verify`: **GATE PASS**, 189 tests
executed, 0 failures, 0 skips
(`.build/gate-logs/gate-20260818-190528-aaf492fa.log`). Same count as the group
1 baseline. The reconciler reinstalled the four changed environments in the
isolated root, then reported `Nothing to do.` and an empty dependency plan.

### Tier 2

All 13 recipes executed successfully against the newly installed tools. Keyed to
set 2026.2 the comparison reports 13 missing, purely because
`Tests/Fixtures/conformance/2026.2/` does not exist yet; that is C9's work, not
a result. The comparison against the committed 2026.1 goldens is **12 same, 1
different, 0 missing**. Goldens were not regenerated.

The one difference, verbatim:

| recipe | output | status | first difference |
| --- | --- | --- | --- |
| sarscov2-deacon | summary.json | different | `$.check_pairs: only in candidate` |

That is group 1's accepted deacon 0.16.0 additive key, unchanged and unrelated
to this group. **Every output touched by this group is byte-identical to its
2026.1 golden**, which is the strongest form of the expected outcome:

- `sarscov2-flagstat` flagstat.json: same, byte-for-byte.
- `sarscov2-idxstats` idxstats.tsv: same, byte-for-byte.
- `sarscov2-minimap2` flagstat.json: same (samtools reads the mapping output).
- `sarscov2-bcftools` calls.vcf: same. The call set was also diffed with headers
  stripped, to separate a genuine call change from a version banner: 12 variant
  records, identical. `bcftools call` defaults did not change.
- `sarscov2-spades` contigs-stats.tsv: same. 32 contigs, 9030 bp total, N50 307,
  max 707, GC 38.85 percent. No tolerance had to be spent; the 5 percent
  allowance for changed assembly heuristics was not needed, and the `NODE_`
  header regex holds.

Each recipe's `meta.json` records the tool version it actually ran, confirming
the identical outputs came from the new binaries and not a stale environment:
spades 4.3.0, samtools 1.24, bcftools 1.24, all stamped `dependencySet 2026.2`.

### Live checks in the verify root

With `LUNGFISH_STORAGE_ROOT=$HOME/.lungfish-verify`:

```
samtools --version      samtools 1.24 / Using htslib 1.24
bcftools --version      bcftools 1.24 / Using htslib 1.24
bgzip --version         bgzip (htslib) 1.24
tabix --version         tabix (htslib) 1.24
spades.py --version     SPAdes genome assembler v4.3.0
```

samtools and bcftools both link the matching htslib 1.24, so the three moved
together rather than leaving a mixed-ABI environment.

`samtools flagstat -O json` still parses. The 1.24 output is byte-identical to
the golden, loads as JSON with the same two top-level keys
(`QC-passed reads`, `QC-failed reads`), and the nested counts are unchanged.
`MappingConformanceTests` covers this path in require mode and is inside the 189
that passed at tier 1.

### One remaining unit failure, environmental

`ToolVersionConformanceTests.testEveryManifestToolReportsPinnedVersion` fails in
a bare `swift test`, reporting `nextflow: expected 26.04.6`. It is a live-tool
check, and a bare run resolves against the developer's real `~/.lungfish`, where
nextflow is still on the old pin. That root is deliberately untouched by this
sweep. The same test passes inside the isolated verify root once tier 1
reconciles it, and it is one of the 189 that passed there. The failure is group
1's pin, not this group's.

## Group 3 (task C7)

The higher-risk group: a major bbmap version, a savont minor that could have
changed its CLI, and the micromamba bootstrap itself. Each was bumped, verified
and committed on its own so a problem in one could not strand the others.

### Commands

```
python3 scripts/deps/check-upstream.py --json /tmp/candidates.json
python3 scripts/deps/bump.py --set 2026.2 --date 2026-08-18 \
    --from /tmp/candidates.json --only <id>          # dry run first, then real
bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify
bash scripts/deps/verify.sh --tier 2 --root ~/.lungfish-verify
```

### What moved

```
bbtools                                39.80   -> 40.02    bioconda::bbmap=40.02=he046917_0
full-length-mhc-genotyping/savont      0.5.0   -> 0.6.3    bioconda::savont=0.6.3=ha819e4a_0
micromamba (bootstrap)                 2.0.5-0 -> 2.9.0-0
```

Each bump was checked with a semantic diff of the manifest before and after the
write, not a reading of the diffstat. In all three cases only the intended
entry moved: for bbtools and savont the `version` and `packageSpec` fields, for
micromamba the `version` and the `sha256` digest. Every other tool, pack tool,
pipeline, database and the rest of the bootstrap block were byte-identical.

Commits: `84d457a2` bbmap, `608a13b8` savont, `18591b89` micromamba.

### bbmap 40.02

Two things were worth checking on a major version jump.

The Java runtime. bbtools is Java, and the locator hard-codes `lib/jvm/bin/java`
inside the bbtools environment, so a changed JRE dependency in the 40.x package
would break every bbtools call. It did not change: the reconciled 40.02
environment still ships `openjdk 25.0.2` and still exposes
`lib/jvm/bin/java`, so `CoreToolLocator.bbToolsEnvironment` resolves as before.
`clumpify.sh --version` in that environment reports BBTools 40.02 and runs
through the managed JRE.

The stderr summaries. The brief asked whether the ingestion pipeline parses
reformat and clumpify counts out of stderr, which would make the 40.x output
text a compatibility surface. It does not. Every bbtools call site checks the
exit status and uses `result.stderr` only for an error message or to store a
provenance envelope. No code reads counts back out, so a reworded summary in
40.x cannot change behaviour.

One test carried a hard-coded `39.80`. Rather than replace it with `40.02`, it
now reads the pinned version from `ManagedToolLock`, so the next re-pin cannot
leave the same stale expectation behind. That test runs clumpify for real, so
it doubles as a live check that 40.02 works.

Filtered unit run: 87 XCTest and 1 swift-testing, zero failures in both halves.

### savont 0.6.3

A minor version on a tool Lungfish drives through a long argument list, so the
CLI contract was checked against the installed binary rather than assumed.

Every flag `SavontClusteringRunRequest.arguments` can emit still exists in 0.6.3
with the same spelling: the `asv` subcommand, `-o`, `-t`,
`--quality-value-cutoff`, `--min-cluster-size`, `--min-read-length`,
`--max-read-length` and `--single-strand`. No pipeline change was needed.

0.6.3 does change several upstream defaults and adds new subcommands
(`classify`, `download`, `sintax`, `export`) and presets. The defaults that
moved include `--quality-value-cutoff` to 98, `--min-cluster-size` to 12,
`--min-read-length` to 1100 and `--max-read-length` to 2000. Lungfish passes
each of these explicitly, so its behaviour is unchanged, but any flag left
unset in future work would now pick up a different default than under 0.5.0.

`SavontCLIContractTests` was added to hold this ground. It runs
`savont asv --help` in the installed environment and asserts every option token
the argument builder can emit is still documented. The flag list is derived by
calling the production argument builder rather than restated by hand, so a
newly added flag is covered automatically. The matcher was checked against a
simulated 0.7 that renames `--min-cluster-size` and drops `--single-strand`, and
it reports both; it also does not match `--min-read-length` inside
`--max-read-length` or `-o` inside `--output-dir`. Like the rest of the
conformance suite it skips when savont is absent and enforces under
`LUNGFISH_REQUIRE_TOOLS=1`, where it passes with zero skips.

Filtered unit run (`FullLengthONTMHC|Savont|Genotype`): 2377 XCTest, zero
failures, 9 skips. All 9 are environmental: 7 `GenotypeRealBundleSmokeTests`,
1 performance test, and `SavontClusteringIntegrationTests`, which needs a real
ONT FASTQ supplied through an environment variable.

**Manual verification pending.** A real full-length ONT MHC genotyping run
needs the user's own ONT data, which is not available to this task. The bump is
covered by the CLI contract test, the argument-construction tests and
require-mode conformance, but an end-to-end run on real reads has not been done.

### micromamba 2.9.0

The bootstrap is the one component that installs everything else, so it got the
most direct proof.

The checksum was verified two independent ways. `bump.py` cleared the stale
digest and refetched it from the pinned `2.9.0-0` release rather than carrying
the old value forward, which is the supply-chain fix C5 landed, and the result
matches a direct download and hash of the release asset:
`ec2a072f028e1a7cf20f3e2e74d5a8127cf5a5f27636375b5359811565f4e5be`. After
`scripts/bundle-native-tools.sh --arch arm64`, the vendored binary on disk
hashes to that same value and self-reports 2.9.0.

Environment creation with 2.9 was proven in a fresh isolated root
(`/tmp/lge-verify-mm29`) seeded from a root whose bootstrap was still 2.0.5, so
the replacement had something real to replace. The reconciler logged
`bootstrap micromamba 2.0.5 -> 2.9.0-0`, the root afterwards reports 2.9.0 at
the pinned digest, and environments were created with the new bootstrap during
the same run. `tools update --plan` in that root then reports `Nothing to do.`,
so the reconciled state is stable. Tier 1 there: GATE PASS, 189 executed, zero
failures, zero skips. Separately, 2.9.0 was asked to solve and create a brand
new environment from scratch, which it did.

Filtered unit run (`CondaManagerTests|BundledDatabaseManifestTests|
DependencyManifestTests`): 65 executed, zero failures.

### Tier 1

`verify.sh --tier 1 --root ~/.lungfish-verify` after each bump: **GATE PASS,
189 executed, 0 failures, 0 skips**, the same count as the group 1 and group 2
baselines. Read from the gate log rather than the console tail, which prints
the last swift-testing suite rather than the total.

### Tier 2

Run once after the bbmap bump, the only group 3 change that can alter pipeline
output. Keyed to 2026.2 the comparison reports all 13 outputs as `missing`,
because `Tests/Fixtures/conformance/2026.2/` does not exist yet; that is C9's
work and not a result. Against the committed 2026.1 goldens: **12 same, 1
different, 0 missing**, and the one difference is verbatim the same row group 2
recorded.

| recipe | output | status | first difference |
| --- | --- | --- | --- |
| sarscov2-deacon | summary.json | different | `$.check_pairs: only in candidate` |

That is group 1's already-accepted additive deacon key. **Zero differences are
attributable to group 3.** Goldens were not regenerated.

## Held builds (task C8)

Held tools were revisited to pick up newer build strings at the same version.
cutadapt was taken directly. pysam was held at first, then taken once the
selection logic learned about Python ABI tags. Commits `4a3d35cf` and
`6645040a`.

### Taken: cutadapt

```
cutadapt 5.2   py311hd78823b_1 -> py313hf513372_2
```

Build number 1 to 2, with the interpreter moving forward from py311 to py313.
cutadapt is invoked as a binary and is not imported by any Lungfish Python, so
the interpreter is internal to its environment. Verified live in the reconciled
verify root: cutadapt reports 5.2 running on Python 3.13.15.

Tier 1 with the C8 filter
(`FASTQToolIntegration|NativeToolRunner|ONTGenotyping|Conformance`):
**GATE PASS, 115 executed, 0 failures, 0 skips**. The reconciler reinstalled
cutadapt for the build change and left pysam untouched.

### Held first, then taken: pysam

```
pysam 0.24.0   py310hf7cbfa5_0 -> py310hf7cbfa5_1
```

pysam was initially held, because the build the tooling proposed
(`py39hfb5fbb1_1`) was newer by publication time but moved the interpreter
backwards, py310 to py39. That matters more for pysam than for most tools:
Lungfish ships its own Python script that does `import pysam`
(`ONTGenotypingPysamFilterRunner`), so the interpreter is part of the contract
rather than an environment detail.

The hold was a symptom of a tooling gap, so the tooling was fixed rather than
the pin left behind. `check-upstream.py` now understands Python ABI tags:

- `latest_conda` receives the build string of the pin in force. When that build
  carries a py tag, candidates on an older interpreter are discarded before
  selection.
- Among the survivors the highest build number wins. Packages like pysam are
  rebuilt once per interpreter at the same build number, so several candidates
  tie; the tie is broken by closeness to the interpreter already pinned rather
  than by the build string. Without that the raw string comparison jumped a
  py310 pin straight to py314, and before the ABI filter it picked py39
  outright, because `py39` sorts above `py310` lexically.
- ABI closeness is only a tie-break. A genuinely higher build number still
  wins, and a forward interpreter move is taken when it is the newest.
- When every published build sits on a lower ABI, the row is reported as `same`
  with the note `newer build only on lower Python ABI: <spec>` rather than
  proposing a downgrade. When a same-ABI build is chosen but a newer lower-ABI
  one was skipped, the note names the skipped build so the chosen one is not
  mistaken for the newest published.

With that in place the candidate for pysam became `py310hf7cbfa5_1`, the
same-ABI rebuild at the newer build number, which is what the hold had been
waiting on. Verified live in the reconciled verify root: pysam 0.24.0 build
`_1` on Python 3.10.20, with `import pysam` succeeding.

Three other rows flipped from `update` to `same` as a side effect: openpyxl,
lofreq and flye. Each is already at the highest build number published for its
own interpreter (`_3`, `_1` and `_16`), so nothing is masked. Their only newer
builds were interpreter jumps that this sweep was never going to take.

Tier 1 after the pysam bump: **GATE PASS, 189 executed, 0 failures, 0 skips**.
Require mode in the verify root with filter
`ONTGenotyping|NativeToolRunner|ToolVersionConformance`: **80 executed, 0
failures, 0 skips**. Python suite: 411 tests, all passing.

### Every remaining hold

`check-upstream.py --markdown` after the bumps reports cutadapt and pysam as
`same`, along with openpyxl, lofreq and flye. Everything still listed is a
deliberate hold:

| id | status | reason |
| --- | --- | --- |
| read-mapping/minimap2 | no-arm64-build | 2.0.r191 exists but publishes no osx-arm64 or noarch build |
| full-length-mhc-genotyping/blast | no-arm64-build | 2.17.0 is linux only; 2.16.0 is the newest installable |
| metagenomics/bracken | no-arm64-build | 3.1p1 is linux only; 1.0.0 is the only arm64 build, and the C4 product fix is the durable answer |
| kraken2-special-silva | manual-check | special index, rebuilt or re-downloaded by hand |
| kraken2-special-greengenes | manual-check | special index, rebuilt or re-downloaded by hand |
| deacon-panhuman | manual-check | no machine-readable index |
| deacon-ribokmers | manual-check | no machine-readable index |
| ncbi-taxonomy | update available | held this sweep per the C5 ruling: the dated archive is a `.zip` and extraction spans two files plus the provenance contract |
| sra-tools | build only | not in scope for this task; no Python ABI involved, so the ABI rule does not apply |

No tool is now held because of a Python ABI regression. pysam, the one case
that was, moved to its same-ABI rebuild once the selection logic could see it.
sra-tools is the only build-only row left outstanding, and it is outside this
task's scope rather than blocked on anything.

## Goldens 2026.2 (task C9)

Committed at `c7deabf1`.

### Commands

```bash
LUNGFISH_CONDA_ROOT=$HOME/.lungfish-verify/conda \
LUNGFISH_STORAGE_ROOT=$HOME/.lungfish-verify \
    bash scripts/deps/regenerate-goldens.sh --set 2026.2 --out .build/goldens-2026.2

python3 scripts/deps/diff_goldens.py --recipes scripts/deps/goldens.json \
    --candidate .build/goldens-2026.2 --set 2026.1
```

All twelve recipes ran clean, with the kraken2 recipe resolving the Viral
database from the verify root's registry at the new 20260626 index.

### Candidate against the 2026.1 goldens

| recipe | output | status | first difference |
| --- | --- | --- | --- |
| kraken2-mini-SRR35517702 | classification.kreport | same |  |
| kraken2-mini-SRR35517702 | classification.kraken | same |  |
| sarscov2-flagstat | flagstat.json | same |  |
| sarscov2-idxstats | idxstats.tsv | same |  |
| sarscov2-seqkit-stats | stats.tsv | same |  |
| sarscov2-fastp | summary.json | same |  |
| sarscov2-minimap2 | flagstat.json | same |  |
| sarscov2-spades | contigs-stats.tsv | same |  |
| sarscov2-megahit | contigs-stats.tsv | different | row 0 column num_seqs: golden '12', candidate '11' |
| sarscov2-vsearch-derep | count.txt | same |  |
| sarscov2-deacon | summary.json | different | $.check_pairs: only in candidate |
| sarscov2-bcftools | calls.vcf | same |  |
| iqtree-known-sarcopterygian | tree.nwk | same |  |

11 same, 2 different, 0 missing.

Only one of those two differences was a real tool change.

### Accepted: deacon adds an additive key

`sarscov2-deacon` differs by exactly one line, `"check_pairs": false`, which
deacon 0.16.0 adds to its filter summary and which is false for this single
ended recipe. Every numeric field is unchanged. This is the additive key group 1
predicted, and it is carried into the 2026.2 golden.

### Investigated and rejected: megahit is nondeterministic

`sarscov2-megahit` is not a tool change. The megahit pin
`bioconda::megahit=1.2.9=h96a01ab_8` is byte identical to 2026.1, so nothing
about megahit moved this sweep.

Rerunning told the real story. Thirteen isolated runs of the recipe all produced
12 contigs, matching the 2026.1 golden. A full rerun of the whole batch also
produced 12, and the diff came back 12 same, 1 different with only the deacon
key outstanding. The 11 contig result has appeared twice, both times in a full
batch run where megahit follows SPAdes, and never once in isolation. This is
megahit's own run to run nondeterminism under the recipe's two threads,
surfacing when the machine is loaded, and the machine used here sits at a load
average around 30 from unrelated user applications.

The flip matters because it is not absorbed by the tolerance. Against the 12
contig golden, 11 contigs is 8.3 percent on `num_seqs` and the N50 move from 332
to 351 is 5.7 percent, both outside the recipe's 5 percent relative tolerance.
Only `sum_len` stayed inside, at 2.7 percent.

The reproducible 12 contig result is what was recorded.

**Open item.** This is the one golden that can fail for a reason unrelated to
any dependency change, which weakens tier 2 as a gate: a later sweep can see a
red tier 2 that means nothing. A second tier 2 run during this task did exactly
that. Two fixes are worth considering, neither taken here because both change a
recipe rather than a pin: run megahit single threaded so the assembly is
deterministic, or compare only `sum_len`. Recorded in
`Tests/Fixtures/conformance/README.md` next to the golden.

### Investigated: kraken2 cannot witness the index rename

The kraken2 golden is byte identical to 2026.1 even though the Viral index moved
to 20260626, which was expected to change it. The index in the verify root is
genuinely the new one: `inspect.txt` contains `Betacoronavirus pandemicum` at
taxid 3418604, and the database provenance records workflow version 20260626.

The recipe cannot see it. `Tests/Fixtures/kraken2-mini/SRR35517702/source.fastq`
holds three synthetic 12-base reads (`ACGTACGTACGT` and friends), and all three
come back unclassified, so the report is a single `unclassified` line that no
index change can move. The recipe pins that kraken2 runs and produces a
well-formed report, not that any particular taxonomy is in the database.

This is recorded because the unchanged golden is misleading on its face: it must
not be read by a later sweep as evidence that the 20260626 taxonomy was
verified. Nothing in the conformance goldens covers the SARS-CoV-2 species
rename, and the name-keyed display surfaces called out in the group 1 release
notes item still need their own review before shipping.

### Provenance and audit

The twelve candidate directories were copied to
`Tests/Fixtures/conformance/2026.2/`, excluding the `stderr.log` that
`regenerate-goldens.sh` writes as a debugging aid, matching the 2026.1 layout.
Each is registered in `scripts/testing/fixture_provenance.py` with
`dependencySet: "2026.2"`, and the four goldens with something to explain
(deacon, megahit, kraken2, plus the version moves on spades and bcftools) carry
that explanation in their `purpose` string.

The writer created all twelve sidecars without needing `--overwrite`, so the
guard that aborts at the classifier-full-viewer check was never reached and the
delete-then-write fallback was not needed. `bash
scripts/testing/audit-fixture-provenance.sh` reports **fixture provenance audit
passed**.

`Tests/Fixtures/conformance` is 252K in total, well under the 5 MB ceiling, so
the 2026.1 goldens stay as history.

### Two guards were asserting against the wrong set

Both restated the current dependency set as a literal `"2026.1"`, so after this
bump they would have kept checking the previous set's goldens while still
passing, which is the failure mode where a guard goes quiet exactly when it
starts being needed.

- `scripts/tests/test_diff_goldens.py` now reads `dependencySet` from
  `third-party-tools-lock.json` rather than restating it.
- `scripts/tests/test_fixture_provenance_scripts.py` built its synthetic root
  from a hardcoded 2026.1 while the audit it invokes reads the real
  `RETAINED_FIXTURES`, so once 2026.2 was registered the two disagreed and two
  tests failed with twelve missing fixture directories. It now derives the set
  list from `RETAINED_FIXTURES` itself and covers every registered set, which
  keeps retired sets working since they stay on disk as history.

Python suite after both fixes: **411 tests, OK**. Verified the second fix is not
vacuous: the test list now contains all 33 real entries with none missing.

### Tier 2 at 2026.2

`bash scripts/deps/verify.sh --tier 2 --root ~/.lungfish-verify`, now keyed to
2026.2 from the manifest: **13 same, 0 different, 0 missing**.

A second run of the same command returned exit 2 on the megahit flip described
above, with the other twelve outputs same. That is the flakiness, not a
regression.

## SwiftPM (task C10)

### Package.resolved delta

`swift package update` moved twenty packages and added one. Every exact pin
held: containerization 0.24.5, grpc-swift 1.27.5, swift-protobuf 1.35.0 and
Sparkle 2.9.6 are all unchanged.

| package | old | new |
| --- | --- | --- |
| async-http-client | 1.30.3 | 1.36.0 |
| swift-argument-parser | 1.7.0 | 1.8.2 |
| swift-asn1 | 1.5.1 | 1.7.1 |
| swift-async-algorithms | 1.1.1 | 1.1.5 |
| swift-atomics | 1.3.0 | 1.3.1 |
| swift-certificates | 1.17.1 | 1.19.4 |
| swift-collections | 1.3.0 | 1.6.0 |
| swift-configuration | not present | 1.2.0 |
| swift-distributed-tracing | 1.3.1 | 1.4.1 |
| swift-http-structured-headers | 1.6.0 | 1.7.0 |
| swift-http-types | 1.5.1 | 1.6.0 |
| swift-log | 1.9.1 | 1.15.0 |
| swift-nio | 2.94.0 | 2.101.3 |
| swift-nio-extras | 1.32.1 | 1.34.3 |
| swift-nio-http2 | 1.39.0 | 1.45.0 |
| swift-nio-ssl | 2.36.0 | 2.37.2 |
| swift-nio-transport-services | 1.26.0 | 1.28.0 |
| swift-service-context | 1.2.1 | 1.3.0 |
| swift-service-lifecycle | 2.9.1 | 2.12.0 |
| swift-system | 1.6.4 | 1.8.1 |

`swift-configuration` 1.2.0 is new to the graph, pulled in transitively by the
updated server-side packages rather than added by us.

`swift package update` printed one diagnostic at the end of resolution:

```
error: Disabled default traits on package 'async-http-client' (async-http-client) that declares no traits. This is prohibited to allow packages to adopt traits initially without causing an API break.
```

It is labelled `error` but did not stop resolution, and `Package.resolved` was
written. Both products build, so it is a resolution-time complaint about a
transitive dependency declaring disabled default traits, not a build failure.
Worth watching on a future SwiftPM upgrade in case it becomes fatal.

`bash scripts/check-package-resolved-consistency.sh --repair`: **PASS
Package.resolved consistency (no Xcode workspace lockfile)**.

### Builds

`swift build --product Lungfish` and `swift build --product lungfish-cli` both
complete cleanly.

### Full suite gate

The first gate run, at `c7deabf1`, came back **GATE FAIL** with 12 XCTest
failures across seven tests, none of them in the known-environmental baseline.

They were not caused by this task. The goldens commit and the SwiftPM commit
touch no Swift source at all. Every one of the seven restates a pin that groups
1 through 3 moved, so each was already failing at `745c5332` before this task
began: this was simply the first full gate since those bumps landed.

| test | restated | manifest |
| --- | --- | --- |
| AboutAcknowledgementsTests.testCurrentSectionsRenderPinnedMetadataForManagedTools | nextflow 25.10.4, bcftools 1.23.1, spades 4.2.0, esviritu 1.3.1 | 26.04.6, 1.24, 4.3.0, 1.3.3 |
| ToolReferenceCommandTests.testVersionToolsPrintsBundledAndManagedToolTable | micromamba 2.0.5-0, nextflow 25.10.4, samtools 1.23.1 | 2.9.0-0, 26.04.6, 1.24 |
| PluginPackRegistryTests.testRequiredSetupPackDefinesPerToolChecks | bbmap 39.80 | 40.02 |
| PluginPackRegistryTests.testRequiredSetupPackExposesPinnedAboutMetadata | pysam build `_0` | `_1` |
| WorkflowRegressionTests.testMicromambaFactory | micromamba 2.0.5-0 | 2.9.0-0 |
| WorkflowRegressionTests.testCreateVersionInfoWritesMicromambaOnlySummary | micromamba 2.0.5-0 in VERSIONS.txt | 2.9.0-0 |
| TaxTriagePipelineTests.testBuildLaunchMetadataUsesDurableWorkflowSnapshotAndReleaseLabel | taxtriage v3.3.6 | v3.3.8 |

This is the same class as the four mirrors C6 fixed and the one C7/C8 fixed.
Nine such mirrors have now been found across the sweep, which is worth noting
as a pattern: a pin bump is not finished when the manifest and the live root
agree, because the mirrors only surface on a full gate.

Fixed at `7e0ed286` by updating each literal to the manifest's current value.

**These were deliberately kept as literals rather than read from
`ManagedToolLock`.** The first attempt derived them, which is tempting because
it never goes stale, and it was wrong: `AboutAcknowledgements` builds its detail
string from the same manifest, so a derived assertion compares the manifest
against itself. That was verified rather than assumed, by sabotaging the built
resource bundle to report a bogus bcftools version. The derived assertion still
passed. A literal is what catches a pin moving when nobody intended it to,
which is the reason these mirrors exist, so refreshing them each sweep is the
intended cost rather than a defect to engineer away. C6 set the same precedent
at `aaf492fa`.

Every replacement literal was checked against the manifest, including taxtriage
v3.3.8, which comes from the pipeline entry's `releaseVersion` field and not
from its revision.

Affected suites after the fix: 97 tests, 0 failures.

The gate rerun at `7e0ed286`:

```
Executed 13433 tests, with 36 tests skipped and 1 failure (0 unexpected) in 1383.921 seconds
```

All seven tool-pin failures are gone. The two that remain are both documented
environmental failures on this machine, and both were confirmed rather than
assumed by rerunning each in isolation:

- `SRASearchIntegrationTests.testBatchThreeAccessions` resolved 1 of 3
  accessions against a required 2. This is the known NCBI SRA reachability
  flake. In isolation: 6 tests, 0 failures.
- The swift-testing `FileSystemWatcher Tests` suite failed with 6 issues, every
  one a watcher callback that never arrived within its timeout. This is the
  documented load-sensitive flake. In isolation: 17 tests, all passed.

Neither touches a dependency pin. The machine ran at a load average near 30
throughout from unrelated user applications, which is the same condition behind
the megahit golden flip.

The gate script still reports **GATE FAIL** because it counts any failure. Read
against the known-environmental baseline (6 GenotypeRealBundleSmokeTests, 2
ZhangArtifactCanaryTests, 1 VCFRobustnessTests plus the documented load flakes),
this run is green: the 9 TCC failures did not appear here because the gate does
not reach those external volumes, and the two that did appear are on the
documented flake list.

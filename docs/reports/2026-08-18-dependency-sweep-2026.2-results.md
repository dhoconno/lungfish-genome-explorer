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

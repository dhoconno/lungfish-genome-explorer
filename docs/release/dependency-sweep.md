# Dependency Sweep Checklist

Lungfish pins every third-party tool, pipeline revision, and reference database
in one manifest: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`.
This checklist is the procedure for bumping that manifest to a new
`dependencySet` and shipping it. See
`docs/superpowers/specs/2026-08-17-dependency-upgrade-mechanism-design.md`
for the design this checklist implements.

## When

Twice a year, plus whenever a security fix in a pinned tool or database needs
to go out sooner. A sweep is a deliberate, tested change to every tool the app
manages, not a routine dependency bump, so it follows this full checklist
even for a single-tool security fix.

## Roles

Fable orchestrates the sweep: it runs the sweep tooling, reviews the
candidate list, decides bumps and holds, dispatches verification, and hands
the finished manifest to the release skill. A human reviews the bump/hold
decisions and the release notes before the release ships.

## Steps

### 1. Survey upstream

```bash
python3 scripts/deps/check-upstream.py --markdown > /tmp/candidates.md
```

Created in Plan C. Reads the manifest and reports, for every pinned tool,
pipeline, and database, the current version against the latest available
upstream: bioconda and conda-forge repodata, GitHub releases for TaxTriage,
EsViritu, deacon, micromamba, and Sparkle, and the Kraken2/NCBI taxonomy
archive listings. Read-only; it does not touch the manifest. Expected
runtime: 2 to 5 minutes (network-bound repodata and API queries).

### 2. Decide bumps and holds

Review `/tmp/candidates.md` line by line. For each candidate, decide bump or
hold and record the reasoning in a release-notes draft:

```
docs/release-notes/deps-<set>.md
```

A hold needs a reason (already current, deliberately deferred, upstream
regression). A bump of a tool with a known output-format risk gets a note in
the same draft so step 4's tier 2 review has context. Expected time: 30 to 90
minutes of judgment, not compute.

### 3. Rewrite the manifest

```bash
python3 scripts/deps/bump.py --set <YYYY.N> --from /tmp/candidates.json [--hold id,...]
```

Created in Plan C. Rewrites the manifest with the decided bumps, resolves
full build strings from repodata, records checksums where fetchable, sets
`dependencySet` and `dependencySetDate`, and regenerates the derived files
(`Resources/Tools/tool-versions.json`, `VERSIONS.txt`,
`THIRD-PARTY-NOTICES` tool table). Idempotent: rerunning with the same
inputs produces the same manifest. Expected runtime: under 1 minute.

### 4. Verify

```bash
bash scripts/deps/verify.sh --tier 1
bash scripts/deps/verify.sh --tier 2
bash scripts/deps/verify.sh --tier 3
```

Created in Plan C. Provisions the new manifest's tools and databases into an
isolated storage root, then runs each regression tier in turn.

Tier 1 (toolset conformance) provisions the full toolset and runs the
conformance suites under `Tests/LungfishWorkflowTests/Conformance/` with
`LUNGFISH_REQUIRE_TOOLS=1`, so a missing tool or database is a hard failure
rather than a skip. Expect 30 to 60 minutes, most of it tool and database
provisioning.

Tier 2 regenerates the golden fixtures with `scripts/deps/regenerate-goldens.sh`
and compares them against the committed goldens with
`scripts/deps/diff_goldens.py`. A header change in any output is always a
failure that needs a parser fix, not a looser rule. A value-level difference
may be legitimate (a tool's algorithm changed) and gets regenerated
deliberately, with the justification recorded in the release-notes draft from
step 2. Expect 10 to 20 minutes.

Tier 3 runs the full TaxTriage and EsViritu pipelines end to end against a
live SRA accession and diffs the report schemas against the mini fixtures.
This tier is manual, not part of CI, because it needs network access, a
container runtime, and multi-gigabyte databases:

```bash
bash scripts/deps/run-pipelines.sh --which all --out /tmp/tier3-<set>
```

Expect 45 to 90 minutes, dominated by TaxTriage's Nextflow pipeline and the
EsViritu database.

### 5. GUI walkthroughs

Drive the app with Computer Use, per the project's GUI-testing rule, against
three storage-root states: a fresh install into an empty root, an upgrade
from a root seeded with a previous release's `envs/` and no receipt, and an
upgrade from a root with a receipt one set behind. Each walkthrough checks
the Update Tools sheet contents, the OperationCenter entries during
provisioning, the receipt after completion, and that a representative
analysis (FASTQ QC, Kraken2 viral classification) runs afterward. Expect 30
to 45 minutes per walkthrough.

### 6. Dispatch toolset-conformance in CI

```bash
gh workflow run ci.yml --ref main
```

This triggers the `workflow_dispatch`-only `toolset-conformance` job, which
provisions the manifest's tools from a clean macOS runner and repeats tier 1
and the golden diff. A green run at the manifest's hash is required before
release; it is independent evidence beyond the local tier 1 and 2 runs.
Expect 60 to 100 minutes of CI time.

### 7. Release notes

Add a "Updated tools and databases" section to the release notes, listing
every bumped tool and database with its old and new version, pulled from the
draft written in step 2.

### 8. Bump the app version and release

Bump the app version and run the release skill
(`.codex/skills/releasing-lungfish/SKILL.md`). Its release gates check that
`dependencySet` in the manifest matches the receipt produced by
`scripts/deps/verify.sh` and that a green `toolset-conformance` run exists
for the manifest hash before it will proceed.

## Known-risk checklist

Every sweep should specifically verify the following, since these are the
places a tool bump has previously broken silently instead of loudly:

1. bbmap behavior in FASTQ ingestion: clumpify, bbduk, bbmerge, and repair
   defaults, since bbtools changes its CLI defaults across minor versions.
2. Savont's output contract for full-length MHC genotyping, checked at both
   literal call sites and in pipeline parsing.
3. samtools flagstat and idxstats text output, since a samtools bump can add
   a JSON output path without changing the default text format, and a parser
   written against the JSON path will silently stop matching.
4. micromamba's environment-creation flags and `--platform` handling, since a
   micromamba bump is a bump to the tool that installs every other tool.
5. TaxTriage's report and `multiqc_confidences.txt` shape, and the Kraken2
   kreport shape at the paired Kraken2 version, since both are hand-parsed
   TSVs with no schema enforcement upstream.

A sixth risk worth checking on any Nextflow bump: the conda and container
profile behavior with `NXF_CONDA_CACHEDIR`, since Nextflow's profile
resolution has changed silently across minor versions before.

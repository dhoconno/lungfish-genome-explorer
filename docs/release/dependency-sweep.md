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

Check the candidate list for interpreter direction on any Python package
before accepting it. Candidate selection is ABI aware and will not propose a
build on an older Python than the one pinned, but it reports such a case as
`same` with a note naming the skipped build, so a row that looks unchanged
may be waiting on an upstream rebuild rather than genuinely current. The
2026.2 sweep hit this on pysam, where the newest build by publication time
was an interpreter downgrade.

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

Bump in risk-ordered groups rather than all at once, with `--only`: low-risk
tools first, then medium-risk families that must move together (the htslib
family, for instance), then the high-risk items that can strand the rest
(a major version, a tool driven through a long argument list, and the
micromamba bootstrap). Commit and verify each group before starting the next
so a failure names one group instead of thirty pins.

Confirm each write with a semantic diff of the manifest before and after,
comparing parsed entries rather than reading the diffstat. The 2026.2 sweep
caught an earlier defect this way, where the tool rewrote checksums for ids
it had not bumped.

Run step 4's build and unit gate per group, not once at the end. Test files
that restate a pinned version as a literal only fail on a full gate, so
running the gate once at the end attributes every stale mirror to whichever
task happened to run it. The 2026.2 sweep found nine such mirrors, seven of
them surfacing at the end and belonging to three earlier groups.

Keep those mirrors as literals when you refresh them. Deriving them from the
manifest is tempting and wrong: the surfaces they guard build their own
output from the same manifest, so a derived assertion compares the manifest
against itself and passes even when the value is bogus. That was verified
during the 2026.2 sweep by sabotaging a built resource bundle. Refreshing the
literals each sweep is the intended cost.

### 4. Verify

```bash
bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify --seed-from ~/.lungfish
bash scripts/deps/verify.sh --tier 2 --root ~/.lungfish-verify
bash scripts/deps/verify.sh --tier 3 --root ~/.lungfish-verify
```

Created in Plan C. Provisions the new manifest's tools and databases into an
isolated storage root, then runs each regression tier in turn.

Always pass `--root` and never verify against the developer's own
`~/.lungfish`. Pass `--seed-from` on the first run of a sweep so the isolated
root starts from the existing install and only the changed environments are
downloaded; without it the first tier 1 run re-downloads the entire toolset.
The seeded root's database registry is repointed at the isolated root
automatically.

Read both halves of the test output. A `swift test` run prints an XCTest
summary and a swift-testing summary separately, and the swift-testing line
alone hides XCTest failures. The 2026.2 sweep reported one group as clean on
the swift-testing line while four XCTest mirrors were already failing. For
the same reason, read tier 1's result from the gate log rather than the
console tail, which prints the last swift-testing suite rather than the
total.

The tier 1 plan gate tolerates advisory database updates. It reads
`tools update --plan --json` and judges the contents: pending environment
installs, reinstalls, removals, a bootstrap update, or a database update with
policy `required` still fail the gate, while an advisory-only plan is printed
and the run continues. An advisory database update pending in the isolated
root is therefore not a gate failure.

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

Before accepting a value-level difference as a tool change, confirm the pin
actually moved. A golden can differ because the recipe is nondeterministic
rather than because anything upstream changed, and the 2026.2 sweep spent
real time on a megahit difference whose pin was byte identical to the
previous set. Rerun the recipe in isolation on an idle machine; if it does
not reproduce, the recipe needs to be made deterministic rather than the
golden re-recorded. Any recipe that produces a different answer run to run
should be pinned to single-threaded execution.

Keyed to the new set, the comparison reports every output as `missing` until
the goldens are regenerated into `Tests/Fixtures/conformance/<set>/`. That is
expected during the bump groups, not a result. Compare against the previous
set while bumping, and key to the new set only after regenerating.

When you do regenerate, refresh each golden's provenance sidecar by deleting
it and rewriting rather than passing `--overwrite`, and rerun
`bash scripts/testing/audit-fixture-provenance.sh`. Check that any guard
restating the current dependency set reads it from the manifest instead of a
literal: two such guards in the 2026.2 sweep would have kept checking the
previous set while still passing.

Tier 3 runs the full TaxTriage and EsViritu pipelines end to end against a
live SRA accession and diffs the report schemas against the mini fixtures.
This tier is manual, not part of CI, because it needs network access, a
container runtime, and multi-gigabyte databases:

```bash
bash scripts/deps/run-pipelines.sh --which all --root ~/.lungfish-verify --out /tmp/tier3-<set>
```

Expect 45 to 90 minutes, dominated by TaxTriage's Nextflow pipeline and the
EsViritu database.

Pass `--root` here too, or the pipelines resolve against the developer's real
storage root. Check the prerequisites before starting: TaxTriage needs Apple
Containers or a running Docker daemon, and EsViritu needs its database
present in whichever root you pass. Both were absent during the 2026.2 sweep,
which is why that set shipped with tier 3 unrun. A tier 3 that cannot run is
recorded as blocked with the specific missing prerequisite, not as a pass.

#### Savont on real ONT reads

Savont's output contract is item 2 on the known-risk checklist below, and it
is the one item that cannot be checked without real Oxford Nanopore reads.
Fetch the fixture and run the integration test:

```bash
bash scripts/deps/fetch-savont-fixture.sh
LUNGFISH_CONDA_ROOT="$HOME/.lungfish-verify/conda" \
  swift test --filter SavontClusteringIntegrationTests
```

The fetch is idempotent, so a second sweep on the same machine reuses the
cached copy and costs nothing. The test finds the cached fixture on its own;
set `LUNGFISH_SAVONT_TEST_INPUT` only to point it at different reads. The test
never downloads anything itself, so it stays a skip on a machine where the
fixture was never fetched, including under `LUNGFISH_REQUIRE_TOOLS=1`.

Fixture provenance:

| Field | Value |
| --- | --- |
| Run accession | SRR31764993 |
| Study | PRJNA1199206, nationwide multicenter ONT 16S rRNA species identification |
| Platform | Oxford Nanopore MinION, AMPLICON, PCR, synthetic metagenome |
| First public | 2025-05-28 (public, no login, no controlled access) |
| Size | 14,809,727 bytes compressed |
| md5 | `5faa45002beffae3649e6aee28a4d9c8` |
| sha256 | `d6e6ce7945d1965848cd36d1ccac6583bfe0e7292b2c02b122c8e2393fe35732` |

Expected statistics, measured 2026-08-19 with the managed `seqkit`:

| Statistic | Value |
| --- | --- |
| Reads | 14,971 |
| Total bases | 21,640,873 |
| Mean read length | 1,445.5 bp (median 1,462, max 3,177) |
| Reads in Savont's default 1100-2000 bp window | 14,659 (97.9%) |
| Q20 | 82.81% (mean quality 16.91) |

Expected Savont result at 0.6.3, byte identical across two consecutive runs:
10 ASVs on the whole run with default parameters, and 4 ASVs on the 1,000-read
subset the integration test clusters. A cluster count of zero is the failure
mode to watch for; see below for why.

Why this accession. Savont needs an amplicon whose reads land in its
length window and whose accuracy clears its consensus quality gate, and the
sweep needs a file small enough to fetch in seconds. This run is a full-length
16S amplicon at roughly 1.45 kb, which sits almost entirely inside Savont's
default window, and is modern enough chemistry to produce consensuses. Being a
synthetic metagenome, its amplicon pool has genuinely distinct members, so the
clustering has real structure to find rather than one dominant sequence.

Why not a primate MHC amplicon, which would match the domain better. Human HLA
class I ONT amplicon runs exist and are attractively small: PRJNA434212 offers
30 runs of roughly 4.1 kb HLA-A, HLA-B and HLA-C amplicons at 4 to 14 MB.
They do not work. SRR6729382 was fetched and tested during this evaluation:
Savont 0.6.3 forms 38 clusters and then discards every one of them at the
low-quality consensus filter, writing an empty `final_asvs.fasta`. The cause is
the chemistry, not the parameters. That study is from 2018 R9.4 2D basecalls
with mean quality 13.7 and Q20 near 50%, and lowering `--n-depth-cutoff` from
250 to 20 does not recover any consensus. A fixture that yields zero clusters
cannot witness an output-contract regression, since the empty result looks the
same whether the contract broke or not. Read accuracy therefore won over
taxonomic proximity.

The consequence is that this fixture covers the Savont invocation, the cluster
FASTA parse, the supporting-read-count normalization, and the provenance
envelope, but not the MHC-specific reference matching downstream of clustering.
That part still needs real MHC data. If a future sweep wants to close the gap,
look for a primate MHC amplicon run on R10.4 or later chemistry rather than
revisiting the 2018 studies.

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

Finish `docs/release-notes/deps-<set>.md`, started as a draft in step 2, and
add an "Updated tools and databases" section to the release notes listing
every bumped tool and database with its old and new version.

Build the old-to-new table by diffing the parsed manifest against the
previous set's commit rather than transcribing it from the bump logs, so the
table cannot drift from what actually shipped.

Include the upgrade plan a user at the previous set would see, captured
read-only against a clone of a real storage root:

```bash
/bin/cp -Rc ~/.lungfish /tmp/lge-<prev>-clone
LUNGFISH_STORAGE_ROOT=/tmp/lge-<prev>-clone \
  .build/debug/lungfish-cli tools update --plan
rm -rf /tmp/lge-<prev>-clone
```

Use `--plan` only, never `--apply`, and delete the clone afterwards. On APFS
`cp -Rc` clones blocks rather than copying, so even a 45 GB root is cheap and
consumes no additional space.

This step is what surfaces user-visible consequences the manifest tables do
not show. The 2026.2 plan revealed reinstalls for build changes at unchanged
versions, which the version table cannot express, and those need their own
note so the update does not look like it is reinstalling tools at random.
Also carry into the notes any upstream taxonomy or display-name change in a
bumped database, since users match on those names even though the parsers
carry taxonomy ids.

### 8. Bump the app version and release

Bump the app version and run the release skill
(`.codex/skills/releasing-lungfish/SKILL.md`). Its release gate checks that a
green `toolset-conformance` run exists for the manifest hash before it will
proceed, and that `dependencySet` in the manifest matches the receipt
produced by `scripts/deps/verify.sh`.

Remember that the app version itself is restated in roughly eight source
locations plus two test expectations, which all move together.

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

The 2026.2 sweep added three more:

7. Taxonomy and display names in any bumped reference database. The 20260626
   Kraken2 indexes renamed the SARS-CoV-2 species, which no parser noticed
   because they all carry taxonomy ids, but which breaks anything matching on
   the name. Check that the conformance assertions for a bumped database key
   on ids rather than names, and check whether a golden can witness the change
   at all before reading an unchanged golden as evidence.
8. Whether a tool's self-reported version can still be trusted. Two tools now
   misreport or cannot report their own version while their package metadata
   is correct, and both are asserted against metadata through a narrow named
   exception list. Review that list each sweep: an entry that upstream has
   since fixed should be removed so the tool is checked normally again.
9. Java runtime dependencies on a bbtools major bump, since the tool locator
   resolves a JRE inside the bbtools environment by a hardcoded path.

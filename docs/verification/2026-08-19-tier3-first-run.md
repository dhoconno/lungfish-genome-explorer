# Tier 3 first real run (2026-08-19)

Status: PASS after four fixes. Tier 3 had never been run before this. It found two
product bugs and two stale golden recipes, all of which would otherwise have shipped
with dependency set 2026.2.

## Tier 3 was not blocked

Earlier notes recorded tier 3 as blocked for want of Apple Containers or Docker. That
was stale. Docker was installed and running, the EsViritu database was present, and the
verify root already had sra-tools, seqkit, nextflow and esviritu. The correct
prerequisite check is the dry run:

```
bash scripts/deps/run-pipelines.sh --which all --out /tmp/lge-tier3 --root ~/.lungfish-verify --dry-run
```

## Bug 1: esviritu detect failed on a correctly installed database

`EsVirituDatabaseManager.isInstalled()` and `installedDatabaseInfo()` both prefer the
registry directory `databases/esviritu/esviritu-viral-db/`, which is where the Plugin
Manager and `conda db download` write. `databaseURL`, the property the CLI actually
calls, returned the versioned path `databases/esviritu/<version>/` unconditionally.

So on any machine using the registry layout, `isInstalled()` returned true and the
caller was handed a path that does not exist. `lungfish esviritu detect` failed with
"Database directory not found" on a database that was correctly installed. This was not
specific to tier 3: it affected the shipped CLI.

Fixed so `databaseURL` prefers the registry directory when it exists. `download()` and
the `isInstalled()` fallback use the versioned layout explicitly, so a fresh install is
unchanged, and `remove()` deletes the registry directory rather than the inner directory
the resolver returns. Two regression tests added. Verified live: detection completes in
about 12 seconds and reports 3 viruses.

## Bug 2: TaxTriage v3.3.8 requires a database

TaxTriage v3.3.8 validates its own parameters and refuses to start without `--db` or
`--download_db`. Lungfish passes `--db` only when a database is configured, so a run
without one failed inside Nextflow with a bare "pipeline failed with exit code 1".

This is a regression introduced by this sweep, since 2026.2 is what moved TaxTriage to
v3.3.8. The CLI now fails immediately with the flag to pass and the commands to list or
install a database. The tier 3 runner resolves viral or standard-16 from the root under
test and takes a `--kraken2-db` override.

## Golden recipe 1: multiqc_confidences.txt no longer exists

`taxtriage-multiqc-confidences` compared `report/multiqc_data/multiqc_confidences.txt`.
TaxTriage v3.3.8 does not emit that file at all: a completed run contains no file
matching `*confidence*` anywhere, work directories included. The fixture was captured
under v3.3.6.

Replaced with `taxtriage-top-report`, comparing `top/<sample>.top_report.tsv`, which
carries the classification schema the recipe was meant to guard and has a real header
row (abundance, clade_fragments_covered, number_fragments_assigned, rank, taxid, name).

## Golden recipe 2: a headerless file compared as though it had a header

`taxtriage-combine-gcfmap` compared `<sample>.combined.gcfmap.tsv` with kind
`tsv-header`. That file has no header row, so the comparison was reading its first data
record, a reference accession, and reporting ordinary biological difference as schema
drift. Golden and candidate are both 4 columns, so the schema was never drifting.

Recipe removed rather than left failing. Restore it only alongside a comparison kind
that checks column count rather than column names. `diff_goldens.py` has no such kind
today: the valid kinds are text, tsv, tsv-header, json, kreport and newick-topology.

## Schema change accepted

EsViritu 3.14 adds two columns to `detected_virus.info.tsv`, `adj_taxonomy` at position
17 and `consensus_ref_identity` at position 23. The change is purely additive, with
nothing removed or renamed, so the mini fixtures were refreshed from this verified run.
`virus_coverage_windows.tsv` was unchanged and was refreshed alongside it.

## Lesson for the next sweep

Tier 3 is the only check that runs the real pipelines end to end, and on its first run
it found a shipped CLI bug, a regression introduced by the sweep itself, and two golden
recipes that could never have passed. Run it before the release build, not after, and do
not trust a recorded "blocked" status without re-checking the prerequisites.

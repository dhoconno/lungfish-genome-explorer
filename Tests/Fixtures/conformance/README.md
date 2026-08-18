# Conformance goldens

Committed tool outputs for one dependency set, used to answer a single question
when third-party tools are upgraded: did any tool change what it produces for the
same input?

Each subdirectory of `2026.1/` holds the outputs of one recipe from
`scripts/deps/goldens.json`, plus a `meta.json` recording the tool version, the
environment, and when the golden was generated. The recipes reduce every tool run
to a small summary (counts, statistics, a topology, a variant table) so a golden
directory stays a few kilobytes rather than carrying whole BAMs or assemblies.

## Regenerating and comparing

Generate a fresh set of outputs with the currently installed tools:

```bash
bash scripts/deps/regenerate-goldens.sh --set 2026.1 --out /tmp/goldens-2026.1
```

Compare that candidate tree against the committed goldens:

```bash
python3 scripts/deps/diff_goldens.py --recipes scripts/deps/goldens.json \
    --candidate /tmp/goldens-2026.1 --set 2026.1
```

The comparison exits 0 when everything matches, 2 when an output differs, and 3
when a golden is missing. Add `--only <id>` to restrict either command to named
recipes, and `--json` to get machine-readable results instead of the Markdown
table.

## Comparators

Outputs are compared by kind, not byte for byte, so that meaningless variation
does not raise a false alarm while real changes still surface.

- `kreport` compares the set of (rank, taxid, name) taxa and their read counts.
- `tsv` and `tsv-header` compare declared columns by position or by header name.
  Any header change in a `tsv-header` output is a failure on its own, because a
  renamed or reordered column is a contract change even when the values match.
- `json` walks the document recursively, skipping `ignoreKeys` and allowing an
  absolute or relative numeric tolerance.
- `newick-topology` compares the leaf set and the unrooted splits, ignoring
  branch lengths and root placement.
- `text` is an exact match after trimming surrounding whitespace.

## Starting a new dependency set

Create `Tests/Fixtures/conformance/<set>/`, regenerate with `--set <set>`, copy
each recipe's outputs into its golden directory, add the new directories to
`RETAINED_FIXTURES` in `scripts/testing/fixture_provenance.py` with a
`dependencySet` field, and run `bash scripts/testing/audit-fixture-provenance.sh`
to write and validate the provenance sidecars.

## Why kraken2-mini has its own golden

The recipe `kraken2-mini-SRR35517702` writes to
`2026.1/kraken2-mini-SRR35517702/` rather than updating the older fixture at
`Tests/Fixtures/kraken2-mini/SRR35517702/`. That older fixture was produced
against the Standard-16 database and reports roughly 2.5 million reads across
2,157 report lines, while its own `source.fastq` holds three synthetic 12-base
reads. It is a viewer fixture, not a reproducible classification of its input.
The recipe runs the same reads against the installed Viral database and produces
a single unclassified line, so the two are not comparable and the older fixture
is left untouched.

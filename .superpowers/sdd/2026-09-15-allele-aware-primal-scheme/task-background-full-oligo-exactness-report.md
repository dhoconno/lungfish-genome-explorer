# Full-oligo exactness annotation: completed fixed-A1 background products

## Result

All6687 retained concrete background-product witnesses were annotated successfully, with every saved terminal mismatch count, terminal interval, orientation, full footprint and product geometry independently recomputed from the bound original103 rows. No hit search, discovery, optimizer, coverage credit or acceptance predicate was run or changed.

**17 of18 selected A1 configurations have at least one added-background150–250bp product with both complete oligos exactly matching the observed templates** (166 unary witnesses). This is stronger sequence support than zero mismatches in only the17-base terminal seed. It does not establish intended coamplification, experimental amplification or a feasible combined panel.

| Context | Both full exact | One full exact | Neither full exact |Total|
|---|---:|---:|---:|---:|
| Unary |174|698|737|1609|
| Same-pool pair |551|2241|2286|5078|
| Total |725|2939|3023|6687|

| Context / product length |Both full exact|One full exact|Neither full exact|
|---|---:|---:|---:|
| Unary150–250 |166|634|616|
| Unary251–500 |0|30|26|
| Unary501–2000 |8|34|95|
| Pair150–250 |8|34|30|
| Pair251–500 |73|303|267|
| Pair501–2000 |470|1904|1989|

There were no products below150 bases. The725 both-full-exact witnesses fall on A2(271), A4(432), B(20), E(2). Full per-end mismatch positions, synthesis-oriented observed templates, terminal/nonterminal partitions, context/ownership, row aliases and original witness records are retained in `annotations.jsonl.gz`. The summary contains complete per-end mismatch histograms; the maximum complete-oligo mismatch count observed was11. Nonterminal mismatches do not prove amplification absent.

A subsequent saved-annotation category recount shows that hypothetically ignoring **only both-full-exact** background witnesses still leaves18/18 unary configurations with rejection witnesses:1435 acrossD2000, including1250 in150–250 alone. This is descriptive category filtering, not a rerun or modification of scientific validation. Shared exact products cannot by themselves explain away all the fixed-panel gate failures.

## Reproducibility and retained files

Evaluation root `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development`.

- Frozen script: `background-full-oligo-exactness-frozen01/annotate.py`,18463bytes, SHA256 `7410cdc92d92668254d3606f4a25ad68bd8f5691c1226569dc993124118677d6`.
- Frozen tests: `background-full-oligo-exactness-frozen01/test_annotate.py`,3940bytes, SHA256 `9f6c44c6a54d3b9238c25ab511733eba9d4c4cdb6c53e41b817edd4977eb5df9`.
- Output: `mamu-a1-background-full-oligo-exactness-01`.
- Summary:143606bytes, SHA256 `e1e79eb3acea42cdc162bdf98a7d07d6cab8b5df59afa14a1b63e7d136e39d22`.
- Complete annotation gzip:651042bytes, SHA256 `4dd5345b715f29516a33736da6966e1a24a9fe4bf891446c040d0ce885dba9cc`.
- Provenance:39105bytes, SHA256 `e5b9c34550dcb2303d00c15204b9d958ae418e6d3f9b35e833933266dc3a6974`.

Exact command, executed from that evaluation root:

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix07/.venv/bin/python background-full-oligo-exactness-frozen01/annotate.py --screen mamu-a1-fixed-panel-original11-background-01 --snapshot mhc-fixture-snapshot-v3/snapshot --helper fixed-panel-background-screen-frozen01/background_screen.py --output mamu-a1-background-full-oligo-exactness-01
```

Receipt status success, exit0,2.255883292s wall time, identitiesUnchanged=true. The command preserves the lexical venv executable. The script binds source screen outputs to its completed receipt, raw snapshot inventory/FASTA bytes to the original screen inputs, the approved parsing helper and every native Python source file to the original screen's recorded bytes, then requires exact parsed target/row labels and content identities. Each source/input/runtime file is hashed before consumption and its device/inode/size/mtime/ctime identity checked at end; the receipt explicitly states this verification policy. No live or unfinished output was read.

The derived output retains requested/resolved inputs/output, exact argv/shell/cwd, source/runtime identity, input/output SHA256 and sizes, timestamps/time/status, resource use and failure evidence. Fresh-output conflicts preserve originals and write sibling failure receipts. Completed annotation counts/categories must reproduce the source90-context/6687-witness inventory before complete=true. Any input/source/runtime change invalidates success and completeness.

## Verification

TDD initial collection failed because `annotate` did not exist. The first implementation had a Python conditional-spacing syntax error, corrected before testing. Final focused verification13tests passed; tests cover plus/minus synthesis orientation, prefix/terminal partitions, ungapped/insertion coordinates, missing/ambiguous footprints, seed-coordinate/count/classification consistency, product exactness, source row/duplicate alias keys, stale binding and failure/output-conflict receipts. Ruff format/check passed.

Retained independent post-freeze test command:

```sh
/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix07/.venv/bin/python -m pytest /Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/background-full-oligo-exactness-frozen01/test_annotate.py -q
```

**13passed in0.11s, exit0.** Exact stdout/stderr, frozen input hashes, runtime and command receipt are in `background-full-oligo-exactness-verification-01`. The real annotation run is separate from these tests and is awaiting parent's independent source/recount review. No production/native/Swift files were edited.

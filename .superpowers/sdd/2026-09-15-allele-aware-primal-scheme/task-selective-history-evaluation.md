# Selective history bounded evaluation

## Frozen inputs and source

The native evaluation used commit `cfafd488fa064438f005417a85d85904ec81da4d`.
The parent-reported frozen native suite completed with 900 tests passing. The
corrected measurement scripts are in commit `1bd5ea118`.

The original A1 input was retained at its original path and measured as
17,940 bytes with SHA-256
`668a009c6e5adf706dca189100f0e0d5e3df63d68ced96865cfb73ad2f67e13e`.
The durable evaluation copy is
`selective-history-evaluation-01/`; [copy-provenance.json](selective-history-evaluation-01/copy-provenance.json)
records the exact copy command, runtime, per-file hashes/sizes, status, and
elapsed time. The original `/tmp/selective-history-evaluation-01-20260916`
directory remains intact so its absolute provenance paths remain valid.

## Tiny CLI checks

The deterministic one-row fixture produced 999 discovery sites and 176
families in compact, full, and default mode. Default resolved to compact.
The run had zero selected assignments; these checks establish CLI, catalog,
history, cache, audit, and replay wiring and do not establish selection
quality. Panel, audit, history query, cache export/reuse, and family/site
diagnostic receipts all reported success with stable source/runtime/input
identities.

## Original A1 anchored API probe

The probe used native MSA parsing and `build_variant_catalog` directly with
forward anchors `[394, 444, 494]` and reverse anchors `[544, 594, 644]`.
Both modes produced one family and 370 sites with identical scientific
projections:

| Mode | History counts (evidence / assessments / events / snapshots) | SQLite bytes | Wall time |
| --- | --- | ---: | ---: |
| compact | 0 / 0 / 10 / 1 | 73,728 | 0.269 s |
| full | 898 / 527 / 1,064 / 1 | 3,117,056 | 0.647 s |

Source, runtime, and input identities were unchanged before and after both
runs. This is a single bounded anchor sample, so it does not support a
whole-panel speed ratio.

## Bounded original A1 compact CLI smoke

The compact CLI run used one pool, a 30-second optimizer bound, and salvage
off. It completed successfully in 246.639 s with peak process RSS
4,162,469,888 bytes (~3.88 GiB), 147,488,461 bytes of output at high water,
and 34 hashed output files. It produced five amplicons and 24.1317% coverage.
Measured phases were discovery 80.705 s, search/validation 57.400 s, and
publication/audit 95.013 s. The post-run audit succeeded and reparsed the raw
input. Source, runtime, and input identities remained stable.

The short bounded result is an engineering measurement. It does not support
the quality of the longer two-pool baseline; search and publication remain
material costs. No full11 rerun, cancelled artifact, GUI change, or installed
runtime edit was performed.

Receipts and outputs are retained under
`selective-history-evaluation-01/`, including the probe receipt, A1 harness
receipt, tiny CLI receipts, and audit results.

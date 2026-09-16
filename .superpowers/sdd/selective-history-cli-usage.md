# Selective discovery history usage (draft)

This is a source-freeze usage draft. The compact/full option and diagnostic command must be confirmed against frozen CLI help before execution.

`panel-create` uses `--discovery-history compact|full`, defaulting to compact. Compact mode skips detailed bookkeeping for ordinary successful discovery candidates; full mode is the detailed evidence oracle. Both modes retain final validation, complete-stage provenance and audit requirements.

For a saved completed bundle, replay exactly one saved object per invocation:

```sh
primalscheme3 panel-discovery-diagnose --bundle BUNDLE --family-id FAMILY_ID --output FAMILY_DIAG
primalscheme3 panel-discovery-diagnose --bundle BUNDLE --site-id SITE_ID --output SITE_DIAG
```

`panel-history` remains a bounded query over saved history. It does not regenerate discovery. `panel-audit` reparses original inputs and freshly validates stored stages. `panel-cache` exports only a completed successful bundle with closed history and stable provenance; `--reuse-discovery CACHE` must verify cache/source/detail-policy identity before reuse.

The A1 engineering harness is [selective-history-a1-harness.py](./selective-history-a1-harness.py). It is configured for exactly one original raw A1 input (C64AA855-086A-4BBB-8AB7-803F0FAC0212), one start, zero repair rounds, 5-second optimizer bound, salvage off, 600-second process cap and 2 GiB output growth cap. It is preparation-only until parent review and source freeze.

Before any CLI A1 arm, compare compact/full through the anchored API using identical input, indexes, settings and a fixed work unit. Compare scientific candidate/site/family projections and fixed-work selector results; compare evidence counts, SQLite size and timing separately. Cross-mode catalog/ledger digests differ by design. Same-mode scientific digests should be deterministic; runtime, wall-time and receipt fields are volatile.

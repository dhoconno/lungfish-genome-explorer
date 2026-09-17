# Frozen matrix10 / LGE search-effort smoke

Date: 2026-09-15 America/Chicago (receipts use UTC 2026-09-16)
Status: passed
Scope: one fresh 500-byte synthetic design through the LGE CLI and frozen native matrix10, followed by saved-bundle inspect, history and fresh audit. A separate matrix09 invocation tested the unsupported explicit-effort failure path before native design. No MHC design, cache reuse, native edit, GUI change, or managed-runtime change occurred.

## Outcome

The real wrapper/native path preserved the effort and explicit override mask:

| Field | Requested | Resolved |
|---|---:|---:|
| `search_effort` | `quality-v1` | `quality-v1` |
| `optimizer_time_limit` | 5 seconds | 5 seconds |
| `optimizer_starts` | 4 | 4 |
| `optimizer_repair_rounds` | omitted | 3 |
| `work_construction_candidate_attempts` | omitted | 8192 |
| `work_families_per_refresh` | 16 | 16 |

The native requested-options record and executed native argv include the effort, time, starts and families overrides. They omit repair rounds and construction attempts, proving those two values came from `quality-v1`. Resolved config, encoded allele options and optimizer options are identical. Scientific profiles contain no effort field; scheduling remains `serial`, salvage remains `off`, and intended/secondary policies remain their exact defaults.

Design, inspect, history and audit all exited zero. The history query is valid. The fresh audit is valid and reparsed stored raw inputs. The old matrix09 executable lacks `alleleCoverage.searchEfforts`; an explicit quality request exited one in 0.65 seconds before native design and retained the probe/runtime/input evidence plus `failure-provenance.json`. The requested success destination was not created.

This tiny result selected one amplicon and has 0.7783 modeled coverage for one observed class. It is a bridge/provenance test, not a quality or biological result.

## Identities and retained artifacts

- LGE source head used to build the binary: `3f5bcc8caa5c6df7b28aed750c1870770f76bf2e`
- LGE binary: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli/.build/debug/lungfish-cli`
- LGE binary SHA-256: `7c3b104029d1fcd191db6a8b05f2131bcfdd7b336d9704c0d05ad20a254fd2d5`
- LGE binary size: `183199376` bytes
- Frozen matrix10 commit: `158a4a3a10156efdfcb98eb19ae0f2c5f7841358`
- Matrix10 executable: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix10/.venv/bin/primalscheme3`
- Matrix10 entry-point SHA-256: `0483160c1c8221da1db9079ae6ff02557970eb3b7666dc2c877bd39042ed00ec`
- Matrix10 source digest: `6dfbdc1cd3390c3bc0ee0f240949050b1059c077cf3f8a0fc5d06c28e1573a1c`
- Matrix09 commit: `01cafef1415dba90b7b1b50e4ac391a1a1d8d50d`
- Input: `/private/tmp/lge4-task10-small-source.fasta`, 500 bytes, SHA-256 `9194587e219bedb585e19b7ed518324affef946f8643392fb0059e5620bab311`
- Retained root: `/private/tmp/lge-matrix10-effort-smoke-01`
- Bundle: `design.lungfishprimeranalysis`
- Result ID: `71EEBFCD-2598-4361-A88B-2FB3A439F9BC`
- History: `history-query`
- Audit: `audit`
- Matrix09 failure: `matrix09-rejected.lungfishprimeranalysis.failure`
- Exact outer argv/status/stdout/stderr: `execution`
- Assertion program: `verify_smoke.py`
- Verification record: `verification.json`, SHA-256 `53649dd7e25be61ff5e17818bc201653697eccbdc798264fd6d45b3f8ec6e37c`

The verifier covered 84 retained regular files totaling 36,522,958 bytes across the bundle, follow-up outputs, failure artifact and outer command evidence. Both native worktrees remained clean and the original input hash was unchanged.

## Exact commands and status

All commands used working directory `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-cli`.

```sh
.build/debug/lungfish-cli primers design primalscheme3 \
  --msa /private/tmp/lge4-task10-small-source.fasta \
  --output /private/tmp/lge-matrix10-effort-smoke-01/design.lungfishprimeranalysis \
  --grouping combined \
  --primalscheme3-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix10/.venv/bin/primalscheme3 \
  --selection-algorithm allele-coverage --search-effort quality-v1 \
  --amplicon-size 180 --amplicon-size-min 150 --amplicon-size-max 220 \
  --pool-count 2 --core-count 1 --candidate-profiles normal \
  --max-amplicons 1 --max-amplicons-per-msa 1 \
  --optimizer-starts 4 --optimizer-time-limit 5 \
  --mispriming-product-size 1000 \
  --work-frontier-candidates 1 \
  --work-repair-candidate-probes-per-round 1 \
  --work-repair-neighborhoods-per-round 1 --work-repair-trials-per-round 1 \
  --work-pool-lookahead-candidates 1 --work-cleanup-moves-per-round 1 \
  --work-families-per-refresh 16
```

- Exit 0; outer wall time 12.8412 seconds; stderr empty.

```sh
.build/debug/lungfish-cli primers analysis inspect \
  /private/tmp/lge-matrix10-effort-smoke-01/design.lungfishprimeranalysis --json

.build/debug/lungfish-cli primers analysis history \
  /private/tmp/lge-matrix10-effort-smoke-01/design.lungfishprimeranalysis \
  --result-id 71EEBFCD-2598-4361-A88B-2FB3A439F9BC \
  --primalscheme3-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix10/.venv/bin/primalscheme3 \
  --output /private/tmp/lge-matrix10-effort-smoke-01/history-query \
  --stage strict --limit 5

.build/debug/lungfish-cli primers analysis audit \
  /private/tmp/lge-matrix10-effort-smoke-01/design.lungfishprimeranalysis \
  --result-id 71EEBFCD-2598-4361-A88B-2FB3A439F9BC \
  --primalscheme3-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix10/.venv/bin/primalscheme3 \
  --output /private/tmp/lge-matrix10-effort-smoke-01/audit
```

- Inspect: exit 0, 0.0989 seconds; stdout exactly equals saved manifest.
- History: exit 0, 1.4227 seconds; query valid.
- Audit: exit 0, 2.7466 seconds; validation valid and raw inputs reparsed.
- All stderr streams empty.

The exact matrix09 rejection argv is retained in `execution/matrix09-reject.json` and the wrapper failure receipt. It differs from the success request by using the matrix09 executable and omitting the small search controls after `--core-count 1`; this is sufficient because rejection occurs at the capability gate before design.

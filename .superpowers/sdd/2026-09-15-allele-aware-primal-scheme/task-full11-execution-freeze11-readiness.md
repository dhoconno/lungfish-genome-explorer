# Full11 execution freeze11 readiness

Date: 2026-09-16 America/Chicago
Status: identity and commands frozen; execution remains gated on completion of the live cold panel and sequential audit/cache gates
Scope: preparation only. No scientific command was launched and no file inside the live `mhc-union-subsets-02` output was read.

## Frozen artifact

Read-only directory:

`/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/full11-execution-freeze11-01`

Primary records:

- `identity-manifest.json` — matrix/native/runtime identities, all eleven ordered input descriptors, all eleven protected source comparisons, option/capability checks, and prior evidence notes
- `commands.json` — the exact three ordered argv arrays, shell renderings, preconditions, required outcomes, and the expected expanded native `panel-create` argv
- `commands.txt` — review rendering of the same three commands; it is not a batch script
- `options/01-primary-narrow-hour.json` — immutable narrow option copy used by the frozen argv
- `input-order.json` — immutable ordered input copy
- `command-evidence/` — exact capabilities at start/end, version, native subcommand help, runner help, stdout/stderr, status, argv, working directory, and timings
- `preparation-provenance.json` — successful preparation receipt with exact invocation, runtime, input/output descriptors, status, wall time, and no-science/no-cold-read declarations
- `preparation-script.py` — exact preparation source

Key artifact hashes:

| File | SHA-256 | Bytes |
|---|---|---:|
| `identity-manifest.json` | `67a07a53692dc4c65496bd9f14e6c722cb83dd79d9cacc538bdfac7fc0036862` | 37,834 |
| `commands.json` | `5ac577c3f13b1462a2b0ebf095455c0c34527e41c741eb9cb920bc5a6eeebc61` | 14,454 |
| `commands.txt` | `973f8b6b758322c878b07670342fb2c392fcdd5bf90524a1bf2a789672812c2d` | 3,819 |
| frozen narrow options | `2dd7ef50b0aa36a977914bb943a5cec97eb4ac9bf2ead9cf61d8759a64278c10` | 935 |
| frozen input order | `42e535f1689a9f3b2455dd3fd03070a292a178d74f9b38151cd9a6dd23e4a5f8` | 3,108 |
| `preparation-provenance.json` | `789f9b9b3b54b405134037e254d7e26a9c1993dc7802e5e60940f417981dc639` | 26,606 |
| `preparation-script.py` | `10c1f79e90bc7428b89ae31622f328b3a8a3fd69e5f86f6525578b829ca28da8` | 22,705 |

The successful preparation receipt reports `status: success`, exit `0`, `sourceRuntimeStable: true`, `coldOutputRead: false`, and `scientificCommandsLaunched: false`. All freeze files are mode `0444` and directories are mode `0555`.

## Exact identities

### Matrix11

- Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11`
- Commit: `236e74af6b186367fd66f15e73b558a0c3e44a74`
- Tracked status: clean
- Tool version: `3.3.0+lge.4`
- Capability source digest: `326e51fc62de3e206447668a7f19dcf9b0c3c3fbdcd02cadd88cb86dd28d8e80`
- Native entry point SHA-256: `1918d1f4e47d178060af3c7f6785e6a544ec8a4792172fe76205b924e17657a1`
- Benchmark helper SHA-256: `115144f123ec179dc62f69d25b1286ed4845bd5bec116d39739d83f016959a19`
- Lexical venv Python: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix11/.venv/bin/python`
- Resolved Python: `/Users/dho/miniforge3/bin/python3.12`
- Python version: `3.12.8`
- Python binary SHA-256: `1926db65c8612964874d0525121980d5342c96a904b60606d90680d153d3bdfb`
- Native kernels: `primalschemers 0.1.13` shared object SHA-256 `0011f6f6e15d57d5991d1840ae494383171a2f2ae03dc4b5e237d306fa672676`; `primer3-py 2.2.0` shared object SHA-256 `c74c2f68e318081abecf1a07e1cb8f6601f291fc3ef5ce582199f50ebc9c0461`

Exact capabilities were captured twice around preparation. Both invocations exited `0`, had empty stderr, and produced the same 12,816-byte SHA-256 `80d558179bb0a70d422d016b76ab7b478be1d4e34fd66e15362c4579b8bec0c2`.

### Reviewed wrapper

- Path: `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/run_cached_allele_control_v5.py`
- SHA-256: `e3bd97df791bbc0eb8f4a3b103a4ee08c9a7488b7d6b1ad9cc38bf1e8103bcd1`
- Size: 9,952 bytes

The primary argv intentionally uses the lexical matrix11 venv Python so imports and site paths remain bound to the frozen environment.

### Cold source compatibility

- Live cold source worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-benchmark-01`
- Commit: `7ca64e68690f6e4db5b91f54bfe8a4847c402a62`
- Tracked status: clean

Every file declared by matrix11 `_DISCOVERY_FILES` is byte-identical to the corresponding `7ca64e6` file. The manifest records both descriptors for all eleven:

1. `primalscheme3/core/config.py`
2. `primalscheme3/core/digestion.py`
3. `primalscheme3/core/variant_thermo.py`
4. `primalscheme3/core/thermo.py`
5. `primalscheme3/core/seq_functions.py`
6. `primalscheme3/core/parallel_discovery.py`
7. `primalscheme3/core/msa.py`
8. `primalscheme3/core/mapping.py`
9. `primalscheme3/panel/coverage_discovery.py`
10. `primalscheme3/panel/allele_coverage.py`
11. `primalscheme3/panel/coverage_types.py`

Each matrix11 descriptor also exactly matches the corresponding descriptor in the captured capability source identity. This is the required source compatibility evidence; reuse must still fail closed if the completed cache receipt or runtime identity disagrees.

## Inputs and options

The exact eleven MSA paths remain in the plan's source order: KIR2DL04, KIR3DL10, KIR3DS, Mamu-A1, Mamu-A2, Mamu-A4, Mamu-B, Mamu-DPA, Mamu-DQB, Mamu-DRB, and Mamu-E. `identity-manifest.json` records each path, label, SHA-256, and size. Their total is 311,367 bytes. Preparation hashed them before and after and found no change.

The original plan files remain untouched:

- `PLAN.md`: `f321d1e8a15c5c61538614338f418266cf0b136393aad9edd113a989d55920a9`
- `commands.json`: `6dba7ac253a59c2d30304dc508a132aef2487d9618b0379286e5e5b3fda80b09`
- `01-primary-narrow-hour.json`: `2dd7ef50b0aa36a977914bb943a5cec97eb4ac9bf2ead9cf61d8759a64278c10`
- `input-order.json`: `42e535f1689a9f3b2455dd3fd03070a292a178d74f9b38151cd9a6dd23e4a5f8`

All 26 option-file fields were expanded with the same sorted `--name value` mapping used by the reviewed v5 runner. Every resulting flag appears in current `panel-create --help` and occurs exactly once with the requested value in the frozen expected native argv. The current capability descriptors exactly advertise:

- `search_effort=standard-v1`, with defaults 120 seconds, 4 starts, 2 repairs, 2,048 construction attempts, and 16 families per refresh;
- explicit `optimizer_time_limit=3600`, which overrides only the inherited time;
- serial phase scheduling (`serial/v1`);
- intended policy `concrete-designated-sites/v1`, coverage credit 0;
- secondary policy `ordered-disjoint-concrete-designated-sites/v1`, coverage credit 0.

The option file explicitly retains the old-default-equal values for starts, repairs, construction attempts, and families. Native argv/provenance can therefore distinguish those user requests from effort inheritance. No policy, chemistry, salvage, scheduling, or work field is silently ignored.

## Exact ordered commands

`commands.json` freezes these commands in order:

1. `gate-audit-cold`: matrix11 `panel-audit --bundle mhc-union-subsets-02 --output mhc-union-subsets-02-audit-matrix11-01`
2. `gate-export-cache`: matrix11 `panel-cache --bundle mhc-union-subsets-02 --output mhc-union-discovery-cache-01`
3. `01-primary-narrow-hour`: the reviewed v5 runner, matrix11 native executable, immutable option copy, exact eleven ordered MSAs, exported cache, and fresh `full11-matrix11-01-primary-narrow-hour-01` output

The first command remains blocked until the cold writer exits successfully, its receipt is complete and stable, and its SQLite writer is closed. The second requires the fresh audit to be valid with raw inputs reparsed and byte-bound. The third requires successful portable cache export and every frozen identity to remain unchanged. The v5 runner will emit the actual expanded native argv, audit the successful panel, and compare requested controls to resolved native options.

## Prior evidence retained in the decision

- `historical-input-equivalence-01` completed successfully in 1.067 seconds: all 14 common-metric receipts and 112 distinct input/output files were hash-verified; all eleven independent FASTAs byte-identically matched the canonical eleven despite differing occurrence UUIDs; combined upstream/LGE3 controls used the same eleven bytes/order. No duplicate common-metric rescore is needed solely for biological input equivalence.
- `mamu-a1-cached-narrow09-3600-01` completed and freshly audited at 89.50267498% mean coverage, 19 amplicons, and 85.3718–93.2765% class coverage. Relative to the matched broad-hour control, only four work caps differed; narrow gained 2.221503 percentage points in mean and 2.29011 points in minimum class coverage, with four classes gaining and two losing. That makes the explicit narrow hour settings a justified first full11 arm. It does not retune `standard-v1`, establish a full11 result, or support a runtime forecast.

## Preparation failure retained

The first preparation attempt is preserved read-only at:

`/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/full11-execution-freeze11-01-preparation-attempt-01-failed`

Its receipt SHA-256 is `db7b3bfccfdce3aecc45c633ae0ff6b3ae90c49d92a478b5fbcbc4b7395523ed`. It failed before manifest creation because the default 80-column Typer rendering abbreviated long option names, making the literal help validation conservatively reject them. The successful preparation captured help at 240 columns and verified the complete flag names. Neither attempt launched science or read the cold output.

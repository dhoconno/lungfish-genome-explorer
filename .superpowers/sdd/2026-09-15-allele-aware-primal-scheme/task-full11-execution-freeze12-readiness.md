# Full11 matrix12 execution freeze readiness

Date: 2026-09-16 America/Chicago  
Status: frozen preparation passed; native full-suite gate passed; cold completion, fresh audit and portable cache export remain sequential gates.  
Scope: source/runtime and three-command identity preparation only. No scientific design, cold-output/database read, native audit, or cache export was launched.

## Frozen source and environment

- Detached matrix12 worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix12`
- Git commit: `74102b8effef79f98487b4962c65b112454425d3`, clean tracked status
- Environment setup: `uv sync --frozen --python /Users/dho/miniforge3/bin/python3.12` in that worktree; 69 packages installed from committed `uv.lock` without updating the lock
- Lexical interpreter: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix12/.venv/bin/python`
- Resolved interpreter: `/Users/dho/miniforge3/bin/python3.12`, CPython `3.12.8`; SHA-256 `1926db65c8612964874d0525121980d5342c96a904b60606d90680d153d3bdfb`
- Native CLI entry point: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/allele-aware-primal-matrix12/.venv/bin/primalscheme3`; SHA-256 `a8e6d51d22b6df7332228609d260d145c8de585ff398d317c44a7c604d72307e`
- Native version: `3.3.0+lge.4`
- Source digest: `5f166bb87ad07018d8534ff795264698b0a00b3477e52e7ba3bd20284b9c3c18`
- Matrix12 `uv.lock` SHA-256: `ba5ccf24f7c588c7f3c746b72340804f7bc4ffd6be8a4ab5c00830dda984517b`
- Matrix12 `pyproject.toml` SHA-256: `ea21def46102c9b3598c9c3654a31538e2faf6bca726af03c80902e0746109cd`
- Native benchmark helper SHA-256: `115144f123ec179dc62f69d25b1286ed4845bd5bec116d39739d83f016959a19`
- Reviewed v5 control runner SHA-256: `e3bd97df791bbc0eb8f4a3b103a4ee08c9a7488b7d6b1ad9cc38bf1e8103bcd1`

The capability runtime records the matrix12 venv prefix, Python and platform identity, declared dependencies, and physical kernel files. Kernel SHA-256 values match the previous frozen environment: `primalschemers 0.1.13` shared object `0011f6f6e15d57d5991d1840ae494383171a2f2ae03dc4b5e237d306fa672676`; `primer3-py 2.2.0` shared object `c74c2f68e318081abecf1a07e1cb8f6601f291fc3ef5ce582199f50ebc9c0461`.

Root's same-commit full native suite completed with exit `0`: `876 passed, 1 upstream Kaleido deprecation warning in 181.11s`. Retained `/tmp/allele-native-suite-74102b8.log` SHA-256 `b419f4bfe64647600b61e399b7e76893c56cd0bf066de80721104eb2581096e8`, 1,547 bytes. The freeze manifest binds this log and records root's reported exit status. The suite was not repeated here.

## Read-only execution freeze

`/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/full11-execution-freeze12-01`

| Artifact | SHA-256 | Bytes |
|---|---|---:|
| `identity-manifest.json` | `4d3855c95f24bc6568c3459a73530f23c74d098d456a1f0b115de2e69a12d4d0` | 38,889 |
| `commands.json` | `4e9964a50d7b2dd942d02142fc1fe4a718e78cf2408b2bd00e47886a0667b78f` | 14,504 |
| `commands.txt` | `2a392fbb566da260ffb6d85b51d48ab6ac2bfe85a0cb1aa841bb2a504c61e640` | 3,819 |
| `preparation-provenance.json` | `2623677d785cca15439b3e64c329fae279e205fdb8731786c0363189ea9c495e` | 27,235 |
| `options/01-primary-narrow-hour.json` | `2dd7ef50b0aa36a977914bb943a5cec97eb4ac9bf2ead9cf61d8759a64278c10` | 935 |
| `input-order.json` | `42e535f1689a9f3b2455dd3fd03070a292a178d74f9b38151cd9a6dd23e4a5f8` | 3,108 |
| `preparation-script.py` | `c81f3f13ea5128ce69980636016a187e18faf48e5b1e61bc10bdbfe5ed82e920` | 23,604 |

Freeze files are mode `0444` and directories mode `0555`. The preparation receipt reports `status: success`, exit `0`, 27 hashed retained outputs, `sourceRuntimeStable: true`, `coldOutputRead: false`, and `scientificCommandsLaunched: false`. Exact preparation argv, working directory, Python/runtime, start/end time, wall time, input/output hashes and sizes, status, and stderr are retained.

Matrix12 `--capabilities-json` snapshots before and after preparation were byte-identical, both exit `0` with empty stderr: 12,816 bytes, SHA-256 `dc5f5f90afc515b3e7da7763b137be546a51ffbf3988a91303881e07137d550c`. Read-only version, panel-create/panel-audit/panel-cache help, and runner help also exited `0` with empty stderr; their exact command receipts and streams are in `command-evidence/`.

## Scientific and input equivalence to freeze11

The new matrix12 source digest differs from matrix11's `326e51fc62de3e206447668a7f19dcf9b0c3c3fbdcd02cadd88cb86dd28d8e80` because the reviewed checkpoint SQL source changed. All eleven discovery-fingerprint source files in matrix12 are byte-identical to frozen cold source `7ca64e68690f6e4db5b91f54bfe8a4847c402a62`, with each SHA-256/size also matching matrix12's capability descriptor. Matrix12 and cold worktrees both had clean tracked status during preparation. Thus the checkpoint query change does not alter the protected discovery dependency bytes; the later cache loader must still verify its own receipt/runtime compatibility.

All eleven original aligned FASTA paths, labels, order, SHA-256 values and sizes are recorded in the manifest and were stable across preparation. They are exactly equal to freeze11's eleven descriptors. The immutable copied input-order JSON is byte-identical to the original plan and freeze11. The copied narrow options are likewise byte-identical to the original plan and freeze11.

The same 26 explicit narrow option keys were checked against full-width matrix12 `panel-create --help`; each is advertised and is forwarded exactly once with its intended value in the frozen expected native argv. Capabilities advertise standard-v1 effort, serial scheduling, concrete-designated intended product policy and ordered-disjoint concrete-designated secondary policy with the expected versioned descriptors. The primary option file explicitly sets `optimizer_time_limit=3600`, `optimizer_starts=4`, `optimizer_repair_rounds=2`, construction attempts `2048`, and families per refresh `16`; these remain a narrow hour control and do not retune the standard preset or scientific chemistry.

An independent comparison normalized the matrix12 paths/names back to matrix11 and found the three argv arrays, expanded native `panel-create` argv, ordered inputs, and option values exactly equal. The only command-path differences are matrix12 Python/native paths, the frozen option-copy path, and the new matrix12 audit/hour output names. The common fresh future cache remains `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-union-discovery-cache-01`.

## Three execution gates

The exact arrays and shell commands are in `commands.json`; `commands.txt` is review text, not an executable batch script. Working directory for all three is `/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development`.

1. `gate-audit-cold`: matrix12 `panel-audit --bundle …/mhc-union-subsets-02 --output …/mhc-union-subsets-02-audit-matrix12-01`. Execute only after the cold writer exits successfully, source/runtime/output hashes are stable, and its history writer is closed. Require fresh `valid` audit with raw inputs reparsed and exact byte binding.
2. `gate-export-cache`: matrix12 `panel-cache --bundle …/mhc-union-subsets-02 --output …/mhc-union-discovery-cache-01`. Execute only after gate 1 passes; require a successful portable cache receipt/manifest and stable source/runtime. Check free space before copying large immutable evidence.
3. `01-primary-narrow-hour`: matrix12 venv Python invokes the reviewed v5 runner with matrix12 native, the read-only freeze12 option copy, the eleven original MSAs, the exported cache, and fresh output `…/full11-matrix12-01-primary-narrow-hour-01`. The v5 runner must verify requested versus native resolved options, true discovery reuse with zero current workers, successful native panel/audit, and unchanged input/source/runtime identities. A cache incompatibility is a failure, never a cold-discovery fallback.

At preparation time the three future output paths were absent. They must be checked again immediately before each command. Completion and audit of the live cold output remain outstanding; this freeze does not assert its success or forecast when it will finish.

## Prior comparison evidence and limits

The previously completed `historical-input-equivalence-01` verified all fourteen common-metric receipts and 112 distinct artifact hashes; each independent target FASTA byte-identically matched the canonical source, and combined upstream/LGE3 controls used the same eleven original bytes/order. The completed, freshly audited narrow09 A1 hour control reached 89.50267498% mean modeled coverage with 19 amplicons and 85.3718–93.2765% class coverage. Those records justify prioritizing the explicit narrow hour arm once the full11 cache is available. They do not imply whole-panel feasibility, an expected full11 score, or a runtime speedup from the v2 query substitution.

No matrix11 worktree, freeze11 artifact, original plan file, live cold source/output, or active biological dataset was edited. Frozen matrix11 and freeze11 hashes were rechecked unchanged. Independent review of `74102b8` is recorded in `task-v2-prefix-joins-review.md`.

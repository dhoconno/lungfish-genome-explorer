# PrimalScheme3-LGE scaling audit probe

Purpose: verify whether the FKmer hash used as the initial panel candidate tie order is stable across fresh Python processes, and record the native source identity inspected for interaction-kernel complexity.

No pathogen or user scientific input was used. The only sequence is the synthetic 19-mer `ACGTACGTACGTACGTACG`. No production files were edited.

## Runtime identity

- PrimalScheme3-LGE: `3.3.0+lge.2`, source commit `00eaa252446f01cabfeae71e10306a68cdb941d6` (installed `primalscheme3/lge-build.json`)
- primalschemers: `0.1.13`
- Python: `3.12.11 | packaged by conda-forge | (main, Jun 4 2025, 14:38:53) [Clang 18.1.8]`
- Platform: `macOS-26.6.2-arm64-arm-64bit`
- Native module: `/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalschemers/primalschemers.cpython-312-darwin.so`
- Native module SHA-256: `0011f6f6e15d57d5991d1840ae494383171a2f2ae03dc4b5e237d306fa672676`
- Native module size: `1300272` bytes

## Exact probe command

```sh
for i in 1 2 3 4 5; do /Users/dho/.lungfish/conda/envs/primalscheme3/bin/python /private/tmp/primalscheme3-nativehash-probe.py; done
```

Output (exit status 0; wall time below timer resolution reported by the command harness):

```text
269248535
273882135
271549463
274215959
271417367
```

Conclusion: identical FKmer content receives different hashes in fresh processes. `panel_main.py` lines 374-378 sorts candidates by `x.fprimer.__hash__()` before stable dynamic sorts, so ties are process-dependent.

## Published native source inspected

- Source distribution: `primalschemers-0.1.13.tar.gz`, downloaded from the URL in the PyPI JSON metadata.
- Archive: `/private/tmp/primalschemers-0.1.13.tar.gz`
- Archive size: `45830` bytes
- Archive SHA-256: `c209805b0bd5f114cfe702f260ecc21fc24086ef5c4ac1688e1f81537d78661e` (matches PyPI metadata)
- Extracted tree: `/private/tmp/primalschemers-0.1.13-src/primalschemers-0.1.13`

The Python binding copies and reverses both oligo vectors on every `do_pool_interact` call, then iterates their Cartesian product at `src/lib.rs` lines 426-448. The core repeats the same structure at `src/primaldimer/mod.rs` lines 371-392. Each directed oligo comparison scans offsets at lines 335-347; scoring an accepted offset scans overlap bases at lines 254-314. No `Python::allow_threads` region wraps this binding.

# PCR primer pack expansion: native installation preflight

Date: 2026-09-24. Worktree: `.worktrees/primer-pack-olivar-varvamp`; baseline `b69e43dbd`.

## Result

Native Apple Silicon installation and coexistence passed for Primer3 2.6.1, PrimalScheme3-LGE 3.3.0+lge.5, Olivar 1.3.3 and varVAMP 1.3.2 in four separate environments under one disposable pack root. The current product pack registry is unchanged; this was a feasibility probe, not a completed product integration.

Raw relocation revealed real portability defects. Prefix-independent Python launchers plus an environment-local MAFFT helper path passed subsequent moves with prior install paths absent. These corrections must be implemented and verified through Lungfish's actual installer/offline pack paths before shipping.

## Tested versions

| Tool | Exact top-level package | Python / relevant dependency |
| --- | --- | --- |
| Primer3 | `bioconda::primer3=2.6.1=pl5321haef7865_7` | Native ARM executable |
| PrimalScheme3-LGE | Existing committed wheel/hash lock, version `3.3.0+lge.5` | Python 3.12.11; NumPy 2.5.3 |
| Olivar | `bioconda::olivar=1.3.3=pyhdfd78af_3` | Python 3.12.14; NumPy 1.26.4; MAFFT 7.526; BLAST 2.17.0 |
| varVAMP | `bioconda::varvamp=1.3.2=pyhdfd78af_0` | Python 3.13.15; NumPy 2.5.3; primer3-py 2.3.1; BLAST 2.17.0 |

The app-bundled micromamba 2.9.0 was used on native ARM64 macOS. Complete package URLs/builds/checksums are retained in the evidence locks. Separate environments prevent Olivar's NumPy <2 requirement from conflicting with the other tools. The two new uncompressed environments measured approximately 1.1 GB and 789 MB respectively; update the pack's storage estimate using the finalized production payloads.

## Checks and findings

- Help/version/import probes passed for all four tools before moving the root.
- Architecture inspection covered 1,276 Mach-O payloads, with zero Intel-only files; universal binaries containing ARM64 were accepted.
- Olivar's upstream launcher uses `env python3`. It must run with the selected environment on PATH or through its explicit Python executable; an unactivated invocation chose the wrong Python and failed.
- After an unmodified move, Primer3 and activated-path Olivar passed. varVAMP and PrimalScheme direct launch failed with exit 127 because their shebangs retained the old prefix. Both worked through the relocated Python interpreter.
- Disposable relative launchers calling the same-environment Python and preserved entrypoint scripts passed a further move for all four tools.
- MAFFT independently retained its original helper-binary path. Setting run-local `MAFFT_BINARIES` to the relocated environment's `libexec/mafft` fixed its version probe. Olivar's test launcher propagated that setting to child processes.
- A fourth-prefix check passed all six probes: Primer3, Olivar, varVAMP, PrimalScheme, MAFFT and BLAST. Original prefixes were absent.
- Cold matplotlib/font initialization can exceed short readiness timeouts. Allow a bounded cold-start timeout of at least 60 seconds or perform a recorded warm-up.

No primer designs or scientific input transformations were run in this installation-only preflight. User-managed environments and the original MHC project were untouched. The relative launchers are throwaway feasibility code, not product changes.

## Baseline and design

The isolated checkout passed 74 targeted baseline tests: 32 registry, 6 runtime preparation, 7 routing, 21 dialog-state, and 8 result-review tests. Test command:

```sh
swift test --build-system swiftbuild -j 4 --filter 'PluginPackRegistryTests|PrimerDesignRuntimePreparationTests|PrimerDesignDialogStateTests|PrimerDesignReviewTests|PrimerAnalysisRoutingTests'
```

Log: `.build/primer-expansion-validation/baseline.log` (exit 0). The [proposed design](../superpowers/specs/2026-09-24-primer-pack-olivar-varvamp-design.md) includes portability repairs, tool-specific size/frequency semantics, shared viewer and probe-aware results, provenance, and native MHC/UI acceptance testing.

Engine source inspection used Olivar tag `v1.3.3` at `73973900196d91c1b707ef2ad4cd08a3b94d77fb` and varVAMP tag `v.1.3.2` at `85d870b53288b637ab7749186c2c4284cab1bd2d`. Detailed source findings are in `.build/primer-engine-research/ENGINE-CONTRACTS.md`.

## Retained local evidence

`.build/primer-expansion-smoke/` contains the complete report, install/probe scripts, transcript, exact locks, architecture inventory, preserved launcher hashes, and raw/corrected relocation results. Root review verified all 61 entries in `evidence-sha256.txt` against their retained bytes. The checksum manifest SHA-256 is `4eefb723ee4bb6e02eade46582c59942b4460aaa307e5240aa64f023a7f2e029`.

Implementation is not yet complete: the actual registry/installer, shared GUI, engine adapters, scientific output normalization and MHC end-to-end tests remain to be implemented and verified. No release was created.

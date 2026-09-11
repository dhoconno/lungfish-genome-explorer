# PrimalScheme3-LGE custom fork

LGE uses **PrimalScheme3-LGE (custom fork)**, version `3.3.0+lge.1`, from the public [dhoconno/primalscheme3-lge repository](https://github.com/dhoconno/primalscheme3-lge). It is based on upstream PrimalScheme3 v3.3.0, commit `dd13ec5cb1cf375f052640355c73101c0c4bf839`. It retains upstream attribution and the GPL license. This is a separately maintained fork, not an upstream release or an upstream endorsement of LGE's changes.

## Behavior and limitations

The fork adds `--terminal-gap-policy legacy|observed-only` to independent scheme and combined panel creation. Its standalone default is legacy; LGE explicitly selects observed-only by default and exposes a checkbox to select legacy instead.

Observed-only applies the earlier terminal-gap patch through the existing Python discovery path. Leading and trailing alignment padding represent unavailable observations at candidate sites. Available internal sequence observations remain in the analysis; genuine internal gaps are not reclassified as missing ends. This is not whole-record filtering or a claim that all input alleles are covered.

Upstream's actual CLI uses Rust-backed discovery, which the Python patch alone would not change. The fork therefore records both `terminal_gap_policy` and `discovery_backend` in native configuration. Legacy retains `rust-legacy`; observed-only uses `python-observed-only`. The custom Python discovery path supports a bounded worker count selected through LGE’s CPU control. LGE defaults to up to four workers, capped by the machine’s active processor count. Selected and effective worker counts are retained in native configuration. Performance and results may differ for reasons beyond the denominator. Downstream scheme/panel construction remains shared. LGE verifies the reported policy and backend before publishing an analysis.

The validation scope is human/macaque MHC and synthetic software fixtures. Computational success does not establish assay performance or biological full-gene boundaries.

## Installation, provenance and distribution

The optional PCR Primer Design pack installs an exact release wheel inside a managed conda environment. Its dependency requirements and wheel have SHA-256 pins. Runtime receipts retain fork and upstream source revisions, release-asset URL, downloaded and installed file inventories, exact installation commands, runtime identity and probe results. Source code and packaged release artifacts are available on GitHub for other users; installing LGE is not required to obtain the fork.

LGE identifies the custom fork in the Plugin Manager, About acknowledgements, design interface, CLI help, execution provenance and result engine label. Stable internal IDs and the `primalscheme3` executable name are retained for compatibility; they do not imply the upstream distribution is being used. Historical stock result bundles remain readable with their original engine identities.

A custom executable must report the supported fork identity. It is recorded as an override rather than falsely claiming to be the managed pinned installation. Every newly saved analysis retains native configuration, exact argv, tool identity and complete payload checksums.

Updates require review against upstream, renewed regression/native MHC validation, a distinct fork release, and new artifact hashes. LGE never installs a moving branch or silently substitutes upstream binaries.

## Pinned release and validation

The public [v3.3.0-lge.1 release](https://github.com/dhoconno/primalscheme3-lge/releases/tag/v3.3.0-lge.1) contains the wheel, source archive, checksums and build evidence. Its source commit is `a5cb62bb831f926701b2ca6eb5fe3d3624fccc0b`. The wheel `primalscheme3-3.3.0+lge.1-py3-none-any.whl` has SHA-256 `62841f9bf3a64e788a7162f333b9c8715667b39c1d422d560632b1f5e80cb55d`. Two clean builds produced the same wheel hash; all four release assets were independently downloaded without GitHub authentication and verified against the local publication artifacts.

Validation on September 11, 2026 included 24 fork Python tests, 19 native runs with human/macaque MHC inputs, and two LGE CLI runs with the final installed wheel followed by integrity reopening. Multiprocessing tests cover stable scientific results across worker counts, worker failure and cancellation cleanup. The focused managed-runtime, registry and acknowledgements suite passed 90 tests with one intentionally skipped opt-in live installation check; a separate opt-in production installation test subsequently passed in a fresh isolated conda environment. That receipt verified the public wheel checksum, exact custom version, both source revisions, all 30 installed Python distributions, version/help probes and successful installation commands.

For one small human MHC-A input, a single measurement took 5.57 seconds with one worker and 5.10 seconds with four workers. Scientific BED fields and ordering agreed across those runs; generated names and UUIDs differed. This is a modest result on a small input, not a general speedup guarantee. Process startup and downstream serial work limit scaling. The legacy fork path also reproduced the scientific BED fields of the prior stock run on that fixture.

Final LGE integration checks also passed for the design interface, CLI option parsing, native configuration validation, bundle publication and viewer loading of the retained final-wheel MHC outputs. Scientific provenance policy checks passed alongside the release-gate and Debug-artifact script checks. Evidence logs are retained in the isolated worktree under `.build/`; scientific fixture payloads are not included in the public fork.

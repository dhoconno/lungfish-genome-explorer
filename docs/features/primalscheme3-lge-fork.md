# PrimalScheme3-LGE custom fork

LGE uses **PrimalScheme3-LGE (custom fork)**. The current managed runtime is version `3.3.0+lge.5`, from the public [dhoconno/primalscheme3-lge repository](https://github.com/dhoconno/primalscheme3-lge), source commit `858a341ab7435fa54a9f1c0b1f10e525f8b3ef2a`. Its wheel `primalscheme3-3.3.0+lge.5-py3-none-any.whl` has SHA-256 `ab8453c4a4b19cbd96794b1e4997fad4538f714eacdea77528c46df59f7b4066`. Historical lge.2 validation and release details remain documented below. The fork retains upstream attribution and the GPL license. This is a separately maintained fork, not an upstream release or an upstream endorsement of LGE's changes.

## Behavior and limitations

The fork adds `--terminal-gap-policy legacy|observed-only` to independent scheme and combined panel creation. Its standalone default is legacy; LGE explicitly selects observed-only by default and exposes a checkbox to select legacy instead.

Observed-only applies the earlier terminal-gap patch through the existing Python discovery path. Leading and trailing alignment padding represent unavailable observations at candidate sites. Available internal sequence observations remain in the analysis; genuine internal gaps are not reclassified as missing ends. This is not whole-record filtering or a claim that all input alleles are covered.

Upstream's actual CLI uses Rust-backed discovery, which the Python patch alone would not change. The fork therefore records both `terminal_gap_policy` and `discovery_backend` in native configuration. Legacy retains `rust-legacy`; observed-only uses `python-observed-only`. The custom Python discovery path supports a bounded worker count selected through LGE’s CPU control. LGE defaults to up to four workers, capped by the machine’s active processor count. Selected and effective worker counts are retained in native configuration. Performance and results may differ for reasons beyond the denominator. Downstream scheme/panel construction remains shared. LGE verifies the reported policy and backend before publishing an analysis.

The validation scope is human/macaque MHC and synthetic software fixtures. Computational success does not establish assay performance or biological full-gene boundaries.

## Coverage panel selection

The CLI can opt into the lge.3 bounded coverage selector with `--selection-algorithm coverage`. Coverage is limited to combined whole-MSA equal panels with first-row mapping, supplied-MSA specificity, and at least one explicit amplicon bound. If one bound is omitted, LGE resolves it from the nominal target and forwards both bounds. The selector also accepts `--coverage-metric`, `--coverage-target`, `--optimizer-seed`, `--optimizer-starts`, `--optimizer-repair-rounds`, `--optimizer-time-limit`, and `--mispriming-product-size`.

Coverage currently requires an explicit local executable through `--primalscheme3-path`. LGE probes it once with `--capabilities-json` and requires the exact `3.3.0+lge.3` source, runtime, schema, profile, and supported-scope contract before scientific execution. The managed installation is lge.5, and legacy invocations preserve their existing arguments. The lge.3 coverage contract remains explicit: coverage execution requires a verified compatible executable reporting the exact lge.3 source, runtime, schema, profile, and supported-scope contract. A verified explicit lge.3 executable may also run the legacy selector without coverage flags.

Before publication, LGE checks the resolved native configuration, compressed candidate catalogue and hashes, optimizer metadata, independent validation, selected candidate and target mappings, BED coordinates and pool numbering, durable input copies, all native output hashes, and source/runtime identity from probe through completion. Coverage below the requested objective and valid empty panels remain publishable when the independent validator reports success. Native validation completes before the existing atomic bundle writer runs, so rejected output cannot appear at the requested destination.

The September 2026 implementation decisions, full nine-locus benchmark, exact coverage metrics, resource measurements, limitations, provenance audit and retained review record are in the [coverage panel optimizer delivery report](../reports/2026-09-13-coverage-panel-optimizer/report.md).

## Installation, provenance and distribution

The optional PCR Primer Design pack installs an exact release wheel inside a managed conda environment. Its dependency requirements and wheel have SHA-256 pins. Runtime receipts retain fork and upstream source revisions, release-asset URL, downloaded and installed file inventories, exact installation commands, runtime identity and probe results. Source code and packaged release artifacts are available on GitHub for other users; installing LGE is not required to obtain the fork.

LGE identifies the custom fork in the Plugin Manager, About acknowledgements, design interface, CLI help, execution provenance and result engine label. Stable internal IDs and the `primalscheme3` executable name are retained for compatibility; they do not imply the upstream distribution is being used. Historical stock result bundles remain readable with their original engine identities.

A custom executable must report the supported fork identity. It is recorded as an override rather than falsely claiming to be the managed pinned installation. Every newly saved analysis retains native configuration, exact argv, tool identity and complete payload checksums.

Updates require review against upstream, renewed regression/native MHC validation, a distinct fork release, and new artifact hashes. LGE never installs a moving branch or silently substitutes upstream binaries.

## Pinned release and validation

The public [v3.3.0-lge.2 release](https://github.com/dhoconno/primalscheme3-lge/releases/tag/v3.3.0-lge.2) contains the wheel, source archive, checksums and build evidence. Its source commit is `00eaa252446f01cabfeae71e10306a68cdb941d6`. The wheel `primalscheme3-3.3.0+lge.2-py3-none-any.whl` has SHA-256 `98eeac686148aa9f14de2584f80ef845f9474969c5421890c1210aef13afe54c`. Two clean builds produced identical wheel and build-evidence bytes. All four public assets were downloaded without GitHub authentication and matched the local publication artifacts.

Version lge.2 adds optional `--amplicon-size-min` and `--amplicon-size-max` flags. Supplying either selects the persisted `reference-span` metric, which bounds the saved full amplicon BED envelope (`end - start`), including primer sites. An omitted individual bound resolves from the nominal target's previous 90%/110% default. Explicit bounds require `minimum <= target <= maximum`. Alternative oligos and aligned alleles may have different individual product sizes; the nominal target does not prioritize the closest size.

The new metric supports fresh linear scheme and whole-MSA equal/entropy panel creation with first-row mapping. Unsupported circular, region, imported-pair and replacement workflows fail before output creation. Flagless invocations and older configurations retain `legacy-pairing` semantics. The panel bug that passed the maximum as both pairing bounds is corrected in both metrics. LGE verifies the saved metric, target, resolved bounds and every reference-span amplicon before publication.

The release also defers startup termination until the multiprocessing pool is owned, then terminates and joins its workers. The complete 33-test synthetic fork suite passed; focused cancellation checks included 60 repeated startup-signal cases. The LGE UI, binding renderer, CLI and publication suite passed 75 checks, including rejection of mismatched native size settings.

Four LGE CLI runs using the final wheel and four workers passed on authentic MHC alignments:

| Input | Grouping | Requested range (bp) | Amplicons | Saved spans (bp) |
| --- | --- | --- | ---: | --- |
| Human A | Independent | 150–250 | 19 | 201–250 |
| Human DPA1 + DPB1 | Combined | 150–250 | 120 | 156–250 |
| Macaque DQA1 + DQB1 | Combined | 150–250 | 68 | 187–250 |
| Human A | Independent | 180–220 | 20 | 182–220 |

Each used a nominal target of 200 bp. All 227 saved spans met their requested bounds. The primer-analysis CLI reopened every bundle; an independent audit verified 318 payload/provenance descriptors, including stored file hashes, sizes, final paths, exact arguments and sizing settings. These runs measure software behavior, not laboratory performance or a guarantee that wider bounds improve design quality.

The managed-runtime, registry and acknowledgements suite passed 46 checks, including a production installer run in a fresh isolated conda environment. It installed the public release wheel, verified both source identities and all 30 Python distributions, and recorded successful version/help probes and installation commands. A fifth MHC class I CLI run used that managed installation without an executable override, retained its complete runtime receipt, and produced 19 amplicons with verified 201–250 bp spans and payload checksums. An existing lge.1 runtime is flagged for repair rather than silently accepted by the new adapter.

## Earlier validation

Validation of lge.1 on September 11, 2026 included 24 fork Python tests, 19 native runs with human/macaque MHC inputs, and two LGE CLI runs with the final installed wheel followed by integrity reopening. Multiprocessing tests cover stable scientific results across worker counts, worker failure and cancellation cleanup. The focused managed-runtime, registry and acknowledgements suite passed 90 tests with one intentionally skipped opt-in live installation check; a separate opt-in production installation test subsequently passed in a fresh isolated conda environment. That receipt verified the public wheel checksum, exact custom version, both source revisions, all 30 installed Python distributions, version/help probes and successful installation commands.

For one small human MHC-A input, a single measurement took 5.57 seconds with one worker and 5.10 seconds with four workers. Scientific BED fields and ordering agreed across those runs; generated names and UUIDs differed. This is a modest result on a small input, not a general speedup guarantee. Process startup and downstream serial work limit scaling. The legacy fork path also reproduced the scientific BED fields of the prior stock run on that fixture.

Final LGE integration checks also passed for the design interface, CLI option parsing, native configuration validation, bundle publication and viewer loading of the retained final-wheel MHC outputs. Scientific provenance policy checks passed alongside the release-gate and Debug-artifact script checks. Evidence logs are retained in the isolated worktree under `.build/`; scientific fixture payloads are not included in the public fork.

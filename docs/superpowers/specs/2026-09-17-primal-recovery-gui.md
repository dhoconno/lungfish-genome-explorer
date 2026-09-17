# PrimalScheme recovery controls in LGE

## Scope

Expose the validated native CLI recovery features in the existing PrimalScheme Advanced settings. Keep existing independent and combined legacy workflows and their defaults unchanged. Do not introduce the abandoned allele coverage optimizer into the GUI.

The user authorized GUI integration after CLI evaluation, with Astra oversight and Luna implementation and testing.

## Controls

- Opt-in bounded dimer salvage for a combined legacy panel, including threshold sequence, floor, interaction budgets, minimum added reference bases, and candidate evaluation limit. Describe interaction limits as heuristic search controls rather than experimentally established safety thresholds.
- Independent follow-up scheme from a selected parent native output directory or an unambiguous saved LGE analysis. State that follow-up pools are separate PCR reactions, not additions to the parent's pools.
- Optional bounded extra candidate generation for follow-up uncovered regions. Default limits: 2,000 anchors and 1,000 pair checks per MSA. Explain that larger limits need not improve coverage.
- Retain arbitrary positive pool counts where supported by the native mode.
- Mutually incompatible controls must be disabled or rejected before execution, with an actionable message.

## Runtime and data contracts

The managed runtime currently predates these options. Provide an explicit executable picker and verify the local runtime's feature contract before scientific execution. Do not publish a runtime release or silently send unsupported flags to the managed executable.

Parent reference identifiers and input sequence semantics must agree with the consumed MSAs. Existing GUI normalization and random per-run row identifiers cannot silently alter the relationship to a native parent. Match and preserve parent identities using verifiable input evidence; reject ambiguous or different inputs. Preserve the original parent unchanged.

Retain all native reports, parent snapshots, source-row mappings, and execution provenance in the final analysis bundle. Historical executed paths may remain in exact argv, but add mappings to final stored payloads. Record input and output hashes and sizes, tool/source/runtime identity, resolved settings, status, duration, and useful stderr for successful and failed execution.

## Validation

Luna implements workflow/CLI and UI in separate file ownership areas. Astra reviews scientific scope and evidence. Verify unchanged default arguments and backward decoding, option propagation and invalid combinations, parent identity and immutability, follow-up namespace, final report/provenance retention, and runtime rejection. Run focused Swift tests and an actual native-backed small workflow before claiming end-to-end support. Build the app and verify the expanded controls through available visual tests or direct inspection. No new large MHC search is required for this integration.

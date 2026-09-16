# LGE search-effort bridge report

## Scope

Implemented the optional LGE CLI and workflow bridge for native `search_effort` in the allele-aware selector only. No GUI, managed-runtime, native scientific kernel, policy, chemistry, discovery, scheduling, salvage, or default-quality behavior changed.

Frozen native interface: `standard-v1` or `quality-v1`, as implemented by native commit `158a4a3a10156efdfcb98eb19ae0f2c5f7841358`.

## Behavior

- `standard-v1` remains the implicit backward-compatible default: 120 selector seconds, 4 starts, 2 repair rounds, 2048 construction attempts, and 16 families per refresh.
- `quality-v1` supplies 3600 selector seconds, 8 starts, 3 repair rounds, 8192 construction attempts, and 32 families per refresh.
- Only these five values vary with effort. Phase scheduling remains serial unless separately requested, salvage remains off, and all scientific and specificity controls are unchanged.
- Explicit individual values win even when they equal the historical standard values. LGE now preserves absent versus explicit optimizer starts, repair rounds, and time limit instead of always forwarding `4/2/120`.
- Native argv contains `--search-effort` only when requested and contains only individual controls actually requested. Wrapper provenance records requested optimizer values separately from the final resolved values.
- Codable round trips preserve the effort, final resolved values, and explicit override mask. Historical saved values without effort resolve as `standard-v1`; current capabilities may inspect historical resolved options that omit the field.
- The output contract validates the exact advertised effort registry, selected/resolved effort and five numbers, native requested mask, optimizer/config option equality, design argv provenance, and existing native output/audit identities. Explicit effort fails when the executable does not advertise the frozen descriptor.

## TDD and verification

The initial focused pipeline test failed to compile because the effort type and requested override fields did not exist, establishing RED before implementation.

Focused verification completed during implementation:

- `PrimalScheme3DesignPipelineTests`: 28 tests passed before the final added historical-selector rejection assertion; a final combined rerun is recorded below.
- `PrimalScheme3AlleleContractTests`: 13 tests passed, including exact capability, explicit old-default overrides, historical missing-field compatibility, tampered descriptor, tampered effort, and unexpected requested override cases.
- Focused `PrimerDesignCommandTests/testPrimalSchemeParsesSearchEffortWithoutInventingIndividualOverrides`: passed.

Final fresh focused verification:

- `swift test --filter 'PrimalScheme3DesignPipelineTests|PrimerDesignCommandTests'`: 35 tests passed (28 workflow and 7 CLI), log `/tmp/lge-effort-final-focused1.log`.
- `swift test --filter PrimalScheme3AlleleContractTests`: 13 tests passed, log `/tmp/lge-effort-contract-suite.log`.

Together these runs cover 48 tests with no failures.

## Documentation

`docs/reports/2026-09-15-allele-aware-primal-scheme/cli-controls.md` now lists both immutable effort tables, precedence, provenance behavior, the shared selector-time interpretation, resource costs outside selector time, independent controls, and the explicit capability requirement. It also states that the older matrix07 example does not advertise this newer option.

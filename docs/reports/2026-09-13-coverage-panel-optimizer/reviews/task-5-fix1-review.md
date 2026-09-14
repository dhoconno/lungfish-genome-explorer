# Task 5 fix round 1 review

Reviewed LGE `641180f28..5a9cb1f44`, the final Task 5 brief, original four findings, fix report, actual changed Swift code, and regression mutations. Native reads/probes were limited to understanding one concrete cross-contract concern introduced by the fix.

## Verdicts

| Original finding | Disposition |
| --- | --- |
| 1. Unequal-length reference FASTA / duplicate identifiers | **ADDRESSED** |
| 2. Exact primer cloud members, footprints, strand and pool | **ADDRESSED** |
| 3. Nested boolean-versus-number JSON identity | **ADDRESSED** |
| 4. Complete target/support metadata and selected-interval metrics | **ADDRESSED for the original omissions**, but the new support comparison introduces the false rejection below |

- Scoped spec compliance: **FAIL pending the new support-semantics regression**.
- Code quality: **NEEDS FIXES** for that one issue.
- Important new fix-diff breakage: **one P2 false rejection**.

The independent reference reader accepts distinct locus lengths and rejects duplicate IDs before dictionary construction; the aligned-input loader remains unchanged. Exact expected BED rows now include names, role, actual sequence, anchor-derived footprint, strand and one-based pool. Recursive JSON comparison distinguishes booleans from numbers and uses `NSNumber.compare`, preserving integer precision above `2^53`. Target/selected-candidate key sets, summary fields, merged intervals, covered bases, fractions, counts, shortfalls and optimizer correspondence are now checked. The committed `target_met` comparison uses the native exact `activeFraction >= coverageTarget` condition, without threshold slack.

## [P2] Do not equate catalogue unknown rows with fresh-validator uncertainty diagnostics

Location: `Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:499–503`, especially the equality loop over all three `supportKeys`.

The newly added guard requires `unknown_rows` in fresh validation to equal the catalogue candidate's `unknown_rows`. Those fields have intentionally different native semantics:

- In `primalscheme3/panel/coverage_catalog.py:324`, unknown rows are added through `elif forward_unknown or reverse_unknown`, after the joint-support branch. A jointly supported row is therefore absent from the catalogue's unknown-row list.
- In `primalscheme3/panel/coverage_specificity.py:217`, the fresh checker adds unknown rows with a separate `if fu or ru`. It preserves uncertainty in another cloud member even when a concrete member establishes joint support on the same row. A fresh-validator row may correctly be both joint and unknown.

Merely allowing overlap in `validateCandidateSupport` does not fix this distinction: the subsequent equality loop still rejects the fresh diagnostic whenever that valid overlap occurs.

### Bounded executed reproducer

A deterministic native probe used the fork's `.venv/bin/python`, existing synthetic-MSA test helper, real `FKmer`/`RKmer` objects, `build_catalog`, `CompatibilityOracle` and `validate_assignments`. No scientific artifact was written, no fixture was overwritten, and no chemistry was mocked or weakened.

Use `random.Random(12345)` to generate eight consecutive 240-base A/C/G/T strings; retain the eighth (trial 7). The second alignment row is the same string with its first base replaced by `N`. The forward cloud contains `sequence[:24]` and `sequence[1:24]`, both anchored at24; the reverse cloud contains `reverse_complement(sequence[176:200])`, anchored at176. The observed concrete primers are:

```text
forward: AGGCATGCTCTTAAGGCAGATGT
forward: GAGGCATGCTCTTAAGGCAGATGT
reverse: CTCAGCTGTCCCATCGCACATTAT
```

The request uses nominal200/min150/max280, reference-span, default native chemistry, and positive `mismatch_product_size=199`. The longer unknown-footprint product spans200 and lies outside this declared bound; the fully observed shorter product spans199 and has its intended exemption. Both rows retain confirmed joint support. This is a valid supported option combination; no new minimum product-distance threshold may be invented to reject it.

Actual results:

```text
D=199 intrinsic_valid: True
independent_validation_valid: True
catalog_unknown: ()
validator_unknown: ['row-04bd73dc8d5f592889dab5f19f9461835f79ce9f7ad0435bcf9d460cf3292278']
```

The joint rows are identical in catalogue and validator. The row-product spans also agree: row0 `[0,200)` and `[1,200)`; row1 `[1,200)`. The only difference is the additional valid fresh uncertainty diagnostic on joint row1. The new Swift equality guard necessarily rejects this native-valid result with `Validation support diagnostic differs from the selected catalogue candidate.` The reviewer did not run an end-to-end Swift publication of this case; the native result and rejecting Swift condition were inspected directly.

An initial equally bounded probe with D=1 also passed native intrinsic/final validation and exposed the same distinction; D=199 above provides the clearer boundary example.

### Required fix and regression

Preserve exact known joint-support and row-product correspondence, plus complete selected-candidate keys, typed diagnostic fields, duplicate rejection and known-row membership. Treat fresh `unknown_rows` according to its actual contract: it may additionally contain jointly supported rows with uncertain cloud members. For example, the relation between its non-joint unknown rows and the catalogue's unknown rows can be checked without demanding equality of the full lists. Do not modify native catalogue/checker semantics or discard fresh diagnostics to satisfy the LGE comparison.

Add a truthful synthetic regression using this mixed-length-cloud/uncertain-flank case that publishes with its fresh diagnostics intact. Retain rejection tests for missing support, unknown row IDs, malformed spans, and mismatched confirmed joint/product support. The existing selected fixture has fully observed support and therefore cannot expose this new false rejection.

## Verification and scope

Accepted supplied verification, not repeated by reviewer:

- `swift test --skip-update --filter 'PrimalScheme3DesignPipelineTests|PrimalScheme3PublicationTests|PrimerDesignCommandTests'`: 33 passed.
- `swift build --skip-update --product lungfish-cli`: succeeded; help inspected.
- Native-generated empty fixture now has references180/183 and valid zero-cap output; reported 16 descriptors match final bytes.

The added mutations rehash their affected descriptors and assert semantic-error categories, so they now test contract enforcement rather than merely stale checksums. The direct JSON regression covers equivalent `51`/`51.0`, boolean distinction, and adjacent large integers.

Reviewer read the actual production/test diff, ran a scoped source/test/generator `git diff --check` successfully, and ran only the two bounded in-memory native probes prompted by the concrete support concern. No broad suites, HLA benchmarks, production/test edits, delegation, native science changes, installed/managed/original-worktree changes, prior-output overwrites, publication or remote actions. Only this ignored scratch review report was written.

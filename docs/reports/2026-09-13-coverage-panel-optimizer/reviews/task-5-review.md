# Task 5 independent review

Reviewed LGE `3fc2179b8..641180f28` on `codex/primalscheme-panel-optimizer`, against the final Task 5 brief and report. Read the actual Swift implementation, caller paths, tests, generator, and representative native fixture records. This is a Task 5 review, not the final whole-branch review.

- Spec compliance: **FAIL pending the findings below**.
- Code quality: **NEEDS FIXES**.
- Findings: **1 P1, 3 P2**. No algorithm-core change is requested.

## 1. [P1] Parse published references as separate loci, not equal-width aligned rows

Location: `Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:457–458`.

`validatePublication` passes native `reference.fasta` to `Primer3InputLoader.readAlignedRows`. That helper explicitly rejects rows of unequal lengths at `Sources/LungfishWorkflow/PrimerDesign/Primer3DesignInput.swift:116`. Native reference FASTA contains one ungapped reference per independent target MSA; separate loci are not required to have equal lengths. A valid combined coverage panel therefore fails publication whenever target reference lengths differ.

The committed tests hide the defect: the selected fixture has one reference, and both references in the empty fixture are 180 bases. The coordinator's upcoming HLA9 references have lengths `1098,1089,1101,783,777,768,786,801,1077`, so the intended valid publication would hit this guard before the bundle writer.

Required fix: use a reference-FASTA reader that accepts independently sized, nonempty sequences while preserving exact identifiers and sequence checks against the catalogue. Reject duplicate reference identifiers with a normal validation error before constructing `Dictionary(uniqueKeysWithValues:)`, which otherwise traps for duplicate keys. Do not relax the equal-width requirement on the existing aligned-input loader.

Regression: a truthful native-generated multi-target fixture with unequal reference lengths must publish, including a valid empty panel if useful. Duplicate native reference identifiers must throw atomically rather than trap. No new biological benchmark is needed for this regression.

## 2. [P2] Verify each selected primer cloud member and its exact binding footprint

Location: `Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:488–495`; BED parsing at `:579–591`.

Primer BED validation currently counts rows whose sequences are members of the expected cloud. It does not require every expected sequence to appear exactly once. For the committed two-member forward cloud, replacing the second forward row's sequence with the first row's sequence still yields two matching member rows and the required row count, even though one selected oligo is absent. Thus the advertised complete-cloud check is not established.

The same guard checks full/trimmed amplicon coordinates but never compares individual primer coordinates with their candidate anchors and concrete oligo length. `BEDRecord` also drops the strand column entirely. A primer row moved to another positive interval or given the wrong strand passes this semantic guard. Because the ordering worksheet is derived from primer BED, a self-consistently hashed malformed native export could become a published order sheet that differs from the selected validated candidate cloud.

Required fix: compare exact, duplicate-free role-specific sequence sets; verify each forward footprint as `[forward_anchor - oligo_length, forward_anchor)` and each reverse footprint as `[reverse_anchor, reverse_anchor + oligo_length)`, with the correct `+`/`-` strand, reference, and one-based pool. Preserve mixed-length clouds and actual 5'-3' reverse sequence orientation. Validate unique row identities as appropriate.

Regressions should duplicate one member while omitting another, shift a primer footprint, and flip a primer strand. Refresh the native provenance size/hash descriptor in these fixtures so rejection proves the scientific correspondence check, not merely a checksum mismatch. The current `bed-pool` mutation leaves stale hashes and does not cover these cases.

## 3. [P2] Nested JSON equality still conflates scientific numbers and booleans

Location: `Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:299–300`, used for integration profile/options at `:132–136`, optimizer options/profile at `:383–388`, and other native identity comparisons.

The explicit numeric helpers correctly distinguish `CFBoolean`, but nested dictionaries bypass them through `(lhs as AnyObject).isEqual(rhs)`. Foundation treats numeric zero/one and booleans as equal. As a result, an optimizer option such as `seed: false` compares equal to requested `seed: 0`, `starts: true` compares equal to `starts: 1`, and a numeric `mismatch_fuzzy: 1` compares equal to the expected boolean `true`. The unchanged well-typed top-level config does not validate those nested artifact values.

This was an explicit Task 5 brief boundary. A small reviewer Swift probe executed the same helper expression:

```swift
let numeric: [String: Any] = [
    "options": ["seed": 0, "starts": 1],
    "profile": ["mismatch_fuzzy": true],
]
let substituted: [String: Any] = [
    "options": ["seed": false, "starts": true],
    "profile": ["mismatch_fuzzy": 1],
]
print((numeric as AnyObject).isEqual(substituted))
// true
```

Required fix: recursively compare JSON values with explicit boolean-versus-number type discrimination, or validate nested fields through typed schema checks before structural equality. Keep equivalent JSON numeric spellings such as native `51.0` versus the resolved numeric `51` compatible where the schema calls for a real value; reject fractional values in integer fields and booleans in either numeric kind.

Regression: replace only nested option/profile numeric values with booleans (and boolean fields with zero/one), keeping top-level config unchanged and refreshing affected artifact descriptors. Confirm atomic rejection with a type/contract error.

## 4. [P2] Target and support metadata are only checked as dictionary-shaped

Location: `Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:394–407` and `:420–424`.

`validateValidation` accepts any dictionary for `per_target` and `support_diagnostics`; `validateOptimizer` similarly only checks the shape of `per_target`. Their target/candidate keys and values are not compared to the catalogue and assignments. For example, replacing the standalone validation's `per_target` and `support_diagnostics` with empty dictionaries, copying that validation into `optimizer.validation`, and retaining a dictionary-shaped optimizer `per_target` passes these checks. The later publication and provenance validators never inspect those records. Once affected file descriptors are updated, no remaining check catches the missing required target/support diagnostics.

This fails the brief's required target identity agreement across catalogue, validator, optimizer/config and complete independent-validation artifact contract. `valid: true` with no violation entries is necessary but does not establish the presence or consistency of the published per-locus validation results.

Required fix: require the exact catalogue target-key set in the independent validator, require selected-candidate support keys, check target reference lengths against the catalogue, and validate the documented per-target metric fields and consistency with selected declared intervals/optimizer summaries. At minimum missing, extra, unknown, malformed, and inconsistent target/support records must be rejected. This need not rerun the native thermochemical/specificity algorithm in Swift.

Regression: self-consistently rehash mutations that remove/rename a target diagnostic, change its reference length or metric, or omit selected-candidate support; confirm rejection before publication. Keep valid under-target and empty-assignment records accepted with the expected complete target summaries.

## Reviewed behavior that meets the contract

- New options have source-compatible initializer defaults and backward-compatible decode defaults; legacy emits no coverage flags.
- Coverage requires combined/equal, MatchDB, explicit reference-span activation, valid selector options, and an explicit local executable before managed runtime preparation.
- Managed default remains exact `3.3.0+lge.2`. Coverage requires `3.3.0+lge.3` capability evidence; an explicit supported lge.3 legacy route remains available without new flags.
- Production capability probing occurs once before native scientific execution and retains raw probe/runtime evidence. Native configuration version must match actual executed identity.
- Catalogue compressed-byte identity is checked separately from semantic identity, schemas and requested settings are cross-checked, input source indices form a strict bijection, and durable consumed input bytes are bound to the actual executed input paths.
- Native output inventory and descriptor hashes are checked before atomic bundle writing. Native artifacts are copied unchanged, with final wrapper paths and derived order-sheet provenance handled separately.
- Fixture generation uses reviewed native science with explicitly declared presentation-only stubs; selected multi-member clouds and literal zero-cap empty results are real producer outputs.
- No managed registry, lock, dependency pins, About, installer, GUI, or original working-copy changes appear in the commit scope.

## Verification and scope

Accepted supplied evidence, not reviewer reruns:

- `swift test --skip-update --filter 'PrimalScheme3DesignPipelineTests|PrimalScheme3PublicationTests|PrimerDesignCommandTests'`: 32 passed.
- `swift build --skip-update --product lungfish-cli`: succeeded; reported help exposes the new options and override.
- Coordinator independently checked selected 15 and empty 16 native output descriptors, two assignments/eight primer-cloud rows, literal zero caps, and strict source byte/index binding.

Reviewer ran the bounded standalone Swift Foundation equality probe above, read the actual aligned-FASTA loader and all relevant validator branches, checked the fixture's mixed-length primer footprints, and ran a source/test/doc scoped `git diff --check` successfully. No existing test suite, native scientific run, or HLA benchmark was repeated. The metadata/BED bypass findings are source-derived; this review does not claim an end-to-end mutated-bundle publication run was performed.

Only this ignored scratch review report was written. No production/test edits, delegates, installed package changes, managed-pin changes, prior-output overwrites, releases, or pushes.

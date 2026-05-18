# Wave 2 IO Correctness Plan

**Worker:** B
**Worktree:** `.worktrees/wave2-io-correctness`
**Base:** `acd514b4 chore: checkpoint wave 1 remediation`

## Scope

Owned files:

- `Sources/LungfishIO/Formats/VCF/VCFReader.swift`
- `Sources/LungfishIO/Bundles/VariantDatabase.swift`
- `Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift`
- `Sources/LungfishIO/Index/FASTAIndex.swift`
- the unused async BigWig reader file
- Focused tests under `Tests/LungfishIOTests/`

## Issues

### W2-IO-B-01: VCF symbolic ALT classification

Problem:

- `VCFVariant.isSNP` treats `ALT=*` as SNP because REF and ALT length are both 1.
- `VCFVariant.isIndel`, `VCFReader.summarize`, and `VariantDatabase.classifyVariant` classify symbolic alleles by string length, so `<DEL>` can become `INS`.
- Breakend alleles should be structural/other, not SNP/indel.
- `##FILTER` parsing loses the ID when `ID` is the last field in the header metadata.

Red tests:

- `swift test --filter VCFReaderTests/testSymbolicAltAndSpanningDeletionClassification`
- `swift test --filter VCFReaderTests/testReadHeaderParsesFilterIDWhenIDIsLastField`
- `swift test --filter VariantDatabaseGenotypeTests/testClassifyVariantSymbolicAndBreakendAltsAsComplex`

Implementation:

- Add VCF allele helpers that detect symbolic (`<...>`), spanning deletion (`*`), and breakend notation.
- Exclude those alleles from SNP/indel length checks.
- Use shared VCF classification in summary and matching rules in `VariantDatabase.classifyVariant`.
- Fix `##FILTER` ID parsing when the ID field is last.

Verification:

- Focused VCF reader and variant database filters.
- `swift build --target LungfishIO`.

Residual risks:

- Symbolic CNV subtyping remains collapsed to `COMPLEX`/`SV`; this lane only prevents false SNP/INS/DEL labels.

### W2-IO-B-02: Universal search LIKE escaping

Problem:

- Search text and attribute contains clauses bind raw `%`, `_`, and `\` into `LIKE`, causing wildcard matches instead of literal matches.
- Path-prefix deletes use raw `LIKE ? || '%'`, so paths containing `%`, `_`, or `\` can delete unrelated rows.

Red tests:

- `swift test --filter ProjectUniversalSearchTests/testSearchEscapesLikeWildcardsInTextAndAttributeFilters`
- `swift test --filter ProjectUniversalSearchTests/testDeleteEntitiesEscapesLikeWildcardsInPathPrefix`

Implementation:

- Add one SQLite LIKE escaping helper for `%`, `_`, and `\`.
- Add `ESCAPE '\'` to text, attribute, and path-prefix `LIKE` clauses.
- Bind escaped patterns only at call sites that use `LIKE`.

Verification:

- Focused universal search filter.
- `swift build --target LungfishIO`.

Residual risks:

- Query parser semantics are unchanged; this only makes existing contains/prefix matching literal-safe.

### W2-IO-B-03: FASTA index streaming builder

Problem:

- `FASTAIndexBuilder.build(for:)` reads the whole file and splits it as a UTF-8 string, which is not viable for multi-GB references.
- The existing code assumes one-byte `\n` line endings when computing offsets and line widths.

Red tests:

- `swift test --filter FASTAIndexRegressionTests/testBuildIndexPreservesOffsetsForCRLFAndFinalLineWithoutNewline`
- `swift test --filter FASTAIndexRegressionTests/testBuildIndexDoesNotCallReadToEnd`

Implementation:

- Replace `readToEnd()`/whole-file string splitting with streaming byte chunks.
- Track byte positions exactly, including `\r\n`, `\n`, and a final line without a newline.
- Keep Wave 1 header behavior: trim header edges and split sequence names on whitespace.

Verification:

- Focused FASTA index filter.
- `swift build --target LungfishIO`.

Residual risks:

- This builder still treats sequence lines as byte-counted ASCII/UTF-8 bases, matching `.fai` expectations.

### W2-IO-B-04: Dead async BigWig reader

Problem:

- The deleted async BigWig reader file defined an unfinished API.
- Repository search shows no production consumers outside its own file.

Evidence:

- The pre-delete reference scan returned no production or test consumers outside that file.

Implementation:

- Delete the dead async BigWig reader file if the package still builds.
- Do not touch `BigBedReader` or `SyncBigBedReader`.

Verification:

- `swift build --target LungfishIO`
- Focused build/test command recorded below.

Residual risks:

- Public API removal could affect downstream users outside this repository. The lane requirement explicitly prefers deletion after proving no in-repo production consumers.

## Red Output Log

- `swift test --filter VCFReaderTests/testSymbolicAltAndSpanningDeletionClassification` failed as expected: symbolic `<DEL>` and breakend were reported as indel, `ALT=*` was reported as SNP, and summary produced SNP/INS counts instead of `SV`/`OTHER`.
- `swift test --filter VCFReaderTests/testReadHeaderParsesFilterIDWhenIDIsLastField` failed as expected: `header.filters["NoCall"]` was nil and an empty filter key was present.
- `swift test --filter VariantDatabaseGenotypeTests/testClassifyVariantSymbolicAndBreakendAltsAsComplex` failed as expected: symbolic/spanning/breakend alternates returned `INS` or `SNP` instead of `COMPLEX`.
- `swift test --filter ProjectUniversalSearchTests/testSearchEscapesLikeWildcardsInTextAndAttributeFilters` failed as expected: `Alpha%Literal` matched `AlphaXLiteral`, and `batch_1` matched `batchA1`.
- `swift test --filter ProjectUniversalSearchTests/testDeleteEntitiesEscapesLikeWildcardsInPathPrefix` failed as expected: deleting `Literal_%_Bundle.lungfishfastq` removed two entities instead of one.
- `swift test --filter FASTAIndexRegressionTests/testBuildIndexPreservesOffsetsForCRLFAndFinalLineWithoutNewline` failed as expected: CRLF and final no-newline offsets/widths were wrong.
- `swift test --filter FASTAIndexRegressionTests/testBuildIndexDoesNotCallReadToEnd` failed as expected: source still contained `readToEnd()`.

## Green Verification Log

- `swift test --filter VCFReaderTests/testSymbolicAltAndSpanningDeletionClassification` passed.
- `swift test --filter VCFReaderTests/testReadHeaderParsesFilterIDWhenIDIsLastField` passed.
- `swift test --filter VariantDatabaseGenotypeTests/testClassifyVariantSymbolicAndBreakendAltsAsComplex` passed.
- `swift test --filter ProjectUniversalSearchTests/testSearchEscapesLikeWildcardsInTextAndAttributeFilters` passed.
- `swift test --filter ProjectUniversalSearchTests/testDeleteEntitiesEscapesLikeWildcardsInPathPrefix` passed.
- `swift test --filter FASTAIndexRegressionTests/testBuildIndexPreservesOffsetsForCRLFAndFinalLineWithoutNewline` passed.
- `swift test --filter FASTAIndexRegressionTests/testBuildIndexDoesNotCallReadToEnd` passed.
- The pre-delete reference scan returned no production or test consumers outside that file.
- `swift build --target LungfishIO` passed.
- `git diff --check` passed.

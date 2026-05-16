# GenBank Streaming And Feature Location Fidelity Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GenBank whole-file parsing with record streaming and preserve nested/mixed feature-location strand information without breaking existing reader APIs.

**Architecture:** `GenBankReader` will read UTF-8 lines incrementally, accumulate only the current GenBank record, and pass complete record lines to the existing record parser. Location parsing will produce an internal tree/result that carries per-interval strand and raw location text before converting to `SequenceAnnotation`.

**Tech Stack:** Swift Package Manager, XCTest, `FileHandle.bytes.lines`, `AsyncThrowingStream`, `Codable`.

---

## Slice Spec

Required behavior:

- `parseFileSync` must not use `readToEnd()` or split the full file with `components(separatedBy: .newlines)`.
- `records()` must stream generated multi-record GenBank input without loading the full file string.
- `readAllSync()` and `readAll()` remain API-compatible and internally collect streamed records.
- `complement(join(10..20,30..40))` remains feature-level `.reverse`.
- `join(complement(10..20),30..40)` preserves interval-level `.reverse` and `.forward`; mixed intervals set feature-level strand to `.unknown`.
- Raw GenBank location text is preserved in a reserved qualifier for diagnostics/export.
- Do not modify Kraken2 parsing.

## File Plan

- Create: `docs/reviews/2026-05-16-wave3-genbank-streaming-plan.md`
  - Tracks this slice plan, red/green commands, verification, and residual risks.
- Modify: `Sources/LungfishCore/Models/SequenceAnnotation.swift`
  - Add optional `AnnotationInterval.strand: Strand? = nil` only if needed for mixed nested locations.
  - Preserve `Codable` compatibility by decoding missing `strand` as `nil`.
- Modify: `Sources/LungfishIO/Formats/GenBank/GenBankReader.swift`
  - Add a reserved raw-location qualifier key.
  - Replace full-file read with line/record streaming.
  - Parse feature locations through an internal structure that preserves nested strand.
  - Emit raw location qualifier and interval strand metadata.
- Modify: `Tests/LungfishIOTests/GenBankReaderTests.swift`
  - Add source-level guard and generated streaming regression.
- Modify: `Tests/LungfishIOTests/GenBankReaderComprehensiveTests.swift`
  - Add nested complement/join fidelity tests and raw-location qualifier assertions.

## TDD / Red-Test Plan

- [ ] Add `testParseFileSyncDoesNotReadEntireFileIntoMemory` in `GenBankReaderTests`.
  - It reads `GenBankReader.swift` as source and asserts `parseFileSync` does not contain `readToEnd()` or `components(separatedBy: .newlines)`.
  - Red expectation: fails on both current source patterns.
- [ ] Add `testRecordsStreamsGeneratedMultiRecordFile` in `GenBankReaderTests`.
  - It writes a generated multi-record `.gb` file and consumes `reader.records()` record by record.
  - Red expectation: source guard already proves current `records()` delegates to whole-file loading; this test protects public streaming behavior after the refactor.
- [ ] Add `testComplementJoinKeepsFeatureReverseStrand` in `GenBankReaderComprehensiveTests`.
  - It parses `complement(join(10..20,30..40))`.
  - Red/green expectation: current code likely passes feature-level reverse; keep as regression protection.
- [ ] Add `testJoinWithNestedComplementPreservesIntervalStrands` in `GenBankReaderComprehensiveTests`.
  - It parses `join(complement(10..20),30..40)`.
  - Red expectation: current model cannot expose interval strands and currently returns feature-level forward.
- [ ] Add `testRawGenBankLocationQualifierIsPreserved` in `GenBankReaderComprehensiveTests`.
  - It asserts a reserved qualifier contains exact raw location text for a mixed-strand feature.
  - Red expectation: current parser only preserves raw feature type.

Red command:

```bash
swift test --filter 'GenBankReaderTests|GenBankReaderComprehensiveTests'
```

Expected red summary:

- Source-level guard fails because `parseFileSync` contains `readToEnd()` and `components(separatedBy: .newlines)`.
- Mixed nested location test fails because interval-level strand is unavailable and feature-level strand is not `.unknown`.
- Raw location qualifier test fails because the qualifier key is not populated.

## Implementation Plan

- [ ] Implement the red tests and capture failure output.
- [ ] Add `AnnotationInterval.strand: Strand?` with default `nil`, update initializer, and add custom `Codable` if synthesized decoding does not tolerate absent keys.
- [ ] Add `GenBankReader.rawLocationQualifierKey`, keeping `rawFeatureTypeQualifierKey` unchanged.
- [ ] Replace `parseFileSync` with record streaming:
  - Open `FileHandle`.
  - Iterate `handle.bytes.lines`.
  - Skip blank lines between records.
  - Append lines to `recordLines` until a trimmed `//`.
  - Parse and emit the single record.
  - At EOF, parse a trailing unterminated non-empty record for compatibility.
- [ ] Keep `parseRecord(lines:startIndex:)` behavior intact where possible, but call it with one record at a time from the streamer.
- [ ] Replace the location parser tuple with an internal parse result:
  - `intervals: [AnnotationInterval]`
  - `strand: Strand`
  - nested complement toggles strand for child intervals.
  - uniform interval strands produce feature-level `.forward` or `.reverse`.
  - mixed interval strands produce feature-level `.unknown`.
- [ ] Preserve exact feature location text in `rawLocationQualifierKey`.
- [ ] Run the focused red/green test target after each behavior.
- [ ] Run full verification commands.
- [ ] Commit only this slice's changed files.

## Verification Commands

```bash
swift test --filter 'GenBankReaderTests|GenBankReaderComprehensiveTests'
swift test --filter LungfishIOTests
swift build --product lungfish-cli
git diff --check
```

## Residual Risks

- `FileHandle.bytes.lines` still decodes complete lines; individual pathological long feature/sequence lines can allocate per-line memory, but not full-file memory.
- `SequenceAnnotation` sorts intervals by coordinate, so interval metadata follows sorted genomic order rather than textual `join()` order. This matches existing API behavior but may not preserve transcript order for reverse-strand joins.
- GenBank location grammar is broader than this slice. Fuzzy positions and remote accessions remain parsed with existing simplified coordinate handling.
- Existing exporters may ignore the new raw-location qualifier until explicitly taught to prefer it.

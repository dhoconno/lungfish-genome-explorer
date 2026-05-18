# Kraken2 Per-Read Streaming Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bounded streaming parsing for Kraken2 per-read output while preserving existing `parse(url:)`, `parse(data:)`, and `parse(text:)` compatibility.

**Architecture:** URL parsing will delegate to a new callback streaming API that reads bounded chunks from `FileHandle`, assembles complete lines, and reuses existing `parseLine` tolerance for malformed records. Existing in-memory parsers remain compatibility APIs, while URL-based read-id helpers filter during streaming without materializing all records.

**Tech Stack:** Swift Package Manager, XCTest, Foundation `FileHandle`, existing `LungfishIO` Kraken parser types.

---

## Slice Spec

- Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/wave3-kraken2-streaming`
- Branch: `codex/wave3-kraken2-streaming`
- Modify only this slice’s files unless a downstream streaming caller update is low-risk and clearly in scope.
- Do not modify `GenBankReader`.
- Required files:
  - Modify `Sources/LungfishIO/Formats/Kraken/Kraken2OutputParser.swift`.
  - Modify `Tests/LungfishIOTests/Kraken2OutputParserTests.swift`.
  - Create this plan at `docs/reviews/2026-05-16-wave3-kraken2-streaming-plan.md`.
- Required behavior:
  - `parse(url:)` no longer calls `Data(contentsOf:)`; it delegates to streaming.
  - Add `parseRecords(url:onRecord:) throws -> Int`.
  - Add `readIds(url:classifiedTo:) throws -> [String]`.
  - Add `readIds(url:classifiedToAnyOf:) throws -> [String]`.
  - Streaming callback receives records in file order.
  - Streaming API returns the parsed record count.
  - Empty files and fully malformed files throw `Kraken2OutputParserError.emptyFile`.
  - `parse(data:)` and `parse(text:)` remain compatible.

## TDD / Red-Test Plan

### Task 1: Add Streaming API Tests

**Files:**
- Modify: `Tests/LungfishIOTests/Kraken2OutputParserTests.swift`
- Modify after red: `Sources/LungfishIO/Formats/Kraken/Kraken2OutputParser.swift`

- [ ] **Step 1: Write failing test for ordered callback and count**

Add a temp-file helper and a test like:

```swift
func testParseRecordsURLStreamsRecordsInOrderAndReturnsCount() throws {
    let url = try writeTemporaryKrakenOutput("""
    C\tread1\t9606\t150\t9606:150
    U\tread2\t0\t150\t0:150
    C\tread3\t562\t200\t562:200
    """)

    var seen: [String] = []
    let count = try Kraken2OutputParser.parseRecords(url: url) { record in
        seen.append(record.readId)
    }

    XCTAssertEqual(count, 3)
    XCTAssertEqual(seen, ["read1", "read2", "read3"])
}
```

- [ ] **Step 2: Run test to verify red**

Run: `swift test --filter Kraken2OutputParserTests/testParseRecordsURLStreamsRecordsInOrderAndReturnsCount`

Expected: compile failure because `parseRecords(url:onRecord:)` does not exist.

- [ ] **Step 3: Implement minimal streaming API**

Add `parseRecords(url:onRecord:) throws -> Int` that:

```swift
public static func parseRecords(
    url: URL,
    onRecord: (Kraken2ReadClassification) throws -> Void
) throws -> Int
```

Use `FileHandle(forReadingFrom:)`, read `64 * 1024` byte chunks, append to a bounded line buffer, split on newline bytes, decode each complete line as UTF-8, call `parseLine`, invoke callback, and increment count. At EOF, parse the final unterminated line if present. Throw `.emptyFile` if count is zero.

- [ ] **Step 4: Run green test**

Run: `swift test --filter Kraken2OutputParserTests/testParseRecordsURLStreamsRecordsInOrderAndReturnsCount`

Expected: PASS.

### Task 2: Source Guard For URL Compatibility API

**Files:**
- Modify: `Tests/LungfishIOTests/Kraken2OutputParserTests.swift`
- Modify after red: `Sources/LungfishIO/Formats/Kraken/Kraken2OutputParser.swift`

- [ ] **Step 1: Write failing source-level guard**

Add:

```swift
func testParseURLDelegatesToStreamingWithoutDataContentsOf() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LungfishIO/Formats/Kraken/Kraken2OutputParser.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let parseURLBody = try XCTUnwrap(source.bodyOfStaticFunction(named: "parse", firstParameter: "url"))
    XCTAssertFalse(parseURLBody.contains("Data(contentsOf:"))
    XCTAssertTrue(parseURLBody.contains("parseRecords(url:"))
}
```

The helper may be a small test-only string scanner in the test file.

- [ ] **Step 2: Run test to verify red**

Run: `swift test --filter Kraken2OutputParserTests/testParseURLDelegatesToStreamingWithoutDataContentsOf`

Expected: FAIL because current `parse(url:)` calls `Data(contentsOf:)`.

- [ ] **Step 3: Route `parse(url:)` through streaming**

Replace URL loading with:

```swift
public static func parse(url: URL) throws -> [Kraken2ReadClassification] {
    var results: [Kraken2ReadClassification] = []
    _ = try parseRecords(url: url) { record in
        results.append(record)
    }
    return results
}
```

- [ ] **Step 4: Run green test**

Run: `swift test --filter Kraken2OutputParserTests/testParseURLDelegatesToStreamingWithoutDataContentsOf`

Expected: PASS.

### Task 3: Streaming Error And Filter Helpers

**Files:**
- Modify: `Tests/LungfishIOTests/Kraken2OutputParserTests.swift`
- Modify after red: `Sources/LungfishIO/Formats/Kraken/Kraken2OutputParser.swift`

- [ ] **Step 1: Write failing tests**

Add tests:

```swift
func testParseRecordsURLThrowsEmptyFileForEmptyAndMalformedFiles() throws { ... }
func testReadIdsURLClassifiedToFiltersDuringStreaming() throws { ... }
func testReadIdsURLClassifiedToAnyOfFiltersDuringStreaming() throws { ... }
```

Assert `.emptyFile` for empty and fully malformed temp files. Assert URL helpers match existing in-memory `readIds(from:)` behavior for taxon `9606` and set `[562, 287]`.

- [ ] **Step 2: Run tests to verify red**

Run: `swift test --filter Kraken2OutputParserTests`

Expected: compile failures for missing URL read-id helper APIs, or failures if empty/malformed streaming handling is incomplete.

- [ ] **Step 3: Implement helper APIs**

Add:

```swift
public static func readIds(url: URL, classifiedTo taxId: Int) throws -> [String]
public static func readIds(url: URL, classifiedToAnyOf taxIds: Set<Int>) throws -> [String]
```

Each helper calls `parseRecords(url:)`, appending `record.readId` only when the streamed record’s `taxId` matches.

- [ ] **Step 4: Run green tests**

Run: `swift test --filter Kraken2OutputParserTests`

Expected: PASS.

## Implementation Plan

- Keep the existing `parseLine` and `parseKmerHits` implementation to preserve malformed-line tolerance and k-mer parsing behavior.
- Implement the bounded reader inside `Kraken2OutputParser` as private helpers:
  - `streamLines(url:onLine:) throws -> Int` or equivalent internal logic.
  - `parseBufferedLine(_ lineData: Data, lineNumber: Int) -> Kraken2ReadClassification?`.
- Use a constant chunk size, e.g. `private static let streamingChunkSize = 64 * 1024`.
- Strip trailing carriage return before decoding lines so CRLF files parse consistently with existing text parsing.
- Map `FileHandle` open/read errors to `Kraken2OutputParserError.fileReadError(url, detail)`.
- Preserve `parse(data:)` and `parse(text:)` exactly, except for harmless internal helper reuse if tests prove compatibility.
- Search for downstream `Kraken2OutputParser.parse(url:)` or read-id filtering. Update only low-risk call sites that need read IDs or filtered records; leave broad result materialization call sites unchanged.

## Verification Commands

- Red tests:
  - `swift test --filter Kraken2OutputParserTests/testParseRecordsURLStreamsRecordsInOrderAndReturnsCount`
  - `swift test --filter Kraken2OutputParserTests/testParseURLDelegatesToStreamingWithoutDataContentsOf`
  - `swift test --filter Kraken2OutputParserTests`
- Required final verification:
  - `swift test --filter Kraken2OutputParserTests`
  - `swift test --filter ClassifierReadResolverTests`
  - `swift test --filter LungfishIOTests`
  - `git diff --check`

## Residual Risks

- Source-level tests can be brittle if function formatting changes substantially; keep the scanner focused on the `parse(url:)` body only.
- `FileHandle.read(upToCount:)` still creates per-chunk `Data`, but bounded chunks avoid full-file materialization.
- Extremely long single-line records require buffering that single line; this is inherent in preserving line-oriented Kraken2 parsing.
- URL read-id helpers still return arrays of all matching IDs; callers extracting very large clades may need a future callback-based ID sink if array size becomes a bottleneck.

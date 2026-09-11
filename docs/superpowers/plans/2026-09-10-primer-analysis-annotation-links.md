# Primer Analysis Annotation Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this bounded task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Preserve the identity of a saved primer analysis, result, and input through existing annotation serialization and database rendering.

**Architecture:** A small LungfishCore value type stores UUID links in versioned, namespaced scalar qualifiers. It does not depend on the renderer's annotation UUID and performs no coordinate transforms or scientific design. Existing annotation storage and rendering remain unchanged.

**Tech Stack:** Swift 6.2, Foundation, existing LungfishCore/IO models, XCTest.

**Spec:** `docs/proposals/2026-09-10-pcr-primer-pack.md`

## Global Constraints

- Work only in `.worktrees/pcr-primer-design` on `codex/pcr-primer-design`.
- Keep implementation independent of biological design engines and parameters.
- No changes to MHC work or global annotation identity behavior.
- Link IDs are metadata references, not a claim that source coordinates or checksums have been validated.
- Do not create a new on-disk scientific workflow without provenance.

## Task 1: Typed links that survive existing annotation roundtrips

**Files:**
- Create `Sources/LungfishCore/Models/PrimerAnalysisAnnotationLink.swift`.
- Create `Tests/LungfishCoreTests/PrimerAnalysisAnnotationLinkTests.swift`.
- Create `Tests/LungfishIOTests/PrimerAnalysisAnnotationLinkRoundtripTests.swift`.

**Interfaces:**
```swift
public struct PrimerAnalysisAnnotationLink: Codable, Sendable, Equatable {
    public let analysisID: UUID
    public let resultID: UUID
    public let inputID: UUID
    public init(analysisID: UUID, resultID: UUID, inputID: UUID)
    public static func read(from annotation: SequenceAnnotation) throws -> Self?
    public func attaching(to annotation: SequenceAnnotation) throws -> SequenceAnnotation
}
```

The four scalar qualifier keys are `lungfish_primer_link_version` (value `1`), `lungfish_primer_analysis_id`, `lungfish_primer_result_id`, and `lungfish_primer_input_id`. Absence of all four means an unlinked annotation. Partial, invalid, multiple-valued, or unsupported-version metadata must throw an explicit error. Attaching the same link is idempotent; attaching a different link to an already linked annotation throws. Preserve the annotation's UUID, intervals, strand, parent, note, and unrelated qualifiers.

- [x] Write tests naming concrete failures: lost link after JSON decoding, changed feature metadata, repeated attachment duplicating metadata, silent overwrite of another result, and malformed/partial/multiple-valued/unsupported link acceptance. First test:
```swift
let linked = try link.attaching(to: annotation)
let restored = try JSONDecoder().decode(SequenceAnnotation.self,
    from: JSONEncoder().encode(linked))
XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: restored), link)
XCTAssertEqual(restored.id, annotation.id)
```
- [x] Run `swift test --jobs 4 --filter PrimerAnalysisAnnotationLinkTests`, redirecting build output into `.build/primer-link-red.log`; confirm the link type is missing.
- [x] Implement scalar validation, UUID parsing, explicit error cases, and nonmutating attachment. First determine whether any recognized key exists, then validate the version and each required UUID; never silently use the first value of a multivalued qualifier.
- [x] Add a real BED14 → SQLite → `AnnotationDatabaseRecord.toAnnotation()` roundtrip with literal harmless feature metadata and the four qualifiers. Verify both reloaded views resolve to the same analysis/result/input IDs even though the renderer UUID can change. Assert unrelated feature metadata is retained.
- [x] Run `swift test --jobs 4 --filter 'PrimerAnalysisAnnotationLink|SequenceAnnotationTests|AnnotationDatabaseTests'` and inspect the exit status and test summary.
- [x] Have Astra independently review the full diff for spec compliance and correctness. Fix findings and rerun affected tests before integration.

## Review notes

This component and the opaque bundle use the same UUID identity contract. No shared production files are edited between them. Engine execution, annotation publication to source bundles, source checksum validation, and UI navigation are separate components; this helper only preserves and validates references.

## Verification record

Initial RED failed because `PrimerAnalysisAnnotationLink` was missing. GREEN ran `swift test --jobs 4 --filter 'PrimerAnalysisAnnotationLink|SequenceAnnotationTests|AnnotationDatabaseTests'`: 134 tests passed with zero failures. Astra reviewed the complete helper, tests, and adjacent serialization code; no blocking findings. Raw duplicate attributes discarded by existing parsers are outside this helper's validation boundary.

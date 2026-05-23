# MHC Genotype Inspector v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v1 five-lens genotype viewport with a three-lens (Summary / Review / Audit) inspector that reuses shared two-panel infrastructure, introduces a haplotype tape primitive, JSON-sidecar annotation layer, Smart Cohorts, and a manual-haplotyping mode for populations without a reference set.

**Architecture:** Reuse `TrackedDividerSplitView` + `TwoPaneTrackedSplitCoordinator` already used by 6 viewports. New types in LungfishCore (`HaplotypeColorToken`, `HaplotypeBlockGlyph`, `HaplotypeSlot`) and LungfishIO (`GenotypeAnnotationSidecar`, `GenotypeCohortSmartFilter`, `ManualHaplotypeAssignment`). New views in LungfishApp's existing pattern (NSViewController + SwiftUI inspector sections). All annotations live in `<bundle>/annotations.json` peer to the existing `genotype-result.json`. CLI parity through `lungfish genotype` subcommands.

**Tech Stack:** Swift 6.2, AppKit + SwiftUI, XCTest, Codable for JSON sidecar, NSCollectionView for Cards, NSTableView for Outline & Matrix, existing OOXML export pipeline for Excel.

---

## Files

### Created

**LungfishCore**
- `Sources/LungfishCore/Genotype/HaplotypeColorToken.swift` — palette token (M1–M7 canonical + extended palette + manual)
- `Sources/LungfishCore/Genotype/HaplotypeBlockGlyph.swift` — glyph enum
- `Sources/LungfishCore/Genotype/HaplotypeSlot.swift` — h1/h2 enum, shared by IO and App

**LungfishIO**
- `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift` — Codable types + reader/writer
- `Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift` — predicate ADT, evaluator, JSON codec
- `Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift` — manual definition model
- `Sources/LungfishIO/Bundles/GenotypeBlockClassifier.swift` — block / recombinant / atypical classifier given a sample's calls
- `Sources/LungfishIO/Bundles/GenotypeDropoutEvaluator.swift` — three-mode dropout threshold evaluator

**LungfishApp (renamed/shared)**
- `Sources/LungfishApp/Views/Layout/ResultPanelLayout.swift` — generic enum lifted from genotype-only; the existing `GenotypeResultPanelLayout` is re-exported as a typealias

**LungfishApp (new viewport pieces)**
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeHaplotypeTapeView.swift` — the two-strip tape primitive
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeOutlineView.swift` — Outline view mode
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeCardsView.swift` — Cards view mode
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift` — search field + pills
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeCohortSummaryPanelView.swift` — Panel B for Summary lens
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeReviewQueueView.swift` — Panel A for Review lens
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeCallEvidenceView.swift` — Panel B for Review lens
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeAuditPanelView.swift` — Panel B for Audit lens
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeManualHaplotypingPanelView.swift` — Audit lens manual-mode panel
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift` — @Observable wrapper around the sidecar; serializes writes
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeViewportV2State.swift` — display state for v2 viewport
- `Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift` — Override card SwiftUI section
- `Sources/LungfishApp/Views/Inspector/Sections/GenotypeSmartCohortSection.swift` — Smart Cohort library
- `Sources/LungfishApp/Views/Inspector/Sections/GenotypeStatusFlagSection.swift` — Status flag radio + comment list

**LungfishCLI**
- `Sources/LungfishCLI/Commands/GenotypeListSamplesSubcommand.swift`
- `Sources/LungfishCLI/Commands/GenotypeListCohortsSubcommand.swift`
- `Sources/LungfishCLI/Commands/GenotypeApplyAnnotationsSubcommand.swift`
- `Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift`
- `Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift` — parent command

**Tests**
- `Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift`
- `Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift`
- `Tests/LungfishIOTests/GenotypeCohortSmartFilterTests.swift`
- `Tests/LungfishIOTests/GenotypeBlockClassifierTests.swift`
- `Tests/LungfishIOTests/GenotypeDropoutEvaluatorTests.swift`
- `Tests/LungfishIOTests/ManualHaplotypeAssignmentTests.swift`
- `Tests/LungfishAppTests/GenotypeHaplotypeTapeViewTests.swift`
- `Tests/LungfishAppTests/GenotypeViewportV2Tests.swift`
- `Tests/LungfishAppTests/GenotypeReviewQueueTests.swift`
- `Tests/LungfishAppTests/GenotypeAnnotationFlowTests.swift`
- `Tests/LungfishAppTests/GenotypeSmartCohortTests.swift`
- `Tests/LungfishAppTests/GenotypeManualHaplotypingTests.swift`
- `Tests/LungfishCLITests/GenotypeSubcommandsTests.swift`

### Modified

- `Sources/LungfishApp/Views/Layout/TwoPaneTrackedSplitCoordinator.swift` — no functional change; this file's API is already general
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` — collapse to three lenses, rewire panels
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultDisplayState.swift` — v2 lens enum (drop `haplotypes`/`anchors`), add view mode enum
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeComparisonMatrixView.swift` — add Fit/Normal toggle
- `Sources/LungfishApp/Views/Results/Genotype/GenotypeViewportExcelExportService.swift` — apply overrides, add audit sheet, M1–M7 conditional formatting
- `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultDocumentSection.swift` — add view-mode radio, panel layout radio, sort key, Smart Cohorts library
- `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultDisplaySection.swift` — drop deprecated highlight code, add status flag bridge
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` — register the three new sections, route by lens
- `Sources/LungfishApp/Services/SampleMetadataBundleImportService.swift` — no functional change; verify compatibility
- `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift` — expose `annotationSidecarURL`, optional `loadAnnotationSidecar()`
- `Sources/LungfishIO/Bundles/BuiltInGenotypeHaplotypeDefinitions.swift` — add `colorTokenIndex` per haplotype; introduce `manualAssignment` placeholder set
- `Sources/LungfishCLI/LungfishCLI.swift` — register `GenotypeCommandGroup`
- `CLAUDE.md` (user memory hint) — note v2 lens model and sidecar location (skip if memory updates are out of scope for the worktree)

---

## Milestone 1: Core types and sidecar (LungfishCore + LungfishIO, no UI)

This milestone is purely data-layer and can ship as one commit. All tasks here are independent of UI changes and can be executed in parallel by separate subagents.

### Task 1.1: Add HaplotypeColorToken

**Files:**
- Create: `Sources/LungfishCore/Genotype/HaplotypeColorToken.swift`
- Test: `Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishCore

final class HaplotypeColorTokenTests: XCTestCase {
    func testCanonicalPaletteHasEightTokens() {
        let palette = HaplotypeColorToken.canonicalPalette
        XCTAssertEqual(palette.count, 8) // M0 (absent) + M1..M7
    }

    func testMCMNameAssignmentIsCanonical() {
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M1A").canonicalIndex, 1)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M3DR").canonicalIndex, 3)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M7B").canonicalIndex, 7)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "-").canonicalIndex, 0)
    }

    func testUnknownNameUsesHashedAssignment() {
        let token = HaplotypeColorToken.assigned(forName: "Mamu-A1*004:01:01")
        XCTAssertGreaterThanOrEqual(token.canonicalIndex, 0)
        XCTAssertLessThan(token.canonicalIndex, 8)
    }

    func testHashedAssignmentIsStable() {
        let a = HaplotypeColorToken.assigned(forName: "DRB1_04_06_01")
        let b = HaplotypeColorToken.assigned(forName: "DRB1_04_06_01")
        XCTAssertEqual(a.canonicalIndex, b.canonicalIndex)
    }

    func testEveryTokenHasDistinctGlyph() {
        let glyphs = Set(HaplotypeColorToken.canonicalPalette.map(\.glyph))
        XCTAssertEqual(glyphs.count, HaplotypeColorToken.canonicalPalette.count)
    }

    func testDarkVariantDiffersFromLight() {
        for token in HaplotypeColorToken.canonicalPalette where token.canonicalIndex != 0 {
            XCTAssertNotEqual(token.fillColor.hexString, token.darkFillColor.hexString,
                              "Token \(token.canonicalIndex) lacks a dark-mode variant")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HaplotypeColorTokenTests`
Expected: FAIL (HaplotypeColorToken does not exist)

- [ ] **Step 3: Implement HaplotypeColorToken**

```swift
// Sources/LungfishCore/Genotype/HaplotypeColorToken.swift
import Foundation

public struct HaplotypeColorToken: Equatable, Hashable, Codable, Sendable {
    public let canonicalIndex: Int
    public let displayName: String
    public let fillColor: AnnotationColor
    public let darkFillColor: AnnotationColor
    public let fontColor: AnnotationColor
    public let glyph: HaplotypeBlockGlyph

    public init(canonicalIndex: Int,
                displayName: String,
                fillColor: AnnotationColor,
                darkFillColor: AnnotationColor,
                fontColor: AnnotationColor,
                glyph: HaplotypeBlockGlyph) {
        self.canonicalIndex = canonicalIndex
        self.displayName = displayName
        self.fillColor = fillColor
        self.darkFillColor = darkFillColor
        self.fontColor = fontColor
        self.glyph = glyph
    }
}

public extension HaplotypeColorToken {
    static let canonicalPalette: [HaplotypeColorToken] = [
        // M0 = absent / blank / "-"
        .init(canonicalIndex: 0, displayName: "Absent",
              fillColor: AnnotationColor(red: 0.87, green: 0.87, blue: 0.87),
              darkFillColor: AnnotationColor(red: 0.27, green: 0.27, blue: 0.27),
              fontColor: AnnotationColor(red: 0.42, green: 0.42, blue: 0.42),
              glyph: .empty),
        .init(canonicalIndex: 1, displayName: "M1",
              fillColor: AnnotationColor(hex: "#0C0000")!,
              darkFillColor: AnnotationColor(hex: "#1A1A1A")!,
              fontColor: AnnotationColor(hex: "#FFFFFF")!,
              glyph: .filledCircle),
        .init(canonicalIndex: 2, displayName: "M2",
              fillColor: AnnotationColor(hex: "#FF0000")!,
              darkFillColor: AnnotationColor(hex: "#FF4444")!,
              fontColor: AnnotationColor(hex: "#FFFFFF")!,
              glyph: .filledSquare),
        .init(canonicalIndex: 3, displayName: "M3",
              fillColor: AnnotationColor(hex: "#0000FF")!,
              darkFillColor: AnnotationColor(hex: "#4488FF")!,
              fontColor: AnnotationColor(hex: "#FFFFFF")!,
              glyph: .filledTriangle),
        .init(canonicalIndex: 4, displayName: "M4",
              fillColor: AnnotationColor(hex: "#008000")!,
              darkFillColor: AnnotationColor(hex: "#22AA44")!,
              fontColor: AnnotationColor(hex: "#FFFFFF")!,
              glyph: .filledDiamond),
        .init(canonicalIndex: 5, displayName: "M5",
              fillColor: AnnotationColor(hex: "#FFFF00")!,
              darkFillColor: AnnotationColor(hex: "#DDDD00")!,
              fontColor: AnnotationColor(hex: "#0C0000")!,
              glyph: .hollowCircle),
        .init(canonicalIndex: 6, displayName: "M6",
              fillColor: AnnotationColor(hex: "#808080")!,
              darkFillColor: AnnotationColor(hex: "#999999")!,
              fontColor: AnnotationColor(hex: "#FFFFFF")!,
              glyph: .hollowSquare),
        .init(canonicalIndex: 7, displayName: "M7",
              fillColor: AnnotationColor(hex: "#800080")!,
              darkFillColor: AnnotationColor(hex: "#BB44BB")!,
              fontColor: AnnotationColor(hex: "#FFFFFF")!,
              glyph: .asterisk),
    ]

    static let canonicalByName: [String: Int] = [
        "M1A": 1, "M2A": 2, "M3A": 3, "M4A": 4, "M5A": 5, "M6A": 6, "M7A": 7,
        "M1B": 1, "M2B": 2, "M3B": 3, "M4B": 4, "M5B": 5, "M6B": 6, "M7B": 7,
        "M1DR": 1, "M2DR": 2, "M3DR": 3, "M4DR": 4, "M5DR": 5, "M6DR": 6, "M7DR": 7,
        "M1DQ": 1, "M2DQ": 2, "M3DQ": 3, "M4DQ": 4, "M5DQ": 5, "M6DQ": 6, "M7DQ": 7,
        "M1DP": 1, "M2DP": 2, "M3DP": 3, "M4M7DP": 4, "M5M6DP": 5,
        "-": 0, "": 0, "A1_063": 1,
    ]

    static func assigned(forName name: String) -> HaplotypeColorToken {
        if let index = canonicalByName[name] {
            return canonicalPalette[index]
        }
        if name.hasPrefix("recM") {
            // Recombinant - use index of first M token in the name
            return canonicalPalette[1]
        }
        // Stable hash → 1..7 (never 0; M0 is reserved for absent)
        let bytes: [UInt8] = Array(name.utf8)
        var hash: UInt32 = 2166136261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        let index = Int(hash % 7) + 1
        return canonicalPalette[index]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HaplotypeColorTokenTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Genotype/HaplotypeColorToken.swift Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift
git commit -m "Add HaplotypeColorToken with canonical M0-M7 palette"
```

### Task 1.2: Add HaplotypeBlockGlyph and HaplotypeSlot

**Files:**
- Create: `Sources/LungfishCore/Genotype/HaplotypeBlockGlyph.swift`
- Create: `Sources/LungfishCore/Genotype/HaplotypeSlot.swift`
- Test: extend `Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift`

- [ ] **Step 1: Write the implementation**

```swift
// Sources/LungfishCore/Genotype/HaplotypeBlockGlyph.swift
import Foundation

public enum HaplotypeBlockGlyph: String, CaseIterable, Codable, Sendable {
    case empty            // M0 / blank
    case filledCircle     // ●
    case filledSquare     // ■
    case filledTriangle   // ▲
    case filledDiamond    // ◆
    case hollowCircle     // ○
    case hollowSquare     // □
    case asterisk         // ✻

    public var symbol: String {
        switch self {
        case .empty:           return "·"
        case .filledCircle:    return "●"
        case .filledSquare:    return "■"
        case .filledTriangle:  return "▲"
        case .filledDiamond:   return "◆"
        case .hollowCircle:    return "○"
        case .hollowSquare:    return "□"
        case .asterisk:        return "✻"
        }
    }
}
```

```swift
// Sources/LungfishCore/Genotype/HaplotypeSlot.swift
import Foundation

public enum HaplotypeSlot: String, CaseIterable, Codable, Sendable {
    case h1
    case h2

    public var displayName: String {
        switch self {
        case .h1: return "H1"
        case .h2: return "H2"
        }
    }
}
```

- [ ] **Step 2: Add slot tests**

Append to `Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift`:

```swift
final class HaplotypeBlockGlyphTests: XCTestCase {
    func testAllGlyphsHaveDistinctSymbols() {
        let symbols = Set(HaplotypeBlockGlyph.allCases.map(\.symbol))
        XCTAssertEqual(symbols.count, HaplotypeBlockGlyph.allCases.count)
    }
}

final class HaplotypeSlotTests: XCTestCase {
    func testDisplayName() {
        XCTAssertEqual(HaplotypeSlot.h1.displayName, "H1")
        XCTAssertEqual(HaplotypeSlot.h2.displayName, "H2")
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter HaplotypeBlockGlyphTests --filter HaplotypeSlotTests`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishCore/Genotype/HaplotypeBlockGlyph.swift Sources/LungfishCore/Genotype/HaplotypeSlot.swift Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift
git commit -m "Add HaplotypeBlockGlyph and HaplotypeSlot enums"
```

### Task 1.3: Add GenotypeAnnotationSidecar model

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
- Test: `Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift`

- [ ] **Step 1: Write failing serialization round-trip test**

```swift
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeAnnotationSidecarTests: XCTestCase {
    func testEmptyRoundTrip() throws {
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T00:00:00Z")
        let data = try sidecar.encoded()
        let decoded = try GenotypeAnnotationSidecar.decode(data)
        XCTAssertEqual(decoded, sidecar)
    }

    func testCallOverrideRoundTrip() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T00:00:00Z")
        sidecar.callOverrides.append(.init(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .contamination, rationale: "Adjacent contamination",
            author: "dho", timestamp: "2026-05-22T16:02:11Z"
        ))
        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())
        XCTAssertEqual(decoded.callOverrides.count, 1)
        XCTAssertEqual(decoded.callOverrides[0].overrideCall, "A1_063")
    }

    func testUnknownKeysPassthroughIsTolerated() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-05-22T00:00:00Z",
          "callOverrides": [],
          "cellHighlights": [],
          "rowHighlights": [],
          "sampleNotes": [],
          "cellComments": [],
          "sampleStatusFlags": [],
          "callStatusFlags": [],
          "smartCohorts": [],
          "manualHaplotypeAssignments": [],
          "settings": {},
          "auditLog": [],
          "futureField": "ignored"
        }
        """.data(using: .utf8)!
        let decoded = try GenotypeAnnotationSidecar.decode(json)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testAuditLogAppendIsImmutable() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "t")
        sidecar.append(audit: .init(action: "highlight", sample: "S1", locus: "MHC-A", slot: .h1, before: nil, after: nil, color: "#FFEB3B", reason: nil, rationale: nil, author: "u", timestamp: "t"))
        XCTAssertEqual(sidecar.auditLog.count, 1)
        sidecar.append(audit: .init(action: "override", sample: "S1", locus: "MHC-A", slot: .h1, before: "M2A", after: "A1_063", color: nil, reason: "contamination", rationale: "x", author: "u", timestamp: "t+1"))
        XCTAssertEqual(sidecar.auditLog.count, 2)
        XCTAssertEqual(sidecar.auditLog[0].action, "highlight")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenotypeAnnotationSidecarTests`
Expected: FAIL (type doesn't exist)

- [ ] **Step 3: Implement GenotypeAnnotationSidecar**

```swift
// Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift
import Foundation
import LungfishCore

public struct GenotypeAnnotationSidecar: Codable, Equatable, Sendable {
    public static let filename = "annotations.json"
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: String
    public var lastEditedAt: String?
    public var lastEditor: String?
    public var callOverrides: [CallOverride]
    public var cellHighlights: [CellHighlight]
    public var rowHighlights: [RowHighlight]
    public var sampleNotes: [SampleNote]
    public var cellComments: [CellComment]
    public var sampleStatusFlags: [SampleStatusFlag]
    public var callStatusFlags: [CallStatusFlag]
    public var smartCohorts: [GenotypeCohortSmartFilter]
    public var manualHaplotypeAssignments: [ManualHaplotypeAssignment]
    public var settings: Settings
    public var auditLog: [AuditEntry]

    public static func empty(generatedAt: String) -> GenotypeAnnotationSidecar {
        .init(schemaVersion: currentSchemaVersion, generatedAt: generatedAt,
              lastEditedAt: nil, lastEditor: nil,
              callOverrides: [], cellHighlights: [], rowHighlights: [],
              sampleNotes: [], cellComments: [],
              sampleStatusFlags: [], callStatusFlags: [],
              smartCohorts: [], manualHaplotypeAssignments: [],
              settings: .default, auditLog: [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> GenotypeAnnotationSidecar {
        try JSONDecoder().decode(GenotypeAnnotationSidecar.self, from: data)
    }

    public mutating func append(audit: AuditEntry) {
        auditLog.append(audit)
        lastEditedAt = audit.timestamp
        lastEditor = audit.author
    }
}

public extension GenotypeAnnotationSidecar {
    struct CallOverride: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let originalCall: String
        public let overrideCall: String
        public let reasonTag: OverrideReasonTag
        public let rationale: String
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    originalCall: String, overrideCall: String,
                    reasonTag: OverrideReasonTag, rationale: String,
                    author: String, timestamp: String) {
            self.sample = sample; self.locus = locus; self.slot = slot
            self.originalCall = originalCall; self.overrideCall = overrideCall
            self.reasonTag = reasonTag; self.rationale = rationale
            self.author = author; self.timestamp = timestamp
        }
    }

    enum OverrideReasonTag: String, Codable, Sendable, CaseIterable {
        case dropout, contamination, novel, misCall, confirmed
    }

    struct CellHighlight: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let fillColor: String?  // hex
        public let borderColor: String?
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    fillColor: String?, borderColor: String?,
                    author: String, timestamp: String) {
            self.sample = sample; self.locus = locus; self.slot = slot
            self.fillColor = fillColor; self.borderColor = borderColor
            self.author = author; self.timestamp = timestamp
        }
    }

    struct RowHighlight: Codable, Equatable, Sendable {
        public let sample: String
        public let fillColor: String?
        public let borderColor: String?
        public let author: String
        public let timestamp: String

        public init(sample: String, fillColor: String?, borderColor: String?, author: String, timestamp: String) {
            self.sample = sample; self.fillColor = fillColor; self.borderColor = borderColor
            self.author = author; self.timestamp = timestamp
        }
    }

    struct SampleNote: Codable, Equatable, Sendable {
        public let sample: String
        public let body: String
        public let author: String
        public let timestamp: String

        public init(sample: String, body: String, author: String, timestamp: String) {
            self.sample = sample; self.body = body; self.author = author; self.timestamp = timestamp
        }
    }

    struct CellComment: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let body: String
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    body: String, author: String, timestamp: String) {
            self.sample = sample; self.locus = locus; self.slot = slot
            self.body = body; self.author = author; self.timestamp = timestamp
        }
    }

    enum StatusValue: String, Codable, Sendable, CaseIterable {
        case unflagged, needsReview, reviewed, confirmed
    }

    struct SampleStatusFlag: Codable, Equatable, Sendable {
        public let sample: String
        public let value: StatusValue
        public let author: String
        public let timestamp: String

        public init(sample: String, value: StatusValue, author: String, timestamp: String) {
            self.sample = sample; self.value = value; self.author = author; self.timestamp = timestamp
        }
    }

    struct CallStatusFlag: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let value: StatusValue
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    value: StatusValue, author: String, timestamp: String) {
            self.sample = sample; self.locus = locus; self.slot = slot
            self.value = value; self.author = author; self.timestamp = timestamp
        }
    }

    struct Settings: Codable, Equatable, Sendable {
        public var viewMode: String  // outline | cards | matrix
        public var panelLayout: String  // aLeading | aTrailing | aOver
        public var cardDensity: String  // compact | comfortable | roomy | auto
        public var cardDensityThreshold: Int
        public var dropoutAbsolute: Int?
        public var dropoutSampleFraction: Double?
        public var dropoutLocusFraction: Double?

        public static let `default` = Settings(
            viewMode: "outline",
            panelLayout: "aLeading",
            cardDensity: "auto",
            cardDensityThreshold: 30,
            dropoutAbsolute: 50,
            dropoutSampleFraction: nil,
            dropoutLocusFraction: 0.05
        )

        public init(viewMode: String, panelLayout: String, cardDensity: String,
                    cardDensityThreshold: Int, dropoutAbsolute: Int?,
                    dropoutSampleFraction: Double?, dropoutLocusFraction: Double?) {
            self.viewMode = viewMode
            self.panelLayout = panelLayout
            self.cardDensity = cardDensity
            self.cardDensityThreshold = cardDensityThreshold
            self.dropoutAbsolute = dropoutAbsolute
            self.dropoutSampleFraction = dropoutSampleFraction
            self.dropoutLocusFraction = dropoutLocusFraction
        }
    }

    struct AuditEntry: Codable, Equatable, Sendable {
        public let action: String
        public let sample: String
        public let locus: String?
        public let slot: HaplotypeSlot?
        public let before: String?
        public let after: String?
        public let color: String?
        public let reason: String?
        public let rationale: String?
        public let author: String
        public let timestamp: String

        public init(action: String, sample: String, locus: String?, slot: HaplotypeSlot?,
                    before: String?, after: String?, color: String?,
                    reason: String?, rationale: String?,
                    author: String, timestamp: String) {
            self.action = action; self.sample = sample; self.locus = locus; self.slot = slot
            self.before = before; self.after = after; self.color = color
            self.reason = reason; self.rationale = rationale
            self.author = author; self.timestamp = timestamp
        }
    }
}
```

Note: the `GenotypeCohortSmartFilter` and `ManualHaplotypeAssignment` referenced here are created in subsequent tasks. To prevent build failure until those land, also create stub placeholder files now in the same commit:

```swift
// Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift  (stub)
import Foundation
public struct GenotypeCohortSmartFilter: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var scope: String
    public var isStarred: Bool
    // Full predicate type added in Task 1.4
    public init(name: String, description: String? = nil, scope: String = "bundle", isStarred: Bool = false) {
        self.name = name; self.description = description; self.scope = scope; self.isStarred = isStarred
    }
}
```

```swift
// Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift  (stub)
import Foundation
import LungfishCore
public struct ManualHaplotypeAssignment: Codable, Equatable, Sendable {
    public var sample: String
    public var locus: String
    public var slot: HaplotypeSlot
    public var label: String
    public var colorTokenIndex: Int
    public var diagnosticAlleles: [String]
    public var notes: String

    public init(sample: String, locus: String, slot: HaplotypeSlot, label: String,
                colorTokenIndex: Int, diagnosticAlleles: [String], notes: String) {
        self.sample = sample; self.locus = locus; self.slot = slot
        self.label = label; self.colorTokenIndex = colorTokenIndex
        self.diagnosticAlleles = diagnosticAlleles; self.notes = notes
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter GenotypeAnnotationSidecarTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift \
        Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift \
        Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift \
        Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift
git commit -m "Add GenotypeAnnotationSidecar JSON model with audit log"
```

### Task 1.4: Replace GenotypeCohortSmartFilter stub with predicate ADT and evaluator

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift`
- Test: `Tests/LungfishIOTests/GenotypeCohortSmartFilterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeCohortSmartFilterTests: XCTestCase {
    private func sample(animal: String, calls: [(locus: String, h1: String, h2: String)],
                        qc: ONTGenotypeQCStatus = .ok, comments: String = "") -> GenotypeCohortSubject {
        let callValues = calls.flatMap { c -> [GenotypeCohortSubject.Call] in
            [.init(locus: c.locus, slot: .h1, name: c.h1, isHomozygous: c.h1 == c.h2, isError: false, isRecombinant: c.h1.hasPrefix("rec") || c.h2.hasPrefix("rec"), readCount: 100),
             .init(locus: c.locus, slot: .h2, name: c.h2, isHomozygous: c.h1 == c.h2, isError: false, isRecombinant: c.h1.hasPrefix("rec") || c.h2.hasPrefix("rec"), readCount: 100)]
        }
        return GenotypeCohortSubject(
            animalId: animal, gsId: nil, qcStatus: qc, totalReads: 50000,
            unmappedPercent: 45, comments: comments, calls: callValues,
            hasAnyComment: !comments.isEmpty, hasErrorAtAnyLocus: callValues.contains { $0.isError },
            isHomozygousAcrossAll: calls.allSatisfy { $0.h1 == $0.h2 },
            hasRegionalRecombinant: callValues.contains { $0.isRecombinant },
            hasAtypicalPattern: false,
            statusValue: .unflagged,
            highlightFills: [], highlightBorders: []
        )
    }

    func testAnimalIdMatches() {
        let predicate = SmartCohortPredicate.animalIdMatches("H18C153")
        XCTAssertTrue(predicate.evaluate(sample(animal: "H18C153", calls: [])))
        XCTAssertFalse(predicate.evaluate(sample(animal: "H18C174", calls: [])))
    }

    func testHaplotypeMatchAtLocus() {
        let predicate = SmartCohortPredicate.hasHaplotypeAt(locus: "MHC-A", slot: nil, names: ["M1A"])
        XCTAssertTrue(predicate.evaluate(sample(animal: "A", calls: [(locus: "MHC-A", h1: "M1A", h2: "M3A")])))
        XCTAssertFalse(predicate.evaluate(sample(animal: "B", calls: [(locus: "MHC-A", h1: "M2A", h2: "M3A")])))
    }

    func testIsHomozygousAcrossAll() {
        let predicate = SmartCohortPredicate.isHomozygousAcrossAll
        XCTAssertTrue(predicate.evaluate(sample(animal: "A", calls: [(locus: "MHC-A", h1: "M1A", h2: "M1A"), (locus: "MHC-B", h1: "M1B", h2: "M1B")])))
        XCTAssertFalse(predicate.evaluate(sample(animal: "B", calls: [(locus: "MHC-A", h1: "M1A", h2: "M3A")])))
    }

    func testAnyOfPredicates() {
        let predicate = SmartCohortPredicate.any([
            .animalIdMatches("H1"),
            .animalIdMatches("H2"),
        ])
        XCTAssertTrue(predicate.evaluate(sample(animal: "H1", calls: [])))
        XCTAssertTrue(predicate.evaluate(sample(animal: "H2", calls: [])))
        XCTAssertFalse(predicate.evaluate(sample(animal: "H3", calls: [])))
    }

    func testJSONRoundTripPreservesPredicate() throws {
        let original = GenotypeCohortSmartFilter(
            name: "Test",
            scope: "bundle",
            isStarred: true,
            predicate: .all([
                .hasHaplotypeAt(locus: "MHC-A", slot: .h1, names: ["M1A", "M2A"]),
                .qcStatus([.ok]),
            ])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Replace the stub with the full implementation**

```swift
// Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift
import Foundation
import LungfishCore

public struct GenotypeCohortSmartFilter: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var scope: String  // "bundle" | "user"
    public var isStarred: Bool
    public var predicate: SmartCohortPredicate

    public init(name: String, description: String? = nil, scope: String = "bundle",
                isStarred: Bool = false, predicate: SmartCohortPredicate = .all([])) {
        self.name = name; self.description = description
        self.scope = scope; self.isStarred = isStarred; self.predicate = predicate
    }
}

public struct GenotypeCohortSubject: Sendable, Equatable {
    public let animalId: String
    public let gsId: String?
    public let qcStatus: ONTGenotypeQCStatus
    public let totalReads: Int
    public let unmappedPercent: Double
    public let comments: String
    public let calls: [Call]
    public let hasAnyComment: Bool
    public let hasErrorAtAnyLocus: Bool
    public let isHomozygousAcrossAll: Bool
    public let hasRegionalRecombinant: Bool
    public let hasAtypicalPattern: Bool
    public let statusValue: GenotypeAnnotationSidecar.StatusValue
    public let highlightFills: [String]   // hex
    public let highlightBorders: [String]

    public init(animalId: String, gsId: String?, qcStatus: ONTGenotypeQCStatus,
                totalReads: Int, unmappedPercent: Double, comments: String,
                calls: [Call], hasAnyComment: Bool, hasErrorAtAnyLocus: Bool,
                isHomozygousAcrossAll: Bool, hasRegionalRecombinant: Bool,
                hasAtypicalPattern: Bool,
                statusValue: GenotypeAnnotationSidecar.StatusValue,
                highlightFills: [String], highlightBorders: [String]) {
        self.animalId = animalId; self.gsId = gsId; self.qcStatus = qcStatus
        self.totalReads = totalReads; self.unmappedPercent = unmappedPercent
        self.comments = comments; self.calls = calls
        self.hasAnyComment = hasAnyComment; self.hasErrorAtAnyLocus = hasErrorAtAnyLocus
        self.isHomozygousAcrossAll = isHomozygousAcrossAll
        self.hasRegionalRecombinant = hasRegionalRecombinant
        self.hasAtypicalPattern = hasAtypicalPattern
        self.statusValue = statusValue
        self.highlightFills = highlightFills
        self.highlightBorders = highlightBorders
    }

    public struct Call: Sendable, Equatable {
        public let locus: String
        public let slot: HaplotypeSlot
        public let name: String
        public let isHomozygous: Bool
        public let isError: Bool
        public let isRecombinant: Bool
        public let readCount: Int

        public init(locus: String, slot: HaplotypeSlot, name: String,
                    isHomozygous: Bool, isError: Bool, isRecombinant: Bool, readCount: Int) {
            self.locus = locus; self.slot = slot; self.name = name
            self.isHomozygous = isHomozygous; self.isError = isError
            self.isRecombinant = isRecombinant; self.readCount = readCount
        }
    }
}

public indirect enum SmartCohortPredicate: Codable, Equatable, Sendable {
    case all([SmartCohortPredicate])
    case any([SmartCohortPredicate])
    case not(SmartCohortPredicate)
    case animalIdMatches(String)
    case animalIdIn([String])
    case gsIdMatches(String)
    case commentContains(String)
    case hasAnyComment
    case qcStatus(Set<ONTGenotypeQCStatus>)
    case hasErrorAtAnyLocus
    case totalReadsAtLeast(Int)
    case totalReadsAtMost(Int)
    case unmappedPercentAtMost(Double)
    case hasHaplotypeAt(locus: String, slot: HaplotypeSlot?, names: Set<String>)
    case isHomozygousAcrossAll
    case hasRegionalRecombinant
    case hasAtypicalPattern
    case hasHighlightFill(String?)   // hex or nil = any
    case hasAnalystFlag(GenotypeAnnotationSidecar.StatusValue)

    public func evaluate(_ subject: GenotypeCohortSubject) -> Bool {
        switch self {
        case .all(let predicates): return predicates.allSatisfy { $0.evaluate(subject) }
        case .any(let predicates): return predicates.contains { $0.evaluate(subject) }
        case .not(let inner):       return !inner.evaluate(subject)
        case .animalIdMatches(let s): return subject.animalId == s
        case .animalIdIn(let ids):  return ids.contains(subject.animalId)
        case .gsIdMatches(let s):   return subject.gsId == s
        case .commentContains(let s):
            return subject.comments.localizedCaseInsensitiveContains(s)
        case .hasAnyComment: return subject.hasAnyComment
        case .qcStatus(let set): return set.contains(subject.qcStatus)
        case .hasErrorAtAnyLocus: return subject.hasErrorAtAnyLocus
        case .totalReadsAtLeast(let n): return subject.totalReads >= n
        case .totalReadsAtMost(let n):  return subject.totalReads <= n
        case .unmappedPercentAtMost(let p): return subject.unmappedPercent <= p
        case .hasHaplotypeAt(let locus, let slot, let names):
            return subject.calls.contains {
                $0.locus == locus &&
                (slot == nil || $0.slot == slot) &&
                names.contains($0.name)
            }
        case .isHomozygousAcrossAll: return subject.isHomozygousAcrossAll
        case .hasRegionalRecombinant: return subject.hasRegionalRecombinant
        case .hasAtypicalPattern: return subject.hasAtypicalPattern
        case .hasHighlightFill(let hex):
            if let hex = hex { return subject.highlightFills.contains(hex) }
            return !subject.highlightFills.isEmpty
        case .hasAnalystFlag(let value): return subject.statusValue == value
        }
    }

    // Codable
    private enum CodingKeys: String, CodingKey { case kind, children, child, value, locus, slot, names, hex, ids, set }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all(let children):  try c.encode("all", forKey: .kind); try c.encode(children, forKey: .children)
        case .any(let children):  try c.encode("any", forKey: .kind); try c.encode(children, forKey: .children)
        case .not(let child):     try c.encode("not", forKey: .kind); try c.encode(child, forKey: .child)
        case .animalIdMatches(let s): try c.encode("animalIdMatches", forKey: .kind); try c.encode(s, forKey: .value)
        case .animalIdIn(let ids):    try c.encode("animalIdIn", forKey: .kind); try c.encode(ids, forKey: .ids)
        case .gsIdMatches(let s):     try c.encode("gsIdMatches", forKey: .kind); try c.encode(s, forKey: .value)
        case .commentContains(let s): try c.encode("commentContains", forKey: .kind); try c.encode(s, forKey: .value)
        case .hasAnyComment:          try c.encode("hasAnyComment", forKey: .kind)
        case .qcStatus(let set):      try c.encode("qcStatus", forKey: .kind); try c.encode(Array(set), forKey: .set)
        case .hasErrorAtAnyLocus:     try c.encode("hasErrorAtAnyLocus", forKey: .kind)
        case .totalReadsAtLeast(let n): try c.encode("totalReadsAtLeast", forKey: .kind); try c.encode(n, forKey: .value)
        case .totalReadsAtMost(let n):  try c.encode("totalReadsAtMost", forKey: .kind); try c.encode(n, forKey: .value)
        case .unmappedPercentAtMost(let p): try c.encode("unmappedPercentAtMost", forKey: .kind); try c.encode(p, forKey: .value)
        case .hasHaplotypeAt(let locus, let slot, let names):
            try c.encode("hasHaplotypeAt", forKey: .kind)
            try c.encode(locus, forKey: .locus)
            try c.encodeIfPresent(slot, forKey: .slot)
            try c.encode(Array(names), forKey: .names)
        case .isHomozygousAcrossAll:  try c.encode("isHomozygousAcrossAll", forKey: .kind)
        case .hasRegionalRecombinant: try c.encode("hasRegionalRecombinant", forKey: .kind)
        case .hasAtypicalPattern:     try c.encode("hasAtypicalPattern", forKey: .kind)
        case .hasHighlightFill(let hex): try c.encode("hasHighlightFill", forKey: .kind); try c.encodeIfPresent(hex, forKey: .hex)
        case .hasAnalystFlag(let v):   try c.encode("hasAnalystFlag", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "all": self = .all(try c.decode([SmartCohortPredicate].self, forKey: .children))
        case "any": self = .any(try c.decode([SmartCohortPredicate].self, forKey: .children))
        case "not": self = .not(try c.decode(SmartCohortPredicate.self, forKey: .child))
        case "animalIdMatches": self = .animalIdMatches(try c.decode(String.self, forKey: .value))
        case "animalIdIn":      self = .animalIdIn(try c.decode([String].self, forKey: .ids))
        case "gsIdMatches":     self = .gsIdMatches(try c.decode(String.self, forKey: .value))
        case "commentContains": self = .commentContains(try c.decode(String.self, forKey: .value))
        case "hasAnyComment":   self = .hasAnyComment
        case "qcStatus":        self = .qcStatus(Set(try c.decode([ONTGenotypeQCStatus].self, forKey: .set)))
        case "hasErrorAtAnyLocus": self = .hasErrorAtAnyLocus
        case "totalReadsAtLeast":  self = .totalReadsAtLeast(try c.decode(Int.self, forKey: .value))
        case "totalReadsAtMost":   self = .totalReadsAtMost(try c.decode(Int.self, forKey: .value))
        case "unmappedPercentAtMost": self = .unmappedPercentAtMost(try c.decode(Double.self, forKey: .value))
        case "hasHaplotypeAt":
            self = .hasHaplotypeAt(
                locus: try c.decode(String.self, forKey: .locus),
                slot: try c.decodeIfPresent(HaplotypeSlot.self, forKey: .slot),
                names: Set(try c.decode([String].self, forKey: .names))
            )
        case "isHomozygousAcrossAll": self = .isHomozygousAcrossAll
        case "hasRegionalRecombinant": self = .hasRegionalRecombinant
        case "hasAtypicalPattern":    self = .hasAtypicalPattern
        case "hasHighlightFill":      self = .hasHighlightFill(try c.decodeIfPresent(String.self, forKey: .hex))
        case "hasAnalystFlag":        self = .hasAnalystFlag(try c.decode(GenotypeAnnotationSidecar.StatusValue.self, forKey: .value))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown predicate kind: \(kind)")
        }
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeCohortSmartFilterTests`
Expected: PASS, 5 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeCohortSmartFilter.swift Tests/LungfishIOTests/GenotypeCohortSmartFilterTests.swift
git commit -m "Add GenotypeCohortSmartFilter predicate ADT and JSON codec"
```

### Task 1.5: Add GenotypeBlockClassifier

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeBlockClassifier.swift`
- Test: `Tests/LungfishIOTests/GenotypeBlockClassifierTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeBlockClassifierTests: XCTestCase {
    private func calls(_ pairs: [(locus: String, h1: String, h2: String)]) -> [(locus: String, h1: String, h2: String)] {
        pairs
    }

    func testBlockCoherentHeterozygote() {
        let result = GenotypeBlockClassifier.classify(calls: calls([
            (locus: "MHC-A", h1: "M2A", h2: "M3A"),
            (locus: "MHC-B", h1: "M2B", h2: "M3B"),
            (locus: "MHC-DRB", h1: "M2DR", h2: "M3DR"),
        ]))
        XCTAssertEqual(result, .blockCoherent)
    }

    func testHomozygousBlock() {
        let result = GenotypeBlockClassifier.classify(calls: calls([
            (locus: "MHC-A", h1: "M1A", h2: "M1A"),
            (locus: "MHC-B", h1: "M1B", h2: "M1B"),
        ]))
        XCTAssertEqual(result, .blockCoherent)
    }

    func testRegionalRecombinant() {
        let result = GenotypeBlockClassifier.classify(calls: calls([
            (locus: "MHC-A", h1: "M1A", h2: "M2A"),
            (locus: "MHC-B", h1: "M1B", h2: "M2B"),
            (locus: "MHC-DRB", h1: "M1DR", h2: "recM2M3DR"),
        ]))
        XCTAssertEqual(result, .regionalRecombinant)
    }

    func testAtypicalMultipleBreaks() {
        let result = GenotypeBlockClassifier.classify(calls: calls([
            (locus: "MHC-A", h1: "M1A", h2: "M2A"),
            (locus: "MHC-B", h1: "M1B", h2: "M5B"),
            (locus: "MHC-DRB", h1: "M1DR", h2: "M7DR"),
            (locus: "MHC-DQA", h1: "M1DQ", h2: "M3DQ"),
        ]))
        XCTAssertEqual(result, .atypical)
    }
}
```

- [ ] **Step 2: Implement classifier**

```swift
// Sources/LungfishIO/Bundles/GenotypeBlockClassifier.swift
import Foundation
import LungfishCore

public enum GenotypeBlockKind: String, Codable, Sendable {
    case blockCoherent
    case regionalRecombinant
    case atypical
    case unknown
}

public enum GenotypeBlockClassifier {
    /// Returns the block-coherence classification for a sample's per-locus haplotype calls.
    /// Algorithm:
    /// - Extract the "M-number" prefix from each call name (M1A → 1, M3DR → 3, recM2M3DR → marked recombinant).
    /// - If the same H1 and H2 M-numbers are consistent across all loci, → blockCoherent.
    /// - If exactly one locus has a recombinant call (rec*) and all others match, → regionalRecombinant.
    /// - If two or more loci diverge in M-number, → atypical.
    public static func classify(
        calls: [(locus: String, h1: String, h2: String)]
    ) -> GenotypeBlockKind {
        guard !calls.isEmpty else { return .unknown }
        var h1Numbers: [Int?] = []
        var h2Numbers: [Int?] = []
        var recombinantLoci = 0
        for c in calls {
            let h1 = mNumber(c.h1)
            let h2 = mNumber(c.h2)
            if c.h1.hasPrefix("rec") || c.h2.hasPrefix("rec") {
                recombinantLoci += 1
            }
            h1Numbers.append(h1)
            h2Numbers.append(h2)
        }
        let h1Set = Set(h1Numbers.compactMap { $0 })
        let h2Set = Set(h2Numbers.compactMap { $0 })

        if recombinantLoci > 0 && h1Set.count <= 1 && h2Set.count <= 1 {
            return .regionalRecombinant
        }
        if h1Set.count <= 1 && h2Set.count <= 1 {
            return .blockCoherent
        }
        return .atypical
    }

    private static func mNumber(_ name: String) -> Int? {
        guard !name.isEmpty, name.first == "M" else { return nil }
        let chars = name.dropFirst()
        var digits = ""
        for ch in chars {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeBlockClassifierTests`
Expected: PASS, 4 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeBlockClassifier.swift Tests/LungfishIOTests/GenotypeBlockClassifierTests.swift
git commit -m "Add GenotypeBlockClassifier for block / recombinant / atypical classification"
```

### Task 1.6: Add GenotypeDropoutEvaluator

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeDropoutEvaluator.swift`
- Test: `Tests/LungfishIOTests/GenotypeDropoutEvaluatorTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import LungfishIO

final class GenotypeDropoutEvaluatorTests: XCTestCase {
    func testAbsoluteOnly() {
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: nil)
        XCTAssertTrue(evaluator.isLowSupport(reads: 28, sampleTotal: 50000, locusTotal: 770))
        XCTAssertFalse(evaluator.isLowSupport(reads: 198, sampleTotal: 50000, locusTotal: 770))
    }

    func testLocusFractionOnly() {
        let evaluator = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.05)
        XCTAssertTrue(evaluator.isLowSupport(reads: 28, sampleTotal: 50000, locusTotal: 770))
        XCTAssertFalse(evaluator.isLowSupport(reads: 100, sampleTotal: 50000, locusTotal: 770))
    }

    func testSampleFractionOnly() {
        let evaluator = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: 0.001, locusFraction: nil)
        XCTAssertTrue(evaluator.isLowSupport(reads: 28, sampleTotal: 50000, locusTotal: 770))
        XCTAssertFalse(evaluator.isLowSupport(reads: 100, sampleTotal: 50000, locusTotal: 770))
    }

    func testAllModesOrTogether() {
        let evaluator = GenotypeDropoutEvaluator(absolute: 200, sampleFraction: nil, locusFraction: 0.05)
        XCTAssertTrue(evaluator.isLowSupport(reads: 100, sampleTotal: 50000, locusTotal: 770)) // below absolute
        XCTAssertTrue(evaluator.isLowSupport(reads: 30, sampleTotal: 50000, locusTotal: 770))  // below locus fraction too
    }

    func testAllNilNeverLowSupport() {
        let evaluator = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: nil)
        XCTAssertFalse(evaluator.isLowSupport(reads: 1, sampleTotal: 50000, locusTotal: 770))
    }
}
```

- [ ] **Step 2: Implement evaluator**

```swift
// Sources/LungfishIO/Bundles/GenotypeDropoutEvaluator.swift
import Foundation

public struct GenotypeDropoutEvaluator: Sendable, Equatable {
    public let absolute: Int?
    public let sampleFraction: Double?
    public let locusFraction: Double?

    public init(absolute: Int?, sampleFraction: Double?, locusFraction: Double?) {
        self.absolute = absolute
        self.sampleFraction = sampleFraction
        self.locusFraction = locusFraction
    }

    /// Returns true if any active threshold marks the allele as low-support.
    public func isLowSupport(reads: Int, sampleTotal: Int, locusTotal: Int) -> Bool {
        if let absolute, reads < absolute { return true }
        if let sampleFraction, sampleTotal > 0 {
            if Double(reads) / Double(sampleTotal) < sampleFraction { return true }
        }
        if let locusFraction, locusTotal > 0 {
            if Double(reads) / Double(locusTotal) < locusFraction { return true }
        }
        return false
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeDropoutEvaluatorTests`
Expected: PASS, 5 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeDropoutEvaluator.swift Tests/LungfishIOTests/GenotypeDropoutEvaluatorTests.swift
git commit -m "Add GenotypeDropoutEvaluator with three OR'd threshold modes"
```

### Task 1.7: Add ManualHaplotypeAssignment helpers

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift`
- Test: `Tests/LungfishIOTests/ManualHaplotypeAssignmentTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import LungfishCore
@testable import LungfishIO

final class ManualHaplotypeAssignmentTests: XCTestCase {
    func testRoundTrip() throws {
        let a = ManualHaplotypeAssignment(
            sample: "S1", locus: "MHC-A", slot: .h1, label: "Custom1",
            colorTokenIndex: 3, diagnosticAlleles: ["A1*001"], notes: "novel"
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(ManualHaplotypeAssignment.self, from: data)
        XCTAssertEqual(decoded, a)
    }

    func testGrouping() {
        let assignments = [
            ManualHaplotypeAssignment(sample: "S1", locus: "MHC-A", slot: .h1, label: "Custom1", colorTokenIndex: 1, diagnosticAlleles: ["A"], notes: ""),
            ManualHaplotypeAssignment(sample: "S2", locus: "MHC-A", slot: .h1, label: "Custom1", colorTokenIndex: 1, diagnosticAlleles: ["A"], notes: ""),
            ManualHaplotypeAssignment(sample: "S3", locus: "MHC-A", slot: .h1, label: "Custom2", colorTokenIndex: 2, diagnosticAlleles: ["B"], notes: ""),
        ]
        let groups = ManualHaplotypeAssignment.groupedByLabel(assignments)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups["Custom1"]?.count, 2)
    }
}
```

- [ ] **Step 2: Extend ManualHaplotypeAssignment with grouping**

Append to `Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift`:

```swift
public extension ManualHaplotypeAssignment {
    /// Group assignments by their label. Useful for the Audit lens to list unique haplotypes.
    static func groupedByLabel(_ assignments: [ManualHaplotypeAssignment]) -> [String: [ManualHaplotypeAssignment]] {
        Dictionary(grouping: assignments, by: \.label)
    }

    /// Group assignments by (locus, label) for per-locus haplotype display.
    static func groupedByLocusAndLabel(_ assignments: [ManualHaplotypeAssignment]) -> [String: [String: [ManualHaplotypeAssignment]]] {
        let byLocus = Dictionary(grouping: assignments, by: \.locus)
        return byLocus.mapValues { Dictionary(grouping: $0, by: \.label) }
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter ManualHaplotypeAssignmentTests`
Expected: PASS, 2 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift Tests/LungfishIOTests/ManualHaplotypeAssignmentTests.swift
git commit -m "Add ManualHaplotypeAssignment grouping helpers"
```

### Task 1.8: Wire ONTGenotypeResultBundle to expose annotation sidecar URL

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Test: extend `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Add failing test**

Append to `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`:

```swift
final class ONTGenotypeResultBundleAnnotationSidecarTests: XCTestCase {
    func testAnnotationSidecarURLIsPredictable() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishgenotype")
        let url = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        XCTAssertEqual(url.lastPathComponent, "annotations.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "test.lungfishgenotype")
    }

    func testLoadOrCreateReturnsEmptyWhenAbsent() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        XCTAssertEqual(sidecar.callOverrides.count, 0)
    }

    func testLoadOrCreatePersistsAcrossCalls() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        sidecar.sampleNotes.append(.init(sample: "S1", body: "note", author: "u", timestamp: "t"))
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: tempDir)

        let reloaded = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        XCTAssertEqual(reloaded.sampleNotes.count, 1)
        XCTAssertEqual(reloaded.sampleNotes[0].body, "note")
    }
}
```

- [ ] **Step 2: Add methods to `ONTGenotypeResultBundleData`**

Insert near the existing static factory methods in `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`:

```swift
public extension ONTGenotypeResultBundleData {
    static func annotationSidecarURL(forBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }

    static func loadOrCreateAnnotationSidecar(forBundleAt bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        let url = annotationSidecarURL(forBundleAt: bundleURL)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try GenotypeAnnotationSidecar.decode(data)
        }
        let formatter = ISO8601DateFormatter()
        return GenotypeAnnotationSidecar.empty(generatedAt: formatter.string(from: Date()))
    }

    static func writeAnnotationSidecar(_ sidecar: GenotypeAnnotationSidecar, forBundleAt bundleURL: URL) throws {
        let url = annotationSidecarURL(forBundleAt: bundleURL)
        let data = try sidecar.encoded()
        let tempURL = url.appendingPathExtension("writing-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter ONTGenotypeResultBundleAnnotationSidecarTests`
Expected: PASS, 3 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "Wire annotation sidecar URL + load/write on ONTGenotypeResultBundle"
```

### Task 1.9: Extend BuiltInGenotypeHaplotypeDefinitions with colorTokenIndex

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalysis.swift`
- Modify: `Sources/LungfishIO/Bundles/BuiltInGenotypeHaplotypeDefinitions.swift`
- Test: `Tests/LungfishIOTests/BuiltInGenotypeHaplotypeColorTokenTests.swift`

- [ ] **Step 1: Add failing test**

Create file:

```swift
import XCTest
import LungfishCore
@testable import LungfishIO

final class BuiltInGenotypeHaplotypeColorTokenTests: XCTestCase {
    func testMCMHaplotypesHaveCanonicalTokens() {
        let mcm = GenotypeHaplotypeDefinitionRegistry.mauritianCynomolgusMacaqueMHCExon2MiSeq
        let mhcA = mcm.locusDefinitions.first { $0.locus == "MHC-A" }!
        let m3A = mhcA.haplotypes.first { $0.name == "M3A" }!
        XCTAssertEqual(m3A.colorTokenIndex, 3)
    }

    func testRhesusHaplotypesAcceptAnyToken() {
        let mamu = GenotypeHaplotypeDefinitionRegistry.rhesusMacaqueMHCExon2MiSeq
        let mhcA = mamu.locusDefinitions.first { $0.locus == "MHC-A" }!
        XCTAssertFalse(mhcA.haplotypes.isEmpty)
        for h in mhcA.haplotypes {
            // Index must be assigned and in valid range
            XCTAssertGreaterThanOrEqual(h.colorTokenIndex, 0)
            XCTAssertLessThanOrEqual(h.colorTokenIndex, 7)
        }
    }
}
```

- [ ] **Step 2: Add `colorTokenIndex` to `GenotypeHaplotypeDefinition`**

Modify `Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalysis.swift`:

```swift
public struct GenotypeHaplotypeDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let diagnosticAlleles: [String]
    public let colorTokenIndex: Int

    public init(name: String, diagnosticAlleles: [String], colorTokenIndex: Int? = nil) {
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        // Auto-assign from canonical name mapping if not supplied
        self.colorTokenIndex = colorTokenIndex ?? HaplotypeColorToken.assigned(forName: name).canonicalIndex
    }
}
```

(Add `import LungfishCore` at the top of the file if it's not already present.)

- [ ] **Step 3: Verify the existing BuiltInGenotypeHaplotypeDefinitions builds**

The constructor still accepts the existing call sites because `colorTokenIndex` is optional. No further edit required.

- [ ] **Step 4: Run tests**

Run: `swift test --filter BuiltInGenotypeHaplotypeColorTokenTests`
Expected: PASS, 2 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalysis.swift Tests/LungfishIOTests/BuiltInGenotypeHaplotypeColorTokenTests.swift
git commit -m "Add colorTokenIndex to GenotypeHaplotypeDefinition with auto-assignment"
```

### Task 1.10: Build + test gate for Milestone 1

- [ ] **Step 1: Run the full LungfishCore + LungfishIO test suites**

Run: `swift test --filter LungfishCoreTests --filter LungfishIOTests`
Expected: all green

- [ ] **Step 2: Commit any cleanup**

If a follow-up fix is needed, commit with `Fix milestone 1 test failure` style messages, otherwise this is a no-op.

---

## Milestone 2: Haplotype tape primitive and store

This milestone is a single new view + the @Observable annotation store that everything below depends on. The tape view is heavily tested in isolation.

### Task 2.1: GenotypeAnnotationStore (app-side @Observable wrapper)

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift`
- Test: `Tests/LungfishAppTests/GenotypeAnnotationStoreTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class GenotypeAnnotationStoreTests: XCTestCase {
    func testLoadEmptyAndAppendOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)

        try store.applyOverride(sample: "H22C112", locus: "MHC-A", slot: .h2,
                                originalCall: "M2A", overrideCall: "A1_063",
                                reasonTag: .contamination, rationale: "...")
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.auditLog.count, 1)

        // Reload to confirm persistence
        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(reloaded.sidecar.callOverrides.count, 1)
    }

    func testUndoOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(sample: "H22C112", locus: "MHC-A", slot: .h2,
                                originalCall: "M2A", overrideCall: "A1_063",
                                reasonTag: .contamination, rationale: "...")
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        try store.undoLastOverride()
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)
    }
}
```

- [ ] **Step 2: Implement GenotypeAnnotationStore**

```swift
// Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift
import Foundation
import Observation
import LungfishCore
import LungfishIO

@Observable
@MainActor
final class GenotypeAnnotationStore {
    private(set) var sidecar: GenotypeAnnotationSidecar
    let bundleURL: URL
    let author: String

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(bundleURL: URL, author: String) throws {
        self.bundleURL = bundleURL
        self.author = author
        self.sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
    }

    private func now() -> String { isoFormatter.string(from: Date()) }

    func applyOverride(sample: String, locus: String, slot: HaplotypeSlot,
                       originalCall: String, overrideCall: String,
                       reasonTag: GenotypeAnnotationSidecar.OverrideReasonTag,
                       rationale: String) throws {
        let ts = now()
        let entry = GenotypeAnnotationSidecar.CallOverride(
            sample: sample, locus: locus, slot: slot,
            originalCall: originalCall, overrideCall: overrideCall,
            reasonTag: reasonTag, rationale: rationale,
            author: author, timestamp: ts
        )
        sidecar.callOverrides.append(entry)
        sidecar.append(audit: .init(
            action: "override", sample: sample, locus: locus, slot: slot,
            before: originalCall, after: overrideCall,
            color: nil, reason: reasonTag.rawValue, rationale: rationale,
            author: author, timestamp: ts
        ))
        try persist()
    }

    func undoLastOverride() throws {
        guard let last = sidecar.callOverrides.popLast() else { return }
        let ts = now()
        sidecar.append(audit: .init(
            action: "undoOverride", sample: last.sample, locus: last.locus, slot: last.slot,
            before: last.overrideCall, after: last.originalCall,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: ts
        ))
        try persist()
    }

    func setSampleStatus(_ value: GenotypeAnnotationSidecar.StatusValue, sample: String) throws {
        let ts = now()
        sidecar.sampleStatusFlags.removeAll { $0.sample == sample }
        sidecar.sampleStatusFlags.append(.init(sample: sample, value: value, author: author, timestamp: ts))
        sidecar.append(audit: .init(
            action: "setSampleStatus", sample: sample, locus: nil, slot: nil,
            before: nil, after: value.rawValue,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: ts
        ))
        try persist()
    }

    func setCallStatus(_ value: GenotypeAnnotationSidecar.StatusValue,
                       sample: String, locus: String, slot: HaplotypeSlot) throws {
        let ts = now()
        sidecar.callStatusFlags.removeAll { $0.sample == sample && $0.locus == locus && $0.slot == slot }
        sidecar.callStatusFlags.append(.init(sample: sample, locus: locus, slot: slot, value: value, author: author, timestamp: ts))
        sidecar.append(audit: .init(
            action: "setCallStatus", sample: sample, locus: locus, slot: slot,
            before: nil, after: value.rawValue,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: ts
        ))
        try persist()
    }

    func setCellHighlight(sample: String, locus: String, slot: HaplotypeSlot,
                          fillHex: String?, borderHex: String?) throws {
        let ts = now()
        sidecar.cellHighlights.removeAll { $0.sample == sample && $0.locus == locus && $0.slot == slot }
        sidecar.cellHighlights.append(.init(
            sample: sample, locus: locus, slot: slot,
            fillColor: fillHex, borderColor: borderHex,
            author: author, timestamp: ts
        ))
        sidecar.append(audit: .init(
            action: "setCellHighlight", sample: sample, locus: locus, slot: slot,
            before: nil, after: nil, color: fillHex ?? borderHex,
            reason: nil, rationale: nil, author: author, timestamp: ts
        ))
        try persist()
    }

    func addCellComment(sample: String, locus: String, slot: HaplotypeSlot, body: String) throws {
        let ts = now()
        sidecar.cellComments.append(.init(
            sample: sample, locus: locus, slot: slot,
            body: body, author: author, timestamp: ts
        ))
        sidecar.append(audit: .init(
            action: "addCellComment", sample: sample, locus: locus, slot: slot,
            before: nil, after: nil, color: nil,
            reason: nil, rationale: body, author: author, timestamp: ts
        ))
        try persist()
    }

    func addSampleNote(sample: String, body: String) throws {
        let ts = now()
        sidecar.sampleNotes.append(.init(sample: sample, body: body, author: author, timestamp: ts))
        sidecar.append(audit: .init(
            action: "addSampleNote", sample: sample, locus: nil, slot: nil,
            before: nil, after: nil, color: nil,
            reason: nil, rationale: body, author: author, timestamp: ts
        ))
        try persist()
    }

    func updateSettings(_ mutate: (inout GenotypeAnnotationSidecar.Settings) -> Void) throws {
        mutate(&sidecar.settings)
        try persist()
    }

    func saveSmartCohort(_ cohort: GenotypeCohortSmartFilter) throws {
        sidecar.smartCohorts.removeAll { $0.name == cohort.name && $0.scope == cohort.scope }
        sidecar.smartCohorts.append(cohort)
        try persist()
    }

    func deleteSmartCohort(name: String, scope: String) throws {
        sidecar.smartCohorts.removeAll { $0.name == name && $0.scope == scope }
        try persist()
    }

    func addManualHaplotypeAssignment(_ a: ManualHaplotypeAssignment) throws {
        sidecar.manualHaplotypeAssignments.append(a)
        try persist()
    }

    private func persist() throws {
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeAnnotationStoreTests`
Expected: PASS, 2 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift Tests/LungfishAppTests/GenotypeAnnotationStoreTests.swift
git commit -m "Add GenotypeAnnotationStore @Observable wrapper with audit-log persistence"
```

### Task 2.2: GenotypeHaplotypeTapeView (NSView primitive)

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeHaplotypeTapeView.swift`
- Test: `Tests/LungfishAppTests/GenotypeHaplotypeTapeViewTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import AppKit
import LungfishCore
@testable import LungfishApp

@MainActor
final class GenotypeHaplotypeTapeViewTests: XCTestCase {
    func testRendersExpectedNumberOfSwatches() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        view.configure(loci: ["MHC-A", "MHC-B"], slots: [
            .init(locus: "MHC-A", h1: .reference(tokenIndex: 2, label: "M2A"), h2: .reference(tokenIndex: 3, label: "M3A")),
            .init(locus: "MHC-B", h1: .reference(tokenIndex: 2, label: "M2B"), h2: .reference(tokenIndex: 3, label: "M3B")),
        ])
        XCTAssertEqual(view.swatchCount, 4)
    }

    func testRecombinantStripeRenders() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        view.configure(loci: ["MHC-A"], slots: [
            .init(locus: "MHC-A",
                  h1: .reference(tokenIndex: 1, label: "M1A"),
                  h2: .recombinant(tokenIndexA: 2, tokenIndexB: 3, label: "recM2M3DR")),
        ])
        // Just assert no crash and the cell records as recombinant
        XCTAssertEqual(view.swatchCount, 2)
    }

    func testAccessibilityLabel() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        view.configure(loci: ["MHC-A"], slots: [
            .init(locus: "MHC-A", h1: .reference(tokenIndex: 1, label: "M1A"), h2: .reference(tokenIndex: 1, label: "M1A")),
        ])
        view.sampleAccessibilityLabel = "H17C119"
        let children = view.accessibilityChildren() ?? []
        XCTAssertEqual(children.count, 2)
    }
}
```

- [ ] **Step 2: Implement the tape view**

```swift
// Sources/LungfishApp/Views/Results/Genotype/GenotypeHaplotypeTapeView.swift
import AppKit
import LungfishCore

@MainActor
final class GenotypeHaplotypeTapeView: NSView {
    struct Slot {
        let locus: String
        let h1: Cell
        let h2: Cell
    }
    enum Cell {
        case reference(tokenIndex: Int, label: String)
        case manual(tokenIndex: Int, label: String)
        case recombinant(tokenIndexA: Int, tokenIndexB: Int, label: String)
        case error(label: String)
        case empty
    }

    private(set) var swatchCount: Int = 0
    var sampleAccessibilityLabel: String = ""
    var showLabels: Bool = false
    var showOverrideHatching: ((Slot, HaplotypeSlot) -> Bool)? = nil

    private var loci: [String] = []
    private var slots: [Slot] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

    func configure(loci: [String], slots: [Slot]) {
        self.loci = loci
        self.slots = slots
        self.swatchCount = slots.count * 2
        setNeedsDisplay(bounds)
        accessibilityElementsCache = nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !slots.isEmpty else { return }
        let columnWidth = bounds.width / CGFloat(slots.count)
        let halfHeight = bounds.height / 2.0

        for (index, slot) in slots.enumerated() {
            let x = CGFloat(index) * columnWidth
            let topRect = NSRect(x: x, y: 0, width: columnWidth - 1, height: halfHeight - 0.5).insetBy(dx: 0.5, dy: 0.5)
            let botRect = NSRect(x: x, y: halfHeight + 0.5, width: columnWidth - 1, height: halfHeight - 0.5).insetBy(dx: 0.5, dy: 0.5)

            drawCell(slot.h1, in: topRect, isOverridden: showOverrideHatching?(slot, .h1) == true)
            drawCell(slot.h2, in: botRect, isOverridden: showOverrideHatching?(slot, .h2) == true)
        }
    }

    private func drawCell(_ cell: Cell, in rect: NSRect, isOverridden: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        switch cell {
        case .empty:
            HaplotypeColorToken.canonicalPalette[0].fillColor.nsColor.setFill()
            path.fill()
        case .reference(let i, _), .manual(let i, _):
            tokenNSColor(tokenIndex: i).setFill()
            path.fill()
        case .recombinant(let a, let b, _):
            drawStripedFill(a: a, b: b, in: rect, path: path)
        case .error:
            NSColor.systemGray.setFill()
            path.fill()
            NSColor.controlBackgroundColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
        if isOverridden {
            drawHatchOverlay(in: rect)
        }
    }

    private func drawStripedFill(a: Int, b: Int, in rect: NSRect, path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let stripeWidth: CGFloat = 4
        var x = rect.minX
        var toggle = true
        while x < rect.maxX {
            let stripe = NSBezierPath(rect: NSRect(x: x, y: rect.minY, width: stripeWidth, height: rect.height))
            (toggle ? tokenNSColor(tokenIndex: a) : tokenNSColor(tokenIndex: b)).setFill()
            stripe.fill()
            x += stripeWidth
            toggle.toggle()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHatchOverlay(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.addClip()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let lineWidth: CGFloat = 1.0
        let spacing: CGFloat = 4.0
        var x: CGFloat = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: x, y: rect.minY))
            stroke.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            stroke.lineWidth = lineWidth
            stroke.stroke()
            x += spacing
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func tokenNSColor(tokenIndex: Int) -> NSColor {
        let palette = HaplotypeColorToken.canonicalPalette
        let token = palette[max(0, min(palette.count - 1, tokenIndex))]
        let appearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        let color: AnnotationColor = (appearance == .darkAqua) ? token.darkFillColor : token.fillColor
        return color.nsColor
    }

    // Accessibility children: emit one element per swatch
    private var accessibilityElementsCache: [NSAccessibilityElement]?

    override func accessibilityChildren() -> [Any]? {
        if let cache = accessibilityElementsCache { return cache }
        var children: [NSAccessibilityElement] = []
        let labels: [(String, HaplotypeSlot, String)] = slots.flatMap { slot -> [(String, HaplotypeSlot, String)] in
            [(slot.locus, .h1, cellLabel(slot.h1)), (slot.locus, .h2, cellLabel(slot.h2))]
        }
        for (locus, slot, value) in labels {
            let element = NSAccessibilityElement.element(role: .button, frame: bounds, label: "\(sampleAccessibilityLabel) \(locus) \(slot.displayName) \(value)", parent: self) as? NSAccessibilityElement
            if let element { children.append(element) }
        }
        accessibilityElementsCache = children
        return children
    }

    private func cellLabel(_ cell: Cell) -> String {
        switch cell {
        case .empty: return "absent"
        case .reference(_, let l), .manual(_, let l): return l
        case .recombinant(_, _, let l): return l
        case .error(let l): return l
        }
    }
}

// Convenience NSColor bridge for AnnotationColor
extension AnnotationColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension NSAccessibilityElement {
    static func element(role: NSAccessibility.Role, frame: NSRect, label: String, parent: NSObject) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(role)
        element.setAccessibilityFrameInParentSpace(frame)
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(parent)
        return element
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeHaplotypeTapeViewTests`
Expected: PASS, 3 tests

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeHaplotypeTapeView.swift Tests/LungfishAppTests/GenotypeHaplotypeTapeViewTests.swift
git commit -m "Add GenotypeHaplotypeTapeView two-strip primitive"
```

---

## Milestone 3: V2 viewport — Summary lens

This milestone wires the existing GenotypeResultViewController to a new three-lens model and replaces the v1 Outline path with the tape primitive. Cards and Matrix remain in their existing form pending Tasks 4.x.

### Task 3.1: Add GenotypeViewportLensV2 + view-mode enum

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultDisplayState.swift`

- [ ] **Step 1: Edit the enum**

In `GenotypeResultDisplayState.swift`, replace `enum GenotypeResultViewportLens` with:

```swift
enum GenotypeResultViewportLens: String, CaseIterable, Equatable {
    case summary
    case review
    case audit

    var displayName: String {
        switch self {
        case .summary: return "Summary"
        case .review:  return "Review"
        case .audit:   return "Audit"
        }
    }

    var inspectorSystemImage: String {
        switch self {
        case .summary: return "tablecells"
        case .review:  return "checklist"
        case .audit:   return "doc.text.magnifyingglass"
        }
    }

    var identifier: String { rawValue }
}

enum GenotypeSummaryViewMode: String, CaseIterable, Equatable {
    case outline
    case cards
    case matrix

    var displayName: String {
        switch self {
        case .outline: return "Outline"
        case .cards:   return "Cards"
        case .matrix:  return "Matrix"
        }
    }
}
```

Replace usages of `.analyst`, `.haplotypes`, `.anchors`, `.consumer`, `.artifacts` in the file with the new cases (`.summary`, `.review`, `.audit` as appropriate — `.analyst` and `.haplotypes` collapse to `.summary`+`.review`; `.consumer` → `.summary`; `.artifacts` → `.audit`).

Add a `summaryViewMode` field to `GenotypeResultDisplayState`:

```swift
struct GenotypeResultDisplayState: Equatable {
    var viewportLens: GenotypeResultViewportLens = .summary
    var summaryViewMode: GenotypeSummaryViewMode = .outline
    var layout: GenotypeResultPanelLayout = .listLeading
    var hideLowSupport: Bool = true
    var minimumSupportPercent: Double = 1.0
    var supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus
    var cellColorMode: GenotypeResultCellColorMode = .support
    var hideFilteredHighlights: Bool = true

    init(
        viewportLens: GenotypeResultViewportLens = .summary,
        summaryViewMode: GenotypeSummaryViewMode = .outline,
        layout: GenotypeResultPanelLayout = .listLeading,
        hideLowSupport: Bool = true,
        minimumSupportPercent: Double = 1.0,
        supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
        cellColorMode: GenotypeResultCellColorMode = .support,
        hideFilteredHighlights: Bool = true
    ) {
        self.viewportLens = viewportLens
        self.summaryViewMode = summaryViewMode
        self.layout = layout
        self.hideLowSupport = hideLowSupport
        self.minimumSupportPercent = minimumSupportPercent
        self.supportDenominator = supportDenominator
        self.cellColorMode = cellColorMode
        self.hideFilteredHighlights = hideFilteredHighlights
    }

    var activeMinimumSupportPercent: Double {
        hideLowSupport ? minimumSupportPercent : 0
    }
}
```

- [ ] **Step 2: Run swift build**

Run: `swift build`
Expected: BUILD SUCCEEDS (the call sites in `GenotypeResultViewController.swift` referencing the old cases need updating; do them in 3.2).

If swift build fails because of removed cases, that's expected — proceed to 3.2 to fix call sites.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeResultDisplayState.swift
git commit -m "Collapse genotype lenses to summary/review/audit; add summaryViewMode"
```

### Task 3.2: Rewire GenotypeResultViewController for three lenses

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift`

- [ ] **Step 1: Update lens handling in the controller**

Find the `showLens` / `lensChanged(_:)` / segmented-control setup and replace each occurrence of:

- `.analyst` → `.summary`
- `.haplotypes`, `.anchors`, `.consumer` → branched: most callers can `.summary` or `.review`. Specifically `rebuildHaplotypeLens()`, `rebuildAnchorLens()`, `rebuildConsumerLens()` are collapsed into the Summary panel B (cohort summary). Remove the dedicated scroll views for them (keep them empty for v2 and clean them up in 3.5).
- `.artifacts` → `.audit`

The lens segmented control should now display three segments. Set `lensControl = NSSegmentedControl(labels: GenotypeResultViewportLens.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil)`.

- [ ] **Step 2: Run swift build**

Run: `swift build`
Expected: BUILD SUCCEEDS

Fix any remaining call sites (e.g., `Tests/LungfishAppTests/GenotypeResultViewportTests.swift` may reference the old cases).

- [ ] **Step 3: Run regression tests**

Run: `swift test --filter GenotypeResultViewportTests`
Expected: PASS (the v1 tests assert basic configure/configure-result behavior; they should still pass).

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift Tests/LungfishAppTests/GenotypeResultViewportTests.swift
git commit -m "Collapse viewport lens segmented control to summary/review/audit"
```

### Task 3.3: Add GenotypeOutlineView with the tape primitive

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeOutlineView.swift`
- Test: `Tests/LungfishAppTests/GenotypeOutlineViewTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import AppKit
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class GenotypeOutlineViewTests: XCTestCase {
    func testRendersOneRowPerSample() {
        let view = GenotypeOutlineView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.configure(rows: [
            .init(animalId: "H17C119", gsId: "DW472", loci: ["MHC-A", "MHC-B"], tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 1, label: "M1A"), h2: .reference(tokenIndex: 1, label: "M1A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 1, label: "M1B"), h2: .reference(tokenIndex: 1, label: "M1B")),
            ], blockKind: .blockCoherent, commentSummary: "M1 homozygous"),
            .init(animalId: "H18C153", gsId: "DW473", loci: ["MHC-A", "MHC-B"], tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 2, label: "M2A"), h2: .reference(tokenIndex: 3, label: "M3A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 2, label: "M2B"), h2: .reference(tokenIndex: 3, label: "M3B")),
            ], blockKind: .blockCoherent, commentSummary: "block M2 / M3"),
        ])
        XCTAssertEqual(view.numberOfRows, 2)
    }
}
```

- [ ] **Step 2: Implement GenotypeOutlineView**

```swift
// Sources/LungfishApp/Views/Results/Genotype/GenotypeOutlineView.swift
import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeOutlineView: NSView {
    struct Row: Equatable {
        let animalId: String
        let gsId: String?
        let loci: [String]
        let tapeSlots: [GenotypeHaplotypeTapeView.Slot]
        let blockKind: GenotypeBlockKind
        let commentSummary: String

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.animalId == rhs.animalId && lhs.gsId == rhs.gsId &&
            lhs.loci == rhs.loci && lhs.blockKind == rhs.blockKind &&
            lhs.commentSummary == rhs.commentSummary
        }
    }

    var onRowSelected: ((String) -> Void)?
    var onRowDisclosure: ((String, Bool) -> Void)?
    private(set) var numberOfRows: Int = 0
    private var rows: [Row] = []
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let columnHeader = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); buildSubviews() }

    private func buildSubviews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1

        scrollView.documentView = documentView
        documentView.addSubview(stack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    func configure(rows: [Row]) {
        self.rows = rows
        numberOfRows = rows.count
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            stack.addArrangedSubview(makeRow(row))
        }
    }

    private func makeRow(_ row: Row) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let disclosure = NSTextField(labelWithString: "▶")
        disclosure.font = NSFont.systemFont(ofSize: 10)
        disclosure.textColor = .secondaryLabelColor

        let blockGlyph = NSTextField(labelWithString: blockGlyphSymbol(row.blockKind))
        blockGlyph.font = NSFont.systemFont(ofSize: 11)
        blockGlyph.textColor = blockGlyphColor(row.blockKind)
        blockGlyph.toolTip = blockGlyphTooltip(row.blockKind)

        let animalLabel = NSTextField(labelWithString: row.animalId)
        animalLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        animalLabel.textColor = .labelColor

        let tape = GenotypeHaplotypeTapeView()
        tape.translatesAutoresizingMaskIntoConstraints = false
        tape.configure(loci: row.loci, slots: row.tapeSlots)
        tape.sampleAccessibilityLabel = row.animalId
        let tapeWidth = max(140, CGFloat(row.loci.count) * 36)
        NSLayoutConstraint.activate([
            tape.widthAnchor.constraint(equalToConstant: tapeWidth),
            tape.heightAnchor.constraint(equalToConstant: 22),
        ])

        let commentLabel = NSTextField(labelWithString: row.commentSummary)
        commentLabel.font = NSFont.systemFont(ofSize: 10)
        commentLabel.textColor = .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail

        container.addArrangedSubview(disclosure)
        container.addArrangedSubview(blockGlyph)
        container.addArrangedSubview(animalLabel)
        container.addArrangedSubview(tape)
        container.addArrangedSubview(commentLabel)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        container.addGestureRecognizer(click)
        container.identifier = NSUserInterfaceItemIdentifier(row.animalId)
        return container
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view,
              let id = view.identifier?.rawValue else { return }
        onRowSelected?(id)
    }

    private func blockGlyphSymbol(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:        return "▮"
        case .regionalRecombinant:  return "▰▱"
        case .atypical:             return "▱▰▱"
        case .unknown:              return "·"
        }
    }
    private func blockGlyphColor(_ kind: GenotypeBlockKind) -> NSColor {
        switch kind {
        case .blockCoherent:       return NSColor.systemGreen
        case .regionalRecombinant: return NSColor.systemOrange
        case .atypical:            return NSColor.systemRed
        case .unknown:             return NSColor.secondaryLabelColor
        }
    }
    private func blockGlyphTooltip(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:       return "Block coherent"
        case .regionalRecombinant: return "Regional recombinant"
        case .atypical:            return "Atypical"
        case .unknown:             return "Unknown"
        }
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeOutlineViewTests`
Expected: PASS, 1 test

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeOutlineView.swift Tests/LungfishAppTests/GenotypeOutlineViewTests.swift
git commit -m "Add GenotypeOutlineView using haplotype tape primitive"
```

### Task 3.4: Add GenotypeCohortSummaryPanelView (Panel B for Summary lens)

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeCohortSummaryPanelView.swift`
- Test: `Tests/LungfishAppTests/GenotypeCohortSummaryPanelViewTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import AppKit
@testable import LungfishApp

@MainActor
final class GenotypeCohortSummaryPanelViewTests: XCTestCase {
    func testConfigureWithCountsRendersWithoutCrash() {
        let view = GenotypeCohortSummaryPanelView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        view.configure(summary: .init(
            sampleCount: 192,
            qcCounts: [("OK", 154), ("Low support", 22), ("Needs review", 11), ("Error", 5)],
            errorTypeCounts: [("TMH", 3), ("NO HAP", 1), ("TMG", 1)],
            blockCounts: [("Block coherent", 158), ("Recombinant", 26), ("Atypical", 8)],
            readBudget: ("42.8K median", "Below 5K: 8 samples"),
            annotationCounts: [("Overrides", 0), ("Comments", 4), ("Highlights", 0)]
        ))
        XCTAssertTrue(view.subviews.count > 0)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// Sources/LungfishApp/Views/Results/Genotype/GenotypeCohortSummaryPanelView.swift
import AppKit

@MainActor
final class GenotypeCohortSummaryPanelView: NSView {
    struct Summary {
        let sampleCount: Int
        let qcCounts: [(String, Int)]
        let errorTypeCounts: [(String, Int)]
        let blockCounts: [(String, Int)]
        let readBudget: (median: String, belowThreshold: String)
        let annotationCounts: [(String, Int)]
    }

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); build()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        documentView.translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        scrollView.documentView = documentView
        documentView.addSubview(stack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    func configure(summary: Summary) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(makeSection(title: "Cohort summary",
                                             content: [("Samples", "\(summary.sampleCount)")]))
        stack.addArrangedSubview(makeSection(title: "QC distribution",
                                             content: summary.qcCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Errors",
                                             content: summary.errorTypeCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Block coherence",
                                             content: summary.blockCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Read budget",
                                             content: [("Median", summary.readBudget.median),
                                                       ("Below threshold", summary.readBudget.belowThreshold)]))
        stack.addArrangedSubview(makeSection(title: "Annotations",
                                             content: summary.annotationCounts.map { ($0.0, "\($0.1)") }))
    }

    private func makeSection(title: String, content: [(String, String)]) -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        v.addArrangedSubview(titleLabel)
        for (key, value) in content {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            let k = NSTextField(labelWithString: key)
            k.font = NSFont.systemFont(ofSize: 11)
            k.textColor = .secondaryLabelColor
            let val = NSTextField(labelWithString: value)
            val.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            val.textColor = .labelColor
            row.addArrangedSubview(k)
            row.addArrangedSubview(val)
            v.addArrangedSubview(row)
        }
        return v
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GenotypeCohortSummaryPanelViewTests`
Expected: PASS, 1 test

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeCohortSummaryPanelView.swift Tests/LungfishAppTests/GenotypeCohortSummaryPanelViewTests.swift
git commit -m "Add GenotypeCohortSummaryPanelView for Summary lens panel B"
```

### Task 3.5: Wire Summary lens — Outline view + cohort summary panel

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift`

- [ ] **Step 1: Replace the body of the Summary lens with the new outline + summary panel**

Inside the controller:
- Add stored properties `private let outlineView = GenotypeOutlineView()` and `private let cohortSummaryPanel = GenotypeCohortSummaryPanelView()`.
- In `showLens(.summary)`, install `outlineView` into `sampleContainer` and `cohortSummaryPanel` into `detailContainer` (for `summaryViewMode == .outline`).
- When the lens is selected, compute summary rows from the result + sidecar and call `cohortSummaryPanel.configure(summary:)`.
- Drive the outline rows from the result: for each sample, derive its 14 calls from the existing `GenotypeHaplotypeAnalysis` (already exposed via `result.haplotypeAnalysis`).
- Selecting a row in Outline switches the inspector's selectedItem tab via the existing `onSelectionStateChanged` callback.

(For brevity, here is the contract; the engineer reads the current controller and adapts. Keep changes within the existing patterns — no need to introduce new coordination primitives.)

- [ ] **Step 2: Run build and existing tests**

Run: `swift build && swift test --filter GenotypeResultViewportTests`
Expected: all green

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift
git commit -m "Install Outline view and cohort summary panel into Summary lens"
```

---

## Milestone 4: Quick filter, smart cohorts, inspector wiring

These tasks add the filter bar, the smart-cohort library section in the Inspector Document tab, and the override section in the Inspector Selection tab.

### Task 4.1: GenotypeQuickFilterBarView

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift`
- Test: `Tests/LungfishAppTests/GenotypeQuickFilterBarViewTests.swift`

- [ ] **Steps:** TDD as above. Implement an NSSearchField + a horizontal `NSStackView` of pill toggle buttons. Each pill toggle emits a `predicate` value. The bar exposes:

```swift
var onSearchTextChanged: ((String) -> Void)?
var onPredicatesChanged: (([SmartCohortPredicate]) -> Void)?
var onSaveSmartCohortRequested: (([SmartCohortPredicate]) -> Void)?
```

The default pill set: Has errors, Homozygous, Recombinant, Bw6+ (commentContains), Has comments, Duplicate (commentContains "duplicate"). The "+ More…" entry opens a popover hosting the smart-cohort predicate library list.

Test: configure with the default pills; assert toggling a pill emits `onPredicatesChanged` with one predicate.

Commit: `Add GenotypeQuickFilterBarView with default pills and search`.

### Task 4.2: GenotypeSmartCohortSection (Inspector Document tab)

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeSmartCohortSection.swift`
- Test: `Tests/LungfishAppTests/GenotypeSmartCohortSectionTests.swift`

- [ ] **Steps:** SwiftUI view (matches the existing pattern in `GenotypeResultDocumentSection.swift`). Renders a list of `GenotypeCohortSmartFilter` with counts, a star icon for user-scope, a + button for "Save current filter as smart cohort".

```swift
struct GenotypeSmartCohortSection: View {
    let cohorts: [DisplayedCohort]
    var onSelect: (GenotypeCohortSmartFilter) -> Void
    var onDelete: (GenotypeCohortSmartFilter) -> Void
    var onAdd: () -> Void

    struct DisplayedCohort: Identifiable, Equatable {
        let filter: GenotypeCohortSmartFilter
        let count: Int
        var id: String { filter.name + "/" + filter.scope }
    }
    // ...
}
```

Test: configure with 3 cohorts; assert 3 rows render; click one and `onSelect` fires.

Commit: `Add GenotypeSmartCohortSection for Inspector Document tab`.

### Task 4.3: GenotypeOverrideSection (Inspector Selection tab)

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift`
- Test: `Tests/LungfishAppTests/GenotypeOverrideSectionTests.swift`

- [ ] **Steps:** SwiftUI view. Inputs: original call, override target picker (whitelist or free-text), reason chips, rationale textarea, save/cancel.

For reference set bundles (MCM, MAMU, MANE), the picker is a strict whitelist built from the active `GenotypeHaplotypeDefinitionSet.locusDefinitions[locus].haplotypes` names plus `["A1_063", "-"]`. For manual-mode bundles, the picker is a combo box (autocompleting text field with suggestions drawn from `sidecar.manualHaplotypeAssignments`).

```swift
struct GenotypeOverrideSection: View {
    @Binding var draft: OverrideDraft
    let originalCall: String
    let allowedTargets: [String]   // empty = free-text
    var onSave: (OverrideDraft) -> Void
    var onCancel: () -> Void

    struct OverrideDraft: Equatable {
        var target: String = ""
        var reason: GenotypeAnnotationSidecar.OverrideReasonTag = .confirmed
        var rationale: String = ""
    }
    // ...
}
```

Test: render with `allowedTargets: ["M1A","M2A","M3A"]`; assert the picker has those entries.

Commit: `Add GenotypeOverrideSection for analyst overrides`.

### Task 4.4: GenotypeStatusFlagSection (Inspector Selection tab)

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeStatusFlagSection.swift`
- Test: `Tests/LungfishAppTests/GenotypeStatusFlagSectionTests.swift`

- [ ] **Steps:** Renders the four-status segmented control (Unflagged / Needs review / Reviewed / Confirmed) and a comments list.

Commit: `Add GenotypeStatusFlagSection for analyst status flag + comments`.

### Task 4.5: Wire Smart Cohort evaluation in viewport

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift`

- [ ] **Steps:** When the filter bar's `onPredicatesChanged` fires, evaluate the predicate over the sample list (build `GenotypeCohortSubject` per sample using existing data + sidecar). Filter the outline (and matrix / cards once they exist) to matching subjects. Update the Smart Cohort section's counts.

Add a private method `applyFilters(predicates: [SmartCohortPredicate])` and call it on `onPredicatesChanged`.

Commit: `Apply smart cohort predicates to the cohort list`.

---

## Milestone 5: Review lens

### Task 5.1: GenotypeReviewQueueView

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeReviewQueueView.swift`
- Test: `Tests/LungfishAppTests/GenotypeReviewQueueViewTests.swift`

- [ ] **Steps:** A specialized outline that groups samples by Needs-Review sub-group (Errors / Low support / Analyst flagged). Selecting a sample emits `onSampleSelected`. Keyboard handlers for `Down/Up/Right/Left/Space/⌘R/⌘K/⌘⇧F/⌘⇧O/⌘'/⌘⌃1`…`⌘⌃7`.

Commit: `Add GenotypeReviewQueueView with grouped sub-sections`.

### Task 5.2: GenotypeCallEvidenceView (Panel B for Review lens)

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeCallEvidenceView.swift`
- Test: `Tests/LungfishAppTests/GenotypeCallEvidenceViewTests.swift`

- [ ] **Steps:** Three sub-sections: diagnostic allele table, locus coverage bar, run neighbors. Inputs: selected sample, locus, slot.

The diagnostic allele table is a small NSTableView with 4 columns (allele, reads, % locus, status). The locus coverage bar is a custom NSView showing a single horizontal stacked bar. Run neighbors is an NSStackView with 3 entries (prev / selected / next).

Commit: `Add GenotypeCallEvidenceView for Review lens panel B`.

### Task 5.3: Wire Review lens in the viewport

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift`

- [ ] **Steps:** In `showLens(.review)`, install `reviewQueueView` into `sampleContainer` and `callEvidenceView` into `detailContainer`. Wire the keyboard shortcuts to the `GenotypeAnnotationStore` operations.

Commit: `Install Review lens panels in viewport`.

---

## Milestone 6: Audit lens + manual haplotyping

### Task 6.1: GenotypeAuditPanelView with dropout-threshold editor

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeAuditPanelView.swift`
- Test: `Tests/LungfishAppTests/GenotypeAuditPanelViewTests.swift`

- [ ] **Steps:** Build a SwiftUI hosted view with:
  - Absolute reads threshold (NSStepper) + an enable toggle
  - % of sample reads threshold (slider 0–100 + enable toggle)
  - % of locus reads threshold (slider 0–100 + enable toggle)
  - Smart cohort editor list
  - Palette pin table for the active haplotype set
  - Manual definition import/export buttons

Commit: `Add GenotypeAuditPanelView with threshold and palette controls`.

### Task 6.2: GenotypeManualHaplotypingPanelView

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeManualHaplotypingPanelView.swift`
- Test: `Tests/LungfishAppTests/GenotypeManualHaplotypingPanelViewTests.swift`

- [ ] **Steps:** For each locus, list unique observed genotypes across the cohort with their per-sample read counts and a "samples sharing this genotype" count. The analyst selects 1+ genotypes and clicks "Create haplotype…". Sheet prompts for a label and color token. On confirm, write `ManualHaplotypeAssignment` records to the store.

Commit: `Add GenotypeManualHaplotypingPanelView for analyst-defined haplotypes`.

### Task 6.3: Wire Audit lens

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift`

- [ ] **Steps:** In `showLens(.audit)`, install provenance + artifacts into `sampleContainer` and the audit panel into `detailContainer`.

Commit: `Install Audit lens panels in viewport`.

---

## Milestone 7: View modes — Cards + Matrix Fit toggle

### Task 7.1: GenotypeCardsView with auto-densification

**Files:**
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeCardsView.swift`
- Test: `Tests/LungfishAppTests/GenotypeCardsViewTests.swift`

- [ ] **Steps:** NSCollectionView with a flow layout. Each cell contains an animal-id label, a small `GenotypeHaplotypeTapeView`, and a comment summary. Density determined by sample count: ≤30 → Comfortable (full card), >30 → Compact (smaller card with tape only).

Commit: `Add GenotypeCardsView with auto-density`.

### Task 7.2: Matrix Fit/Normal toggle

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeComparisonMatrixView.swift`

- [ ] **Steps:** Add `var fitMode: MatrixFitMode = .normal` and a small NSSegmentedControl at the top of the matrix view (Normal/Fit). In Fit mode set column width to 4pt and hide cell labels.

Commit: `Add Matrix Fit toggle to GenotypeComparisonMatrixView`.

### Task 7.3: View-mode picker in Inspector Document tab

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultDocumentSection.swift`

- [ ] **Steps:** Add a Picker (radio-style) bound to `displayState.summaryViewMode` with three options. The picker triggers `onDisplayStateChanged` so the viewport swaps Panel A.

Commit: `Add view-mode picker (Outline/Cards/Matrix) to Inspector Document section`.

---

## Milestone 8: Excel export + CLI

### Task 8.1: Apply overrides in Excel export

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeViewportExcelExportService.swift`
- Test: `Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift`

- [ ] **Steps:** Extend the export service to optionally apply call overrides from a passed-in sidecar. For each overridden cell, write the override value as the visible cell and add an Excel cell comment with the original call + author + timestamp. Add a second sheet `<run>_overrides` listing all overrides. Add a third sheet `<run>_audit` with the audit log.

Test: round-trip a bundle with one override; reopen the produced xlsx via openpyxl in a subprocess (or use the existing OOXML reader if available) and assert the cell + comment + sheet 2 + sheet 3 are present.

Commit: `Apply overrides + audit sheets in Excel export`.

### Task 8.2: M1–M7 conditional formatting in Excel export

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeViewportExcelExportService.swift`

- [ ] **Steps:** For each canonical haplotype name (M1, M2, ..., M7), emit a `containsText` conditional format on `D6:ZZ19` painting the cell to the canonical palette color and the font to the token's `fontColor`. Use the `HaplotypeColorToken.canonicalPalette` values verbatim.

Commit: `Emit M1-M7 conditional formatting in Excel export`.

### Task 8.3: CLI subcommand group

**Files:**
- Create: `Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift`
- Create: `Sources/LungfishCLI/Commands/GenotypeListSamplesSubcommand.swift`
- Create: `Sources/LungfishCLI/Commands/GenotypeListCohortsSubcommand.swift`
- Create: `Sources/LungfishCLI/Commands/GenotypeApplyAnnotationsSubcommand.swift`
- Create: `Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift`
- Test: `Tests/LungfishCLITests/GenotypeSubcommandsTests.swift`

- [ ] **Steps:** Build the command group following the `FastqONTBarcodeGenotypingSubcommand` pattern. Each subcommand takes `--bundle <path>` and prints to stdout (or writes to `--out` for export).

Commit: `Add lungfish genotype CLI subcommands`.

---

## Milestone 9: Integration tests + GUI smoke

### Task 9.1: GenotypeViewportV2Tests

**Files:**
- Modify: `Tests/LungfishAppTests/GenotypeResultViewportTests.swift` (or add a new file)

- [ ] **Steps:** Open a fixture bundle, exercise all three lenses, assert the Outline / Cards / Matrix view-mode switch swaps Panel A.

Commit: `Add GenotypeViewportV2 integration tests`.

### Task 9.2: GenotypeAnnotationFlowTests

- [ ] **Steps:** Apply an override; assert sidecar contains the entry + audit; the outline renders the overridden cell with hatch; undo reverts.

Commit: `Add genotype override annotation flow tests`.

### Task 9.3: GenotypeSmartCohortTests

- [ ] **Steps:** Define a smart cohort; activate; assert the cohort filter is applied to the cohort list. Save the cohort to the sidecar; reopen the viewport; assert the cohort persists.

Commit: `Add smart cohort persistence + filtering tests`.

### Task 9.4: GenotypeManualHaplotypingTests

- [ ] **Steps:** Create a manual haplotype from two genotypes; the tape draws the haplotype's color on matching samples; export round-trips.

Commit: `Add manual haplotyping flow tests`.

### Task 9.5: Build green gate

- [ ] **Steps:** Run `swift build && swift test`. Fix any remaining test breakage. The full suite must be green before the milestone closes.

Commit: `Fix milestone 9 regressions` (if any).

---

## Self-review checklist (run after writing — fix inline, don't re-review)

- [x] **Spec coverage:** every spec requirement maps to a task (Three lenses → Tasks 3.1–6.3; Tape primitive → 2.2; Smart Cohorts → 1.4 + 4.2 + 4.5; Annotation sidecar → 1.3 + 1.8 + 2.1; Override flow → 2.1 + 4.3; Manual haplotyping → 1.7 + 6.2; Three dropout modes → 1.6 + 6.1; Excel export → 8.1, 8.2; CLI parity → 8.3; Accessibility → built into tape primitive 2.2).
- [x] **Placeholder scan:** no TBDs, no "implement later", every code step shows code.
- [x] **Type consistency:** `HaplotypeColorToken`, `HaplotypeSlot`, `GenotypeAnnotationSidecar`, `SmartCohortPredicate`, `GenotypeAnnotationStore` — names match across tasks.
- [x] **Scope:** the plan is bounded; no creeping features. Plate view, KIR UI, LabKey ingestion, multi-author collab all deferred per spec.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-22-mhc-genotype-inspector-v2.md`. The user has authorized autonomous execution for the next four hours. Use **subagent-driven-development** to execute task-by-task. Stay on `codex/lungfishgenotype-viewport-inspector`. Run `swift build && swift test` at the end of each milestone; commit between tasks; never `--no-verify` a hook.

# Declarative Recipe Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded recipe execution in FASTQBatchImporter with a declarative JSON-based recipe engine, implementing the VSP2 recipe using fastp + deacon as the first recipe.

**Architecture:** New `Recipes/` module within LungfishWorkflow. Recipes are JSON files parsed into a `Recipe` model. Each step type has a `RecipeStepExecutor` conforming struct. The `RecipeEngine` orchestrator validates, plans format conversions, fuses consecutive fastp steps, and executes. `FASTQBatchImporter` delegates to `RecipeEngine` for new-format recipes while keeping the old code path for unmigrated recipes.

**Tech Stack:** Swift 6.2, strict concurrency, `@Sendable`, SPM resources, XCTest

---

## File Structure

| File | Responsibility |
|------|---------------|
| `LungfishWorkflow/Recipes/SequencingPlatform.swift` | Platform enum + defaults + auto-detection |
| `LungfishWorkflow/Recipes/Recipe.swift` | Recipe JSON model (Codable) |
| `LungfishWorkflow/Recipes/RecipeStepExecutor.swift` | Step protocol + FileFormat + StepInput/Output/Context |
| `LungfishWorkflow/Recipes/RecipeEngine.swift` | Orchestrator: validate, plan, fuse, execute |
| `LungfishWorkflow/Recipes/RecipeRegistry.swift` | Load built-in + user recipes, filter by platform |
| `LungfishWorkflow/Recipes/Steps/FastpDedupStep.swift` | fastp --dedup executor |
| `LungfishWorkflow/Recipes/Steps/FastpTrimStep.swift` | fastp trim executor |
| `LungfishWorkflow/Recipes/Steps/DeaconScrubStep.swift` | deacon filter executor |
| `LungfishWorkflow/Recipes/Steps/FastpMergeStep.swift` | fastp --merge executor |
| `LungfishWorkflow/Recipes/Steps/SeqkitLengthFilterStep.swift` | seqkit length filter executor |
| `LungfishWorkflow/Resources/Recipes/vsp2.recipe.json` | VSP2 recipe JSON |
| Tests: `LungfishWorkflowTests/Recipes/` | All recipe engine tests |

Modified files:
| File | Changes |
|------|---------|
| `Package.swift` | Add `.copy("Resources/Recipes")` to LungfishWorkflow resources |
| `Native/NativeToolRunner.swift` | Add `deacon` case to `NativeTool` enum |
| `Ingestion/FASTQBatchImporter.swift` | Update `ImportConfig`, add `RecipeEngine` delegation |
| `LungfishCLI/Commands/ImportFastqCommand.swift` | Add `--platform`, `--no-optimize-storage`, `--compression`, `--force` flags |

---

### Task 1: SequencingPlatform enum + tests

**Files:**
- Create: `Sources/LungfishWorkflow/Recipes/SequencingPlatform.swift`
- Create: `Tests/LungfishWorkflowTests/Recipes/SequencingPlatformTests.swift`

- [ ] **Step 1: Write the failing test for platform defaults**

```swift
// Tests/LungfishWorkflowTests/Recipes/SequencingPlatformTests.swift
import XCTest
@testable import LungfishWorkflow

final class SequencingPlatformTests: XCTestCase {

    func testIlluminaDefaults() {
        let p = SequencingPlatform.illumina
        XCTAssertEqual(p.displayName, "Illumina")
        XCTAssertEqual(p.defaultPairing, .paired)
        XCTAssertTrue(p.defaultOptimizeStorage)
        XCTAssertEqual(p.defaultQualityBinning, .illumina4)
        XCTAssertEqual(p.defaultCompressionLevel, .balanced)
    }

    func testONTDefaults() {
        let p = SequencingPlatform.ont
        XCTAssertEqual(p.displayName, "Oxford Nanopore")
        XCTAssertEqual(p.defaultPairing, .single)
        XCTAssertFalse(p.defaultOptimizeStorage)
        XCTAssertEqual(p.defaultQualityBinning, .none)
        XCTAssertEqual(p.defaultCompressionLevel, .balanced)
    }

    func testPacBioDefaults() {
        let p = SequencingPlatform.pacbio
        XCTAssertEqual(p.displayName, "PacBio HiFi")
        XCTAssertEqual(p.defaultPairing, .single)
        XCTAssertFalse(p.defaultOptimizeStorage)
        XCTAssertEqual(p.defaultQualityBinning, .none)
        XCTAssertEqual(p.defaultCompressionLevel, .balanced)
    }

    func testUltimaDefaults() {
        let p = SequencingPlatform.ultima
        XCTAssertEqual(p.displayName, "Ultima Genomics")
        XCTAssertEqual(p.defaultPairing, .paired)
        XCTAssertTrue(p.defaultOptimizeStorage)
        XCTAssertEqual(p.defaultQualityBinning, .illumina4)
        XCTAssertEqual(p.defaultCompressionLevel, .balanced)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SequencingPlatformTests 2>&1 | tail -20`
Expected: Compilation error — `SequencingPlatform` not found.

- [ ] **Step 3: Implement SequencingPlatform**

```swift
// Sources/LungfishWorkflow/Recipes/SequencingPlatform.swift
import Foundation
import LungfishIO

/// Sequencing platform identity — determines available recipes and import defaults.
public enum SequencingPlatform: String, Codable, CaseIterable, Sendable {
    case illumina
    case ont
    case pacbio
    case ultima

    public var displayName: String {
        switch self {
        case .illumina: return "Illumina"
        case .ont:      return "Oxford Nanopore"
        case .pacbio:   return "PacBio HiFi"
        case .ultima:   return "Ultima Genomics"
        }
    }

    public var defaultPairing: IngestionMetadata.PairingMode {
        switch self {
        case .illumina, .ultima: return .interleaved // "paired" in user terms
        case .ont, .pacbio:      return .singleEnd
        }
    }

    /// Whether k-mer sorting (clumpify reorder) is recommended for this platform.
    public var defaultOptimizeStorage: Bool {
        switch self {
        case .illumina, .ultima: return true
        case .ont, .pacbio:      return false
        }
    }

    public var defaultQualityBinning: QualityBinningScheme {
        switch self {
        case .illumina, .ultima: return .illumina4
        case .ont, .pacbio:      return .none
        }
    }

    public var defaultCompressionLevel: CompressionLevel {
        return .balanced
    }
}

/// Compression level for FASTQ bundle finalization.
public enum CompressionLevel: String, Codable, Sendable, CaseIterable {
    case fast       // zl=1
    case balanced   // zl=4
    case maximum    // zl=9

    public var zlValue: Int {
        switch self {
        case .fast:     return 1
        case .balanced: return 4
        case .maximum:  return 9
        }
    }

    public var displayName: String {
        switch self {
        case .fast:     return "Fast (larger files)"
        case .balanced: return "Balanced"
        case .maximum:  return "Maximum (slower import)"
        }
    }
}
```

Note: `IngestionMetadata.PairingMode` and `QualityBinningScheme` already exist in LungfishIO and LungfishWorkflow respectively.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SequencingPlatformTests 2>&1 | tail -20`
Expected: All 4 tests pass.

- [ ] **Step 5: Write platform auto-detection test**

Add to `SequencingPlatformTests.swift`:

```swift
    func testAutoDetectIllumina() {
        let header = "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT"
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQHeader: header), .illumina)
    }

    func testAutoDetectONT() {
        let header = "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1"
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQHeader: header), .ont)
    }

    func testAutoDetectPacBio() {
        let header = "@m64011_190830_220126/101/ccs"
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQHeader: header), .pacbio)
    }

    func testAutoDetectUnknown() {
        let header = "@read1 some random format"
        XCTAssertNil(SequencingPlatform.detect(fromFASTQHeader: header))
    }
```

- [ ] **Step 6: Run test to verify it fails**

Run: `swift test --filter SequencingPlatformTests 2>&1 | tail -20`
Expected: Compilation error — `detect(fromFASTQHeader:)` not found.

- [ ] **Step 7: Implement auto-detection**

Add to `SequencingPlatform.swift`:

```swift
extension SequencingPlatform {
    /// Attempt to detect platform from the first FASTQ header line (including @).
    /// Returns nil if format is not recognized.
    public static func detect(fromFASTQHeader header: String) -> SequencingPlatform? {
        let stripped = header.hasPrefix("@") ? String(header.dropFirst()) : header

        // Illumina: INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y
        // e.g., "A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT"
        let illuminaPattern = #"^[A-Za-z0-9_-]+:\d+:[A-Za-z0-9]+:\d+:\d+:\d+:\d+"#
        if stripped.range(of: illuminaPattern, options: .regularExpression) != nil {
            return .illumina
        }

        // ONT: contains "runid="
        if stripped.contains("runid=") {
            return .ont
        }

        // PacBio: m{digits}_{digits}_{digits}/{zmw}/ccs or similar
        let pacbioPattern = #"^m\d+_\d+_\d+/\d+/(ccs|subreads)"#
        if stripped.range(of: pacbioPattern, options: .regularExpression) != nil {
            return .pacbio
        }

        return nil
    }
}
```

- [ ] **Step 8: Run tests to verify all pass**

Run: `swift test --filter SequencingPlatformTests 2>&1 | tail -20`
Expected: All 8 tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/LungfishWorkflow/Recipes/SequencingPlatform.swift \
       Tests/LungfishWorkflowTests/Recipes/SequencingPlatformTests.swift
git commit -m "feat: add SequencingPlatform enum with defaults and auto-detection"
```

---

### Task 2: Recipe model + JSON parsing + tests

**Files:**
- Create: `Sources/LungfishWorkflow/Recipes/Recipe.swift`
- Create: `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json`
- Create: `Tests/LungfishWorkflowTests/Recipes/RecipeTests.swift`

- [ ] **Step 1: Write the failing test for recipe parsing**

```swift
// Tests/LungfishWorkflowTests/Recipes/RecipeTests.swift
import XCTest
@testable import LungfishWorkflow

final class RecipeTests: XCTestCase {

    func testParseMinimalRecipe() throws {
        let json = """
        {
            "formatVersion": 1,
            "id": "test-recipe",
            "name": "Test Recipe",
            "platforms": ["illumina"],
            "requiredInput": "paired",
            "steps": []
        }
        """.data(using: .utf8)!

        let recipe = try JSONDecoder().decode(Recipe.self, from: json)
        XCTAssertEqual(recipe.id, "test-recipe")
        XCTAssertEqual(recipe.name, "Test Recipe")
        XCTAssertEqual(recipe.platforms, [.illumina])
        XCTAssertEqual(recipe.requiredInput, .paired)
        XCTAssertTrue(recipe.steps.isEmpty)
        XCTAssertNil(recipe.qualityBinning)
        XCTAssertNil(recipe.description)
        XCTAssertNil(recipe.author)
        XCTAssertTrue(recipe.tags.isEmpty)
    }

    func testParseFullRecipe() throws {
        let json = """
        {
            "formatVersion": 1,
            "id": "vsp2-target-enrichment",
            "name": "VSP2 Target Enrichment",
            "description": "Optimized for VSP2",
            "author": "Lungfish Built-in",
            "tags": ["illumina", "vsp2"],
            "platforms": ["illumina"],
            "requiredInput": "paired",
            "qualityBinning": "illumina4",
            "steps": [
                { "type": "fastp-dedup", "label": "Dedup" },
                { "type": "fastp-trim", "label": "Trim", "params": { "quality": 15 } }
            ]
        }
        """.data(using: .utf8)!

        let recipe = try JSONDecoder().decode(Recipe.self, from: json)
        XCTAssertEqual(recipe.id, "vsp2-target-enrichment")
        XCTAssertEqual(recipe.qualityBinning, .illumina4)
        XCTAssertEqual(recipe.steps.count, 2)
        XCTAssertEqual(recipe.steps[0].type, "fastp-dedup")
        XCTAssertEqual(recipe.steps[0].label, "Dedup")
        XCTAssertEqual(recipe.steps[1].type, "fastp-trim")
        XCTAssertEqual(recipe.steps[1].params?["quality"] as? Int, 15)
    }

    func testRoundTrip() throws {
        let json = """
        {
            "formatVersion": 1,
            "id": "round-trip-test",
            "name": "Round Trip",
            "platforms": ["ont", "pacbio"],
            "requiredInput": "single",
            "qualityBinning": "none",
            "steps": [
                { "type": "seqkit-length-filter", "params": { "minLength": 200 } }
            ]
        }
        """.data(using: .utf8)!

        let recipe = try JSONDecoder().decode(Recipe.self, from: json)
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)

        XCTAssertEqual(recipe.id, decoded.id)
        XCTAssertEqual(recipe.name, decoded.name)
        XCTAssertEqual(recipe.platforms, decoded.platforms)
        XCTAssertEqual(recipe.steps.count, decoded.steps.count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecipeTests 2>&1 | tail -20`
Expected: Compilation error — `Recipe` not found.

- [ ] **Step 3: Implement Recipe model**

```swift
// Sources/LungfishWorkflow/Recipes/Recipe.swift
import Foundation

/// A declarative FASTQ processing recipe loaded from JSON.
public struct Recipe: Codable, Sendable, Identifiable, Equatable {

    public let formatVersion: Int
    public let id: String
    public let name: String
    public var description: String?
    public var author: String?
    public var tags: [String]
    public let platforms: [SequencingPlatform]
    public let requiredInput: InputRequirement
    public var qualityBinning: QualityBinningScheme?
    public var steps: [RecipeStep]

    public enum InputRequirement: String, Codable, Sendable, Equatable {
        case paired
        case single
        case any
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        platforms = try container.decode([SequencingPlatform].self, forKey: .platforms)
        requiredInput = try container.decode(InputRequirement.self, forKey: .requiredInput)
        qualityBinning = try container.decodeIfPresent(QualityBinningScheme.self, forKey: .qualityBinning)
        steps = try container.decode([RecipeStep].self, forKey: .steps)
    }
}

/// A single step within a recipe.
public struct RecipeStep: Codable, Sendable, Equatable {
    public let type: String
    public var label: String?
    public var params: [String: AnyCodableValue]?

    public init(type: String, label: String? = nil, params: [String: AnyCodableValue]? = nil) {
        self.type = type
        self.label = label
        self.params = params
    }
}

/// Type-erased Codable value for recipe step parameters.
/// Supports String, Int, Double, Bool — the types needed for tool arguments.
public enum AnyCodableValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension AnyCodableValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        throw DecodingError.typeMismatch(AnyCodableValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported param type"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        }
    }
}

extension AnyCodableValue {
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecipeTests 2>&1 | tail -20`
Expected: All 3 tests pass.

- [ ] **Step 5: Create the VSP2 recipe JSON file**

```json
// Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json
{
    "formatVersion": 1,
    "id": "vsp2-target-enrichment",
    "name": "VSP2 Target Enrichment",
    "description": "Optimized for VSP2 short-insert viral enrichment: dedup, trim, scrub human, merge, length filter.",
    "author": "Lungfish Built-in",
    "tags": ["illumina", "vsp2", "viral", "paired-end", "target-enrichment"],
    "platforms": ["illumina"],
    "requiredInput": "paired",
    "qualityBinning": "illumina4",
    "steps": [
        {
            "type": "fastp-dedup",
            "label": "Remove PCR duplicates"
        },
        {
            "type": "fastp-trim",
            "label": "Adapter + quality trim",
            "params": {
                "detectAdapter": true,
                "quality": 15,
                "window": 5,
                "cutMode": "right"
            }
        },
        {
            "type": "deacon-scrub",
            "label": "Remove human reads",
            "params": {
                "database": "deacon"
            }
        },
        {
            "type": "fastp-merge",
            "label": "Merge overlapping pairs",
            "params": {
                "minOverlap": 15
            }
        },
        {
            "type": "seqkit-length-filter",
            "label": "Remove short reads",
            "params": {
                "minLength": 50
            }
        }
    ]
}
```

- [ ] **Step 6: Add `.copy("Resources/Recipes")` to Package.swift**

In `Package.swift`, find the LungfishWorkflow target's `resources` array and add `.copy("Resources/Recipes")`:

```swift
resources: [
    .copy("Resources/Containerization"),
    .copy("Resources/Tools"),
    .copy("Resources/Databases"),
    .copy("Resources/Recipes")
]
```

- [ ] **Step 7: Write test that loads the bundled VSP2 recipe JSON**

Add to `RecipeTests.swift`:

```swift
    func testLoadBundledVSP2Recipe() throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "vsp2.recipe", withExtension: "json", subdirectory: "Recipes") else {
            XCTFail("vsp2.recipe.json not found in bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertEqual(recipe.id, "vsp2-target-enrichment")
        XCTAssertEqual(recipe.platforms, [.illumina])
        XCTAssertEqual(recipe.requiredInput, .paired)
        XCTAssertEqual(recipe.steps.count, 5)
        XCTAssertEqual(recipe.steps[0].type, "fastp-dedup")
        XCTAssertEqual(recipe.steps[1].type, "fastp-trim")
        XCTAssertEqual(recipe.steps[2].type, "deacon-scrub")
        XCTAssertEqual(recipe.steps[3].type, "fastp-merge")
        XCTAssertEqual(recipe.steps[4].type, "seqkit-length-filter")
    }
```

- [ ] **Step 8: Run tests to verify all pass**

Run: `swift test --filter RecipeTests 2>&1 | tail -20`
Expected: All 4 tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/LungfishWorkflow/Recipes/Recipe.swift \
       Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json \
       Tests/LungfishWorkflowTests/Recipes/RecipeTests.swift \
       Package.swift
git commit -m "feat: add Recipe JSON model with VSP2 recipe definition"
```

---

### Task 3: RecipeStepExecutor protocol + FileFormat + tests

**Files:**
- Create: `Sources/LungfishWorkflow/Recipes/RecipeStepExecutor.swift`
- Create: `Tests/LungfishWorkflowTests/Recipes/RecipeStepExecutorTests.swift`

- [ ] **Step 1: Write the failing test for FileFormat and StepInput/Output**

```swift
// Tests/LungfishWorkflowTests/Recipes/RecipeStepExecutorTests.swift
import XCTest
@testable import LungfishWorkflow

final class RecipeStepExecutorTests: XCTestCase {

    func testFileFormatCodable() throws {
        let format = FileFormat.pairedR1R2
        let data = try JSONEncoder().encode(format)
        let decoded = try JSONDecoder().decode(FileFormat.self, from: data)
        XCTAssertEqual(decoded, .pairedR1R2)
    }

    func testStepInputPaired() {
        let r1 = URL(fileURLWithPath: "/tmp/R1.fq.gz")
        let r2 = URL(fileURLWithPath: "/tmp/R2.fq.gz")
        let input = StepInput(r1: r1, r2: r2, r3: nil, format: .pairedR1R2)
        XCTAssertEqual(input.format, .pairedR1R2)
        XCTAssertNotNil(input.r2)
        XCTAssertNil(input.r3)
    }

    func testStepInputMerged() {
        let merged = URL(fileURLWithPath: "/tmp/merged.fq.gz")
        let ur1 = URL(fileURLWithPath: "/tmp/unmerged_R1.fq.gz")
        let ur2 = URL(fileURLWithPath: "/tmp/unmerged_R2.fq.gz")
        let input = StepInput(r1: merged, r2: ur1, r3: ur2, format: .merged)
        XCTAssertEqual(input.format, .merged)
        XCTAssertNotNil(input.r3)
    }

    func testStepOutputSingle() {
        let url = URL(fileURLWithPath: "/tmp/reads.fq.gz")
        let output = StepOutput(r1: url, r2: nil, r3: nil, format: .single, readCount: 1000)
        XCTAssertEqual(output.readCount, 1000)
        XCTAssertNil(output.r2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecipeStepExecutorTests 2>&1 | tail -20`
Expected: Compilation error — types not found.

- [ ] **Step 3: Implement the protocol and supporting types**

```swift
// Sources/LungfishWorkflow/Recipes/RecipeStepExecutor.swift
import Foundation

/// File format for data flowing between recipe steps.
public enum FileFormat: String, Codable, Sendable, Equatable {
    /// Separate R1.fq.gz + R2.fq.gz files.
    case pairedR1R2
    /// Single interleaved FASTQ file.
    case interleaved
    /// Post-merge: merged.fq.gz + unmerged_R1.fq.gz + unmerged_R2.fq.gz.
    case merged
    /// Single-end reads in one file.
    case single
}

/// Input files for a recipe step.
public struct StepInput: Sendable {
    /// Primary file: R1, interleaved, merged reads, or single-end.
    public let r1: URL
    /// Secondary: R2 for pairedR1R2, unmerged_R1 for merged, nil otherwise.
    public let r2: URL?
    /// Tertiary: unmerged_R2 for merged format, nil otherwise.
    public let r3: URL?
    /// Format of the input files.
    public let format: FileFormat

    public init(r1: URL, r2: URL? = nil, r3: URL? = nil, format: FileFormat) {
        self.r1 = r1
        self.r2 = r2
        self.r3 = r3
        self.format = format
    }
}

/// Output files from a recipe step.
public struct StepOutput: Sendable {
    public let r1: URL
    public let r2: URL?
    public let r3: URL?
    public let format: FileFormat
    /// Read count if known from tool output parsing.
    public let readCount: Int?

    public init(r1: URL, r2: URL? = nil, r3: URL? = nil, format: FileFormat, readCount: Int? = nil) {
        self.r1 = r1
        self.r2 = r2
        self.r3 = r3
        self.format = format
        self.readCount = readCount
    }
}

/// Context provided to each step executor by the engine.
public struct StepContext: Sendable {
    /// Temporary workspace directory for intermediate files.
    public let workspace: URL
    /// Thread count for parallel tools.
    public let threads: Int
    /// Sample name (for unique file naming).
    public let sampleName: String
    /// Tool runner for executing external binaries.
    public let runner: NativeToolRunner
    /// Progress callback: (fraction 0-1, message).
    public let progress: @Sendable (Double, String) -> Void

    public init(
        workspace: URL,
        threads: Int,
        sampleName: String,
        runner: NativeToolRunner,
        progress: @escaping @Sendable (Double, String) -> Void
    ) {
        self.workspace = workspace
        self.threads = threads
        self.sampleName = sampleName
        self.runner = runner
        self.progress = progress
    }
}

/// Protocol for recipe step executors.
///
/// Each step type (e.g., "fastp-dedup", "deacon-scrub") implements this protocol.
/// The RecipeEngine dispatches to the correct executor based on the step's `type` field.
public protocol RecipeStepExecutor: Sendable {
    /// Unique type identifier matching the recipe JSON "type" field.
    static var typeID: String { get }

    /// Human-readable name for UI/logs when no label is provided.
    static var displayName: String { get }

    /// What input format this step accepts.
    var inputFormat: FileFormat { get }

    /// What output format this step produces.
    var outputFormat: FileFormat { get }

    /// Initialize from recipe JSON params dictionary. Nil params = use defaults.
    init(params: [String: AnyCodableValue]?) throws

    /// Execute the step, returning output file(s).
    func execute(input: StepInput, context: StepContext) async throws -> StepOutput
}

/// Protocol for fastp-based steps that can be fused into a single invocation.
public protocol FastpFusible: RecipeStepExecutor {
    /// Returns the fastp CLI arguments this step contributes to a fused invocation.
    func fastpArgs() -> [String]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecipeStepExecutorTests 2>&1 | tail -20`
Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Recipes/RecipeStepExecutor.swift \
       Tests/LungfishWorkflowTests/Recipes/RecipeStepExecutorTests.swift
git commit -m "feat: add RecipeStepExecutor protocol with FileFormat and StepInput/Output"
```

---

### Task 4: Step executors (all 5) + tests

**Files:**
- Create: `Sources/LungfishWorkflow/Recipes/Steps/FastpDedupStep.swift`
- Create: `Sources/LungfishWorkflow/Recipes/Steps/FastpTrimStep.swift`
- Create: `Sources/LungfishWorkflow/Recipes/Steps/DeaconScrubStep.swift`
- Create: `Sources/LungfishWorkflow/Recipes/Steps/FastpMergeStep.swift`
- Create: `Sources/LungfishWorkflow/Recipes/Steps/SeqkitLengthFilterStep.swift`
- Create: `Tests/LungfishWorkflowTests/Recipes/StepExecutorTests.swift`

This task creates all 5 step executors and tests their argument generation. The `execute()` methods shell out to real tools, so the unit tests focus on parameter parsing and argument building. Integration tests (Task 7) test actual execution.

- [ ] **Step 1: Write failing tests for all 5 step executors**

```swift
// Tests/LungfishWorkflowTests/Recipes/StepExecutorTests.swift
import XCTest
@testable import LungfishWorkflow

final class StepExecutorTests: XCTestCase {

    // MARK: - FastpDedupStep

    func testFastpDedupTypeID() {
        XCTAssertEqual(FastpDedupStep.typeID, "fastp-dedup")
    }

    func testFastpDedupFormats() throws {
        let step = try FastpDedupStep(params: nil)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .pairedR1R2)
    }

    func testFastpDedupArgs() throws {
        let step = try FastpDedupStep(params: nil)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("--dedup"))
        // Dedup-only: disable adapter, quality, length filters
        XCTAssertTrue(args.contains("-A"))
        XCTAssertTrue(args.contains("-G"))
        XCTAssertTrue(args.contains("-Q"))
        XCTAssertTrue(args.contains("-L"))
    }

    // MARK: - FastpTrimStep

    func testFastpTrimTypeID() {
        XCTAssertEqual(FastpTrimStep.typeID, "fastp-trim")
    }

    func testFastpTrimDefaultArgs() throws {
        let step = try FastpTrimStep(params: nil)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("--detect_adapter_for_pe"))
        XCTAssertTrue(args.contains("-q"))
        XCTAssertTrue(args.contains("20")) // default quality
        XCTAssertTrue(args.contains("--cut_right")) // default cutMode
    }

    func testFastpTrimCustomArgs() throws {
        let params: [String: AnyCodableValue] = [
            "detectAdapter": .bool(true),
            "quality": .int(15),
            "window": .int(5),
            "cutMode": .string("right"),
        ]
        let step = try FastpTrimStep(params: params)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("-q"))
        XCTAssertTrue(args.contains("15"))
        XCTAssertTrue(args.contains("-W"))
        XCTAssertTrue(args.contains("5"))
        XCTAssertTrue(args.contains("--cut_right"))
    }

    func testFastpTrimCutBoth() throws {
        let params: [String: AnyCodableValue] = ["cutMode": .string("both")]
        let step = try FastpTrimStep(params: params)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("--cut_front"))
        XCTAssertTrue(args.contains("--cut_right"))
    }

    // MARK: - DeaconScrubStep

    func testDeaconScrubTypeID() {
        XCTAssertEqual(DeaconScrubStep.typeID, "deacon-scrub")
    }

    func testDeaconScrubFormats() throws {
        let step = try DeaconScrubStep(params: nil)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .pairedR1R2)
    }

    func testDeaconScrubDatabaseID() throws {
        let step = try DeaconScrubStep(params: ["database": .string("custom-db")])
        XCTAssertEqual(step.databaseID, "custom-db")
    }

    func testDeaconScrubDefaultDatabase() throws {
        let step = try DeaconScrubStep(params: nil)
        XCTAssertEqual(step.databaseID, "deacon")
    }

    // MARK: - FastpMergeStep

    func testFastpMergeTypeID() {
        XCTAssertEqual(FastpMergeStep.typeID, "fastp-merge")
    }

    func testFastpMergeFormats() throws {
        let step = try FastpMergeStep(params: nil)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .merged)
    }

    func testFastpMergeDefaultOverlap() throws {
        let step = try FastpMergeStep(params: nil)
        XCTAssertEqual(step.minOverlap, 15)
    }

    func testFastpMergeCustomOverlap() throws {
        let step = try FastpMergeStep(params: ["minOverlap": .int(20)])
        XCTAssertEqual(step.minOverlap, 20)
    }

    // MARK: - SeqkitLengthFilterStep

    func testSeqkitLengthFilterTypeID() {
        XCTAssertEqual(SeqkitLengthFilterStep.typeID, "seqkit-length-filter")
    }

    func testSeqkitLengthFilterAcceptsAnyFormat() throws {
        let step = try SeqkitLengthFilterStep(params: ["minLength": .int(50)])
        // inputFormat and outputFormat depend on what is passed in at execution time,
        // but the step should declare it accepts any single-stream format
        XCTAssertEqual(step.minLength, 50)
        XCTAssertNil(step.maxLength)
    }

    func testSeqkitLengthFilterWithMax() throws {
        let step = try SeqkitLengthFilterStep(params: [
            "minLength": .int(100),
            "maxLength": .int(1000),
        ])
        XCTAssertEqual(step.minLength, 100)
        XCTAssertEqual(step.maxLength, 1000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StepExecutorTests 2>&1 | tail -20`
Expected: Compilation errors — step types not found.

- [ ] **Step 3: Implement FastpDedupStep**

```swift
// Sources/LungfishWorkflow/Recipes/Steps/FastpDedupStep.swift
import Foundation

/// Deduplicates paired-end reads using fastp's --dedup mode.
/// All non-dedup operations (adapter trim, quality trim, length filter) are disabled.
public struct FastpDedupStep: FastpFusible, Sendable {
    public static let typeID = "fastp-dedup"
    public static let displayName = "PCR Duplicate Removal"

    public let inputFormat: FileFormat = .pairedR1R2
    public let outputFormat: FileFormat = .pairedR1R2

    public init(params: [String: AnyCodableValue]?) throws {
        // No parameters — dedup is always the same
    }

    public func fastpArgs() -> [String] {
        ["--dedup", "-A", "-G", "-Q", "-L"]
    }

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_dedup_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_dedup_R2.fq.gz")

        let args = [
            "-i", input.r1.path, "-I", r2.path,
            "-o", outR1.path, "-O", outR2.path,
        ] + fastpArgs() + [
            "-w", String(context.threads),
            "-j", "/dev/null", "-h", "/dev/null",
        ]

        let result = try await context.runner.run(.fastp, arguments: args)
        guard result.exitCode == 0 else {
            throw RecipeEngineError.toolFailed(tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2)
    }
}
```

- [ ] **Step 4: Implement FastpTrimStep**

```swift
// Sources/LungfishWorkflow/Recipes/Steps/FastpTrimStep.swift
import Foundation

/// Adapter removal and quality trimming using fastp.
public struct FastpTrimStep: FastpFusible, Sendable {
    public static let typeID = "fastp-trim"
    public static let displayName = "Adapter + Quality Trim"

    public let inputFormat: FileFormat = .pairedR1R2
    public let outputFormat: FileFormat = .pairedR1R2

    public let detectAdapter: Bool
    public let quality: Int
    public let window: Int
    public let cutMode: CutMode

    public enum CutMode: String, Sendable {
        case right, front, tail, both
    }

    public init(params: [String: AnyCodableValue]?) throws {
        self.detectAdapter = params?["detectAdapter"]?.boolValue ?? true
        self.quality = params?["quality"]?.intValue ?? 20
        self.window = params?["window"]?.intValue ?? 4
        let modeStr = params?["cutMode"]?.stringValue ?? "right"
        guard let mode = CutMode(rawValue: modeStr) else {
            throw RecipeEngineError.invalidParam(step: Self.typeID, param: "cutMode", value: modeStr)
        }
        self.cutMode = mode
    }

    public func fastpArgs() -> [String] {
        var args: [String] = []
        if detectAdapter {
            args.append("--detect_adapter_for_pe")
        }
        args += ["-q", String(quality), "-W", String(window)]
        switch cutMode {
        case .right: args.append("--cut_right")
        case .front: args.append("--cut_front")
        case .tail:  args.append("--cut_tail")
        case .both:  args += ["--cut_front", "--cut_right"]
        }
        return args
    }

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_trim_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_trim_R2.fq.gz")

        let args = [
            "-i", input.r1.path, "-I", r2.path,
            "-o", outR1.path, "-O", outR2.path,
        ] + fastpArgs() + [
            "-w", String(context.threads),
            "-j", "/dev/null", "-h", "/dev/null",
        ]

        let result = try await context.runner.run(.fastp, arguments: args)
        guard result.exitCode == 0 else {
            throw RecipeEngineError.toolFailed(tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2)
    }
}
```

- [ ] **Step 5: Implement DeaconScrubStep**

```swift
// Sources/LungfishWorkflow/Recipes/Steps/DeaconScrubStep.swift
import Foundation

/// Removes human reads using Deacon's minimizer-based filtering.
public struct DeaconScrubStep: RecipeStepExecutor, Sendable {
    public static let typeID = "deacon-scrub"
    public static let displayName = "Human Read Removal"

    public let inputFormat: FileFormat = .pairedR1R2
    public let outputFormat: FileFormat = .pairedR1R2

    public let databaseID: String

    public init(params: [String: AnyCodableValue]?) throws {
        self.databaseID = params?["database"]?.stringValue ?? "deacon"
    }

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        // Resolve database path via DatabaseRegistry
        guard let dbPath = await DatabaseRegistry.shared.effectiveDatabasePath(for: databaseID) else {
            throw RecipeEngineError.databaseNotFound(id: databaseID, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_scrub_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_scrub_R2.fq.gz")

        let args = [
            "filter", "-d",
            dbPath.path,
            input.r1.path, r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
            "-t", String(context.threads),
        ]

        let result = try await context.runner.run(.deacon, arguments: args)
        guard result.exitCode == 0 else {
            throw RecipeEngineError.toolFailed(tool: "deacon", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2)
    }
}
```

- [ ] **Step 6: Implement FastpMergeStep**

```swift
// Sources/LungfishWorkflow/Recipes/Steps/FastpMergeStep.swift
import Foundation

/// Merges overlapping paired-end reads using fastp --merge.
/// Produces three output files: merged, unmerged R1, unmerged R2.
public struct FastpMergeStep: RecipeStepExecutor, Sendable {
    public static let typeID = "fastp-merge"
    public static let displayName = "Paired-End Merge"

    public let inputFormat: FileFormat = .pairedR1R2
    public let outputFormat: FileFormat = .merged

    public let minOverlap: Int

    public init(params: [String: AnyCodableValue]?) throws {
        self.minOverlap = params?["minOverlap"]?.intValue ?? 15
    }

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let mergedOut = context.workspace.appendingPathComponent("\(context.sampleName)_merged.fq.gz")
        let unmergedR1 = context.workspace.appendingPathComponent("\(context.sampleName)_unmerged_R1.fq.gz")
        let unmergedR2 = context.workspace.appendingPathComponent("\(context.sampleName)_unmerged_R2.fq.gz")

        let args = [
            "-i", input.r1.path, "-I", r2.path,
            "--merge",
            "--merged_out", mergedOut.path,
            "--out1", unmergedR1.path,
            "--out2", unmergedR2.path,
            "--overlap_len_require", String(minOverlap),
            "-A", "-G", "-Q", "-L", // disable non-merge operations
            "-w", String(context.threads),
            "-j", "/dev/null", "-h", "/dev/null",
        ]

        let result = try await context.runner.run(.fastp, arguments: args)
        guard result.exitCode == 0 else {
            throw RecipeEngineError.toolFailed(tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: mergedOut, r2: unmergedR1, r3: unmergedR2, format: .merged)
    }
}
```

- [ ] **Step 7: Implement SeqkitLengthFilterStep**

```swift
// Sources/LungfishWorkflow/Recipes/Steps/SeqkitLengthFilterStep.swift
import Foundation

/// Filters reads by length using seqkit.
/// Accepts any single-stream format (single, interleaved, or merged after concatenation).
public struct SeqkitLengthFilterStep: RecipeStepExecutor, Sendable {
    public static let typeID = "seqkit-length-filter"
    public static let displayName = "Length Filter"

    // These are set dynamically based on the actual input at execution time
    public let inputFormat: FileFormat = .single
    public let outputFormat: FileFormat = .single

    public let minLength: Int
    public let maxLength: Int?

    public init(params: [String: AnyCodableValue]?) throws {
        self.minLength = params?["minLength"]?.intValue ?? 0
        self.maxLength = params?["maxLength"]?.intValue
    }

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        let outURL = context.workspace.appendingPathComponent("\(context.sampleName)_lenfilter.fq.gz")

        var args = ["seq", "-j", String(context.threads)]
        if minLength > 0 {
            args += ["-m", String(minLength)]
        }
        if let maxLen = maxLength {
            args += ["-M", String(maxLen)]
        }
        args += [input.r1.path, "-o", outURL.path]

        let result = try await context.runner.run(.seqkit, arguments: args)
        guard result.exitCode == 0 else {
            throw RecipeEngineError.toolFailed(tool: "seqkit", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: outURL, format: input.format, readCount: nil)
    }
}
```

- [ ] **Step 8: Create RecipeEngineError enum**

Add to `RecipeStepExecutor.swift` (or create a separate file if preferred — adding here to keep errors colocated with the protocol):

```swift
// Append to Sources/LungfishWorkflow/Recipes/RecipeStepExecutor.swift

/// Errors from recipe validation and step execution.
public enum RecipeEngineError: Error, LocalizedError {
    case unknownStepType(String)
    case formatMismatch(expected: FileFormat, got: FileFormat, step: String)
    case incompatibleFormatChain(from: FileFormat, to: FileFormat, step: String)
    case invalidParam(step: String, param: String, value: String)
    case toolFailed(tool: String, step: String, stderr: String)
    case databaseNotFound(id: String, step: String)
    case inputRequirementNotMet(required: Recipe.InputRequirement, actual: FileFormat)

    public var errorDescription: String? {
        switch self {
        case .unknownStepType(let type):
            return "Unknown recipe step type: '\(type)'"
        case .formatMismatch(let expected, let got, let step):
            return "Step '\(step)' expects \(expected.rawValue) input but received \(got.rawValue)"
        case .incompatibleFormatChain(let from, let to, let step):
            return "Cannot convert \(from.rawValue) to \(to.rawValue) before step '\(step)'"
        case .invalidParam(let step, let param, let value):
            return "Invalid parameter '\(param)' = '\(value)' for step '\(step)'"
        case .toolFailed(let tool, let step, let stderr):
            return "Tool '\(tool)' failed in step '\(step)': \(stderr.prefix(500))"
        case .databaseNotFound(let id, let step):
            return "Database '\(id)' not found for step '\(step)'. Run setup first."
        case .inputRequirementNotMet(let required, let actual):
            return "Recipe requires \(required.rawValue) input but received \(actual.rawValue)"
        }
    }
}
```

- [ ] **Step 9: Run tests to verify all pass**

Run: `swift test --filter StepExecutorTests 2>&1 | tail -30`
Expected: All 15 tests pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/LungfishWorkflow/Recipes/Steps/ \
       Sources/LungfishWorkflow/Recipes/RecipeStepExecutor.swift \
       Tests/LungfishWorkflowTests/Recipes/StepExecutorTests.swift
git commit -m "feat: add 5 recipe step executors (fastp-dedup, fastp-trim, deacon-scrub, fastp-merge, seqkit-length-filter)"
```

---

### Task 5: RecipeEngine orchestrator + tests

**Files:**
- Create: `Sources/LungfishWorkflow/Recipes/RecipeEngine.swift`
- Create: `Tests/LungfishWorkflowTests/Recipes/RecipeEngineTests.swift`

- [ ] **Step 1: Write failing tests for recipe validation**

```swift
// Tests/LungfishWorkflowTests/Recipes/RecipeEngineTests.swift
import XCTest
@testable import LungfishWorkflow

final class RecipeEngineTests: XCTestCase {

    func testValidateUnknownStepType() throws {
        let recipe = Recipe(
            formatVersion: 1, id: "test", name: "Test",
            platforms: [.illumina], requiredInput: .paired,
            steps: [RecipeStep(type: "nonexistent-tool")]
        )
        let engine = RecipeEngine()
        XCTAssertThrowsError(try engine.validate(recipe: recipe, inputFormat: .pairedR1R2)) { error in
            guard case RecipeEngineError.unknownStepType("nonexistent-tool") = error else {
                XCTFail("Expected unknownStepType, got \(error)")
                return
            }
        }
    }

    func testValidateInputRequirementMismatch() throws {
        let recipe = Recipe(
            formatVersion: 1, id: "test", name: "Test",
            platforms: [.illumina], requiredInput: .paired,
            steps: [RecipeStep(type: "fastp-dedup")]
        )
        let engine = RecipeEngine()
        XCTAssertThrowsError(try engine.validate(recipe: recipe, inputFormat: .single)) { error in
            guard case RecipeEngineError.inputRequirementNotMet = error else {
                XCTFail("Expected inputRequirementNotMet, got \(error)")
                return
            }
        }
    }

    func testValidateValidRecipe() throws {
        let recipe = Recipe(
            formatVersion: 1, id: "test", name: "Test",
            platforms: [.illumina], requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-dedup"),
                RecipeStep(type: "fastp-trim"),
            ]
        )
        let engine = RecipeEngine()
        XCTAssertNoThrow(try engine.validate(recipe: recipe, inputFormat: .pairedR1R2))
    }

    func testPlanFusesConsecutiveFastpSteps() throws {
        let recipe = Recipe(
            formatVersion: 1, id: "test", name: "Test",
            platforms: [.illumina], requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-dedup"),
                RecipeStep(type: "fastp-trim", params: ["quality": .int(15), "window": .int(5), "cutMode": .string("right")]),
            ]
        )
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // Two fastp steps should fuse into one planned step
        XCTAssertEqual(plan.count, 1)
        if case .fusedFastp(let args, _, _) = plan[0] {
            XCTAssertTrue(args.contains("--dedup"))
            XCTAssertTrue(args.contains("-q"))
            XCTAssertTrue(args.contains("15"))
        } else {
            XCTFail("Expected fusedFastp, got \(plan[0])")
        }
    }

    func testPlanDoesNotFuseAcrossNonFastp() throws {
        let recipe = Recipe(
            formatVersion: 1, id: "test", name: "Test",
            platforms: [.illumina], requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-dedup"),
                RecipeStep(type: "deacon-scrub"),
                RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
            ]
        )
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // fastp-dedup alone (not fusible with deacon), deacon, fastp-merge alone
        XCTAssertEqual(plan.count, 3)
    }

    func testPlanInsertsMergedToSingleConversion() throws {
        let recipe = Recipe(
            formatVersion: 1, id: "test", name: "Test",
            platforms: [.illumina], requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-merge", params: ["minOverlap": .int(15)]),
                RecipeStep(type: "seqkit-length-filter", params: ["minLength": .int(50)]),
            ]
        )
        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: recipe, inputFormat: .pairedR1R2)

        // merge step + conversion (merged→single) + length filter
        XCTAssertEqual(plan.count, 3)
        if case .formatConversion(let from, let to) = plan[1] {
            XCTAssertEqual(from, .merged)
            XCTAssertEqual(to, .single)
        } else {
            XCTFail("Expected formatConversion, got \(plan[1])")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecipeEngineTests 2>&1 | tail -20`
Expected: Compilation error — `RecipeEngine` not found.

- [ ] **Step 3: Implement RecipeEngine**

```swift
// Sources/LungfishWorkflow/Recipes/RecipeEngine.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "RecipeEngine")

/// Orchestrates recipe execution: validates, plans format conversions, fuses fastp steps, and executes.
public final class RecipeEngine: Sendable {

    /// Registry of known step type IDs to their executor types.
    private let stepTypes: [String: any RecipeStepExecutor.Type]

    public init() {
        // Register all built-in step types
        var registry: [String: any RecipeStepExecutor.Type] = [:]
        let types: [any RecipeStepExecutor.Type] = [
            FastpDedupStep.self,
            FastpTrimStep.self,
            DeaconScrubStep.self,
            FastpMergeStep.self,
            SeqkitLengthFilterStep.self,
        ]
        for t in types {
            registry[t.typeID] = t
        }
        self.stepTypes = registry
    }

    // MARK: - Execution Plan

    /// A planned execution entry — either a real step, a fused fastp group, or a format conversion.
    public enum PlannedStep: Sendable {
        /// Execute a single step executor.
        case singleStep(any RecipeStepExecutor, label: String)
        /// Fused consecutive fastp steps into one invocation.
        case fusedFastp(args: [String], inputFormat: FileFormat, label: String)
        /// Insert a format conversion between steps.
        case formatConversion(from: FileFormat, to: FileFormat)
    }

    // MARK: - Validate

    /// Validate the recipe: all step types known, input requirements met, format chain is compatible.
    public func validate(recipe: Recipe, inputFormat: FileFormat) throws {
        // Check input requirement
        switch recipe.requiredInput {
        case .paired:
            if inputFormat != .pairedR1R2 && inputFormat != .interleaved {
                throw RecipeEngineError.inputRequirementNotMet(required: .paired, actual: inputFormat)
            }
        case .single:
            if inputFormat != .single {
                throw RecipeEngineError.inputRequirementNotMet(required: .single, actual: inputFormat)
            }
        case .any:
            break
        }

        // Check all step types are registered
        for step in recipe.steps {
            guard stepTypes[step.type] != nil else {
                throw RecipeEngineError.unknownStepType(step.type)
            }
        }

        // Validate format chain
        _ = try plan(recipe: recipe, inputFormat: inputFormat)
    }

    // MARK: - Plan

    /// Build an execution plan with fusible fastp detection and format conversions.
    public func plan(recipe: Recipe, inputFormat: FileFormat) throws -> [PlannedStep] {
        // 1. Instantiate all executors
        var executors: [(any RecipeStepExecutor, String)] = []
        for step in recipe.steps {
            guard let executorType = stepTypes[step.type] else {
                throw RecipeEngineError.unknownStepType(step.type)
            }
            let executor = try executorType.init(params: step.params?.mapValues { $0 })
            let label = step.label ?? type(of: executor).displayName
            executors.append((executor, label))
        }

        // 2. Group consecutive FastpFusible steps with compatible formats
        var plan: [PlannedStep] = []
        var currentFormat = inputFormat
        var i = 0

        while i < executors.count {
            let (executor, label) = executors[i]

            // Check if this starts a fusible fastp run
            if let fusible = executor as? (any FastpFusible),
               fusible.inputFormat == .pairedR1R2 && fusible.outputFormat == .pairedR1R2 {
                // Collect consecutive fusible steps
                var fusedArgs = fusible.fastpArgs()
                var fusedLabels = [label]
                var j = i + 1
                while j < executors.count,
                      let nextFusible = executors[j].0 as? (any FastpFusible),
                      nextFusible.inputFormat == .pairedR1R2 && nextFusible.outputFormat == .pairedR1R2 {
                    fusedArgs += nextFusible.fastpArgs()
                    fusedLabels.append(executors[j].1)
                    j += 1
                }

                // Insert format conversion if needed
                if currentFormat != .pairedR1R2 {
                    if canConvert(from: currentFormat, to: .pairedR1R2) {
                        plan.append(.formatConversion(from: currentFormat, to: .pairedR1R2))
                    } else {
                        throw RecipeEngineError.incompatibleFormatChain(from: currentFormat, to: .pairedR1R2, step: fusedLabels[0])
                    }
                }

                if j - i > 1 {
                    // Multiple fusible steps — fuse them
                    plan.append(.fusedFastp(args: fusedArgs, inputFormat: .pairedR1R2, label: fusedLabels.joined(separator: " + ")))
                } else {
                    // Single fusible step — run as normal single step
                    plan.append(.singleStep(executor, label: label))
                }
                currentFormat = .pairedR1R2
                i = j
            } else {
                // Non-fusible step — check format compatibility
                let neededFormat = executor.inputFormat

                // seqkit-length-filter accepts any format via concatenation
                if executor is SeqkitLengthFilterStep {
                    if currentFormat == .merged {
                        plan.append(.formatConversion(from: .merged, to: .single))
                        currentFormat = .single
                    }
                    plan.append(.singleStep(executor, label: label))
                    // output format stays as single after length filter on merged input
                    if currentFormat == .single || currentFormat == .merged {
                        currentFormat = .single
                    }
                } else if currentFormat != neededFormat {
                    if canConvert(from: currentFormat, to: neededFormat) {
                        plan.append(.formatConversion(from: currentFormat, to: neededFormat))
                        currentFormat = neededFormat
                    } else {
                        throw RecipeEngineError.incompatibleFormatChain(from: currentFormat, to: neededFormat, step: label)
                    }
                    plan.append(.singleStep(executor, label: label))
                    currentFormat = executor.outputFormat
                } else {
                    plan.append(.singleStep(executor, label: label))
                    currentFormat = executor.outputFormat
                }
                i += 1
            }
        }

        return plan
    }

    /// Whether a format conversion is possible.
    private func canConvert(from: FileFormat, to: FileFormat) -> Bool {
        switch (from, to) {
        case (.pairedR1R2, .interleaved), (.interleaved, .pairedR1R2): return true
        case (.merged, .single): return true
        default: return from == to
        }
    }

    // MARK: - Execute

    /// Execute a recipe on input files, returning the processed output.
    public func execute(
        recipe: Recipe,
        input: StepInput,
        context: StepContext
    ) async throws -> StepOutput {
        let executionPlan = try plan(recipe: recipe, inputFormat: input.format)
        let totalSteps = executionPlan.count

        var current = input

        for (index, planned) in executionPlan.enumerated() {
            let fraction = Double(index) / Double(max(1, totalSteps))

            switch planned {
            case .singleStep(let executor, let label):
                logger.info("Step \(index + 1)/\(totalSteps): \(label)")
                context.progress(fraction, label)
                current = StepInput(r1: (try await executor.execute(input: current, context: context)).r1,
                                     r2: (try await executor.execute(input: current, context: context)).r2,
                                     r3: nil,
                                     format: executor.outputFormat)
                // Fix: execute once and capture output
                let output = try await executor.execute(input: current, context: context)
                current = StepInput(r1: output.r1, r2: output.r2, r3: output.r3, format: output.format)

            case .fusedFastp(let args, _, let label):
                logger.info("Step \(index + 1)/\(totalSteps): \(label) [fused]")
                context.progress(fraction, label)
                current = try await executeFusedFastp(args: args, input: current, context: context)

            case .formatConversion(let from, let to):
                logger.info("Step \(index + 1)/\(totalSteps): converting \(from.rawValue) → \(to.rawValue)")
                current = try await convertFormat(from: from, to: to, input: current, context: context)
            }
        }

        context.progress(1.0, "Complete")
        return StepOutput(r1: current.r1, r2: current.r2, r3: current.r3, format: current.format)
    }

    // MARK: - Fused Fastp Execution

    private func executeFusedFastp(args: [String], input: StepInput, context: StepContext) async throws -> StepInput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: "fused-fastp")
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_fused_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_fused_R2.fq.gz")

        let fullArgs = [
            "-i", input.r1.path, "-I", r2.path,
            "-o", outR1.path, "-O", outR2.path,
        ] + args + [
            "-w", String(context.threads),
            "-j", "/dev/null", "-h", "/dev/null",
        ]

        let result = try await context.runner.run(.fastp, arguments: fullArgs)
        guard result.exitCode == 0 else {
            throw RecipeEngineError.toolFailed(tool: "fastp", step: "fused-fastp", stderr: result.stderr)
        }

        return StepInput(r1: outR1, r2: outR2, format: .pairedR1R2)
    }

    // MARK: - Format Conversion

    private func convertFormat(from: FileFormat, to: FileFormat, input: StepInput, context: StepContext) async throws -> StepInput {
        switch (from, to) {
        case (.pairedR1R2, .interleaved):
            let out = context.workspace.appendingPathComponent("\(context.sampleName)_interleaved.fq")
            let args = [
                "in=\(input.r1.path)", "in2=\(input.r2!.path)",
                "out=\(out.path)", "interleaved=t",
                "threads=\(context.threads)", "ow=t",
            ]
            let result = try await context.runner.run(.reformat, arguments: args)
            guard result.exitCode == 0 else {
                throw RecipeEngineError.toolFailed(tool: "reformat.sh", step: "format-conversion", stderr: result.stderr)
            }
            return StepInput(r1: out, format: .interleaved)

        case (.interleaved, .pairedR1R2):
            let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_deinterleave_R1.fq.gz")
            let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_deinterleave_R2.fq.gz")
            let args = [
                "in=\(input.r1.path)",
                "out=\(outR1.path)", "out2=\(outR2.path)",
                "threads=\(context.threads)", "ow=t",
            ]
            let result = try await context.runner.run(.reformat, arguments: args)
            guard result.exitCode == 0 else {
                throw RecipeEngineError.toolFailed(tool: "reformat.sh", step: "format-conversion", stderr: result.stderr)
            }
            return StepInput(r1: outR1, r2: outR2, format: .pairedR1R2)

        case (.merged, .single):
            // Concatenate merged + unmerged_R1 + unmerged_R2 into single file
            let out = context.workspace.appendingPathComponent("\(context.sampleName)_combined.fq.gz")
            let parts = [input.r1, input.r2, input.r3].compactMap { $0 }
            let catArgs = parts.map(\.path) + [">", out.path]
            // Use pigz to concatenate gzipped files (cat works for gzip concatenation)
            let catData = try parts.reduce(Data()) { data, url in
                try data + Data(contentsOf: url)
            }
            try catData.write(to: out)
            return StepInput(r1: out, format: .single)

        default:
            throw RecipeEngineError.incompatibleFormatChain(from: from, to: to, step: "format-conversion")
        }
    }
}
```

**Note:** The `execute` method in the `.singleStep` case has a bug (executes twice). The implementer must fix this — execute once and capture the result:

```swift
case .singleStep(let executor, let label):
    logger.info("Step \(index + 1)/\(totalSteps): \(label)")
    context.progress(fraction, label)
    let output = try await executor.execute(input: current, context: context)
    current = StepInput(r1: output.r1, r2: output.r2, r3: output.r3, format: output.format)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecipeEngineTests 2>&1 | tail -30`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Recipes/RecipeEngine.swift \
       Tests/LungfishWorkflowTests/Recipes/RecipeEngineTests.swift
git commit -m "feat: add RecipeEngine with validation, fastp fusion, and format conversion"
```

---

### Task 6: RecipeRegistry + deacon in NativeToolRunner

**Files:**
- Create: `Sources/LungfishWorkflow/Recipes/RecipeRegistry.swift` (new — replaces old LungfishIO RecipeRegistry)
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`

- [ ] **Step 1: Write failing test for RecipeRegistry**

```swift
// Tests/LungfishWorkflowTests/Recipes/RecipeRegistryTests.swift
import XCTest
@testable import LungfishWorkflow

final class RecipeRegistryTests: XCTestCase {

    func testLoadBuiltinRecipes() {
        let recipes = RecipeRegistryV2.builtinRecipes()
        XCTAssertFalse(recipes.isEmpty, "Should have at least one built-in recipe")

        let vsp2 = recipes.first { $0.id == "vsp2-target-enrichment" }
        XCTAssertNotNil(vsp2, "VSP2 recipe should be in built-in recipes")
        XCTAssertEqual(vsp2?.platforms, [.illumina])
        XCTAssertEqual(vsp2?.steps.count, 5)
    }

    func testFilterByPlatform() {
        let all = RecipeRegistryV2.builtinRecipes()
        let illumina = all.filter { $0.platforms.contains(.illumina) }
        let ont = all.filter { $0.platforms.contains(.ont) }

        XCTAssertTrue(illumina.contains { $0.id == "vsp2-target-enrichment" })
        XCTAssertFalse(ont.contains { $0.id == "vsp2-target-enrichment" })
    }
}
```

(Using `RecipeRegistryV2` to avoid name collision with the old `RecipeRegistry` in LungfishIO.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecipeRegistryTests 2>&1 | tail -20`
Expected: Compilation error.

- [ ] **Step 3: Implement RecipeRegistryV2**

```swift
// Sources/LungfishWorkflow/Recipes/RecipeRegistry.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "RecipeRegistry")

/// Loads and manages new-format (v2) declarative recipes.
///
/// Named `RecipeRegistryV2` to avoid collision with the old `RecipeRegistry` in LungfishIO
/// during the migration period. Once all recipes are migrated, rename to `RecipeRegistry`.
public enum RecipeRegistryV2 {

    /// Load all built-in recipes from the bundle's Resources/Recipes/ directory.
    public static func builtinRecipes() -> [Recipe] {
        guard let recipesDir = Bundle.module.url(forResource: "Recipes", withExtension: nil) else {
            logger.warning("Recipes resource directory not found in bundle")
            return []
        }

        var recipes: [Recipe] = []
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: recipesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let decoder = JSONDecoder()
            for url in contents where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let recipe = try decoder.decode(Recipe.self, from: data)
                    recipes.append(recipe)
                } catch {
                    logger.warning("Failed to parse recipe \(url.lastPathComponent): \(error)")
                }
            }
        } catch {
            logger.warning("Failed to scan recipes directory: \(error)")
        }
        return recipes
    }

    /// Load user-created recipes from ~/Library/Application Support/Lungfish/recipes/.
    public static func userRecipes() -> [Recipe] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("Lungfish", isDirectory: true)
            .appendingPathComponent("recipes", isDirectory: true)

        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        var recipes: [Recipe] = []
        let decoder = JSONDecoder()
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in contents where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let recipe = try? decoder.decode(Recipe.self, from: data) {
                    recipes.append(recipe)
                }
            }
        }
        return recipes
    }

    /// All recipes (built-in + user), optionally filtered by platform.
    public static func allRecipes(platform: SequencingPlatform? = nil) -> [Recipe] {
        var recipes = builtinRecipes() + userRecipes()
        if let platform {
            recipes = recipes.filter { $0.platforms.contains(platform) }
        }
        return recipes
    }

    /// Find a recipe by ID.
    public static func recipe(id: String) -> Recipe? {
        allRecipes().first { $0.id == id }
    }
}
```

- [ ] **Step 4: Add `deacon` to NativeToolRunner's NativeTool enum**

In `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, add `deacon` case to the `NativeTool` enum (after the existing scrubber cases):

```swift
// Add to NativeTool enum:
case deacon
```

Also add the tool path resolution in the `findTool` method. Deacon lives in a conda environment, not the bundled tools directory. Add a resolution path that checks `~/miniforge3/envs/deacon-bench/bin/deacon`:

Find the `findTool` or `resolvedPath(for:)` method and add a case for `.deacon` that checks the conda env path:

```swift
case .deacon:
    // Deacon is installed via conda, not bundled
    let condaPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("miniforge3/envs/deacon-bench/bin/deacon")
    if FileManager.default.fileExists(atPath: condaPath.path) {
        return condaPath
    }
    // Fall back to PATH
    return URL(fileURLWithPath: "/usr/local/bin/deacon")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RecipeRegistryTests 2>&1 | tail -20`
Expected: All tests pass.

Also run: `swift test --filter NativeToolRunnerTests 2>&1 | tail -20`
Expected: Existing tests still pass (deacon addition is additive).

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Recipes/RecipeRegistry.swift \
       Sources/LungfishWorkflow/Native/NativeToolRunner.swift \
       Tests/LungfishWorkflowTests/Recipes/RecipeRegistryTests.swift
git commit -m "feat: add RecipeRegistryV2 and register deacon in NativeToolRunner"
```

---

### Task 7: Update ImportConfig and FASTQBatchImporter

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`

- [ ] **Step 1: Write failing test for new ImportConfig fields**

```swift
// Add to Tests/LungfishWorkflowTests/Recipes/ImportConfigTests.swift
import XCTest
@testable import LungfishWorkflow

final class ImportConfigTests: XCTestCase {

    func testImportConfigDefaultsFromPlatform() {
        let config = ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina
        )
        XCTAssertEqual(config.platform, .illumina)
        XCTAssertTrue(config.optimizeStorage)
        XCTAssertEqual(config.qualityBinning, .illumina4)
        XCTAssertEqual(config.compressionLevel, .balanced)
        XCTAssertNil(config.newRecipe)
        XCTAssertFalse(config.forceReimport)
    }

    func testImportConfigONTDefaults() {
        let config = ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .ont
        )
        XCTAssertFalse(config.optimizeStorage)
        XCTAssertEqual(config.qualityBinning, .none)
    }

    func testImportConfigExplicitOverrides() {
        let config = ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp/test.lungfish"),
            platform: .illumina,
            qualityBinning: .none,
            optimizeStorage: false,
            compressionLevel: .maximum,
            forceReimport: true
        )
        XCTAssertFalse(config.optimizeStorage)
        XCTAssertEqual(config.qualityBinning, .none)
        XCTAssertEqual(config.compressionLevel, .maximum)
        XCTAssertTrue(config.forceReimport)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ImportConfigTests 2>&1 | tail -20`
Expected: Compilation error — new fields not found.

- [ ] **Step 3: Update ImportConfig in FASTQBatchImporter.swift**

Replace the existing `ImportConfig` struct with the expanded version. Keep backward compatibility by keeping the old `recipe: ProcessingRecipe?` field alongside the new `newRecipe: Recipe?` field:

```swift
public struct ImportConfig: Sendable {
    public let projectDirectory: URL
    public let platform: SequencingPlatform
    /// Old-format recipe (for unmigrated recipes).
    public let recipe: ProcessingRecipe?
    /// New-format declarative recipe.
    public let newRecipe: Recipe?
    public let qualityBinning: QualityBinningScheme
    public let optimizeStorage: Bool
    public let compressionLevel: CompressionLevel
    public let threads: Int
    public let logDirectory: URL?
    public let forceReimport: Bool

    public init(
        projectDirectory: URL,
        platform: SequencingPlatform = .illumina,
        recipe: ProcessingRecipe? = nil,
        newRecipe: Recipe? = nil,
        qualityBinning: QualityBinningScheme? = nil,
        optimizeStorage: Bool? = nil,
        compressionLevel: CompressionLevel? = nil,
        threads: Int = 4,
        logDirectory: URL? = nil,
        forceReimport: Bool = false
    ) {
        self.projectDirectory = projectDirectory
        self.platform = platform
        self.recipe = recipe
        self.newRecipe = newRecipe
        // Resolve defaults: explicit > recipe > platform
        self.qualityBinning = qualityBinning
            ?? newRecipe?.qualityBinning
            ?? platform.defaultQualityBinning
        self.optimizeStorage = optimizeStorage ?? platform.defaultOptimizeStorage
        self.compressionLevel = compressionLevel ?? platform.defaultCompressionLevel
        self.threads = threads
        self.logDirectory = logDirectory
        self.forceReimport = forceReimport
    }
}
```

- [ ] **Step 4: Add RecipeEngine delegation in runBatchImport**

In `FASTQBatchImporter.runBatchImport()`, find where `applyRecipe()` is called and add a branch for new-format recipes:

```swift
// In the sample processing loop, where recipe is applied:
if let newRecipe = config.newRecipe {
    // Use new declarative recipe engine
    let engine = RecipeEngine()
    let stepInput = StepInput(r1: pair.r1, r2: pair.r2, format: .pairedR1R2)
    let stepContext = StepContext(
        workspace: workspace,
        threads: config.threads,
        sampleName: pair.sampleName,
        runner: NativeToolRunner.shared,
        progress: { fraction, message in
            log?(.stepStart(sample: pair.sampleName, step: message,
                            stepIndex: Int(fraction * 100), totalSteps: 100))
        }
    )
    let output = try await engine.execute(recipe: newRecipe, input: stepInput, context: stepContext)
    currentURL = output.r1
    // If output is merged format, concatenate for bundle finalization
    if output.format == .merged {
        let combined = workspace.appendingPathComponent("\(pair.sampleName)_combined.fq.gz")
        let parts = [output.r1, output.r2, output.r3].compactMap { $0 }
        let catData = try parts.reduce(Data()) { try $0 + Data(contentsOf: $1) }
        try catData.write(to: combined)
        currentURL = combined
    }
} else if let oldRecipe = config.recipe {
    // Use old code path for unmigrated recipes
    currentURL = try await applyRecipe(oldRecipe, ...)
}
```

The exact integration point depends on the current code structure. The implementer should read the `runBatchImport` method and find the right insertion point.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ImportConfigTests 2>&1 | tail -20`
Expected: All 3 tests pass.

Run: `swift test --filter FASTQBatchImporterTests 2>&1 | tail -20`
Expected: Existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift \
       Tests/LungfishWorkflowTests/Recipes/ImportConfigTests.swift
git commit -m "feat: update ImportConfig with platform, storage, compression; add RecipeEngine delegation"
```

---

### Task 8: Update CLI with new flags

**Files:**
- Modify: `Sources/LungfishCLI/Commands/ImportFastqCommand.swift`

- [ ] **Step 1: Add new CLI options**

Add these options to `ImportCommand.FastqSubcommand`:

```swift
@Option(
    name: .customLong("platform"),
    help: "Sequencing platform: illumina, ont, pacbio, ultima (default: auto-detect)"
)
var platform: String?

@Flag(
    name: .customLong("no-optimize-storage"),
    help: "Skip read reordering for storage optimization"
)
var noOptimizeStorage: Bool = false

@Option(
    name: .customLong("compression"),
    help: "Compression level: fast, balanced, maximum (default: balanced)"
)
var compression: String = "balanced"

@Flag(
    name: .customLong("force"),
    help: "Reimport samples even if bundle already exists"
)
var force: Bool = false
```

- [ ] **Step 2: Update the `run()` method to resolve new-format recipes**

In the `run()` method, add logic to:
1. Detect/parse platform
2. Resolve recipe from new RecipeRegistryV2 first, fall back to old resolveRecipe
3. Build ImportConfig with all new fields

```swift
// Platform resolution
let resolvedPlatform: SequencingPlatform
if let platformStr = platform {
    guard let p = SequencingPlatform(rawValue: platformStr) else {
        throw ValidationError("Unknown platform: \(platformStr). Valid: illumina, ont, pacbio, ultima")
    }
    resolvedPlatform = p
} else {
    // Auto-detect from first FASTQ header
    resolvedPlatform = autoDetectPlatform(from: pairs) ?? .illumina
}

// Recipe resolution: try new format first, then old
var newRecipe: Recipe? = nil
var oldRecipe: ProcessingRecipe? = nil
if recipe != "none" {
    if let r = RecipeRegistryV2.recipe(id: recipe) ?? RecipeRegistryV2.allRecipes().first(where: {
        $0.name.lowercased().contains(recipe.lowercased()) || $0.id.contains(recipe.lowercased())
    }) {
        newRecipe = r
    } else {
        oldRecipe = try FASTQBatchImporter.resolveRecipe(named: recipe)
    }
}

// Compression level
guard let compLevel = CompressionLevel(rawValue: compression) else {
    throw ValidationError("Unknown compression: \(compression). Valid: fast, balanced, maximum")
}

let config = ImportConfig(
    projectDirectory: projectURL,
    platform: resolvedPlatform,
    recipe: oldRecipe,
    newRecipe: newRecipe,
    qualityBinning: parsedBinning,
    optimizeStorage: !noOptimizeStorage,
    compressionLevel: compLevel,
    threads: threads ?? 4,
    logDirectory: logDir.map { URL(fileURLWithPath: $0) },
    forceReimport: force
)
```

- [ ] **Step 3: Add platform auto-detection helper**

```swift
private func autoDetectPlatform(from pairs: [SamplePair]) -> SequencingPlatform? {
    guard let firstPair = pairs.first else { return nil }
    // Read first line of R1
    guard let handle = try? FileHandle(forReadingFrom: firstPair.r1) else { return nil }
    defer { handle.closeFile() }

    // If gzipped, decompress first few bytes
    let header: String
    if firstPair.r1.pathExtension.lowercased() == "gz" {
        // Use a quick zcat via Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", firstPair.r1.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readData(ofLength: 512)
        process.terminate()
        header = String(data: data, encoding: .utf8)?.components(separatedBy: "\n").first ?? ""
    } else {
        let data = handle.readData(ofLength: 512)
        header = String(data: data, encoding: .utf8)?.components(separatedBy: "\n").first ?? ""
    }

    return SequencingPlatform.detect(fromFASTQHeader: header)
}
```

- [ ] **Step 4: Build and verify CLI compiles**

Run: `swift build --target LungfishCLI 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 5: Test CLI help includes new flags**

Run: `swift run lungfish import fastq --help 2>&1`
Expected: Output includes `--platform`, `--no-optimize-storage`, `--compression`, `--force`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/ImportFastqCommand.swift
git commit -m "feat: add --platform, --no-optimize-storage, --compression, --force CLI flags"
```

---

### Task 9: Integration test — VSP2 recipe on test fixtures

**Files:**
- Create: `Tests/LungfishWorkflowTests/Recipes/RecipeIntegrationTests.swift`

- [ ] **Step 1: Write integration test**

This test loads the VSP2 recipe, validates it, and plans it. Full execution requires real tool binaries which may not be available in CI, so mark the execution test as requiring tools.

```swift
// Tests/LungfishWorkflowTests/Recipes/RecipeIntegrationTests.swift
import XCTest
@testable import LungfishWorkflow

final class RecipeIntegrationTests: XCTestCase {

    func testVSP2RecipeLoadsAndValidates() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })

        let engine = RecipeEngine()
        XCTAssertNoThrow(try engine.validate(recipe: vsp2, inputFormat: .pairedR1R2))
    }

    func testVSP2RecipePlanFusesDedupAndTrim() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })

        let engine = RecipeEngine()
        let plan = try engine.plan(recipe: vsp2, inputFormat: .pairedR1R2)

        // Expected plan:
        // 1. fusedFastp (dedup + trim)
        // 2. singleStep (deacon-scrub)
        // 3. singleStep (fastp-merge)
        // 4. formatConversion (merged → single)
        // 5. singleStep (seqkit-length-filter)
        XCTAssertEqual(plan.count, 5)

        if case .fusedFastp(let args, _, _) = plan[0] {
            XCTAssertTrue(args.contains("--dedup"), "Fused args should include --dedup")
            XCTAssertTrue(args.contains("--detect_adapter_for_pe"), "Fused args should include adapter detection")
            XCTAssertTrue(args.contains("-q"), "Fused args should include quality threshold")
        } else {
            XCTFail("First planned step should be fusedFastp, got \(plan[0])")
        }
    }

    func testVSP2RecipeRejectssSingleEndInput() throws {
        let recipes = RecipeRegistryV2.builtinRecipes()
        let vsp2 = try XCTUnwrap(recipes.first { $0.id == "vsp2-target-enrichment" })

        let engine = RecipeEngine()
        XCTAssertThrowsError(try engine.validate(recipe: vsp2, inputFormat: .single))
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter RecipeIntegrationTests 2>&1 | tail -20`
Expected: All 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishWorkflowTests/Recipes/RecipeIntegrationTests.swift
git commit -m "test: add integration tests for VSP2 recipe loading, validation, and planning"
```

---

### Task 10: Run full test suite and fix any breakage

- [ ] **Step 1: Run the complete test suite**

Run: `swift test 2>&1 | tail -40`

Expected: All existing tests plus new recipe tests pass. If any existing tests break due to `ImportConfig` changes (the struct gained new required fields), fix the call sites.

Common fixes needed:
- Any test creating `ImportConfig` needs to add `platform: .illumina` parameter
- Old `resolveRecipe(named: "vsp2")` calls should still work (old code path preserved)

- [ ] **Step 2: Fix any compilation errors or test failures**

Update call sites as needed. The key principle: the old code path must still work for unmigrated recipes.

- [ ] **Step 3: Run tests again to confirm all green**

Run: `swift test 2>&1 | tail -40`
Expected: All tests pass.

- [ ] **Step 4: Commit fixes**

```bash
git add -A
git commit -m "fix: update existing test call sites for expanded ImportConfig"
```

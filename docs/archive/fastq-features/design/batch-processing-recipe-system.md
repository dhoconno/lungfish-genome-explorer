# Batch Processing Recipe System — Design Document

## 1. Recipe / Workflow Definition

### Concept

A `ProcessingRecipe` is an ordered list of `FASTQDerivativeOperation` steps with their parameters, serialized as JSON. The user defines operations once in the operations panel; the recipe captures the full pipeline definition independent of any specific input bundle.

Recipes reuse the existing `FASTQDerivativeOperation` type (from `FASTQDerivatives.swift`) directly — no parallel type hierarchy. Each step in the recipe is exactly the same struct that already appears in `derived.manifest.json` lineage arrays, minus the `createdAt` timestamp (which gets stamped at execution time).

### Swift Types (LungfishIO)

```swift
// ProcessingRecipe.swift

/// A reusable, serializable pipeline definition.
public struct ProcessingRecipe: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var description: String
    public let createdAt: Date
    public var modifiedAt: Date

    /// Ordered pipeline steps. Each step is a template — `createdAt` is
    /// set to `.distantPast` at definition time and stamped with the real
    /// date at execution time.
    public var steps: [FASTQDerivativeOperation]

    /// Optional tags for organization ("amplicon", "wgs", "ont", etc.).
    public var tags: [String]

    /// Who created this recipe (for shared/builtin recipes).
    public var author: String?

    /// Minimum input requirements (e.g. must be paired-end for PE merge step).
    public var requiredPairingMode: IngestionMetadata.PairingMode?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        steps: [FASTQDerivativeOperation],
        tags: [String] = [],
        author: String? = nil,
        requiredPairingMode: IngestionMetadata.PairingMode? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.steps = steps
        self.tags = tags
        self.author = author
        self.requiredPairingMode = requiredPairingMode
    }

    /// Human-readable summary: "3 steps: Quality Trim → Adapter Trim → PE Merge"
    public var pipelineSummary: String {
        let stepNames = steps.map { $0.kind.rawValue }
        return "\(steps.count) steps: \(stepNames.joined(separator: " → "))"
    }
}
```

### Built-in Recipe Templates

```swift
extension ProcessingRecipe {
    /// Standard Illumina WGS preprocessing.
    public static let illuminaWGS = ProcessingRecipe(
        name: "Illumina WGS Standard",
        description: "Quality trim, adapter removal, contaminant filter (PhiX), PE merge",
        steps: [
            FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20, windowSize: 4, qualityTrimMode: .cutRight),
            FASTQDerivativeOperation(kind: .adapterTrim, adapterMode: .autoDetect),
            FASTQDerivativeOperation(kind: .contaminantFilter, contaminantFilterMode: .phix, contaminantKmerSize: 31, contaminantHammingDistance: 1),
            FASTQDerivativeOperation(kind: .pairedEndMerge, mergeStrictness: .normal, mergeMinOverlap: 12),
        ],
        tags: ["illumina", "wgs", "paired-end"],
        author: "Lungfish Built-in",
        requiredPairingMode: .interleaved
    )

    /// ONT amplicon — quality filter + length select.
    public static let ontAmplicon = ProcessingRecipe(
        name: "ONT Amplicon",
        description: "Quality trim, length filter for expected amplicon size, deduplication",
        steps: [
            FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 10, windowSize: 10, qualityTrimMode: .cutBoth),
            FASTQDerivativeOperation(kind: .lengthFilter, minLength: 200, maxLength: 1500),
            FASTQDerivativeOperation(kind: .deduplicate, deduplicateMode: .sequence),
        ],
        tags: ["ont", "amplicon", "nanopore"],
        author: "Lungfish Built-in"
    )

    /// PacBio HiFi — minimal processing, dedup + error correction.
    public static let pacbioHiFi = ProcessingRecipe(
        name: "PacBio HiFi",
        description: "Deduplicate, error correction for HiFi consensus reads",
        steps: [
            FASTQDerivativeOperation(kind: .deduplicate, deduplicateMode: .sequence),
            FASTQDerivativeOperation(kind: .errorCorrection, errorCorrectionKmerSize: 50),
        ],
        tags: ["pacbio", "hifi", "long-read"],
        author: "Lungfish Built-in"
    )

    /// Primer removal + quality trim for targeted amplicon sequencing.
    public static let targetedAmplicon = ProcessingRecipe(
        name: "Targeted Amplicon",
        description: "Primer removal, quality trim, adapter trim, PE merge",
        steps: [
            FASTQDerivativeOperation(kind: .primerRemoval, primerSource: .literal, primerKmerSize: 23, primerMinKmer: 11, primerHammingDistance: 1),
            FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20, windowSize: 4, qualityTrimMode: .cutRight),
            FASTQDerivativeOperation(kind: .adapterTrim, adapterMode: .autoDetect),
            FASTQDerivativeOperation(kind: .pairedEndMerge, mergeStrictness: .strict, mergeMinOverlap: 10),
        ],
        tags: ["amplicon", "targeted", "paired-end"],
        author: "Lungfish Built-in",
        requiredPairingMode: .interleaved
    )
}
```

### Recipe JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ProcessingRecipe",
  "type": "object",
  "required": ["id", "name", "createdAt", "modifiedAt", "steps"],
  "properties": {
    "id": { "type": "string", "format": "uuid" },
    "name": { "type": "string", "minLength": 1, "maxLength": 100 },
    "description": { "type": "string" },
    "createdAt": { "type": "string", "format": "date-time" },
    "modifiedAt": { "type": "string", "format": "date-time" },
    "steps": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/$defs/FASTQDerivativeOperation" }
    },
    "tags": { "type": "array", "items": { "type": "string" } },
    "author": { "type": "string" },
    "requiredPairingMode": {
      "type": "string",
      "enum": ["single_end", "paired_end", "interleaved"]
    }
  },
  "$defs": {
    "FASTQDerivativeOperation": {
      "type": "object",
      "required": ["kind", "createdAt"],
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "subsampleProportion", "subsampleCount", "lengthFilter",
            "searchText", "searchMotif", "deduplicate",
            "qualityTrim", "adapterTrim", "fixedTrim",
            "contaminantFilter", "pairedEndMerge", "pairedEndRepair",
            "primerRemoval", "errorCorrection", "interleaveReformat"
          ]
        },
        "createdAt": { "type": "string", "format": "date-time" },
        "qualityThreshold": { "type": "integer" },
        "windowSize": { "type": "integer" },
        "qualityTrimMode": { "type": "string" },
        "adapterMode": { "type": "string" },
        "adapterSequence": { "type": "string" },
        "mergeStrictness": { "type": "string" },
        "mergeMinOverlap": { "type": "integer" },
        "minLength": { "type": "integer" },
        "maxLength": { "type": "integer" },
        "toolUsed": { "type": "string" },
        "toolCommand": { "type": "string" }
      },
      "additionalProperties": true
    }
  }
}
```

---

## 2. Batch Execution Engine

### Swift Types (LungfishApp)

```swift
// BatchProcessingEngine.swift

/// Identifies a single barcode within a batch run.
public struct BarcodeInput: Sendable, Identifiable {
    public let id: UUID
    public let label: String           // e.g. "BC01", "SRR12345"
    public let bundleURL: URL          // .lungfishfastq source bundle
}

/// Tracks progress for one barcode through the pipeline.
public struct BarcodeProgress: Sendable {
    public let barcodeID: UUID
    public let barcodeLabel: String

    /// Index of the step currently executing (0-based). -1 = not started.
    public var currentStepIndex: Int
    /// Total steps in the recipe.
    public let totalSteps: Int
    /// Per-step status.
    public var stepStatuses: [StepStatus]

    public enum StepStatus: Sendable {
        case pending
        case running(statusMessage: String)
        case completed(outputBundleURL: URL, stats: FASTQDatasetStatistics)
        case failed(Error)
        case cancelled
    }

    /// Overall fraction complete (0.0–1.0).
    public var overallProgress: Double {
        let completedCount = stepStatuses.filter {
            if case .completed = $0 { return true }
            return false
        }.count
        return Double(completedCount) / Double(totalSteps)
    }
}

/// Configuration for a batch run.
public struct BatchRunConfiguration: Sendable {
    public let recipe: ProcessingRecipe
    public let inputs: [BarcodeInput]
    public let outputBaseDirectory: URL
    public let batchName: String

    /// Max barcodes to process concurrently.
    /// Default: min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    /// Each barcode pipeline is itself sequential (step1 → step2 → step3),
    /// but multiple barcodes run their pipelines in parallel.
    public var maxConcurrentBarcodes: Int

    /// Whether to stop all remaining barcodes on first failure.
    public var failFast: Bool
}

/// The batch engine. An actor because it manages shared mutable state
/// (the progress matrix, cancellation tokens) from concurrent barcode tasks.
public actor BatchProcessingEngine {

    private let derivativeService = FASTQDerivativeService.shared
    private var barcodeProgresses: [UUID: BarcodeProgress] = [:]
    private var cancellationTokens: [UUID: Bool] = [:]   // per-barcode
    private var globalCancelled = false

    /// Progress callback: fired whenever any barcode's progress changes.
    /// The dictionary maps barcodeID → BarcodeProgress.
    public typealias ProgressCallback = @Sendable ([UUID: BarcodeProgress]) -> Void

    /// Runs a full batch. Returns the comparison manifest on success.
    public func runBatch(
        configuration: BatchRunConfiguration,
        onProgress: ProgressCallback? = nil
    ) async throws -> BatchComparisonManifest {

        let batchID = UUID()
        let batchDir = configuration.outputBaseDirectory
            .appendingPathComponent(configuration.batchName, isDirectory: true)
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)

        // Save the recipe once at the batch level
        let recipeURL = batchDir.appendingPathComponent("recipe.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration.recipe).write(to: recipeURL, options: .atomic)

        // Initialize progress tracking
        for input in configuration.inputs {
            barcodeProgresses[input.id] = BarcodeProgress(
                barcodeID: input.id,
                barcodeLabel: input.label,
                currentStepIndex: -1,
                totalSteps: configuration.recipe.steps.count,
                stepStatuses: Array(repeating: .pending, count: configuration.recipe.steps.count)
            )
            cancellationTokens[input.id] = false
        }

        // Process barcodes with bounded concurrency
        try await withThrowingTaskGroup(of: Void.self) { group in
            var semaphore = 0
            var inputIterator = configuration.inputs.makeIterator()

            // Seed initial batch
            for _ in 0..<configuration.maxConcurrentBarcodes {
                guard let input = inputIterator.next() else { break }
                semaphore += 1
                group.addTask { [self] in
                    try await self.processBarcode(
                        input: input,
                        recipe: configuration.recipe,
                        batchID: batchID,
                        batchDir: batchDir,
                        onProgress: onProgress
                    )
                }
            }

            // As each completes, start the next
            for try await _ in group {
                semaphore -= 1
                if let input = inputIterator.next() {
                    semaphore += 1
                    group.addTask { [self] in
                        try await self.processBarcode(
                            input: input,
                            recipe: configuration.recipe,
                            batchID: batchID,
                            batchDir: batchDir,
                            onProgress: onProgress
                        )
                    }
                }
            }
        }

        // Generate comparison manifest
        let comparison = buildComparisonManifest(
            batchID: batchID,
            configuration: configuration,
            batchDir: batchDir
        )
        let comparisonURL = batchDir.appendingPathComponent("comparison.json")
        try encoder.encode(comparison).write(to: comparisonURL, options: .atomic)

        // Write batch manifest
        let batchManifest = BatchManifest(
            batchID: batchID,
            recipeName: configuration.recipe.name,
            recipeID: configuration.recipe.id,
            batchName: configuration.batchName,
            startedAt: Date(), // would be captured at actual start
            completedAt: Date(),
            barcodeCount: configuration.inputs.count,
            stepCount: configuration.recipe.steps.count,
            barcodeLabels: configuration.inputs.map(\.label)
        )
        let manifestURL = batchDir.appendingPathComponent("batch.manifest.json")
        try encoder.encode(batchManifest).write(to: manifestURL, options: .atomic)

        return comparison
    }

    /// Process a single barcode through all recipe steps sequentially.
    private func processBarcode(
        input: BarcodeInput,
        recipe: ProcessingRecipe,
        batchID: UUID,
        batchDir: URL,
        onProgress: ProgressCallback?
    ) async throws {
        let barcodeDir = batchDir.appendingPathComponent(input.label, isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)

        var currentSourceURL = input.bundleURL

        for (stepIndex, stepTemplate) in recipe.steps.enumerated() {
            // Check cancellation
            if globalCancelled || cancellationTokens[input.id] == true {
                barcodeProgresses[input.id]?.stepStatuses[stepIndex] = .cancelled
                return
            }

            barcodeProgresses[input.id]?.currentStepIndex = stepIndex
            barcodeProgresses[input.id]?.stepStatuses[stepIndex] = .running(statusMessage: "Starting \(stepTemplate.kind.rawValue)...")
            onProgress?(barcodeProgresses)

            do {
                // Convert the step template to a FASTQDerivativeRequest
                let request = try requestFromOperation(stepTemplate)

                // Create derivative — the existing service handles everything
                let outputURL = try await derivativeService.createDerivative(
                    from: currentSourceURL,
                    request: request,
                    progress: { [self] message in
                        Task {
                            await self.updateStepMessage(
                                barcodeID: input.id,
                                stepIndex: stepIndex,
                                message: message
                            )
                        }
                    }
                )

                // Move output bundle into the batch directory structure
                let stepDir = barcodeDir.appendingPathComponent(
                    "step-\(stepIndex + 1)-\(stepTemplate.shortLabel)",
                    isDirectory: true
                )
                let destURL = stepDir.appendingPathComponent(
                    outputURL.lastPathComponent,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: outputURL, to: destURL)

                // Inject batchOperationID into the derived manifest
                try injectBatchID(batchID, into: destURL)

                // Load stats from the manifest
                let stats = FASTQBundle.loadDerivedManifest(in: destURL)?.cachedStatistics
                    ?? FASTQDatasetStatistics.empty

                barcodeProgresses[input.id]?.stepStatuses[stepIndex] = .completed(
                    outputBundleURL: destURL,
                    stats: stats
                )
                onProgress?(barcodeProgresses)

                // The output of this step becomes the input of the next
                currentSourceURL = destURL

            } catch {
                barcodeProgresses[input.id]?.stepStatuses[stepIndex] = .failed(error)
                onProgress?(barcodeProgresses)
                throw error
            }
        }
    }

    // MARK: - Cancellation

    public func cancelAll() {
        globalCancelled = true
    }

    public func cancelBarcode(_ id: UUID) {
        cancellationTokens[id] = true
    }

    // ... helper methods omitted for brevity
}
```

### Parallelism Strategy

The key insight: each barcode's pipeline is **sequential** (step 1 must finish before step 2 starts), but **multiple barcodes** run their pipelines concurrently. The concurrency limit defaults to `min(4, activeProcessorCount / 2)` because:

- Each BBTools operation is already multi-threaded (`-@ threads`)
- 4 concurrent barcodes x 4 threads each = 16 threads, saturating a modern Mac
- Memory: each barcode pipeline materializes one FASTQ at a time (the service's temp dir pattern), so memory pressure scales linearly with concurrency

For a 96-barcode plate on an M3 Max (12P+4E), the recommended setting is `maxConcurrentBarcodes: 4`, processing 4 barcodes in parallel. Total wall time ~ (96/4) x time-per-barcode.

---

## 3. Output Organization

### Filesystem Layout

For 3 barcodes (BC01, BC02, BC03) through a 3-step recipe (quality trim, adapter trim, PE merge):

```
~/Documents/Lungfish/
  MyProject/
    raw-data/
      BC01.lungfishfastq/              ← original barcode bundles
      BC02.lungfishfastq/
      BC03.lungfishfastq/

    batch-runs/
      2026-03-08-IlluminaWGS/          ← batch output directory
        batch.manifest.json            ← batch-level metadata
        recipe.json                    ← the recipe (stored once)
        comparison.json                ← cross-barcode comparison table

        BC01/
          step-1-qtrim-Q20/
            BC01-qtrim-Q20-20260308T143022Z.lungfishfastq/
              derived.manifest.json    ← standard derivative manifest + batchOperationID
              read-ids.txt  or  trim-positions.tsv  or  transformed.fastq
          step-2-adapter-trim/
            BC01-qtrim-Q20-…-adapter-trim-20260308T143045Z.lungfishfastq/
              derived.manifest.json
              ...
          step-3-merge-normal/
            BC01-…-merge-normal-20260308T143112Z.lungfishfastq/
              derived.manifest.json
              merged.fastq
              unmerged.fastq
              read-manifest.json

        BC02/
          step-1-qtrim-Q20/
            BC02-qtrim-Q20-20260308T143025Z.lungfishfastq/
              ...
          step-2-adapter-trim/
            ...
          step-3-merge-normal/
            ...

        BC03/
          step-1-qtrim-Q20/
            ...
          step-2-adapter-trim/
            ...
          step-3-merge-normal/
            ...
```

### Key Design Decisions

1. **One directory per barcode** — maps naturally to the source-list sidebar. Users can expand/collapse per barcode.

2. **Numbered step directories** — `step-1-qtrim-Q20/` provides both order and readability. The number ensures correct sort order; the suffix is `operation.shortLabel`.

3. **Standard derivative bundles inside** — each step output is a normal `.lungfishfastq` bundle with its `derived.manifest.json`. The existing viewer, inspector, and derivative chain all work unchanged.

4. **Intermediate access** — every step's output is a first-class bundle. Users can open `step-2-adapter-trim/` output to inspect quality after adapter removal, before merging.

5. **Cross-cutting views** — the comparison manifest enables "show me all step-2 outputs" across barcodes without changing the filesystem layout.

---

## 4. Batch Manifest JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "BatchManifest",
  "type": "object",
  "required": ["batchID", "recipeName", "recipeID", "batchName", "startedAt", "completedAt", "barcodeCount", "stepCount", "barcodeLabels"],
  "properties": {
    "batchID": { "type": "string", "format": "uuid" },
    "recipeName": { "type": "string" },
    "recipeID": { "type": "string", "format": "uuid" },
    "batchName": { "type": "string" },
    "startedAt": { "type": "string", "format": "date-time" },
    "completedAt": { "type": "string", "format": "date-time" },
    "barcodeCount": { "type": "integer" },
    "stepCount": { "type": "integer" },
    "barcodeLabels": {
      "type": "array",
      "items": { "type": "string" }
    }
  }
}
```

Swift type:

```swift
public struct BatchManifest: Codable, Sendable {
    public let batchID: UUID
    public let recipeName: String
    public let recipeID: UUID
    public let batchName: String
    public let startedAt: Date
    public let completedAt: Date
    public let barcodeCount: Int
    public let stepCount: Int
    public let barcodeLabels: [String]
}
```

---

## 5. Cross-Barcode Comparison Manifest

### JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "BatchComparisonManifest",
  "type": "object",
  "required": ["batchID", "generatedAt", "recipeName", "steps", "barcodes"],
  "properties": {
    "batchID": { "type": "string", "format": "uuid" },
    "generatedAt": { "type": "string", "format": "date-time" },
    "recipeName": { "type": "string" },
    "steps": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["index", "operationKind", "shortLabel", "displaySummary"],
        "properties": {
          "index": { "type": "integer" },
          "operationKind": { "type": "string" },
          "shortLabel": { "type": "string" },
          "displaySummary": { "type": "string" }
        }
      }
    },
    "barcodes": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["label", "inputStats", "stepResults"],
        "properties": {
          "label": { "type": "string" },
          "inputStats": { "$ref": "#/$defs/StepMetrics" },
          "stepResults": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["stepIndex", "status"],
              "properties": {
                "stepIndex": { "type": "integer" },
                "status": {
                  "type": "string",
                  "enum": ["completed", "failed", "cancelled"]
                },
                "metrics": { "$ref": "#/$defs/StepMetrics" },
                "errorMessage": { "type": "string" },
                "bundleRelativePath": { "type": "string" }
              }
            }
          }
        }
      }
    }
  },
  "$defs": {
    "StepMetrics": {
      "type": "object",
      "properties": {
        "readCount": { "type": "integer" },
        "baseCount": { "type": "integer" },
        "meanReadLength": { "type": "number" },
        "medianReadLength": { "type": "integer" },
        "n50ReadLength": { "type": "integer" },
        "meanQuality": { "type": "number" },
        "q20Percentage": { "type": "number" },
        "q30Percentage": { "type": "number" },
        "gcContent": { "type": "number" },
        "readsRetainedPct": {
          "type": "number",
          "description": "Percentage of input reads retained through this step (vs step input, not vs raw)."
        },
        "cumulativeRetainedPct": {
          "type": "number",
          "description": "Percentage of original raw reads retained through all steps up to this point."
        }
      }
    }
  }
}
```

### Swift Type

```swift
public struct BatchComparisonManifest: Codable, Sendable {
    public let batchID: UUID
    public let generatedAt: Date
    public let recipeName: String
    public let steps: [StepDefinition]
    public let barcodes: [BarcodeResult]

    public struct StepDefinition: Codable, Sendable {
        public let index: Int
        public let operationKind: String
        public let shortLabel: String
        public let displaySummary: String
    }

    public struct StepMetrics: Codable, Sendable {
        public let readCount: Int
        public let baseCount: Int64
        public let meanReadLength: Double
        public let medianReadLength: Int
        public let n50ReadLength: Int
        public let meanQuality: Double
        public let q20Percentage: Double
        public let q30Percentage: Double
        public let gcContent: Double
        public let readsRetainedPct: Double?     // vs this step's input
        public let cumulativeRetainedPct: Double? // vs original raw input
    }

    public struct StepResult: Codable, Sendable {
        public let stepIndex: Int
        public let status: Status
        public let metrics: StepMetrics?
        public let errorMessage: String?
        public let bundleRelativePath: String?

        public enum Status: String, Codable, Sendable {
            case completed, failed, cancelled
        }
    }

    public struct BarcodeResult: Codable, Sendable {
        public let label: String
        public let inputStats: StepMetrics
        public let stepResults: [StepResult]
    }
}
```

### Example Comparison JSON (3 barcodes x 3 steps)

```json
{
  "batchID": "A1B2C3D4-...",
  "generatedAt": "2026-03-08T14:35:00Z",
  "recipeName": "Illumina WGS Standard",
  "steps": [
    { "index": 0, "operationKind": "qualityTrim",  "shortLabel": "qtrim-Q20", "displaySummary": "Quality trim Q20 w4 (cutRight)" },
    { "index": 1, "operationKind": "adapterTrim",   "shortLabel": "adapter-trim", "displaySummary": "Adapter removal (auto-detect)" },
    { "index": 2, "operationKind": "pairedEndMerge", "shortLabel": "merge-normal", "displaySummary": "PE merge (normal, min overlap: 12)" }
  ],
  "barcodes": [
    {
      "label": "BC01",
      "inputStats": { "readCount": 1250000, "baseCount": 187500000, "meanReadLength": 150.0, "medianReadLength": 150, "n50ReadLength": 150, "meanQuality": 32.1, "q20Percentage": 95.2, "q30Percentage": 88.7, "gcContent": 0.42, "readsRetainedPct": null, "cumulativeRetainedPct": null },
      "stepResults": [
        { "stepIndex": 0, "status": "completed", "metrics": { "readCount": 1230000, "baseCount": 178200000, "meanReadLength": 144.9, "medianReadLength": 148, "n50ReadLength": 149, "meanQuality": 33.5, "q20Percentage": 97.8, "q30Percentage": 92.1, "gcContent": 0.42, "readsRetainedPct": 98.4, "cumulativeRetainedPct": 98.4 }, "bundleRelativePath": "BC01/step-1-qtrim-Q20/BC01-qtrim-Q20-20260308T143022Z.lungfishfastq" },
        { "stepIndex": 1, "status": "completed", "metrics": { "readCount": 1225000, "baseCount": 174800000, "meanReadLength": 142.7, "medianReadLength": 146, "n50ReadLength": 148, "meanQuality": 33.6, "q20Percentage": 97.9, "q30Percentage": 92.3, "gcContent": 0.42, "readsRetainedPct": 99.6, "cumulativeRetainedPct": 98.0 }, "bundleRelativePath": "BC01/step-2-adapter-trim/BC01-...-adapter-trim-20260308T143045Z.lungfishfastq" },
        { "stepIndex": 2, "status": "completed", "metrics": { "readCount": 980000, "baseCount": 280000000, "meanReadLength": 285.7, "medianReadLength": 290, "n50ReadLength": 295, "meanQuality": 35.2, "q20Percentage": 98.5, "q30Percentage": 94.1, "gcContent": 0.42, "readsRetainedPct": 80.0, "cumulativeRetainedPct": 78.4 }, "bundleRelativePath": "BC01/step-3-merge-normal/BC01-...-merge-normal-20260308T143112Z.lungfishfastq" }
      ]
    },
    {
      "label": "BC02",
      "inputStats": { "readCount": 980000, "baseCount": 147000000, "meanReadLength": 150.0, "medianReadLength": 150, "n50ReadLength": 150, "meanQuality": 28.3, "q20Percentage": 89.1, "q30Percentage": 78.5, "gcContent": 0.48, "readsRetainedPct": null, "cumulativeRetainedPct": null },
      "stepResults": [
        { "stepIndex": 0, "status": "completed", "metrics": { "readCount": 910000, "baseCount": 125580000, "meanReadLength": 138.0, "medianReadLength": 142, "n50ReadLength": 145, "meanQuality": 30.8, "q20Percentage": 94.5, "q30Percentage": 85.2, "gcContent": 0.48, "readsRetainedPct": 92.9, "cumulativeRetainedPct": 92.9 }, "bundleRelativePath": "BC02/step-1-qtrim-Q20/..." },
        { "stepIndex": 1, "status": "completed", "metrics": { "readCount": 900000, "baseCount": 122400000, "meanReadLength": 136.0, "medianReadLength": 140, "n50ReadLength": 143, "meanQuality": 31.0, "q20Percentage": 94.8, "q30Percentage": 85.5, "gcContent": 0.48, "readsRetainedPct": 98.9, "cumulativeRetainedPct": 91.8 }, "bundleRelativePath": "BC02/step-2-adapter-trim/..." },
        { "stepIndex": 2, "status": "completed", "metrics": { "readCount": 680000, "baseCount": 190400000, "meanReadLength": 280.0, "medianReadLength": 285, "n50ReadLength": 290, "meanQuality": 33.1, "q20Percentage": 97.2, "q30Percentage": 91.0, "gcContent": 0.48, "readsRetainedPct": 75.6, "cumulativeRetainedPct": 69.4 }, "bundleRelativePath": "BC02/step-3-merge-normal/..." }
      ]
    },
    {
      "label": "BC03",
      "inputStats": { "readCount": 1100000, "baseCount": 165000000, "meanReadLength": 150.0, "medianReadLength": 150, "n50ReadLength": 150, "meanQuality": 34.5, "q20Percentage": 97.0, "q30Percentage": 93.2, "gcContent": 0.41, "readsRetainedPct": null, "cumulativeRetainedPct": null },
      "stepResults": [
        { "stepIndex": 0, "status": "completed", "metrics": { "readCount": 1095000, "baseCount": 163050000, "meanReadLength": 148.9, "medianReadLength": 150, "n50ReadLength": 150, "meanQuality": 34.8, "q20Percentage": 97.5, "q30Percentage": 93.8, "gcContent": 0.41, "readsRetainedPct": 99.5, "cumulativeRetainedPct": 99.5 }, "bundleRelativePath": "BC03/step-1-qtrim-Q20/..." },
        { "stepIndex": 1, "status": "completed", "metrics": { "readCount": 1092000, "baseCount": 161600000, "meanReadLength": 148.0, "medianReadLength": 149, "n50ReadLength": 150, "meanQuality": 34.9, "q20Percentage": 97.6, "q30Percentage": 93.9, "gcContent": 0.41, "readsRetainedPct": 99.7, "cumulativeRetainedPct": 99.3 }, "bundleRelativePath": "BC03/step-2-adapter-trim/..." },
        { "stepIndex": 2, "status": "completed", "metrics": { "readCount": 920000, "baseCount": 267000000, "meanReadLength": 290.2, "medianReadLength": 293, "n50ReadLength": 296, "meanQuality": 36.0, "q20Percentage": 98.8, "q30Percentage": 95.2, "gcContent": 0.41, "readsRetainedPct": 84.2, "cumulativeRetainedPct": 83.6 }, "bundleRelativePath": "BC03/step-3-merge-normal/..." }
      ]
    }
  ]
}
```

---

## 6. Integration with Existing Derivative System

### Minimal Changes to `FASTQDerivedBundleManifest`

Add one optional field:

```swift
// In FASTQDerivatives.swift, add to FASTQDerivedBundleManifest:

/// Links this derivative to a batch run. All barcodes processed in the
/// same batch share this ID. Nil for single (non-batch) derivatives.
public let batchOperationID: UUID?
```

This field is:
- `nil` for all existing single-operation derivatives (backward compatible)
- Set to the batch UUID for all derivatives created by the batch engine
- Used by the sidebar/source list to group "all outputs from batch X"

### No Other Changes Required

The existing system already supports everything else:
- `lineage: [FASTQDerivativeOperation]` already records the full chain of operations
- `parentBundleRelativePath` already links step N output to step N-1 output
- `rootBundleRelativePath` already links back to the original raw bundle
- `cachedStatistics` already provides the per-step metrics the comparison manifest needs
- The recipe is stored once at `batch-runs/MyBatch/recipe.json`, not in each bundle

### Recipe Storage

Recipes are stored in the app's Application Support directory:

```
~/Library/Application Support/Lungfish/
  recipes/
    builtin/                           ← shipped with app, read-only
      illumina-wgs.recipe.json
      ont-amplicon.recipe.json
      pacbio-hifi.recipe.json
      targeted-amplicon.recipe.json
    user/                              ← user-created, editable
      my-custom-pipeline.recipe.json
      lab-standard-v2.recipe.json
```

File extension: `.recipe.json` (so Finder shows them as JSON but Lungfish can register a UTType for drag-and-drop import/export).

---

## 7. Comparison Table UI Recommendations

### Layout: NSTableView with Frozen Row Header

The comparison table has two axes:
- **Rows**: barcodes (BC01, BC02, ..., BC96)
- **Column groups**: one group per pipeline step, plus an "Input" group

Each column group contains the key metrics as sub-columns. The user selects which metric to display prominently.

### Concrete Column Layout

```
| Barcode | Input      | Step 1: Quality Trim    | Step 2: Adapter Trim    | Step 3: PE Merge        |
|         | Reads | Q  | Reads | %Ret | Q  | Q30 | Reads | %Ret | Q  | Q30 | Reads | %Ret | Q  | Q30 |
|---------|-------|-----|-------|------|-----|-----|-------|------|-----|-----|-------|------|-----|-----|
| BC01    | 1.25M | 32.1| 1.23M| 98.4%| 33.5| 92.1| 1.22M| 99.6%| 33.6| 92.3| 980K | 80.0%| 35.2| 94.1|
| BC02    | 980K  | 28.3| 910K | 92.9%| 30.8| 85.2| 900K | 98.9%| 31.0| 85.5| 680K | 75.6%| 33.1| 91.0|
| BC03    | 1.10M | 34.5| 1.09M| 99.5%| 34.8| 93.8| 1.09M| 99.7%| 34.9| 93.9| 920K | 84.2%| 36.0| 95.2|
```

### Outlier Detection & Conditional Formatting

Apply cell background coloring based on z-score within each column:
- **Red** (z < -2): significantly below peers (e.g., BC02's 92.9% retention at step 1 when others are >98%)
- **Yellow** (z < -1): mildly below peers
- **Green** (z > 1): above peers
- **Default**: within normal range

The z-score is computed per-column across all barcodes. Thresholds are configurable.

### Interactive Features

1. **Click cell to open bundle** — clicking a cell navigates to that barcode's step output in the viewer
2. **Sort by any column** — click column header to sort barcodes by that metric
3. **Filter barcodes** — text field to filter by barcode name, or filter to "outliers only"
4. **Export to CSV/TSV** — the table is directly exportable for downstream analysis in R/Excel
5. **Collapse/expand step groups** — for 96 barcodes x 5 steps x 4 metrics, the table gets wide; collapsible groups help
6. **Summary row** — bottom row shows mean/median/stdev across all barcodes for each metric

### Implementation Notes

- Use `NSTableView` (not SwiftUI Table) for performance with 96+ rows and dozens of columns
- The comparison manifest JSON is small (<100 KB even for 384 barcodes) — load entirely into memory
- Column header rendering: use a custom `NSTableHeaderView` subclass for the two-level headers (step name on top, metric name below)
- Conditional formatting: compute z-scores once at load time, cache per-cell background colors

### Progress View (During Batch Execution)

While the batch is running, show a grid that's a simplified version of the comparison table:

```
| Barcode | Step 1          | Step 2          | Step 3          |
|---------|-----------------|-----------------|-----------------|
| BC01    | [====] Done     | [==  ] Trimming | [ ] Pending     |
| BC02    | [====] Done     | [ ] Pending     | [ ] Pending     |
| BC03    | [=== ] Q trim.. | [ ] Pending     | [ ] Pending     |
| ...     |                 |                 |                 |
```

Each cell is a mini progress indicator (NSProgressIndicator + status label). The grid updates via the `ProgressCallback` from the batch engine. Failed cells show a red X with the error message on hover.

---

## 8. Summary of New Files

| File | Module | Purpose |
|------|--------|---------|
| `ProcessingRecipe.swift` | LungfishIO | Recipe model + built-in templates |
| `BatchProcessingEngine.swift` | LungfishApp | Batch execution actor |
| `BatchComparisonManifest.swift` | LungfishIO | Comparison + batch manifest models |
| `BatchComparisonViewController.swift` | LungfishApp | NSTableView comparison UI |
| `BatchProgressViewController.swift` | LungfishApp | Progress grid during execution |
| `RecipeEditorViewController.swift` | LungfishApp | Recipe creation/editing UI |

Changes to existing files:
- `FASTQDerivatives.swift` — add `batchOperationID: UUID?` to `FASTQDerivedBundleManifest`
- `FASTQDerivativeService.swift` — no changes (the batch engine calls its existing `createDerivative` method)

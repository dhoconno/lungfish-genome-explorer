# Virtual FASTQ Concurrency Implementation Plan

## Context

The existing system uses `FASTQDerivativeService` (an actor) to create pointer-based derivative bundles, and `BatchProcessingEngine` (an actor) for bounded-concurrency batch processing across demultiplexed barcodes. The current `FASTQDerivativePayload` enum already distinguishes between `subset`, `trim`, `full`, `demuxedVirtual`, and `orientMap` payloads -- representing varying degrees of "virtual" vs "materialized" data. This plan extends that model with explicit lifecycle state tracking, a materialization pipeline actor, and proper MainActor dispatching for UI updates.

---

## 1. Sendable-Safe Data Models for Virtual FASTQ State

### 1.1 MaterializationState Enum

The current system has an implicit state model: a bundle is either "virtual" (has a read-ID list or trim positions referencing a root FASTQ) or "materialized" (contains the actual FASTQ data). There is no in-flight tracking. Add an explicit three-state lifecycle:

```swift
// LungfishIO/Formats/FASTQ/VirtualFASTQState.swift

/// Lifecycle state of a virtual FASTQ derivative.
/// Value type -- safe to pass across isolation boundaries.
public enum MaterializationState: Codable, Sendable, Equatable {
    /// Derivative is pointer-based. The bundle contains only metadata
    /// (read ID list, trim positions, orient map) referencing the root FASTQ.
    case virtual

    /// Materialization is in progress. Stores a stable identifier for the
    /// in-flight task so the UI can bind to progress and cancel.
    case materializing(taskID: UUID)

    /// Derivative has been fully written to disk as a standalone FASTQ.
    /// Stores the materialized file's SHA-256 for integrity verification.
    case materialized(checksum: String)
}
```

Key design decisions:

- **Codable + Sendable**: The state is persisted inside the derived bundle manifest (`FASTQDerivedBundleManifest`), so it survives app restarts. A bundle whose materialization was interrupted will have `materializing(taskID:)` on disk -- the app treats this as `virtual` on relaunch (stale task ID).
- **No reference types**: `UUID` and `String` are value types. No `Task` handles or closures stored in the model.
- **taskID is an opaque correlator**: The UI uses it to look up live progress from the `MaterializationPipeline` actor. If the actor has no matching task, the state is treated as stale/virtual.

### 1.2 VirtualFASTQDescriptor

A lightweight descriptor that captures everything needed to materialize a virtual derivative, without holding file handles or task state:

```swift
/// Immutable snapshot of a virtual FASTQ's identity and lineage.
/// Used as the "job specification" for materialization.
public struct VirtualFASTQDescriptor: Sendable, Equatable, Identifiable {
    public let id: UUID  // From derived manifest
    public let bundleURL: URL
    public let rootBundleRelativePath: String
    public let rootFASTQFilename: String
    public let payload: FASTQDerivativePayload
    public let lineage: [FASTQDerivativeOperation]
    public let pairingMode: IngestionMetadata.PairingMode?
    public let sequenceFormat: SequenceFormat?

    /// Creates a descriptor from an existing derived bundle manifest.
    public init(bundleURL: URL, manifest: FASTQDerivedBundleManifest) {
        self.id = manifest.id
        self.bundleURL = bundleURL
        self.rootBundleRelativePath = manifest.rootBundleRelativePath
        self.rootFASTQFilename = manifest.rootFASTQFilename
        self.payload = manifest.payload
        self.lineage = manifest.lineage
        self.pairingMode = manifest.pairingMode
        self.sequenceFormat = manifest.sequenceFormat
    }
}
```

### 1.3 Extending FASTQDerivedBundleManifest

Add an optional `materializationState` field to the existing manifest. Default is `nil`, interpreted as `.virtual` for derived bundles and `.materialized(checksum: "")` for root bundles:

```swift
// Add to FASTQDerivedBundleManifest
public var materializationState: MaterializationState?

/// Resolved state: nil defaults based on bundle type.
public var resolvedState: MaterializationState {
    if let state = materializationState {
        // Stale materializing state from a crashed session
        if case .materializing = state {
            return .virtual
        }
        return state
    }
    // Bundles with full/fullPaired/fullMixed payloads are materialized
    switch payload {
    case .full, .fullPaired, .fullMixed, .fullFASTA:
        return .materialized(checksum: payloadChecksums?.values.first ?? "")
    default:
        return .virtual
    }
}
```

This is backward-compatible: existing manifests without the field decode to `nil` and fall through to the `resolvedState` logic.

---

## 2. Actor Design for Materialization Pipeline

### 2.1 MaterializationPipeline Actor

```swift
// LungfishApp/Services/MaterializationPipeline.swift

/// Manages concurrent materialization of virtual FASTQ derivatives.
///
/// Design constraints:
/// - Actor isolation protects the task registry and progress state.
/// - File I/O and tool execution happen inside structured `Task` groups.
/// - Progress is reported via a Sendable callback, NOT @Published properties
///   (see MEMORY.md: @Published on actors doesn't reliably reach MainActor).
/// - Cancellation is cooperative: each tool invocation checks Task.isCancelled.
public actor MaterializationPipeline {

    // MARK: - Types

    public struct JobProgress: Sendable {
        public let taskID: UUID
        public let descriptor: VirtualFASTQDescriptor
        public let fraction: Double    // 0.0 ... 1.0
        public let message: String
        public let phase: Phase

        public enum Phase: String, Sendable {
            case resolving       // Locating root FASTQ
            case materializing   // Running seqkit/bbtools/cutadapt
            case statistics      // Computing output stats
            case finalizing      // Moving into bundle, updating manifest
            case completed
            case failed
            case cancelled
        }
    }

    public enum JobResult: Sendable {
        case success(materializedURL: URL, checksum: String)
        case cancelled
        case failed(Error)
    }

    // MARK: - State

    /// Active materialization tasks, keyed by task ID.
    private var activeTasks: [UUID: Task<JobResult, Never>] = [:]

    /// Latest progress snapshot per task ID.
    private var progressSnapshots: [UUID: JobProgress] = [:]

    /// Bounded concurrency semaphore (cooperative, not GCD-based).
    private let maxConcurrency: Int

    /// The underlying service that actually runs tools.
    private let derivativeService: FASTQDerivativeService

    public init(
        derivativeService: FASTQDerivativeService = .shared,
        maxConcurrency: Int = 2
    ) {
        self.derivativeService = derivativeService
        self.maxConcurrency = max(1, maxConcurrency)
    }

    // MARK: - Public API

    /// Enqueues a materialization job. Returns immediately with a task ID.
    ///
    /// The caller provides a `@Sendable` progress callback that will be
    /// invoked from the actor's isolation context. To update UI, the
    /// callback must dispatch to MainActor:
    ///
    /// ```swift
    /// pipeline.materialize(descriptor) { progress in
    ///     DispatchQueue.main.async {
    ///         MainActor.assumeIsolated {
    ///             self.updateProgressBar(progress)
    ///         }
    ///     }
    /// }
    /// ```
    public func materialize(
        _ descriptor: VirtualFASTQDescriptor,
        onProgress: (@Sendable (JobProgress) -> Void)? = nil
    ) -> UUID {
        let taskID = UUID()

        let task = Task { [self] in
            await self.runMaterialization(
                taskID: taskID,
                descriptor: descriptor,
                onProgress: onProgress
            )
        }

        activeTasks[taskID] = task
        return taskID
    }

    /// Cancels a running materialization.
    public func cancel(taskID: UUID) {
        activeTasks[taskID]?.cancel()
        activeTasks.removeValue(forKey: taskID)
        progressSnapshots.removeValue(forKey: taskID)
    }

    /// Returns current progress for a task, or nil if not active.
    public func progress(for taskID: UUID) -> JobProgress? {
        progressSnapshots[taskID]
    }

    /// Returns all active task IDs.
    public var activeTaskIDs: [UUID] {
        Array(activeTasks.keys)
    }

    // MARK: - Internal Execution

    private func runMaterialization(
        taskID: UUID,
        descriptor: VirtualFASTQDescriptor,
        onProgress: (@Sendable (JobProgress) -> Void)?
    ) async -> JobResult {
        func report(_ phase: JobProgress.Phase, _ fraction: Double, _ message: String) {
            let p = JobProgress(
                taskID: taskID,
                descriptor: descriptor,
                fraction: fraction,
                message: message,
                phase: phase
            )
            // Update snapshot within actor isolation (we're already on the actor)
            progressSnapshots[taskID] = p
            onProgress?(p)
        }

        do {
            try Task.checkCancellation()

            // Phase 1: Resolve root FASTQ
            report(.resolving, 0.05, "Locating root dataset...")

            // Phase 2: Materialize via the existing service
            report(.materializing, 0.10, "Materializing...")
            let materializedURL = try await derivativeService.exportMaterializedFASTQ(
                fromDerivedBundle: descriptor.bundleURL,
                to: descriptor.bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("materialized-\(taskID.uuidString.prefix(8)).fastq"),
                progress: { message in
                    report(.materializing, 0.50, message)
                }
            )

            try Task.checkCancellation()

            // Phase 3: Compute checksum
            report(.finalizing, 0.90, "Computing checksum...")
            let data = try Data(contentsOf: materializedURL)
            let checksum = data.sha256HexString  // Assumes CryptoKit extension

            // Phase 4: Update manifest
            report(.finalizing, 0.95, "Updating manifest...")
            // Update the derived manifest with materialization state
            if var manifest = FASTQBundle.loadDerivedManifest(in: descriptor.bundleURL) {
                manifest.materializationState = .materialized(checksum: checksum)
                try FASTQBundle.saveDerivedManifest(manifest, in: descriptor.bundleURL)
            }

            report(.completed, 1.0, "Complete")
            activeTasks.removeValue(forKey: taskID)
            return .success(materializedURL: materializedURL, checksum: checksum)

        } catch is CancellationError {
            report(.cancelled, 0.0, "Cancelled")
            activeTasks.removeValue(forKey: taskID)
            return .cancelled

        } catch {
            report(.failed, 0.0, "Failed: \(error.localizedDescription)")
            activeTasks.removeValue(forKey: taskID)
            return .failed(error)
        }
    }
}
```

### 2.2 Why Actor, Not @MainActor Class

The `MaterializationPipeline` runs long I/O operations (seqkit, bbtools). Making it `@MainActor` would either block the UI or require `Task.detached` everywhere (which breaks cooperative scheduling per MEMORY.md). An actor runs on the cooperative pool, and the `report()` closure bridges to MainActor via the callback pattern.

### 2.3 Bounded Concurrency

The existing `BatchProcessingEngine` uses a manual `while` loop with `activeTasks < maxConcurrency`. For the materialization pipeline, use the same pattern inside a `withThrowingTaskGroup` when batch-materializing multiple descriptors:

```swift
/// Materializes multiple descriptors with bounded concurrency.
public func materializeBatch(
    _ descriptors: [VirtualFASTQDescriptor],
    onProgress: (@Sendable (UUID, JobProgress) -> Void)? = nil
) async -> [UUID: JobResult] {
    var results: [UUID: JobResult] = [:]

    await withTaskGroup(of: (UUID, JobResult).self) { group in
        var index = 0
        var active = 0

        while index < descriptors.count || active > 0 {
            while active < maxConcurrency && index < descriptors.count {
                let desc = descriptors[index]
                let taskID = UUID()
                index += 1
                active += 1

                group.addTask { [self] in
                    let result = await self.runMaterialization(
                        taskID: taskID,
                        descriptor: desc,
                        onProgress: { progress in
                            onProgress?(taskID, progress)
                        }
                    )
                    return (taskID, result)
                }
            }

            if let (id, result) = await group.next() {
                results[id] = result
                active -= 1
            }
        }
    }

    return results
}
```

---

## 3. MainActor Dispatching for UI Updates

### 3.1 The Problem (from MEMORY.md)

`Task { @MainActor in }` from GCD background queues does not reliably execute during AppKit layout-draw cycles. The cooperative executor is not drained by the RunLoop in all code paths. This means progress updates from actors will silently stall if dispatched naively.

### 3.2 The Solution: GCD Main Queue + assumeIsolated

All progress callbacks from `MaterializationPipeline` must use this pattern at the call site:

```swift
// In FASTQDatasetViewController (which is @MainActor)
let taskID = await pipeline.materialize(descriptor) { [weak self] progress in
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let self else { return }
            self.updateMaterializationProgress(progress)
        }
    }
}
```

**Why this works:**
- `DispatchQueue.main.async` schedules on the GCD main queue, which is drained by the RunLoop's mach port source in `kCFRunLoopCommonModes` -- this always fires, even during AppKit animations/layout.
- `MainActor.assumeIsolated` tells the Swift 6.2 compiler we're on the main actor (guaranteed by GCD) without going through the cooperative executor.
- `[weak self]` prevents retain cycles since the closure is `@Sendable` and outlives the caller.

### 3.3 Generation Counter for Stale Progress

The existing codebase uses generation counters for stale fetch results (see `annotationFetchGeneration` in ViewerViewController). Apply the same pattern to materialization:

```swift
// In the @MainActor view controller
private var materializationGeneration = 0

func startMaterialization(for descriptor: VirtualFASTQDescriptor) {
    materializationGeneration += 1
    let thisGeneration = materializationGeneration

    Task {
        let taskID = await pipeline.materialize(descriptor) { [weak self] progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          self.materializationGeneration == thisGeneration else { return }
                    self.updateMaterializationProgress(progress)
                }
            }
        }
        // Store taskID for cancel button
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                      self.materializationGeneration == thisGeneration else { return }
                self.activeMaterializationTaskID = taskID
            }
        }
    }
}
```

### 3.4 Cancellation UI

```swift
@objc private func cancelMaterializationClicked(_ sender: Any) {
    guard let taskID = activeMaterializationTaskID else { return }
    materializationGeneration += 1  // Ignore future progress from this task
    Task {
        await pipeline.cancel(taskID: taskID)
    }
    activeMaterializationTaskID = nil
    updateUI(state: .virtual)
}
```

---

## 4. Async and Cancellable Reference Sequence Scanning

### 4.1 Current State

`ReferenceSequenceFolder.listReferences(in:)` is synchronous and scans the filesystem on whatever thread calls it. For large projects with many reference bundles, this blocks.

### 4.2 Design: AsyncSequence-Based Scanner

```swift
// LungfishIO/Bundles/ReferenceSequenceScanner.swift

/// Scans project directories for reference sequences, yielding results
/// as they are discovered. Supports cooperative cancellation.
public struct ReferenceSequenceScanner: Sendable {

    /// A discovered reference with its source location.
    public struct DiscoveredReference: Sendable, Identifiable {
        public let id: UUID  // Stable per scan
        public let url: URL
        public let manifest: ReferenceSequenceManifest
        public let source: Source

        public enum Source: String, Sendable {
            /// From the project's "Reference Sequences" folder.
            case projectFolder
            /// From a .lungfishref bundle elsewhere in the project.
            case projectBundle
            /// From a standalone FASTA file in the project tree.
            case standaloneFASTA
        }
    }

    /// Scans all reference sources for a project directory.
    ///
    /// Yields results as an `AsyncStream` so the UI can populate
    /// incrementally. The stream checks `Task.isCancelled` between
    /// directory entries.
    public static func scan(
        projectURL: URL,
        includeStandaloneFASTA: Bool = true
    ) -> AsyncStream<DiscoveredReference> {
        AsyncStream { continuation in
            // The stream body runs on the cooperative pool.
            // Cancellation is handled by Task.isCancelled checks.
            continuation.onTermination = { _ in
                // Cleanup if needed
            }

            Task {
                defer { continuation.finish() }

                // 1. Scan "Reference Sequences" folder (fast, O(N) bundles)
                let refFolderResults = ReferenceSequenceFolder.listReferences(in: projectURL)
                for (url, manifest) in refFolderResults {
                    guard !Task.isCancelled else { return }
                    continuation.yield(DiscoveredReference(
                        id: UUID(),
                        url: url,
                        manifest: manifest,
                        source: .projectFolder
                    ))
                }

                guard includeStandaloneFASTA else { return }

                // 2. Scan project tree for standalone FASTA files
                // Use FileManager enumerator for lazy traversal
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: projectURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { return }

                let fastaExtensions: Set<String> = ["fasta", "fa", "fna", "fas"]
                var seenPaths = Set<String>()

                // Pre-populate seen paths from Reference Sequences folder
                for (url, _) in refFolderResults {
                    seenPaths.insert(url.path)
                }

                for case let fileURL as URL in enumerator {
                    guard !Task.isCancelled else { return }

                    // Skip inside bundles
                    if fileURL.pathExtension == "lungfishfastq" ||
                       fileURL.pathExtension == "lungfishref" {
                        enumerator.skipDescendants()
                        continue
                    }

                    let ext = fileURL.pathExtension.lowercased()
                    let effectiveExt = ext == "gz"
                        ? fileURL.deletingPathExtension().pathExtension.lowercased()
                        : ext
                    guard fastaExtensions.contains(effectiveExt) else { continue }
                    guard !seenPaths.contains(fileURL.path) else { continue }
                    seenPaths.insert(fileURL.path)

                    continuation.yield(DiscoveredReference(
                        id: UUID(),
                        url: fileURL,
                        manifest: ReferenceSequenceManifest(
                            name: fileURL.deletingPathExtension().lastPathComponent,
                            createdAt: (try? fm.attributesOfItem(
                                atPath: fileURL.path
                            )[.creationDate] as? Date) ?? Date(),
                            sourceFilename: fileURL.lastPathComponent,
                            fastaFilename: fileURL.lastPathComponent
                        ),
                        source: .standaloneFASTA
                    ))
                }
            }
        }
    }
}
```

### 4.3 UI Consumption Pattern

```swift
// In the @MainActor view controller
private var referenceScanTask: Task<Void, Never>?

func refreshReferenceList() {
    referenceScanTask?.cancel()
    discoveredReferences.removeAll()

    guard let projectURL = resolveProjectURL() else { return }

    referenceScanTask = Task { [weak self] in
        let stream = ReferenceSequenceScanner.scan(projectURL: projectURL)
        for await ref in stream {
            guard !Task.isCancelled else { break }
            // We're already on MainActor since the view controller is @MainActor
            // and this Task inherits its isolation.
            self?.discoveredReferences.append(ref)
            self?.referencesTableView.reloadData()
        }
    }
}
```

Note: This `Task` inherits `@MainActor` isolation from the enclosing class. The `for await` loop suspends at each yield, returning control to the main RunLoop between items. This is fine because the actual I/O (directory enumeration) happens inside the `AsyncStream`'s detached task on the cooperative pool.

---

## 5. Type-Safe Operation Chains

### 5.1 Problem

The current `ProcessingRecipe` stores `[FASTQDerivativeOperation]` -- a flat list of operations with dozens of optional properties. There is no compile-time guarantee that a trim operation's output (trimmed reads) is compatible with the next operation's input requirements (e.g., paired-end merge requires interleaved input).

### 5.2 Design: Typed Operation Nodes with Input/Output Contracts

Rather than replacing `FASTQDerivativeOperation` (which is deeply embedded in persistence and the `BatchProcessingEngine`), add a compile-time validation layer on top:

```swift
// LungfishIO/Formats/FASTQ/OperationChain.swift

/// Describes what an operation produces.
public struct OperationOutput: Sendable, Equatable {
    /// The data format after the operation.
    public let format: DataFormat
    /// Whether paired-end structure is preserved.
    public let pairing: PairingState

    public enum DataFormat: String, Sendable {
        case fastq, fasta
    }

    public enum PairingState: String, Sendable {
        case interleaved     // R1/R2 interleaved in one file
        case splitPaired     // Separate R1 and R2 files
        case merged          // Overlapping pairs merged into singles
        case single          // Unpaired or unknown
        case mixed           // Multiple read types (merged + unmerged)
    }
}

/// Describes what an operation requires as input.
public struct OperationInput: Sendable, Equatable {
    public let acceptedFormats: Set<OperationOutput.DataFormat>
    public let requiredPairing: Set<OperationOutput.PairingState>?  // nil = any
}

/// Maps each operation kind to its input requirements and output shape.
public enum OperationContract {

    public static func input(for kind: FASTQDerivativeOperationKind) -> OperationInput {
        switch kind {
        case .pairedEndMerge, .pairedEndRepair:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: [.interleaved]
            )
        case .qualityTrim, .adapterTrim, .primerRemoval:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil  // works on any
            )
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .fixedTrim:
            return OperationInput(
                acceptedFormats: [.fastq, .fasta],
                requiredPairing: nil
            )
        case .contaminantFilter, .errorCorrection:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .interleaveReformat:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .demultiplex:
            return OperationInput(
                acceptedFormats: [.fastq],
                requiredPairing: nil
            )
        case .orient:
            return OperationInput(
                acceptedFormats: [.fastq, .fasta],
                requiredPairing: nil
            )
        }
    }

    public static func output(
        for kind: FASTQDerivativeOperationKind,
        inputPairing: OperationOutput.PairingState
    ) -> OperationOutput {
        switch kind {
        case .pairedEndMerge:
            return OperationOutput(format: .fastq, pairing: .mixed)
        case .pairedEndRepair:
            return OperationOutput(format: .fastq, pairing: .interleaved)
        case .interleaveReformat:
            // Toggle: interleaved -> splitPaired, splitPaired -> interleaved
            let newPairing: OperationOutput.PairingState =
                inputPairing == .interleaved ? .splitPaired : .interleaved
            return OperationOutput(format: .fastq, pairing: newPairing)
        case .demultiplex:
            return OperationOutput(format: .fastq, pairing: .single)
        default:
            // Most operations preserve the input pairing
            return OperationOutput(format: .fastq, pairing: inputPairing)
        }
    }
}
```

### 5.3 Recipe Validation

```swift
extension ProcessingRecipe {

    /// Validation error describing why a recipe is invalid.
    public enum ValidationError: Error, LocalizedError, Sendable {
        case incompatibleFormat(stepIndex: Int, expected: Set<OperationOutput.DataFormat>, got: OperationOutput.DataFormat)
        case incompatiblePairing(stepIndex: Int, expected: Set<OperationOutput.PairingState>, got: OperationOutput.PairingState)
        case demultiplexNotTerminal(stepIndex: Int)

        public var errorDescription: String? {
            switch self {
            case .incompatibleFormat(let i, let expected, let got):
                return "Step \(i + 1) requires \(expected) but receives \(got)."
            case .incompatiblePairing(let i, let expected, let got):
                return "Step \(i + 1) requires pairing \(expected) but receives \(got)."
            case .demultiplexNotTerminal(let i):
                return "Demultiplex at step \(i + 1) must be the last step."
            }
        }
    }

    /// Validates that each step's output is compatible with the next step's input.
    /// Returns nil if valid, or the first validation error.
    public func validate(
        inputFormat: OperationOutput.DataFormat = .fastq,
        inputPairing: OperationOutput.PairingState = .single
    ) -> ValidationError? {
        var currentFormat = inputFormat
        var currentPairing = inputPairing

        for (index, step) in steps.enumerated() {
            let input = OperationContract.input(for: step.kind)

            // Check format compatibility
            if !input.acceptedFormats.contains(currentFormat) {
                return .incompatibleFormat(
                    stepIndex: index,
                    expected: input.acceptedFormats,
                    got: currentFormat
                )
            }

            // Check pairing compatibility
            if let requiredPairing = input.requiredPairing,
               !requiredPairing.contains(currentPairing) {
                return .incompatiblePairing(
                    stepIndex: index,
                    expected: requiredPairing,
                    got: currentPairing
                )
            }

            // Demux must be terminal
            if step.kind == .demultiplex && index < steps.count - 1 {
                return .demultiplexNotTerminal(stepIndex: index)
            }

            // Compute output for next step
            let output = OperationContract.output(for: step.kind, inputPairing: currentPairing)
            currentFormat = output.format
            currentPairing = output.pairing
        }

        return nil
    }
}
```

### 5.4 Virtual Chain Composition

When the user adds operations in the UI, the chain is validated before the recipe is saved. The existing `BatchProcessingEngine.executeBatch()` already processes steps sequentially per barcode -- it passes each step's output bundle URL as the next step's input. The validation layer ensures this chain is well-typed before execution begins.

---

## 6. Error Handling and Recovery Patterns

### 6.1 Error Classification

```swift
/// Categories of errors during FASTQ operations, used for recovery decisions.
public enum FASTQOperationFailureKind: Sendable {
    /// Tool not found or not executable. Recovery: re-check tool installation.
    case toolMissing(toolName: String)

    /// Tool ran but returned nonzero exit. Recovery: show stderr, allow retry.
    case toolFailed(toolName: String, exitCode: Int32, stderr: String)

    /// Input file missing or unreadable. Recovery: re-scan project.
    case inputMissing(path: String)

    /// Root bundle for virtual derivative is gone. Recovery: user must re-import.
    case rootBundleLost(relativePath: String)

    /// Disk full or write permission denied. Recovery: clear space, check perms.
    case diskError(underlying: Error)

    /// Operation produced zero reads. Recovery: adjust parameters.
    case emptyResult

    /// User cancelled. Not an error -- normal flow.
    case cancelled

    /// Unknown error. Recovery: log and show to user.
    case unknown(Error)
}
```

### 6.2 Recovery Strategies

```swift
/// Encapsulates a recovery action for a failed operation.
public struct RecoveryAction: Sendable {
    public let label: String
    public let action: @Sendable () async throws -> Void
}

extension FASTQOperationFailureKind {

    /// Returns available recovery actions for this failure kind.
    public func recoveryActions(
        retryBlock: @escaping @Sendable () async throws -> Void
    ) -> [RecoveryAction] {
        switch self {
        case .toolMissing:
            return [
                RecoveryAction(label: "Check Tool Installation") {
                    // Re-verify tool paths
                }
            ]
        case .toolFailed:
            return [
                RecoveryAction(label: "Retry") { try await retryBlock() },
                RecoveryAction(label: "Show Log") { /* present stderr */ }
            ]
        case .inputMissing, .rootBundleLost:
            return [
                RecoveryAction(label: "Re-scan Project") {
                    // Trigger project rescan
                }
            ]
        case .emptyResult:
            return [
                RecoveryAction(label: "Adjust Parameters") {
                    // Open operation panel
                }
            ]
        case .cancelled, .diskError, .unknown:
            return []
        }
    }
}
```

### 6.3 Batch Error Continuation Strategy

The existing `BatchProcessingEngine.processBarcode()` already implements the correct pattern: on step failure, mark remaining steps as `.skipped` and continue to the next barcode. Extend this with structured error collection:

```swift
/// Result of a batch run, capturing per-barcode outcomes.
public struct BatchResult: Sendable {
    public let manifest: BatchManifest
    public let failedBarcodes: [(label: String, stepIndex: Int, error: FASTQOperationFailureKind)]
    public let completedBarcodes: Int
    public let skippedBarcodes: Int

    /// Whether the batch had any failures.
    public var hasFailures: Bool { !failedBarcodes.isEmpty }

    /// Summary suitable for a notification.
    public var summary: String {
        if failedBarcodes.isEmpty {
            return "All \(completedBarcodes) barcodes processed successfully."
        }
        return "\(completedBarcodes) succeeded, \(failedBarcodes.count) failed."
    }
}
```

### 6.4 Materialization Failure Recovery

When materialization fails mid-stream:

1. **Stale state on disk**: The manifest has `materializing(taskID:)`. On next launch, `resolvedState` returns `.virtual` (see section 1.3). The temp file is cleaned up by the `defer` block in the pipeline actor.

2. **Root bundle moved**: If the root FASTQ is missing, the existing `FASTQBundle.findBundleContaining(fastqFilename:from:)` recovery logic fires. If that also fails, surface `.rootBundleLost` with a "Re-scan Project" recovery action.

3. **Partial output**: The pipeline writes to a temp directory first, then atomically moves into the bundle. A crash during materialization never leaves a corrupt FASTQ inside the bundle.

---

## 7. Integration Points

### 7.1 FASTQDatasetViewController Changes

The existing `FASTQDatasetViewController` is `@MainActor`. Add:

- A "Materialize" button in the operations sidebar that creates a `VirtualFASTQDescriptor` and submits it to `MaterializationPipeline`.
- A progress indicator bound to the pipeline's callback via the GCD+assumeIsolated pattern.
- A "Cancel" button that calls `pipeline.cancel(taskID:)`.
- State display: "Virtual" / "Materializing (45%)" / "Materialized" badge next to the derivative name.

### 7.2 BatchProcessingEngine Changes

Extend `executeBatch` to accept an optional `materializeOutputs: Bool` parameter. When true, after all recipe steps complete for a barcode, submit the final output bundle to `MaterializationPipeline` if it's virtual. This enables "run recipe and materialize" as a single user action.

### 7.3 FASTQMetadataDrawerView Changes

The metadata drawer (currently in `ViewerViewController+FASTQDrawer.swift`) should display `resolvedState` from the manifest. For virtual derivatives, show the lineage chain. For materialized derivatives, show the checksum and file size.

---

## 8. Thread Safety Summary

| Component | Isolation | Rationale |
|---|---|---|
| `MaterializationState` | `Sendable` value type | Stored in Codable manifests, passed across boundaries |
| `VirtualFASTQDescriptor` | `Sendable` struct | Job specification, immutable after creation |
| `MaterializationPipeline` | `actor` | Owns mutable task registry, must serialize access |
| `ReferenceSequenceScanner` | `Sendable` struct + `AsyncStream` | Stateless scanner, stream handles concurrency |
| `OperationContract` | `enum` with static methods | Pure functions, no state |
| `FASTQDatasetViewController` | `@MainActor` | AppKit view controller, all UI updates |
| `FASTQDerivativeService` | `actor` (existing) | Runs external tools, manages temp directories |
| `BatchProcessingEngine` | `actor` (existing) | Bounded concurrency across barcodes |

### Critical Pattern Reminders

1. **NEVER** `Task { @MainActor in }` from actor methods. Use `DispatchQueue.main.async { MainActor.assumeIsolated { } }`.
2. **NEVER** store `Task` handles in Sendable structs. Store `UUID` correlators; look up live tasks from the actor.
3. **ALWAYS** check `Task.isCancelled` before each tool invocation in the materialization pipeline.
4. **ALWAYS** use `defer { try? FileManager.default.removeItem(at: tempDir) }` for temp directories.
5. **ALWAYS** use generation counters in `@MainActor` view controllers to discard stale callbacks.

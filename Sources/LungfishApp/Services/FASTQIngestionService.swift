// FASTQIngestionService.swift - App-level FASTQ ingestion with OperationCenter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "FASTQIngestionService")

// MARK: - FASTQIngestionService

/// App-level service that runs the FASTQ ingestion pipeline (clumpify → compress)
/// and reports progress via OperationCenter.
///
/// Call `ingestIfNeeded` from any FASTQ import path (SRA download, drag-drop, file import).
/// The service checks the sidecar metadata to skip already-ingested files.
@MainActor
public enum FASTQIngestionService {

    /// Ingests a FASTQ file if it hasn't already been processed.
    ///
    /// Runs clumpify → compress in the background via OperationCenter.
    /// The processed file replaces the original. Metadata sidecar is updated.
    ///
    /// - Parameters:
    ///   - url: URL of the FASTQ file to ingest
    ///   - pairingMode: Pairing mode (single-end, paired-end, interleaved)
    ///   - pairedFile: For paired-end, the second file (R2). The first is `url` (R1).
    ///   - existingMetadata: Existing metadata to preserve (SRA info, download date, etc.)
    public static func ingestIfNeeded(
        url: URL,
        pairingMode: FASTQIngestionConfig.PairingMode = .singleEnd,
        pairedFile: URL? = nil,
        existingMetadata: PersistedFASTQMetadata? = nil
    ) {
        // Skip if already ingested
        if let existing = existingMetadata ?? FASTQMetadataStore.load(for: url),
           let ingestion = existing.ingestion,
           ingestion.isClumpified && ingestion.isCompressed {
            logger.info("Skipping ingestion for \(url.lastPathComponent) — already processed")
            return
        }

        let inputFiles: [URL]
        if let pairedFile, pairingMode == .pairedEnd {
            inputFiles = [url, pairedFile]
        } else {
            inputFiles = [url]
        }

        let outputDir = url.deletingLastPathComponent()
        let config = FASTQIngestionConfig(
            inputFiles: inputFiles,
            pairingMode: pairingMode,
            outputDirectory: outputDir,
            threads: min(ProcessInfo.processInfo.processorCount, 8),
            deleteOriginals: true
        )

        let baseName = FASTQIngestionPipeline.deriveBaseName(from: url)
        let title = "FASTQ Ingestion: \(baseName)"

        // Register the operation FIRST so we have a stable ID to pass to the detached task.
        let opID = OperationCenter.shared.start(
            title: title,
            detail: "Preparing...",
            operationType: .ingestion
        )

        let task = Task.detached {
            await Self.runIngestion(
                config: config,
                operationID: opID,
                existingMetadata: existingMetadata
            )
        }

        // Store cancellation callback now that we have the task handle.
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    // MARK: - Ingest and Bundle

    /// Ingests a FASTQ file in a temp directory, then creates a `.lungfishfastq`
    /// bundle in the project directory with the processed file.
    ///
    /// Flow: source → temp copy → clumpify + compress → create bundle → move into bundle.
    ///
    /// - Parameters:
    ///   - sourceURL: Original FASTQ file (not modified).
    ///   - projectDirectory: Where to create the `.lungfishfastq` bundle.
    ///   - completion: Called on main thread with the bundle URL on success, or error.
    public static func ingestAndBundle(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        let title = "FASTQ Import: \(bundleName)"

        let opID = OperationCenter.shared.start(
            title: title,
            detail: "Copying to temp\u{2026}",
            operationType: .ingestion
        )

        let task = Task.detached {
            await Self.runIngestAndBundle(
                sourceURL: sourceURL,
                projectDirectory: projectDirectory,
                bundleName: bundleName,
                operationID: opID,
                completion: completion
            )
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    // MARK: - Pipeline Runners

    /// Runs the ingestion pipeline off the main actor.
    ///
    /// Must be `nonisolated` — the cooperative executor does not reliably schedule
    /// `@MainActor` methods called from `Task.detached`.  We hop to `MainActor.run`
    /// only for the few OperationCenter mutations that need it.
    nonisolated private static func runIngestion(
        config: FASTQIngestionConfig,
        operationID opID: UUID,
        existingMetadata: PersistedFASTQMetadata?
    ) async {
        do {
            let pipeline = FASTQIngestionPipeline()
            let result = try await pipeline.run(config: config) { fraction, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: opID,
                            progress: fraction,
                            detail: message
                        )
                    }
                }
            }

            guard result.wasClumpified else {
                throw FASTQIngestionError.clumpifyFailed("pipeline completed without clumpifying reads")
            }
            // Update metadata sidecar
            let pairingMode: IngestionMetadata.PairingMode = {
                switch result.pairingMode {
                case .singleEnd: return .singleEnd
                case .pairedEnd: return .interleaved  // paired-end becomes interleaved after clumpify
                case .interleaved: return .interleaved
                }
            }()

            let ingestion = IngestionMetadata(
                isClumpified: result.wasClumpified,
                isCompressed: true,
                pairingMode: pairingMode,
                qualityBinning: result.qualityBinning.rawValue,
                originalFilenames: result.originalFilenames,
                ingestionDate: Date(),
                originalSizeBytes: result.originalSizeBytes
            )

            var metadata = existingMetadata ?? PersistedFASTQMetadata()
            metadata.ingestion = ingestion
            FASTQMetadataStore.save(metadata, for: result.outputFile)

            let savedStr = ByteCountFormatter.string(
                fromByteCount: result.originalSizeBytes - result.finalSizeBytes,
                countStyle: .file
            )
            let detail = result.wasClumpified
                ? "Clumpified and compressed (saved \(savedStr))"
                : "Compressed (saved \(savedStr))"

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: [])
                }
            }

            logger.info("Ingestion complete: \(result.outputFile.lastPathComponent)")

        } catch is CancellationError {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                }
            }
        } catch {
            logger.error("Ingestion failed: \(error)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "\(error)")
                }
            }
        }
    }

    /// Ingests in a temp directory, creates the bundle, moves processed file in.
    nonisolated private static func runIngestAndBundle(
        sourceURL: URL,
        projectDirectory: URL,
        bundleName: String,
        operationID opID: UUID,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-fastq-ingest-\(UUID().uuidString)")

        do {
            // 1. Copy source to temp directory
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFASTQ = tempDir.appendingPathComponent(sourceURL.lastPathComponent)
            try fm.copyItem(at: sourceURL, to: tempFASTQ)

            logger.info("ingestAndBundle: Copied \(sourceURL.lastPathComponent) to temp dir")

            // 2. Run ingestion pipeline in temp
            let config = FASTQIngestionConfig(
                inputFiles: [tempFASTQ],
                pairingMode: .singleEnd,
                outputDirectory: tempDir,
                threads: min(ProcessInfo.processInfo.processorCount, 8),
                deleteOriginals: true
            )

            let pipeline = FASTQIngestionPipeline()
            let result = try await pipeline.run(config: config) { fraction, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: opID,
                            progress: fraction * 0.8, // Reserve 20% for bundling
                            detail: message
                        )
                    }
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.update(id: opID, progress: 0.85, detail: "Creating bundle\u{2026}")
                }
            }

            // 3. Create .lungfishfastq bundle in project
            let bundleURL = projectDirectory.appendingPathComponent(
                "\(bundleName).\(FASTQBundle.directoryExtension)"
            )
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            // 4. Move processed file into bundle
            let destFASTQ = bundleURL.appendingPathComponent(result.outputFile.lastPathComponent)
            try fm.moveItem(at: result.outputFile, to: destFASTQ)

            // 5. Write ingestion metadata sidecar in bundle
            let pairingMode: IngestionMetadata.PairingMode = {
                switch result.pairingMode {
                case .singleEnd: return .singleEnd
                case .pairedEnd: return .interleaved
                case .interleaved: return .interleaved
                }
            }()

            let ingestion = IngestionMetadata(
                isClumpified: result.wasClumpified,
                isCompressed: true,
                pairingMode: pairingMode,
                qualityBinning: result.qualityBinning.rawValue,
                originalFilenames: result.originalFilenames,
                ingestionDate: Date(),
                originalSizeBytes: result.originalSizeBytes
            )

            var metadata = PersistedFASTQMetadata()
            metadata.ingestion = ingestion
            FASTQMetadataStore.save(metadata, for: destFASTQ)

            // 6. Clean up temp directory
            try? fm.removeItem(at: tempDir)

            let savedStr = ByteCountFormatter.string(
                fromByteCount: result.originalSizeBytes - result.finalSizeBytes,
                countStyle: .file
            )
            let detail = "Imported and clumpified (saved \(savedStr))"

            logger.info("ingestAndBundle: Created bundle \(bundleURL.lastPathComponent)")

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: [bundleURL])
                    completion(.success(bundleURL))
                }
            }

        } catch is CancellationError {
            try? fm.removeItem(at: tempDir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    completion(.failure(CancellationError()))
                }
            }
        } catch {
            try? fm.removeItem(at: tempDir)
            logger.error("ingestAndBundle: \(error)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: opID, detail: "\(error)")
                    completion(.failure(error))
                }
            }
        }
    }
}

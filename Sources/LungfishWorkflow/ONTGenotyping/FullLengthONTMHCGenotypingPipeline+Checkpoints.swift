import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func importRequestedCheckpointGeneration(
        request: FullLengthONTMHCGenotypingRunRequest,
        priorFinalOutputURL: URL,
        stagedOutputURL: URL
    ) throws {
        let sampleNames = plannedSampleNames(for: request.inputFASTQURLs)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for sample in sampleNames {
            try Task.checkCancellation()
            let relativeCheckpointPath = ".full-length-ont-mhc/checkpoints/samples/\(sample).json"
            let sourceCheckpointURL = priorFinalOutputURL.appendingPathComponent(relativeCheckpointPath)
            guard FileManager.default.fileExists(atPath: sourceCheckpointURL.path) else { continue }
            let checkpointDescriptor: Int32
            do {
                checkpointDescriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
                    sourceCheckpointURL,
                    within: priorFinalOutputURL,
                    role: "sample checkpoint"
                )
            } catch {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Prior sample checkpoint must be reachable through real directories and be a regular file without symlinks: \(sourceCheckpointURL.path) (\(error.localizedDescription))"
                )
            }
            let checkpointData = try readData(
                from: checkpointDescriptor,
                role: "sample checkpoint",
                maximumBytes: 16 * 1_024 * 1_024
            )
            guard let checkpoint = try? decoder.decode(
                FullLengthONTMHCSampleCheckpoint.self,
                from: checkpointData
            ), checkpoint.schemaVersion == FullLengthONTMHCSampleCheckpoint.schemaVersion,
               checkpoint.signature.sample == sample,
               checkpoint.result.sample == sample else {
                continue
            }

            var allowedSourceFiles = Set<URL>()
            allowedSourceFiles.insert(checkpoint.result.clustersFASTAURL.standardizedFileURL)
            for url in checkpoint.result.steps.flatMap(\.outputs) {
                allowedSourceFiles.insert(url.standardizedFileURL)
            }
            for sourceURL in allowedSourceFiles.sorted(by: { $0.path < $1.path }) {
                try copyCheckpointRegularFile(
                    sourceURL,
                    sample: sample,
                    priorFinalOutputURL: priorFinalOutputURL,
                    stagedOutputURL: stagedOutputURL
                )
            }

            let destinationCheckpointURL = stagedOutputURL.appendingPathComponent(relativeCheckpointPath)
            try FileManager.default.createDirectory(
                at: destinationCheckpointURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try checkpointData.write(to: destinationCheckpointURL, options: .atomic)
            try rewriteJSONStrings(
                at: destinationCheckpointURL,
                replacing: priorFinalOutputURL.standardizedFileURL.path,
                with: stagedOutputURL.standardizedFileURL.path
            )
        }
    }

    internal func plannedSampleNames(for inputURLs: [URL]) -> [String] {
        var counts: [String: Int] = [:]
        return inputURLs.enumerated().map { index, url in
            let base = sampleName(for: url, fallbackIndex: index)
            let occurrence = (counts[base] ?? 0) + 1
            counts[base] = occurrence
            return occurrence == 1 ? base : "\(base)-\(occurrence)"
        }
    }

    internal func copyCheckpointRegularFile(
        _ sourceURL: URL,
        sample: String,
        priorFinalOutputURL: URL,
        stagedOutputURL: URL
    ) throws {
        let source = sourceURL.standardizedFileURL
        let rootComponents = priorFinalOutputURL.standardizedFileURL.pathComponents
        let sourceComponents = source.pathComponents
        guard sourceComponents.count > rootComponents.count,
              Array(sourceComponents.prefix(rootComponents.count)) == rootComponents else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Prior sample checkpoint output escapes its result bundle: \(source.path)"
            )
        }
        let relativeComponents = Array(sourceComponents.dropFirst(rootComponents.count))
        guard relativeComponents.count >= 3,
              relativeComponents[0] == "samples",
              relativeComponents[1] == sample else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Prior sample checkpoint output is outside the allowed sample directory: \(source.path)"
            )
        }
        let sourceDescriptor: Int32
        do {
            sourceDescriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
                source,
                within: priorFinalOutputURL,
                role: "sample checkpoint output"
            )
        } catch {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Prior sample checkpoint output must be reachable through real directories and be a regular file without symlinks: \(source.path) (\(error.localizedDescription))"
            )
        }
        let destination = relativeComponents.reduce(stagedOutputURL) {
            $0.appendingPathComponent($1)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let imported = try copyRegularFile(
            from: sourceDescriptor,
            to: destination,
            role: "sample checkpoint output"
        )
        let destinationSize = try ProvenanceFileHasher.fileSize(of: destination)
        let destinationChecksum = try ProvenanceFileHasher.sha256(of: destination) {
            try Task.checkCancellation()
        }
        guard imported.size == destinationSize, imported.sha256 == destinationChecksum else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Imported sample checkpoint output failed size/checksum validation: \(source.path)"
            )
        }
    }

    internal func readData(
        from descriptor: Int32,
        role: String,
        maximumBytes: Int
    ) throws -> Data {
        defer { Darwin.close(descriptor) }
        var result = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try readDescriptorChunk(descriptor, maximumBytes: 1_024 * 1_024)
            guard !chunk.isEmpty else { return result }
            guard result.count <= maximumBytes - chunk.count else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "\(role.capitalized) exceeds \(maximumBytes) bytes."
                )
            }
            result.append(chunk)
        }
    }

    internal func copyRegularFile(
        from sourceDescriptor: Int32,
        to destination: URL,
        role: String
    ) throws -> (size: UInt64, sha256: String) {
        defer { Darwin.close(sourceDescriptor) }
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(destinationDescriptor) }
        var hasher = SHA256()
        var size: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try readDescriptorChunk(sourceDescriptor, maximumBytes: 1_024 * 1_024)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            size += UInt64(chunk.count)
            try chunk.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < chunk.count {
                    let count = Darwin.write(
                        destinationDescriptor,
                        baseAddress.advanced(by: written),
                        chunk.count - written
                    )
                    guard count > 0 else {
                        throw FullLengthONTMHCGenotypingError.reportFailed(
                            "Could not copy \(role): \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)"
                        )
                    }
                    written += count
                }
            }
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, sha256)
    }

    internal func readDescriptorChunk(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = Darwin.read(descriptor, &bytes, maximumBytes)
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(bytes.prefix(count))
    }

    internal func rewriteCheckpointPaths(
        in bundleURL: URL,
        replacing oldValue: String,
        with newValue: String
    ) throws {
        let checkpointDirectory = bundleURL
            .appendingPathComponent(".full-length-ont-mhc/checkpoints/samples", isDirectory: true)
        guard FileManager.default.fileExists(atPath: checkpointDirectory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(
            at: checkpointDirectory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension.lowercased() == "json" }) {
            try rewriteJSONStrings(
                at: url,
                replacing: oldValue,
                with: newValue
            )
        }
    }

    internal func rewriteJSONStrings(
        at url: URL,
        replacing oldValue: String,
        with newValue: String
    ) throws {
        func rewritten(_ value: Any) -> Any {
            if let string = value as? String {
                return string.replacingOccurrences(of: oldValue, with: newValue)
            }
            if let array = value as? [Any] {
                return array.map(rewritten)
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(rewritten)
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let data = try JSONSerialization.data(
            withJSONObject: rewritten(object),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    internal func loadCompatibleSampleCheckpoint(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration
    ) throws -> (url: URL, result: FullLengthONTMHCSampleResult)? {
        let checkpointURL = sampleCheckpointURL(for: scheduled.sample, request: request)
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(
            FullLengthONTMHCSampleCheckpoint.self,
            from: Data(contentsOf: checkpointURL)
        ) else { return nil }
        guard checkpoint.schemaVersion == FullLengthONTMHCSampleCheckpoint.schemaVersion,
              checkpoint.signature == (try sampleCheckpointSignature(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
              )),
              durableSampleCheckpointOutputsExist(for: checkpoint.result) else {
            return nil
        }
        return (checkpointURL, checkpoint.result)
    }

    internal func saveSampleCheckpoint(
        result: FullLengthONTMHCSampleResult,
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration
    ) throws -> FullLengthONTMHCSampleResult {
        guard request.keepIntermediates || request.reuseCompatibleCheckpoints else {
            return result
        }
        let checkpointURL = sampleCheckpointURL(for: scheduled.sample, request: request)
        try FileManager.default.createDirectory(
            at: checkpointURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let checkpoint = FullLengthONTMHCSampleCheckpoint(
            signature: try sampleCheckpointSignature(
                scheduled: scheduled,
                preparedFASTQ: preparedFASTQ,
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                execution: execution
            ),
            result: result,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
        return result
    }

    internal func sampleCheckpointURL(
        for sample: String,
        request: FullLengthONTMHCGenotypingRunRequest
    ) -> URL {
        request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc", isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent("\(sample).json")
    }

    internal func sampleCheckpointSignature(
        scheduled: FullLengthONTMHCScheduledSample,
        preparedFASTQ: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        referenceFASTAURL: URL,
        execution: FullLengthONTMHCSampleExecutionConfiguration
    ) throws -> FullLengthONTMHCSampleCheckpointSignature {
        try FullLengthONTMHCSampleCheckpointSignature(
            sample: scheduled.sample,
            sourceFASTQ: .fingerprint(url: scheduled.inputURL),
            preparedFASTQ: .fingerprint(url: preparedFASTQ),
            referenceFASTA: .fingerprint(url: referenceFASTAURL),
            orientReference: request.orientReferenceURL.map { try .fingerprint(url: $0) },
            forwardPrimer: request.forwardPrimerURL.map { try .fingerprint(url: $0) },
            reversePrimer: request.reversePrimerURL.map { try .fingerprint(url: $0) },
            minimumLength: request.minimumLength,
            maximumLength: request.maximumLength,
            savontQualityValueCutoff: request.savontQualityValueCutoff,
            savontMinimumClusterSize: request.savontMinimumClusterSize,
            minUnmatchedReads: request.minUnmatchedReads,
            cdnaThreshold: request.cdnaThreshold,
            workerThreads: execution.workerThreads,
            savontThreads: execution.savontThreads,
            savontToolVersion: FullLengthONTMHCGenotypingRunRequest.savontToolVersion,
            savontCondaEnvironment: FullLengthONTMHCGenotypingRunRequest.savontCondaEnvironment,
            savontPackageSpec: FullLengthONTMHCGenotypingRunRequest.savontPackageSpec
        )
    }

    internal func durableSampleCheckpointOutputsExist(
        for result: FullLengthONTMHCSampleResult
    ) -> Bool {
        let urls = result.steps
            .flatMap(\.outputs)
            .filter { $0.path.contains("/samples/\(result.sample)/") }
        return !urls.isEmpty && urls.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    internal func sampleCheckpointReuseStep(
        checkpointURL: URL,
        result: FullLengthONTMHCSampleResult
    ) -> FullLengthONTMHCProvenanceStep {
        let completedAt = Date()
        let outputs = result.steps
            .flatMap(\.outputs)
            .filter { $0.path.contains("/samples/\(result.sample)/") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return FullLengthONTMHCProvenanceStep(
            toolName: "lungfish full-length ONT MHC sample checkpoint reuse",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                CLICommandIdentity.executableName,
                "fastq",
                "full-length-ont-mhc-genotype",
                "reuse-sample-checkpoint",
                result.sample,
                "--checkpoint",
                checkpointURL.path,
            ],
            inputs: [checkpointURL],
            outputs: outputs,
            exitStatus: 0,
            stderr: nil,
            startedAt: completedAt,
            completedAt: completedAt
        )
    }
}

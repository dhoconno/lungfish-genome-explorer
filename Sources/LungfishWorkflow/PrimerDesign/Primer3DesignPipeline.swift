import Foundation
import Darwin
import LungfishIO

public enum Primer3DesignError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case inputChanged(String)
    case versionUnavailable
    case executionFailed(Int32, String)
    case malformedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): "Invalid Primer3 design request: \(message)"
        case .inputChanged(let path): "Primer3 input changed after selection: \(path)"
        case .versionUnavailable: "Could not establish the exact Primer3 version before design."
        case .executionFailed(let status, let stderr): "Primer3 exited with status \(status): \(stderr)"
        case .malformedOutput(let message): "Malformed Primer3 output: \(message)"
        }
    }
}

public struct Primer3DesignPipeline: Sendable {
    private let runner: Primer3DesignRunner
    private let writer: PrimerAnalysisBundleWriter
    private let runtimePreparer: PrimerDesignManagedRuntime.Preparer?

    public init() {
        runner = Primer3NativeRunner.run
        writer = PrimerAnalysisBundleWriter()
        runtimePreparer = { try await PrimerDesignManagedRuntime.prepareAndAcquire(toolID: "primer3", progress: $0) }
    }

    init(runner: @escaping Primer3DesignRunner, writer: PrimerAnalysisBundleWriter = .init(), runtimePreparer: PrimerDesignManagedRuntime.Preparer? = nil) {
        self.runner = runner
        self.writer = writer
        self.runtimePreparer = runtimePreparer
    }

    public static func inspectInput(at url: URL) async throws -> Primer3DesignInputSummary {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Primer3InputLoader.inspect(url)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    public func run(
        request: Primer3DesignRequest,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await runDetached(request: request, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func runDetached(
        request: Primer3DesignRequest,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        try Self.validate(request)
        let destinationURL = try Self.physicalDestination(request.destinationURL)
        let runtimeLease = request.executableURL == nil ? try await runtimePreparer?(progress) : nil
        defer { runtimeLease?.release() }
        progress?(0.05, "Validating selected templates")
        try Task.checkCancellation()
        let prepared = try request.selections.map { selection in
            try Task.checkCancellation()
            if let expected = request.expectedInputChecksums[selection.inputURL] {
                guard try Primer3InputLoader.fingerprint(selection.inputURL).caseInsensitiveCompare(expected) == .orderedSame else { throw Primer3DesignError.inputChanged(selection.inputURL.path) }
            }
            return try Primer3InputLoader.prepare(selection)
        }
        let fileManager = FileManager.default
        let scratch = destinationURL.deletingLastPathComponent().appendingPathComponent(".lungfish-primer3-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let native = scratch.appendingPathComponent("native", isDirectory: true)
        let inputsDirectory = scratch.appendingPathComponent("inputs", isDirectory: true)
        let resultsDirectory = scratch.appendingPathComponent("results", isDirectory: true)
        let provenanceDirectory = scratch.appendingPathComponent("execution-provenance", isDirectory: true)
        for directory in [native, inputsDirectory, resultsDirectory, provenanceDirectory] { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }

        var artifacts: [PrimerAnalysisSourceArtifact] = []
        var analysisInputs: [PrimerAnalysisInput] = []
        for template in prepared {
            let sourceArtifacts = try Self.snapshotSource(template, scratch: scratch)
            artifacts.append(contentsOf: sourceArtifacts.artifacts)
            let relative = "inputs/\(template.inputID.uuidString).fasta"
            let snapshot = scratch.appendingPathComponent(relative)
            try Data(">\(template.inputID.uuidString)\n\(template.sequence)\n".utf8).write(to: snapshot, options: .atomic)
            artifacts.append(.init(sourceURL: snapshot, relativePath: relative, role: "input", format: "fasta"))
            analysisInputs.append(.init(id: template.inputID, label: template.title, artifactPaths: sourceArtifacts.paths + [relative]))
        }
        for (url, expected) in request.expectedInputChecksums {
            guard try Primer3InputLoader.fingerprint(url).caseInsensitiveCompare(expected) == .orderedSame else { throw Primer3DesignError.inputChanged(url.path) }
        }

        let boulderURL = native.appendingPathComponent("primer3-input.boulder")
        let outputURL = native.appendingPathComponent("primer3-output.boulder")
        let stderrURL = native.appendingPathComponent("primer3.stderr.txt")
        let stdoutURL = native.appendingPathComponent("primer3.stdout.txt")
        let boulder = try Primer3BoulderWriter.makeInput(templates: prepared, options: request.options)
        try Data(boulder.utf8).write(to: boulderURL, options: .atomic)
        progress?(0.25, "Running Primer3")
        let receipt = try await runner(.init(executableURL: request.executableURL, inputURL: boulderURL, outputURL: outputURL, workingDirectory: scratch, managedEnvironmentURL: runtimeLease?.environmentURL))
        try Data(receipt.stdout.utf8).write(to: stdoutURL, options: .atomic)
        try Data(receipt.stderr.utf8).write(to: stderrURL, options: .atomic)
        guard receipt.exitStatus == 0 else { throw Primer3DesignError.executionFailed(receipt.exitStatus, receipt.stderr) }
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: outputURL.path) else { throw Primer3DesignError.malformedOutput("native output file is missing") }
        let raw = try String(contentsOf: outputURL, encoding: .utf8)
        let parsed = try Primer3BoulderParser.parse(raw, expectedResultIDs: prepared.map(\.resultID))
        let enriched = zip(parsed, prepared).map { result, template in
            Primer3TemplateResult(resultID: result.resultID, inputID: template.inputID, title: template.title, sourceKind: template.sourceKind.rawValue, sourceIndex: template.sourceIndex, sourceRecordID: template.sourceRecordID, templateSequence: template.sequence, alignmentToTemplate: template.alignmentToTemplate, excludedRegions: template.excludedRegions.map { .init(start: $0.lowerBound, end: $0.upperBound) }, pairs: result.pairs, error: result.error, explanation: result.explanation)
        }
        for result in enriched {
            for pair in result.pairs {
                guard pair.left.start >= 0, pair.right.end <= result.templateSequence.count,
                      pair.left.end <= pair.right.start,
                      pair.productSize == pair.right.end - pair.left.start,
                      pair.internalOligo.map({ $0.start >= 0 && $0.end <= result.templateSequence.count }) ?? true,
                      Self.matchesTemplate(pair.left, in: result.templateSequence),
                      Self.matchesTemplate(pair.right, in: result.templateSequence),
                      pair.internalOligo.map({ Self.matchesTemplate($0, in: result.templateSequence) }) ?? true,
                      !Self.overlapsExcludedBindingPosition(pair.left, exclusions: result.excludedRegions),
                      !Self.overlapsExcludedBindingPosition(pair.right, exclusions: result.excludedRegions),
                      pair.internalOligo.map({ !Self.overlapsExcludedBindingPosition($0, exclusions: result.excludedRegions) }) ?? true else {
                    throw Primer3DesignError.malformedOutput("primer coordinates or product size are inconsistent with template \(result.title)")
                }
            }
        }
        let analysisID = UUID(), runID = UUID()
        let normalizedURL = resultsDirectory.appendingPathComponent("primer3-normalized-v1.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Primer3NormalizedResults(analysisID: analysisID, runID: runID, results: enriched)).write(to: normalizedURL, options: .atomic)
        var annotationArtifacts: [PrimerAnalysisSourceArtifact] = []
        for result in enriched {
            let relative = "annotations/\(result.inputID.uuidString).bed"
            let url = scratch.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Self.bed14(result: result, analysisID: analysisID).utf8).write(to: url, options: .atomic)
            annotationArtifacts.append(.init(sourceURL: url, relativePath: relative, role: "derivedAnnotation", format: "bed"))
        }

        let replayArgv = [
            receipt.argv[0],
            "--output=\(destinationURL.appendingPathComponent("native/primer3-output.boulder").path)",
            destinationURL.appendingPathComponent("native/primer3-input.boulder").path,
        ]
        var builder = ProvenanceRunBuilder(workflowName: "primer3.design", workflowVersion: "1", toolName: "Primer3", toolVersion: receipt.version)
            .argv(receipt.argv)
            .durableReplayArgv(replayArgv)
            .reproducibleCommand(replayArgv.map(Self.shellQuote).joined(separator: " "))
            .options(explicit: Self.provenanceOptions(request.options), defaults: Self.fixedBoulderDefaults, resolved: Self.provenanceOptions(request.options, prepared: prepared, expectedChecksums: request.expectedInputChecksums).merging(Self.fixedBoulderDefaults) { current, _ in current })
            .runtime(receipt.runtimeIdentity)
        let finalInput = ProvenanceFileDescriptor(
            path: destinationURL.appendingPathComponent("native/primer3-input.boulder").path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: boulderURL),
            fileSize: try ProvenanceFileHasher.fileSize(of: boulderURL), format: .text, role: .input,
            originPath: boulderURL.path)
        let finalOutput = ProvenanceFileDescriptor(
            path: destinationURL.appendingPathComponent("native/primer3-output.boulder").path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: outputURL),
            fileSize: try ProvenanceFileHasher.fileSize(of: outputURL), format: .text, role: .output,
            originPath: outputURL.path)
        builder = try builder.consumedInputSnapshot(finalInput)
        builder = try builder.relocatedOutput(finalOutput)
        let envelope = try builder.complete(exitStatus: Int(receipt.exitStatus), stderr: receipt.stderr, startedAt: receipt.startedAt, endedAt: receipt.endedAt)
        let toolProvenanceURL = provenanceDirectory.appendingPathComponent("primer3.json")
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: toolProvenanceURL)

        var normalization = ProvenanceRunBuilder(workflowName: "lungfish.primer3.normalize", workflowVersion: "1", toolName: "Lungfish Primer3 Result Normalizer", toolVersion: request.invocation.callerVersion)
            .argv(request.invocation.argv)
            .reproducibleCommand(request.invocation.argv.map(Self.shellQuote).joined(separator: " "))
            .options(explicit: request.invocation.explicitOptions, defaults: [:], resolved: Self.provenanceOptions(request.options, prepared: prepared, expectedChecksums: request.expectedInputChecksums))
            .runtime(request.invocation.runtimeIdentity)
        normalization = try normalization.consumedInputSnapshot(ProvenanceFileDescriptor(
            path: finalOutput.path, checksumSHA256: finalOutput.checksumSHA256,
            fileSize: finalOutput.fileSize, format: finalOutput.format, role: .input,
            originPath: finalOutput.originPath))
        let derivedFiles = [(normalizedURL, "results/primer3-normalized-v1.json", FileFormat.json)]
            + annotationArtifacts.map { ($0.sourceURL, $0.relativePath, FileFormat.bed) }
        for (origin, relative, format) in derivedFiles {
            normalization = try normalization.relocatedOutput(ProvenanceFileDescriptor(
                path: destinationURL.appendingPathComponent(relative).path,
                checksumSHA256: try ProvenanceFileHasher.sha256(of: origin),
                fileSize: try ProvenanceFileHasher.fileSize(of: origin), format: format, role: .output,
                originPath: origin.path))
        }
        let normalizationEnvelope = try normalization.complete(exitStatus: 0, startedAt: receipt.endedAt, endedAt: Date())
        let normalizationProvenanceURL = provenanceDirectory.appendingPathComponent("normalization.json")
        _ = try ProvenanceWriter(signingProvider: nil).write(normalizationEnvelope, toSidecar: normalizationProvenanceURL)

        artifacts += [
            .init(sourceURL: boulderURL, relativePath: "native/primer3-input.boulder", role: "input", format: "text"),
            .init(sourceURL: outputURL, relativePath: "native/primer3-output.boulder", role: "nativeOutput", format: "text"),
            .init(sourceURL: stdoutURL, relativePath: "native/primer3.stdout.txt", role: "log", format: "text"),
            .init(sourceURL: stderrURL, relativePath: "native/primer3.stderr.txt", role: "log", format: "text"),
            .init(sourceURL: normalizedURL, relativePath: "results/primer3-normalized-v1.json", role: "normalizedResult", format: "json"),
            .init(sourceURL: toolProvenanceURL, relativePath: "execution-provenance/primer3.json", role: "toolProvenance", format: "json"),
            .init(sourceURL: normalizationProvenanceURL, relativePath: "execution-provenance/normalization.json", role: "workflowProvenance", format: "json"),
        ] + annotationArtifacts
        let analysisResults = enriched.map { PrimerAnalysisResult(id: $0.resultID, label: $0.title, inputIDs: [$0.inputID], artifactPaths: ["native/primer3-output.boulder", "results/primer3-normalized-v1.json", "annotations/\($0.inputID.uuidString).bed"]) }
        progress?(0.9, "Publishing Primer3 analysis")
        _ = try writer.write(.init(analysisID: analysisID, runID: runID, grouping: .independent, inputs: analysisInputs, results: analysisResults, artifacts: artifacts, destinationURL: destinationURL, invocation: request.invocation))
        progress?(1, "Primer3 analysis complete")
        return destinationURL
    }

    static func validate(_ request: Primer3DesignRequest) throws {
        try validate(request.options)
        guard !request.inputURLs.isEmpty, !request.selections.isEmpty else { throw Primer3DesignError.invalidRequest("at least one input and explicit selection are required") }
        let inputs = Set(request.inputURLs.map { $0.standardizedFileURL })
        guard request.selections.allSatisfy({ inputs.contains($0.inputURL.standardizedFileURL) }) else { throw Primer3DesignError.invalidRequest("every selection must reference a declared input") }
        guard inputs.allSatisfy({ input in request.selections.contains { $0.inputURL.standardizedFileURL == input } }) else { throw Primer3DesignError.invalidRequest("every declared input must have a selection") }
        guard request.inputURLs.allSatisfy({ url in
            guard let digest = request.expectedInputChecksums[url] else { return false }
            return digest.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
        }) else { throw Primer3DesignError.invalidRequest("inspection checksum is required for every input") }
        guard request.destinationURL.pathExtension.lowercased() == "lungfishprimeranalysis", !FileManager.default.fileExists(atPath: request.destinationURL.path) else { throw Primer3DesignError.invalidRequest("destination must be a new .lungfishprimeranalysis bundle") }
    }

    static func validate(_ options: Primer3DesignOptions) throws {
        guard options.productSizeMin > 0, options.productSizeMin <= options.productSizeMax,
              options.pairCount > 0, options.primerMinSize > 0,
              options.primerMinSize <= options.primerOptSize, options.primerOptSize <= options.primerMaxSize,
              options.primerMinTm.isFinite, options.primerOptTm.isFinite, options.primerMaxTm.isFinite,
              options.primerMinTm <= options.primerOptTm, options.primerOptTm <= options.primerMaxTm,
              options.primerMinGC.isFinite, options.primerMaxGC.isFinite,
              options.primerMinGC >= 0, options.primerMinGC <= options.primerMaxGC, options.primerMaxGC <= 100,
              (options.targetStart == nil) == (options.targetEnd == nil) else { throw Primer3DesignError.invalidRequest("option values are out of range or order") }
        if let start = options.targetStart, let end = options.targetEnd, !(start > 0 && start <= end) { throw Primer3DesignError.invalidRequest("target must be 1-based inclusive and ordered") }
    }

    private static func provenanceOptions(_ options: Primer3DesignOptions) -> [String: ParameterValue] {
        ["PRIMER_PRODUCT_SIZE_RANGE": .string("\(options.productSizeMin)-\(options.productSizeMax)"), "SEQUENCE_TARGET_1_BASED_INCLUSIVE": options.targetStart.flatMap { start in options.targetEnd.map { ParameterValue.string("\(start)-\($0)") } } ?? ParameterValue.null, "PRIMER_NUM_RETURN": .integer(options.pairCount), "PRIMER_MIN_SIZE": .integer(options.primerMinSize), "PRIMER_OPT_SIZE": .integer(options.primerOptSize), "PRIMER_MAX_SIZE": .integer(options.primerMaxSize), "PRIMER_MIN_TM": .number(options.primerMinTm), "PRIMER_OPT_TM": .number(options.primerOptTm), "PRIMER_MAX_TM": .number(options.primerMaxTm), "PRIMER_MIN_GC": .number(options.primerMinGC), "PRIMER_MAX_GC": .number(options.primerMaxGC), "PRIMER_PICK_INTERNAL_OLIGO": .integer(options.pickInternalOligo ? 1 : 0)]
    }
    private static let fixedBoulderDefaults: [String: ParameterValue] = [
        "PRIMER_TASK": .string("generic"), "PRIMER_FIRST_BASE_INDEX": .integer(0),
        "PRIMER_PICK_LEFT_PRIMER": .integer(1), "PRIMER_PICK_RIGHT_PRIMER": .integer(1),
        "PRIMER_MAX_NS_ACCEPTED": .integer(0), "PRIMER_INTERNAL_MAX_NS_ACCEPTED": .integer(0),
        "PRIMER_EXPLAIN_FLAG": .integer(1),
    ]
    private static func provenanceOptions(_ options: Primer3DesignOptions, prepared: [Primer3PreparedTemplate], expectedChecksums: [URL: String]) -> [String: ParameterValue] {
        var values = provenanceOptions(options)
        values["selections"] = .array(prepared.map { template in
            let masked = (try? Primer3BoulderWriter.maskedSequence(for: template)) ?? template.sequence
            return .dictionary([
                "inputID": .string(template.inputID.uuidString), "resultID": .string(template.resultID.uuidString),
                "sourcePath": .string(template.sourceURL.path), "sourceIndex": .integer(template.sourceIndex),
                "sourceKind": .string(template.sourceKind.rawValue), "sourceRecordID": .string(template.sourceRecordID), "bindingSitePolicy": .string(template.bindingSitePolicy.rawValue),
                "sourceFingerprint": .string(expectedChecksums[template.sourceURL] ?? "unsupplied"),
                "unmaskedTemplateSHA256": .string(MultipleSequenceAlignmentBundle.sha256Hex(for: Data(template.sequence.utf8))),
                "nativeMaskedTemplateSHA256": .string(MultipleSequenceAlignmentBundle.sha256Hex(for: Data(masked.utf8))),
                "excludedRegions": .array(template.excludedRegions.map { .string("\($0.lowerBound),\($0.count)") }),
            ])
        })
        values["coordinateConvention"] = .string("target-input-1-based-inclusive; normalized-output-0-based-half-open")
        values["bindingExclusionEncoding"] = .string("excluded zero-based template positions are replaced by N only in native Boulder SEQUENCE_TEMPLATE; PRIMER_MAX_NS_ACCEPTED=0 and PRIMER_INTERNAL_MAX_NS_ACCEPTED=0 prevent primers and internal oligos from overlapping them; normalized and selected-template artifacts retain the original unmasked sequence")
        return values
    }

    private static func overlapsExcludedBindingPosition(_ oligo: Primer3Oligo, exclusions: [Primer3CoordinateRange]) -> Bool {
        exclusions.contains { exclusion in oligo.start < exclusion.end && exclusion.start < oligo.end }
    }

    private static func matchesTemplate(_ oligo: Primer3Oligo, in template: String) -> Bool {
        guard oligo.start >= 0, oligo.end <= template.count, oligo.start < oligo.end else { return false }
        let start = template.index(template.startIndex, offsetBy: oligo.start)
        let end = template.index(template.startIndex, offsetBy: oligo.end)
        let source = String(template[start..<end]).uppercased()
        let expected = oligo.orientation == .forward ? source : reverseComplement(source)
        return expected == oligo.sequence.uppercased()
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base in
            switch base {
            case "A": "T"; case "C": "G"; case "G": "C"; case "T": "A"
            default: "N"
            }
        })
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func physicalDestination(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw Primer3DesignError.invalidRequest("destination path is unsafe") }
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { throw Primer3DesignError.invalidRequest("destination parent must already exist") }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    private static func bed14(result: Primer3TemplateResult, analysisID: UUID) -> String {
        let attributes = "lungfish_primer_link_version=1;lungfish_primer_analysis_id=\(analysisID.uuidString);lungfish_primer_result_id=\(result.resultID.uuidString);lungfish_primer_input_id=\(result.inputID.uuidString);lungfish_source_index=\(result.sourceIndex)"
        var rows: [String] = []
        for (pairIndex, pair) in result.pairs.enumerated() {
            var oligos: [(Primer3Oligo, String, String)] = [
                (pair.left, "pair-\(pairIndex + 1)-left", "primer_bind"),
                (pair.right, "pair-\(pairIndex + 1)-right", "primer_bind"),
            ]
            if let internalOligo = pair.internalOligo { oligos.append((internalOligo, "pair-\(pairIndex + 1)-internal", "internal_oligo")) }
            for (oligo, label, type) in oligos {
                rows.append([result.inputID.uuidString, String(oligo.start), String(oligo.end), "\(label)-\(oligo.id.uuidString)", "0", oligo.orientation == .forward ? "+" : "-", String(oligo.start), String(oligo.end), "0,0,0", "1", String(oligo.end - oligo.start), "0", type, attributes].joined(separator: "\t"))
            }
        }
        return rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
    }

    private static func snapshotSource(_ template: Primer3PreparedTemplate, scratch: URL) throws -> (artifacts: [PrimerAnalysisSourceArtifact], paths: [String]) {
        let fileManager = FileManager.default
        let rootRelative = "source-inputs/\(template.inputID.uuidString)"
        let root = scratch.appendingPathComponent(rootRelative, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var sourceFiles: [(URL, String)] = []
        if template.sourceKind == .fasta {
            guard try Self.fileType(at: template.sourceURL) == .typeRegular else {
                throw Primer3DesignError.invalidRequest("FASTA source must be a regular file: \(template.sourceURL.path)")
            }
            sourceFiles = [(template.sourceURL, template.sourceURL.lastPathComponent)]
        } else {
            sourceFiles = try Self.regularFilesRecursively(in: template.sourceURL).sorted { $0.1 < $1.1 }
        }
        var artifacts: [PrimerAnalysisSourceArtifact] = [], paths: [String] = []
        for (source, suffix) in sourceFiles {
            let relative = rootRelative + "/" + suffix
            let destination = scratch.appendingPathComponent(relative)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            artifacts.append(.init(sourceURL: destination, relativePath: relative, role: "input", format: Self.snapshotFormat(for: suffix)))
            paths.append(relative)
        }
        let snapshotRoot = template.sourceKind == .fasta ? root.appendingPathComponent(template.sourceURL.lastPathComponent) : root
        let snapshotToken = try Primer3InputLoader.fingerprint(snapshotRoot)
        let sourceToken = try Primer3InputLoader.fingerprint(template.sourceURL)
        guard snapshotToken == sourceToken else { throw Primer3DesignError.inputChanged(template.sourceURL.path) }
        return (artifacts, paths)
    }

    private static func regularFilesRecursively(in root: URL, relativePrefix: String = "") throws -> [(URL, String)] {
        guard try fileType(at: root) == .typeDirectory else {
            throw Primer3DesignError.invalidRequest("native MSA source must be a directory: \(root.path)")
        }
        var files: [(URL, String)] = []
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relative = relativePrefix.isEmpty ? child.lastPathComponent : relativePrefix + "/" + child.lastPathComponent
            switch try fileType(at: child) {
            case .typeRegular:
                files.append((child, relative))
            case .typeDirectory:
                files.append(contentsOf: try regularFilesRecursively(in: child, relativePrefix: relative))
            case .typeSymbolicLink:
                throw Primer3DesignError.invalidRequest("native MSA source contains a symbolic link: \(child.path)")
            default:
                throw Primer3DesignError.invalidRequest("native MSA source contains a special file: \(child.path)")
            }
        }
        return files
    }

    private static func fileType(at url: URL) throws -> FileAttributeType {
        guard let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
            throw Primer3DesignError.invalidRequest("cannot determine source file type: \(url.path)")
        }
        return type
    }

    private static func snapshotFormat(for relativePath: String) -> String {
        switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
        case "fasta", "fa", "fna", "fas": "fasta"
        case "json": "json"
        case "sqlite", "db": "sqlite"
        case "bed": "bed"
        case "text", "txt": "text"
        case let ext where !ext.isEmpty: ext
        default: "binary"
        }
    }
}

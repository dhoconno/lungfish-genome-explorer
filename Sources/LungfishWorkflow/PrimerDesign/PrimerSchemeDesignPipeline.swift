import Darwin
import Foundation
import LungfishCore
import LungfishIO

public struct PrimerSchemeDesignRequest: Sendable {
    public let analysisID: UUID
    public let runID: UUID
    public let resultID: UUID
    public let inputURLs: [URL]
    public let destinationURL: URL
    public let options: PrimerSchemeDesignOptions
    public let invocation: PrimerAnalysisWrapperInvocation
    public let expectedInputChecksums: [URL: String]
    public let executableURL: URL?
    public let inputIDs: [URL: UUID]

    public init(
        analysisID: UUID = UUID(), runID: UUID = UUID(), resultID: UUID = UUID(),
        inputURLs: [URL], destinationURL: URL, options: PrimerSchemeDesignOptions,
        invocation: PrimerAnalysisWrapperInvocation,
        expectedInputChecksums: [URL: String], executableURL: URL? = nil,
        inputIDs: [URL: UUID] = [:]
    ) {
        self.analysisID = analysisID
        self.runID = runID
        self.resultID = resultID
        self.inputURLs = inputURLs
        self.destinationURL = destinationURL
        self.options = options
        self.invocation = invocation
        self.expectedInputChecksums = expectedInputChecksums
        self.executableURL = executableURL
        var resolvedIDs = inputIDs
        for input in inputURLs where resolvedIDs[input] == nil { resolvedIDs[input] = UUID() }
        self.inputIDs = resolvedIDs
    }
}

public struct PrimerSchemeDesignPipeline: Sendable {
    public static let adapterVersion = "1.0.0"
    public static let resultRelativePath = PrimerSchemeResultsDocument.storedRelativePath
    public typealias Progress = @Sendable (Double, String) -> Void

    typealias RuntimePreparer = @Sendable (PrimerSchemeEngine, Progress?) async throws
        -> PrimerDesignManagedRuntime.Lease

    private let runner: PrimerSchemeAdapterRunner
    private let writer: PrimerAnalysisBundleWriter
    private let runtimePreparer: RuntimePreparer?
    private let adapterSourceProvider: @Sendable () throws -> URL

    public init() {
        runner = PrimerSchemeAdapterExecution.execute
        writer = PrimerAnalysisBundleWriter()
        runtimePreparer = { engine, progress in
            try await PrimerDesignManagedRuntime.prepareAndAcquire(
                toolID: engine.rawValue, progress: progress)
        }
        adapterSourceProvider = PrimerSchemeAdapterResources.bundledV1URL
    }

    init(
        runner: @escaping PrimerSchemeAdapterRunner,
        writer: PrimerAnalysisBundleWriter = PrimerAnalysisBundleWriter(),
        runtimePreparer: RuntimePreparer?,
        adapterSourceProvider: @escaping @Sendable () throws -> URL
    ) {
        self.runner = runner
        self.writer = writer
        self.runtimePreparer = runtimePreparer
        self.adapterSourceProvider = adapterSourceProvider
    }

    public func run(
        request: PrimerSchemeDesignRequest, progress: Progress? = nil
    ) async throws -> URL {
        try await runOffMain(request: request, progress: progress)
    }

    private func runOffMain(
        request: PrimerSchemeDesignRequest, progress: Progress?
    ) async throws -> URL {
        try preflight(request)
        try request.options.validate()
        try Task.checkCancellation()

        let lease: PrimerDesignManagedRuntime.Lease?
        if request.executableURL == nil, let runtimePreparer {
            lease = try await runtimePreparer(request.options.engine, progress)
        } else {
            lease = nil
        }
        defer { lease?.release() }
        try Task.checkCancellation()

        let python = try executable(request: request, lease: lease)
        let parent = request.destinationURL.deletingLastPathComponent()
        let failure = parent.appendingPathComponent(
            ".primer-scheme-failure-\(request.runID.uuidString)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: failure.path) else {
            throw PrimerSchemeDesignError.invalidRequest(
                "Existing failure evidence must be moved or removed before reusing this run ID: \(failure.path)")
        }
        let scratch = parent.appendingPathComponent(
            ".primer-scheme-run-\(request.runID.uuidString)-\(UUID().uuidString)", isDirectory: true)
        guard Darwin.mkdir(scratch.path, mode_t(0o700)) == 0 else {
            throw PrimerSchemeDesignError.invalidRequest("Could not reserve private run storage.")
        }
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: scratch) } }

        do {
            progress?(0.06, "Snapshotting primer-scheme inputs…")
            let prepared = try PrimerSchemeInputPreparation.prepare(
                inputURLs: request.inputURLs, inputIDs: request.inputIDs,
                expectedInputChecksums: request.expectedInputChecksums, scratchRoot: scratch)
            let auxiliary = try PrimerSchemeInputPreparation.prepareAuxiliaryInputs(
                options: request.options, scratchRoot: scratch)
            let adapter = scratch.appendingPathComponent("adapter", isDirectory: true)
            try PrimerSchemeAdapterResources.copyV1(from: try adapterSourceProvider(), to: adapter)
            let adapterDigest = try PrimerSchemeAdapterResources.directorySHA256(adapter)
            let output = scratch.appendingPathComponent("adapter-output", isDirectory: true)
            let requestURL = scratch.appendingPathComponent("request.json")
            let wireRequest = PrimerSchemeAdapterRequest(
                engine: request.options.engine, engineVersion: engineVersion(request.options.engine),
                analysisID: request.analysisID, runID: request.runID, resultID: request.resultID,
                mode: request.options.mode,
                grouping: request.options.grouping == .combined ? .combined : .perInput,
                inputs: prepared.map {
                    .init(id: $0.id, label: $0.label, path: $0.adapterInputURL.path)
                },
                outputDirectory: output.path, options: auxiliary.options.adapterOptions)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(wireRequest).write(to: requestURL, options: .withoutOverwriting)

            let environment = controlledEnvironment(python: python, scratch: scratch)
            let environmentURL = scratch.appendingPathComponent("adapter-environment.json")
            try encoder.encode(environment).write(to: environmentURL, options: .withoutOverwriting)
            let command = PrimerSchemeAdapterCommand(
                executableURL: python,
                arguments: [adapter.appendingPathComponent("run.py").path,
                            "--request", requestURL.path],
                request: wireRequest, requestURL: requestURL,
                adapterDirectoryURL: adapter, outputDirectoryURL: output,
                workingDirectoryURL: scratch, environment: environment)

            progress?(0.12, "Running \(request.options.engine.rawValue) through the LGE adapter…")
            let execution: PrimerSchemeAdapterExecution
            do {
                execution = try await runner(command)
            } catch {
                try retainFailure(
                    scratch: scratch, at: failure, request: request, command: command,
                    adapterDigest: adapterDigest, execution: nil, cause: error.localizedDescription)
                retained = true
                if error is CancellationError { throw CancellationError() }
                throw PrimerSchemeDesignError.executionFailed(-1, error.localizedDescription, failure.path)
            }
            try write(execution.stdout, to: scratch.appendingPathComponent("adapter-process-stdout.txt"))
            try write(execution.stderr, to: scratch.appendingPathComponent("adapter-process-stderr.txt"))
            guard execution.exitStatus == 0 else {
                try retainFailure(
                    scratch: scratch, at: failure, request: request, command: command,
                    adapterDigest: adapterDigest, execution: execution,
                    cause: failureMessage(execution.stderr))
                retained = true
                throw PrimerSchemeDesignError.executionFailed(
                    execution.exitStatus, failureMessage(execution.stderr), failure.path)
            }
            do {
                try Task.checkCancellation()
                let verified = try PrimerSchemeAdapterResultLoader.loadVerified(
                    outputDirectory: output, command: command, options: auxiliary.options)
                progress?(0.86, "Normalizing primer-scheme results…")
                let normalized = try canonicalize(
                    verified: verified, prepared: prepared, scratch: scratch,
                    options: auxiliary.options,
                    executedToStoredPaths: auxiliary.executedToStoredPaths)
                let artifacts = try publicationArtifacts(
                    scratch: scratch, adapterOutput: output, prepared: prepared,
                    auxiliaryArtifacts: auxiliary.artifacts,
                    canonicalMapPaths: normalized.mapPaths)
                let allArtifactPaths = artifacts.map(\.relativePath)
                let inputManifest = prepared.enumerated().map { index, input in
                    PrimerAnalysisInput(
                        id: input.id, label: input.label,
                        artifactPaths: input.sourceArtifactPaths
                            + (index == 0 ? auxiliary.artifacts.map(\.relativePath) : []))
                }
                let resultManifest = normalized.document.results.map {
                    PrimerAnalysisResult(
                        id: $0.id, label: "\(request.options.engine.rawValue) \(request.options.mode.rawValue)",
                        inputIDs: $0.inputIDs, artifactPaths: allArtifactPaths.filter {
                            $0 == Self.resultRelativePath
                                || $0.hasPrefix("results/binding-projections/")
                                || $0.hasPrefix("native/adapter-output/")
                        })
                }
                var pathMap = Dictionary(uniqueKeysWithValues: prepared.map {
                    ($0.adapterInputURL.path, $0.adapterInputRelativePath)
                })
                pathMap.merge(auxiliary.executedToStoredPaths) { _, new in new }
                let augmented = PrimerAnalysisWrapperInvocation(
                    argv: request.invocation.argv, callerVersion: request.invocation.callerVersion,
                    explicitOptions: request.invocation.explicitOptions.merging([
                        "adapterVersion": .string(Self.adapterVersion),
                        "adapterSHA256": .string(adapterDigest),
                        "adapterArgv": .array(execution.argv.map(ParameterValue.string)),
                        "adapterEnvironment": .dictionary(environment.mapValues(ParameterValue.string)),
                        "adapterResolvedOptions": .dictionary(
                            verified.document.resolvedOptions.mapValues(\.parameterValue)),
                        "executedToStoredInputPaths": .dictionary(pathMap.mapValues(ParameterValue.string)),
                        "explicitPythonOverride": request.executableURL.map {
                            .string($0.path)
                        } ?? .null,
                    ]) { _, new in new },
                    runtimeIdentity: execution.runtime)
                let bundle = try writer.write(.init(
                    analysisID: request.analysisID, runID: request.runID,
                    grouping: request.options.grouping, inputs: inputManifest,
                    results: resultManifest, artifacts: artifacts,
                    destinationURL: request.destinationURL, invocation: augmented))
                progress?(1, "Primer analysis published")
                return bundle.url
            } catch {
                try retainFailure(
                    scratch: scratch, at: failure, request: request, command: command,
                    adapterDigest: adapterDigest, execution: execution,
                    cause: error.localizedDescription)
                retained = true
                if error is CancellationError { throw CancellationError() }
                if let designError = error as? PrimerSchemeDesignError,
                   case .contractViolation(let reason, _) = designError {
                    throw PrimerSchemeDesignError.contractViolation(
                        reason, diagnostics: failure.path)
                }
                throw PrimerSchemeDesignError.contractViolation(
                    error.localizedDescription, diagnostics: failure.path)
            }
        } catch {
            throw error
        }
    }

    private func preflight(_ request: PrimerSchemeDesignRequest) throws {
        guard !request.inputURLs.isEmpty,
              request.destinationURL.isFileURL,
              request.destinationURL.pathExtension == "lungfishprimeranalysis",
              request.invocation.argv.isEmpty == false,
              Set(request.inputURLs).count == request.inputURLs.count,
              Set(request.inputIDs.values).count == request.inputURLs.count,
              request.inputURLs.allSatisfy({ request.inputIDs[$0] != nil }) else {
            throw PrimerSchemeDesignError.invalidRequest(
                "Distinct inputs, IDs, exact invocation argv, and a new .lungfishprimeranalysis destination are required.")
        }
        let parent = request.destinationURL.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              !FileManager.default.fileExists(atPath: request.destinationURL.path) else {
            throw PrimerSchemeDesignError.invalidRequest(
                "The destination parent must be an existing non-symlink directory and the destination must not exist.")
        }
    }

    private func executable(
        request: PrimerSchemeDesignRequest, lease: PrimerDesignManagedRuntime.Lease?
    ) throws -> URL {
        let executable = request.executableURL
            ?? lease!.environmentURL.appendingPathComponent("bin/python")
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PrimerSchemeDesignError.invalidRequest(
                "The Python override must be an absolute executable file.")
        }
        return executable
    }

    private func controlledEnvironment(python: URL, scratch: URL) -> [String: String] {
        let root = python.deletingLastPathComponent().deletingLastPathComponent()
        let cache = scratch.appendingPathComponent("wrapper-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = [
            "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin",
            "CONDA_PREFIX": root.path,
            "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": "", "PYTHONHOME": "",
            "MPLBACKEND": "Agg", "XDG_CACHE_HOME": cache.path,
            "TMPDIR": cache.path,
        ]
        let mafft = root.appendingPathComponent("libexec/mafft", isDirectory: true)
        if FileManager.default.fileExists(atPath: mafft.path) { values["MAFFT_BINARIES"] = mafft.path }
        return values
    }

    private struct Canonicalized {
        let document: PrimerSchemeResultsDocument
        let mapPaths: [String]
    }

    private func canonicalize(
        verified: PrimerSchemeVerifiedAdapterOutput,
        prepared: [PrimerSchemePreparedInput], scratch: URL,
        options: PrimerSchemeDesignOptions,
        executedToStoredPaths: [String: String]
    ) throws -> Canonicalized {
        let inputByID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0) })
        var projections: [String: PrimerBindingProjection] = [:]
        var results = verified.document.results
        var mapPaths: [String] = []
        for resultIndex in results.indices {
            for targetIndex in results[resultIndex].targets.indices {
                var target = results[resultIndex].targets[targetIndex]
                guard let source = inputByID[target.sourceInputID],
                      var projection = verified.projections[target.bindingProjectionPath] else {
                    throw PrimerSchemeDesignError.contractViolation(
                        "Canonicalization could not resolve a target input or projection.")
                }
                target.referencePath = "native/adapter-output/" + target.referencePath
                let mapPath = "results/binding-projections/\(target.id.uuidString.lowercased()).json"
                target.bindingProjectionPath = mapPath
                projection.sourcePath = source.adapterInputRelativePath
                projection.generatedReferencePath = target.referencePath
                let mapURL = scratch.appendingPathComponent(mapPath)
                try FileManager.default.createDirectory(
                    at: mapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(projection).write(to: mapURL, options: .withoutOverwriting)
                projections[mapPath] = projection
                mapPaths.append(mapPath)
                results[resultIndex].targets[targetIndex] = target
            }
        }
        let document = PrimerSchemeResultsDocument(
            analysisID: verified.document.analysisID, runID: verified.document.runID,
            resultID: verified.document.resultID, engine: verified.document.engine,
            engineVersion: verified.document.engineVersion,
            adapterVersion: verified.document.adapterVersion, mode: verified.document.mode,
            resolvedOptions: rebaseJSON(
                verified.document.resolvedOptions, mappings: executedToStoredPaths),
            results: results,
            artifacts: verified.document.artifacts.map {
                .init(path: "native/adapter-output/" + $0.path, sha256: $0.sha256,
                      byteSize: $0.byteSize, kind: $0.kind)
            },
            provenancePath: "native/adapter-output/" + verified.document.provenancePath)
        try document.validateStructure(
            knownInputIDs: Set(prepared.map(\.id)), options: options, projections: projections)
        let documentURL = scratch.appendingPathComponent(Self.resultRelativePath)
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: documentURL, options: .withoutOverwriting)
        return .init(document: document, mapPaths: mapPaths)
    }

    private func publicationArtifacts(
        scratch: URL, adapterOutput: URL, prepared: [PrimerSchemePreparedInput],
        auxiliaryArtifacts: [PrimerAnalysisSourceArtifact],
        canonicalMapPaths: [String]
    ) throws -> [PrimerAnalysisSourceArtifact] {
        var artifacts = prepared.flatMap(\.artifacts) + auxiliaryArtifacts
        let adapter = scratch.appendingPathComponent("adapter", isDirectory: true)
        artifacts += try PrimerSchemeInputPreparation.regularFiles(in: adapter).map {
            .init(sourceURL: $0,
                  relativePath: "native/adapter/" + PrimerSchemeInputPreparation.relative($0, to: adapter),
                  role: "nativeRuntime", format: PrimerSchemeInputPreparation.format(for: $0))
        }
        for (sourceName, storedName, role) in [
            ("request.json", "native/request.json", "configuration"),
            ("adapter-environment.json", "native/adapter-environment.json", "configuration"),
            ("adapter-process-stdout.txt", "native/adapter-process-stdout.txt", "nativeLog"),
            ("adapter-process-stderr.txt", "native/adapter-process-stderr.txt", "nativeLog"),
        ] {
            artifacts.append(.init(sourceURL: scratch.appendingPathComponent(sourceName),
                                   relativePath: storedName, role: role,
                                   format: storedName.hasSuffix(".json") ? "json" : "txt"))
        }
        artifacts += try PrimerSchemeInputPreparation.regularFiles(in: adapterOutput).map {
            .init(sourceURL: $0,
                  relativePath: "native/adapter-output/" + PrimerSchemeInputPreparation.relative($0, to: adapterOutput),
                  role: "nativeOutput", format: PrimerSchemeInputPreparation.format(for: $0))
        }
        artifacts.append(.init(sourceURL: scratch.appendingPathComponent(Self.resultRelativePath),
                               relativePath: Self.resultRelativePath,
                               role: "normalizedResult", format: "json"))
        artifacts += canonicalMapPaths.map {
            .init(sourceURL: scratch.appendingPathComponent($0), relativePath: $0,
                  role: "bindingProjection", format: "json")
        }
        return artifacts
    }

    private func rebaseJSON(
        _ values: [String: PrimerSchemeJSONValue], mappings: [String: String]
    ) -> [String: PrimerSchemeJSONValue] {
        func rebase(_ value: PrimerSchemeJSONValue) -> PrimerSchemeJSONValue {
            switch value {
            case .string(let string): return mappings[string].map(PrimerSchemeJSONValue.string) ?? value
            case .array(let values): return .array(values.map(rebase))
            case .object(let values): return .object(values.mapValues(rebase))
            default: return value
            }
        }
        return values.mapValues(rebase)
    }

    private struct FailureEvidence: Codable {
        struct File: Codable {
            let path: String
            let sha256: String
            let byteSize: UInt64
        }
        let schemaVersion: Int
        let status: String
        let cause: String
        let engine: PrimerSchemeEngine
        let engineVersion: String
        let adapterVersion: String
        let adapterSHA256: String
        let analysisID: String
        let runID: String
        let resultID: String
        let argv: [String]
        let durableReplayArgv: [String]
        let wrapperArgv: [String]
        let callerVersion: String
        let workingDirectory: String
        let pathMappings: [String: String]
        let environment: [String: String]
        let options: [String: PrimerSchemeJSONValue]
        let inputs: [PrimerSchemeAdapterInput]
        let startedAt: Date?
        let endedAt: Date?
        let wallTimeSeconds: Double?
        let exitStatus: Int32?
        let stdout: String?
        let stderr: String?
        let files: [File]
    }

    private func retainFailure(
        scratch: URL, at failure: URL, request: PrimerSchemeDesignRequest,
        command: PrimerSchemeAdapterCommand, adapterDigest: String,
        execution: PrimerSchemeAdapterExecution?, cause: String
    ) throws {
        let replayRequestURL = scratch.appendingPathComponent("replay-request.json")
        let replayRequest = PrimerSchemeAdapterRequest(
            engine: command.request.engine, engineVersion: command.request.engineVersion,
            analysisID: command.request.analysisID, runID: command.request.runID,
            resultID: command.request.resultID, mode: command.request.mode,
            grouping: command.request.grouping,
            inputs: command.request.inputs.map {
                .init(id: $0.id, label: $0.label,
                      path: $0.path.replacingOccurrences(
                        of: scratch.path + "/", with: failure.path + "/"))
            },
            outputDirectory: failure.appendingPathComponent("replay-output").path,
            options: rebaseFailureOptions(
                command.request.options, from: scratch.path + "/", to: failure.path + "/"))
        let replayEncoder = JSONEncoder()
        replayEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try replayEncoder.encode(replayRequest).write(to: replayRequestURL, options: .withoutOverwriting)
        let durableArgv = [command.executableURL.path,
                           failure.appendingPathComponent("adapter/run.py").path,
                           "--request", failure.appendingPathComponent("replay-request.json").path]
        let files = try PrimerSchemeInputPreparation.regularFiles(in: scratch).map {
            FailureEvidence.File(
                path: PrimerSchemeInputPreparation.relative($0, to: scratch),
                sha256: try ProvenanceFileHasher.sha256(of: $0),
                byteSize: try ProvenanceFileHasher.fileSize(of: $0))
        }
        let record = FailureEvidence(
            schemaVersion: 1, status: execution == nil && Task.isCancelled ? "cancelled" : "failed",
            cause: cause, engine: request.options.engine,
            engineVersion: engineVersion(request.options.engine),
            adapterVersion: Self.adapterVersion, adapterSHA256: adapterDigest,
            analysisID: request.analysisID.uuidString.lowercased(),
            runID: request.runID.uuidString.lowercased(), resultID: request.resultID.uuidString.lowercased(),
            argv: execution?.argv ?? [command.executableURL.path] + command.arguments,
            durableReplayArgv: durableArgv, wrapperArgv: request.invocation.argv,
            callerVersion: request.invocation.callerVersion,
            workingDirectory: command.workingDirectoryURL.path,
            pathMappings: [scratch.path: failure.path],
            environment: command.environment, options: command.request.options,
            inputs: command.request.inputs, startedAt: execution?.startedAt,
            endedAt: execution?.endedAt,
            wallTimeSeconds: execution.map { max(0, $0.endedAt.timeIntervalSince($0.startedAt)) },
            exitStatus: execution?.exitStatus, stdout: execution?.stdout, stderr: execution?.stderr,
            files: files)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(
            to: scratch.appendingPathComponent("wrapper-failure-provenance-v1.json"),
            options: .withoutOverwriting)
        guard rename(scratch.path, failure.path) == 0 else {
            throw PrimerSchemeDesignError.executionFailed(
                execution?.exitStatus ?? -1,
                "Native failure occurred, but private diagnostics could not be retained.", nil)
        }
    }

    private func rebaseFailureOptions(
        _ values: [String: PrimerSchemeJSONValue], from: String, to: String
    ) -> [String: PrimerSchemeJSONValue] {
        func replace(_ value: PrimerSchemeJSONValue) -> PrimerSchemeJSONValue {
            switch value {
            case .string(let string): return .string(
                string.replacingOccurrences(of: from, with: to))
            case .array(let values): return .array(values.map(replace))
            case .object(let values): return .object(values.mapValues(replace))
            default: return value
            }
        }
        return values.mapValues(replace)
    }

    private func engineVersion(_ engine: PrimerSchemeEngine) -> String {
        engine == .olivar ? "1.3.3" : "1.3.2"
    }

    private func failureMessage(_ stderr: String) -> String {
        guard let data = stderr.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            let value = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "native adapter failed without a diagnostic message" : value
        }
        return message
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .withoutOverwriting)
    }
}

import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum PrimalScheme3TerminalGapPolicy: String, Codable, CaseIterable, Sendable {
    case legacy
    case observedOnly = "observed-only"

    public var discoveryBackend: String {
        self == .legacy ? "rust-legacy" : "python-observed-only"
    }
}

public enum PrimalScheme3PanelMode: String, Codable, CaseIterable, Sendable {
    case equal, entropy
}

public struct PrimalScheme3DesignOptions: Codable, Equatable, Sendable {
    public static var defaultCoreCount: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)) }
    public var ampliconSizeMinimum: Int { (100...2000).contains(ampliconSize) ? Int(Double(ampliconSize) * 0.9) : 0 }
    public var ampliconSizeMaximum: Int { (100...2000).contains(ampliconSize) ? Int(Double(ampliconSize) * 1.1) : 0 }
    public let dimerScore: Double
    public let useMatchDB: Bool
    public let backtrack: Bool
    public let ignoreN: Bool
    public let panelMode: PrimalScheme3PanelMode
    public let maxAmplicons: Int?
    public let maxAmpliconsPerMSA: Int?
    public let ampliconSize: Int
    public let poolCount: Int
    public let minOverlap: Int
    public let minimumBaseFrequency: Double
    public let highGC: Bool
    public let coreCount: Int
    public let terminalGapPolicy: PrimalScheme3TerminalGapPolicy
    public init(ampliconSize: Int, poolCount: Int, minOverlap: Int = 10,
                minimumBaseFrequency: Double = 0, highGC: Bool = false, coreCount: Int = PrimalScheme3DesignOptions.defaultCoreCount,
                terminalGapPolicy: PrimalScheme3TerminalGapPolicy = .observedOnly,
                dimerScore: Double = -26, useMatchDB: Bool = true,
                backtrack: Bool = false, ignoreN: Bool = false,
                panelMode: PrimalScheme3PanelMode = .equal,
                maxAmplicons: Int? = nil, maxAmpliconsPerMSA: Int? = nil) {
        self.dimerScore = dimerScore
        self.useMatchDB = useMatchDB
        self.backtrack = backtrack
        self.ignoreN = ignoreN
        self.panelMode = panelMode
        self.maxAmplicons = maxAmplicons
        self.maxAmpliconsPerMSA = maxAmpliconsPerMSA
        self.ampliconSize = ampliconSize
        self.poolCount = poolCount
        self.minOverlap = minOverlap
        self.minimumBaseFrequency = minimumBaseFrequency
        self.highGC = highGC
        self.coreCount = coreCount
        self.terminalGapPolicy = terminalGapPolicy
    }

    public var provenanceOptions: [String: ParameterValue] {
        ["ampliconSize": .integer(ampliconSize), "ampliconSizeMinimum": .integer(ampliconSizeMinimum),
         "ampliconSizeMaximum": .integer(ampliconSizeMaximum), "poolCount": .integer(poolCount),
         "minOverlap": .integer(minOverlap), "minimumBaseFrequency": .number(minimumBaseFrequency),
         "highGC": .boolean(highGC), "coreCount": .integer(coreCount),
         "terminalGapPolicy": .string(terminalGapPolicy.rawValue), "dimerScore": .number(dimerScore),
         "useMatchDB": .boolean(useMatchDB), "backtrack": .boolean(backtrack), "ignoreN": .boolean(ignoreN),
         "panelMode": .string(panelMode.rawValue),
         "maxAmplicons": maxAmplicons.map(ParameterValue.integer) ?? .string("unlimited"),
         "maxAmpliconsPerMSA": maxAmpliconsPerMSA.map(ParameterValue.integer) ?? .string("unlimited")]
    }
}

public struct PrimalScheme3DesignRequest: Sendable {
    public let inputURLs: [URL]
    public let destinationURL: URL
    public let options: PrimalScheme3DesignOptions
    public let grouping: PrimerAnalysisGrouping
    public let invocation: PrimerAnalysisWrapperInvocation
    public let executableURL: URL?
    public let expectedInputChecksums: [URL: String]

    public init(inputURLs: [URL], destinationURL: URL, options: PrimalScheme3DesignOptions,
                grouping: PrimerAnalysisGrouping, invocation: PrimerAnalysisWrapperInvocation,
                executableURL: URL? = nil, expectedInputChecksums: [URL: String] = [:]) {
        self.inputURLs = inputURLs
        self.destinationURL = destinationURL
        self.options = options
        self.grouping = grouping
        self.invocation = invocation
        self.executableURL = executableURL
        self.expectedInputChecksums = expectedInputChecksums
    }
}

public enum PrimalScheme3DesignError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case executionFailed(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "PrimalScheme3-LGE (custom fork): \(reason)"
        case .executionFailed(let code, let detail): return "PrimalScheme3-LGE custom fork exited with status \(code): \(detail)"
        }
    }
}

struct PrimalScheme3Command: Sendable {
    let executableOverride: URL?
    let arguments: [String]
    let workingDirectory: URL
}

struct PrimalScheme3Execution: Sendable {
    let argv: [String]
    let stdout: String
    let stderr: String
    let exitStatus: Int32
    let version: String
    let runtime: ProvenanceRuntimeIdentity
    let startedAt: Date
    let endedAt: Date
    var executableSHA256: String? = nil
    var runtimeEvidence: [String: Data] = [:]
}

public struct PrimalScheme3DesignPipeline: Sendable {
    public static let toolVersion = "3.3.0+lge.1"
    public static let toolDisplayName = "PrimalScheme3-LGE (custom fork)"
    public static let sourceRepository = "https://github.com/dhoconno/primalscheme3-lge"
    typealias Runner = @Sendable (PrimalScheme3Command) async throws -> PrimalScheme3Execution
    private let runner: Runner
    private let writer: PrimerAnalysisBundleWriter

    public init() {
        runner = Self.execute
        writer = PrimerAnalysisBundleWriter()
    }

    init(runner: @escaping Runner, writer: PrimerAnalysisBundleWriter = PrimerAnalysisBundleWriter()) {
        self.runner = runner
        self.writer = writer
    }

    public func run(request: PrimalScheme3DesignRequest,
                    progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) {
            try await runOffMain(request: request, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    static func arguments(inputs: [URL], output: URL, grouping: PrimerAnalysisGrouping,
                          options: PrimalScheme3DesignOptions) throws -> [String] {
        guard !inputs.isEmpty, (100...2000).contains(options.ampliconSize), options.poolCount > 0,
              options.minOverlap >= 0, options.minimumBaseFrequency.isFinite,
              (0...1).contains(options.minimumBaseFrequency), options.coreCount > 0,
              grouping != .combined || options.minOverlap == 10,
              grouping == .combined || inputs.count == 1 else {
            throw PrimalScheme3DesignError.invalidRequest("Choose an amplicon size from 100 to 2000, positive pool/core counts, nonnegative overlap, base frequency from 0 to 1, and explicit alignment inputs. Custom overlap applies only to independent schemes.")
        }
        guard options.dimerScore.isFinite,
              options.maxAmplicons.map({ $0 > 0 }) ?? true,
              options.maxAmpliconsPerMSA.map({ $0 > 0 }) ?? true,
              grouping != .combined || (!options.backtrack && !options.ignoreN),
              grouping != .independent || (options.panelMode == .equal && options.maxAmplicons == nil && options.maxAmpliconsPerMSA == nil) else {
            throw PrimalScheme3DesignError.invalidRequest("Dimer score must be finite and amplicon limits positive. Backtracking and unknown-base omission apply only to independent schemes; panel modes and limits apply only to combined panels.")
        }
        var args = [grouping == .combined ? "panel-create" : "scheme-create"]
        // Stock panel-create defaults to region-only, which requires a BED file.
        // This interface has whole-alignment inputs, so select equal explicitly.
        if grouping == .combined { args += ["--mode", options.panelMode.rawValue] }
        for input in inputs { args += ["--msa", input.path] }
        args += ["--output", output.path, "--amplicon-size", String(options.ampliconSize),
                 "--n-pools", String(options.poolCount),
                 "--min-base-freq", String(options.minimumBaseFrequency), "--mapping", "first",
                 options.highGC ? "--high-gc" : "--no-high-gc", "--ncores", String(options.coreCount),
                 "--terminal-gap-policy", options.terminalGapPolicy.rawValue]
        args += ["--dimer-score", String(options.dimerScore), options.useMatchDB ? "--use-matchdb" : "--no-use-matchdb", "--offline-plots"]
        if grouping == .independent {
            args += ["--min-overlap", String(options.minOverlap), options.backtrack ? "--backtrack" : "--no-backtrack",
                     options.ignoreN ? "--ignore-n" : "--no-ignore-n"]
        } else {
            if let count = options.maxAmplicons { args += ["--max-amplicons", String(count)] }
            if let count = options.maxAmpliconsPerMSA { args += ["--max-amplicons-msa", String(count)] }
        }
        return args
    }

    private struct Input: Sendable {
        let id: UUID
        let originalURL: URL
        let snapshotURL: URL
        let alignedURL: URL
        let paths: [String]
        let fingerprint: String
        let referenceName: String
        let rowMappingPath: String
    }

    private func runOffMain(request: PrimalScheme3DesignRequest,
                            progress: (@Sendable (Double, String) -> Void)?) async throws -> URL {
        try Task.checkCancellation()
        guard !request.inputURLs.isEmpty, Set(request.inputURLs).count == request.inputURLs.count else {
            throw PrimalScheme3DesignError.invalidRequest("Select distinct alignment inputs.")
        }
        guard request.destinationURL.pathExtension.lowercased() == "lungfishprimeranalysis" else {
            throw PrimalScheme3DesignError.invalidRequest("The destination must be a .lungfishprimeranalysis bundle.")
        }
        let destination = try Self.physicalParent(request.destinationURL)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw PrimalScheme3DesignError.invalidRequest("The destination already exists.")
        }
        _ = try Self.arguments(inputs: [request.inputURLs[0]], output: destination,
                               grouping: request.grouping, options: request.options)
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(
            ".primalscheme3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var artifacts: [PrimerAnalysisSourceArtifact] = []
        var inputs: [Input] = []
        for url in request.inputURLs {
            try Task.checkCancellation()
            guard let expected = request.expectedInputChecksums[url], expected.count == 64,
                  expected == (try Primer3InputLoader.fingerprint(url)) else {
                throw PrimalScheme3DesignError.invalidRequest("An input changed after inspection or has no inspection checksum: \(url.lastPathComponent)")
            }
            let id = UUID()
            let prefix = "source-inputs/\(id.uuidString)"
            let native = url.pathExtension.lowercased() == MultipleSequenceAlignmentBundle.directoryExtension
            let snapshot = scratch.appendingPathComponent(prefix).appendingPathComponent(
                native ? "source.lungfishmsa" : "source.fasta")
            try Self.copySource(url, to: snapshot)
            guard try Primer3InputLoader.fingerprint(snapshot) == expected else {
                throw PrimalScheme3DesignError.invalidRequest("An input changed while its snapshot was being captured.")
            }
            let sourceAligned = native ? snapshot.appendingPathComponent("alignment/primary.aligned.fasta") : snapshot
            let rows = try Primer3InputLoader.readAlignedRows(at: sourceAligned)
            if native {
                try Primer3InputLoader.validateAlignedRows(rows, bundle: MultipleSequenceAlignmentBundle.load(from: snapshot))
            }
            let lengths = Set(rows.map { $0.sequence.count })
            guard !rows.isEmpty, lengths.count == 1, lengths.first != 0,
                  Set(rows.map(\.title)).count == rows.count,
                  rows.allSatisfy({ $0.sequence.uppercased().allSatisfy { "ACGTRYSWKMBDHVN-".contains($0) } }) else {
                throw PrimalScheme3DesignError.invalidRequest("Each input must contain aligned, nonempty DNA rows with distinct FASTA identifiers. No alignment or record selection is inferred.")
            }
            let files = try Self.regularFiles(in: snapshot)
            let aligned = scratch.appendingPathComponent("inputs/\(id.uuidString).fasta")
            try FileManager.default.createDirectory(at: aligned.deletingLastPathComponent(), withIntermediateDirectories: true)
            let normalizedNames = rows.indices.map { "input_\(id.uuidString.replacingOccurrences(of: "-", with: ""))_row_\($0)" }
            let consumedFASTA = rows.enumerated().map { index, row in
                ">\(normalizedNames[index])\n\(row.sequence)\n"
            }.joined()
            try Data(consumedFASTA.utf8).write(to: aligned, options: .withoutOverwriting)
            let mappingPath = "inputs/\(id.uuidString)-row-map.json"
            let mappingURL = scratch.appendingPathComponent(mappingPath)
            let mapping: [String: Any] = ["schemaVersion": 1, "inputID": id.uuidString,
                "transformation": "FASTA headers replaced; sequence symbols and row order preserved",
                "rows": rows.enumerated().map { index, row in
                    ["rowIndex": index, "originalHeader": row.title, "normalizedHeader": normalizedNames[index]] as [String: Any]
                }]
            try JSONSerialization.data(withJSONObject: mapping, options: [.prettyPrinted, .sortedKeys])
                .write(to: mappingURL, options: .withoutOverwriting)
            let paths = files.map { Self.relative($0, to: scratch) } + [Self.relative(aligned, to: scratch), mappingPath]
            for file in files {
                artifacts.append(.init(sourceURL: file, relativePath: Self.relative(file, to: scratch),
                                       role: "input", format: file.pathExtension.isEmpty ? "binary" : file.pathExtension))
            }
            artifacts.append(.init(sourceURL: aligned, relativePath: Self.relative(aligned, to: scratch), role: "input", format: "fasta"))
            artifacts.append(.init(sourceURL: mappingURL, relativePath: mappingPath, role: "input", format: "json"))
            inputs.append(Input(id: id, originalURL: url, snapshotURL: snapshot, alignedURL: aligned,
                                paths: paths, fingerprint: expected, referenceName: normalizedNames[0],
                                rowMappingPath: mappingPath))
        }
        let analysisID = UUID(), runID = UUID()
        let groups = request.grouping == .combined ? [inputs] : inputs.map { [$0] }
        var results: [PrimerAnalysisResult] = []
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            progress?(Double(index) / Double(groups.count), "Running PrimalScheme3-LGE custom fork (\(index + 1)/\(groups.count))")
            let resultID = UUID()
            let output = scratch.appendingPathComponent("native/\(resultID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let args = try Self.arguments(inputs: group.map(\.alignedURL), output: output,
                                          grouping: request.grouping, options: request.options)
            let executed = try await runner(.init(executableOverride: request.executableURL,
                                                  arguments: args, workingDirectory: scratch))
            try Task.checkCancellation()
            guard executed.exitStatus == 0 else {
                throw PrimalScheme3DesignError.executionFailed(executed.exitStatus, executed.stderr)
            }
            guard executed.version == Self.toolVersion, !executed.argv.isEmpty else {
                throw PrimalScheme3DesignError.invalidRequest("The executed tool did not report the verified PrimalScheme3-LGE custom fork identity.")
            }
            let configURL = output.appendingPathComponent("config.json")
            let configData = try Data(contentsOf: configURL)
            guard let configuration = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
                throw PrimalScheme3DesignError.invalidRequest("Native configuration is missing or malformed.")
            }
            guard configuration["terminal_gap_policy"] as? String == request.options.terminalGapPolicy.rawValue,
                  configuration["discovery_backend"] as? String == request.options.terminalGapPolicy.discoveryBackend else {
                throw PrimalScheme3DesignError.invalidRequest("The custom fork's native policy or discovery backend does not match the requested policy.")
            }
            guard let effectiveWorkers = configuration["discovery_core_count"] as? Int,
                  (1...request.options.coreCount).contains(effectiveWorkers) else {
                throw PrimalScheme3DesignError.invalidRequest("The custom fork did not report a valid effective discovery worker count.")
            }
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("primer.bed").path),
                  FileManager.default.fileExists(atPath: output.appendingPathComponent("reference.fasta").path) else {
                throw PrimalScheme3DesignError.invalidRequest("Native primer.bed or reference.fasta output is missing.")
            }
            let files = try Self.regularFiles(in: output)
            var resultPaths: [String] = []
            let replayArgv = executed.argv.map {
                $0.replacingOccurrences(of: scratch.path + "/", with: destination.path + "/")
            }
            var builder = ProvenanceRunBuilder(workflowName: "lungfish.primalscheme3.design", workflowVersion: "1",
                                               toolName: Self.toolDisplayName, toolVersion: executed.version)
                .argv(executed.argv)
                .durableReplayArgv(replayArgv)
                .reproducibleCommand(replayArgv.map(shellEscape).joined(separator: " "))
                .runtime(executed.runtime)
                .options(explicit: request.options.provenanceOptions.merging(["grouping": .string(request.grouping.rawValue)]) { _, new in new },
                         defaults: [:], resolved: ["nativeConfiguration": Self.parameter(configuration),
                         "customFork": .boolean(true), "sourceRepository": .string(Self.sourceRepository),
                         "terminalGapPolicy": .string(request.options.terminalGapPolicy.rawValue),
                         "discoveryBackend": .string(request.options.terminalGapPolicy.discoveryBackend),
                         "effectiveCoreCount": .integer(effectiveWorkers),
                         "analysisID": .string(analysisID.uuidString), "runID": .string(runID.uuidString),
                         "resultID": .string(resultID.uuidString), "inputIDs": .array(group.map { .string($0.id.uuidString) }),
                         "panelMode": .string(request.grouping == .combined ? request.options.panelMode.rawValue : "not-applicable"),
                         "mapping": .string("first"),
                         "minOverlap": request.grouping == .combined ? .string("not-applicable") : .integer(request.options.minOverlap),
                         "executableSHA256": executed.executableSHA256.map(ParameterValue.string) ?? .string("injected-test-runner"),
                         "sourceInputs": .array(group.map { .dictionary([
                            "inputID": .string($0.id.uuidString), "sourcePath": .string($0.originalURL.path),
                            "consumedRelativePath": .string(Self.relative($0.alignedURL, to: scratch)),
                            "inspectionSHA256": .string($0.fingerprint),
                            "preprocessing": .string("FASTA-header-normalization-only; bases-and-row-order-preserved"),
                            "rowMappingRelativePath": .string($0.rowMappingPath),
                            "referenceName": .string($0.referenceName)
                         ]) })])
            for input in group {
                builder = try builder.consumedInputSnapshot(Self.descriptor(input.alignedURL,
                    path: destination.appendingPathComponent(Self.relative(input.alignedURL, to: scratch)).path,
                    role: .input, origin: input.alignedURL.path))
            }
            for file in files {
                let path = Self.relative(file, to: scratch)
                artifacts.append(.init(sourceURL: file, relativePath: path, role: "nativeOutput",
                                       format: file.pathExtension.isEmpty ? "binary" : file.pathExtension))
                resultPaths.append(path)
                builder = try builder.relocatedOutput(Self.descriptor(file, path: destination.appendingPathComponent(path).path,
                                                                      role: .output, origin: file.path))
            }
            let logs = scratch.appendingPathComponent("logs/\(resultID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            for (name, bytes) in executed.runtimeEvidence.sorted(by: { $0.key < $1.key }) {
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                    throw PrimalScheme3DesignError.invalidRequest("Invalid runtime evidence filename.")
                }
                let file = logs.appendingPathComponent(name)
                try bytes.write(to: file, options: .withoutOverwriting)
                let path = Self.relative(file, to: scratch)
                artifacts.append(.init(sourceURL: file, relativePath: path, role: "runtime", format: file.pathExtension))
                resultPaths.append(path)
                builder = try builder.relocatedOutput(Self.descriptor(file,
                    path: destination.appendingPathComponent(path).path, role: .output, origin: file.path))
            }
            for (name, contents) in [("stdout.txt", executed.stdout), ("stderr.txt", executed.stderr)] {
                let file = logs.appendingPathComponent(name)
                try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
                let path = Self.relative(file, to: scratch)
                artifacts.append(.init(sourceURL: file, relativePath: path, role: "log", format: "text"))
                resultPaths.append(path)
                builder = try builder.relocatedOutput(Self.descriptor(file, path: destination.appendingPathComponent(path).path,
                                                                      role: .output, origin: file.path))
            }
            let envelope = try builder.complete(exitStatus: 0, stderr: executed.stderr,
                                                startedAt: executed.startedAt, endedAt: executed.endedAt)
            let provenance = logs.appendingPathComponent("execution.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(envelope).write(to: provenance, options: .withoutOverwriting)
            let provenancePath = Self.relative(provenance, to: scratch)
            artifacts.append(.init(sourceURL: provenance, relativePath: provenancePath, role: "toolProvenance", format: "json"))
            resultPaths.append(provenancePath)
            // LGE derives the ordering worksheet; it is not an engine-native output.
            let orderStarted = Date()
            let bedURL = output.appendingPathComponent("primer.bed")
            let orderURL = output.appendingPathComponent(PrimalSchemeOrderSheet.filename)
            try PrimalSchemeOrderSheet.csv(fromBED: Data(contentsOf: bedURL))
                .write(to: orderURL, options: .withoutOverwriting)
            let orderPath = Self.relative(orderURL, to: scratch)
            let bedPath = Self.relative(bedURL, to: scratch)
            artifacts.append(.init(sourceURL: orderURL, relativePath: orderPath, role: "derived-order-sheet", format: "csv"))
            resultPaths.append(orderPath)
            var orderBuilder = ProvenanceRunBuilder(workflowName: "lungfish.primalscheme3.order-sheet", workflowVersion: "1",
                toolName: "Lungfish Primer Order Sheet", toolVersion: request.invocation.callerVersion)
                .argv(request.invocation.argv)
                .options(explicit: ["schemaVersion": .integer(PrimalSchemeOrderSheet.schemaVersion)], defaults: [:],
                    resolved: ["ordering": .string("numeric-pool-then-native-row"),
                               "sequenceOrientation": .string("native-5-prime-to-3-prime"),
                               "spreadsheetFormulaEscaping": .boolean(true),
                               "transform": .string("PrimalSchemeOrderSheet.csv(fromBED:), schema 1, applied to the checksummed stored primer.bed"),
                               "argvMeaning": .string("Exact host-process invocation; GUI launch argv alone does not replay the transformation.")])
                .runtime(request.invocation.runtimeIdentity)
            orderBuilder = try orderBuilder.consumedInputSnapshot(Self.descriptor(bedURL,
                path: destination.appendingPathComponent(bedPath).path, role: .input, origin: bedURL.path))
            orderBuilder = try orderBuilder.relocatedOutput(Self.descriptor(orderURL,
                path: destination.appendingPathComponent(orderPath).path, role: .output, origin: orderURL.path))
            let orderEnvelope = try orderBuilder.complete(exitStatus: 0, stderr: "", startedAt: orderStarted, endedAt: Date())
            let orderProvenanceURL = logs.appendingPathComponent("order-sheet.json")
            try encoder.encode(orderEnvelope).write(to: orderProvenanceURL, options: .withoutOverwriting)
            let orderProvenancePath = Self.relative(orderProvenanceURL, to: scratch)
            artifacts.append(.init(sourceURL: orderProvenanceURL, relativePath: orderProvenancePath, role: "derivedProvenance", format: "json"))
            resultPaths.append(orderProvenancePath)
            results.append(.init(id: resultID, label: request.grouping == .combined ? "Combined panel" : group[0].originalURL.deletingPathExtension().lastPathComponent,
                                 inputIDs: group.map(\.id), artifactPaths: resultPaths))
        }
        try Task.checkCancellation()
        let bundle = try writer.write(.init(analysisID: analysisID, runID: runID, grouping: request.grouping,
            inputs: inputs.map { .init(id: $0.id, label: $0.originalURL.lastPathComponent, artifactPaths: $0.paths) },
            results: results, artifacts: artifacts, destinationURL: destination, invocation: request.invocation))
        progress?(1, "Saved PrimalScheme3-LGE custom fork analysis")
        return bundle.url
    }

    private static func execute(_ command: PrimalScheme3Command) async throws -> PrimalScheme3Execution {
        let manager = CondaManager.shared
        let executable: URL
        let prefix: URL?
        if let override = command.executableOverride { executable = override; prefix = nil }
        else {
            executable = try await manager.toolPath(name: "primalscheme3", environment: "primalscheme3")
            prefix = await manager.environmentURL(named: "primalscheme3")
        }
        let environment = prefix.map { ["PATH": $0.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                                        "CONDA_PREFIX": $0.path, "PYTHONNOUSERSITE": "1",
                                        "PYTHONPATH": "", "PYTHONHOME": ""] }
        var runtimeEvidence: [String: Data] = [:]
        if let environment {
            runtimeEvidence["execution-environment.json"] = try JSONSerialization.data(
                withJSONObject: environment, options: [.prettyPrinted, .sortedKeys])
        }
        if let prefix {
            guard let spec = ManagedToolLock.bundled.packTool(packID: "pcr-primer-design", id: "primalscheme3")?.pythonRuntime else {
                throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime specification is missing.")
            }
            let receiptURL = ManagedPythonRuntimeReceipt.receiptURL(for: spec, environmentURL: prefix)
            let data = try Data(contentsOf: receiptURL)
            let receipt = try JSONDecoder().decode(ManagedPythonRuntimeReceipt.self, from: data)
            guard receipt.validates(spec: spec, environmentURL: prefix) else {
                throw PrimalScheme3DesignError.invalidRequest("The managed PrimalScheme3 runtime needs repair in the plugin manager.")
            }
            runtimeEvidence["managed-runtime.json"] = data
        }
        let executableHash = try ProvenanceFileHasher.sha256(of: executable)
        let native = NativeToolRunner()
        let version = try await native.runProcess(executableURL: executable, arguments: ["--version"],
                                                  workingDirectory: command.workingDirectory, environment: environment, timeout: 30)
        guard version.exitCode == 0, version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "PrimalScheme3-LGE version: \(Self.toolVersion)" else {
            throw PrimalScheme3DesignError.invalidRequest("This adapter requires the PrimalScheme3-LGE custom fork \(Self.toolVersion). Install or repair PCR Primer Design in the plugin manager; stock PrimalScheme3 is not interchangeable with this fork.")
        }
        runtimeEvidence["version-probe.json"] = try JSONSerialization.data(withJSONObject: [
            "argv": version.arguments, "stdout": version.stdout, "stderr": version.stderr, "exitStatus": version.exitCode
        ], options: [.prettyPrinted, .sortedKeys])
        try Task.checkCancellation()
        let start = Date()
        let result = try await native.runProcess(executableURL: executable, arguments: command.arguments,
            workingDirectory: command.workingDirectory, environment: environment, timeout: 86400, toolName: Self.toolDisplayName)
        guard try ProvenanceFileHasher.sha256(of: executable) == executableHash else {
            throw PrimalScheme3DesignError.invalidRequest("The executable changed during the run.")
        }
        return .init(argv: result.arguments, stdout: result.stdout, stderr: result.stderr, exitStatus: result.exitCode,
                     version: Self.toolVersion, runtime: .init(executablePath: executable.path,
                     condaEnvironment: prefix == nil ? nil : "primalscheme3", condaPrefix: prefix?.path,
                     pluginPack: prefix == nil ? nil : "pcr-primer-design", dependencySet: prefix == nil ? nil : ManagedToolLock.bundled.resolvedDependencySet),
                     startedAt: start, endedAt: Date(), executableSHA256: executableHash, runtimeEvidence: runtimeEvidence)
    }

    private static func physicalParent(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.pathComponents.contains("..") else {
            throw PrimalScheme3DesignError.invalidRequest("Unsafe destination path.")
        }
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else {
            throw PrimalScheme3DesignError.invalidRequest("The destination parent must already exist.")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    private static func relative(_ url: URL, to root: URL) -> String { String(url.path.dropFirst(root.path.count + 1)) }

    private static func regularFiles(in url: URL) throws -> [URL] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw PrimalScheme3DesignError.invalidRequest("Symbolic-link payloads are unsupported.") }
        if values.isRegularFile == true { return [url] }
        guard values.isDirectory == true else { throw PrimalScheme3DesignError.invalidRequest("Unsupported payload file type.") }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { try regularFiles(in: $0) }
    }

    private static func copySource(_ source: URL, to destination: URL) throws {
        let files = try regularFiles(in: source)
        let directory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if directory { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        for file in files {
            try Task.checkCancellation()
            let target = directory ? destination.appendingPathComponent(relative(file, to: source)) : destination
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: target)
        }
    }

    private static func descriptor(_ source: URL, path: String, role: FileRole, origin: String? = nil) throws -> ProvenanceFileDescriptor {
        return .init(path: path, checksumSHA256: try ProvenanceFileHasher.sha256(of: source),
                     fileSize: try ProvenanceFileHasher.fileSize(of: source), role: role, originPath: origin)
    }

    private static func parameter(_ value: Any) -> ParameterValue {
        if let dictionary = value as? [String: Any] { return .dictionary(dictionary.mapValues(parameter)) }
        if let array = value as? [Any] { return .array(array.map(parameter)) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        return .string("null")
    }
}

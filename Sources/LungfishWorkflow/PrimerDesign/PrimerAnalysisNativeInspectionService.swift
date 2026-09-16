import CoreFoundation
import Foundation
import LungfishIO

public enum PrimerAnalysisNativeInspectionError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct PrimerAnalysisHistoryQuery: Sendable, Equatable {
    public var entity: String?
    public var target: String?
    public var region: String?
    public var pool: Int?
    public var stage: String?
    public var profile: String?
    public var lineage: Bool
    public var limit: Int
    public var offset: Int

    public init(entity: String? = nil, target: String? = nil, region: String? = nil,
                pool: Int? = nil, stage: String? = nil, profile: String? = nil,
                lineage: Bool = false, limit: Int = 100, offset: Int = 0) {
        self.entity = entity; self.target = target; self.region = region; self.pool = pool
        self.stage = stage; self.profile = profile; self.lineage = lineage
        self.limit = limit; self.offset = offset
    }
}

public struct PrimerAnalysisNativeInspectionService: Sendable {
    private struct RunEvidence {
        var bundle: PrimerAnalysisBundle?
        var nativeDirectory: URL?
        var executableHash: String?
        var capabilities: PrimalScheme3AlleleCapabilities?
        var probe: NativeToolResult?
        var nativeResult: NativeToolResult?
        var nativeArgv: [String]
    }

    public init() {}

    public func history(analysisURL: URL, resultID: UUID, executableURL: URL, outputURL: URL,
                        query: PrimerAnalysisHistoryQuery, invocationArgv: [String]) async throws -> URL {
        var arguments = ["panel-history"]
        if let value = query.entity { arguments += ["--entity", value] }
        if let value = query.target { arguments += ["--target", value] }
        if let value = query.region { arguments += ["--region", value] }
        if let value = query.pool { arguments += ["--pool", String(value)] }
        if let value = query.stage { arguments += ["--stage", value] }
        if let value = query.profile { arguments += ["--profile", value] }
        if query.lineage { arguments += ["--lineage"] }
        arguments += ["--limit", String(query.limit), "--offset", String(query.offset)]
        let explicit: [String: ParameterValue] = [
            "entity": query.entity.map(ParameterValue.string) ?? .null,
            "target": query.target.map(ParameterValue.string) ?? .null,
            "region": query.region.map(ParameterValue.string) ?? .null,
            "pool": query.pool.map(ParameterValue.integer) ?? .null,
            "stage": query.stage.map(ParameterValue.string) ?? .null,
            "profile": query.profile.map(ParameterValue.string) ?? .null,
            "lineage": .boolean(query.lineage), "limit": .integer(query.limit), "offset": .integer(query.offset)
        ]
        return try await run(analysisURL: analysisURL, resultID: resultID, executableURL: executableURL,
                             outputURL: outputURL, subcommandArguments: arguments,
                             invocationArgv: invocationArgv, explicit: explicit, audit: false)
    }

    public func audit(analysisURL: URL, resultID: UUID, executableURL: URL, outputURL: URL,
                      tier: String?, invocationArgv: [String]) async throws -> URL {
        var arguments = ["panel-audit"]
        if let tier { arguments += ["--tier", tier] }
        return try await run(analysisURL: analysisURL, resultID: resultID, executableURL: executableURL,
                             outputURL: outputURL, subcommandArguments: arguments,
                             invocationArgv: invocationArgv,
                             explicit: ["tier": tier.map(ParameterValue.string) ?? .null], audit: true)
    }

    private func run(analysisURL: URL, resultID: UUID, executableURL: URL, outputURL: URL,
                     subcommandArguments: [String], invocationArgv: [String],
                     explicit: [String: ParameterValue], audit: Bool) async throws -> URL {
        guard outputURL.isFileURL, outputURL.path.hasPrefix("/"), !outputURL.pathComponents.contains(".."),
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PrimerAnalysisNativeInspectionError.invalid("The inspection output must be a new absolute directory.")
        }
        let startedAt = Date()
        let workingDirectory = outputURL.deletingLastPathComponent()
        let attemptDirectory = workingDirectory.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).inspection-attempt", isDirectory: true)
        try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: false)
        let attemptURL = attemptDirectory.appendingPathComponent("inspection-attempt.json")
        try Self.writeJSONObject([
            "status": "started", "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "wrapperArgv": invocationArgv, "analysis": analysisURL.path,
            "resultID": resultID.uuidString, "nativeExecutable": executableURL.path,
            "nativeSubcommand": subcommandArguments, "output": outputURL.path,
            "workingDirectory": workingDirectory.path
        ], to: attemptURL)
        var evidence = RunEvidence(nativeArgv: [executableURL.path] + subcommandArguments)

        do {
            let bundle = try PrimerAnalysisBundle.load(from: analysisURL) { try Task.checkCancellation() }
            evidence.bundle = bundle
            let native = try Self.nativeDirectory(bundle: bundle, resultID: resultID)
            evidence.nativeDirectory = native
            evidence.nativeArgv = [executableURL.path] + subcommandArguments
                + ["--bundle", native.path, "--output", outputURL.path]
            let executableHash = try ProvenanceFileHasher.sha256(of: executableURL)
            evidence.executableHash = executableHash
            let runner = NativeToolRunner()
            let probe = try await runner.runProcess(executableURL: executableURL, arguments: ["--capabilities-json"],
                                                    workingDirectory: workingDirectory, timeout: 30)
            evidence.probe = probe
            guard probe.exitCode == 0, let capabilitiesData = probe.stdout.data(using: .utf8) else {
                throw PrimerAnalysisNativeInspectionError.invalid("The supplied executable did not return lge.4 capabilities.")
            }
            let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(capabilitiesData)
            evidence.capabilities = capabilities
            let arguments = Array(evidence.nativeArgv.dropFirst())
            let result = try await runner.runProcess(executableURL: executableURL, arguments: arguments,
                workingDirectory: workingDirectory, timeout: 86400,
                toolName: audit ? "PrimalScheme3 panel-audit" : "PrimalScheme3 panel-history")
            evidence.nativeResult = result
            guard result.exitCode == 0 else {
                throw PrimerAnalysisNativeInspectionError.invalid("Native inspection failed with status \(result.exitCode): \(result.stderr)")
            }
            guard try ProvenanceFileHasher.sha256(of: executableURL) == executableHash else {
                throw PrimerAnalysisNativeInspectionError.invalid("The native executable changed during inspection.")
            }
            try Self.validateNativeReceipt(output: outputURL, native: native, capabilities: capabilities,
                                           executedArgv: result.arguments, audit: audit)
            try Self.writeWrapperProvenance(outputURL: outputURL, analysisURL: analysisURL,
                resultID: resultID, executableURL: executableURL, invocationArgv: invocationArgv,
                explicit: explicit, audit: audit, evidence: evidence, status: "success",
                exitStatus: 0, stderr: result.stderr, startedAt: startedAt)
            try? FileManager.default.removeItem(at: attemptDirectory)
            return outputURL
        } catch {
            let cancelled = error is CancellationError
            let detail = [evidence.nativeResult?.stderr, evidence.probe?.stderr, error.localizedDescription]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            do {
                if !FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
                }
                let retainedAttempt = outputURL.appendingPathComponent("inspection-attempt.json")
                if !FileManager.default.fileExists(atPath: retainedAttempt.path) {
                    try FileManager.default.copyItem(at: attemptURL, to: retainedAttempt)
                }
                try Self.writeWrapperProvenance(outputURL: outputURL, analysisURL: analysisURL,
                    resultID: resultID, executableURL: executableURL, invocationArgv: invocationArgv,
                    explicit: explicit, audit: audit, evidence: evidence,
                    status: cancelled ? "cancelled" : "failed", exitStatus: cancelled ? 130 : 1,
                    stderr: detail, startedAt: startedAt)
                try? FileManager.default.removeItem(at: attemptDirectory)
            } catch let provenanceError {
                throw PrimerAnalysisNativeInspectionError.invalid(
                    "\(error.localizedDescription) Failure provenance could not be written: \(provenanceError.localizedDescription)")
            }
            throw error
        }
    }

    private static func writeWrapperProvenance(outputURL: URL, analysisURL: URL, resultID: UUID,
                                                executableURL: URL, invocationArgv: [String],
                                                explicit: [String: ParameterValue], audit: Bool,
                                                evidence: RunEvidence, status: String, exitStatus: Int,
                                                stderr: String, startedAt: Date) throws {
        var resolved: [String: ParameterValue] = [
            "status": .string(status), "resultID": .string(resultID.uuidString),
            "analysisPath": .string(analysisURL.path), "outputPath": .string(outputURL.path),
            "workingDirectory": .string(outputURL.deletingLastPathComponent().path),
            "nativeExecutable": .string(executableURL.path),
            "nativeExecutableSHA256": evidence.executableHash.map(ParameterValue.string) ?? .null,
            "nativeProbeArgv": .array(([executableURL.path, "--capabilities-json"]).map(ParameterValue.string)),
            "nativeProbeExitStatus": evidence.probe.map { .integer(Int($0.exitCode)) } ?? .null,
            "nativeProbeStdout": evidence.probe.map { .string($0.stdout) } ?? .null,
            "nativeProbeStderr": evidence.probe.map { .string($0.stderr) } ?? .null,
            "nativeArgv": .array((evidence.nativeResult?.arguments ?? evidence.nativeArgv).map(ParameterValue.string)),
            "nativeExitStatus": evidence.nativeResult.map { .integer(Int($0.exitCode)) } ?? .null,
            "nativeStdout": evidence.nativeResult.map { .string($0.stdout) } ?? .null,
            "nativeStderr": evidence.nativeResult.map { .string($0.stderr) } ?? .null
        ]
        if let bundle = evidence.bundle { resolved["analysisID"] = .string(bundle.manifest.analysisID.uuidString) }
        if let native = evidence.nativeDirectory { resolved["nativeDirectory"] = .string(native.path) }
        if let capabilities = evidence.capabilities {
            resolved["nativeSource"] = parameterValue(capabilities.source)
            resolved["nativeRuntime"] = parameterValue(capabilities.runtime)
        }
        var builder = ProvenanceRunBuilder(
            workflowName: audit ? "lungfish.primer-analysis.panel-audit" : "lungfish.primer-analysis.panel-history",
            workflowVersion: "1", toolName: "Lungfish saved panel inspection",
            toolVersion: PrimalScheme3DesignPipeline.alleleToolVersion)
            .argv(invocationArgv)
            .reproducibleCommand(invocationArgv.map(shellEscape).joined(separator: " "))
            .runtime(.init())
            .options(explicit: explicit, defaults: [:], resolved: resolved)
        if let bundle = evidence.bundle {
            builder = try builder.input(bundle.url.appendingPathComponent(PrimerAnalysisManifest.filename), format: .json)
            if let native = evidence.nativeDirectory {
                let prefix = "native/\(resultID.uuidString)/"
                for artifact in bundle.manifest.artifacts where artifact.relativePath.hasPrefix(prefix) {
                    builder = try builder.consumedInputSnapshot(.init(
                        path: native.appendingPathComponent(String(artifact.relativePath.dropFirst(prefix.count))).path,
                        checksumSHA256: artifact.sha256, fileSize: artifact.byteSize, role: .input))
                }
            }
        } else {
            let manifest = analysisURL.appendingPathComponent(PrimerAnalysisManifest.filename)
            if FileManager.default.fileExists(atPath: manifest.path) { builder = try builder.input(manifest, format: .json) }
        }
        let provenanceURL = outputURL.appendingPathComponent("lungfish-provenance.json")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            for file in try regularFiles(outputURL) where file != provenanceURL {
                builder = try builder.output(file)
            }
        }
        let envelope = try builder.complete(exitStatus: exitStatus, stderr: stderr,
                                            startedAt: startedAt, endedAt: Date())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: provenanceURL, options: .withoutOverwriting)
    }

    private static func parameterValue(_ value: Any) -> ParameterValue {
        switch value {
        case let string as String: return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            if number.doubleValue.rounded() == number.doubleValue { return .integer(number.intValue) }
            return .number(number.doubleValue)
        case let array as [Any]: return .array(array.map(parameterValue))
        case let dictionary as [String: Any]: return .dictionary(dictionary.mapValues(parameterValue))
        default: return .null
        }
    }

    private static func writeJSONObject(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .withoutOverwriting)
    }

    static func nativeDirectory(bundle: PrimerAnalysisBundle, resultID: UUID) throws -> URL {
        guard let result = bundle.manifest.results.first(where: { $0.id == resultID }) else {
            throw PrimerAnalysisNativeInspectionError.invalid("The result ID is not present in this analysis.")
        }
        let prefix = "native/\(resultID.uuidString)/"
        let nativePaths = result.artifactPaths.filter { $0.hasPrefix(prefix) }
        guard !nativePaths.isEmpty,
              nativePaths.contains(where: { $0 == prefix + "panel-provenance.json" }),
              nativePaths.allSatisfy({ path in bundle.manifest.artifacts.contains { $0.relativePath == path && $0.role == "nativeOutput" } }) else {
            throw PrimerAnalysisNativeInspectionError.invalid("This result has no contained lge.4 native panel directory.")
        }
        for path in nativePaths { _ = try bundle.artifactURL(forRelativePath: path) }
        return bundle.url.appendingPathComponent("native/\(resultID.uuidString)", isDirectory: true)
    }

    private static func validateNativeReceipt(output: URL, native: URL,
                                              capabilities: PrimalScheme3AlleleCapabilities,
                                              executedArgv: [String], audit: Bool) throws {
        let provenanceURL = output.appendingPathComponent("provenance.json")
        let resultURL = output.appendingPathComponent(audit ? "validation.json" : "query.json")
        let provenance = try object(JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)), "native receipt")
        let result = try object(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)), "native result")
        guard provenance["schemaVersion"] as? String == "primalscheme3.panel-inspection-provenance/v1",
              provenance["toolVersion"] as? String == PrimalScheme3DesignPipeline.alleleToolVersion,
              provenance["status"] as? String == "success", (provenance["exitStatus"] as? NSNumber)?.intValue == 0,
              (result["valid"] as? NSNumber)?.boolValue == true,
              let command = provenance["command"] as? [String: Any], command["argv"] as? [String] == executedArgv,
              equalJSON(provenance["source"], capabilities.source), equalJSON(provenance["sourceAtEnd"], capabilities.source),
              equalJSON(provenance["runtime"], capabilities.runtime), equalJSON(provenance["runtimeAtEnd"], capabilities.runtime),
              (provenance["inputChangedDuringRun"] as? NSNumber)?.boolValue == false,
              (provenance["sourceChangedDuringRun"] as? NSNumber)?.boolValue == false,
              (provenance["runtimeChangedDuringRun"] as? NSNumber)?.boolValue == false else {
            throw PrimerAnalysisNativeInspectionError.invalid("Native inspection provenance is incomplete or detached.")
        }
        if audit, (result["raw_inputs_reparsed"] as? NSNumber)?.boolValue != true {
            throw PrimerAnalysisNativeInspectionError.invalid("Native audit did not reparse stored source alignments.")
        }
        let nativeFiles = try regularFiles(native)
        let nativeByPath = Dictionary(uniqueKeysWithValues: nativeFiles.map { (relative($0, to: native), $0) })
        let inputs = try objectArray(provenance["inputs"], "inspection inputs")
        if audit, Set(inputs.compactMap { $0["path"] as? String }) != Set(nativeByPath.keys) {
            throw PrimerAnalysisNativeInspectionError.invalid("Native audit input inventory is incomplete.")
        }
        for descriptor in inputs {
            guard let path = descriptor["path"] as? String, let file = nativeByPath[path] else {
                throw PrimerAnalysisNativeInspectionError.invalid("Native inspection references an unknown input.")
            }
            try validateDescriptor(descriptor, file: file)
        }
        let outputs = try objectArray(provenance["outputs"], "inspection outputs")
        guard outputs.count == 1, outputs[0]["path"] as? String == resultURL.lastPathComponent else {
            throw PrimerAnalysisNativeInspectionError.invalid("Native inspection output receipt is incomplete.")
        }
        try validateDescriptor(outputs[0], file: resultURL)
    }

    private static func validateDescriptor(_ descriptor: [String: Any], file: URL) throws {
        guard descriptor["sha256"] as? String == (try ProvenanceFileHasher.sha256(of: file)),
              (descriptor["size"] as? NSNumber)?.uint64Value == (try ProvenanceFileHasher.fileSize(of: file)) else {
            throw PrimerAnalysisNativeInspectionError.invalid("Native inspection file hash or size differs from its receipt.")
        }
    }

    private static func regularFiles(_ root: URL) throws -> [URL] {
        let values = try root.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PrimerAnalysisNativeInspectionError.invalid("Symbolic links are unsupported.") }
        if values.isRegularFile == true { return [root] }
        guard values.isDirectory == true else { throw PrimerAnalysisNativeInspectionError.invalid("Unsupported inspection file type.") }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.path < $1.path }.flatMap(regularFiles)
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
    }

    private static func object(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw PrimerAnalysisNativeInspectionError.invalid("\(label) is missing or malformed.")
        }
        return result
    }

    private static func objectArray(_ value: Any?, _ label: String) throws -> [[String: Any]] {
        guard let result = value as? [[String: Any]] else {
            throw PrimerAnalysisNativeInspectionError.invalid("\(label) is missing or malformed.")
        }
        return result
    }

    private static func equalJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs, JSONSerialization.isValidJSONObject(lhs), JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }
}

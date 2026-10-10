// ProvenanceCompatFacts.swift - Host-independent projection of what the readers say about a sidecar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Decoding a provenance sidecar fills values from the reading machine: the
// runtime identity of an old bare run takes the reader's executable path, pid,
// architecture and dependency set, a missing workflow version takes the
// reader's app version, a missing date takes the file's modification time, and
// `@/`, `<tool-root>` and `<storage-root>` paths resolve against the reader's
// project and managed roots. Comparing whole decoded envelopes would therefore
// differ from one Mac to the next. This projection keeps only what the bytes
// say, passed through the production readers, and rewrites the machine-bound
// path prefixes to fixed tokens. A runtime key or a date appears only when the
// key is present in the source bytes.
//
// Facts version 2 adds, per step, the durable replay argv, the reproducible
// command, the step graph as positions, the wall time, the resolved options and
// the container and conda identity the step's bytes hold, and adds two views of
// the steps as the legacy readers see them (`legacyRunSteps`, `canonicalRunSteps`).

import Foundation
import LungfishCore
import LungfishWorkflow

public struct ProvenanceCompatFacts: Codable, Equatable, Sendable {
    public static let currentFactsVersion = 2

    /// Which step of the tolerant reader accepts the bytes. It is decided by trying the
    /// decoders in the reader's order on the path-resolved bytes.
    public enum DecodedBy: String, Codable, Sendable {
        /// Step 1, the canonical envelope.
        case envelope
        /// Step 2, a bare `WorkflowRun` converted with `canonicalEnvelope()`.
        case workflowRun
        /// Step 3, the primitive adapter.
        case primitive
    }

    /// What `ops stats` makes of the bytes when they sit in a file named
    /// `.lungfish-provenance.json`. It decodes the file as a `WorkflowRun` with a
    /// plain decoder and drops it silently when that fails.
    public struct OpsStats: Codable, Equatable, Sendable {
        public var decodesAsWorkflowRun: Bool
        public var completedRunCount: Int
        public var totalWallTimeSeconds: Double
        public var peakMemoryBytes: UInt64?
    }

    public struct FileFact: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String?
        public var size: UInt64?
        public var role: String
        public var format: String?
    }

    /// One step of the envelope as the reader presents it.
    public struct StepFact: Codable, Equatable, Sendable {
        public var toolName: String
        public var toolVersion: String
        public var argv: [String]
        public var durableReplayArgv: [String]?
        public var reproducibleCommand: String
        /// The steps this step depends on, as positions in `steps`, so step ids drop out.
        /// A reference to an id that is not among the steps reads -1.
        public var dependsOn: [Int]
        public var exitStatus: Int?
        public var wallTimeSeconds: Double?
        public var peakMemoryBytes: UInt64?
        public var stderr: String?
        public var resolvedOptions: Value
        /// `containerImage`, `containerDigest` and `condaEnvironment`, present only when the
        /// step's own bytes hold the key, either on the step or in its runtime identity.
        public var recorded: [String: String]
        public var inputs: [FileFact]
        public var outputs: [FileFact]
    }

    /// One step of the `WorkflowRun` that `legacyWorkflowRun()` returns, which is what Copy
    /// Command, `provenance bibliography`, `ops stats` and the exporters read.
    public struct LegacyStepFact: Codable, Equatable, Sendable {
        public var toolName: String
        public var toolVersion: String
        public var command: [String]
        public var durableReplayArgv: [String]?
        public var containerImage: String?
        public var containerDigest: String?
        public var exitCode: Int?
        public var wallTime: Double?
        public var peakMemoryBytes: UInt64?
        /// Positions in this view's own step list.
        public var dependsOn: [Int]
    }

    public var factsVersion: Int
    public var decodedBy: DecodedBy
    /// Whether the strict readers (`loadCanonical`, `decodeCanonical`) accept the bytes.
    public var strictAccepts: Bool
    public var opsStats: OpsStats
    /// The top-level `status` string exactly as the bytes hold it, or nil when the key is absent.
    public var status: String?
    /// The `status` of the embedded `legacyWorkflowRun`, as the bytes hold it.
    public var embeddedRunStatus: String?
    /// The status a consumer of `envelope.legacyWorkflowRun()` reads.
    public var readStatus: String
    public var workflowName: String
    public var toolName: String
    public var toolVersion: String
    public var argv: [String]
    public var durableReplayArgv: [String]?
    public var reproducibleCommand: String
    public var exitStatus: Int?
    public var wallTimeSeconds: Double?
    public var stderr: String?
    public var explicitOptions: Value
    public var defaultOptions: Value
    public var resolvedDefaultOptions: Value
    /// The parameters of `envelope.legacyWorkflowRun()`, which for a run-bearing
    /// envelope or a bare run are the run's own parameters.
    public var legacyRunParameters: Value
    public var files: [FileFact]
    public var output: FileFact?
    public var outputs: [FileFact]
    public var steps: [StepFact]
    /// The steps of `envelope.legacyWorkflowRun()`. A run-bearing envelope or a bare run shows
    /// the run's own steps, any other record shows steps rebuilt from the envelope's.
    public var legacyRunSteps: [LegacyStepFact]
    /// The steps of `envelope.legacyWorkflowRun(preferCanonicalSteps: true)`, which the
    /// exporters read. They are always rebuilt from the envelope's own steps.
    public var canonicalRunSteps: [LegacyStepFact]
    /// Values the bytes record for the keys a reader would otherwise fill from the
    /// reading machine (`createdAt`, `workflowVersion`, `appVersion`, `hostOS`, and every
    /// scalar in `runtimeIdentity` and `runtime`), present only when the key is in the bytes.
    public var recorded: [String: String]

    // MARK: JSON

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> ProvenanceCompatFacts {
        try JSONDecoder().decode(ProvenanceCompatFacts.self, from: data)
    }

    // MARK: Projection

    public enum ProjectionError: Error, LocalizedError {
        case missingSidecar(String)
        case notJSONObject(String)

        public var errorDescription: String? {
            switch self {
            case .missingSidecar(let path): return "No readable provenance sidecar at \(path)"
            case .notJSONObject(let path): return "The sidecar is not a JSON object: \(path)"
            }
        }
    }

    /// Reads the sidecar through the production readers and projects what they say.
    ///
    /// - Parameters:
    ///   - sidecar: The sidecar inside a temporary project. It is read, never written.
    ///   - projectRoot: The `.lungfish` project that holds it. Its paths become `<project>`.
    public static func project(sidecar: URL, projectRoot: URL) throws -> ProvenanceCompatFacts {
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: sidecar) else {
            throw ProjectionError.missingSidecar(sidecar.path)
        }
        return try project(envelope: envelope, sidecar: sidecar, projectRoot: projectRoot)
    }

    /// Projects an envelope a reader or the finder already decoded from `sidecar`.
    public static func project(
        envelope: ProvenanceEnvelope,
        sidecar: URL,
        projectRoot: URL
    ) throws -> ProvenanceCompatFacts {
        let rawBytes = try Data(contentsOf: sidecar)
        let resolvedBytes = PortablePath.resolveJSON(rawBytes, forFileAt: sidecar, encoder: ProvenanceJSON.encoder)
        guard let json = try JSONSerialization.jsonObject(with: resolvedBytes) as? [String: Any] else {
            throw ProjectionError.notJSONObject(sidecar.path)
        }
        let normalize = PathNormalizer(projectRoot: projectRoot)

        let strictAccepts = (try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecar)) != nil
        let legacyView = envelope.legacyWorkflowRun()
        let canonicalView = envelope.legacyWorkflowRun(preferCanonicalSteps: true)
        let embeddedRun = json["legacyWorkflowRun"] as? [String: Any]
        let rawSteps = rawStepObjects(in: json)
        let stepIDs = envelope.steps.map(\.id)

        return ProvenanceCompatFacts(
            factsVersion: currentFactsVersion,
            decodedBy: decodedBy(ofResolvedBytes: resolvedBytes),
            strictAccepts: strictAccepts,
            opsStats: try opsStatsFacts(rawBytes: rawBytes),
            status: json["status"] as? String,
            embeddedRunStatus: embeddedRun?["status"] as? String,
            readStatus: legacyView.status.rawValue,
            workflowName: normalize(envelope.workflowName),
            toolName: normalize(envelope.toolName),
            toolVersion: normalize(envelope.toolVersion),
            argv: envelope.argv.map { normalize($0) },
            durableReplayArgv: envelope.durableReplayArgv?.map { normalize($0) },
            reproducibleCommand: normalize(envelope.reproducibleCommand),
            exitStatus: envelope.exitStatus,
            wallTimeSeconds: envelope.wallTimeSeconds,
            stderr: envelope.stderr.map { normalize($0) },
            explicitOptions: typedValue(of: envelope.options.explicit, normalize: normalize),
            defaultOptions: typedValue(of: envelope.options.defaults, normalize: normalize),
            resolvedDefaultOptions: typedValue(of: envelope.options.resolvedDefaults, normalize: normalize),
            legacyRunParameters: typedValue(of: legacyView.parameters, normalize: normalize),
            files: envelope.files.map { fileFact($0, normalize: normalize) },
            output: envelope.output.map { fileFact($0, normalize: normalize) },
            outputs: envelope.outputs.map { fileFact($0, normalize: normalize) },
            steps: envelope.steps.enumerated().map { index, step in
                stepFact(
                    step,
                    stepIDs: stepIDs,
                    rawStep: index < rawSteps.count ? rawSteps[index] : nil,
                    normalize: normalize
                )
            },
            legacyRunSteps: legacyStepFacts(legacyView.steps, normalize: normalize),
            canonicalRunSteps: legacyStepFacts(canonicalView.steps, normalize: normalize),
            recorded: recordedValues(in: json, normalize: normalize)
        )
    }

    /// Tries the decoders on the path-resolved bytes in the reader's order.
    private static func decodedBy(ofResolvedBytes bytes: Data) -> DecodedBy {
        if (try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes)) != nil {
            return .envelope
        }
        if (try? ProvenanceJSON.decoder.decode(WorkflowRun.self, from: bytes)) != nil {
            return .workflowRun
        }
        return .primitive
    }

    private static func opsStatsFacts(rawBytes: Data) throws -> OpsStats {
        // `ops stats` reads the raw file with a plain ISO 8601 decoder and keeps the
        // runs that decode. It only looks at files named `.lungfish-provenance.json`,
        // so the bytes are copied to a scratch folder under that name.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodes = (try? decoder.decode(WorkflowRun.self, from: rawBytes)) != nil

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-compat-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try rawBytes.write(to: scratch.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let report = try OperationStatsAggregator().summarize(projectURL: scratch)
        return OpsStats(
            decodesAsWorkflowRun: decodes,
            completedRunCount: report.completedRunCount,
            totalWallTimeSeconds: report.totalWallTimeSeconds,
            peakMemoryBytes: report.peakMemoryBytes
        )
    }

    private static func fileFact(_ descriptor: ProvenanceFileDescriptor, normalize: PathNormalizer) -> FileFact {
        FileFact(
            path: normalize(descriptor.path),
            sha256: descriptor.checksumSHA256,
            size: descriptor.fileSize,
            role: descriptor.role.rawValue,
            format: descriptor.format?.rawValue
        )
    }

    private static func stepFact(
        _ step: ProvenanceStep,
        stepIDs: [UUID],
        rawStep: [String: Any]?,
        normalize: PathNormalizer
    ) -> StepFact {
        StepFact(
            toolName: normalize(step.toolName),
            toolVersion: normalize(step.toolVersion),
            argv: step.argv.map { normalize($0) },
            durableReplayArgv: step.durableReplayArgv?.map { normalize($0) },
            reproducibleCommand: normalize(step.reproducibleCommand),
            dependsOn: step.dependsOn.map { stepIDs.firstIndex(of: $0) ?? -1 },
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            peakMemoryBytes: step.peakMemoryBytes,
            stderr: step.stderr.map { normalize($0) },
            resolvedOptions: typedValue(of: step.resolvedOptions, normalize: normalize),
            recorded: stepRecordedValues(in: rawStep, normalize: normalize),
            inputs: step.inputs.map { fileFact($0, normalize: normalize) },
            outputs: step.outputs.map { fileFact($0, normalize: normalize) }
        )
    }

    private static func legacyStepFacts(_ steps: [StepExecution], normalize: PathNormalizer) -> [LegacyStepFact] {
        let ids = steps.map(\.id)
        return steps.map { step in
            LegacyStepFact(
                toolName: normalize(step.toolName),
                toolVersion: normalize(step.toolVersion),
                command: step.command.map { normalize($0) },
                durableReplayArgv: step.durableReplayArgv?.map { normalize($0) },
                containerImage: step.containerImage.map { normalize($0) },
                containerDigest: step.containerDigest.map { normalize($0) },
                exitCode: step.exitCode.map(Int.init),
                wallTime: step.wallTime,
                peakMemoryBytes: step.peakMemoryBytes,
                dependsOn: step.dependsOn.map { ids.firstIndex(of: $0) ?? -1 }
            )
        }
    }

    /// Options and parameters as typed JSON, built straight from the model so the result does
    /// not depend on the working directory. A file value that was recorded as a relative path
    /// keeps that path, where `URL.path` would prepend the current directory.
    private static func typedValue(of parameters: [String: ParameterValue], normalize: PathNormalizer) -> Value {
        .object(parameters.mapValues { typedValue(of: $0, normalize: normalize) })
    }

    private static func typedValue(of parameter: ParameterValue, normalize: PathNormalizer) -> Value {
        func typed(_ type: String, _ value: Value? = nil) -> Value {
            var members: [String: Value] = ["type": .string(type)]
            if let value { members["value"] = value }
            return .object(members)
        }
        switch parameter {
        case .string(let text):
            return typed("string", .string(normalize(text)))
        case .integer(let number):
            return typed("integer", .integer(Int64(number)))
        case .number(let number):
            return typed("number", .number(number))
        case .boolean(let flag):
            return typed("boolean", .bool(flag))
        case .file(let url):
            return typed("file", .string(normalize(url.baseURL != nil ? url.relativePath : url.path)))
        case .array(let items):
            return typed("array", .array(items.map { typedValue(of: $0, normalize: normalize) }))
        case .dictionary(let members):
            return typed("dictionary", .object(members.mapValues { typedValue(of: $0, normalize: normalize) }))
        case .null:
            return typed("null")
        }
    }

    /// The step objects in the bytes, in the order the envelope decoder reads them.
    private static func rawStepObjects(in json: [String: Any]) -> [[String: Any]] {
        for key in ["steps", "workflowSteps", "externalToolInvocations"] {
            if let steps = json[key] as? [[String: Any]], !steps.isEmpty { return steps }
        }
        if let single = json["externalTool"] as? [String: Any] { return [single] }
        return []
    }

    private static func stepRecordedValues(in rawStep: [String: Any]?, normalize: PathNormalizer) -> [String: String] {
        guard let rawStep else { return [:] }
        let identity = rawStep["runtimeIdentity"] as? [String: Any] ?? rawStep["runtime"] as? [String: Any]
        var result: [String: String] = [:]
        for key in ["containerImage", "containerDigest", "condaEnvironment"] {
            if let text = scalarText(identity?[key]) ?? scalarText(rawStep[key]) {
                result[key] = normalize(text)
            }
        }
        return result
    }

    /// The top-level keys a reader fills when they are missing, and every scalar of the
    /// two runtime objects, read straight from the resolved bytes.
    private static func recordedValues(in json: [String: Any], normalize: PathNormalizer) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["createdAt", "workflowVersion", "appVersion", "hostOS"] {
            if let text = scalarText(json[key]) { result[key] = normalize(text) }
        }
        for objectKey in ["runtimeIdentity", "runtime"] {
            guard let object = json[objectKey] as? [String: Any] else { continue }
            for (key, raw) in object {
                if let text = scalarText(raw) { result["\(objectKey).\(key)"] = normalize(text) }
            }
        }
        return result
    }

    private static func scalarText(_ raw: Any?) -> String? {
        switch raw {
        case let text as String:
            return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            return nil
        }
    }
}

// MARK: - JSON value

extension ProvenanceCompatFacts {
    /// An arbitrary JSON document, so options appear in the facts file as nested JSON
    /// instead of an escaped string.
    public indirect enum Value: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let integer = try? container.decode(Int64.self) {
                self = .integer(integer)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([Value].self) {
                self = .array(array)
            } else if let object = try? container.decode([String: Value].self) {
                self = .object(object)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        public func mappingStrings(_ transform: (String) -> String) -> Value {
            switch self {
            case .string(let text): return .string(transform(text))
            case .array(let items): return .array(items.map { $0.mappingStrings(transform) })
            case .object(let members): return .object(members.mapValues { $0.mappingStrings(transform) })
            default: return self
            }
        }
    }
}

// MARK: - Path normalization

extension ProvenanceCompatFacts {
    /// Rewrites the path prefixes that belong to the machine or the test run to fixed tokens.
    ///
    /// In this order: the temporary project (`<project>`), the managed tool root
    /// (`<tool-root>`), the managed storage root (`<storage-root>`), the temporary folders
    /// (`<tmp>`), and the account folder of any user (`<home>`). A prefix matches only on a
    /// path boundary, and both spellings of a symlinked prefix (`/var` and `/private/var`)
    /// are tried. The working directory is not an anchor, because a test started from a
    /// home folder would turn every `<home>` path into it.
    public struct PathNormalizer: Sendable {
        private let anchors: [(path: String, token: String)]

        public init(projectRoot: URL) {
            var candidates: [(path: String, token: String)] = []
            func add(_ path: String, _ token: String) {
                for spelling in Self.spellings(of: path) {
                    candidates.append((spelling, token))
                }
            }
            add(projectRoot.path, "<project>")
            let managed = PortablePath.defaultManagedRoots
            add(managed.toolRoot.path, "<tool-root>")
            add(managed.storageRoot.path, "<storage-root>")
            add(FileManager.default.temporaryDirectory.path, "<tmp>")
            add(NSTemporaryDirectory(), "<tmp>")
            if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], tmpdir.count > 1 { add(tmpdir, "<tmp>") }

            var seen = Set<String>()
            anchors = candidates
                .filter { $0.path.count > 1 && seen.insert($0.path).inserted }
                .sorted { $0.path.count > $1.path.count }
        }

        public func callAsFunction(_ text: String) -> String {
            guard text.contains("/") else { return text }
            var result = text
            for anchor in anchors {
                result = Self.replacing(prefix: anchor.path, with: anchor.token, in: result)
            }
            result = Self.rewritingDarwinTemporaryFolders(in: result)
            for root in ["/private/var/tmp", "/var/tmp", "/private/tmp", "/tmp"] {
                result = Self.replacing(prefix: root, with: "<tmp>", in: result)
            }
            return Self.rewritingAccountFolders(in: result)
        }

        // MARK: Matching

        private static func spellings(of path: String) -> [String] {
            var trimmed = path
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            var result = [trimmed, URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path]
            for spelling in result {
                if spelling.hasPrefix("/private/var/") {
                    result.append(String(spelling.dropFirst("/private".count)))
                } else if spelling.hasPrefix("/var/") {
                    result.append("/private" + spelling)
                }
            }
            return result
        }

        private static func isPathCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }

        /// Replaces `prefix` where it starts a path and ends at a path boundary.
        private static func replacing(prefix: String, with token: String, in text: String) -> String {
            var result = ""
            var cursor = text.startIndex
            while let range = text.range(of: prefix, range: cursor..<text.endIndex) {
                let before: Character? = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after: Character? = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let startsPath = before.map { !isPathCharacter($0) && $0 != "/" } ?? true
                let endsPath = after.map { $0 == "/" || !isPathCharacter($0) } ?? true
                result += text[cursor..<range.lowerBound]
                if startsPath && endsPath {
                    result += token
                } else {
                    result += text[range]
                }
                cursor = range.upperBound
            }
            result += text[cursor...]
            return result
        }

        /// `/var/folders/<xx>/<hash>/T` and its `/private` spelling become `<tmp>`.
        private static func rewritingDarwinTemporaryFolders(in text: String) -> String {
            var result = ""
            var cursor = text.startIndex
            while let range = text.range(of: "/var/folders/", range: cursor..<text.endIndex) {
                var start = range.lowerBound
                if text[..<start].hasSuffix("/private") {
                    start = text.index(start, offsetBy: -"/private".count)
                }
                var end = range.upperBound
                var components = 0
                while components < 3, end < text.endIndex {
                    while end < text.endIndex, text[end] != "/", !isDelimiter(text[end]) { end = text.index(after: end) }
                    components += 1
                    if components < 3, end < text.endIndex, text[end] == "/" { end = text.index(after: end) } else { break }
                }
                result += text[cursor..<start]
                result += "<tmp>"
                cursor = end
            }
            result += text[cursor...]
            return result
        }

        private static func isDelimiter(_ character: Character) -> Bool {
            character.isWhitespace || "'\"\\,;:()[]{}<>|".contains(character)
        }

        /// `/Users/<name>` becomes `<home>`, except `/Users/Shared`.
        private static func rewritingAccountFolders(in text: String) -> String {
            var result = ""
            var cursor = text.startIndex
            while let range = text.range(of: "/Users/", range: cursor..<text.endIndex) {
                let before: Character? = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let startsPath = before.map { !isPathCharacter($0) && $0 != "/" } ?? true
                var end = range.upperBound
                while end < text.endIndex, text[end] != "/", !isDelimiter(text[end]) { end = text.index(after: end) }
                let name = text[range.upperBound..<end]
                result += text[cursor..<range.lowerBound]
                if startsPath, !name.isEmpty, name != "Shared" {
                    result += "<home>"
                } else {
                    result += text[range.lowerBound..<end]
                }
                cursor = end
            }
            result += text[cursor...]
            return result
        }
    }
}

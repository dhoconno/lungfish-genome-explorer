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

import Foundation
import LungfishCore
import LungfishWorkflow

public struct ProvenanceCompatFacts: Codable, Equatable, Sendable {
    public static let currentFactsVersion = 1

    /// Which step of the tolerant reader accepted the bytes.
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

    public struct StepFact: Codable, Equatable, Sendable {
        public var toolName: String
        public var toolVersion: String
        public var argv: [String]
        public var exitStatus: Int?
        public var peakMemoryBytes: UInt64?
        public var stderr: String?
        public var inputs: [FileFact]
        public var outputs: [FileFact]
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
        let decodedBy: DecodedBy = strictAccepts ? .envelope : (envelope.legacyRun != nil ? .workflowRun : .primitive)

        let legacyView = envelope.legacyWorkflowRun()
        let embeddedRun = json["legacyWorkflowRun"] as? [String: Any]

        return ProvenanceCompatFacts(
            factsVersion: currentFactsVersion,
            decodedBy: decodedBy,
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
            explicitOptions: try value(of: envelope.options.explicit, normalize: normalize),
            defaultOptions: try value(of: envelope.options.defaults, normalize: normalize),
            resolvedDefaultOptions: try value(of: envelope.options.resolvedDefaults, normalize: normalize),
            legacyRunParameters: try value(of: legacyView.parameters, normalize: normalize),
            files: envelope.files.map { fileFact($0, normalize: normalize) },
            output: envelope.output.map { fileFact($0, normalize: normalize) },
            outputs: envelope.outputs.map { fileFact($0, normalize: normalize) },
            steps: envelope.steps.map { stepFact($0, normalize: normalize) },
            recorded: recordedValues(in: json, normalize: normalize)
        )
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

    private static func stepFact(_ step: ProvenanceStep, normalize: PathNormalizer) -> StepFact {
        StepFact(
            toolName: normalize(step.toolName),
            toolVersion: normalize(step.toolVersion),
            argv: step.argv.map { normalize($0) },
            exitStatus: step.exitStatus,
            peakMemoryBytes: step.peakMemoryBytes,
            stderr: step.stderr.map { normalize($0) },
            inputs: step.inputs.map { fileFact($0, normalize: normalize) },
            outputs: step.outputs.map { fileFact($0, normalize: normalize) }
        )
    }

    private static func value(of parameters: [String: ParameterValue], normalize: PathNormalizer) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(parameters)
        return try JSONDecoder().decode(Value.self, from: data).mappingStrings { normalize($0) }
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
    /// (`<tool-root>`), the managed storage root (`<storage-root>`), the working directory
    /// (`<cwd>`), the temporary folders (`<tmp>`), and the account folder of any user
    /// (`<home>`). A prefix matches only on a path boundary, and both spellings of a
    /// symlinked prefix (`/var` and `/private/var`) are tried.
    public struct PathNormalizer: Sendable {
        private let anchors: [(path: String, token: String)]

        public init(
            projectRoot: URL,
            workingDirectory: String = FileManager.default.currentDirectoryPath
        ) {
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
            if workingDirectory.count > 1 { add(workingDirectory, "<cwd>") }
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

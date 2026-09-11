import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

/// Excel supplies an untrusted proposal; only the bundle baseline grants
/// editing authority. Protection and hidden workbook metadata are not trusted.
public struct GenotypeEditableWorkbookService: Sendable {
    public static let baselinePath = "artifacts/workbooks/editable-baseline.json"
    public enum EditError: Error, LocalizedError, Equatable {
        case rejected(String)
        public var errorDescription: String? {
            switch self { case .rejected(let reason): return "Workbook review required: " + reason }
        }
    }
    public struct Change: Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case call, review, comment }
        public let kind: Kind
        public let target: GenotypeAnnotationSidecar.MatrixTarget?
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot?
        public let baseline: String?
        public let before: String?
        /// nil means explicit clear, never an omitted row or blank cell.
        public let value: String?
        public let passedUniqueReads: Int?
    }
    public struct Inspection: Sendable {
        public let changes: [Change]
        public let workbookURL: URL
        public let workbookSHA256: String
        public let bundleURL: URL
        public let baselineSHA256: String
        public var supportsCallOverrides: Bool { baseline.callEditingSupported }
        fileprivate let workbookData: Data
        fileprivate let baseline: Baseline
        fileprivate let runtime: Runtime
        fileprivate let parsedData: Data
        fileprivate let wallTimeSeconds: Double
    }
    struct Witness: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let size: Int
    }
    struct Document: Codable, Equatable, Sendable {
        let sheets: [String: [[String]]]
        let evidence: [String: [String: String]]
    }
    struct Baseline: Codable, Sendable {
        let schemaVersion: Int
        let callEditingSupported: Bool
        let workbook: Witness
        let inputs: [Witness]
        let document: Document
    }
    struct Runtime: Codable, Sendable {
        let executable: String
        let python: String
        let openpyxl: String
        let platform: String
    }
    private struct Parsed: Codable { let document: Document; let runtime: Runtime }
    private let pythonExecutableURL: URL
    public init(pythonExecutableURL: URL) { self.pythonExecutableURL = pythonExecutableURL }

    /// Cheap byte-level gate used before regeneration or opening. A valid
    /// accepted edit is scoped to this exact baseline, source, and retained XLSX.
    public static func hasUnreviewedExternalEdits(in bundleURL: URL) throws -> Bool {
        let baselineURL = bundleURL.appendingPathComponent(baselinePath)
        let baselineData = FileManager.default.fileExists(atPath: baselineURL.path) ? try readRegular(baselineURL) : nil
        let baseline = try baselineData.map { try JSONDecoder().decode(Baseline.self, from: $0) }
        let workbookPath: String
        let expected: String
        if let baseline {
            workbookPath = baseline.workbook.path; expected = baseline.workbook.sha256
        } else if let manifest = try? ONTGenotypeResultBundle.loadManifest(from: bundleURL),
                  let current = manifest.currentWorkbookPath,
                  let revision = manifest.workbookRevisions?.last(where: { $0.path == current }) {
            workbookPath = current; expected = revision.sha256
        } else { return false }
        guard !workbookPath.hasPrefix("/"), !workbookPath.split(separator: "/").contains("..") else { throw EditError.rejected("Unsafe workbook path.") }
        let actual = hash(try readRegular(bundleURL.appendingPathComponent(workbookPath)))
        if actual == expected { return false }
        guard let baselineData, let baseline else { return true }
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        guard let data = try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(named: provenanceURL.lastPathComponent, inBundleAt: bundleURL),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = object["options"] as? [String: Any],
              let explicit = options["explicit"] as? [String: Any],
              let accepted = explicit["acceptedEditableWorkbook"] as? [String: Any],
              accepted["workbookSHA256"] as? String == actual,
              accepted["baselineSHA256"] as? String == hash(baselineData),
              let evidencePath = accepted["evidenceDirectory"] as? String else { return true }
        let evidence = URL(fileURLWithPath: evidencePath)
        guard evidence.resolvingSymlinksInPath().path.hasPrefix(bundleURL.resolvingSymlinksInPath().appendingPathComponent("artifacts/workbook-edits").path + "/"),
              hash(try readRegular(evidence.appendingPathComponent("input.xlsx"))) == actual,
              hash(try readRegular(evidence.appendingPathComponent("baseline.json"))) == hash(baselineData) else { return true }
        for input in baseline.inputs where input.path != GenotypeAnnotationSidecar.filename {
            guard !input.path.hasPrefix("/"), !input.path.split(separator: "/").contains(".."),
                  hash(try readRegular(bundleURL.appendingPathComponent(input.path))) == input.sha256 else { return true }
        }
        return false
    }

    /// Used by the editable role after synchronization. Legacy read-only
    /// opening continues to use the immutable handoff service.
    public static func canonicalEditableWorkbookURL(in bundleURL: URL) throws -> URL {
        guard try !hasUnreviewedExternalEdits(in: bundleURL) else { throw EditError.rejected("Review external edits before reopening current.xlsx.") }
        let baseline = try JSONDecoder().decode(Baseline.self, from: readRegular(bundleURL.appendingPathComponent(baselinePath)))
        let url = bundleURL.appendingPathComponent(baseline.workbook.path)
        guard hash(try readRegular(url)) == baseline.workbook.sha256 else { throw EditError.rejected("Refresh the accepted workbook before opening it for more edits.") }
        for input in baseline.inputs {
            let data: Data
            if input.path == GenotypeAnnotationSidecar.filename {
                guard let annotations = try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(named: input.path, inBundleAt: bundleURL) else { throw EditError.rejected("Annotations changed before opening.") }
                data = annotations
            } else { data = try readRegular(bundleURL.appendingPathComponent(input.path)) }
            guard hash(data) == input.sha256 else { throw EditError.rejected("Refresh the workbook after source or annotation changes.") }
        }
        if !baseline.inputs.contains(where: { $0.path == GenotypeAnnotationSidecar.filename }),
           try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(named: GenotypeAnnotationSidecar.filename, inBundleAt: bundleURL) != nil {
            throw EditError.rejected("Annotations appeared after workbook generation. Refresh before opening.")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { throw EditError.rejected("current.xlsx is read-only.") }
        return url
    }

    /// Only a freshly generated private candidate may acquire a baseline. The
    /// caller publishes it in the same generation as its attested workbook.
    func attestGeneratedWorkbook(workbookURL: URL, bundleURL: URL, scientificInputURLs: [URL] = []) throws {
        try attestGeneratedWorkbook(workbookURL: workbookURL, bundleURL: bundleURL, scientificInputURLs: scientificInputURLs, callEditingSupported: true)
    }

    func attestGeneratedWorkbook(workbookURL: URL, bundleURL: URL, scientificInputURLs: [URL] = [], callEditingSupported: Bool) throws {
        let parsed = try parse(workbookURL)
        _ = try rows(parsed.document.sheets["Edit Calls"], sheet: "Edit Calls")
        _ = try rows(parsed.document.sheets["Edit Matrix"], sheet: "Edit Matrix")
        var inputs = [try witness(bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename), in: bundleURL)]
        if let sidecar = try sidecarData(in: bundleURL) {
            inputs.append(Witness(path: GenotypeAnnotationSidecar.filename, sha256: Self.hash(sidecar), size: sidecar.count))
        }
        for url in scientificInputURLs where !inputs.contains(where: { $0.path == relative(url, in: bundleURL) }) {
            inputs.append(try witness(url, in: bundleURL))
        }
        let baseline = Baseline(schemaVersion: 1, callEditingSupported: callEditingSupported, workbook: try witness(workbookURL, in: bundleURL), inputs: inputs, document: parsed.document)
        let output = bundleURL.appendingPathComponent(Self.baselinePath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(baseline).write(to: output, options: .atomic)
    }

    public func inspect(bundleURL: URL) throws -> Inspection {
        let startedAt = Date()
        let baselineData = try Self.readRegular(bundleURL.appendingPathComponent(Self.baselinePath))
        let baseline = try JSONDecoder().decode(Baseline.self, from: baselineData)
        guard baseline.schemaVersion == 1 else { throw reject("Unsupported editing schema.") }
        try validateInputs(baseline, bundleURL: bundleURL)
        let workbookURL = try containedURL(baseline.workbook.path, in: bundleURL)
        let data = try Self.readRegular(workbookURL)
        let parsed = try parse(workbookURL)
        guard Self.hash(try Self.readRegular(workbookURL)) == Self.hash(data) else { throw reject("Excel saved during inspection. Inspect again.") }
        guard parsed.document.evidence == baseline.document.evidence,
              Set(parsed.document.sheets.keys) == Set(baseline.document.sheets.keys) else {
            throw reject("A scientific sheet, formula, comment, or workbook schema changed. Raw observations cannot be imported as edits.")
        }
        var changes: [Change] = []
        for sheet in ["Edit Calls", "Edit Matrix"] {
            let before = try rows(baseline.document.sheets[sheet], sheet: sheet)
            let after = try rows(parsed.document.sheets[sheet], sheet: sheet)
            guard Set(before.keys) == Set(after.keys) else { throw reject("Missing or unknown IDs in \(sheet). Omitted rows do not clear annotations.") }
            let editable: Set<String> = sheet == "Edit Calls" ? ["Operation", "Value"] : ["Review operation", "Review value", "Comment operation", "Comment value"]
            for id in before.keys.sorted() {
                let original = before[id]!, row = after[id]!
                guard Set(row.keys) == Set(original.keys), row.filter({ !editable.contains($0.key) }) == original.filter({ !editable.contains($0.key) }) else {
                    throw reject("Read-only identity or evidence changed for \(id).")
                }
                if sheet == "Edit Calls" {
                    if let operation = try operation(row, key: "Operation", value: "Value") {
                        guard baseline.callEditingSupported, row["Baseline available"] == "yes" else { throw reject("H1/H2 overrides are unavailable for legacy manual assignments or calls without a raw baseline. Matrix reviews and comments remain supported.") }
                        guard let slot = HaplotypeSlot(rawValue: row["Slot"] ?? "") else { throw reject("Unknown haplotype slot.") }
                        changes.append(Change(kind: .call, target: nil, sample: row["Sample"]!, locus: row["Locus"]!, slot: slot, baseline: row["Baseline call"], before: row["Effective call"], value: operation == "clear" ? nil : row["Value"], passedUniqueReads: nil))
                    }
                } else {
                    let target = try JSONDecoder().decode(GenotypeAnnotationSidecar.MatrixTarget.self, from: Data(row["Target"]!.utf8))
                    let support = Int(row["Reads"] ?? "")
                    for kind in [Change.Kind.review, .comment] {
                        let prefix = kind == .review ? "Review" : "Comment"
                        if let operation = try operation(row, key: prefix + " operation", value: prefix + " value") {
                            let value = operation == "clear" ? nil : row[prefix + " value"]
                            if kind == .review {
                                guard case .cell = target else { throw reject("Reviews require an exact cell target.") }
                                if let value {
                                    guard let support, (value == "false-positive" && support > 0) || (value == "false-negative" && support == 0) else { throw reject("Review disposition does not match attested raw evidence.") }
                                }
                            }
                            changes.append(Change(kind: kind, target: target, sample: target.sample ?? "", locus: target.locus ?? "", slot: nil, baseline: nil, before: row["Current " + prefix.lowercased()], value: value, passedUniqueReads: support))
                        }
                    }
                }
            }
        }
        let result = Inspection(changes: changes, workbookURL: workbookURL, workbookSHA256: Self.hash(data), bundleURL: bundleURL.standardizedFileURL, baselineSHA256: Self.hash(baselineData), workbookData: data, baseline: baseline, runtime: parsed.runtime, parsedData: try encoder.encode(parsed), wallTimeSeconds: Date().timeIntervalSince(startedAt))
        try revalidate(result)
        return result
    }

    /// Repeat under the annotation publication lock immediately before apply.
    public func revalidate(_ inspection: Inspection) throws {
        guard Self.hash(try Self.readRegular(inspection.bundleURL.appendingPathComponent(Self.baselinePath))) == inspection.baselineSHA256,
              Self.hash(try Self.readRegular(inspection.workbookURL)) == inspection.workbookSHA256 else { throw reject("Workbook or baseline changed after inspection. Inspect again.") }
        try validateInputs(inspection.baseline, bundleURL: inspection.bundleURL)
    }

    /// Preserve exact imported bytes before annotation publication. A rejected
    /// operation can leave this evidence receipt, but cannot leave partial edits.
    public func preserveEvidence(_ inspection: Inspection) throws -> URL {
        try revalidate(inspection)
        // Resolve existing parents separately: Foundation does not resolve an
        // intermediate symlink when the final UUID leaf does not yet exist.
        _ = try containedURL("artifacts", in: inspection.bundleURL)
        _ = try containedURL("artifacts/workbook-edits", in: inspection.bundleURL)
        let directory = try containedURL("artifacts/workbook-edits/" + UUID().uuidString, in: inspection.bundleURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("input.xlsx")
        try inspection.workbookData.write(to: input, options: .withoutOverwriting)
        try inspection.parsedData.write(to: directory.appendingPathComponent("inspection.json"), options: .withoutOverwriting)
        try Self.readRegular(inspection.bundleURL.appendingPathComponent(Self.baselinePath)).write(to: directory.appendingPathComponent("baseline.json"), options: .withoutOverwriting)
        try Data(Self.readerScript.utf8).write(to: directory.appendingPathComponent("inspect-workbook.py"), options: .withoutOverwriting)
        var sourceInputs: [[String: Any]] = []
        for witness in inspection.baseline.inputs {
            var url = try containedURL(witness.path, in: inspection.bundleURL)
            // These identities are mutable during acceptance/regeneration; keep
            // the exact prior payloads instead of pointing replay at newer bytes.
            if witness.path == GenotypeAnnotationSidecar.filename || witness.path == ONTGenotypeResultBundleManifest.filename {
                let data = try Self.readRegular(url)
                guard Self.hash(data) == witness.sha256 else { throw reject("Source changed before preservation.") }
                url = directory.appendingPathComponent("source-" + url.lastPathComponent)
                try data.write(to: url, options: .withoutOverwriting)
            }
            sourceInputs.append(["path": url.path, "sourcePath": witness.path, "sha256": witness.sha256, "sizeBytes": witness.size])
        }
        let argv = [pythonExecutableURL.path, directory.appendingPathComponent("inspect-workbook.py").path, input.path, directory.appendingPathComponent("replayed-inspection.json").path]
        let receipt: [String: Any] = [
            "workflowName": "Inspect supported genotype workbook edits", "workflowVersion": WorkflowRun.currentAppVersion,
            "toolName": "Lungfish Genome Explorer", "toolVersion": WorkflowRun.currentAppVersion,
            "argv": argv, "runtimeIdentity": ["executable": inspection.runtime.executable, "python": inspection.runtime.python, "openpyxl": inspection.runtime.openpyxl, "platform": inspection.runtime.platform],
            "options": ["schemaVersion": 1, "blankCellsDelete": false, "readOnlyEvidenceRequired": true],
            "inputs": [["path": input.path, "sha256": inspection.workbookSHA256, "sizeBytes": inspection.workbookData.count],
                       ["path": directory.appendingPathComponent("baseline.json").path, "sha256": inspection.baselineSHA256, "sizeBytes": try Self.readRegular(directory.appendingPathComponent("baseline.json")).count]]
                + sourceInputs,
            "outputs": [["path": directory.appendingPathComponent("inspection.json").path, "sha256": Self.hash(inspection.parsedData), "sizeBytes": inspection.parsedData.count]],
            "exitStatus": 0, "wallTimeSeconds": inspection.wallTimeSeconds, "stderr": "", "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("provenance.json"), options: .withoutOverwriting)
        try Self.synchronizeEvidence(at: directory)
        return directory
    }

    public static func synchronizeEvidence(at directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize(); try handle.close()
        }
        // Sync each newly created directory entry before annotation publication
        // can reference this evidence. Parent chain stops at the bundle root.
        var current = directory
        for _ in 0..<4 {
            let fd = Darwin.open(current.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw EditError.rejected("Cannot synchronize workbook evidence.") }
            let result = Darwin.fsync(fd); Darwin.close(fd)
            guard result == 0 else { throw EditError.rejected("Cannot synchronize workbook evidence.") }
            current = current.deletingLastPathComponent()
        }
    }

    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func readRegular(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EditError.rejected("Cannot read a regular file at \(url.path).") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw EditError.rejected("Unsafe file at \(url.path).") }
        return try handle.readToEnd() ?? Data()
    }
    private var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    private func reject(_ message: String) -> EditError { .rejected(message) }
    private func relative(_ url: URL, in bundle: URL) -> String { String(url.standardizedFileURL.path.dropFirst(bundle.standardizedFileURL.path.count + 1)) }
    private func containedURL(_ path: String, in bundle: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw reject("Unsafe bundle path.") }
        let url = bundle.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/") else { throw reject("File escapes the bundle.") }
        return url
    }
    private func witness(_ url: URL, in bundle: URL) throws -> Witness {
        let path = relative(url, in: bundle)
        let data = try Self.readRegular(containedURL(path, in: bundle))
        return Witness(path: path, sha256: Self.hash(data), size: data.count)
    }
    private func sidecarData(in bundle: URL) throws -> Data? { try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(named: GenotypeAnnotationSidecar.filename, inBundleAt: bundle) }
    private func validateInputs(_ baseline: Baseline, bundleURL: URL) throws {
        for input in baseline.inputs {
            let data: Data
            if input.path == GenotypeAnnotationSidecar.filename {
                guard let stored = try sidecarData(in: bundleURL) else { throw reject("Annotation sidecar was removed.") }
                data = stored
            } else { data = try Self.readRegular(containedURL(input.path, in: bundleURL)) }
            guard data.count == input.size, Self.hash(data) == input.sha256 else { throw reject("Source or sidecar revision changed: \(input.path).") }
        }
        if !baseline.inputs.contains(where: { $0.path == GenotypeAnnotationSidecar.filename }), try sidecarData(in: bundleURL) != nil { throw reject("Annotation sidecar appeared after workbook generation.") }
    }
    private func rows(_ values: [[String]]?, sheet: String) throws -> [String: [String: String]] {
        let required: Set<String> = sheet == "Edit Calls"
            ? ["ID", "Sample", "Locus", "Slot", "Effective call", "Baseline call", "Operation", "Value", "Baseline available"]
            : ["ID", "Target", "Reads", "Current review", "Current comment", "Review operation", "Review value", "Comment operation", "Comment value"]
        guard let values, let header = values.first, Set(header) == required, Set(header).count == header.count else { throw reject("Missing, unknown, or duplicate headers in \(sheet).") }
        var result: [String: [String: String]] = [:]
        for row in values.dropFirst() {
            guard row.count == header.count else { throw reject("Ambiguous row in \(sheet).") }
            let record = Dictionary(uniqueKeysWithValues: zip(header, row))
            guard let id = record["ID"], !id.isEmpty, result.updateValue(record, forKey: id) == nil else { throw reject("Missing or duplicate ID in \(sheet).") }
        }
        return result
    }
    private func operation(_ row: [String: String], key: String, value: String) throws -> String? {
        let op = row[key] ?? "", text = row[value] ?? ""
        if op.isEmpty || op == "keep" {
            guard text.isEmpty else { throw reject("Set an explicit operation for \(value).") }
            return nil
        }
        guard op == "set" || op == "clear" else { throw reject("Unknown operation: \(op). Use keep, set, or clear.") }
        guard op == "set" ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : text.isEmpty else { throw reject("Set requires a value; clear requires an empty value.") }
        return op
    }
    private func parse(_ workbook: URL) throws -> Parsed {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-workbook-inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("inspect-workbook.py"), output = directory.appendingPathComponent("inspection.json"), errorURL = directory.appendingPathComponent("stderr.txt")
        try Data().write(to: errorURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        try Data(Self.readerScript.utf8).write(to: script)
        let process = Process(); process.executableURL = pythonExecutableURL
        process.arguments = [script.path, workbook.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errorHandle
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw reject(String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)) }
        return try JSONDecoder().decode(Parsed.self, from: Data(contentsOf: output))
    }
}

// ProvenanceCompatCorpus.swift - Frozen legacy provenance bytes for compatibility tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The corpus holds provenance sidecars exactly as older Lungfish builds wrote
// them (or as today's writers write the shapes that later lanes stop writing),
// with a MANIFEST.tsv that pins every byte by SHA-256. Nothing hands a test a
// tracked path to read through production code: `materialize(_:)` copies one
// case into a fresh temporary `.lungfish` project, and the tests read that copy.
// A case is never edited. A change in behaviour is a change in the facts the
// reader projects from the same frozen bytes (see ProvenanceCompatFacts).

import CryptoKit
import Foundation

/// One frozen sidecar listed in MANIFEST.tsv.
public struct ProvenanceCompatCase: Sendable, Equatable {
    /// Unique, stable name. It names the case folder and the expected facts file.
    public let id: String
    /// Where the bytes live. `cases/<id>/<layout>` for a stored case, or
    /// `repo:<path from the repository root>` for a tracked file that is
    /// referenced in place instead of being duplicated.
    public let path: String
    /// Shape code S1 to S8 from the Phase 2.4 inventory.
    public let shape: String
    /// Filename family code F01 to F45 from the Phase 2.4 inventory.
    public let family: String
    /// Where the bytes came from and every edit made to them.
    public let origin: String
    /// SHA-256 of the file, lowercase hexadecimal.
    public let sha256: String

    public init(id: String, path: String, shape: String, family: String, origin: String, sha256: String) {
        self.id = id
        self.path = path
        self.shape = shape
        self.family = family
        self.origin = origin
        self.sha256 = sha256
    }

    /// True when the manifest points at a tracked file elsewhere in the repository.
    public var isReferencedInPlace: Bool {
        path.hasPrefix(ProvenanceCompatCorpus.inPlacePrefix)
    }

    /// The sidecar's path inside a materialized project. A stored case keeps the
    /// layout it had on disk, so `Analyses/<name>/.lungfish-provenance.json` lands
    /// at the same place under the project. A file referenced in place lands at
    /// the project root.
    public var layoutPath: String {
        if isReferencedInPlace {
            return URL(fileURLWithPath: String(path.dropFirst(ProvenanceCompatCorpus.inPlacePrefix.count)))
                .lastPathComponent
        }
        let prefix = "cases/\(id)/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// What a user would select in the app to see this sidecar: the folder for a
    /// `.lungfish-provenance.json`, the output file for `<file>.lungfish-provenance.json`,
    /// and nothing for any other name.
    public var selectionLayoutPath: String? {
        let layout = layoutPath
        let name = (layout as NSString).lastPathComponent
        let parent = (layout as NSString).deletingLastPathComponent
        if name == ProvenanceCompatCorpus.sidecarFilename {
            return parent
        }
        let suffix = ".lungfish-provenance.json"
        if name.hasSuffix(suffix), name.count > suffix.count {
            let subject = String(name.dropLast(suffix.count))
            return parent.isEmpty ? subject : "\(parent)/\(subject)"
        }
        return nil
    }
}

/// A case copied into a fresh temporary project. Every URL points into the
/// temporary folder. Call `cleanup()` when the test ends.
public struct ProvenanceCompatMaterialized: Sendable {
    public let caseID: String
    /// The `provenance-compat-<UUID>` folder that holds everything. Remove it with `cleanup()`.
    public let temporaryRoot: URL
    /// `<temporaryRoot>/<uuid>/Fixture.lungfish`, the project the sidecar sits in.
    public let projectRoot: URL
    /// The copied sidecar.
    public let sidecar: URL
    /// The item a user would select to find the sidecar, when its name implies one.
    /// For `<file>.lungfish-provenance.json` this URL may name a file that was
    /// not copied.
    public let selection: URL?
    /// Every file copied into the project.
    public let copiedFiles: [URL]

    public func cleanup() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}

public enum ProvenanceCompatCorpusError: Error, LocalizedError, Equatable {
    case malformedManifest(String)
    case unknownCase(String)
    case missingBytes(String)
    case checksumMismatch(id: String, expected: String, actual: String)
    case strayFile(String)
    case orphanExpectedFacts(String)
    case captureNotRequested(String)
    case wouldOverwrite(String)
    case machinePath(id: String, marker: String)
    case accountName(id: String)

    public var errorDescription: String? {
        switch self {
        case .malformedManifest(let reason):
            return "MANIFEST.tsv is malformed: \(reason)"
        case .unknownCase(let id):
            return "The provenance compatibility corpus has no case named \(id)"
        case .missingBytes(let path):
            return "The corpus bytes are missing: \(path)"
        case .checksumMismatch(let id, let expected, let actual):
            return "Corpus case \(id) changed: MANIFEST.tsv pins \(expected) but the bytes hash to \(actual). A case is never edited."
        case .strayFile(let path):
            return "File is not listed in MANIFEST.tsv: \(path)"
        case .orphanExpectedFacts(let path):
            return "Expected facts file has no manifest case: \(path)"
        case .captureNotRequested(let variable):
            return "Refusing to write into the corpus unless \(variable)=1"
        case .wouldOverwrite(let path):
            return "Refusing to overwrite an existing corpus file: \(path)"
        case .machinePath(let id, let marker):
            return "Refusing to freeze case \(id): its bytes hold the machine path marker \(marker). Substitute it and document the substitution."
        case .accountName(let id):
            return "Refusing to freeze case \(id): a user value in its bytes is not \(ProvenanceCompatCorpus.accountPlaceholder). An account name must not enter a committed fixture, so substitute it and document the substitution."
        }
    }
}

public enum ProvenanceCompatCorpus {
    /// The name of a folder-level sidecar.
    public static let sidecarFilename = ".lungfish-provenance.json"
    /// Prefix of a manifest path that points at a tracked file outside the corpus.
    public static let inPlacePrefix = "repo:"
    /// Set to `1` to let a capture test add a new case. The gate never sets it.
    public static let captureCasesVariable = "LUNGFISH_CAPTURE_PROVENANCE_COMPAT"
    /// Set to `1` to let a capture test write missing expected facts. The gate never sets it.
    public static let captureFactsVariable = "LUNGFISH_CAPTURE_PROVENANCE_FACTS"

    /// Path fragments that tie bytes to one Mac or one test run. No corpus file may hold one,
    /// in the plain spelling or the JSON-escaped spelling (`\/`).
    public static let forbiddenPathMarkers: [String] = ["/Users/", "/private/var/folders", "/var/folders", "/tmp"]

    /// What stands in for the capture account's name in a committed fixture. Older builds recorded
    /// the account in a `user` value, and the key stays so the readers still read it.
    public static let accountPlaceholder = "lge-user"

    static let manifestHeader = ["id", "path", "shape", "family", "origin", "sha256"]
    private static let shapeCodes: Set<String> = ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"]

    // MARK: Locations

    /// `Tests/Fixtures/provenance-compat`, found from this file's own path.
    public static var root: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/provenance-compat", isDirectory: true)
    }

    /// The checkout that holds this file.
    public static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LungfishTestSupport
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    public static var manifestURL: URL {
        root.appendingPathComponent("MANIFEST.tsv")
    }

    // MARK: Cases

    /// Every case in MANIFEST.tsv, in manifest order.
    public static func cases() throws -> [ProvenanceCompatCase] {
        try parseManifest(String(decoding: Data(contentsOf: manifestURL), as: UTF8.self))
    }

    /// The case ids, or an empty list when the manifest cannot be read. Parameterized
    /// tests use it for their arguments, and a separate test fails when it is empty.
    public static func caseIDs() -> [String] {
        ((try? cases()) ?? []).map(\.id)
    }

    public static func parseManifest(_ text: String) throws -> [ProvenanceCompatCase] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let header = lines.first, header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == manifestHeader else {
            throw ProvenanceCompatCorpusError.malformedManifest("the header must be \(manifestHeader.joined(separator: " <tab> "))")
        }
        var seen = Set<String>()
        var result: [ProvenanceCompatCase] = []
        for (offset, line) in lines.dropFirst().enumerated() {
            let number = offset + 2
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == manifestHeader.count else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) has \(columns.count) columns, expected \(manifestHeader.count)")
            }
            let item = ProvenanceCompatCase(
                id: columns[0], path: columns[1], shape: columns[2],
                family: columns[3], origin: columns[4], sha256: columns[5]
            )
            guard !item.id.isEmpty, item.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) has an id that is not letters, digits and dashes")
            }
            guard seen.insert(item.id).inserted else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) repeats id \(item.id)")
            }
            guard shapeCodes.contains(item.shape) else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) has shape \(item.shape), expected S1 to S8")
            }
            guard item.family.count == 3, item.family.hasPrefix("F"), item.family.dropFirst().allSatisfy(\.isNumber) else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) has family \(item.family), expected F01 to F45")
            }
            guard !item.origin.isEmpty else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) has no origin")
            }
            guard item.sha256.count == 64, item.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) has a sha256 that is not 64 lowercase hex digits")
            }
            let inPlace = item.path.hasPrefix(inPlacePrefix)
            let storedPrefix = "cases/\(item.id)/"
            guard inPlace || (item.path.hasPrefix(storedPrefix) && item.path.count > storedPrefix.count) else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) path must start with cases/\(item.id)/ or \(inPlacePrefix)")
            }
            guard !item.path.split(separator: "/").contains("..") else {
                throw ProvenanceCompatCorpusError.malformedManifest("line \(number) path climbs out of its folder")
            }
            result.append(item)
        }
        return result
    }

    // MARK: Materializing

    /// Copies one case into `<temp>/provenance-compat-<UUID>/<uuid>/Fixture.lungfish/<layout>`.
    ///
    /// The project is nested two levels below the temporary folder so that a finder
    /// walking up five directories cannot reach a sidecar another test left in the
    /// system temporary folder. The copy gets a fixed modification time, so a
    /// reader that falls back to the file's date reads the same value everywhere.
    /// For a `<file>.lungfish-provenance.json` the file it describes is copied
    /// beside it when it exists next to the tracked sidecar.
    public static func materialize(_ id: String) throws -> ProvenanceCompatMaterialized {
        guard let item = try cases().first(where: { $0.id == id }) else {
            throw ProvenanceCompatCorpusError.unknownCase(id)
        }
        let source = sourceURL(of: item)
        guard let bytes = try? Data(contentsOf: source) else {
            throw ProvenanceCompatCorpusError.missingBytes(item.path)
        }
        let actual = sha256Hex(bytes)
        guard actual == item.sha256 else {
            throw ProvenanceCompatCorpusError.checksumMismatch(id: id, expected: item.sha256, actual: actual)
        }

        let fileManager = FileManager.default
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-compat")
        do {
            let projectRoot = temporaryRoot
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("Fixture.lungfish", isDirectory: true)
            let sidecar = projectRoot.appendingPathComponent(item.layoutPath)
            try fileManager.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: sidecar)
            var copied = [sidecar]

            if item.isReferencedInPlace, let subject = subjectName(of: item) {
                let subjectSource = source.deletingLastPathComponent().appendingPathComponent(subject)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: subjectSource.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    let subjectCopy = sidecar.deletingLastPathComponent().appendingPathComponent(subject)
                    try Data(contentsOf: subjectSource).write(to: subjectCopy)
                    copied.append(subjectCopy)
                }
            }
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            for url in copied {
                try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
            }

            let selection = item.selectionLayoutPath.map {
                $0.isEmpty ? projectRoot : projectRoot.appendingPathComponent($0)
            }
            return ProvenanceCompatMaterialized(
                caseID: id,
                temporaryRoot: temporaryRoot,
                projectRoot: projectRoot,
                sidecar: sidecar,
                selection: selection,
                copiedFiles: copied
            )
        } catch {
            TestTempDirectory.cleanup(temporaryRoot)
            throw error
        }
    }

    private static func subjectName(of item: ProvenanceCompatCase) -> String? {
        let suffix = ".lungfish-provenance.json"
        let name = (item.layoutPath as NSString).lastPathComponent
        guard name.hasSuffix(suffix), name.count > suffix.count else { return nil }
        return String(name.dropLast(suffix.count))
    }

    private static func sourceURL(of item: ProvenanceCompatCase) -> URL {
        if item.isReferencedInPlace {
            return repositoryRoot.appendingPathComponent(String(item.path.dropFirst(inPlacePrefix.count)))
        }
        return root.appendingPathComponent(item.path)
    }

    // MARK: Verifying

    /// Fails when a case's bytes no longer match MANIFEST.tsv, when a file under
    /// `cases/` is not listed, or when an expected facts file has no case. It
    /// reads only `cases/` and `expected/`, so other folders (a demo archive,
    /// for example) can sit beside them.
    public static func verifyManifest() throws {
        let items = try cases()
        for item in items {
            guard let bytes = try? Data(contentsOf: sourceURL(of: item)) else {
                throw ProvenanceCompatCorpusError.missingBytes(item.path)
            }
            let actual = sha256Hex(bytes)
            guard actual == item.sha256 else {
                throw ProvenanceCompatCorpusError.checksumMismatch(id: item.id, expected: item.sha256, actual: actual)
            }
        }
        let listed = Set(items.filter { !$0.isReferencedInPlace }.map(\.path))
        for file in try regularFiles(under: root.appendingPathComponent("cases", isDirectory: true)) {
            let relative = relativePath(of: file, under: root)
            guard listed.contains(relative) else {
                throw ProvenanceCompatCorpusError.strayFile(relative)
            }
        }
        let ids = Set(items.map(\.id))
        for file in try regularFiles(under: root.appendingPathComponent("expected", isDirectory: true)) {
            let name = file.lastPathComponent
            let suffix = ".facts.json"
            guard name.hasSuffix(suffix), ids.contains(String(name.dropLast(suffix.count))) else {
                throw ProvenanceCompatCorpusError.orphanExpectedFacts(relativePath(of: file, under: root))
            }
        }
    }

    // MARK: Expected facts

    public static func expectedFactsURL(for id: String) -> URL {
        root.appendingPathComponent("expected/\(id).facts.json")
    }

    /// The reviewed facts for one case, or nil when none has been captured yet.
    public static func expectedFactsData(for id: String) -> Data? {
        try? Data(contentsOf: expectedFactsURL(for: id))
    }

    // MARK: Capture (never run by the gate)

    public static var captureCasesRequested: Bool {
        ProcessInfo.processInfo.environment[captureCasesVariable] == "1"
    }

    public static var captureFactsRequested: Bool {
        ProcessInfo.processInfo.environment[captureFactsVariable] == "1"
    }

    /// Adds a case captured from a current writer: writes the bytes under
    /// `cases/<id>/<layoutPath>` and appends the manifest row. It refuses to run
    /// without `LUNGFISH_CAPTURE_PROVENANCE_COMPAT=1` and never replaces anything.
    @discardableResult
    public static func addCapturedCase(
        id: String,
        layoutPath: String,
        shape: String,
        family: String,
        origin: String,
        bytes: Data
    ) throws -> ProvenanceCompatCase {
        guard captureCasesRequested else {
            throw ProvenanceCompatCorpusError.captureNotRequested(captureCasesVariable)
        }
        let item = ProvenanceCompatCase(
            id: id,
            path: "cases/\(id)/\(layoutPath)",
            shape: shape,
            family: family,
            origin: origin,
            sha256: sha256Hex(bytes)
        )
        if let marker = machinePathMarkers(in: bytes).first {
            throw ProvenanceCompatCorpusError.machinePath(id: id, marker: marker)
        }
        if !accountNameFindings(in: bytes).isEmpty {
            throw ProvenanceCompatCorpusError.accountName(id: id)
        }
        let existing = try cases()
        let destination = root.appendingPathComponent(item.path)
        let caseFolder = root.appendingPathComponent("cases/\(id)", isDirectory: true)
        guard !existing.contains(where: { $0.id == id }), !FileManager.default.fileExists(atPath: caseFolder.path) else {
            throw ProvenanceCompatCorpusError.wouldOverwrite("cases/\(id)")
        }
        // Validate the new row before touching the disk.
        let row = [item.id, item.path, item.shape, item.family, item.origin, item.sha256].joined(separator: "\t")
        var manifest = try manifestText()
        if !manifest.hasSuffix("\n") { manifest += "\n" }
        let updatedManifest = manifest + row + "\n"
        _ = try parseManifest(updatedManifest)

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .withoutOverwriting)
        try Data(updatedManifest.utf8).write(to: manifestURL, options: .atomic)
        return item
    }

    /// Writes the expected facts for a case. It refuses to run without
    /// `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1` and never replaces a file.
    public static func writeExpectedFacts(_ data: Data, for id: String) throws {
        guard captureFactsRequested else {
            throw ProvenanceCompatCorpusError.captureNotRequested(captureFactsVariable)
        }
        guard try cases().contains(where: { $0.id == id }) else {
            throw ProvenanceCompatCorpusError.unknownCase(id)
        }
        let destination = expectedFactsURL(for: id)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProvenanceCompatCorpusError.wouldOverwrite("expected/\(id).facts.json")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .withoutOverwriting)
    }

    // MARK: Helpers

    /// The forbidden path markers `data` holds, in either spelling.
    public static func machinePathMarkers(in data: Data) -> [String] {
        forbiddenPathMarkers.filter { marker in
            let escaped = marker.replacingOccurrences(of: "/", with: "\\/")
            return data.range(of: Data(marker.utf8)) != nil || data.range(of: Data(escaped.utf8)) != nil
        }
    }

    /// The values of `user` keys in `data` that are not the placeholder, which would be an account
    /// name. It reads the key in any JSON spacing, so `"user" : "name"` and `"user":"name"` both count.
    public static func accountNameFindings(in data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        guard let expression = try? NSRegularExpression(pattern: #""user"\s*:\s*"((?:[^"\\]|\\.)*)""#) else {
            return []
        }
        var values: [String] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range])
            if value != accountPlaceholder, !values.contains(value) { values.append(value) }
        }
        return values
    }

    private static func manifestText() throws -> String {
        String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func regularFiles(under directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return path }
        return String(path.dropFirst(basePath.count + 1))
    }
}

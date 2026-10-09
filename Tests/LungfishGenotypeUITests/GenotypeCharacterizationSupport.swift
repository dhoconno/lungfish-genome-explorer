// GenotypeCharacterizationSupport.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Canonical bytes, masks and the expected-file store behind the genotype GUI
// characterization tests (Phase 2.3, REVIEW.md R6). The GUI Excel export never
// runs lungfish-cli, so the CLI goldens cannot see the capture code in
// GenotypeResultViewController. These files are the byte-level oracle for it.
//
// One encoder turns any captured value into bytes. Non-Codable values are
// walked through Mirror, so a stored property added later shows up and fails
// the compare instead of being skipped. Codable values go through JSONEncoder
// with sorted keys. Only three masks exist, each with a guard, and every
// expected file starts with a normalization object that lists them.
//
// Compare mode (the default) never writes into the checkout. Capture mode
// (LUNGFISH_CAPTURE_GENOTYPE_GUI_GOLDENS=1) builds a scenario twice from fresh
// temp roots and writes only when both builds agree byte for byte, the rule
// the tool goldens follow in Tests/LungfishWorkflowTests/ToolGoldens.

import CryptoKit
import Foundation
import LungfishCore
import XCTest

// MARK: - Masks

/// One mask the canonical form applies. The three masks are the only
/// normalization the expected files carry, so a new one is a reviewed diff.
struct GenotypeCharacterizationMask: Sendable {
    let token: String
    let applies: String
    let guardRule: String

    static let root = GenotypeCharacterizationMask(
        token: "<ROOT>",
        applies: "The test's own temp root in plain paths and file URLs, in the /var and the /private/var spelling",
        guardRule: "None, it is the fixture root"
    )

    static let generatedAt = GenotypeCharacterizationMask(
        token: "<GENERATED_AT>",
        applies: "The top-level generatedAt of the frozen Excel capture",
        guardRule: "Parses as ISO 8601 UTC to the second and lies inside the test's time window"
    )

    static let sha256 = GenotypeCharacterizationMask(
        token: "<SHA256>",
        applies: "A sourceRevision digest of the frozen Excel capture whose key names a captured input",
        guardRule: "Equals the SHA-256 of that input's raw bytes, which are decoded and compared in full"
    )

    static let all: [GenotypeCharacterizationMask] = [root, generatedAt, sha256]
}

enum GenotypeCharacterizationCanonicalError: Error, CustomStringConvertible {
    case capturedInputIsNotBase64(String)
    case digestMismatch(input: String, recorded: String, computed: String)
    case generatedAtUnparseable(String)
    case generatedAtOutsideWindow(String, ClosedRange<Date>)
    case generatedAtWithoutWindow(String)
    case notJSONSerializable(String)

    var description: String {
        switch self {
        case .capturedInputIsNotBase64(let name):
            return "captured input \(name) is not base64"
        case let .digestMismatch(input, recorded, computed):
            return "sourceRevision[\(input)] is \(recorded) but the input's bytes hash to \(computed)"
        case .generatedAtUnparseable(let value):
            return "generatedAt \(value) is not an ISO 8601 UTC date-time to the second"
        case let .generatedAtOutsideWindow(value, window):
            return "generatedAt \(value) lies outside the test's window \(window.lowerBound) to \(window.upperBound)"
        case .generatedAtWithoutWindow(let value):
            return "generatedAt \(value) was found but the canonicalizer has no time window"
        case .notJSONSerializable(let description):
            return "the canonical tree is not JSON serializable: \(description)"
        }
    }
}

// MARK: - Canonical form

/// Turns a captured value into canonical bytes. Build one per capture with the
/// temp root of the scenario and, for a frozen Excel capture, the window the
/// capture ran in.
struct GenotypeCharacterizationCanonicalizer: Sendable {
    private struct MaskCounts {
        var root = 0
        var generatedAt = 0
        var sha256 = 0
    }

    /// Root spellings, longest first, so /private/var is replaced before /var.
    let rootSpellings: [String]
    let generatedAtWindow: ClosedRange<Date>?

    init(root: URL, generatedAtWindow: ClosedRange<Date>? = nil) {
        rootSpellings = Self.spellings(of: root)
        self.generatedAtWindow = generatedAtWindow
    }

    /// Every spelling of `root` a production path may carry.
    static func spellings(of root: URL) -> [String] {
        var spellings = Set<String>()
        for path in [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path] {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !trimmed.isEmpty else { continue }
            spellings.insert(trimmed)
            let privatePrefix = "/private"
            if trimmed.hasPrefix(privatePrefix + "/var/") {
                spellings.insert(String(trimmed.dropFirst(privatePrefix.count)))
            } else if trimmed.hasPrefix("/var/") {
                spellings.insert(privatePrefix + trimmed)
            }
        }
        return spellings.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
        }
    }

    /// A text with every root spelling replaced by the root token.
    func maskRoot(in text: String) -> String {
        var counts = MaskCounts()
        return maskRoot(in: text, counts: &counts)
    }

    /// The canonical bytes of `value`, prefixed by the normalization object.
    func encode(_ value: Any) throws -> Data {
        var counts = MaskCounts()
        let tree = try canonicalTree(value, counts: &counts)
        let document: [String: Any] = [
            "normalization": [
                "masks": GenotypeCharacterizationMask.all.map { mask in
                    [
                        "token": mask.token,
                        "applies": mask.applies,
                        "guard": mask.guardRule,
                        "count": count(for: mask, in: counts),
                    ] as [String: Any]
                },
            ],
            "value": tree,
        ]
        guard JSONSerialization.isValidJSONObject(document) else {
            throw GenotypeCharacterizationCanonicalError.notJSONSerializable(String(describing: type(of: value)))
        }
        var data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private func count(for mask: GenotypeCharacterizationMask, in counts: MaskCounts) -> Int {
        switch mask.token {
        case GenotypeCharacterizationMask.root.token: return counts.root
        case GenotypeCharacterizationMask.generatedAt.token: return counts.generatedAt
        default: return counts.sha256
        }
    }

    private func maskRoot(in text: String, counts: inout MaskCounts) -> String {
        var masked = text
        for spelling in rootSpellings {
            let pieces = masked.components(separatedBy: spelling)
            guard pieces.count > 1 else { continue }
            counts.root += pieces.count - 1
            masked = pieces.joined(separator: GenotypeCharacterizationMask.root.token)
        }
        return masked
    }

    // MARK: Walk

    private func canonicalTree(_ value: Any, counts: inout MaskCounts) throws -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return NSNull() }
            return try canonicalTree(wrapped.value, counts: &counts)
        }
        if value is NSNull { return NSNull() }
        if let string = value as? String { return maskRoot(in: string, counts: &counts) }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number }
        if let data = value as? Data { return try decodedData(data, counts: &counts) }
        if let url = value as? URL {
            return maskRoot(in: url.isFileURL ? url.path : url.absoluteString, counts: &counts)
        }
        if let color = value as? AnnotationColor { return Self.hex(color) }
        if let date = value as? Date { return Self.iso8601.string(from: date) }
        if let encodable = value as? any Encodable {
            return try normalizedJSON(try Self.jsonObject(encoding: encodable), counts: &counts)
        }
        switch mirror.displayStyle {
        case .struct, .class:
            var object: [String: Any] = [:]
            for child in mirror.children {
                let label = child.label ?? "_\(object.count)"
                object[maskRoot(in: label, counts: &counts)] = try canonicalTree(child.value, counts: &counts)
            }
            return object
        case .enum:
            guard let payload = mirror.children.first else { return String(describing: value) }
            return [payload.label ?? String(describing: value): try canonicalTree(payload.value, counts: &counts)]
        case .tuple, .collection:
            return try mirror.children.map { try canonicalTree($0.value, counts: &counts) }
        case .set:
            return try sortedByCanonicalText(mirror.children.map { try canonicalTree($0.value, counts: &counts) })
        case .dictionary:
            return try canonicalDictionary(mirror, counts: &counts)
        default:
            return maskRoot(in: String(describing: value), counts: &counts)
        }
    }

    private func canonicalDictionary(_ mirror: Mirror, counts: inout MaskCounts) throws -> Any {
        var pairs: [(key: Any, value: Any)] = []
        for entry in mirror.children {
            let parts = Array(Mirror(reflecting: entry.value).children)
            guard parts.count == 2 else { continue }
            pairs.append((try canonicalTree(parts[0].value, counts: &counts), try canonicalTree(parts[1].value, counts: &counts)))
        }
        if pairs.allSatisfy({ $0.key is String }) {
            var object: [String: Any] = [:]
            for pair in pairs { object[pair.key as! String] = pair.value }
            return object
        }
        let keyed = try pairs.map { pair -> (text: String, pair: [String: Any]) in
            (try Self.canonicalText(pair.key), ["key": pair.key, "value": pair.value])
        }
        return keyed.sorted { $0.text < $1.text }.map(\.pair)
    }

    private func sortedByCanonicalText(_ trees: [Any]) throws -> [Any] {
        try trees.map { (text: try Self.canonicalText($0), tree: $0) }
            .sorted { $0.text < $1.text }
            .map(\.tree)
    }

    private static func canonicalText(_ tree: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [tree],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Data and Codable payloads

    /// Decoded JSON when the bytes parse, base64 otherwise. A frozen Excel
    /// capture is recognized and its masks applied.
    private func decodedData(_ data: Data, counts: inout MaskCounts) throws -> Any {
        guard let tree = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data.base64EncodedString()
        }
        return try normalizedJSON(tree, counts: &counts)
    }

    private func normalizedJSON(_ tree: Any, counts: inout MaskCounts) throws -> Any {
        if let object = tree as? [String: Any] {
            if Self.isFrozenCapture(object) {
                return try normalizedFrozenCapture(object, counts: &counts)
            }
            var normalized: [String: Any] = [:]
            for (key, value) in object {
                normalized[maskRoot(in: key, counts: &counts)] = try normalizedJSON(value, counts: &counts)
            }
            return normalized
        }
        if let array = tree as? [Any] {
            return try array.map { try normalizedJSON($0, counts: &counts) }
        }
        if let string = tree as? String {
            return maskRoot(in: string, counts: &counts)
        }
        return tree
    }

    /// The frozen capture is the one object that carries retained inputs, their
    /// digests and a capture time (GenotypeWorkbookPresentation.Snapshot).
    private static func isFrozenCapture(_ object: [String: Any]) -> Bool {
        object["capturedScientificInputs"] is [String: Any]
            && object["sourceRevision"] is [String: Any]
            && object["generatedAt"] is String
    }

    private func normalizedFrozenCapture(_ object: [String: Any], counts: inout MaskCounts) throws -> Any {
        var capture = object
        let inputs = object["capturedScientificInputs"] as? [String: String] ?? [:]
        var revision = object["sourceRevision"] as? [String: String] ?? [:]
        var decodedInputs: [String: Any] = [:]
        for name in inputs.keys.sorted() {
            guard let raw = Data(base64Encoded: inputs[name] ?? "") else {
                throw GenotypeCharacterizationCanonicalError.capturedInputIsNotBase64(name)
            }
            let computed = Self.sha256Hex(raw)
            let recorded = revision[name] ?? ""
            guard recorded == computed else {
                throw GenotypeCharacterizationCanonicalError.digestMismatch(input: name, recorded: recorded, computed: computed)
            }
            revision[name] = GenotypeCharacterizationMask.sha256.token
            counts.sha256 += 1
            decodedInputs[name] = try decodedData(raw, counts: &counts)
        }
        capture["capturedScientificInputs"] = decodedInputs
        var maskedRevision: [String: Any] = [:]
        for (key, value) in revision {
            maskedRevision[key] = maskRoot(in: value, counts: &counts)
        }
        capture["sourceRevision"] = maskedRevision
        let generatedAt = object["generatedAt"] as? String ?? ""
        guard let date = Self.iso8601.date(from: generatedAt) else {
            throw GenotypeCharacterizationCanonicalError.generatedAtUnparseable(generatedAt)
        }
        guard let window = generatedAtWindow else {
            throw GenotypeCharacterizationCanonicalError.generatedAtWithoutWindow(generatedAt)
        }
        guard window.contains(date) else {
            throw GenotypeCharacterizationCanonicalError.generatedAtOutsideWindow(generatedAt, window)
        }
        capture["generatedAt"] = GenotypeCharacterizationMask.generatedAt.token
        counts.generatedAt += 1
        var normalized: [String: Any] = [:]
        for (key, value) in capture {
            normalized[key] = key == "capturedScientificInputs" || key == "sourceRevision" || key == "generatedAt"
                ? value
                : try normalizedJSON(value, counts: &counts)
        }
        return normalized
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    private static func jsonObject(encoding value: any Encodable) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(AnyEncodable(value: value))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Fixed spellings

    /// `#RRGGBBAA` with 8-bit channels, so no float text reaches a file.
    static func hex(_ color: AnnotationColor) -> String {
        func channel(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X%02X",
            channel(color.red), channel(color.green), channel(color.blue), channel(color.alpha)
        )
    }

    /// A fresh formatter each time, since the formatter type is not Sendable.
    static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A window that admits a `generatedAt` truncated to the second.
    static func window(from start: Date, to end: Date) -> ClosedRange<Date> {
        let floored = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
        return floored...max(floored, end)
    }
}

// MARK: - Expected files

/// The committed expected files under Tests/Fixtures/golden/genotype-gui.
enum GenotypeCharacterizationExpectedStore {
    static let captureEnvironmentVariable = "LUNGFISH_CAPTURE_GENOTYPE_GUI_GOLDENS"
    static let testFilter = #"LungfishGenotypeUITests\.GenotypeExportCharacterizationTests"#

    static var isCaptureMode: Bool {
        ProcessInfo.processInfo.environment[captureEnvironmentVariable] == "1"
    }

    /// Found through this file's own path, so Package.swift needs no resource entry.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LungfishGenotypeUITests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/golden/genotype-gui", isDirectory: true)
    }

    static func url(for name: String) -> URL {
        root.appendingPathComponent(name)
    }

    static var captureCommand: String {
        "\(captureEnvironmentVariable)=1 swift test --skip-update --filter '\(testFilter)'"
    }

    /// Compare mode builds once and checks every named file against the
    /// checkout. Capture mode builds twice, refuses to write unless both
    /// builds agree byte for byte, then writes every file.
    @MainActor
    static func verify(
        _ build: () throws -> [String: Data],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if isCaptureMode {
            let first = try build()
            let second = try build()
            for name in Set(first.keys).union(second.keys).sorted() {
                guard let lhs = first[name], let rhs = second[name], lhs == rhs else {
                    XCTFail(
                        "Two fresh builds of \(name) differ, so nothing was written.\n"
                            + differences(expected: first[name] ?? Data(), actual: second[name] ?? Data()),
                        file: file, line: line
                    )
                    return
                }
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in first.keys.sorted() {
                try first[name]?.write(to: url(for: name), options: .atomic)
            }
            return
        }
        let actual = try build()
        for name in actual.keys.sorted() {
            let expectedURL = url(for: name)
            guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                XCTFail(
                    "No expected file at \(expectedURL.path). Capture it on known-good code with\n\(captureCommand)",
                    file: file, line: line
                )
                continue
            }
            let expected = try Data(contentsOf: expectedURL)
            guard let bytes = actual[name], bytes != expected else { continue }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-genotype-gui-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let actualURL = scratch.appendingPathComponent(name)
            try bytes.write(to: actualURL)
            XCTFail(
                "\(name) differs from the committed expected file.\n"
                    + "Actual bytes were written to \(actualURL.path)\n"
                    + "Expected \(expectedURL.path)\n"
                    + differences(expected: expected, actual: bytes),
                file: file, line: line
            )
        }
    }

    /// The first differing lines, numbered, with the expected line marked
    /// with a minus and the actual line with a plus.
    static func differences(expected: Data, actual: Data, limit: Int = 12) -> String {
        let expectedLines = (String(data: expected, encoding: .utf8) ?? "").components(separatedBy: "\n")
        let actualLines = (String(data: actual, encoding: .utf8) ?? "").components(separatedBy: "\n")
        var report: [String] = []
        var reported = 0
        for index in 0..<max(expectedLines.count, actualLines.count) where reported < limit {
            let lhs = index < expectedLines.count ? expectedLines[index] : nil
            let rhs = index < actualLines.count ? actualLines[index] : nil
            guard lhs != rhs else { continue }
            report.append("line \(index + 1)")
            report.append("- " + (lhs ?? "<no line>"))
            report.append("+ " + (rhs ?? "<no line>"))
            reported += 1
        }
        if expectedLines.count != actualLines.count {
            report.append("expected \(expectedLines.count) lines, actual \(actualLines.count) lines")
        }
        return report.joined(separator: "\n")
    }
}

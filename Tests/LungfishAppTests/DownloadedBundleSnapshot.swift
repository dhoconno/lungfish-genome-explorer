// DownloadedBundleSnapshot.swift - A text snapshot of a reference bundle built from a download
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// A text snapshot of a reference bundle that a download builds, for pins that compare one bundle
/// before and after a change of code home. It keeps what a run repeats byte for byte and leaves out
/// what it cannot repeat: dates, wall times, tool versions and paths, the host argv, scratch
/// folders, and the bytes of bgzip and SQLite output, which follow the tool and library build. The
/// decompressed FASTA, the FASTA index, every annotation row and every provenance step stay in.
enum DownloadedBundleSnapshot {

    /// The snapshot of `bundle`, with each `(from, to)` replacement applied to the whole text.
    static func text(of bundle: URL, replacing replacements: [(String, String)]) async throws -> String {
        var lines = ["bundle \(bundle.lastPathComponent)"]
        let files = try regularFiles(in: bundle)
        for path in files {
            lines += try await fileLines(path, in: bundle)
        }
        lines += try manifestLines(bundle)
        for path in files where path.hasSuffix(".db") {
            lines += try annotationLines(path, in: bundle)
        }
        if let envelope = ProvenanceRecorder.loadEnvelope(from: bundle) {
            lines += provenanceLines(envelope)
        } else {
            lines.append("provenance none")
        }
        var text = lines.joined(separator: "\n")
        for (from, to) in replacements where !from.isEmpty {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.reversed().drop(while: { $0 == " " }).reversed()) }
            .joined(separator: "\n")
    }

    /// The replacements for a bundle written into `directory`, under both path spellings.
    static func directoryReplacements(_ directory: URL, as name: String) -> [(String, String)] {
        let path = directory.standardizedFileURL.path
        let resolved = directory.resolvingSymlinksInPath().path
        return [(resolved, name), (path, name)]
    }

    /// Writes `text` to `$LUNGFISH_PIN_SNAPSHOT_DIR/<name>.txt` when that variable is set, so a pin
    /// can be recorded at its base.
    static func recordIfAsked(_ text: String, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LUNGFISH_PIN_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).txt")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((text + "\n").utf8).write(to: url)
    }

    // MARK: - Parts

    private static func regularFiles(in bundle: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: bundle.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        var paths: [String] = []
        while let relativePath = enumerator.nextObject() as? String {
            let url = bundle.appendingPathComponent(relativePath)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                paths.append(relativePath)
            }
        }
        return paths.sorted()
    }

    private static func fileLines(_ path: String, in bundle: URL) async throws -> [String] {
        let url = bundle.appendingPathComponent(path)
        if path == "manifest.json" { return ["file \(path) manifest"] }
        if path.hasSuffix(".db") { return ["file \(path) sqlite"] }
        if path.contains("provenance") { return ["file \(path) provenance"] }
        if path.hasSuffix(".gzi") { return ["file \(path) bgzf-index"] }
        if path.hasSuffix(".gz") {
            return ["file \(path) gzip content-sha256=\(try await decompressedSHA256(url))"]
        }
        if path.hasSuffix(".fai") {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rows = text.split(whereSeparator: \.isNewline).map {
                "  fai " + $0.replacingOccurrences(of: "\t", with: " ")
            }
            return ["file \(path) fasta-index"] + rows
        }
        return ["file \(path) sha256=\(try ProvenanceFileHasher.sha256(of: url))"]
    }

    private static func decompressedSHA256(_ url: URL) async throws -> String {
        var hasher = SHA256()
        for try await line in try GzipInputStream(url: url).lines() {
            hasher.update(data: Data((line + "\n").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func manifestLines(_ bundle: URL) throws -> [String] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let object = repeatable(try JSONSerialization.jsonObject(with: data))
        let canonical = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: canonical, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "manifest " + $0 }
    }

    /// Drops every key whose name holds "date", since a build stamps its clock there, and writes
    /// `<uuid>` for each UUID, since a metadata group and item draw a new one each build.
    private static func repeatable(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary
                .filter { !$0.key.lowercased().contains("date") }
                .mapValues(repeatable)
        }
        if let array = object as? [Any] { return array.map(repeatable) }
        if let text = object as? String, UUID(uuidString: text) != nil { return "<uuid>" }
        return object
    }

    private static func annotationLines(_ path: String, in bundle: URL) throws -> [String] {
        let database = try AnnotationDatabase(url: bundle.appendingPathComponent(path))
        let rows = database.query(nameFilter: "", types: [], limit: 5000).map { record in
            [
                "annotation", path, record.chromosome, String(record.start), String(record.end),
                record.strand, record.type, record.name,
                "blocks=\(record.blockCount.map(String.init) ?? "-")/\(record.blockSizes ?? "-")/\(record.blockStarts ?? "-")",
                "gene=\(record.geneName ?? "-")",
                "attributes=\(record.attributes ?? "-")",
            ].joined(separator: " ")
        }
        return ["annotations \(path) total=\(database.totalCount())"] + rows.sorted()
    }

    private static func provenanceLines(_ envelope: ProvenanceEnvelope) -> [String] {
        var lines = ["provenance workflow \(envelope.workflowName) exit \(envelope.exitStatus.map(String.init) ?? "-")"]
        lines.append("provenance stderr \(escaped(envelope.stderr ?? ""))")
        let options = envelope.options
        let keys = Set(options.explicit.keys).union(options.defaults.keys).union(options.resolvedDefaults.keys)
        for key in keys.sorted() {
            lines.append("provenance option \(key) explicit=\(render(options.explicit[key]))"
                + " default=\(render(options.defaults[key])) resolved=\(render(options.resolvedDefaults[key]))")
        }
        for (index, step) in envelope.steps.enumerated() {
            lines.append("provenance step \(index) \(step.toolName) exit \(step.exitStatus.map(String.init) ?? "-")")
            if step.argv.isEmpty {
                lines.append("  command \(step.reproducibleCommand)")
            } else if ["bgzip", "samtools"].contains(step.toolName) {
                // The executable's folder and bgzip's thread count (-@) follow the machine.
                var argv = [URL(fileURLWithPath: step.argv[0]).lastPathComponent]
                for (index, argument) in step.argv.enumerated().dropFirst() {
                    argv.append(step.argv[index - 1] == "-@" ? "<threads>" : argument)
                }
                lines.append("  argv \(argv.joined(separator: " "))")
            } else {
                lines.append("  argv host")
            }
            for key in step.resolvedOptions.keys.sorted() {
                lines.append("  option \(key)=\(render(step.resolvedOptions[key]))")
            }
            lines += step.inputs.map { "  in \(describe($0))" }
            lines += step.outputs.map { "  out \(describe($0))" }
            if let stderr = step.stderr, !stderr.isEmpty { lines.append("  stderr \(escaped(stderr))") }
        }
        lines += envelope.outputs.map { "provenance output \(describe($0))" }.sorted()
        return lines
    }

    private static func describe(_ file: ProvenanceFileDescriptor) -> String {
        let stable = !(file.path.hasSuffix(".db") || file.path.hasSuffix(".gz") || file.path.hasSuffix(".gzi")
            || file.path.hasSuffix("manifest.json") || file.path.contains("provenance"))
        let digest = stable ? (file.checksumSHA256 ?? "-") : "build-dependent"
        return "\(file.path) sha256=\(digest)"
    }

    private static func render(_ value: ParameterValue?) -> String {
        guard let value else { return "-" }
        switch value {
        case .string(let text): return "\"\(escaped(text))\""
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        case .boolean(let flag): return String(flag)
        case .file(let url): return "file:\(url.path)"
        default: return "\(value)"
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n")
    }
}

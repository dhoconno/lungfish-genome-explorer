// ReferenceBundleMergePinConformanceTests.swift - What the reference bundle merge writes today, pinned before it moves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M1 (BIO 4). The sidebar's Merge into New Bundle runs `ReferenceBundleMergeService`
// in the app. Lane A49 moves the service down to Workflow, then runs it behind `bundle merge`. This pin
// merges two fixture bundles, each with a sequence and a gene track, and keeps the merged bundle's file
// list, its decompressed genome, its manifest and its provenance record as one text, with the times,
// sizes, digests, tool versions, random identifiers and the test folder taken out. The move and the
// command must leave that text as it is. It also prints the wall time of one merge.
//
// It runs the managed bgzip and samtools faidx, so its name ends in Conformance, which keeps it out of the
// unit tier, and it skips without the tools unless `LUNGFISH_REQUIRE_TOOLS=1`. To capture the text again
// set `LUNGFISH_RECAPTURE_REFERENCE_MERGE=1`, which rewrites `ReferenceBundleMergePinExpected.swift`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
@testable import LungfishOperations
@testable import LungfishWorkflow
import LungfishTestSupport

/// Two source bundles for a merge, the same ones for every test of lane A49.
enum ReferenceMergeFixture {
    /// A reference bundle named `name` in `project`, with one sequence `sequence` of `bases`, a plain FASTA with
    /// its index, and one gene track of one gene over the first half of the sequence.
    static func writeSource(
        named name: String, sequence: String, bases: String, gene: String, in project: URL, inputs: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundle = project.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        for folder in ["genome", "annotations"] {
            try fileManager.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: inputs, withIntermediateDirectories: true)
        try ">\(sequence)\n\(bases)\n".write(
            to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8
        )
        let offset = sequence.count + 2
        try "\(sequence)\t\(bases.count)\t\(offset)\t\(bases.count)\t\(bases.count + 1)\n".write(
            to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        let bed = inputs.appendingPathComponent("\(name).bed")
        let end = bases.count / 2
        try "\(sequence)\t0\t\(end)\t\(gene)\t0\t+\t0\t\(end)\t0\t1\t\(end),\t0,\tgene\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        let count = try AnnotationDatabase.createFromBED(
            bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db")
        )
        try BundleManifest(
            formatVersion: "1.0",
            name: name,
            identifier: "org.lungfish.tests.reference-merge.\(name.lowercased())",
            source: SourceInfo(organism: "Test organism \(name)", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(bases.count),
                chromosomes: [ChromosomeInfo(
                    name: sequence, length: Int64(bases.count), offset: Int64(offset),
                    lineBases: bases.count, lineWidth: bases.count + 1
                )]
            ),
            annotations: [AnnotationTrackInfo(
                id: "genes", name: "Genes \(name)", path: "annotations/genes.db", databasePath: "annotations/genes.db",
                annotationType: .gene, featureCount: count
            )]
        ).save(to: bundle)
        return bundle
    }
}

@MainActor
final class ReferenceBundleMergePinConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "reference-merge-pin")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testTwoFixtureBundlesMergeToThePinnedBundleAndRecord() async throws {
        try await requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = try ReferenceMergeFixture.writeSource(
            named: "Alpha", sequence: "chrA", bases: "ACGTACGTACGTACGTACGT", gene: "geneA", in: project, inputs: inputs
        )
        let second = try ReferenceMergeFixture.writeSource(
            named: "Beta", sequence: "chrB", bases: "TTGGCCAATTGGCCAATTGG", gene: "geneB", in: project, inputs: inputs
        )

        var merged: URL?
        let wall = try await ContinuousClock().measure {
            merged = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [first, second],
                outputDirectory: project,
                bundleName: "Merged Pin",
                provenanceWriter: .live
            )
        }
        print("reference-merge-pin wall time of one merge of two bundles: \(wall)")
        XCTAssertLessThan(wall, .seconds(120), "one merge of two small bundles")

        let bundle = try XCTUnwrap(merged)
        let actual = try await Self.snapshot(of: bundle, root: root)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_REFERENCE_MERGE"] == "1" {
            try Self.writeExpected(actual)
            return
        }
        XCTAssertEqual(actual, ReferenceBundleMergePinExpected.twoBundles)
    }

    // MARK: - The snapshot

    /// The merged bundle as text: its files, its decompressed genome, its manifest and its record.
    static func snapshot(of bundle: URL, root: URL) async throws -> String {
        let files = relativeFiles(in: bundle)
        let manifest = try BundleManifest.load(from: bundle)
        let genomeURL = bundle.appendingPathComponent(try XCTUnwrap(manifest.genome).path)
        var genome: [String] = []
        for try await line in genomeURL.linesAutoDecompressing() { genome.append(line) }
        let replacements = [root.resolvingSymlinksInPath().path, root.path].map { ($0, "<ROOT>") }
            + [(NSHomeDirectory(), "<HOME>")]
        return [
            "== files ==", files.sorted().joined(separator: "\n"),
            "== genome ==", genome.joined(separator: "\n"),
            "== manifest ==", try normalizedJSON(bundle.appendingPathComponent(BundleManifest.filename), replacements),
            "== record ==", try normalizedJSON(bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename), replacements),
        ].joined(separator: "\n")
    }

    /// The regular files of `bundle`, as paths relative to it.
    nonisolated private static func relativeFiles(in bundle: URL) -> [String] {
        var files: [String] = []
        let prefix = bundle.resolvingSymlinksInPath().path.count + 1
        if let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(String(url.resolvingSymlinksInPath().path.dropFirst(prefix)))
            }
        }
        return files
    }

    private static func normalizedJSON(_ url: URL, _ replacements: [(String, String)]) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let data = try JSONSerialization.data(
            withJSONObject: scrub(object, replacements), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static let volatileKeys: Set<String> = [
        "wallTimeSeconds", "checksumSHA256", "fileSize", "toolVersion", "workflowVersion", "runtimeIdentity",
    ]

    private static func scrub(_ value: Any, _ replacements: [(String, String)]) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, inner) in dictionary where !volatileKeys.contains(key) && !key.hasSuffix("At") && key.lowercased().range(of: "date") == nil {
                result[key] = scrub(inner, replacements)
            }
            return result
        }
        if let array = value as? [Any] { return array.map { scrub($0, replacements) } }
        guard var text = value as? String else { return value }
        for (path, name) in replacements where !path.isEmpty { text = text.replacingOccurrences(of: path, with: name) }
        for (pattern, name) in [
            ("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "<UUID>"),
            ("reference-merge-[A-Za-z0-9]+", "reference-merge-<ID>"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        return text
    }

    /// Rewrites the expected text, for `LUNGFISH_RECAPTURE_REFERENCE_MERGE=1`.
    private static func writeExpected(_ text: String, file: String = #filePath) throws {
        let url = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("ReferenceBundleMergePinExpected.swift")
        let source = [
            "// ReferenceBundleMergePinExpected.swift - The text ReferenceBundleMergePinConformanceTests pins",
            "// Copyright (c) 2026 Lungfish Contributors",
            "// SPDX-License-Identifier: MIT",
            "",
            "enum ReferenceBundleMergePinExpected {",
            "    static let twoBundles = #\"\"\"",
            text,
            "\"\"\"#",
            "}",
            "",
        ].joined(separator: "\n")
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }
}

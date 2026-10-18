// TaxaCollectionFixtures.swift - Kraken2 results and collections for the taxa collection tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A66. Two Kraken2 results inside one project, each over loose read files as a
// classification run leaves them, a single-end run and a paired run. Genus 10 holds species 11 and
// 12 and species 20 stands alone, so a target with children reads a genus's species and a target
// without them does not.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

struct TaxaCollectionFixtures {
    static let genus = 10
    static let speciesA1 = 11
    static let speciesA2 = 12
    static let speciesB = 20

    /// Genus A with its children, then Species B alone.
    static let collection = TaxaCollection(
        id: "a66-genus-and-b",
        name: "A66 genus and B",
        description: "",
        sfSymbol: "circle",
        taxa: [
            TaxonTarget(name: "Genus A", taxId: genus, includeChildren: true),
            TaxonTarget(name: "Species B", taxId: speciesB, includeChildren: false),
        ]
    )

    /// Genus A without its children, which the report gives no reads of its own, Species B alone and a
    /// taxon the report does not hold. Only Species B gives a file.
    static let skippingCollection = TaxaCollection(
        id: "a66-skips",
        name: "A66 skips",
        description: "",
        sfSymbol: "circle",
        taxa: [
            TaxonTarget(name: "Genus A", taxId: genus, includeChildren: false),
            TaxonTarget(name: "Species B", taxId: speciesB, includeChildren: false),
            TaxonTarget(name: "Absent", taxId: 999, includeChildren: true),
        ]
    )

    /// The report of both runs. Species 11 holds two reads, species 12 one and species 20 two.
    static let kreport = [
        " 16.67\t1\t1\tU\t0\tunclassified",
        " 83.33\t5\t0\tR\t1\troot",
        " 50.00\t3\t0\tG\t10\t  Genus A",
        " 33.33\t2\t2\tS\t11\t    Species A1",
        " 16.67\t1\t1\tS\t12\t    Species A2",
        " 33.33\t2\t2\tS\t20\t  Species B",
    ].joined(separator: "\n") + "\n"

    /// The folder of the project that holds both results.
    let projectURL: URL
    /// The single-end result folder, reads a1 to a3 and b1, b2 classified and u1 not.
    let singleEnd: URL
    /// The single-end read file of ``singleEnd``.
    let singleEndReads: URL
    /// The paired result folder, pairs p1 to p3 classified.
    let paired: URL

    init(in root: URL) throws {
        let fileManager = FileManager.default
        projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analyses = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try fileManager.createDirectory(at: analyses, withIntermediateDirectories: true)

        singleEndReads = projectURL.appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["a1", "a2", "a3", "b1", "b2", "u1"]).write(to: singleEndReads, atomically: true, encoding: .utf8)
        singleEnd = try Self.writeResult(
            named: "single", in: analyses, inputs: [singleEndReads], paired: false,
            lines: [
                Self.single("a1", Self.speciesA1), Self.single("a2", Self.speciesA1), Self.single("a3", Self.speciesA2),
                Self.single("b1", Self.speciesB), Self.single("b2", Self.speciesB), "U\tu1\t0\t10\t0:3",
            ]
        )

        let r1 = projectURL.appendingPathComponent("sample_R1.fastq")
        let r2 = projectURL.appendingPathComponent("sample_R2.fastq")
        try ReadSetFixtures.fastq(["p1/1", "p2/1", "p3/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["p1/2", "p2/2", "p3/2"]).write(to: r2, atomically: true, encoding: .utf8)
        paired = try Self.writeResult(
            named: "paired", in: analyses, inputs: [r1, r2], paired: true,
            lines: [Self.pair("p1", Self.speciesA1), Self.pair("p2", Self.speciesB), Self.pair("p3", Self.speciesA2)]
        )
    }

    /// The report of ``writeGenusWithOwnRead()``. Genus A holds one read of its own beside its species.
    static let ownReadKreport = [
        "100.00\t4\t0\tR\t1\troot",
        "100.00\t4\t1\tG\t10\t  Genus A",
        " 50.00\t2\t2\tS\t11\t    Species A1",
        " 25.00\t1\t1\tS\t12\t    Species A2",
    ].joined(separator: "\n") + "\n"

    /// Genus A alone, with or without its children.
    static func genusOnly(includeChildren: Bool) -> TaxaCollection {
        TaxaCollection(
            id: "genus-only", name: "Genus only", description: "", sfSymbol: "circle",
            taxa: [TaxonTarget(name: "Genus A", taxId: genus, includeChildren: includeChildren)]
        )
    }

    /// Writes a third, single-end result, `kraken2-own`, whose reads a1 to a3 belong to Genus A's species
    /// and g1 to Genus A itself (BIO's ruling on lane 12.11, the exact scope).
    func writeGenusWithOwnRead() throws -> URL {
        let reads = projectURL.appendingPathComponent("own-reads.fastq")
        try ReadSetFixtures.fastq(["a1", "a2", "a3", "g1"]).write(to: reads, atomically: true, encoding: .utf8)
        return try Self.writeResult(
            named: "own", in: projectURL.appendingPathComponent("Analyses", isDirectory: true), inputs: [reads], paired: false,
            lines: [
                Self.single("a1", Self.speciesA1), Self.single("a2", Self.speciesA1), Self.single("a3", Self.speciesA2),
                Self.single("g1", Self.genus),
            ],
            kreport: Self.ownReadKreport
        )
    }

    /// The report of ``writePairedGenusWithOwnPair()``. Genus A holds one pair of its own between the
    /// pairs of its two species.
    static let ownPairKreport = [
        "100.00\t3\t0\tR\t1\troot",
        "100.00\t3\t1\tG\t10\t  Genus A",
        " 33.33\t1\t1\tS\t11\t    Species A1",
        " 33.33\t1\t1\tS\t12\t    Species A2",
    ].joined(separator: "\n") + "\n"

    /// Writes a fourth, paired result, `kraken2-own-paired`, over two loose read files. Pair p1 belongs
    /// to Species A1, g1 to Genus A itself and p3 to Species A2, in that file order (lane 12.11, the
    /// review's fix 6, the paired form of the exact scope).
    func writePairedGenusWithOwnPair() throws -> URL {
        let r1 = projectURL.appendingPathComponent("own-pairs_R1.fastq")
        let r2 = projectURL.appendingPathComponent("own-pairs_R2.fastq")
        try ReadSetFixtures.fastq(["p1/1", "g1/1", "p3/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["p1/2", "g1/2", "p3/2"]).write(to: r2, atomically: true, encoding: .utf8)
        return try Self.writeResult(
            named: "own-paired", in: projectURL.appendingPathComponent("Analyses", isDirectory: true), inputs: [r1, r2], paired: true,
            lines: [Self.pair("p1", Self.speciesA1), Self.pair("g1", Self.genus), Self.pair("p3", Self.speciesA2)],
            kreport: Self.ownPairKreport
        )
    }

    static func single(_ read: String, _ taxId: Int) -> String {
        "C\t\(read)\t\(taxId)\t10\t\(taxId):3"
    }

    static func pair(_ fragment: String, _ taxId: Int) -> String {
        "C\t\(fragment)\t\(taxId)\t10|10\t\(taxId):3 |:| \(taxId):3"
    }

    private static func writeResult(
        named name: String, in analyses: URL, inputs: [URL], paired: Bool, lines: [String], kreport: String = TaxaCollectionFixtures.kreport
    ) throws -> URL {
        let directory = analyses.appendingPathComponent("kraken2-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The result names its reads and its own folder relative to itself, as a copy of the project needs,
        // so a copy of the project reads its own files.
        let relativeInputs = inputs.map { URL(string: "../../\($0.lastPathComponent)")! }
        var config = ClassificationConfig(
            inputFiles: relativeInputs, isPairedEnd: paired, databaseName: "Viral",
            databasePath: URL(string: ".")!, outputDirectory: URL(string: ".")!
        )
        config.originalInputFiles = relativeInputs
        let kreportURL = directory.appendingPathComponent("classification.kreport")
        try kreport.write(to: kreportURL, atomically: true, encoding: .utf8)
        let krakenURL = directory.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: krakenURL, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: config, tree: try KreportParser.parse(url: kreportURL), reportURL: kreportURL, outputURL: krakenURL,
            brackenURL: nil, runtime: 1, toolVersion: "2.17.1", provenanceId: nil
        ).save(to: directory)
        return directory
    }

    /// The record names of a FASTQ file, plain or gzip, in file order.
    static func recordNames(in url: URL) throws -> [String] {
        let text: String
        if url.pathExtension == "gz" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }
}

/// The messages a progress callback received, in order.
final class TaxaCollectionProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// RNASeqExportReadAtExportTests.swift - Route and set are read from the result at every export (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ADJ-BULK-5 item 6 and `SCR/rulings/ADJ-BULK-5.md:18-20`. A copied or moved project exports the same files and refuses
// the same joins, a replaced `quant.sf` is refused in words that name the file, and nothing about a route is cached.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class RNASeqExportReadAtExportTests: RNASeqExportTestCase {
    typealias Fix = RNASeqExportFixture

    func testAMovedProjectExportsTheSameFilesAndRefusesTheSameJoin() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"]))
        let b = try make(.init(name: "b", samples: ["T1", "T2"]))
        let c = try make(.init(name: "c", route: Fix.starSalmon, samples: ["U1", "U2"]))
        let before = try Fix.join([a, b])
        let moved = root.appendingPathComponent("Moved/Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let urls = try [a, b, c].map { url -> URL in
            let copy = moved.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
        let after = try Fix.join([urls[0], urls[1]])
        XCTAssertEqual(try after.counts.tsvData(), try before.counts.tsvData())
        XCTAssertEqual(after.genes, before.genes)
        XCTAssertEqual(after.route, before.route)
        var words: [String] = []
        for pair in [[a, c], [urls[0], urls[2]]] {
            XCTAssertThrowsError(try Fix.join(pair)) { words.append($0.localizedDescription) }
        }
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0], words[1])
    }

    func testAReplacedQuantFileIsRefusedInWordsThatNameTheFile() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"]))
        let manifest = try RNASeqResultBundle.loadManifest(from: a)
        let quant = try XCTUnwrap(manifest.sourceFiles.first { $0.path.hasSuffix("quant.sf") })
        try Data("replaced\n".utf8).write(to: a.appendingPathComponent(quant.path))
        XCTAssertThrowsError(try RNASeqExportReader.read([a])) {
            let words = $0.localizedDescription
            XCTAssertTrue(words.contains(quant.path), words)
            XCTAssertTrue(words.contains("a.lungfishrnaseq") || words.contains("\"a\""), words)
            XCTAssertTrue(words.contains("changed"), words)
        }
    }

    func testAReplacedCountTableIsRefusedToo() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"]))
        let counts = try XCTUnwrap(try RNASeqResultBundle.loadManifest(from: a).counts.first)
        try Data("feature_id\tS1\tS2\nG1\t999\t999\n".utf8).write(to: a.appendingPathComponent(counts.path))
        XCTAssertThrowsError(try RNASeqExportReader.read([a])) { XCTAssertTrue($0.localizedDescription.contains(counts.path), $0.localizedDescription) }
    }

    /// The manifest is read again at each export. Edit a result's route between two exports and the second refuses.
    func testTheRouteIsReadFromTheRecordAtEveryExportAndNeverCached() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"]))
        let b = try make(.init(name: "b", samples: ["T1", "T2"]))
        XCTAssertNoThrow(try Fix.join([a, b]))
        var manifest = try RNASeqResultBundle.loadManifest(from: b)
        manifest.route = Fix.starSalmon
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: RNASeqResultBundle.manifestURL(in: b))
        XCTAssertThrowsError(try Fix.join([a, b])) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("These samples were counted by different routes: "), $0.localizedDescription)
        }
    }

    func testAFolderThatIsNoResultIsRefusedInWords() throws {
        let empty = root.appendingPathComponent("not-a-result.lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RNASeqExportReader.read([empty])) {
            XCTAssertTrue($0.localizedDescription.contains("no readable manifest"), $0.localizedDescription)
        }
    }
}

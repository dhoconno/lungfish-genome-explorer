// ViewerFigureTrackTests.swift - The ruler and sequence track builders and their scene goldens
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 M3 (GFX-0, ruling sections 2.2 and 6 of ARCH-B10-graphics, BIO ruling Q-G3 item 10).
// The goldens are `Tests/Fixtures/golden/viewer-graphics/<case>.scene.json`, JSON with sorted
// keys and no rendered bytes. A predicted change rewrites them with
// LUNGFISH_UPDATE_VIEWER_FIGURE_GOLDENS=1 and names the change in its report.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// A fixed 30,000 base contig in a FASTA with its index, written for each test.
enum ViewerFigureTrackFixture {
    static let contig = "figure-contig"
    static let length = 30_000

    /// A fixed pattern of the four bases, with an N run at 110..<114 and lower case at 120..<126.
    static func bases() -> [UInt8] {
        let pattern = Array("ACGTTGCAACGGTCATGCTA".utf8)
        var bases = (0 ..< length).map { pattern[($0 * 7 + $0 / 20) % pattern.count] }
        for index in 110 ..< 114 {
            bases[index] = UInt8(ascii: "N")
        }
        for index in 120 ..< 126 {
            bases[index] |= 0x20
        }
        return bases
    }

    /// Writes `figure.fa` with 60 bases a line and its `.fai`, and returns the FASTA's URL.
    static func write(in folder: URL) throws -> URL {
        let fasta = folder.appendingPathComponent("figure.fa")
        let header = ">\(contig)\n"
        var text = header
        let bases = bases()
        for start in stride(from: 0, to: length, by: 60) {
            text += String(decoding: bases[start ..< min(start + 60, length)], as: UTF8.self) + "\n"
        }
        try Data(text.utf8).write(to: fasta)
        try Data("\(contig)\t\(length)\t\(header.utf8.count)\t60\t61\n".utf8).write(to: fasta.appendingPathExtension("fai"))
        return fasta
    }

    static func frame(start: Double, end: Double, width: Int, trailingInset: CGFloat = 0) -> ViewerFigureFrame {
        ViewerFigureFrame(
            chromosome: contig, start: start, end: end, pixelWidth: width, sequenceLength: length,
            trailingInset: trailingInset
        )
    }
}

final class ViewerFigureRulerTrackTests: XCTestCase {
    func testTickIntervalFollowsTheLiveRule() {
        XCTAssertEqual(ViewerFigureRulerTrack.tickInterval(visibleRange: 100, pixelWidth: 388), 20)
        XCTAssertEqual(ViewerFigureRulerTrack.tickInterval(visibleRange: 29903, pixelWidth: 288), 10000)
        XCTAssertEqual(ViewerFigureRulerTrack.tickInterval(visibleRange: 5, pixelWidth: 1000), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ViewerFigureRulerTrack.tickInterval(visibleRange: 3e6, pixelWidth: 300), 1e6)
        XCTAssertEqual(ViewerFigureRulerTrack.tickInterval(visibleRange: 40, pixelWidth: 400), 10)
    }

    func testPositionLabelsFollowTheLiveFormatInEveryLocale() {
        XCTAssertEqual(ViewerFigureRulerTrack.formatPosition(1_500_000, tickInterval: 1e6), "1.5 Mb")
        XCTAssertEqual(ViewerFigureRulerTrack.formatPosition(2_000_000, tickInterval: 1e6), "2 Mb")
        XCTAssertEqual(ViewerFigureRulerTrack.formatPosition(21_500, tickInterval: 1000), "21.5 kb")
        XCTAssertEqual(ViewerFigureRulerTrack.formatPosition(20_000, tickInterval: 10000), "20 kb")
        XCTAssertEqual(ViewerFigureRulerTrack.formatPosition(1_234_567, tickInterval: 1), "1,234,567")
        for (value, text) in [(0, "0"), (999, "999"), (1000, "1,000"), (21_612, "21,612"), (-1234, "-1,234")] {
            XCTAssertEqual(ViewerFigureRulerTrack.grouped(value), text)
        }
    }

    func testAnEmptyRegionDrawsTheBandAndBorderOnly() async throws {
        let frame = ViewerFigureTrackFixture.frame(start: 50, end: 50, width: 100)
        let scene = try await ViewerFigureSceneBuilder.build(frame: frame, appearance: .light, tracks: [ViewerFigureRulerTrack()])
        XCTAssertEqual(scene.items.count, 2)
        XCTAssertEqual(scene.omissions, [])
        XCTAssertEqual(scene.fonts, [], "no label, no font")
    }
}

final class ViewerFigureSequenceTrackTests: XCTestCase {
    private func buildScene(
        _ frame: ViewerFigureFrame, showsRNA: Bool = false, in root: URL
    ) async throws -> ViewerFigureScene {
        let track = ViewerFigureSequenceTrack(fastaURL: try ViewerFigureTrackFixture.write(in: root), showsRNA: showsRNA)
        return try await ViewerFigureSceneBuilder.build(frame: frame, appearance: .light, tracks: [track])
    }

    private func texts(_ scene: ViewerFigureScene) -> [ViewerFigureText] {
        scene.items.compactMap { item in
            guard case .text(let text) = item else { return nil }
            return text
        }
    }

    func testBasesWithNoRoomForLettersRecordTheCount() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        let scene = try await buildScene(ViewerFigureTrackFixture.frame(start: 0, end: 600, width: 200), in: root)
        XCTAssertEqual(texts(scene), [])
        XCTAssertEqual(scene.items.count, 600, "one cell for each base inside the data area")
        XCTAssertEqual(scene.omissions.map(\.kind), [.labelsOmitted])
        XCTAssertEqual(scene.omissions.first?.count, 600)
        XCTAssertEqual(scene.fonts, [], "no letter, no font")
    }

    func testALetterThatFitsTheDataAreaExactlyIsDrawn() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        // 201 points over 20 bases is 10.05 points a base. The last cell ends a hair past the data
        // area in floating point, and the track must not read that as a cut by the edge.
        let scene = try await buildScene(ViewerFigureTrackFixture.frame(start: 100, end: 120, width: 201), in: root)
        XCTAssertEqual(texts(scene).count, 20)
        XCTAssertEqual(scene.omissions, [])
    }

    func testNoCellIsDrawnForTheBaseAfterTheWindow() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        // 201 points over 25 bases is 8.04 points a base. The base after the window begins a hair
        // before the data area's edge in floating point, and it must not enter the scene.
        let scene = try await buildScene(ViewerFigureTrackFixture.frame(start: 100, end: 125, width: 201), in: root)
        XCTAssertEqual(scene.items.count, 50, "25 cells and 25 letters")
        XCTAssertEqual(scene.omissions, [])
    }

    func testRNAModeShowsUAndDNAModeShowsT() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        let frame = ViewerFigureTrackFixture.frame(start: 100, end: 140, width: 400)
        let dna = texts(try await buildScene(frame, in: root)).map(\.string)
        let rna = texts(try await buildScene(frame, showsRNA: true, in: root)).map(\.string)
        XCTAssertEqual(dna.count, 40)
        XCTAssertTrue(dna.contains("T"))
        XCTAssertFalse(rna.contains("T"))
        XCTAssertEqual(dna.map { $0 == "T" ? "U" : $0 }, rna)
        XCTAssertEqual(Set(dna), ["A", "C", "G", "T", "N"], "lower case shows upper case")
    }

    func testABarCutByTheDataAreaKeepsOnlyItsInsideSides() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        let scene = try await buildScene(ViewerFigureTrackFixture.frame(start: 0, end: 29000.5, width: 80), in: root)
        guard case .strokeSegments(let sides, _, let paint) = scene.items.last else {
            return XCTFail("the cut outline is drawn as segments")
        }
        XCTAssertEqual(sides.count, 3, "top, bottom and the left side")
        XCTAssertEqual(paint, ViewerFigurePaint(.systemGray, alpha: 0.7))
        XCTAssertEqual(scene.omissions.map(\.kind), [.scaleMode])
    }

    func testAContigTheIndexDoesNotNameFails() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        let frame = ViewerFigureFrame(chromosome: "chrNone", start: 0, end: 10, pixelWidth: 100)
        do {
            _ = try await buildScene(frame, in: root)
            XCTFail("an unknown contig built a scene")
        } catch {
            XCTAssertEqual(
                error as? ViewerFigureSequenceTrackError, .contigNotFound(contig: "chrNone", fasta: "figure.fa")
            )
        }
    }

    func testTheOmissionCountsTheWindowsOwnBases() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-sequence")
        defer { TestTempDirectory.cleanup(root) }
        // The live view reads one base past a whole-number end, and that base lies outside the
        // window and is never drawn. A fractional end shows part of the base at the end.
        let cases: [(start: Double, end: Double, width: Int, count: Int)] = [
            (100, 2100, 100, 2000), (100, 2100.5, 100, 2001), (0, 29000, 80, 29000),
        ]
        for window in cases {
            let frame = ViewerFigureTrackFixture.frame(start: window.start, end: window.end, width: window.width)
            let scene = try await buildScene(frame, in: root)
            XCTAssertEqual(scene.omissions.map(\.kind), [.scaleMode], "\(window.start) to \(window.end)")
            XCTAssertEqual(scene.omissions.first?.count, window.count, "\(window.start) to \(window.end)")
        }
    }

    func testInputFilesNameTheFASTAAndItsIndex() {
        let fasta = URL(fileURLWithPath: "/tmp/figure.fa")
        XCTAssertEqual(
            ViewerFigureSequenceTrack(fastaURL: fasta).inputFiles,
            [fasta, URL(fileURLWithPath: "/tmp/figure.fa.fai")]
        )
    }

    func testDominantBaseBreaksATieInAFixedOrder() {
        let cases: [(String, Character)] = [("ACGT", "A"), ("tgca", "A"), ("GGCC", "C"), ("GGTT", "T"), ("RRA", "R"), ("NNA", "N")]
        for (bin, expected) in cases {
            XCTAssertEqual(ViewerFigureSequenceTrack.dominantBase(ArraySlice(Array(bin.utf8))), expected, bin)
        }
    }
}

final class ViewerFigureTrackGoldenTests: XCTestCase {
    private static let updateKey = "LUNGFISH_UPDATE_VIEWER_FIGURE_GOLDENS"
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden/viewer-graphics", isDirectory: true)

    private func assertGolden(_ scene: ViewerFigureScene, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.folder.appendingPathComponent("\(name).scene.json")
        let json = try scene.goldenJSON()
        if ProcessInfo.processInfo.environment[Self.updateKey] == "1" {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try json.write(to: url)
        }
        let golden = try Data(contentsOf: url)
        XCTAssertTrue(
            json == golden, "\(name) differs from its golden. A predicted change reruns with \(Self.updateKey)=1.",
            file: file, line: line
        )
        XCTAssertEqual(try JSONDecoder().decode(ViewerFigureScene.self, from: golden), scene, name, file: file, line: line)
    }

    private func build(
        _ frame: ViewerFigureFrame, appearance: ViewerFigureAppearance = .light, tracks: [any ViewerFigureTrackBuilding]
    ) async throws -> ViewerFigureScene {
        try await ViewerFigureSceneBuilder.build(frame: frame, appearance: appearance, tracks: tracks)
    }

    func testRulerInBases() async throws {
        let frame = ViewerFigureFrame(
            chromosome: "MN908947.3", start: 21562, end: 21662, pixelWidth: 400, sequenceLength: 29903, trailingInset: 12
        )
        let scene = try await build(frame, tracks: [ViewerFigureRulerTrack()])
        XCTAssertEqual(scene.omissions, [ViewerFigureOmission(
            trackID: "ruler", kind: .labelsOmitted, reason: "1 of 5 position labels had no room", count: 1
        )], "21,660 would cross the trailing inset")
        XCTAssertEqual(scene.fonts, [ViewerFigureFontResolution(requested: "Menlo-Regular", resolved: "Menlo-Regular", size: 10)])
        try assertGolden(scene, "ruler-bases")
    }

    func testRulerInKilobases() async throws {
        let frame = ViewerFigureFrame(
            chromosome: "MN908947.3", start: 0, end: 29903, pixelWidth: 300, sequenceLength: 29903, trailingInset: 12
        )
        let scene = try await build(frame, appearance: .dark, tracks: [ViewerFigureRulerTrack()])
        XCTAssertEqual(scene.omissions.map(\.count), [1], "0 kb has no room at the left edge")
        try assertGolden(scene, "ruler-kilobases")
    }

    func testSequenceLettersUnderTheRuler() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-golden")
        defer { TestTempDirectory.cleanup(root) }
        let fasta = try ViewerFigureTrackFixture.write(in: root)
        let frame = ViewerFigureTrackFixture.frame(start: 100, end: 140, width: 412, trailingInset: 12)
        let scene = try await build(frame, tracks: [ViewerFigureRulerTrack(), ViewerFigureSequenceTrack(fastaURL: fasta)])
        XCTAssertEqual(scene.height, 60)
        XCTAssertEqual(scene.omissions, [ViewerFigureOmission(
            trackID: "ruler", kind: .labelsOmitted, reason: "2 of 5 position labels had no room", count: 2
        )], "the labels at both edges have no room, and every letter of the 40 bases has room")
        XCTAssertEqual(scene.fonts.map(\.resolved), ["Menlo-Regular", "Menlo-Bold"])
        XCTAssertFalse(try ViewerFigureRasterizer.render(scene, format: .png).isEmpty)
        try assertGolden(scene, "sequence-letters")
    }

    func testSequenceBlocks() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-golden")
        defer { TestTempDirectory.cleanup(root) }
        let track = ViewerFigureSequenceTrack(fastaURL: try ViewerFigureTrackFixture.write(in: root))
        let scene = try await build(ViewerFigureTrackFixture.frame(start: 0, end: 2000, width: 100), tracks: [track])
        XCTAssertEqual(scene.items.count, 100, "one block for each 20 bases")
        XCTAssertEqual(scene.omissions, [ViewerFigureOmission(
            trackID: "sequence", kind: .scaleMode,
            reason: "bases drawn as blocks of their most common base at 20 bases per point, 10 or more", count: 2000
        )], "base 2000 is outside the window from 0 to 2,000")
        try assertGolden(scene, "sequence-blocks")
    }

    func testSequenceBar() async throws {
        let root = try TestTempDirectory.make(prefix: "viewer-figure-golden")
        defer { TestTempDirectory.cleanup(root) }
        let track = ViewerFigureSequenceTrack(fastaURL: try ViewerFigureTrackFixture.write(in: root))
        let scene = try await build(ViewerFigureTrackFixture.frame(start: 0, end: 30000, width: 80), tracks: [track])
        XCTAssertEqual(scene.items.count, 2, "the bar and its outline")
        XCTAssertEqual(scene.omissions.map(\.kind), [.scaleMode])
        XCTAssertEqual(scene.omissions.first?.count, 30000)
        try assertGolden(scene, "sequence-bar")
    }
}

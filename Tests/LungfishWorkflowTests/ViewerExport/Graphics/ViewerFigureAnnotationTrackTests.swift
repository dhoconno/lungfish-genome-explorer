// ViewerFigureAnnotationTrackTests.swift - The annotation track builder's items and omissions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow

final class ViewerFigureAnnotationTrackTests: XCTestCase {
    private func feature(
        _ name: String, _ type: AnnotationType, _ start: Int, _ end: Int, strand: Strand = .forward
    ) -> SequenceAnnotation {
        SequenceAnnotation(type: type, name: name, chromosome: "chr1", start: start, end: end, strand: strand)
    }

    private var genes: [SequenceAnnotation] {
        [
            feature("geneA", .gene, 10, 200), feature("geneB", .gene, 100, 300, strand: .reverse),
            feature("rs1", .snp, 150, 151), feature("cdsX", .cds, 250, 260), feature("tx1", .mRNA, 400, 600),
        ]
    }

    private func draw(
        _ annotations: [SequenceAnnotation], end: Double = 1_000, height: Double = 200,
        options: ViewerFigureAnnotationTrack.Options = .init()
    ) throws -> ViewerFigureCanvas {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: end, pixelWidth: 1_000)
        let track = ViewerFigureAnnotationTrack(sources: [], height: height, options: options)
        var canvas = ViewerFigureCanvas()
        try track.draw(annotations, into: &canvas, frame: frame, area: ViewerFigureRect(x: 0, y: 10, width: 1_000, height: height))
        return canvas
    }

    private func texts(_ canvas: ViewerFigureCanvas) -> [ViewerFigureText] {
        canvas.items.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    func testExpandedRowsDrawBoxesLabelsAndArrowsInRoles() throws {
        let canvas = try draw(genes)
        XCTAssertEqual(texts(canvas).map(\.string), ["geneA", "tx1", "geneB"], "row by row, and cdsX is 10 points wide, under 72")
        XCTAssertEqual(Set(texts(canvas).map(\.fontName)), ["HelveticaNeue"])
        XCTAssertEqual(texts(canvas).first?.paint, ViewerFigurePaint(.text))
        XCTAssertEqual(texts(canvas).first?.point.x, 12, "two points inside the box")
        XCTAssertTrue(canvas.items.contains(.fill(
            rect: ViewerFigureRect(x: 10, y: 10, width: 190, height: 16), paint: ViewerFigurePaint(.annotationGene, alpha: 0.7)
        )))
        XCTAssertTrue(canvas.items.contains(.strokeRect(
            rect: ViewerFigureRect(x: 10, y: 10, width: 190, height: 16), lineWidth: 1, paint: ViewerFigurePaint(.annotationGene)
        )))
        XCTAssertTrue(canvas.items.contains(.strokeSegments(segments: [
            ViewerFigureSegment(from: ViewerFigurePoint(x: 194, y: 16), to: ViewerFigurePoint(x: 198, y: 18)),
            ViewerFigureSegment(from: ViewerFigurePoint(x: 198, y: 18), to: ViewerFigurePoint(x: 194, y: 20)),
        ], lineWidth: 1, paint: ViewerFigurePaint(.text, alpha: 0.5))), "the forward arrow at the right end")
        XCTAssertEqual(canvas.omissions, [
            ViewerFigureOmission(trackID: "annotations", kind: .labelsOmitted, reason: "narrower than 72 points or more than 12 rows", count: 1),
            ViewerFigureOmission(trackID: "annotations", kind: .trackNotDrawn, reason: "embedded CDS translations", count: 1),
        ])
    }

    func testRowCapAndTrackHeightAreCountedAsLeftOut() throws {
        var options = ViewerFigureAnnotationTrack.Options()
        options.maxRows = 1
        let capped = try draw(genes, options: options)
        XCTAssertEqual(capped.omissions.first, ViewerFigureOmission(trackID: "annotations", kind: .annotationLimit, reason: "max 1 rows", count: 2))
        XCTAssertEqual(texts(capped).last?.string, "+2 more features")
        let short = try draw(genes, height: 20)
        XCTAssertEqual(short.omissions.first, ViewerFigureOmission(
            trackID: "annotations", kind: .annotationLimit, reason: "rows past the track height of 20 points", count: 2
        ))
        XCTAssertEqual(texts(short).last?.string, "+2 more features")
    }

    func testSpanningRegionFeatureIsCountedWhenOthersDraw() throws {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: 1_000, pixelWidth: 1_000, sequenceLength: 1_000)
        var canvas = ViewerFigureCanvas()
        try ViewerFigureAnnotationTrack(sources: [], height: 200).draw(
            genes + [feature("whole", .region, 0, 1_000)], into: &canvas, frame: frame,
            area: ViewerFigureRect(x: 0, y: 10, width: 1_000, height: 200)
        )
        XCTAssertEqual(texts(canvas).map(\.string), ["geneA", "tx1", "geneB"], "the region feature is not drawn, the others are")
        XCTAssertEqual(canvas.omissions.first, ViewerFigureOmission(
            trackID: "annotations", kind: .scaleMode, reason: "region features span the view", count: 1
        ))
    }

    func testSquishedRowsLeaveEveryLabelOutAndSaySo() throws {
        let canvas = try draw(genes.map { feature($0.name, $0.type, $0.start * 1_000, $0.end * 1_000) }, end: 1_000_000)
        XCTAssertTrue(texts(canvas).isEmpty)
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(
            trackID: "annotations", kind: .labelsOmitted, reason: "squished rows above 500 bases per point", count: 4
        )])
    }

    func testDensityRecordsTheScaleAndCountsEveryFeature() throws {
        let canvas = try draw(genes.map { feature($0.name, $0.type, $0.start * 100_000, $0.end * 100_000) }, end: 100_000_000)
        XCTAssertEqual(texts(canvas).map(\.string), ["5 features (zoom in to see details)"])
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(
            trackID: "annotations", kind: .scaleMode, reason: "density above 50000 bases per point", count: 5
        )])
        XCTAssertEqual(canvas.items.first, .fill(
            rect: ViewerFigureRect(x: 0, y: 10, width: 1_000, height: 30), paint: ViewerFigurePaint(.controlBackground, alpha: 0.3)
        ))
    }

    func testEveryAnnotationTypeHasAColourRole() {
        let roles = Set(AnnotationType.allCases.map(ViewerFigureAnnotationColors.role(for:)))
        XCTAssertEqual(roles.count, 51)
        XCTAssertTrue(roles.allSatisfy { $0.rawValue.hasPrefix("annotation") })
    }

    func testBuildReadsARealAnnotationDatabaseOffTheMainActor() async throws {
        let scene = try await ViewerFigureAnnotationFixture.databaseScene()
        let strings = scene.items.compactMap { if case .text(let text) = $0 { text.string } else { nil } }
        XCTAssertEqual(strings, ["geneA", "tx1", "geneB"], "the BED rows read back through queryByRegion")
        XCTAssertTrue(scene.items.contains(.fill(
            rect: ViewerFigureRect(x: 10, y: 0, width: 190, height: 16), paint: ViewerFigurePaint(.annotationGene, alpha: 0.7)
        )))
        XCTAssertEqual(scene.omissions, [
            ViewerFigureOmission(trackID: "annotations", kind: .labelsOmitted, reason: "narrower than 72 points or more than 12 rows", count: 1),
            ViewerFigureOmission(trackID: "annotations", kind: .trackNotDrawn, reason: "embedded CDS translations", count: 1),
        ])
        XCTAssertEqual(scene.fonts.map(\.resolved), ["HelveticaNeue"])
    }

    func testQueryLimitOmissionNamesTheSourceAndTheLimit() async throws {
        XCTAssertEqual(ViewerFigureAnnotationTrack.Options().queryLimit, 50_000, "the live bundle query stops at 50,000 records")
        var options = ViewerFigureAnnotationTrack.Options()
        options.queryLimit = 2
        let scene = try await ViewerFigureAnnotationFixture.databaseScene(options: options)
        XCTAssertTrue(scene.omissions.contains(ViewerFigureOmission(
            trackID: "annotations", kind: .annotationLimit, reason: "genes query limit 2 records", count: nil
        )))
    }

    func testAContigNamedByAnAliasDrawsOnlyWhenTheSourceListsTheAlias() async throws {
        func geneFill(_ scene: ViewerFigureScene) -> Bool {
            scene.items.contains { if case .fill(_, let paint) = $0 { paint.role == .annotationGene } else { false } }
        }
        func strings(_ scene: ViewerFigureScene) -> [String] {
            scene.items.compactMap { if case .text(let text) = $0 { text.string } else { nil } }
        }
        let listed = try await ViewerFigureAnnotationFixture.databaseScene(bedContig: "1", chromosomeNames: ["1"])
        XCTAssertEqual(strings(listed), ["geneA", "tx1", "geneB"], "the database holds contig 1 and the source lists it for chr1")
        XCTAssertTrue(geneFill(listed))
        let unlisted = try await ViewerFigureAnnotationFixture.databaseScene(bedContig: "1")
        XCTAssertEqual(strings(unlisted), [], "without the alias the query finds nothing, as the bare name did before")
        XCTAssertFalse(geneFill(unlisted))
    }
}

/// An annotation database built from a BED file, for the database and golden cases.
enum ViewerFigureAnnotationFixture {
    /// Four BED rows with a type column: two genes, a CDS and an mRNA on chr1.
    static let bed = [
        "chr1\t10\t200\tgeneA\t0\t+\t10\t200\t0\t1\t190\t0\tgene",
        "chr1\t100\t300\tgeneB\t0\t-\t100\t300\t0\t1\t200\t0\tgene",
        "chr1\t250\t260\tcdsX\t0\t+\t250\t260\t0\t1\t10\t0\tCDS",
        "chr1\t400\t600\ttx1\t0\t+\t400\t600\t0\t1\t200\t0\tmRNA",
    ].joined(separator: "\n") + "\n"

    /// The scene of a 1,000-point annotation track over the database, read off the main actor. The
    /// frame names chr1, and `bedContig` is the name the database holds the rows under.
    static func databaseScene(
        appearance: ViewerFigureAppearance = .light, options: ViewerFigureAnnotationTrack.Options = .init(),
        bedContig: String = "chr1", chromosomeNames: [String] = []
    ) async throws -> ViewerFigureScene {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("figure-annotations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bedURL = folder.appendingPathComponent("genes.bed")
        let databaseURL = folder.appendingPathComponent("genes.db")
        try Data(bed.replacingOccurrences(of: "chr1\t", with: "\(bedContig)\t").utf8).write(to: bedURL)
        XCTAssertEqual(try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL), 4)
        let track = ViewerFigureAnnotationTrack(
            sources: [.init(id: "genes", name: "Genes", databaseURL: databaseURL, chromosomeNames: chromosomeNames)],
            height: 200, options: options
        )
        return try await ViewerFigureSceneBuilder.build(
            frame: ViewerFigureFrame(chromosome: "chr1", start: 0, end: 1_000, pixelWidth: 1_000),
            appearance: appearance, tracks: [track]
        )
    }
}

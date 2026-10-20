// BundleExportGraphicCommandTests.swift - lungfish-cli bundle export-graphic
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2). The leaf's region, refusals and record, on a small bundle with a plain FASTA, two
// annotation tracks, a variant track and a signal track that has no figure builder yet.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BundleExportGraphicCommandTests: XCTestCase {
    private var folder: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleExportGraphic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bundle = try Self.makeBundle(in: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A bundle with `chr1` (alias `1`) of 3,000 bases in a plain FASTA, annotation tracks `genes` and `repeats`, a
    /// variant track `calls` of one SNP at 1151 for samples `s1` and `s2`, and a signal track `signal` that has no
    /// figure builder.
    static func makeBundle(in folder: URL) throws -> URL {
        let bundle = folder.appendingPathComponent("figure.lungfishref", isDirectory: true)
        for sub in ["genome", "annotations", "variants"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let bases = String(repeating: "ACGTTGCA", count: 375)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n".write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        for (name, line) in [("genes", "chr1\t1100\t1400\tgene-a\t0\t+\n"), ("repeats", "chr1\t1500\t1600\trep-a\t0\t-\n")] {
            let bed = folder.appendingPathComponent("\(name).bed")
            try line.write(to: bed, atomically: true, encoding: .utf8)
            _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/\(name).db"))
            try FileManager.default.removeItem(at: bed)
        }
        let vcf = folder.appendingPathComponent("calls.vcf")
        try ([
            "##fileformat=VCFv4.2", "##contig=<ID=chr1,length=3000>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2",
            "chr1\t1151\t.\tA\tG\t50\tPASS\t.\tGT\t0/1\t1/1",
        ].joined(separator: "\n") + "\n").write(to: vcf, atomically: true, encoding: .utf8)
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: bundle.appendingPathComponent("variants/calls.db"))
        try FileManager.default.removeItem(at: vcf)
        try BundleManifest(
            name: "Figure Fixture",
            identifier: "org.lungfish.figure-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61, aliases: ["1"])]
            ),
            annotations: [
                AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"),
                AnnotationTrackInfo(id: "repeats", name: "Repeats", path: "annotations/repeats.bb", databasePath: "annotations/repeats.db"),
            ],
            variants: [VariantTrackInfo(
                id: "calls", name: "Calls", path: "variants/calls.vcf.gz", indexPath: "variants/calls.vcf.gz.tbi",
                databasePath: "variants/calls.db"
            )],
            tracks: [SignalTrackInfo(id: "signal", name: "Signal", path: "signal/signal.bw")],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    private func command(_ arguments: [String]) throws -> BundleExportGraphicSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(["bundle", "export-graphic"] + arguments)
        return try XCTUnwrap(parsed as? BundleExportGraphicSubcommand)
    }

    private func export(_ arguments: [String]) async throws -> ViewerExportLeafOutcome {
        try await command([bundle.path] + arguments).export(events: CLIEventEmitter(enabled: false) { _ in })
    }

    private func envelope(_ output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
    }

    func testBundleExportGraphicLeafParsesTheGUIArguments() throws {
        let output = folder.appendingPathComponent("viewer-export.png")
        let settings = ViewerGraphicExport.Settings(
            region: "chr1:1000-2001", width: 812.5, includeRuler: true, tracks: ["sequence", "genes"], format: .png,
            scale: 2, theme: .dark, excludeFlags: 1796, coverageScale: .log10, viewState: folder.appendingPathComponent("v.json").path
        )
        let invocation = ViewerGraphicExport.invocation(bundleURL: bundle, settings: settings, outputURL: output, force: true)
        let parsed = try command(invocation.arguments().dropFirst(2).map { $0 })
        XCTAssertEqual(parsed.invocation(), invocation)
        XCTAssertEqual(parsed.graphic.settings, settings)
        XCTAssertEqual(Array(invocation.arguments().prefix(5)), ["bundle", "export-graphic", bundle.standardizedFileURL.path, "--region", "chr1:1000-2001"])
        XCTAssertTrue(invocation.arguments().contains("812.5"))
    }

    func testExportGraphicRegionIsOneBasedAndClosed() async throws {
        let opened = try ViewerGraphicBundle(url: bundle)
        for (text, start, end) in [("chr1:1,001-2,000", 1000.0, 2000.0), ("chr1:5-5", 4.0, 5.0), ("1:5-5", 4.0, 5.0)] {
            let parsed = try XCTUnwrap(GenomicRegionArgument.parseRegion(text))
            let region = try opened.region(contig: parsed.contig, start: parsed.start, end: parsed.end)
            let figure = try await ViewerGraphicExport.figure(
                bundle: opened, region: region, trackIDs: ["sequence"],
                settings: .init(region: text, format: .png), viewState: nil, viewStateURL: nil
            )
            XCTAssertEqual(figure.scene.frame?.chromosome, "chr1", text)
            XCTAssertEqual(figure.scene.frame?.start, start, text)
            XCTAssertEqual(figure.scene.frame?.end, end, text)
        }
    }

    func testExportGraphicRefusesARegionItCannotDraw() async throws {
        let output = folder.appendingPathComponent("refused.png")
        for region in ["chr1:0-10", "chr1:10-5", "chr1:2990-3001", "chr2:1-10", "chr1", "chr1:a-b"] {
            do {
                _ = try await export(["--region", region, "--output-format", "png", "-o", output.path])
                XCTFail("\(region) was drawn")
            } catch {
                XCTAssertTrue(error is ViewerExportRefusal, "\(region): \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), region)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), region)
        }
        do {
            _ = try await export(["--region", "chr1:1-10", "--track", "nothing", "--output-format", "png", "-o", output.path])
            XCTFail("an unknown track was drawn")
        } catch {
            XCTAssertTrue(error is ViewerExportRefusal)
        }
    }

    func testExportGraphicRecordStatesTheRegionAsPassedAndResolved() async throws {
        let output = folder.appendingPathComponent("region.png")
        _ = try await export(["--region", "chr1:1,001-2,000", "--track", "sequence", "--output-format", "png", "-o", output.path])
        let record = try envelope(output)
        XCTAssertEqual(record.toolName, "lungfish-cli")
        XCTAssertEqual(record.tool.kind, "cli")
        XCTAssertEqual(record.workflowName, "lungfish bundle export-graphic")
        XCTAssertEqual(record.options.explicit["region"], .string("chr1:1,001-2,000"))
        XCTAssertEqual(record.options.resolvedDefaults["region"], .string("chr1:1001-2000"))
        XCTAssertEqual(record.options.resolvedDefaults["regionConvention"], .string("1-based closed"))
        XCTAssertEqual(record.options.resolvedDefaults["regionLength"], .integer(1000))
        XCTAssertEqual(record.argv, ["lungfish-cli"] + (try command([bundle.path, "--region", "chr1:1,001-2,000", "--track", "sequence",
                                                                    "--output-format", "png", "-o", output.path]).invocation().arguments()))
    }

    func testExportGraphicRecordHoldsEveryPixelSetting() async throws {
        let output = folder.appendingPathComponent("pixels.jpg")
        _ = try await export(["--region", "chr1:1001-2000", "--width", "400", "--include-ruler", "--output-format", "jpeg",
                              "--scale", "4", "-o", output.path])
        let record = try envelope(output)
        let resolved = record.options.resolvedDefaults
        for key in ["region", "regionConvention", "regionLength", "tracks", "includeRuler", "theme", "widthPoints", "heightPoints",
                    "pixelScale", "pixelWidth", "pixelHeight", "format", "jpegQuality", "rendererVersion", "sceneFormatVersion",
                    "fonts", "hostOSBuild", "degraded"] {
            XCTAssertNotNil(resolved[key], key)
        }
        XCTAssertNil(resolved["tiffCompression"])
        XCTAssertEqual(resolved["pixelScale"], .number(4))
        XCTAssertEqual(resolved["pixelWidth"], .integer(1600))
        XCTAssertEqual(resolved["rendererVersion"], .integer(ViewerFigureRasterizer.version))
        XCTAssertEqual(resolved["theme"], .string("light"))
        XCTAssertNil(record.options.explicit["theme"])
        XCTAssertEqual(record.options.defaults["theme"], .string("light"))
        XCTAssertEqual(record.options.defaults["tracks"], .array(["sequence", "genes", "repeats", "calls", "signal"].map { .string($0) }))
        XCTAssertEqual(record.options.explicit["scale"], .integer(4))
        XCTAssertFalse(resolved["hostOSBuild"]?.stringValue?.isEmpty ?? true)
        let output2 = folder.appendingPathComponent("dark.png")
        _ = try await export(["--region", "chr1:1-100", "--theme", "dark", "--output-format", "png", "-o", output2.path])
        XCTAssertEqual(try envelope(output2).options.explicit["theme"], .string("dark"))
        XCTAssertNil(try envelope(output2).options.defaults["theme"])
    }

    func testExportGraphicRecordNamesOnlyTheFilesTheDrawnTracksRead() async throws {
        let output = folder.appendingPathComponent("inputs.png")
        _ = try await export(["--region", "chr1:1001-2000", "--track", "sequence", "--track", "genes", "--output-format", "png", "-o", output.path])
        let inputs = try envelope(output).files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["manifest.json", "sequence.fa", "sequence.fa.fai", "genes.db"])
        for input in inputs {
            XCTAssertEqual(input.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: input.path)), input.path)
        }
        let written = try envelope(output).files.filter { $0.role == .output }
        XCTAssertEqual(written.first?.checksumSHA256, try ProvenanceFileHasher.sha256(of: output))
    }

    func testExportGraphicRecordsAnEmptyDegradedList() async throws {
        let output = folder.appendingPathComponent("empty.png")
        _ = try await export(["--region", "chr1:1101-1300", "--width", "2000", "--track", "genes", "--output-format", "png", "-o", output.path])
        XCTAssertEqual(try envelope(output).options.resolvedDefaults["degraded"], .array([]))
    }

    func testExportGraphicRecordsATrackItCannotDrawAndDrawsTheRest() async throws {
        let output = folder.appendingPathComponent("signal.png")
        _ = try await export(["--region", "chr1:1101-1300", "--width", "2000", "--track", "genes", "--track", "signal",
                              "--output-format", "png", "-o", output.path])
        XCTAssertEqual(try envelope(output).options.resolvedDefaults["degraded"], .array([.dictionary([
            "trackID": .string("signal"), "kind": .string("trackNotDrawn"), "reason": .string("no figure builder"),
        ])]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testExportGraphicDrawsTheVariantTrackAndNamesItsDatabase() async throws {
        let output = folder.appendingPathComponent("variant.png")
        _ = try await export(["--region", "chr1:1101-1300", "--track", "calls", "--output-format", "png", "-o", output.path])
        let record = try envelope(output)
        let inputs = record.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(inputs, ["manifest.json", "calls.db"])
        XCTAssertEqual(record.options.resolvedDefaults["tracks"], .array([.dictionary([
            "id": .string("calls"), "kind": .string("variant"), "displayMode": .string("summaryAndGenotypes"),
            "height": .number(46),
        ])]))
        XCTAssertEqual(record.options.resolvedDefaults["degraded"], .array([]))

        let opened = try ViewerGraphicBundle(url: bundle)
        let figure = try await ViewerGraphicExport.figure(
            bundle: opened, region: try opened.region(contig: "chr1", start: 1100, end: 1300), trackIDs: ["calls"],
            settings: .init(region: "chr1:1101-1300", format: .png), viewState: nil, viewStateURL: nil
        )
        let layers = figure.scene.items.compactMap { item -> ViewerFigureContextLayer? in
            if case .layer(let layer) = item { return layer }
            return nil
        }
        guard case .variantSummary(let bar) = layers.first, case .genotypeRows(let rows) = layers.last else {
            return XCTFail("expected the summary bar and the genotype rows: \(layers)")
        }
        XCTAssertEqual(bar.marks.map(\.start), [1150])
        XCTAssertEqual(rows.sampleNames, ["s1", "s2"])
    }

    func testPDFExportRecordLetsAReplayCheckIt() async throws {
        let first = folder.appendingPathComponent("first.pdf")
        let second = folder.appendingPathComponent("second.pdf")
        for output in [first, second] {
            _ = try await export(["--region", "chr1:1001-1100", "--include-ruler", "--output-format", "pdf", "-o", output.path])
        }
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        let metadata = try XCTUnwrap(try envelope(first).options.resolvedDefaults["pdfFixedMetadata"])
        XCTAssertEqual(metadata, try envelope(second).options.resolvedDefaults["pdfFixedMetadata"])
        guard case .dictionary(let fields) = metadata else { return XCTFail("pdfFixedMetadata is not a dictionary") }
        XCTAssertNotNil(fields["fileID"])
        XCTAssertNil(try envelope(first).options.resolvedDefaults["pixelScale"])
    }

    /// QA ruling item 4 and R-QM1. A PDF the normalizer keeps as written records UX's degraded fact and no fixed
    /// metadata, and a normal render of the same figure records neither the fact nor any other.
    func testAPDFKeptAsWrittenIsADegradedFact() async throws {
        let arguments = ["--region", "chr1:1101-1300", "--width", "2000", "--track", "genes", "--output-format", "pdf"]
        let kept = folder.appendingPathComponent("kept.pdf")
        _ = try await command([bundle.path] + arguments + ["-o", kept.path]).export(
            events: CLIEventEmitter(enabled: false) { _ in }
        ) { scene, format, pixelScale in
            let made = try ViewerFigureRasterizer.renderReporting(scene, format: format, pixelScale: pixelScale)
            return ViewerFigureRendering(data: made.data, pdfKeptAsWritten: "the PDF has no trailer keyword")
        }
        let keptResolved = try envelope(kept).options.resolvedDefaults
        XCTAssertEqual(keptResolved["degraded"], .array([.dictionary([
            "trackID": .string("figure"), "kind": .string("pdfKeptAsWritten"),
            "reason": .string("This PDF keeps the creation date, modification date and file ID that macOS wrote, so "
                + "running its command again writes a file with a different checksum. The file has no trailer."),
        ])]))
        XCTAssertNil(keptResolved["pdfFixedMetadata"])

        let normal = folder.appendingPathComponent("normal.pdf")
        _ = try await export(arguments + ["-o", normal.path])
        let normalResolved = try envelope(normal).options.resolvedDefaults
        XCTAssertEqual(normalResolved["degraded"], .array([]))
        XCTAssertNotNil(normalResolved["pdfFixedMetadata"])
    }

    func testAPDFTakesNoScale() throws {
        XCTAssertThrowsError(try command([bundle.path, "--region", "chr1:1-10", "--output-format", "pdf", "--scale", "2", "-o", "/tmp/x.pdf"]))
        XCTAssertThrowsError(try command([bundle.path, "--region", "chr1:1-10", "--output-format", "png", "--scale", "3", "-o", "/tmp/x.png"]))
    }

    func testEachPDFReasonReadsAsOneSentence() {
        let sentences = [
            "the PDF has no trailer keyword": "The file has no trailer.",
            "the last trailer has 0 /Info references": "The trailer names no document information.",
            "the PDF has 2 /ID entries, 1 of them as expected": "The file has more than one file ID.",
            "the PDF has 2 /CreationDate entries, 1 of them as expected": "A date appears more than once.",
            "/ModDate is outside the Info object 7": "A date appears outside the document information.",
        ]
        for (reason, sentence) in sentences {
            XCTAssertEqual(BundleExportGraphicRecord.pdfReasonSentence(reason), sentence, reason)
        }
        XCTAssertTrue(BundleExportGraphicRecord.pdfKeptAsWrittenFact("the PDF has no trailer keyword").hasPrefix(
            "This PDF keeps the creation date, modification date and file ID that macOS wrote, so running its command again"
        ))
    }
}

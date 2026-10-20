// ViewerGraphicsExportCLIGUIParityReplayTests.swift - The viewer image export of a bundle against its replay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2), BIO ruling Q-G3 item 8, QA ruling QA-GFX-mask items 4 and 5, on lane Q30's harness.
// Each case shows a fixture bundle in the viewer and exports Tracks in one format on three sides that start as copies
// of one root.
//
// - Side A is today's AppKit capture of the same view (`viewerExportData`), which stays live for the captures of
//   other content. It is written beside the side roots and is a measurement only, never a pass or fail: the case
//   prints the share of pixels that differ from side C and the largest channel change, decoded to RGBA at C's pixel
//   size, and copies both images to `LUNGFISH_PARITY_DUMP` when it is set (O17, the declared visual difference).
// - Side C is `finishViewerGraphicsExport`, which writes the view state, begins the row and runs the built
//   `lungfish-cli bundle export-graphic` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with the view-state file copied into its
//   root. C against C' is compared byte for byte under `.files` with the standard masks, and both records name the
//   bytes written by their full SHA-256.
//
// Every case root sits four folders below the scratch folder, so no record's sidecar lookup lists the user temporary
// folder (12.31 M4). It launches the built lungfish-cli, so its name ends in ReplayTests (the integration tier).

import AppKit
import Foundation
import ImageIO
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViewerGraphicsExportCLIGUIParityReplayTests: XCTestCase {
    /// The tracks a fixture bundle holds besides its sequence.
    enum Kind: String, Sendable {
        case sequence
        case annotation
        case variant
    }

    var scratch: URL!
    var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "viewer-graphics-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testEachFormatReplaysToTheRecordedDigest() async throws {
        for format in ViewerGraphicFormat.allCases {
            try await assertCase(.variant, format)
        }
    }

    func testSequenceAndAnnotationCasesMatchTheirReplay() async throws {
        for kind in [Kind.sequence, .annotation] {
            for format in ViewerGraphicFormat.allCases {
                try await assertCase(kind, format)
            }
        }
    }

    // MARK: - One case

    func assertCase(_ kind: Kind, _ format: ViewerGraphicFormat) async throws {
        let name = "\(kind.rawValue)-\(format.rawValue)"
        let caseRoot = scratch.appendingPathComponent("levels/deep/run/\(name)", isDirectory: true)
        let capture = caseRoot.appendingPathComponent("capture-A.\(format.fileExtension)")
        let figureName = "figure.\(format.fileExtension)"
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        defer { controller.close() }
        let viewer = try XCTUnwrap(controller.mainSplitViewController?.viewerController)
        let cli = harness.cliBinary

        let runs = try await harness.run(
            in: caseRoot,
            fixture: { root in try Self.makeBundle(kind, in: root) },
            sideA: { root in
                try viewer.displayBundle(at: Self.bundleURL(in: root), mode: .sequence(name: "chr1", restoreViewState: false))
                let data = try delegate.viewerExportData(
                    viewerController: viewer, scope: .tracks, format: format, bitmapScale: 2
                )
                try data.write(to: capture)
                return RouteParitySideOutcome(end: .completed, detail: "AppKit capture, a measurement only")
            },
            sideC: { root in
                let bundle = Self.bundleURL(in: root)
                try viewer.displayBundle(at: bundle, mode: .sequence(name: "chr1", restoreViewState: false))
                let begun = try XCTUnwrap(delegate.finishViewerGraphicsExport(
                    viewerController: viewer, content: .referenceBundle(bundle), scope: .tracks, format: format,
                    bitmapScale: 2, outputURL: root.appendingPathComponent(figureName),
                    presentAlert: { XCTFail("\(name): \($0.message)") },
                    runner: CLIViewerExportRunner(cliURLOverride: cli)
                ))
                let outcome = await begun.task.value
                let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
                let warned = item?.logEntries.contains { $0.level == .warning } ?? false
                // Side C' runs on the inputs the row's command ran on, the view-state file the app wrote and the
                // bundle as the viewer left it, since opening the bundle rewrote `variants/calls.db` before the leaf
                // read it.
                let replayRoot = RouteParityHarness.root(of: .cPrime, in: caseRoot)
                let inputs = root.appendingPathComponent(ViewerExportSelection.inputsFolderName)
                try FileManager.default.copyItem(
                    at: inputs, to: replayRoot.appendingPathComponent(ViewerExportSelection.inputsFolderName)
                )
                try FileManager.default.removeItem(at: Self.bundleURL(in: replayRoot))
                try FileManager.default.copyItem(at: bundle, to: Self.bundleURL(in: replayRoot))
                let completed = { if case .completed = outcome { return true } else { return false } }()
                return RouteParitySideOutcome(
                    end: completed ? (warned ? .completedWithWarnings : .completed) : .failed, detail: "\(outcome)",
                    recordedCommand: item?.cliCommand
                )
            }
        )
        XCTAssertNotEqual(runs.c.outcome.end, .failed, "\(name): \(runs.c.outcome.detail)")
        XCTAssertNotEqual(runs.cPrime.outcome.end, .failed, "\(name): \(runs.cPrime.outcome.detail)")
        let found = try harness.differences(runs.c, runs.cPrime)
        XCTAssertEqual(found.map(\.description), [], "\(name): side C' differs from side C")

        for run in [runs.c, runs.cPrime] {
            let figure = run.root.appendingPathComponent(figureName)
            let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: figure)))
            let written = record.files.filter { $0.role == .output }
            XCTAssertEqual(written.count, 1, name)
            XCTAssertEqual(written.first?.checksumSHA256, try ProvenanceFileHasher.sha256(of: figure), "\(name) \(run.side)")
        }
        let digestC = try ProvenanceFileHasher.sha256(of: runs.c.root.appendingPathComponent(figureName))
        let digestCPrime = try ProvenanceFileHasher.sha256(of: runs.cPrime.root.appendingPathComponent(figureName))
        XCTAssertEqual(digestC, digestCPrime, "\(name): the replay writes the recorded bytes")

        try Self.measure(name, capture: capture, figure: runs.c.root.appendingPathComponent(figureName), format: format)
    }

    // MARK: - Side A against side C, a measurement

    /// Prints the share of pixels that differ and the largest channel change between the capture and the figure,
    /// both drawn to RGBA at the figure's pixel size, and copies both images to `LUNGFISH_PARITY_DUMP`.
    static func measure(_ name: String, capture: URL, figure: URL, format: ViewerGraphicFormat) throws {
        let size = try pixelSize(of: figure, format: format)
        let a = try rgba(capture, format: format, size: size)
        let c = try rgba(figure, format: format, size: size)
        var differing = 0
        var largest = 0
        for pixel in 0..<(size.width * size.height) {
            var differs = false
            for channel in 0..<4 {
                let change = abs(Int(a[pixel * 4 + channel]) - Int(c[pixel * 4 + channel]))
                largest = max(largest, change)
                differs = differs || change > 0
            }
            if differs { differing += 1 }
        }
        let share = Double(differing) / Double(max(1, size.width * size.height))
        print("PARITY-A-C \(name) size=\(size.width)x\(size.height) differing=\(differing) share=\(share) largestChannelChange=\(largest)")
        if let dump = ProcessInfo.processInfo.environment["LUNGFISH_PARITY_DUMP"] {
            let folder = URL(fileURLWithPath: dump, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (side, url) in [("A", capture), ("C", figure)] {
                let target = folder.appendingPathComponent("\(name)-\(side).\(format.fileExtension)")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
            }
        }
    }

    static func pixelSize(of url: URL, format: ViewerGraphicFormat) throws -> (width: Int, height: Int) {
        if format == .pdf {
            let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
            let box = page.getBoxRect(.mediaBox)
            return (max(1, Int(box.width.rounded(.up))), max(1, Int(box.height.rounded(.up))))
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    static func rgba(_ url: URL, format: ViewerGraphicFormat, size: (width: Int, height: Int)) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if format == .pdf {
            let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
            let box = page.getBoxRect(.mediaBox)
            context.scaleBy(x: rect.width / max(1, box.width), y: rect.height / max(1, box.height))
            context.drawPDFPage(page)
        } else {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            context.draw(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), in: rect)
        }
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: size.width * size.height * 4))
    }

    // MARK: - The fixture

    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent("fixture.lungfishref", isDirectory: true)
    }

    /// A bundle with `chr1` of 3,000 bases in a plain FASTA, the annotation track `genes` for `.annotation` and
    /// `.variant`, and the variant track `calls` of one SNP at 1151 for samples `s1` and `s2` for `.variant`.
    static func makeBundle(_ kind: Kind, in root: URL) throws {
        let bundle = bundleURL(in: root)
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
        try "chr1\t3000\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        var annotations: [AnnotationTrackInfo] = []
        var variants: [VariantTrackInfo] = []
        if kind != .sequence {
            let bed = root.appendingPathComponent("genes.bed")
            try "chr1\t1100\t1400\tgene-a\t0\t+\n".write(to: bed, atomically: true, encoding: .utf8)
            _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
            try FileManager.default.removeItem(at: bed)
            annotations.append(AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"
            ))
        }
        if kind == .variant {
            let vcf = root.appendingPathComponent("calls.vcf")
            try ([
                "##fileformat=VCFv4.2", "##contig=<ID=chr1,length=3000>",
                "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
                "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2",
                "chr1\t1151\t.\tA\tG\t50\tPASS\t.\tGT\t0/1\t1/1",
            ].joined(separator: "\n") + "\n").write(to: vcf, atomically: true, encoding: .utf8)
            _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: bundle.appendingPathComponent("variants/calls.db"))
            try FileManager.default.removeItem(at: vcf)
            variants.append(VariantTrackInfo(
                id: "calls", name: "Calls", path: "variants/calls.vcf.gz", indexPath: "variants/calls.vcf.gz.tbi",
                databasePath: "variants/calls.db"
            ))
        }
        try BundleManifest(
            name: "Parity Fixture",
            identifier: "org.lungfish.viewer-graphics-parity",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: annotations,
            variants: variants,
            tracks: [],
            recordStore: nil
        ).save(to: bundle)
    }
}

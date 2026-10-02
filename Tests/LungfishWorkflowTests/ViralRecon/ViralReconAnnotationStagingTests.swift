// ViralReconAnnotationStagingTests.swift - GFF3 annotations staged under the .gff name viralrecon accepts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import XCTest
@testable import LungfishWorkflow

final class ViralReconAnnotationStagingTests: XCTestCase {
    /// nf-core/viralrecon 3.0.0's `gff` pattern.
    private static let gffPattern = #"^\S+\.gff(\.gz)?$"#

    private var root: URL!

    override func setUpWithError() throws {
        root = try ViralReconWorkflowTestFixtures.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let gff3Text = "##gff-version 3\nMN908947.3\tGenbank\tgene\t21563\t25384\t.\t+\t.\tID=gene-S;Name=S\n"

    func testStagedNamesSatisfyTheSchemaAndKeepCompression() {
        let expectations: [(String, String?)] = [
            ("genes.gff3", "genes.gff"),
            ("genes.gff3.gz", "genes.gff.gz"),
            ("MN908947.3.gff3", "MN908947.3.gff"),
            ("GENES.GFF3", "GENES.gff"),
            ("genes.GFF", "genes.gff"),
            ("genes.gff", nil),
            ("genes.gff.gz", nil),
            ("genes.gtf", nil),
            ("genes.txt", nil),
        ]
        for (name, expected) in expectations {
            let staged = ViralReconAnnotationStaging.stagedFileName(for: name)
            XCTAssertEqual(staged, expected, name)
            if let staged {
                XCTAssertNotNil(("/run/" + staged).range(of: Self.gffPattern, options: .regularExpression), staged)
            }
        }
    }

    func testBundleGFF3IsCopiedIntoTheRunBundleWithItsBytesAndBundlePath() throws {
        let bundle = root.appendingPathComponent("MN908947.3.lungfishref", isDirectory: true)
        let gff3 = try write(gff3Text, to: bundle.appendingPathComponent("genome/genes.gff3"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let params = ["gff": gff3.path, "platform": "illumina"]

        let staged = try XCTUnwrap(try ViralReconAnnotationStaging.stage(params: params, inRunBundle: runBundle))

        XCTAssertEqual(staged.stagedURL, runBundle.appendingPathComponent("inputs/reference/genes.gff"))
        XCTAssertEqual(try Data(contentsOf: staged.stagedURL), try Data(contentsOf: gff3))
        XCTAssertEqual(staged.sha256, try FileDigest.sha256(of: gff3))
        XCTAssertEqual(staged.sourceURL, gff3)
        XCTAssertEqual(staged.sourceBundleURL, bundle)
        XCTAssertEqual(staged.sourceBundleRelativePath, "genome/genes.gff3")
        XCTAssertTrue(staged.summary.contains("genome/genes.gff3"), staged.summary)

        let launch = ViralReconAnnotationStaging.launchParams(params, using: staged)
        XCTAssertEqual(launch, ["gff": staged.stagedURL.path, "platform": "illumina"])
        XCTAssertNotNil(launch["gff"]?.range(of: Self.gffPattern, options: .regularExpression))

        guard case .dictionary(let record) = staged.provenanceValue else {
            return XCTFail("the provenance record is a dictionary")
        }
        XCTAssertEqual(record["parameter"], .string("gff"))
        XCTAssertEqual(record["source"], .file(gff3))
        XCTAssertEqual(record["staged"], .file(staged.stagedURL))
        XCTAssertEqual(record["sourceBundle"], .file(bundle))
        XCTAssertEqual(record["sourceBundleRelativePath"], .string("genome/genes.gff3"))
        XCTAssertEqual(record["sha256"], .string(staged.sha256))
    }

    func testLooseGFF3HasNoBundlePath() throws {
        let gff3 = try write(gff3Text, to: root.appendingPathComponent("downloads/MN908947.3.gff3"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let staged = try XCTUnwrap(try ViralReconAnnotationStaging.stage(params: ["gff": gff3.path], inRunBundle: runBundle))

        XCTAssertEqual(staged.stagedURL.lastPathComponent, "MN908947.3.gff")
        XCTAssertNil(staged.sourceBundleURL)
        XCTAssertNil(staged.sourceBundleRelativePath)
        guard case .dictionary(let record) = staged.provenanceValue else {
            return XCTFail("the provenance record is a dictionary")
        }
        XCTAssertNil(record["sourceBundle"])
        XCTAssertNil(record["sourceBundleRelativePath"])
    }

    func testRestagingReplacesAnEarlierCopy() throws {
        let gff3 = try write(gff3Text, to: root.appendingPathComponent("genes.gff3"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        _ = try write("stale\n", to: runBundle.appendingPathComponent("inputs/reference/genes.gff"))

        let staged = try XCTUnwrap(try ViralReconAnnotationStaging.stage(params: ["gff": gff3.path], inRunBundle: runBundle))

        XCTAssertEqual(try Data(contentsOf: staged.stagedURL), try Data(contentsOf: gff3))
    }

    func testAnAnnotationAlreadyAtTheStagedPathIsNeverReplaced() throws {
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let upper = try write(gff3Text, to: runBundle.appendingPathComponent("inputs/reference/genes.GFF"))

        XCTAssertNil(try ViralReconAnnotationStaging.stage(params: ["gff": upper.path], inRunBundle: runBundle))
        XCTAssertEqual(try String(contentsOf: upper, encoding: .utf8), gff3Text, "the caller's file must survive")
    }

    func testNothingIsStagedWhenTheNameAlreadyPassesOrThereIsNoLocalAnnotation() throws {
        let gff = try write(gff3Text, to: root.appendingPathComponent("genes.gff"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        for params in [
            ["gff": gff.path],
            ["platform": "illumina"],
            ["gff": ""],
            ["gff": "https://example.org/genes.gff3"],
        ] {
            XCTAssertNil(try ViralReconAnnotationStaging.stage(params: params, inRunBundle: runBundle), "\(params)")
            XCTAssertEqual(ViralReconAnnotationStaging.launchParams(params, using: nil), params)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runBundle.path), "nothing is written when nothing is staged")
    }

    func testMissingGFF3IsReportedBeforeAnythingIsWritten() {
        let missing = root.appendingPathComponent("absent.gff3")
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        XCTAssertThrowsError(try ViralReconAnnotationStaging.stage(params: ["gff": missing.path], inRunBundle: runBundle)) { error in
            XCTAssertEqual(error as? ViralReconAnnotationStaging.StagingError, .annotationNotFound(missing))
            XCTAssertTrue(error.localizedDescription.contains(missing.path), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runBundle.path))
    }
}

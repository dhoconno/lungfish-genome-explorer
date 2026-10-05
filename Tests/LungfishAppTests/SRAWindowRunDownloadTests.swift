// SRAWindowRunDownloadTests.swift - The window's download of one SRA run and its fallback to the SRA Toolkit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishKit
@testable import LungfishApp

/// The window downloads each SRA run through `SRAWindowRunDownload.download`.
/// ENA's mirror serves the files ENA lists, and the SRA Toolkit fetches the
/// whole run when the mirror cannot. The window's `streamingDownload` throws
/// `DatabaseServiceError.serverError` for an HTTP error status and URLSession's
/// error for a broken transfer, so the scripted mirror throws the same. The
/// toolkit is a stub, so no test reaches the network.
final class SRAWindowRunDownloadTests: XCTestCase {

    func testMirrorServingEveryFileRecordsENA() async throws {
        let run = try await Self.download(mirror: { _ in Self.gzipFixture })

        XCTAssertEqual(run.download.source.rawValue, "ENA")
        XCTAssertEqual(run.download.fastqFiles.map(\.lastPathComponent), ["SRR27069570_1.fastq.gz", "SRR27069570_2.fastq.gz"])
        XCTAssertEqual(run.download.enaSteps.map(\.toolName), ["https-download", "https-download"])
        XCTAssertEqual(run.toolkitStatusLines, [])
    }

    func testFileFailingTheCheckFallsBackToTheToolkitAsAnIncompleteMirror() async throws {
        let run = try await Self.download(mirror: { url in
            url.lastPathComponent.hasSuffix("_2.fastq.gz") ? Self.directoryListing : Self.gzipFixture
        })

        XCTAssertEqual(run.download.source.rawValue, "SRA Toolkit (ENA mirror incomplete)")
        XCTAssertEqual(run.toolkitStatusLines, ["ENA mirror is missing files for SRR27069570; using SRA Toolkit..."])
        XCTAssertEqual(run.download.fastqFiles, run.toolkitFiles)
        XCTAssertEqual(run.download.enaSteps.count, 0)
        XCTAssertEqual(run.stagedFiles, [], "no mate from ENA may stay beside the toolkit's files")
    }

    func testToolkitRouteRecordsSRAToolkit() async throws {
        let run = try await Self.download(
            route: .sraToolkit(enaRecord: nil, reason: "ENA returned HTTP 500 (server error) for SRR27069570"),
            mirror: { url in
                XCTFail("the toolkit route fetched \(url.lastPathComponent) from ENA's mirror")
                return Self.gzipFixture
            }
        )

        XCTAssertEqual(run.download.source.rawValue, "SRA Toolkit")
        XCTAssertEqual(run.toolkitStatusLines, ["ENA returned HTTP 500 (server error) for SRR27069570; using SRA Toolkit..."])
        XCTAssertEqual(run.download.fastqFiles, run.toolkitFiles)
    }

    func testCancelledTransferStopsTheDownload() async throws {
        do {
            _ = try await Self.download(mirror: { url in
                guard url.lastPathComponent.hasSuffix("_2.fastq.gz") else { return Self.gzipFixture }
                throw CancellationError()
            })
            XCTFail("a cancelled transfer must stop the download")
        } catch is CancellationError {
            // Expected.
        }
    }

    // MARK: - A failed transfer falls back as `fetch sra download` does

    func testHTTPErrorFromTheMirrorFallsBackToTheToolkitAsAFailedTransfer() async throws {
        let run = try await Self.download(mirror: { url in
            guard url.lastPathComponent.hasSuffix("_2.fastq.gz") else { return Self.gzipFixture }
            throw DatabaseServiceError.serverError(message: "HTTP 500 downloading \(url.lastPathComponent)")
        })

        XCTAssertEqual(run.download.source.rawValue, "SRA Toolkit (ENA transfer failed)")
        XCTAssertEqual(run.toolkitStatusLines, ["ENA transfer failed for SRR27069570; using SRA Toolkit..."])
        XCTAssertEqual(run.download.fastqFiles, run.toolkitFiles)
        XCTAssertEqual(run.download.enaSteps.count, 0)
        XCTAssertEqual(run.stagedFiles, [], "no mate from ENA may stay beside the toolkit's files")
    }

    func testDroppedConnectionFallsBackToTheToolkitAsAFailedTransfer() async throws {
        let run = try await Self.download(mirror: { url in
            guard url.lastPathComponent.hasSuffix("_2.fastq.gz") else { return Self.gzipFixture }
            throw URLError(.networkConnectionLost)
        })

        XCTAssertEqual(run.download.source.rawValue, "SRA Toolkit (ENA transfer failed)")
        XCTAssertEqual(run.toolkitStatusLines, ["ENA transfer failed for SRR27069570; using SRA Toolkit..."])
        XCTAssertEqual(run.download.fastqFiles, run.toolkitFiles)
        XCTAssertEqual(run.download.enaSteps.count, 0)
        XCTAssertEqual(run.stagedFiles, [], "no mate from ENA may stay beside the toolkit's files")
    }

    // MARK: - Helpers

    /// An empty gzip stream, which passes the download check's magic-byte test.
    private static let gzipFixture = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    /// The directory listing ENA's mirror serves with HTTP 200 for a missing mate.
    private static let directoryListing = Data("<html><head><title>Index of /vol1/fastq</title></head></html>".utf8)

    private struct Run {
        let download: SRAWindowRunDownload
        let toolkitStatusLines: [String]
        let toolkitFiles: [URL]
        /// The files left in the staging folder, which the toolkit stub never writes to.
        let stagedFiles: [String]
    }

    /// ENA lists a paired run, with the size of the gzip fixture for each mate.
    private static func pairedRecord() throws -> ENAReadRecord {
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/SRR27069570"
        let json = """
        {"run_accession": "SRR27069570", "library_layout": "PAIRED",
         "fastq_ftp": "\(folder)/SRR27069570_1.fastq.gz;\(folder)/SRR27069570_2.fastq.gz",
         "fastq_bytes": "\(gzipFixture.count);\(gzipFixture.count)"}
        """
        return try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
    }

    private static func download(
        route: SRAFASTQDownloadRoute? = nil,
        mirror: (URL) async throws -> Data
    ) async throws -> Run {
        let batchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-window-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: batchDir) }

        let toolkitFiles = ["SRR27069570_1.fastq", "SRR27069570_2.fastq"].map {
            URL(fileURLWithPath: "/tmp/sra-window-run-toolkit").appendingPathComponent($0)
        }
        var toolkitStatusLines: [String] = []
        let download = try await SRAWindowRunDownload.download(
            accession: "SRR27069570",
            route: try route ?? .enaMirror(pairedRecord()),
            into: batchDir,
            mirrorFile: { url, _, _ in try await mirror(url) },
            toolkit: { status in
                // Under Prefer ENA the toolkit only ever runs as a fallback,
                // which the Operations panel logs as a warning.
                XCTAssertEqual(status.level, .warning, status.line)
                toolkitStatusLines.append(status.line)
                return toolkitFiles
            }
        )
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: batchDir.path).sorted()
        return Run(
            download: download,
            toolkitStatusLines: toolkitStatusLines,
            toolkitFiles: toolkitFiles,
            stagedFiles: stagedFiles
        )
    }
}

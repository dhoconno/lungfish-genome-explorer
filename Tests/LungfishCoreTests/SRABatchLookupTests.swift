// SRABatchLookupTests.swift - Tests for batch ENA lookup
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

final class SRABatchLookupTests: XCTestCase {

    func testBatchLookupFetchesAccessionsInOrderAndReportsProgress() async throws {
        let mockClient = MockHTTPClient()
        let service = ENAService(httpClient: mockClient)
        let progress = BatchProgressRecorder()

        await mockClient.register(
            pattern: "accession=SRR000001",
            response: .json([Self.readRecord(accession: "SRR000001", readCount: "100")])
        )
        await mockClient.register(
            pattern: "accession=SRR000002",
            response: .json([Self.readRecord(accession: "SRR000002", readCount: "200")])
        )

        let results = try await service.searchReadsBatch(
            accessions: ["SRR000001", "SRR000002"],
            concurrency: 1,
            progress: { completed, total in
                progress.record(completed: completed, total: total)
            }
        )

        XCTAssertEqual(results.map(\.runAccession), ["SRR000001", "SRR000002"])
        XCTAssertEqual(results.map(\.readCount), [100, 200])
        XCTAssertEqual(progress.snapshot, [
            BatchProgress(completed: 1, total: 2),
            BatchProgress(completed: 2, total: 2),
        ])

        let requestURLs = await mockClient.requests.compactMap { $0.url?.absoluteString }
        XCTAssertEqual(requestURLs.count, 2)
        XCTAssertTrue(requestURLs[0].contains("accession=SRR000001"))
        XCTAssertTrue(requestURLs[0].contains("result=read_run"))
        XCTAssertTrue(requestURLs[1].contains("accession=SRR000002"))
    }

    func testBatchLookupSkipsFailedAccessionsAndStillCompletesProgress() async throws {
        let mockClient = MockHTTPClient()
        let service = ENAService(httpClient: mockClient)
        let progress = BatchProgressRecorder()

        await mockClient.register(
            pattern: "accession=SRR_MISSING",
            response: .error(statusCode: 500, message: "ENA unavailable")
        )
        await mockClient.register(
            pattern: "accession=SRR000003",
            response: .json([Self.readRecord(accession: "SRR000003", readCount: "300")])
        )

        let results = try await service.searchReadsBatch(
            accessions: ["SRR_MISSING", "SRR000003"],
            concurrency: 1,
            progress: { completed, total in
                progress.record(completed: completed, total: total)
            }
        )

        XCTAssertEqual(results.map(\.runAccession), ["SRR000003"])
        XCTAssertEqual(results.first?.readCount, 300)
        XCTAssertEqual(progress.snapshot, [
            BatchProgress(completed: 1, total: 2),
            BatchProgress(completed: 2, total: 2),
        ])
    }

    private static func readRecord(accession: String, readCount: String) -> [String: Any] {
        [
            "run_accession": accession,
            "experiment_accession": "ERX\(accession.suffix(3))",
            "sample_accession": "SAMEA\(accession.suffix(3))",
            "study_accession": "PRJEB1",
            "experiment_title": "Mock read run \(accession)",
            "library_layout": "PAIRED",
            "library_source": "GENOMIC",
            "library_strategy": "WGS",
            "instrument_platform": "ILLUMINA",
            "base_count": "1000",
            "read_count": readCount,
            "fastq_ftp": "ftp.sra.ebi.ac.uk/vol1/fastq/\(accession)_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/\(accession)_2.fastq.gz",
            "fastq_bytes": "123;456",
            "fastq_md5": "abc;def",
            "first_public": "2024-01-01",
        ]
    }
}

private struct BatchProgress: Equatable {
    let completed: Int
    let total: Int
}

private final class BatchProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BatchProgress] = []

    var snapshot: [BatchProgress] {
        lock.withLock { values }
    }

    func record(completed: Int, total: Int) {
        lock.withLock {
            values.append(BatchProgress(completed: completed, total: total))
        }
    }
}

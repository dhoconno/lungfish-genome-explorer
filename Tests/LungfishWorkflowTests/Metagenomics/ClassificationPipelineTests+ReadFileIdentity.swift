// ClassificationPipelineTests+ReadFileIdentity.swift - A Kraken2 run records the size and digest of each read file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane READ-IDENTITY (BIO-READ-IDENTITY 4.2). When a run ends, its sidecar records the size and SHA-256
// of every read file Extract and BLAST will read, so they can tell by one `stat` that the files changed. The digest
// comes from the run's digest cache, so a payload the provenance step already hashed is read once.

import XCTest
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ClassificationPipelineTests: XCTestCase {

    func testRunRecordsSizeAndDigestOfEachReadFile() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()
        let payload = try XCTUnwrap(config.inputFiles.first)
        let cache = ProvenanceDigestCache()

        _ = try await ProvenanceDigestCache.scoped(cache) {
            try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)
        }

        let loaded = try ClassificationResult.load(from: config.outputDirectory)
        let identities = try XCTUnwrap(loaded.config.readFileIdentities, "the run recorded no read file identities")
        XCTAssertEqual(identities.map { $0.url.standardizedFileURL.path }, [payload.standardizedFileURL.path])
        XCTAssertEqual(identities.map(\.sizeBytes), [try ProvenanceFileHasher.fileSize(of: payload)])
        XCTAssertEqual(identities.map(\.sha256), [try FileDigest.sha256(of: payload)])
        XCTAssertEqual(cache.readCount(of: payload), 1, "the payload is read once for provenance and the record")
    }
}

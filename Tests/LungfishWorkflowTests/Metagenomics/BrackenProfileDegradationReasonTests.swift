// BrackenProfileDegradationReasonTests.swift - A result keeps opening when a later release names a new reason
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane B7 (decision C1). Phase 2.9 writes a new degradation reason, `belowThreshold`, for
// a Bracken profile where no taxon reaches Bracken's threshold. The reason is stored in the
// `profileOutcome` of `classification-result.json`, so a reader that fails on a raw value it does
// not know fails the whole sidecar and the result does not open. These tests hold this build to
// reading any reason, to writing it back unchanged and to showing it as plain text.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class BrackenProfileDegradationReasonTests: XCTestCase {

    /// The raw value Phase 2.9 writes. This build knows it, and these tests still hold, because
    /// they read its token and never its case. `futureReason` is the token for the case check.
    private let laterReason = "belowThreshold"
    private let futureReason = "aReasonNoReleaseNamesYet"
    private let message = "No taxon at species level reaches the threshold of 10 reads."

    /// The eight tokens builds write. The first seven are stored in sidecars that released builds
    /// wrote, and `belowThreshold` is stored in the ones the Preview after 2026.10.15 writes. A
    /// change to one is a defect. Adding a reason adds a row.
    private let releasedTokens: [(BrackenProfileDegradationReason, String)] = [
        (.unsupportedRank, "unsupportedRank"),
        (.rankAbsentFromReport, "rankAbsentFromReport"),
        (.distributionUnavailable, "distributionUnavailable"),
        (.toolUnavailable, "toolUnavailable"),
        (.toolFailed, "toolFailed"),
        (.outputMissing, "outputMissing"),
        (.outputInvalid, "outputInvalid"),
        (.belowThreshold, "belowThreshold"),
    ]

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bracken-reason-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var resolution: BrackenProfileResolution {
        BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-special-silva",
            installationRecipe: .kraken2Special(type: .silva),
            request: .automatic
        )
    }

    // MARK: - The reason

    func testEachReleasedReasonKeepsItsTokenAndNeverDecodesAsUnknown() throws {
        XCTAssertEqual(releasedTokens.count, 8)
        for (reason, token) in releasedTokens {
            XCTAssertEqual(reason.rawValue, token)
            XCTAssertEqual(BrackenProfileDegradationReason(rawValue: token), reason)

            let decoded = try JSONDecoder().decode(
                [BrackenProfileDegradationReason].self,
                from: Data("[\"\(token)\"]".utf8)
            )
            XCTAssertEqual(decoded, [reason])
            if case .unknown = decoded[0] {
                XCTFail("\(token) decoded as an unknown reason")
            }
            XCTAssertEqual(
                String(decoding: try JSONEncoder().encode([reason]), as: UTF8.self),
                "[\"\(token)\"]"
            )
        }
    }

    func testAnUnknownTokenBecomesAnUnknownCaseThatKeepsIt() {
        let reason = BrackenProfileDegradationReason(rawValue: futureReason)

        XCTAssertEqual(reason, .unknown(futureReason))
        XCTAssertEqual(reason.rawValue, futureReason)
        XCTAssertEqual("\(reason)", futureReason)
        guard case .unknown(let token) = reason else {
            return XCTFail("\(futureReason) did not become an unknown reason")
        }
        XCTAssertEqual(token, futureReason)

        // An empty token is kept too, and the whole token is kept, spaces and all.
        XCTAssertEqual(BrackenProfileDegradationReason(rawValue: "").rawValue, "")
        XCTAssertEqual(BrackenProfileDegradationReason(rawValue: " toolFailed ").rawValue, " toolFailed ")
    }

    func testReasonsAreEqualAndHashedByTheirToken() {
        XCTAssertEqual(BrackenProfileDegradationReason.unknown("toolFailed"), .toolFailed)
        XCTAssertEqual(
            Set([BrackenProfileDegradationReason.toolFailed, .unknown("toolFailed"), .outputMissing]).count,
            2
        )
        XCTAssertNotEqual(BrackenProfileDegradationReason.unknown("a"), .unknown("b"))
        XCTAssertNotEqual(BrackenProfileDegradationReason.unknown("toolFailed "), .toolFailed)
    }

    func testAReasonThatIsNotAStringStillFailsToDecode() {
        // Only an unknown string is tolerated. A number is a damaged file, not a later release.
        XCTAssertThrowsError(
            try JSONDecoder().decode([BrackenProfileDegradationReason].self, from: Data("[7]".utf8))
        )
    }

    // MARK: - The outcome

    func testAnOutcomeWithAnUnknownReasonStillDecodes() throws {
        let outcome = try JSONDecoder().decode(
            BrackenProfileOutcome.self,
            from: try degradedOutcomeJSON(reason: laterReason)
        )

        XCTAssertEqual(outcome.state, .degraded)
        XCTAssertEqual(outcome.reason?.rawValue, laterReason)
        XCTAssertEqual(outcome.message, message)
        XCTAssertEqual(outcome.resolution, resolution)
        XCTAssertEqual(outcome.toolVersion, "3.0.1")
    }

    func testAnOutcomeWithAnUnknownReasonIsWrittenBackWithTheSameToken() throws {
        let outcome = try JSONDecoder().decode(
            BrackenProfileOutcome.self,
            from: try degradedOutcomeJSON(reason: futureReason)
        )
        XCTAssertEqual(outcome.reason, .unknown(futureReason))

        let encoded = try JSONEncoder().encode(outcome)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["reason"] as? String, futureReason)
        XCTAssertEqual(try JSONDecoder().decode(BrackenProfileOutcome.self, from: encoded), outcome)
    }

    // MARK: - The sidecar

    func testASidecarWithAnUnknownReasonStillLoadsWithEveryOtherField() throws {
        let saved = try saveResult(reason: .toolFailed)
        try rewriteSidecarOutcome { $0["reason"] = laterReason }

        let loaded = try ClassificationResult.load(from: folder)

        XCTAssertEqual(loaded.profileOutcome.state, .degraded)
        XCTAssertEqual(loaded.profileOutcome.reason?.rawValue, laterReason)
        XCTAssertEqual(loaded.profileOutcome.message, message)
        XCTAssertEqual(loaded.profileOutcome.resolution, resolution)
        XCTAssertEqual(loaded.tree.totalReads, saved.tree.totalReads)
        XCTAssertEqual(loaded.toolVersion, "2.1.3")
        XCTAssertEqual(loaded.runtime, 42.5)
    }

    /// `build-db` loads a result and saves it again, so the later release's token must survive the
    /// save and not turn into a known reason or vanish.
    func testASidecarSavedAgainKeepsTheUnknownReason() throws {
        try saveResult(reason: .toolFailed)
        try rewriteSidecarOutcome { $0["reason"] = futureReason }

        let loaded = try ClassificationResult.load(from: folder)
        XCTAssertEqual(loaded.profileOutcome.reason, .unknown(futureReason))
        try loaded.save(to: folder)

        XCTAssertEqual(try sidecarOutcome()["reason"] as? String, futureReason)
        XCTAssertEqual(try ClassificationResult.load(from: folder).profileOutcome, loaded.profileOutcome)
    }

    // MARK: - Every display

    /// The reason is shown only when Bracken left no message of its own, by the result summary, the
    /// batch row, the Operations detail and the CLI warning. Each shows the token as plain text, and
    /// the provenance parameter holds the token exactly.
    func testEveryDisplayOfTheReasonShowsAnUnknownOneAsItsToken() throws {
        try saveResult(reason: .toolFailed)
        try rewriteSidecarOutcome {
            $0["reason"] = laterReason
            $0.removeValue(forKey: "message")
        }

        let result = try ClassificationResult.load(from: folder)

        XCTAssertNil(result.profileOutcome.message)
        XCTAssertTrue(result.summary.contains("Profiling detail: \(laterReason)"), result.summary)
        XCTAssertEqual(ClassificationBatchOutcomePolicy.row(sampleId: "S1", result: result).message, laterReason)
        let metadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: result)
        XCTAssertTrue(metadata.completionDetail.hasSuffix(": \(laterReason)"), metadata.completionDetail)
        XCTAssertEqual(metadata.analysisParameters["brackenDegradationReason"]?.stringValue, laterReason)
        XCTAssertEqual(
            Kraken2AnalysisRunTool.warning(for: result),
            "Kraken classification completed, but Bracken profiling did not complete: \(laterReason)"
        )
    }

    // MARK: - Fixtures

    /// The JSON of a degraded outcome whose reason is `raw`. It starts from an outcome the encoder
    /// wrote, so every other key is spelled as the encoder spells it.
    private func degradedOutcomeJSON(reason raw: String) throws -> Data {
        let known = BrackenProfileOutcome.degraded(
            resolution: resolution,
            reason: .toolFailed,
            message: message,
            toolVersion: "3.0.1"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any]
        )
        object["reason"] = raw
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Writes a result folder with a kreport, a Kraken output and a degraded profile outcome.
    @discardableResult
    private func saveResult(reason: BrackenProfileDegradationReason) throws -> ClassificationResult {
        let kreportURL = folder.appendingPathComponent("classification.kreport")
        try """
        100.00\t1000\t0\tR\t1\troot
         80.00\t800\t0\tD\t2\t  Bacteria
         50.00\t500\t200\tG\t561\t    Escherichia
         20.00\t200\t200\tS\t562\t      Escherichia coli
         20.00\t200\t200\tD\t2157\t  Archaea
        """.write(to: kreportURL, atomically: true, encoding: .utf8)
        let krakenURL = folder.appendingPathComponent("classification.kraken")
        try "C\tread1\t562\t150\t0:150\n".write(to: krakenURL, atomically: true, encoding: .utf8)

        let config = ClassificationConfig(
            inputFiles: [folder.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "SILVA",
            databasePath: folder,
            databaseCatalogID: "kraken2-special-silva",
            databaseInstallationRecipe: .kraken2Special(type: .silva),
            brackenProfileRequest: .automaticDefault,
            outputDirectory: folder
        )
        let result = ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: kreportURL),
            reportURL: kreportURL,
            outputURL: krakenURL,
            brackenURL: nil,
            profileOutcome: .degraded(
                resolution: resolution,
                reason: reason,
                message: message,
                toolVersion: "3.0.1"
            ),
            runtime: 42.5,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
        try result.save(to: folder)
        return result
    }

    private var sidecarURL: URL {
        folder.appendingPathComponent(ClassificationResult.sidecarFilename)
    }

    private func sidecarOutcome() throws -> [String: Any] {
        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        )
        return try XCTUnwrap(sidecar["profileOutcome"] as? [String: Any])
    }

    /// Edits the `profileOutcome` object of the saved sidecar, as a later release's writer would
    /// have written it.
    private func rewriteSidecarOutcome(_ edit: (inout [String: Any]) -> Void) throws {
        var sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        )
        var outcome = try XCTUnwrap(sidecar["profileOutcome"] as? [String: Any])
        edit(&outcome)
        sidecar["profileOutcome"] = outcome
        try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys]).write(to: sidecarURL)
    }
}

// MetagenomicsDialogBundleSamplesTests.swift - The Classification and EsViritu dialogs make one sample per FASTQ bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishWorkflow

/// BIO ruling BIO-TT-PAIR, question 3. The Classification (Kraken2) and EsViritu dialogs group the
/// sidebar bundles through `MetagenomicsSampleGrouper`, which made one paired sample `S` of the
/// bundles `S_1` and `S_2`. Each bundle is one sample now, so two bundles are a batch and the route
/// runs `kraken2 classify --batch`, never the one-sample path that keeps two inputs as a pair.
@MainActor
final class MetagenomicsDialogBundleSamplesTests: XCTestCase {
    private let bundles = ["S_1", "S_2"].map {
        URL(fileURLWithPath: "/data/run/\($0).lungfishfastq", isDirectory: true)
    }

    func testTheClassificationDialogBuildsTwoSamplesFromBundlesNamedLikeMates() throws {
        let samples = ClassificationWizardSheet(inputFiles: bundles).groupedSamples

        XCTAssertEqual(samples.map(\.sampleId), ["S_1", "S_2"])
        XCTAssertEqual(samples.map(\.inputFiles), [[bundles[0]], [bundles[1]]])

        let database = MetagenomicsDatabaseInfo(
            name: "Viral", tool: "kraken2", version: "2026.1", sizeBytes: 1, catalogID: "kraken2-viral",
            installationRecipe: nil, payloadDigest: "sha256:viral-fixture", description: "Viral fixture",
            path: URL(fileURLWithPath: "/data/db/viral", isDirectory: true), status: .ready, recommendedRAM: 1
        )
        let batchRoot = URL(fileURLWithPath: "/data/run/classification-batch-0000TEST", isDirectory: true)
        let configs = samples.map { sample in
            ClassificationWizardSheet.makeProfileConfig(
                sample: sample,
                readPlan: ClassificationSampleReadPlan(format: .unpaired, layout: nil),
                database: database,
                databasePath: URL(fileURLWithPath: "/data/db/viral", isDirectory: true),
                outputDirectory: batchRoot.appendingPathComponent(sample.sampleId, isDirectory: true),
                confidence: 0.2,
                minimumHitGroups: 2,
                threads: 1,
                memoryMapping: false,
                extraArguments: []
            )
        }
        let launch = try XCTUnwrap(
            ClassifierCLIRouteLaunch.kraken2(configs: configs, projectURL: URL(fileURLWithPath: "/data/Project.lungfish"))
        )

        XCTAssertEqual(launch.arguments.filter { $0 == "--batch" }.count, 1)
        XCTAssertEqual(launch.arguments.filter { $0 == "--paired" }.count, 0)
        XCTAssertEqual(Array(launch.arguments.suffix(2)), bundles.map(\.path))
        XCTAssertEqual(launch.sampleIDs, ["S_1", "S_2"])
    }

    func testTheEsVirituDialogBuildsTwoSamplesFromBundlesNamedLikeMates() {
        let samples = EsVirituWizardSheet(inputFiles: bundles).groupedSamples

        XCTAssertEqual(samples.map(\.sampleId), ["S_1", "S_2"])
        XCTAssertEqual(samples.map(\.inputFiles), [[bundles[0]], [bundles[1]]])
        XCTAssertEqual(samples.map(\.isPairedEnd), [false, false])
    }
}

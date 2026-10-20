// EsVirituPipelineRunFactsTests.swift - Where EsViritu's pipeline record files the facts of a run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.15, SW26 note 1 (BIO-13.15-SW26 items 1 and 5). The paired-end flag, the build's EsViritu
/// release, a changed read format and the layout scan are facts of the run, not options the user chose. The pipeline
/// record files each among its resolved defaults with the value the base filed among the explicit options. It sits
/// beside `EsVirituPipelineTests.swift`, whose classes test the configuration and hold no pipeline record.
final class EsVirituPipelineRunFactsTests: XCTestCase {
    /// The options of the record `EsVirituPipeline.detect` saves for `config`, run on the stand-in tool of `run`.
    private func recordedOptions(of config: EsVirituConfig, in run: StandInEsVirituRun) async throws -> ProvenanceOptions {
        _ = try await EsVirituPipeline(condaManager: run.condaManager).detect(config: config)
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory)).options
    }

    /// A single-end FASTQ classified as `auto` classifies it. Each of the seven run facts is a resolved default with the
    /// value the base filed as explicit, and `pairedEnd` follows the resolved read format.
    func testTheEsVirituRunFactsAreResolvedDefaultsNotExplicitOptions() async throws {
        let run = try StandInEsVirituRun()
        defer { run.remove() }
        var config = run.config
        let layout = FASTQReadLayoutClassifier.classify(inputURL: config.inputFiles[0])
        config.inputLayout = layout

        let options = try await recordedOptions(of: config, in: run)

        let facts: [String: ParameterValue] = [
            "github_release_version": .string(EsVirituPipeline.esVirituGithubReleaseVersion),
            "inputReadLayout": .string(layout.layout.rawValue),
            "inputReadLayoutMatePairs": .integer(layout.matePairs),
            "inputReadLayoutReason": .string(layout.reason),
            "inputReadLayoutScannedRecords": .integer(layout.scannedRecords),
            "inputReadLayoutUnpairedRecords": .integer(layout.unpairedRecords),
            "pairedEnd": .boolean(false),
        ]
        for (key, value) in facts {
            XCTAssertNil(options.explicit[key], "\(key) is a fact of the run, not an option the user chose")
            XCTAssertEqual(options.resolvedDefaults[key], value, key)
        }
        XCTAssertEqual(options.resolvedDefaults["readFormat"], .string("unpaired"))
    }

    /// A paired run resolves `pairedEnd` true beside the read format `paired`, and names neither as chosen.
    func testAPairedEsVirituRunResolvesPairedEndFromItsReadFormat() async throws {
        let run = try StandInEsVirituRun()
        defer { run.remove() }
        let mate = run.config.inputFiles[0].deletingLastPathComponent().appendingPathComponent("sample_R2.fastq")
        try FileManager.default.copyItem(at: run.config.inputFiles[0], to: mate)
        let config = EsVirituConfig(
            inputFiles: [run.config.inputFiles[0], mate],
            isPairedEnd: true,
            sampleName: "sample",
            outputDirectory: run.config.outputDirectory,
            databasePath: run.config.databasePath,
            threads: 4,
            readFormat: .paired
        )

        let options = try await recordedOptions(of: config, in: run)

        XCTAssertNil(options.explicit["pairedEnd"])
        XCTAssertEqual(options.resolvedDefaults["pairedEnd"], .boolean(true))
        XCTAssertEqual(options.resolvedDefaults["readFormat"], .string("paired"))
    }

    /// An interleaved request over a file that is not strictly interleaved runs unpaired. The format asked for is the
    /// resolved default `requestedReadFormat`, never an explicit option.
    func testAChangedEsVirituRequestIsTheRequestedReadFormatResolvedDefault() async throws {
        let run = try StandInEsVirituRun()
        defer { run.remove() }
        let config = EsVirituConfig(
            inputFiles: run.config.inputFiles,
            isPairedEnd: false,
            sampleName: "sample",
            outputDirectory: run.config.outputDirectory,
            databasePath: run.config.databasePath,
            threads: 4,
            readFormat: .interleaved
        )

        let options = try await recordedOptions(of: config, in: run)

        XCTAssertNil(options.explicit["requestedReadFormat"])
        XCTAssertEqual(options.resolvedDefaults["requestedReadFormat"], .string("interleaved"))
        XCTAssertEqual(options.resolvedDefaults["readFormat"], .string("unpaired"))
    }
}

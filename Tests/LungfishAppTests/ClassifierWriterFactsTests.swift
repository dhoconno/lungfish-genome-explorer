// ClassifierWriterFactsTests.swift - The facts of today's five classifier records, captured once on the base of Phase 2.7
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, "Freeze, then change" of
// docs/contracts/RECORDING-PROVENANCE.md. Each test runs one classifier writer
// the way today's GUI or CLI runs it, with fake tools (`ClassifierLegacyRuns`),
// projects its record with `ProvenanceCompatFacts` and compares the facts with
// the file captured on the base in
// Tests/Fixtures/provenance-writer-parity/classifiers. The README there says
// how each file was made and which lane may move which fact. A lane that
// changes one of these writers moves the facts it declares in a reviewed
// commit of its own.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class ClassifierWriterFactsTests: XCTestCase {

    // MARK: - The five records

    /// `ClassificationPipeline.profile`, the run the Kraken2 wizard always asks for.
    func testKraken2PipelineRecord() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)
        try assertFacts(.kraken2Pipeline, of: config.outputDirectory, projectRoot: fixture.root)
    }

    /// `lungfish-cli conda classify` run with the command the Operations panel
    /// records for the same wizard config, so the wrapper record replaces the
    /// pipeline record in the output folder.
    func testCondaClassifyWrapperRecord() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let run = try await ClassifierLegacyRuns.condaClassify(
            arguments: try ClassifierLegacyRuns.recordedClassifyArguments(for: config),
            databasePath: config.databasePath,
            condaManager: fixture.condaManager
        )
        XCTAssertEqual(run.wrapperEnvelope.workflowName, "lungfish.classify")
        try assertFacts(.condaClassifyWrapper, of: run.outputDirectory, projectRoot: fixture.root)
    }

    /// The batch record `runClassificationBatch` writes over two completed samples.
    func testKraken2BatchRecord() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let batch = try await ClassifierLegacyRuns.kraken2Batch(fixture: fixture)
        try assertFacts(.kraken2Batch, of: batch.batchRoot, projectRoot: fixture.root)
    }

    /// `EsVirituPipeline.detect` on one sample file, the record both routes write.
    func testEsVirituPipelineRecord() async throws {
        let root = try TestTempDirectory.make(prefix: "esviritu-pipeline-facts")
        defer { TestTempDirectory.cleanup(root) }
        let esviritu = try ClassifierLegacyRuns.StandInEsVirituConda(root: root)
        let input = root.appendingPathComponent("inputs/sample.fastq")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@sample-1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        let config = ClassifierLegacyRuns.esVirituConfig(
            input: input,
            sampleName: "sample",
            outputDirectory: root.appendingPathComponent("Analyses/esviritu-batch/sample", isDirectory: true),
            databasePath: esviritu.databaseURL
        )
        _ = try await EsVirituPipeline(condaManager: esviritu.condaManager).detect(config: config)
        try assertFacts(.esVirituPipeline, of: config.outputDirectory, projectRoot: root)
    }

    /// The batch record `runEsVirituBatch` writes over two completed samples.
    func testEsVirituBatchRecord() async throws {
        let root = try TestTempDirectory.make(prefix: "esviritu-batch-facts")
        defer { TestTempDirectory.cleanup(root) }
        let esviritu = try ClassifierLegacyRuns.StandInEsVirituConda(root: root)
        let batch = try await ClassifierLegacyRuns.esVirituBatch(root: root, esviritu: esviritu)
        try assertFacts(.esVirituBatch, of: batch.batchRoot, projectRoot: root)
    }

    // MARK: - The folder

    /// One canonical facts file per scenario, each named in the README, none
    /// holding a machine path, a host value or the recorded host keys.
    func testTheFolderHoldsOneCanonicalFilePerScenario() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(Self.suffix) }
        XCTAssertEqual(
            Set(files.map { String($0.lastPathComponent.dropLast(Self.suffix.count)) }),
            Set(BareRunWriterParity.Scenario.classifierScenarios.map(\.id))
        )
        let readme = try String(contentsOf: Self.folder.appendingPathComponent("README.md"), encoding: .utf8)
        let hostValues = (BareRunWriterParity.hostReplacements() + Self.cliVersionReplacement)
            .map(\.pattern).filter { !$0.isEmpty }
        for file in files {
            let name = file.lastPathComponent
            let bytes = try Data(contentsOf: file)
            let facts = try ProvenanceCompatFacts.decode(bytes)
            XCTAssertEqual(try facts.canonicalJSON(), bytes, "\(name) is the canonical encoding of its facts")
            XCTAssertTrue(ProvenanceCompatCorpus.machinePathMarkers(in: bytes).isEmpty, "\(name) holds a machine path")
            XCTAssertTrue(facts.recorded.isEmpty, "\(name) holds the host values of the run that captured it")
            XCTAssertTrue(readme.contains(name), "the README names \(name)")
            let text = String(decoding: bytes, as: UTF8.self)
            for value in hostValues {
                XCTAssertFalse(text.contains(value), "\(name) holds the host value \(value)")
            }
        }
    }

    // MARK: - Capture and compare

    private static let suffix = ".facts.json"

    /// Tests/Fixtures/provenance-writer-parity/classifiers. The bare-run
    /// parity suites list only the parent folder's own files.
    static var folder: URL {
        BareRunWriterParity.fixtureRoot.appendingPathComponent("classifiers", isDirectory: true)
    }

    /// The CLI version a wrapper record holds, as a token. Left out when it is
    /// the app version, which the host replacements already turn into a token.
    private static var cliVersionReplacement: [BareRunWriterParity.Replacement] {
        let version = LungfishCLI.configuration.version
        guard !version.isEmpty, version != WorkflowRun.currentAppVersion else { return [] }
        return [.literal(version, as: "<cli-version>")]
    }

    /// Projects the record in `directory`, normalizes it for `scenario` and
    /// compares it with the captured file. With no file, it writes one when
    /// `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1` and fails otherwise. It never
    /// replaces a file.
    private func assertFacts(
        _ scenario: BareRunWriterParity.Scenario,
        of directory: URL,
        projectRoot: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sidecar = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let facts = try Self.withoutPeakMemory(BareRunWriterParity.normalized(
            try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: projectRoot),
            scenario: scenario,
            replacing: Self.cliVersionReplacement
        ))
        let url = Self.folder.appendingPathComponent(scenario.id + Self.suffix)
        guard let data = try? Data(contentsOf: url) else {
            guard ProvenanceCompatCorpus.captureFactsRequested else {
                return XCTFail(
                    "\(url.lastPathComponent) is missing. Run this test once on unchanged code with "
                        + "\(ProvenanceCompatCorpus.captureFactsVariable)=1 to capture it.",
                    file: file,
                    line: line
                )
            }
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try facts.canonicalJSON().write(to: url, options: .withoutOverwriting)
            return
        }
        let problems = facts.differences(
            from: try ProvenanceCompatFacts.decode(data),
            ignoring: BareRunWriterParity.runSpecificFields(of: scenario)
        )
        XCTAssertEqual(problems, [], "\(scenario.id) differs from the facts captured on the base", file: file, line: line)
    }

    /// The facts without any `peakMemoryBytes`, which a fake tool's process
    /// reports differently on every run.
    private static func withoutPeakMemory(_ facts: ProvenanceCompatFacts) throws -> ProvenanceCompatFacts {
        func strip(_ value: ProvenanceCompatFacts.Value) -> ProvenanceCompatFacts.Value {
            switch value {
            case .object(let members):
                return .object(members.filter { $0.key != "peakMemoryBytes" }.mapValues(strip))
            case .array(let items):
                return .array(items.map(strip))
            default:
                return value
            }
        }
        let tree = try JSONDecoder().decode(ProvenanceCompatFacts.Value.self, from: JSONEncoder().encode(facts))
        return try JSONDecoder().decode(ProvenanceCompatFacts.self, from: JSONEncoder().encode(strip(tree)))
    }
}

extension BareRunWriterParity.Scenario {
    /// Any UUID, such as the one in a Bracken scratch folder's name, becomes a token.
    private static let uuidToken = BareRunWriterParity.Replacement.regularExpression(
        "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        as: "<uuid>"
    )

    /// The files of a Kraken2 run whose bytes differ on every run. The result
    /// sidecar holds the run's dates and runtime, gzip stores the time it read
    /// `classification.kraken`, and SQLite pages differ from run to run.
    private static let kraken2RunFiles = ["classification-result.json", "classification.kraken.gz", ".kraken.gz.idx.sqlite"]

    static let kraken2Pipeline = Self(
        id: "kraken2-pipeline-profile",
        timing: .clockedRunAndSteps,
        volatileFileSuffixes: kraken2RunFiles,
        replacements: [uuidToken]
    )
    static let condaClassifyWrapper = Self(
        id: "conda-classify-wrapper",
        timing: .clockedRunAndSteps,
        volatileFileSuffixes: kraken2RunFiles,
        replacements: [uuidToken]
    )
    static let kraken2Batch = Self(
        id: "kraken2-batch",
        timing: .clockedRunAndSteps,
        volatileFileSuffixes: kraken2RunFiles + ["classification-batch-result.json"],
        replacements: [uuidToken]
    )
    static let esVirituPipeline = Self(
        id: "esviritu-pipeline",
        timing: .clockedRunAndSteps,
        volatileFileSuffixes: ["esviritu-result.json"],
        replacements: [uuidToken]
    )
    static let esVirituBatch = Self(
        id: "esviritu-batch",
        timing: .clockedRunAndSteps,
        volatileFileSuffixes: ["esviritu-result.json"],
        replacements: [uuidToken]
    )

    /// Every scenario of Tests/Fixtures/provenance-writer-parity/classifiers.
    static let classifierScenarios = [kraken2Pipeline, condaClassifyWrapper, kraken2Batch, esVirituPipeline, esVirituBatch]
}

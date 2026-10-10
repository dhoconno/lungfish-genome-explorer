import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishWorkflow

/// Guards the expected facts of the bare-run writer parity suites (Phase 2.4, finding R8, lane W2B)
/// and pins what the helper does to facts before they are captured or compared.
@Suite("Bare-run writer parity fixtures")
struct BareRunWriterParityFixtureTests {
    typealias Parity = BareRunWriterParity

    private static let factsSuffix = ".facts.json"

    // MARK: The folder

    @Test("every scenario has a name of its own and a source, and every expected facts file has a scenario")
    func registryMatchesTheFixtureFolder() throws {
        let ids = Parity.Scenarios.all.map(\.id)
        #expect(Set(ids).count == ids.count, "a scenario id is used twice")

        let ownIDs = Parity.Scenarios.all.filter { $0.source == .parityFixture }.map(\.id)
        let fileIDs = try Self.factsFiles().map { String($0.lastPathComponent.dropLast(Self.factsSuffix.count)) }
        #expect(Set(fileIDs) == Set(ownIDs), "scenarios without a file: \(Set(ownIDs).subtracting(fileIDs).sorted()), files without a scenario: \(Set(fileIDs).subtracting(ownIDs).sorted())")

        let corpusIDs = Set(ProvenanceCompatCorpus.caseIDs())
        for scenario in Parity.Scenarios.all where scenario.source == .corpusCase {
            #expect(corpusIDs.contains(scenario.id), "scenario \(scenario.id) names no corpus case")
        }
    }

    @Test("an expected facts file is canonical, current, free of machine values and holds no host values")
    func expectedFactsAreCanonicalAndFreeOfMachineValues() throws {
        let hostValues = Parity.hostReplacements().map(\.pattern).filter { !$0.isEmpty }
        for file in try Self.factsFiles() {
            let bytes = try Data(contentsOf: file)
            let name = file.lastPathComponent
            let facts = try ProvenanceCompatFacts.decode(bytes)

            #expect(facts.factsVersion == ProvenanceCompatFacts.currentFactsVersion, "\(name) has an old facts version")
            #expect(try facts.canonicalJSON() == bytes, "\(name) is not the canonical encoding of its facts")
            #expect(ProvenanceCompatCorpus.machinePathMarkers(in: bytes).isEmpty, "\(name) holds a machine path")
            #expect(facts.recorded.isEmpty, "\(name) holds the host values of the run that captured it")
            let text = String(decoding: bytes, as: UTF8.self)
            for value in hostValues {
                #expect(!text.contains(value), "\(name) holds the host value \(value)")
            }
        }
    }

    // MARK: Normalization

    @Test("normalizing replaces host values, clears the checksums of volatile files and the times a clock decides")
    func normalizationReplacesAndClears() throws {
        let frozen = try Self.corpusFacts("s3-write-sidecar-bare-run")
        #expect(frozen.wallTimeSeconds == 41)
        #expect(!frozen.recorded.isEmpty)
        #expect(frozen.files.contains { $0.path.hasSuffix(".vcf") && $0.sha256 != nil })

        // A fixed clock keeps every time, and a volatile suffix clears the checksum and size of that file only.
        let injected = Parity.Scenario(id: "demo", timing: .injected, volatileFileSuffixes: [".vcf"])
        let kept = try Parity.normalized(frozen, scenario: injected)
        #expect(kept.wallTimeSeconds == 41)
        #expect(kept.steps.map(\.wallTimeSeconds) == frozen.steps.map(\.wallTimeSeconds))
        #expect(kept.recorded.isEmpty)
        #expect(kept.files.filter { $0.path.hasSuffix(".vcf") }.allSatisfy { $0.sha256 == nil && $0.size == nil })
        #expect(kept.files.filter { !$0.path.hasSuffix(".vcf") }.allSatisfy { $0.sha256 != nil })
        #expect(kept.steps[0].outputs.allSatisfy { $0.sha256 == nil }, "the clearing reaches the files inside steps")

        // A clocked run drops the run's times and the ops-stats total, and keeps the steps' times.
        let clockedRun = try Parity.normalized(frozen, scenario: Parity.Scenario(id: "demo", timing: .clockedRun))
        #expect(clockedRun.wallTimeSeconds == nil)
        #expect(clockedRun.opsStats.totalWallTimeSeconds == 0)
        #expect(clockedRun.steps.map(\.wallTimeSeconds) == frozen.steps.map(\.wallTimeSeconds))

        // A clocked run and its steps drop every time, in all three step views.
        let clockedAll = try Parity.normalized(frozen, scenario: Parity.Scenario(id: "demo", timing: .clockedRunAndSteps))
        #expect(clockedAll.steps.allSatisfy { $0.wallTimeSeconds == nil })
        #expect(clockedAll.legacyRunSteps.allSatisfy { $0.wallTime == nil })
        #expect(clockedAll.canonicalRunSteps.allSatisfy { $0.wallTime == nil })
        // Nothing else moves.
        #expect(clockedAll.argv == frozen.argv)
        #expect(clockedAll.steps.map(\.argv) == frozen.steps.map(\.argv))
        #expect(clockedAll.files == frozen.files)
    }

    @Test("a literal replacement is longest first, a version replacement needs a boundary, and a pattern is a regular expression")
    func replacementsApplyInOrder() throws {
        var facts = try Self.corpusFacts("s3-write-sidecar-bare-run")
        facts.toolVersion = "release 2.3 of Lungfish 1999.1.1 (test), build 12.34"
        let scenario = Parity.Scenario(id: "demo", timing: .injected)

        let result = try Parity.normalized(
            facts,
            scenario: scenario,
            replacing: [
                .literal("Lungfish 1999.1.1 (test)", as: "<app>"),
                .literal("Lungfish", as: "<name>"),
                .version("2.3", as: "<two-three>"),
                .regularExpression(#"build \d+\.\d+"#, as: "<build>"),
            ]
        )

        #expect(result.toolVersion == "release <two-three> of <app>, <build>")
    }

    @Test("a replacement that is not a regular expression is refused")
    func invalidReplacementIsRefused() throws {
        let facts = try Self.corpusFacts("s3-write-sidecar-bare-run")
        #expect(throws: Parity.ParityError.invalidReplacement("(")) {
            _ = try Parity.normalized(
                facts,
                scenario: Parity.Scenario(id: "demo", timing: .injected),
                replacing: [.regularExpression("(", as: "x")]
            )
        }
    }

    // MARK: Capture

    @Test("an unregistered scenario is refused, and the message for missing facts names the capture command")
    func unregisteredScenarioIsRefused() throws {
        let facts = try Self.corpusFacts("s3-write-sidecar-bare-run")
        let unregistered = Parity.Scenario(id: "not-in-the-registry", timing: .injected)
        #expect(throws: Parity.ParityError.unregisteredScenario("not-in-the-registry")) {
            _ = try Parity.problemsBeforeConversion(facts, scenario: unregistered)
        }
        #expect(throws: (any Error).self) {
            try Parity.capture(facts, as: unregistered)
        }
        let message = Parity.ParityError.noExpectedFacts(id: "demo").errorDescription ?? ""
        #expect(message.contains(ProvenanceCompatCorpus.captureFactsVariable))
    }

    // MARK: Helpers

    private static func factsFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: Parity.fixtureRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(factsSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func corpusFacts(_ id: String) throws -> ProvenanceCompatFacts {
        try ProvenanceCompatFacts.decode(
            try #require(ProvenanceCompatCorpus.expectedFactsData(for: id), "case \(id) has no expected facts")
        )
    }
}

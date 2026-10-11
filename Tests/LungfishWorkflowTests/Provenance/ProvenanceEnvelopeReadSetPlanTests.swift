import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishWorkflow

/// The one reader of a record's read set plan (E13). Each record below is built in the test, in the
/// shape a released build wrote it, or is a frozen record of the compatibility corpus, which the test
/// reads from a temporary copy and never changes.
@Suite("Provenance envelope read set plan")
struct ProvenanceEnvelopeReadSetPlanTests {
    // MARK: Plans

    private static func plan(_ marker: String) -> ParameterValue {
        .dictionary([
            "capability": .string("pairsOrSinglesPerRun"),
            "sourceLayout": .string("pairsAndSingles"),
            "pairedFragments": .integer(1),
            "mergedReads": .null,
            "orphanReads": .integer(1),
            "singleEndReads": .null,
            "mergedOrOrphanReads": .null,
            "runs": .integer(2),
            "singleReadReason": .string(marker),
        ])
    }

    private static func fields(_ marker: String) -> [String: ParameterValue] {
        plan(marker).dictionaryValue ?? [:]
    }

    // MARK: Records

    private static func envelope(
        explicit: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:],
        steps: [ProvenanceStep] = [],
        nestedRunParameters: [String: ParameterValue]? = nil
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            workflowName: "fixture",
            toolName: "fixture-tool",
            toolVersion: "1.0.0",
            options: ProvenanceOptions(explicit: explicit, resolvedDefaults: resolvedDefaults),
            steps: steps,
            legacyWorkflowRun: nestedRunParameters.map {
                WorkflowRun(name: "fixture", status: .completed, parameters: $0)
            }
        )
    }

    private static func step(_ resolvedOptions: [String: ParameterValue]) -> ProvenanceStep {
        ProvenanceStep(toolName: "fixture-tool", toolVersion: "1.0.0", resolvedOptions: resolvedOptions)
    }

    // MARK: Each place

    @Test("the one home is options.resolvedDefaults")
    func theHomeIsResolvedDefaults() {
        let record = Self.envelope(resolvedDefaults: ["readSetPlan": Self.plan("home")])
        #expect(record.readSetPlan == RecordedReadSetPlan(fields: Self.fields("home"), place: .resolvedDefaults))
    }

    @Test("a plan in options.explicit is read, the way the recorder merges the Kraken2 run parameters")
    func explicitOptionsAreRead() {
        let record = Self.envelope(explicit: ["goal": .string("classify"), "readSetPlan": Self.plan("explicit")])
        #expect(record.readSetPlan == RecordedReadSetPlan(fields: Self.fields("explicit"), place: .explicitOptions))
    }

    @Test("a plan in the resolved options of a step is read, the way map records it")
    func stepResolvedOptionsAreRead() {
        let first = Self.step([:])
        let second = Self.step(["readSetPlan": Self.plan("step")])
        let record = Self.envelope(steps: [first, second])
        #expect(record.readSetPlan == RecordedReadSetPlan(
            fields: Self.fields("step"),
            place: .stepResolvedOptions(stepID: second.id)
        ))
    }

    @Test("a plan in the parameters of a nested legacy run is read")
    func nestedRunParametersAreRead() {
        let record = Self.envelope(nestedRunParameters: ["readSetPlan": Self.plan("nested")])
        #expect(record.readSetPlan == RecordedReadSetPlan(fields: Self.fields("nested"), place: .nestedRunParameters))
    }

    // MARK: Order

    @Test("the home wins over every released place, and each place wins over the ones after it")
    func theFirstPlaceInOrderWins() {
        let early = Self.step(["readSetPlan": Self.plan("first step")])
        let late = Self.step(["readSetPlan": Self.plan("second step")])
        let everywhere = Self.envelope(
            explicit: ["readSetPlan": Self.plan("explicit")],
            resolvedDefaults: ["readSetPlan": Self.plan("home")],
            steps: [early, late],
            nestedRunParameters: ["readSetPlan": Self.plan("nested")]
        )
        #expect(everywhere.readSetPlan?.place == .resolvedDefaults)
        #expect(everywhere.readSetPlan?.fields == Self.fields("home"))

        let withoutHome = Self.envelope(
            explicit: ["readSetPlan": Self.plan("explicit")],
            steps: [early, late],
            nestedRunParameters: ["readSetPlan": Self.plan("nested")]
        )
        #expect(withoutHome.readSetPlan?.place == .explicitOptions)

        let withoutExplicit = Self.envelope(steps: [early, late], nestedRunParameters: ["readSetPlan": Self.plan("nested")])
        #expect(withoutExplicit.readSetPlan?.place == .stepResolvedOptions(stepID: early.id))
        #expect(withoutExplicit.readSetPlan?.fields == Self.fields("first step"))

        let nestedOnly = Self.envelope(nestedRunParameters: ["readSetPlan": Self.plan("nested")])
        #expect(nestedOnly.readSetPlan?.place == .nestedRunParameters)
    }

    @Test("a copy of the plan in two places reads the same from either")
    func aCopyInTwoPlacesReadsTheSame() {
        // `assemble` records the plan in both the explicit options and the resolved defaults.
        let both = Self.envelope(
            explicit: ["readSetPlan": Self.plan("same")],
            resolvedDefaults: ["readSetPlan": Self.plan("same")]
        )
        let explicitOnly = Self.envelope(explicit: ["readSetPlan": Self.plan("same")])
        #expect(both.readSetPlan?.fields == explicitOnly.readSetPlan?.fields)
    }

    // MARK: Absence and look-alikes

    @Test("a record without a plan reads nil, whatever else it holds")
    func aRecordWithoutAPlanReadsNil() {
        #expect(Self.envelope().readSetPlan == nil)
        #expect(Self.envelope(
            explicit: ["threads": .integer(4)],
            resolvedDefaults: ["confidence": .number(0.2)],
            steps: [Self.step(["preset": .string("sr")])],
            nestedRunParameters: ["goal": .string("classify")]
        ).readSetPlan == nil)
    }

    @Test("a value that is not an object is no plan, and the reader goes on to the next place")
    func aValueThatIsNotAnObjectIsNoPlan() {
        let notObjects: [ParameterValue] = [.string("pairs"), .null, .integer(2), .array([Self.plan("inside an array")])]
        for value in notObjects {
            let alone = Self.envelope(resolvedDefaults: ["readSetPlan": value])
            #expect(alone.readSetPlan == nil, "\(value)")
            let withNext = Self.envelope(
                explicit: ["readSetPlan": Self.plan("explicit")],
                resolvedDefaults: ["readSetPlan": value]
            )
            #expect(withNext.readSetPlan?.place == .explicitOptions, "\(value)")
        }
    }

    @Test("the plural keys of TaxTriage and 12S matching and a plan nested in another value are no plan")
    func otherKeysAndNestedValuesAreNoPlan() {
        // TaxTriage records one plan per sample and 12S matching records `readSetPlans`. Viral Recon
        // records the key inside each read pairing decision, with another meaning.
        let record = Self.envelope(
            explicit: [
                "read_set_plans": .array([Self.plan("per sample")]),
                "readSetPlans": .array([Self.plan("per sample")]),
                "readPairing": .array([.dictionary(["readSetPlan": Self.plan("bundle staging")])]),
            ],
            steps: [Self.step(["inner": .dictionary(["readSetPlan": Self.plan("deeper")])])]
        )
        #expect(record.readSetPlan == nil)
    }

    // MARK: Written and read back

    @Test("a plan in each place the encoder writes survives the file")
    func aPlanSurvivesTheFile() throws {
        let home = Self.envelope(resolvedDefaults: ["readSetPlan": Self.plan("home")])
        let explicit = Self.envelope(explicit: ["readSetPlan": Self.plan("explicit")])
        let step = Self.step(["readSetPlan": Self.plan("step")])
        let onStep = Self.envelope(steps: [step])
        for (record, place) in [
            (home, RecordedReadSetPlan.Place.resolvedDefaults),
            (explicit, .explicitOptions),
            (onStep, .stepResolvedOptions(stepID: step.id)),
        ] {
            let bytes = try ProvenanceJSON.encoder.encode(record)
            let decoded = try ProvenanceEnvelopeReader.decode(bytes)
            #expect(decoded.readSetPlan?.place == place)
            #expect(decoded.readSetPlan?.fields == record.readSetPlan?.fields)
        }
    }

    // MARK: The frozen corpus

    @Test("over the frozen corpus only the Kraken2 recorder case holds a plan, in its nested run")
    func onlyOneFrozenCaseHoldsAPlan() throws {
        var found: [String: RecordedReadSetPlan.Place] = [:]
        for id in ProvenanceCompatCorpus.caseIDs() {
            let materialized = try ProvenanceCompatCorpus.materialize(id)
            defer { materialized.cleanup() }
            let record = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar), "case \(id)")
            if let plan = record.readSetPlan {
                found[id] = plan.place
            }
        }
        #expect(found == ["s1-recorder-readsetplan": .nestedRunParameters])
    }

    @Test("the frozen Kraken2 recorder record gives the plan its run recorded")
    func theFrozenKraken2PlanIsRead() throws {
        let materialized = try ProvenanceCompatCorpus.materialize("s1-recorder-readsetplan")
        defer { materialized.cleanup() }
        let record = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        #expect(record.options.explicit["readSetPlan"] == nil, "the frozen bytes never named the plan in the options")
        let plan = try #require(record.readSetPlan)
        #expect(plan.place == .nestedRunParameters)
        #expect(plan.fields["capability"] == .string("pairsOrSinglesPerRun"))
        #expect(plan.fields["sourceLayout"] == .string("pairsAndSingles"))
        #expect(plan.fields["pairedFragments"] == .integer(1))
        #expect(plan.fields["orphanReads"] == .integer(1))
        #expect(plan.fields["runs"] == .integer(2))
        #expect(plan.fields["singleReadReason"] == .string("orphan reads run as single reads"))
    }

    @Test("a record the recorder writes today reads the same plan as the frozen record")
    func theRecorderRecordReadsTheSamePlan() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sidecar = try await ProvenanceCompatScenarios.recorderRunWithReadSetPlan(in: project)
        let today = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))

        let materialized = try ProvenanceCompatCorpus.materialize("s1-recorder-readsetplan")
        defer { materialized.cleanup() }
        let frozen = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))

        #expect(today.readSetPlan != nil)
        #expect(today.readSetPlan?.fields == frozen.readSetPlan?.fields)
    }
}

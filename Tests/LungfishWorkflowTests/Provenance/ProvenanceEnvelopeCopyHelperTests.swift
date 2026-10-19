// ProvenanceEnvelopeCopyHelperTests.swift - ProvenanceEnvelope.with keeps what a copy site leaves alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, panel decisions P5 and E13. Twelve sites copied a recorded envelope by naming
// every field, and each field they forgot was dropped, the status among them. `ProvenanceEnvelope.with`
// replaces them. The walk below reads the stored properties of an envelope by reflection, so a field
// added to the envelope later is checked here without another edit. It fails when the helper loses one,
// and it fails when the fixture leaves one unset, because a fixture that sets nothing would pass a copy
// that drops the field.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceEnvelopeCopyHelperTests: XCTestCase {
    private let plan: ParameterValue = .dictionary(["runs": .integer(2), "mergedReads": .null])

    /// An envelope with every stored property set. The nested run holds only parameters that the options
    /// already hold, so the merge adds nothing and the options must come through unchanged.
    private func fullEnvelope(status: RunStatus = .cancelled) -> ProvenanceEnvelope {
        let input = ProvenanceFileDescriptor(
            path: "/tmp/in.fastq", checksumSHA256: String(repeating: "a", count: 64), fileSize: 12,
            format: .fastq, role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: "/tmp/out.bam", checksumSHA256: String(repeating: "b", count: 64), fileSize: 34,
            format: .bam, role: .output
        )
        let step = ProvenanceStep(
            toolName: "samtools", toolVersion: "1.22", argv: ["samtools", "sort", "/tmp/in.fastq"],
            inputs: [input], outputs: [output], exitStatus: 0, wallTimeSeconds: 1
        )
        return ProvenanceEnvelope(
            schemaVersion: 2,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            workflowName: "lungfish map",
            workflowVersion: "2026.10.14",
            toolName: "minimap2",
            toolVersion: "2.30",
            githubReleaseVersion: "v2.30",
            tool: ProvenanceToolIdentity(
                name: "minimap2", version: "2.30", kind: "conda", managedToolID: ManagedToolID(rawValue: "minimap2")
            ),
            argv: ["lungfish-cli", "map", "/tmp/in.fastq"],
            durableReplayArgv: ["lungfish-cli", "map", "@/in.fastq"],
            reproducibleCommand: "lungfish-cli map /tmp/in.fastq",
            options: ProvenanceOptions(
                explicit: ["mode": .string("fast")],
                defaults: ["quality": .integer(20)],
                resolvedDefaults: ["indexed": .boolean(true)]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "minimap2", condaPrefix: "/envs/minimap2"),
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 12.5,
            exitStatus: 0,
            stderr: "a warning",
            signatures: [
                ProvenanceSignatureReference(
                    provider: "local", provenanceSHA256: String(repeating: "c", count: 64),
                    signaturePath: "/tmp/x.sig", publicKeyPath: "/tmp/x.pub"
                )
            ],
            priorSignatures: [
                ProvenancePriorSignature(
                    provider: "local", publicKeySHA256: String(repeating: "d", count: 64),
                    provenanceSHA256: String(repeating: "e", count: 64), signedAt: Date(timeIntervalSince1970: 1_790_000_100)
                )
            ],
            status: status,
            legacyWorkflowRun: WorkflowRun(
                name: "lungfish map", status: status, parameters: ["mode": .string("fast"), "quality": .integer(20)]
            )
        )
    }

    func testTheFixtureSetsEveryStoredProperty() {
        assertEveryPropertyIsSet(in: fullEnvelope())
    }

    /// The walk. Every stored property comes through `with` unchanged except the two it exists to change.
    func testWithCarriesEveryStoredPropertyItDoesNotChange() {
        let original = fullEnvelope()
        let copy = original.with { _ in }
        assertEveryPropertyCarried(
            copy, from: original, except: ["signatures", "legacyRun"], "ProvenanceEnvelope.with"
        )
        let walked = Set(StepParentSupport.properties(of: original).map(\.name))
        XCTAssertTrue(
            ["signatures", "legacyRun"].allSatisfy(walked.contains),
            "the two exceptions must name stored properties, or the walk hides a rename"
        )
    }

    func testWithClearsTheSignaturesAndDropsTheNestedRun() {
        let copy = fullEnvelope().with { _ in }
        XCTAssertEqual(copy.signatures, [])
        XCTAssertNil(copy.legacyRun)
    }

    func testWithKeepsEveryStatus() {
        for status in [RunStatus.running, .completed, .failed, .cancelled] {
            let source = fullEnvelope(status: status)
            XCTAssertEqual(source.with { _ in }.status, status)
            XCTAssertEqual(source.with { $0.argv = ["changed"] }.status, status, "a change elsewhere keeps the status")
        }
    }

    func testWithChangesOnlyWhatTheChangeSets() {
        let original = fullEnvelope()
        let copy = original.with {
            $0.argv = ["changed"]
            $0.exitStatus = 7
        }
        XCTAssertEqual(copy.argv, ["changed"])
        XCTAssertEqual(copy.exitStatus, 7)
        assertEveryPropertyCarried(
            copy, from: original, except: ["argv", "exitStatus", "signatures", "legacyRun"],
            "ProvenanceEnvelope.with after a change"
        )
    }

    func testWithKeepsTheIdentityOfTheRecord() {
        let original = fullEnvelope()
        let copy = original.with { $0.workflowName = "renamed" }
        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.schemaVersion, original.schemaVersion)
        XCTAssertEqual(copy.toolName, original.toolName)
        XCTAssertEqual(copy.toolVersion, original.toolVersion)
        XCTAssertEqual(copy.tool, original.tool)
    }

    func testWithRethrowsWhatTheChangeThrows() {
        struct Refused: Error {}
        XCTAssertThrowsError(try fullEnvelope().with { _ in throw Refused() })
    }

    // MARK: The nested run's parameters

    private func envelope(
        options: ProvenanceOptions,
        nestedParameters: [String: ParameterValue]?
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            workflowName: "kraken2 classify",
            toolName: "kraken2",
            options: options,
            exitStatus: 0,
            legacyWorkflowRun: nestedParameters.map { WorkflowRun(name: "kraken2 classify", parameters: $0) }
        )
    }

    /// A record written before 2.4 holds `readSetPlan` only in its nested run. The plan lands in the
    /// run-level resolved defaults, the one home of E13, and never in the explicit options.
    func testWithMergesANestedRunsParametersIntoTheResolvedDefaults() {
        let source = envelope(
            options: ProvenanceOptions(explicit: ["confidence": .number(0.2)], resolvedDefaults: ["threads": .integer(4)]),
            nestedParameters: ["readSetPlan": plan, "database": .string("Viral")]
        )
        let copy = source.with { _ in }
        XCTAssertEqual(copy.options.resolvedDefaults["readSetPlan"], plan)
        XCTAssertEqual(copy.options.resolvedDefaults["database"], .string("Viral"))
        XCTAssertEqual(copy.options.resolvedDefaults["threads"], .integer(4), "what the options held stays")
        XCTAssertEqual(copy.options.explicit, ["confidence": .number(0.2)], "nothing lands in the explicit options")
        XCTAssertNil(copy.options.explicit["readSetPlan"])
    }

    func testWithFollowsTheRecorderRuleForAParameterTheOptionsAlreadyHold() {
        let source = envelope(
            options: ProvenanceOptions(
                explicit: ["confidence": .number(0.2)],
                defaults: ["minimumHitGroups": .integer(2)],
                resolvedDefaults: ["threads": .integer(4), "readSetPlan": .string("kept")]
            ),
            nestedParameters: [
                "confidence": .number(0.9),
                "minimumHitGroups": .integer(2),
                "threads": .integer(4),
                "readSetPlan": plan,
                "goal": .string("classify"),
            ]
        )
        let copy = source.with { _ in }
        XCTAssertEqual(copy.options.explicit, ["confidence": .number(0.2)], "the explicit value wins a clash")
        XCTAssertEqual(copy.options.defaults, ["minimumHitGroups": .integer(2)])
        XCTAssertNil(copy.options.resolvedDefaults["confidence"], "an explicit key is not copied")
        XCTAssertNil(copy.options.resolvedDefaults["minimumHitGroups"], "a recorded default is not copied")
        XCTAssertEqual(copy.options.resolvedDefaults["readSetPlan"], .string("kept"), "a resolved default stays")
        XCTAssertEqual(copy.options.resolvedDefaults["goal"], .string("classify"))
        XCTAssertEqual(copy.options.resolvedDefaults["threads"], .integer(4))
    }

    /// A site that replaces the options still gets the nested run's parameters, because the merge runs
    /// after the change.
    func testWithMergesAfterTheChangeReplacedTheOptions() {
        let source = envelope(options: ProvenanceOptions(), nestedParameters: ["readSetPlan": plan])
        let copy = source.with { $0.options = ProvenanceOptions(explicit: ["format": .string("fasta")]) }
        XCTAssertEqual(copy.options.explicit, ["format": .string("fasta")])
        XCTAssertEqual(copy.options.resolvedDefaults["readSetPlan"], plan)
    }

    func testWithAddsNoOptionToARecordWithoutANestedRun() {
        let options = ProvenanceOptions(explicit: ["a": .integer(1)], resolvedDefaults: ["b": .integer(2)])
        let copy = envelope(options: options, nestedParameters: nil).with { _ in }
        XCTAssertEqual(copy.options, options)
    }

    /// `WorkflowRun.canonicalEnvelope()` embeds its run, whose parameters are the explicit options, so
    /// copying such an envelope must not repeat every option in the resolved defaults.
    func testWithAddsNothingForAnEnvelopeBuiltFromItsRun() {
        let run = WorkflowRun(name: "demo", status: .completed, parameters: ["a": .integer(1), "b": .string("x")])
        let built = run.canonicalEnvelope()
        XCTAssertNotNil(built.legacyRun)
        let copy = built.with { _ in }
        XCTAssertEqual(copy.options, built.options)
        XCTAssertEqual(copy.options.resolvedDefaults, [:])
        XCTAssertEqual(copy.status, .completed)
    }
}

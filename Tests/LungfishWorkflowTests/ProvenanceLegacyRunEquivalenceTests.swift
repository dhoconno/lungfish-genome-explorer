// ProvenanceLegacyRunEquivalenceTests.swift - A record without its nested run says what the nested run said
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// New records stop carrying `legacyWorkflowRun`, so every reader that asks an envelope for its
/// legacy run gets one rebuilt from the envelope's own fields. These tests prove that the run
/// rebuilt from a record without its nested run equals the nested run on name, status,
/// parameters, and on every step's tool, version, command, durable argv, files, exit code, wall
/// time, peak memory, dependencies and container identity. A field the rebuilt run lost would
/// fail here before the encoder drops the nested run.
///
/// Two kinds of record are read. A record that still holds its nested run (a frozen capture, or
/// an envelope in memory) is compared with its own nested run. A scenario written by today's
/// writer is compared by facts with the frozen case it was captured as, so the check holds
/// after the encoder stops writing the run.
@Suite("Provenance legacy run equivalence")
struct ProvenanceLegacyRunEquivalenceTests {
    // MARK: Helpers

    /// The envelope as a record without a nested run reads: encoded, the `legacyWorkflowRun` key
    /// removed, and decoded again.
    static func withoutNestedRun(_ envelope: ProvenanceEnvelope) throws -> ProvenanceEnvelope {
        let encoded = try ProvenanceJSON.encoder.encode(envelope)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "legacyWorkflowRun")
        let stripped = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(stripped.legacyRun == nil)
        return stripped
    }

    /// Rewrites the sidecar without its `legacyWorkflowRun` key, which is how a record written
    /// without it reads. A sidecar that has no such key is left alone.
    static func removeNestedRun(from sidecar: URL) throws {
        let bytes = try Data(contentsOf: sidecar)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        guard object.removeValue(forKey: "legacyWorkflowRun") != nil else { return }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: sidecar)
    }

    private static func json(_ value: ParameterValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<unprintable>" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One line per way `rebuilt` loses or changes something `nested` says. The rebuilt run may
    /// hold more than the nested one in two places by design. Its parameters are the envelope's
    /// explicit options, which may name more, and its final step also lists the outputs of the
    /// earlier steps (`mergeFallbackOutputsIntoFinalStep`).
    static func differences(nested: WorkflowRun, rebuilt: WorkflowRun) -> [String] {
        var lines: [String] = []
        func check<Value: Equatable>(_ label: String, _ expected: Value, _ found: Value) {
            if expected != found { lines.append("\(label): expected \(expected), found \(found)") }
        }
        check("name", nested.name, rebuilt.name)
        check("status", nested.status, rebuilt.status)
        for (key, value) in nested.parameters.sorted(by: { $0.key < $1.key }) {
            let found = rebuilt.parameters[key].map(json) ?? "<absent>"
            if found != json(value) { lines.append("parameters.\(key): expected \(json(value)), found \(found)") }
        }
        check("steps", nested.steps.count, rebuilt.steps.count)
        for (index, pair) in zip(nested.steps, rebuilt.steps).enumerated() {
            let (expected, found) = pair
            let label = "steps[\(index)]"
            check("\(label).id", expected.id, found.id)
            check("\(label).toolName", expected.toolName, found.toolName)
            check("\(label).toolVersion", expected.toolVersion, found.toolVersion)
            check("\(label).command", expected.command, found.command)
            check("\(label).durableReplayArgv", expected.durableReplayArgv, found.durableReplayArgv)
            check("\(label).containerImage", expected.containerImage, found.containerImage)
            check("\(label).containerDigest", expected.containerDigest, found.containerDigest)
            check("\(label).exitCode", expected.exitCode, found.exitCode)
            check("\(label).wallTime", expected.wallTime, found.wallTime)
            check("\(label).peakMemoryBytes", expected.peakMemoryBytes, found.peakMemoryBytes)
            check("\(label).dependsOn", expected.dependsOn, found.dependsOn)
            check("\(label).stderr", expected.stderr, found.stderr)
            check("\(label).inputs", expected.inputs, found.inputs)
            let lost = expected.outputs.filter { !found.outputs.contains($0) }
            if !lost.isEmpty { lines.append("\(label).outputs lost \(lost)") }
            if index < nested.steps.count - 1 { check("\(label).outputs", expected.outputs, found.outputs) }
        }
        return lines
    }

    /// The facts of the sidecar the scenario wrote, after the nested run is removed, and the facts of the case it reproduces.
    private static func facts(
        of sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        andCase id: String
    ) throws -> (live: ProvenanceCompatFacts, frozen: ProvenanceCompatFacts) {
        try removeNestedRun(from: sidecar)
        let live = try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: project.root)
        let frozen = try ProvenanceCompatFacts.decode(
            try #require(ProvenanceCompatCorpus.expectedFactsData(for: id), "case \(id) has no expected facts")
        )
        return (live, frozen)
    }

    // MARK: Frozen captures

    @Test(
        "a frozen run-bearing capture rebuilds its nested run from the envelope alone",
        arguments: ["s1-cancelled-single-step", "s1-canonical-envelope-run", "s1-recorder-readsetplan"]
    )
    func frozenCaptureRebuildsItsNestedRun(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        let nested = try #require(envelope.legacyRun, "case \(id) embeds its run")

        let rebuilt = try Self.withoutNestedRun(envelope).legacyWorkflowRun(preferCanonicalSteps: true)
        let lines = Self.differences(nested: nested, rebuilt: rebuilt)

        if id == "s1-recorder-readsetplan" {
            // The one loss in the frozen bytes. The save passed explicit options that did not name
            // the readSetPlan, so the plan survived only in the nested run. The recorder merges
            // the run's parameters into the options now, and the scenario test below shows it.
            #expect(lines.count == 1 && lines[0].hasPrefix("parameters.readSetPlan: expected"), "\(lines)")
        } else {
            #expect(lines.isEmpty, "\(lines)")
        }
        #expect(rebuilt.status == nested.status)
    }

    @Test("the frozen cancelled capture rebuilds as cancelled with its peak memory")
    func frozenCancelledCaptureRebuildsAsCancelled() throws {
        let materialized = try ProvenanceCompatCorpus.materialize("s1-cancelled-single-step")
        defer { materialized.cleanup() }
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        let rebuilt = try Self.withoutNestedRun(envelope).legacyWorkflowRun(preferCanonicalSteps: true)

        #expect(envelope.exitStatus == 0)
        #expect(rebuilt.status == .cancelled)
        #expect(rebuilt.steps.first?.peakMemoryBytes == 42_000_000)
        #expect(rebuilt.steps.first?.exitCode == 0)
    }

    // MARK: Producers in memory

    @Test("the variants phase run rebuilds from the canonical envelope made from it")
    func variantsPhaseRunRebuildsFromItsCanonicalEnvelope() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)
        let run = try ProvenanceCompatScenarios.variantsPhaseRun(project: project.root, analysis: analysis)

        let envelope = run.canonicalEnvelope()
        #expect(envelope.legacyRun == run)
        let rebuilt = try Self.withoutNestedRun(envelope).legacyWorkflowRun(preferCanonicalSteps: true)

        #expect(Self.differences(nested: run, rebuilt: rebuilt).isEmpty, "\(Self.differences(nested: run, rebuilt: rebuilt))")
        #expect(rebuilt.steps.count == 2)
        #expect(rebuilt.steps[1].dependsOn == [rebuilt.steps[0].id])
        #expect(rebuilt.steps[1].durableReplayArgv == run.steps[1].durableReplayArgv)
        // The one thing the rebuilt run holds beyond the nested one is the earlier step's output,
        // which `mergeFallbackOutputsIntoFinalStep` also lists on the final step.
        let extra = rebuilt.steps[1].outputs.filter { !run.steps[1].outputs.contains($0) }
        #expect(extra.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["raw.vcf"])
    }

    @Test("a mapping record rebuilds from the envelope MappingProvenance writes")
    func mappingRecordRebuildsFromItsEnvelope() throws {
        let directory = try TestTempDirectory.make(prefix: "legacy-run-mapping")
        defer { TestTempDirectory.cleanup(directory) }
        let provenance = try Self.mappingProvenance(in: directory)

        let envelope = provenance.canonicalEnvelope(sourceDirectory: directory)
        let nested = try #require(envelope.legacyRun, "MappingProvenance builds the envelope with its run")
        let rebuilt = try Self.withoutNestedRun(envelope).legacyWorkflowRun(preferCanonicalSteps: true)

        #expect(nested.steps.count >= 3)
        #expect(!nested.parameters.isEmpty)
        #expect(Self.differences(nested: nested, rebuilt: rebuilt).isEmpty, "\(Self.differences(nested: nested, rebuilt: rebuilt))")
    }

    /// A small mapping run: minimap2, then two samtools steps, with their files on disk.
    private static func mappingProvenance(in directory: URL) throws -> MappingProvenance {
        let reads = directory.appendingPathComponent("reads.fastq")
        try Data("@r1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n".utf8).write(to: reads)
        let reference = directory.appendingPathComponent("reference.fa")
        try Data(">chr1\nACGTACGTACGT\n".utf8).write(to: reference)
        let sourceBundle = directory.appendingPathComponent("source.lungfishref", isDirectory: true)
        let viewerBundle = directory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: viewerBundle, withIntermediateDirectories: true)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [reads],
            referenceFASTAURL: reference,
            sourceReferenceBundleURL: sourceBundle,
            outputDirectory: directory,
            sampleName: "sample",
            threads: 8,
            includeSecondary: false,
            includeSupplementary: false,
            minimumMappingQuality: 17,
            advancedArguments: ["--eqx"]
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            sourceReferenceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle,
            bamURL: directory.appendingPathComponent("sample.sorted.bam"),
            baiURL: directory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 91,
            unmappedReads: 9,
            wallClockSeconds: 12.5,
            contigs: []
        )
        try Data("bam".utf8).write(to: result.bamURL)
        try Data("bai".utf8).write(to: result.baiURL)
        let rawSAM = directory.appendingPathComponent("sample.raw.sam")
        let filteredBAM = directory.appendingPathComponent("sample.filtered.bam")
        try Data("sam".utf8).write(to: rawSAM)
        try Data("filtered".utf8).write(to: filteredBAM)

        let mapperCommand = try MappingProvenance.mapperInvocation(
            for: request,
            referenceLocator: ReferenceLocator(
                referenceURL: reference,
                indexPrefixURL: directory.appendingPathComponent("index/reference-index")
            )
        )
        let normalization = MappingProvenance.normalizationInvocations(
            rawAlignmentURL: rawSAM,
            outputDirectory: directory,
            sampleName: request.sampleName,
            threads: request.threads,
            minimumMappingQuality: request.minimumMappingQuality,
            includeSecondary: request.includeSecondary,
            includeSupplementary: request.includeSupplementary
        )
        let readsRecord = ProvenanceRecorder.fileRecord(url: reads, format: .fastq, role: .input)
        let rawRecord = ProvenanceRecorder.fileRecord(url: rawSAM, format: .sam, role: .output)
        let filteredRecord = ProvenanceRecorder.fileRecord(url: filteredBAM, format: .bam, role: .output)
        let bamRecord = ProvenanceRecorder.fileRecord(url: result.bamURL, format: .bam, role: .output)
        return MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapperCommand,
            normalizationInvocations: normalization,
            mapperVersion: "2.30",
            samtoolsVersion: "1.21",
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
            inputFiles: [
                readsRecord,
                ProvenanceRecorder.fileRecord(url: reference, format: .fasta, role: .reference),
            ],
            outputFiles: [bamRecord, ProvenanceRecorder.fileRecord(url: result.baiURL, role: .index)],
            runtimeIdentity: ["mapper": "managed conda environment minimap2; executable minimap2"],
            steps: [
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.30",
                    command: mapperCommand.argv,
                    inputs: [readsRecord],
                    outputs: [rawRecord],
                    exitCode: 0,
                    wallTime: 1.0,
                    stderr: "mapper stderr"
                ),
                StepExecution(
                    toolName: "samtools",
                    toolVersion: "1.21",
                    command: normalization[0].argv,
                    inputs: [ProvenanceRecorder.fileRecord(url: rawSAM, format: .sam, role: .input)],
                    outputs: [filteredRecord],
                    exitCode: 0,
                    wallTime: 0.5,
                    stderr: ""
                ),
                StepExecution(
                    toolName: "samtools",
                    toolVersion: "1.21",
                    command: normalization[1].argv,
                    inputs: [ProvenanceRecorder.fileRecord(url: filteredBAM, format: .bam, role: .input)],
                    outputs: [bamRecord],
                    exitCode: 0,
                    wallTime: 0.5
                ),
            ],
            exitStatus: 0
        )
    }

    // MARK: Scenarios written by today's writers

    @Test("the recorder run keeps its readSetPlan in the options and reads back as the run it recorded")
    func recorderScenarioKeepsItsReadSetPlan() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sidecar = try await ProvenanceCompatScenarios.recorderRunWithReadSetPlan(in: project)
        let (live, frozen) = try Self.facts(of: sidecar, in: project, andCase: "s1-recorder-readsetplan")

        // The only difference from the frozen bytes is the plan, now in the explicit options.
        let lines = live.differences(
            from: frozen,
            ignoring: ProvenanceCompatFacts.runSpecific.union(ProvenanceCompatFacts.shapeChange)
        )
        #expect(lines.count == 1 && lines[0].hasPrefix("explicitOptions.readSetPlan: expected <absent>"), "\(lines)")
        // The run rebuilt from the record, with no nested run, has the plan the nested run held.
        #expect(live.legacyRunParameters == frozen.legacyRunParameters)
        #expect(live.legacyRunSteps == frozen.legacyRunSteps)
        #expect(live.readStatus == frozen.readStatus)

        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        #expect(envelope.legacyRun == nil)
        #expect(envelope.options.explicit["readSetPlan"] != nil)
        #expect(envelope.legacyWorkflowRun().parameters["readSetPlan"] == envelope.options.explicit["readSetPlan"])
    }

    @Test("the variants phase canonical envelope reads back as the run it was made from")
    func variantsPhaseScenarioReadsBackAsItsRun() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)
        let run = try ProvenanceCompatScenarios.variantsPhaseRun(project: project.root, analysis: analysis)
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: analysis)
        let sidecar = analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let (live, frozen) = try Self.facts(of: sidecar, in: project, andCase: "s1-canonical-envelope-run")

        let lines = live.differences(
            from: frozen,
            ignoring: ProvenanceCompatFacts.runSpecific.union(ProvenanceCompatFacts.shapeChange)
        )
        #expect(lines.isEmpty, "\(lines)")
        #expect(live.legacyRunSteps == frozen.legacyRunSteps)
        #expect(live.legacyRunParameters == frozen.legacyRunParameters)
    }

    @Test("the containerized GATK run keeps each step's container when its bare run becomes a canonical envelope")
    func gatkContainerScenarioKeepsEachStepsContainer() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sidecar = try await ProvenanceCompatScenarios.gatkContainerRun(in: project)

        // The executor writes a bare run today. Read it and write it as the bare-run writers will,
        // as a canonical envelope without a nested run.
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        try ProvenanceWriter(signingProvider: nil).write(try Self.withoutNestedRun(envelope), toSidecar: sidecar)
        let (live, frozen) = try Self.facts(of: sidecar, in: project, andCase: "s3-gatk-container-bare-run")

        #expect(live.legacyRunSteps.count == 2)
        for step in live.legacyRunSteps {
            #expect(step.containerImage == ProvenanceCompatScenarios.gatkContainerImage)
            #expect(step.containerDigest == ProvenanceCompatScenarios.gatkContainerDigest)
        }
        // Both legacy step views compare exactly, which is where a lost image or digest would show.
        #expect(live.legacyRunSteps == frozen.legacyRunSteps)
        #expect(live.canonicalRunSteps == frozen.canonicalRunSteps)
        // An envelope step keeps no container key of its own, so that map of the steps' bytes is
        // the one thing that changes with the shape, and the views above carry the image and digest.
        let lines = live.differences(
            from: frozen,
            ignoring: ProvenanceCompatFacts.runSpecific
                .union(ProvenanceCompatFacts.shapeChange)
                .union([.stepRecordedContainer]),
            runWallTimeTolerance: 1
        )
        #expect(lines.isEmpty, "\(lines)")
    }

    // MARK: V9, the recorder keeps the run's parameters

    @Test("save merges the run's parameters into the explicit options, the caller wins a clash and defaults stay defaults")
    func saveMergesRunParametersIntoOptions() async throws {
        let directory = try TestTempDirectory.make(prefix: "legacy-run-merge")
        defer { TestTempDirectory.cleanup(directory) }
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let plan: ParameterValue = .dictionary(["runs": .integer(2), "reason": .string("orphans run as singles")])
        let runID = await recorder.beginRun(
            name: "Merge",
            parameters: [
                // Only the run has these two, so the record keeps them as explicit options.
                "readSetPlan": plan,
                "onlyInRun": .string("run value"),
                // The caller has this one as an explicit option too, and its value wins.
                "clash": .string("run value"),
                // The caller records these two as a default and a resolved default with the same
                // value, so they stay there and do not turn into explicit options.
                "inDefaults": .integer(4),
                "inResolved": .string("G"),
                // The caller's resolved default has another value, so the run's value is kept.
                "resolvedElsewhere": .integer(1),
            ]
        )
        await recorder.recordStep(
            runID: runID,
            toolName: "fixture-tool",
            toolVersion: "1.0.0",
            command: ["fixture-tool", "--run"],
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 1
        )
        await recorder.completeRun(runID, status: .completed)

        let withOptions = directory.appendingPathComponent("with-options", isDirectory: true)
        try await recorder.save(
            runID: runID,
            to: withOptions,
            options: ProvenanceOptions(
                explicit: ["clash": .string("caller value"), "onlyInOptions": .integer(1)],
                defaults: ["inDefaults": .integer(4)],
                resolvedDefaults: ["inResolved": .string("G"), "resolvedElsewhere": .integer(2)]
            )
        )
        let merged = try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: withOptions.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        #expect(merged.options.explicit == [
            "readSetPlan": plan,
            "onlyInRun": .string("run value"),
            "clash": .string("caller value"),
            "onlyInOptions": .integer(1),
            "resolvedElsewhere": .integer(1),
        ])
        #expect(merged.options.defaults == ["inDefaults": .integer(4)])
        #expect(merged.options.resolvedDefaults == ["inResolved": .string("G"), "resolvedElsewhere": .integer(2)])
        // The parameters that only the run had, or that the caller also records as a default, are all
        // still somewhere in the record with the run's value.
        let everywhere = merged.options.explicit
            .merging(merged.options.defaults) { explicit, _ in explicit }
            .merging(merged.options.resolvedDefaults) { current, _ in current }
        #expect(everywhere["readSetPlan"] == plan)
        #expect(everywhere["inDefaults"] == .integer(4))
        #expect(everywhere["inResolved"] == .string("G"))

        // Without options the explicit options already were the run's parameters.
        let plain = directory.appendingPathComponent("plain", isDirectory: true)
        try await recorder.save(runID: runID, to: plain)
        let plainEnvelope = try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: plain.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        #expect(plainEnvelope.options.explicit == [
            "readSetPlan": plan,
            "onlyInRun": .string("run value"),
            "clash": .string("run value"),
            "inDefaults": .integer(4),
            "inResolved": .string("G"),
            "resolvedElsewhere": .integer(1),
        ])
        #expect(plainEnvelope.options.defaults.isEmpty)
    }
}

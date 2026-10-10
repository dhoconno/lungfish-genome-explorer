import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Sends the frozen corpus through the three rehydrators that rewrite a source sidecar for a new
/// place, into a temporary destination project. What each must keep is what a user's record needs
/// after an import: the tool names and versions, the exit status, the step graph, the argv tokens
/// that are not machine paths, the container identity and the status. What each re-roots is the
/// output paths.
///
/// Where today's behaviour falls short of that, the test says so instead of weakening the check.
/// The generic and GUI rehydrators write no embedded run, so a copied cancelled run reads as
/// completed (finding F3). The GUI import also rebuilds each step without its peak memory, resolved
/// options, runtime identity and release version (lane finding W1A-1). The checks for both sit
/// inside `withKnownIssue`, so the suite passes today. The losses are deterministic, so the lane
/// that fixes one gets a red "known issue was not recorded" and promotes that check to a plain
/// expectation, which then guards the fix as a declared, reviewed difference.
@Suite("Provenance compatibility rehydration")
struct ProvenanceCompatRehydrationTests {
    static let cancelledCaseID = "s1-cancelled-single-step"
    static let gatkCaseID = "s3-gatk-container-bare-run"

    /// The cases whose sidecar sits at a folder root, which is where `load(from:)` looks.
    static let folderSidecarCaseIDs: [String] = ((try? ProvenanceCompatCorpus.cases()) ?? [])
        .filter { ($0.layoutPath as NSString).lastPathComponent == ProvenanceCompatCorpus.sidecarFilename }
        .map(\.id)

    // MARK: ProvenanceRehydrator

    @Test(
        "the generic rehydrator keeps identity, steps, argv tokens and container identity, and re-roots outputs",
        arguments: ProvenanceCompatCorpus.caseIDs()
    )
    func genericRehydratorKeepsIdentityAndReRootsOutputs(id: String) throws {
        let source = try ProvenanceCompatCorpus.materialize(id)
        let destination = try ProvenanceCompatScenarios.makeProject()
        defer {
            source.cleanup()
            destination.cleanup()
        }
        let sourceEnvelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: source.sidecar))
        let sourceFacts = try ProvenanceCompatFacts.project(
            envelope: sourceEnvelope, sidecar: source.sidecar, projectRoot: source.projectRoot
        )

        // Map every recorded output to a stand-in in the destination project. Directories map to directories.
        let imported = try destination.folder("Imported")
        var pathMap: [String: String] = [:]
        for (index, path) in Self.outputPaths(of: sourceEnvelope).enumerated() {
            let target = imported.appendingPathComponent("\(index)-\((path as NSString).lastPathComponent)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try ProvenanceCompatScenarios.write("stand-in \(index)", to: target)
            }
            pathMap[path] = target.path
        }
        let finalDirectory = destination.root.appendingPathComponent("Final", isDirectory: true)

        try ProvenanceRehydrator.rehydrate(
            sourceDirectory: source.sidecar.deletingLastPathComponent(),
            finalDirectory: finalDirectory,
            pathMap: pathMap
        )

        let sidecar = finalDirectory.appendingPathComponent(ProvenanceCompatCorpus.sidecarFilename)
        let rehydrated = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let rehydratedFacts = try ProvenanceCompatFacts.project(
            envelope: rehydrated, sidecar: sidecar, projectRoot: destination.root
        )

        // Identity, exit status and the step graph.
        #expect(rehydrated.workflowName == sourceEnvelope.workflowName)
        #expect(rehydrated.toolName == sourceEnvelope.toolName)
        #expect(rehydrated.toolVersion == sourceEnvelope.toolVersion)
        #expect(rehydrated.exitStatus == sourceEnvelope.exitStatus)
        #expect(Self.stepIdentity(rehydratedFacts.steps) == Self.stepIdentity(sourceFacts.steps))

        // The argv keeps its length, and every token that is not an absolute path is verbatim.
        Self.expectArgvKeptExceptAbsolutePaths(rehydrated.argv, sourceEnvelope.argv)

        // Container identity survives in the exporters' step view.
        #expect(rehydratedFacts.canonicalRunSteps.map(\.containerImage) == sourceFacts.canonicalRunSteps.map(\.containerImage))
        #expect(rehydratedFacts.canonicalRunSteps.map(\.containerDigest) == sourceFacts.canonicalRunSteps.map(\.containerDigest))

        // Outputs are re-rooted into the destination and remember where they came from.
        let mappedTargets = Set(pathMap.values.map(Self.physicalPath))
        #expect(!rehydrated.outputs.isEmpty)
        for output in rehydrated.outputs {
            #expect(mappedTargets.contains(Self.physicalPath(output.path)), "output \(output.path) is not a mapped destination")
            #expect(output.originPath != nil, "output \(output.path) lost its origin")
        }
        // An argv token that named a recorded output now names the destination in the durable replay argv.
        let replayBase = sourceEnvelope.durableReplayArgv ?? sourceEnvelope.argv
        let replayed = rehydrated.durableReplayArgv ?? []
        #expect(replayed.count == replayBase.count)
        for (token, replayedToken) in zip(replayBase, replayed) {
            if let target = pathMap[token] {
                #expect(Self.physicalPath(replayedToken) == Self.physicalPath(target))
            }
        }

        // Status. Neither this rehydrator nor the GUI one writes an embedded run, so a cancelled run
        // reads as completed today.
        if id == Self.cancelledCaseID {
            withKnownIssue(
                "F3: the rehydrator writes no embedded run, so a copied cancelled run reads completed"
            ) {
                #expect(rehydratedFacts.readStatus == sourceFacts.readStatus)
            }
            #expect(sourceFacts.readStatus == "cancelled")
        } else {
            #expect(rehydratedFacts.readStatus == sourceFacts.readStatus)
        }
    }

    // MARK: GUIImportedProvenanceRehydrator

    /// Runs of the captured cases that wrote a recreated payload file the GUI can import. Their
    /// frozen sidecar is copied beside the output as a file sidecar, which is how a CLI output
    /// that sits outside a project carries its record.
    @Test(
        "a GUI file import keeps the steps, appends an import step and re-roots the output",
        arguments: [
            "s3-write-sidecar-bare-run", "s1-canonical-envelope-run",
            ProvenanceCompatRehydrationTests.cancelledCaseID, ProvenanceCompatRehydrationTests.gatkCaseID,
        ]
    )
    func guiFileImportKeepsStepsAndAppendsAnImportStep(id: String) async throws {
        let source = try ProvenanceCompatCorpus.materialize(id)
        let destination = try ProvenanceCompatScenarios.makeProject()
        defer {
            source.cleanup()
            destination.cleanup()
        }
        let analysis = source.sidecar.deletingLastPathComponent()
        let outputName: String
        if id == Self.cancelledCaseID {
            // The cancelled run's input and its empty output, as the scenario writes them.
            try ProvenanceCompatScenarios.write("@r1\nACGT\n+\nIIII\n", to: source.projectRoot.appendingPathComponent("Inputs/reads.fastq"))
            try Data().write(to: analysis.appendingPathComponent("trimmed.fastq"))
            outputName = "trimmed.fastq"
        } else if id == Self.gatkCaseID {
            // The scenario's executor writes the payload files the capture recorded, into a scratch
            // project. They are copied beside the frozen record.
            let scratch = try ProvenanceCompatScenarios.makeProject()
            defer { scratch.cleanup() }
            let liveFolder = try await ProvenanceCompatScenarios.gatkContainerRun(in: scratch).deletingLastPathComponent()
            for name in ["combined.g.vcf", "joint.vcf"] {
                try FileManager.default.copyItem(
                    at: liveFolder.appendingPathComponent(name),
                    to: analysis.appendingPathComponent(name)
                )
            }
            outputName = "joint.vcf"
        } else {
            // The scenario writes the same payload files the capture recorded.
            _ = try ProvenanceCompatScenarios.variantsPhaseRun(project: source.projectRoot, analysis: analysis)
            outputName = "phased.vcf"
        }
        let sourceFile = analysis.appendingPathComponent(outputName)
        try FileManager.default.copyItem(at: source.sidecar, to: ProvenanceRecorder.fileSidecarURL(for: sourceFile))

        let sourceEnvelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: source.sidecar))
        let recordedOutput = try #require(
            sourceEnvelope.outputs.first { Self.physicalPath($0.path) == Self.physicalPath(sourceFile.path) }
        )
        // The recreated payload is the file the frozen record names.
        #expect(try ProvenanceFileHasher.sha256(of: sourceFile) == recordedOutput.checksumSHA256)
        #expect(try ProvenanceFileHasher.fileSize(of: sourceFile) == recordedOutput.fileSize)

        let destinationFile = destination.root.appendingPathComponent("Imports/\(outputName)")
        try FileManager.default.createDirectory(at: destinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceFile, to: destinationFile)

        // The other records name the lungfish CLI, so the gate accepts them. Nothing in the GATK
        // executor's record does, so today's gate refuses it and the import has to waive the gate.
        let requireCLIProvenance = id != Self.gatkCaseID
        if !requireCLIProvenance {
            #expect(throws: GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance(sourceFile.path)) {
                try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(from: sourceFile, to: destinationFile)
            }
        }
        try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(
            from: sourceFile,
            to: destinationFile,
            requireCLIProvenance: requireCLIProvenance
        )

        let sidecar = ProvenanceRecorder.fileSidecarURL(for: destinationFile)
        let rehydrated = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let rehydratedFacts = try ProvenanceCompatFacts.project(
            envelope: rehydrated, sidecar: sidecar, projectRoot: destination.root
        )
        let sourceFacts = try ProvenanceCompatFacts.project(
            envelope: sourceEnvelope, sidecar: source.sidecar, projectRoot: source.projectRoot
        )

        // The original steps are kept in order, and one import step is appended. The step's peak
        // memory is not part of the comparison, because this import rebuilds the step without it.
        #expect(rehydrated.steps.count == sourceEnvelope.steps.count + 1)
        let keptSteps = Array(rehydratedFacts.steps.dropLast())
        #expect(
            Self.stepIdentity(keptSteps, includePeakMemory: false)
                == Self.stepIdentity(sourceFacts.steps, includePeakMemory: false)
        )
        // The loss shows only where the source recorded a peak memory, so the known issue is
        // declared for those cases alone and every other case is checked plainly.
        if sourceFacts.steps.contains(where: { $0.peakMemoryBytes != nil }) {
            withKnownIssue(
                "W1A-1: the GUI import rebuilds each step without its peak memory"
            ) {
                #expect(keptSteps.map(\.peakMemoryBytes) == sourceFacts.steps.map(\.peakMemoryBytes))
            }
        } else {
            #expect(keptSteps.map(\.peakMemoryBytes) == sourceFacts.steps.map(\.peakMemoryBytes))
        }

        // Container identity. The imported envelope holds no embedded run, so both step views are
        // rebuilt from the envelope, and a run with one container still shows its image and digest
        // on every step. A run with several containers is where finding F8 would show a loss.
        let keptCount = sourceEnvelope.steps.count
        #expect(
            rehydratedFacts.canonicalRunSteps.prefix(keptCount).map(\.containerImage)
                == sourceFacts.canonicalRunSteps.map(\.containerImage)
        )
        #expect(
            rehydratedFacts.canonicalRunSteps.prefix(keptCount).map(\.containerDigest)
                == sourceFacts.canonicalRunSteps.map(\.containerDigest)
        )
        // This is the view that Copy Command and ops stats read.
        #expect(
            rehydratedFacts.legacyRunSteps.prefix(keptCount).map(\.containerImage)
                == sourceFacts.legacyRunSteps.map(\.containerImage)
        )

        let importStep = try #require(rehydrated.steps.last)
        #expect(importStep.toolName == "lungfish-app")
        #expect(Array(importStep.argv.prefix(2)) == ["lungfish-app", "gui-import"])
        #expect(rehydrated.toolName == sourceEnvelope.toolName)
        #expect(rehydrated.toolVersion == sourceEnvelope.toolVersion)
        #expect(rehydrated.exitStatus == sourceEnvelope.exitStatus)
        Self.expectArgvKeptExceptAbsolutePaths(rehydrated.argv, sourceEnvelope.argv)

        // The output now names the imported file and remembers the source.
        #expect(rehydrated.outputs.map { Self.physicalPath($0.path) } == [Self.physicalPath(destinationFile.path)])
        #expect(rehydrated.outputs.allSatisfy { $0.originPath != nil })

        if id == Self.cancelledCaseID {
            withKnownIssue(
                "F3: the GUI rehydrator writes no embedded run, so an imported cancelled run reads completed"
            ) {
                #expect(rehydratedFacts.readStatus == sourceFacts.readStatus)
            }
        } else {
            #expect(rehydratedFacts.readStatus == sourceFacts.readStatus)
        }
    }

    @Test("the GUI gate accepts the legacy executable name lungfish and still cannot import the alpha.11 file")
    func guiGateAcceptsTheLegacyExecutableName() throws {
        let source = try ProvenanceCompatCorpus.materialize("s3-ncbi-fetch-alpha11")
        let destination = try ProvenanceCompatScenarios.makeProject()
        defer {
            source.cleanup()
            destination.cleanup()
        }
        let sourceFile = source.sidecar.deletingLastPathComponent().appendingPathComponent("MN908947.3.gff3")
        let destinationFile = destination.root.appendingPathComponent("Imports/MN908947.3.gff3")
        try FileManager.default.createDirectory(at: destinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceFile, to: destinationFile)

        // argv[0] is `lungfish`, which the gate accepts as the CLI. So the import is not refused
        // as unsupported provenance. It fails later, because the recorded output path belongs to
        // the machine that wrote the record and is not the file being imported.
        #expect(try ProvenanceEnvelopeReader.load(fromSidecar: source.sidecar)?.argv.first == "lungfish")
        do {
            try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(from: sourceFile, to: destinationFile)
            Issue.record("expected the import of the alpha.11 fetch record to fail")
        } catch let error as ProvenanceRehydrationError {
            #expect(error == .outputPathNotMapped(sourceFile.path))
        } catch {
            Issue.record("expected outputPathNotMapped, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: destinationFile).path))
    }

    @Test("a GUI bundle import refuses the shipped MCM record as a non-CLI record and takes the MSA record past the gate")
    func guiBundleImportGate() throws {
        let destination = try ProvenanceCompatScenarios.makeProject()
        defer { destination.cleanup() }

        let mcm = try ProvenanceCompatCorpus.materialize("s4-mcm-mhcref-shipped")
        defer { mcm.cleanup() }
        let mcmBundle = mcm.sidecar.deletingLastPathComponent()
        let mcmTarget = destination.root.appendingPathComponent("Imports/\(mcmBundle.lastPathComponent)", isDirectory: true)
        try FileManager.default.createDirectory(at: mcmTarget, withIntermediateDirectories: true)
        do {
            try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: mcmBundle, to: mcmTarget)
            Issue.record("expected the MCM record to be refused")
        } catch let error as GUIImportedProvenanceRehydratorError {
            #expect(error == .unsupportedSourceProvenance(mcmBundle.path))
        } catch {
            Issue.record("expected unsupportedSourceProvenance, got \(error)")
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: mcmTarget.appendingPathComponent(ProvenanceCompatCorpus.sidecarFilename).path
            ),
            "a refused import must not leave a sidecar in the destination"
        )

        // The MSA record names `lungfish align mafft`, with the legacy executable name as argv[0], so the
        // gate admits it. The import then stops, because the corpus stores the sidecar and not the
        // bundle's payload files, which the import hashes before it writes anything.
        let msa = try ProvenanceCompatCorpus.materialize("s4-msa-mafft-2026-05")
        defer { msa.cleanup() }
        let msaBundle = msa.sidecar.deletingLastPathComponent()
        let msaTarget = destination.root.appendingPathComponent("Imports/\(msaBundle.lastPathComponent)", isDirectory: true)
        try FileManager.default.createDirectory(at: msaTarget, withIntermediateDirectories: true)
        do {
            try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: msaBundle, to: msaTarget)
            Issue.record("expected the MSA bundle import to stop, because its payload files are not in the corpus")
        } catch let error as GUIImportedProvenanceRehydratorError {
            #expect(error != .unsupportedSourceProvenance(msaBundle.path), "the gate must admit argv[0] lungfish")
        } catch {
            // Any other error comes from reading the payload files, which the corpus does not hold.
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: msaTarget.appendingPathComponent(ProvenanceCompatCorpus.sidecarFilename).path
            ),
            "a refused import must not leave a sidecar in the destination"
        )
    }

    // MARK: ReferenceBundleImportProvenanceRehydrator

    @Test(
        "the reference bundle rehydrator keeps tool identity, step graph and status, and replaces the command",
        arguments: ProvenanceCompatRehydrationTests.folderSidecarCaseIDs
    )
    func referenceBundleRehydratorKeepsToolIdentityAndStatus(id: String) throws {
        let source = try ProvenanceCompatCorpus.materialize(id)
        defer { source.cleanup() }
        let bundle = source.sidecar.deletingLastPathComponent()
        let before = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: source.sidecar))
        let durable = try ProvenanceCompatScenarios.write(
            ">chr1\nACGT\n",
            to: source.projectRoot.appendingPathComponent("durable/import-source.fasta")
        )
        let replay = ["lungfish-cli", "import", "fasta", durable.path, "--output", bundle.path]
        let context = ReferenceBundleImportProvenanceContext(
            workflowName: "reference.import",
            replayCommand: replay,
            options: ProvenanceOptions(explicit: ["format": .string("fasta")])
        )

        try ReferenceBundleImportProvenanceRehydrator.rehydrateSidecar(
            bundleURL: bundle,
            durableSourceURL: durable,
            sourceRelativePath: "import-source.fasta",
            context: context
        )

        let after = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: source.sidecar))
        // The import replaces the workflow name and the command, which is its purpose.
        #expect(after.workflowName == "reference.import")
        #expect(after.argv == replay)
        // Everything about the tools that ran is kept.
        #expect(after.exitStatus == before.exitStatus)
        let oldRun = before.legacyWorkflowRun()
        let newRun = after.legacyWorkflowRun()
        #expect(newRun.status == oldRun.status)
        #expect(newRun.steps.count == oldRun.steps.count)
        for (old, new) in zip(oldRun.steps, newRun.steps) {
            #expect(new.toolName == old.toolName)
            #expect(new.toolVersion == old.toolVersion)
            #expect(new.exitCode == old.exitCode)
            #expect(new.wallTime == old.wallTime)
            #expect(new.peakMemoryBytes == old.peakMemoryBytes)
            #expect(new.containerImage == old.containerImage)
            #expect(new.containerDigest == old.containerDigest)
            #expect(new.dependsOn.count == old.dependsOn.count)
        }
    }

    // MARK: Helpers

    /// The recorded output paths of an envelope, once each and in a stable order.
    private static func outputPaths(of envelope: ProvenanceEnvelope) -> [String] {
        var paths: [String] = []
        func add(_ path: String) {
            if !paths.contains(path) { paths.append(path) }
        }
        envelope.files.filter { $0.role == .output }.forEach { add($0.path) }
        envelope.outputs.forEach { add($0.path) }
        if let output = envelope.output { add(output.path) }
        envelope.steps.flatMap(\.outputs).forEach { add($0.path) }
        return paths
    }

    /// The step facts that name a tool run: tool, version, exit status, graph, wall time, standard
    /// error, the argument count and, unless left out, the peak memory.
    private static func stepIdentity(
        _ steps: [ProvenanceCompatFacts.StepFact],
        includePeakMemory: Bool = true
    ) -> [String] {
        steps.map { step in
            var parts = [
                step.toolName, step.toolVersion, String(describing: step.exitStatus),
                String(describing: step.dependsOn), String(describing: step.wallTimeSeconds),
                String(describing: step.stderr), String(step.argv.count),
            ]
            if includePeakMemory { parts.append(String(describing: step.peakMemoryBytes)) }
            return parts.joined(separator: "|")
        }
    }

    private static func expectArgvKeptExceptAbsolutePaths(_ actual: [String], _ source: [String]) {
        #expect(actual.count == source.count)
        for (original, rewritten) in zip(source, actual) where !original.hasPrefix("/") {
            #expect(rewritten == original, "argv token \(original) changed to \(rewritten)")
        }
    }

    private static func physicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

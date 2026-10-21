// ProvenanceEnvelopeCopySitesTests.swift - What the Workflow sites that copy a recorded envelope keep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3, plan decisions P5 and E13. Twelve sites copied a recorded envelope
// field by field. A site that names every field drops each field it forgets. Three facts were forgotten.
// They are the status, which a copy derived from the exit status cannot tell cancelled from completed,
// a pre-2.4 record's `readSetPlan`, which sat only in the nested run that the encoder never writes, and
// the release version and durable replay command that some sites left out. The sites call
// `ProvenanceEnvelope.with` now, and these tests keep them honest.
//
// Each test sends the three sources of `EnvelopeCopySources` through a site and checks what the copy
// holds. The facts of every copy go to the folder named by `LUNGFISH_COPY_PIN_FACTS_DIR`, when set, so
// the facts of two builds can be compared.
//
// This file covers the Workflow sites that a test reaches without a window or a tool. The App sites are
// in `ProvenanceEnvelopeCopySitesAppTests` and the markdup site is in `MarkdupEnvelopeCopyTests`.

import XCTest
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProvenanceEnvelopeCopySitesTests: XCTestCase {
    typealias CopySources = EnvelopeCopySources

    // MARK: ReferenceBundleImportProvenanceRehydrator, line 107

    func testReferenceBundleRehydratorCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let bundle = try project.folder("Imports/Sample")
            let payload = try ProvenanceCompatScenarios.write(
                ">chr1\nACGT\n", to: bundle.appendingPathComponent("genome/sequence.fa")
            )
            let durable = try ProvenanceCompatScenarios.write(
                ">chr1\nACGT\n", to: project.root.appendingPathComponent("durable/import-source.fasta")
            )
            let base = try CopySources.baseEnvelope(workflowName: "reference import", output: payload, input: durable)
            try ProvenanceWriter(signingProvider: nil).write(base, to: bundle)
            let sidecar = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            try CopySources.rewriteSidecar(at: sidecar, as: kind)
            let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
            let replay = ["lungfish-cli", "import", "fasta", durable.path, "--output", bundle.path]

            try ReferenceBundleImportProvenanceRehydrator.rehydrateSidecar(
                bundleURL: bundle,
                durableSourceURL: durable,
                sourceRelativePath: "import-source.fasta",
                context: ReferenceBundleImportProvenanceContext(
                    workflowName: "reference.import",
                    replayCommand: replay,
                    options: ProvenanceOptions(explicit: ["format": .string("fasta")])
                )
            )

            let copy = try CopySources.capture(
                site: "reference-rehydrator", kind: kind, sidecar: sidecar, projectRoot: project.root
            )
            // The import replaces the command, so the replay command is the import's own.
            CopySources.assertFaithfulCopy(
                site: "ReferenceBundleImportProvenanceRehydrator:107", kind: kind, copy: copy,
                keeping: source, keepsDurableReplayArgv: false
            )
            XCTAssertEqual(copy.durableReplayArgv, replay)
            XCTAssertEqual(copy.steps.count, source.steps.count, "the import keeps the record's steps")
        }
    }

    // MARK: ProvenanceExporter.mergeProvenanceChain, line 268

    func testLineageExportMergeCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let upstreamOutput = try ProvenanceCompatScenarios.write(
                "upstream\n", to: project.root.appendingPathComponent("Upstream/out.txt")
            )
            let downstreamOutput = try ProvenanceCompatScenarios.write(
                "downstream\n", to: project.root.appendingPathComponent("Downstream/out.txt")
            )
            let upstream = try CopySources.baseEnvelope(workflowName: "upstream", output: upstreamOutput)
            let receiver = try CopySources.variant(
                kind,
                of: try CopySources.baseEnvelope(workflowName: "downstream", output: downstreamOutput, input: upstreamOutput)
            )

            let merged = ProvenanceExporter(signingProvider: nil)
                .mergeProvenanceChain([upstream, receiver], fallback: receiver)

            CopySources.assertFaithfulCopy(
                site: "ProvenanceExporter:268", kind: kind, copy: merged,
                keeping: receiver
            )
            CopySources.assertCarried(
                merged, from: receiver, except: CopySources.changedByTheHelper(kind).union(["createdAt", "files", "steps"]),
                site: "ProvenanceExporter:268"
            )
            XCTAssertEqual(merged.id, receiver.id, "the merged record is the exported run")
            XCTAssertEqual(merged.steps.count, 4, "the merge holds the steps of both runs")
        }
    }

    // MARK: FASTQBundleCopyImportWorkflow, lines 303 and 480

    /// The copy is a new run that carries the source bundle's steps. A copy of a cancelled or failed
    /// bundle keeps that status, because the copy step itself succeeded and says nothing about the
    /// reads it copied. The plan belongs to the source's run and is not an option of the copy run.
    func testFASTQBundleCopyImportKeepsTheStatusOfTheBundleItCopied() throws {
        for (kind, failedExit) in CopySources.sourcesWithFailedExit {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let sourceBundle = try project.folder("Imports/source.lungfishfastq")
            let reads = try ProvenanceCompatScenarios.write(
                "@r1\nACGT\n+\n!!!!\n", to: sourceBundle.appendingPathComponent("reads.fastq")
            )
            let base = try CopySources.baseEnvelope(workflowName: "source fastq import", output: reads)
            try ProvenanceWriter(signingProvider: nil).write(base, to: sourceBundle)
            // The copy reads the record of the one output it copies, which a bundle also holds.
            try CopySources.rewriteEveryRecord(under: sourceBundle, as: kind, exitStatus: failedExit)
            let destination = project.root.appendingPathComponent("Imports/copied.lungfishfastq", isDirectory: true)

            _ = try FASTQBundleCopyImportWorkflow().importBundle(
                sourceBundleURL: sourceBundle,
                outputURL: destination,
                context: FASTQBundleCopyImportWorkflow.CommandContext(
                    workflowName: "test fastq bundle import",
                    toolName: "lungfish-cli",
                    argv: ["lungfish", "fastq", "import-bundle", sourceBundle.path]
                )
            )

            let copy = try CopySources.capture(
                site: "fastq-copy-import",
                kind: kind,
                sidecar: destination.appendingPathComponent(ProvenanceWriter.provenanceFilename),
                projectRoot: project.root
            )
            CopySources.assertFaithfulCopy(
                site: "FASTQBundleCopyImportWorkflow:303,480", kind: kind, copy: copy,
                expectsPlan: false
            )
            XCTAssertEqual(copy.workflowName, "test fastq bundle import", "the record is the copy run")
            XCTAssertEqual(copy.steps.first?.toolName, "samtools", "the source bundle's steps come first")
            XCTAssertEqual(copy.steps.count, base.steps.count + 1)
            if let failedExit {
                XCTAssertEqual(
                    copy.exitStatus, failedExit,
                    "a copy of a \(kind.rawValue) bundle keeps the exit status of the run it copies"
                )
            }
        }
    }

    // MARK: InPlaceIngestionProvenance, the in-place ingestion merge

    // Phase 2.11 lane A61 M3, review Group B (Fixes 4 to 6). The app's in-process ingestion reached the merge
    // through `FASTQIngestionService`, and the tests that pinned the merge there went with that writer. The
    // merge stays, because `lungfish-cli fastq ingest` still ships it, so these three tests keep what the merge
    // itself promises. Each makes the three calls that the CLI leaf makes (`FastqIngestSubcommand+Run.swift`),
    // the lookup of the standing record, the merge and the write of the folder's record.

    /// The S4a pin of the merge (plan decisions P5 and E13). The merged record keeps the standing record's
    /// identity, status and release facts, puts the ingestion's steps after the record's own, and leaves a
    /// failed or cancelled record its exit status over the ingestion's 0.
    func testInPlaceIngestionMergeCopiesEachSourceFaithfully() throws {
        for (kind, failedExit) in CopySources.sourcesWithFailedExit {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let bundle = try project.folder("Imports/Sample.lungfishfastq")
            let importedFASTQ = bundle.appendingPathComponent("Sample.fastq")
            let optimizedFASTQ = bundle.appendingPathComponent("Sample.fastq.gz")
            // The record names a file the ingestion does not replace, so the merge rewrites no path.
            let recordedOutput = try ProvenanceCompatScenarios.write(
                "@r\nACGT\n+\n!!!!\n", to: bundle.appendingPathComponent("Other.fastq")
            )
            try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: optimizedFASTQ)
            let base = try CopySources.baseEnvelope(workflowName: "fastq import", output: recordedOutput)
            try ProvenanceWriter(signingProvider: nil).write(base, to: bundle)
            let sidecar = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            try CopySources.rewriteSidecar(at: sidecar, as: kind, exitStatus: failedExit)
            let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
            let ingestion = Self.ingestionEnvelope(
                importedFASTQ: importedFASTQ, optimizedFASTQ: optimizedFASTQ, recordingTheImportedFile: false
            )
            XCTAssertEqual(ingestion.exitStatus, 0, "the ingestion that follows the record exited 0")

            try Self.mergeAsTheCLILeafDoes(
                ingestion: ingestion, into: bundle, replacing: importedFASTQ, with: optimizedFASTQ
            )

            let copy = try CopySources.capture(
                site: "fastq-in-place", kind: kind, sidecar: sidecar, projectRoot: project.root
            )
            CopySources.assertFaithfulCopy(
                site: "InPlaceIngestionProvenance.mergedInPlaceIngestionEnvelope", kind: kind, copy: copy,
                keeping: source
            )
            XCTAssertEqual(copy.workflowName, source.workflowName, "the record stays the imported run")
            XCTAssertEqual(copy.steps.prefix(source.steps.count).map(\.id), source.steps.map(\.id))
            XCTAssertGreaterThan(copy.steps.count, source.steps.count, "the ingestion's steps follow")
            if let failedExit {
                XCTAssertEqual(
                    copy.exitStatus, failedExit,
                    "a \(kind.rawValue) record keeps its exit status over the ingestion's 0"
                )
            }
        }
    }

    /// A completed ingestion finds the record that stands beside the input file when the folder holds no record
    /// of its own. The lookup tries the folder's root record first and then the record of each input
    /// (`InPlaceIngestionProvenance.existingInPlaceIngestionProvenance`).
    func testInPlaceIngestionMergeFindsTheInputsOwnSidecar() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundle = try project.folder("Imports/Sample.lungfishfastq")
        let importedFASTQ = try ProvenanceCompatScenarios.write(
            "@r\nACGT\n+\n!!!!\n", to: bundle.appendingPathComponent("Sample.fastq")
        )
        let optimizedFASTQ = bundle.appendingPathComponent("Sample.fastq.gz")
        let inputSidecar = ProvenanceRecorder.fileSidecarURL(for: importedFASTQ)
        let materializeArgv = ["lungfish-cli", "fastq", "materialize", "--output", importedFASTQ.path]
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Materialize",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(materializeArgv)
        .output(importedFASTQ, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: materializeArgv,
                outputs: [try ProvenanceFileDescriptor.file(url: importedFASTQ, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 40),
            endedAt: Date(timeIntervalSince1970: 41)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, toSidecar: inputSidecar)
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: optimizedFASTQ)
        let ingestion = Self.ingestionEnvelope(
            importedFASTQ: importedFASTQ, optimizedFASTQ: optimizedFASTQ, recordingTheImportedFile: true
        )
        // The clumpify run consumed the imported file, so only its record stands.
        try FileManager.default.removeItem(at: importedFASTQ)

        let found = try Self.mergeAsTheCLILeafDoes(
            ingestion: ingestion, into: bundle, replacing: importedFASTQ, with: optimizedFASTQ
        )

        XCTAssertEqual(found.sourceURL?.path, inputSidecar.path, "the lookup found the input's own record")
        XCTAssertEqual(found.envelope.workflowName, "CLI FASTQ Materialize")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertEqual(
            envelope.steps.map(\.toolName), ["lungfish-cli", "clumpify.sh"],
            "the import step comes first and the ingestion's steps follow"
        )
        let importStep = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(importStep.outputs.map(\.path), [optimizedFASTQ.path])
        XCTAssertEqual(importStep.outputs.first?.originPath, importedFASTQ.path)
        XCTAssertEqual(importStep.durableReplayArgv?.last, optimizedFASTQ.path)
        XCTAssertFalse(envelope.files.contains { $0.role == .output && $0.path == importedFASTQ.path })

        // A folder that holds a root record and the input's record is answered by the root record.
        let both = try project.folder("Imports/Both.lungfishfastq")
        let bothInput = try ProvenanceCompatScenarios.write(
            "@r\nACGT\n+\n!!!!\n", to: both.appendingPathComponent("Both.fastq")
        )
        try ProvenanceWriter(signingProvider: nil).write(
            try CopySources.baseEnvelope(workflowName: "root record", output: bothInput), to: both
        )
        try ProvenanceWriter(signingProvider: nil).write(
            try CopySources.baseEnvelope(workflowName: "input record", output: bothInput),
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: bothInput)
        )
        let preferred = try XCTUnwrap(
            InPlaceIngestionProvenance.existingInPlaceIngestionProvenance(outputDirectory: both, inputFiles: [bothInput])
        )
        XCTAssertEqual(
            preferred.sourceURL?.path, both.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path,
            "the root record comes before the record of an input"
        )
        XCTAssertEqual(preferred.envelope.workflowName, "root record")
    }

    /// The merge points the standing record's output options and replay arguments at the file the ingestion
    /// wrote. The record is the imported copy of a download, rebuilt by the rehydrator as the import makes it.
    func testInPlaceIngestionMergeRewritesOutputOptionsAndReplayArgumentsToTheGzipFile() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundle = try project.folder("Imports/Sample.lungfishfastq")
        let sourceCLIOutput = try ProvenanceCompatScenarios.write(
            "@r\nACGT\n+\n!!!!\n", to: project.root.appendingPathComponent("cli-output.fastq")
        )
        let importedFASTQ = try ProvenanceCompatScenarios.write(
            "@r\nACGT\n+\n!!!!\n", to: bundle.appendingPathComponent("Sample.fastq")
        )
        let optimizedFASTQ = bundle.appendingPathComponent("Sample.fastq.gz")
        let fetchArgv = ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceCLIOutput.path]
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Download",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(fetchArgv)
        .options(
            explicit: ["downloadOutput": .file(sourceCLIOutput)],
            defaults: ["defaultOutput": .string(sourceCLIOutput.path)],
            resolved: ["resolvedOutput": .file(sourceCLIOutput)]
        )
        .output(sourceCLIOutput, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: fetchArgv,
                durableReplayArgv: fetchArgv,
                outputs: [try ProvenanceFileDescriptor.file(url: sourceCLIOutput, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 50),
            endedAt: Date(timeIntervalSince1970: 51)
        )
        try ProvenanceWriter(signingProvider: nil).write(
            cliEnvelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: sourceCLIOutput)
        )
        try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: sourceCLIOutput, to: importedFASTQ)
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: optimizedFASTQ)
        let ingestion = Self.ingestionEnvelope(
            importedFASTQ: importedFASTQ, optimizedFASTQ: optimizedFASTQ, recordingTheImportedFile: true
        )
        try FileManager.default.removeItem(at: importedFASTQ)

        try Self.mergeAsTheCLILeafDoes(
            ingestion: ingestion, into: bundle, replacing: importedFASTQ, with: optimizedFASTQ
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        let importStep = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(importStep.durableReplayArgv?.last, optimizedFASTQ.path)
        XCTAssertEqual(envelope.durableReplayArgv?.last, optimizedFASTQ.path)
        XCTAssertEqual(envelope.options.explicit["downloadOutput"]?.fileValue?.path, optimizedFASTQ.path)
        XCTAssertEqual(envelope.options.defaults["defaultOutput"]?.stringValue, optimizedFASTQ.path)
        XCTAssertEqual(envelope.options.resolvedDefaults["resolvedOutput"]?.fileValue?.path, optimizedFASTQ.path)
    }

    // MARK: ReferenceBundleAnnotationImportService, lines 591 and 695

    /// The merged record is the annotation import run, which the builder completed, with the steps of the
    /// source file's record in front. The source's status describes the run that made the file, so it is
    /// not the import's status. The source's steps and the import's own facts have to survive.
    @MainActor
    func testAnnotationImportMergeKeepsTheImportRunAndTheSourceSteps() async throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let bundle = try Self.makeReferenceBundle(in: project)
            let bed = try ProvenanceCompatScenarios.write(
                "chr1\t1\t12\tgeneA\t0\t+\n", to: project.root.appendingPathComponent("Sources/features.bed")
            )
            let sourceFolder = bed.deletingLastPathComponent()
            let base = try CopySources.baseEnvelope(workflowName: "annotation source", output: bed)
            try ProvenanceWriter(signingProvider: nil).write(base, to: sourceFolder)
            try CopySources.rewriteSidecar(
                at: sourceFolder.appendingPathComponent(ProvenanceWriter.provenanceFilename), as: kind
            )

            _ = try await ReferenceBundleAnnotationImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).attachAnnotationTrack(
                sourceURL: bed, bundleURL: bundle
            )

            let copy = try CopySources.capture(
                site: "annotation-import",
                kind: kind,
                sidecar: bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename),
                projectRoot: project.root
            )
            CopySources.assertFaithfulCopy(
                site: "ReferenceBundleAnnotationImportService:591", kind: kind, copy: copy,
                expectedStatus: .completed, expectsPlan: false
            )
            XCTAssertEqual(copy.workflowName, "lungfish annotation track import")
            XCTAssertEqual(copy.steps.map(\.toolName).first, "samtools", "the source file's steps come first")
            XCTAssertEqual(copy.steps.count, base.steps.count + 1)
        }
    }

    func testAnnotationImportDescriptorReplacementCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let output = try ProvenanceCompatScenarios.write(
                "features\n", to: project.root.appendingPathComponent("Analysis/features.db")
            )
            let receiver = try CopySources.variant(
                kind, of: try CopySources.baseEnvelope(workflowName: "annotation record", output: output)
            )
            let replacement = try ProvenanceFileDescriptor.file(url: output, format: .sqlite, role: .output)

            let copy = receiver.replacingOutputDescriptor(replacement, matchingPath: output.path)

            CopySources.assertFaithfulCopy(
                site: "ReferenceBundleAnnotationImportService:695", kind: kind, copy: copy,
                keeping: receiver
            )
            CopySources.assertCarried(
                copy, from: receiver, except: CopySources.changedByTheHelper(kind).union(["files", "output", "outputs", "steps"]),
                site: "ReferenceBundleAnnotationImportService:695"
            )
            XCTAssertEqual(copy.output, replacement, "the replacement is the one change")
        }
    }

    // MARK: MappingViewerBundlePublicationService, line 1393

    /// The viewer bundle's import records are remapped from the candidate bundle's paths to the final
    /// bundle's paths when the bundle is published. A pre-2.4 source's nested run also names a file in the
    /// candidate bundle, and the helper merges the nested run's parameters after the change, so the site
    /// has to remap them too or the published record names the deleted candidate (S4a review, fix 1).
    func testMappingPublicationRemapCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let finalBundle = project.root.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
            let candidateBundle = project.root.appendingPathComponent(".Viewer.candidate", isDirectory: true)
            let candidateAlignments = candidateBundle.appendingPathComponent("alignments", isDirectory: true)
            try FileManager.default.createDirectory(at: candidateAlignments, withIntermediateDirectories: true)
            let candidateBAM = candidateAlignments.appendingPathComponent("viewer.bam")
            try Data("viewer-bam".utf8).write(to: candidateBAM)
            let candidateDB = candidateAlignments.appendingPathComponent("viewer.stats.db")
            do {
                let database = try AlignmentMetadataDatabase.create(at: candidateDB)
                database.setFileInfo("source_path", value: candidateBAM.path)
            }
            let base = try CopySources.baseEnvelope(workflowName: "BAM import", output: candidateBAM)
            let sidecar = candidateAlignments.appendingPathComponent("viewer.import.lungfish-provenance.json")
            try ProvenanceWriter(signingProvider: nil).write(base, toSidecar: sidecar)
            try CopySources.rewriteSidecar(
                at: sidecar, as: kind, extraNestedParameters: ["copyPinNestedFile": .file(candidateBAM)]
            )
            let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))

            var copy: ProvenanceEnvelope?
            try MappingViewerBundlePublicationService.publishCandidate(
                candidateBundleURL: candidateBundle,
                finalBundleURL: finalBundle
            ) { publishedBundle in
                copy = try CopySources.capture(
                    site: "mapping-remap",
                    kind: kind,
                    sidecar: publishedBundle.appendingPathComponent("alignments/viewer.import.lungfish-provenance.json"),
                    projectRoot: project.root
                )
            }

            let published = try XCTUnwrap(copy)
            CopySources.assertFaithfulCopy(
                site: "MappingViewerBundlePublicationService:1393", kind: kind, copy: published,
                keeping: source
            )
            XCTAssertEqual(
                published.output?.path,
                finalBundle.appendingPathComponent("alignments/viewer.bam").path,
                "the remap moved the paths, which is its purpose"
            )
            let nestedFile = published.options.resolvedDefaults["copyPinNestedFile"]
            if kind == .preTwoFourNestedPlan {
                XCTAssertEqual(
                    nestedFile?.fileValue?.path,
                    finalBundle.appendingPathComponent("alignments/viewer.bam").path,
                    "the nested run's file value names the final bundle, never the candidate"
                )
            } else {
                XCTAssertNil(nestedFile, "only the pre-2.4 source holds a nested run")
            }
        }
    }

    // MARK: Helpers

    /// The envelope of an in-place ingestion as the deleted app writer built it, a completed run named
    /// `FASTQ Ingestion` with the one clumpify step that reads the imported file and writes the gzip file.
    /// The step records the imported file's digest only when `recordingTheImportedFile` is set, and then the
    /// file has to exist. The gzip file always has to exist.
    private static func ingestionEnvelope(
        importedFASTQ: URL,
        optimizedFASTQ: URL,
        recordingTheImportedFile: Bool
    ) -> ProvenanceEnvelope {
        let optimizationStep = StepExecution(
            toolName: "clumpify.sh",
            toolVersion: "test-bbtools",
            command: ["clumpify.sh", "in=\(importedFASTQ.path)", "out=\(optimizedFASTQ.path)"],
            inputs: recordingTheImportedFile
                ? [ProvenanceRecorder.fileRecord(url: importedFASTQ, format: .fastq, role: .input)]
                : [],
            outputs: [ProvenanceRecorder.fileRecord(url: optimizedFASTQ, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 1.25
        )
        return WorkflowRun(name: "FASTQ Ingestion", status: .completed, steps: [optimizationStep], parameters: [:])
            .canonicalEnvelope()
    }

    /// The three calls of `lungfish-cli fastq ingest` (`FastqIngestSubcommand+Run.swift`). It looks for the
    /// record that stands in `bundle` for `importedFASTQ`, merges `ingestion` into it with the gzip file as the
    /// file that replaces the imported one, and writes the result as the folder's record. Returns what the
    /// lookup found.
    @discardableResult
    private static func mergeAsTheCLILeafDoes(
        ingestion: ProvenanceEnvelope,
        into bundle: URL,
        replacing importedFASTQ: URL,
        with optimizedFASTQ: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (envelope: ProvenanceEnvelope, sourceURL: URL?) {
        let found = try XCTUnwrap(
            InPlaceIngestionProvenance.existingInPlaceIngestionProvenance(
                outputDirectory: bundle, inputFiles: [importedFASTQ]
            ),
            "no record stands for the ingestion to join",
            file: file,
            line: line
        )
        let merged = try InPlaceIngestionProvenance.mergedInPlaceIngestionEnvelope(
            existingEnvelope: found.envelope,
            sourceProvenanceURL: found.sourceURL,
            ingestionEnvelope: ingestion,
            replacedInputFiles: [importedFASTQ],
            finalFASTQURL: optimizedFASTQ,
            finalFASTQDescriptor: ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileRecord(url: optimizedFASTQ, format: .fastq, role: .output)
            )
        )
        try ProvenanceWriter(signingProvider: nil).write(merged, to: bundle)
        return found
    }

    /// A reference bundle with a genome and no tracks, as the annotation import tests build one.
    private static func makeReferenceBundle(in project: ProvenanceCompatScenarios.Project) throws -> URL {
        let bundle = try project.folder("Bundles/Pin.lungfishref")
        try ProvenanceCompatScenarios.write(">chr1\nACGTACGTACGTACGT\n", to: bundle.appendingPathComponent("genome/sequence.fa"))
        try ProvenanceCompatScenarios.write("chr1\t16\t6\t7\n", to: bundle.appendingPathComponent("genome/sequence.fa.fai"))
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("annotations", isDirectory: true), withIntermediateDirectories: true
        )
        try BundleManifest(
            name: "Pin",
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: "Pin"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 16,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 16, offset: 6, lineBases: 16, lineWidth: 17)]
            )
        ).save(to: bundle)
        return bundle
    }
}

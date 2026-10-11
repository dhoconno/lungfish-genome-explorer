// ProvenanceEnvelopeCopySitesTests.swift - What the Workflow sites that copy a recorded envelope keep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3, plan decisions P5 and E13. Twelve sites copy a recorded envelope
// field by field. A site that names every field drops each field it forgets, and three facts were
// forgotten: the status, which a copy derived from the exit status cannot tell cancelled from
// completed, and a pre-2.4 record's `readSetPlan`, which sat only in the nested run that the encoder
// never writes, and the release version and durable replay command that some sites left out.
//
// Each test sends the three sources of `EnvelopeCopySources` through a site and checks what the copy
// holds. `EnvelopeCopySources.knownDefects` lists the pairs that fail at the base commit. They are expected failures, so the
// commit that moves a site onto `ProvenanceEnvelope.with` removes its pairs and the pin flips to a plain
// expectation. The facts of every copy go to the folder named by `LUNGFISH_COPY_PIN_FACTS_DIR`, when set,
// so the facts at the base and after the change can be compared.
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
            XCTAssertEqual(merged.id, receiver.id, "the merged record is the exported run")
            XCTAssertEqual(merged.steps.count, 4, "the merge holds the steps of both runs")
        }
    }

    // MARK: FASTQBundleCopyImportWorkflow, lines 303 and 480

    /// The copy is a new run that carries the source bundle's steps. A copy of a cancelled or failed
    /// bundle keeps that status, because the copy step itself succeeded and says nothing about the
    /// reads it copied. The plan belongs to the source's run and is not an option of the copy run.
    func testFASTQBundleCopyImportKeepsTheStatusOfTheBundleItCopied() throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let sourceBundle = try project.folder("Imports/source.lungfishfastq")
            let reads = try ProvenanceCompatScenarios.write(
                "@r1\nACGT\n+\n!!!!\n", to: sourceBundle.appendingPathComponent("reads.fastq")
            )
            let base = try CopySources.baseEnvelope(workflowName: "source fastq import", output: reads)
            try ProvenanceWriter(signingProvider: nil).write(base, to: sourceBundle)
            try CopySources.rewriteSidecar(
                at: sourceBundle.appendingPathComponent(ProvenanceWriter.provenanceFilename), as: kind
            )
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
        }
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

            _ = try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
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
            XCTAssertEqual(copy.output, replacement, "the replacement is the one change")
        }
    }

    // MARK: MappingViewerBundlePublicationService, line 1393

    /// The viewer bundle's import records are remapped from the candidate bundle's paths to the final
    /// bundle's paths when the bundle is published.
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
            try CopySources.rewriteSidecar(at: sidecar, as: kind)
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
        }
    }

    // MARK: Helpers

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

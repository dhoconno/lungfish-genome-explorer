// CrossProjectItemCopierBasePinTests.swift - What a cross-project copy does before project copy-item
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 12.18 M1 pins (QA 1), reduced by Phase 2.13 (DEL-REST). They passed at the base, before the copier
// moved into Workflow and before `lungfish-cli project copy-item` existed, and they hold the facts the move and
// the leaf keep: where each kind lands, how a name is uniqued, the containment refusal on resolved paths, and
// the read bundle's copy record with the command of its identity. The pins of the app's own records
// (`fastq import-ont` with `caller` `app-cross-project-copy`, and the `Lungfish.app import-native` receipt) went
// with the identity that wrote them. The kinds that `CrossProjectItemCopierTests` already copies are not
// repeated here.

import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class CrossProjectItemCopierBasePinTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!
    private let fm = FileManager.default
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CrossProjectItemCopierBasePinTests-\(UUID().uuidString)", isDirectory: true)
        sourceProject = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        try fm.createDirectory(at: sourceProject, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetProject, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - Fixtures

    private func makeBundle(_ relative: String, files: [String: String] = ["manifest.json": "{\"bundleKind\":\"fixture\"}"]) throws -> URL {
        let bundle = sourceProject.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return bundle
    }

    /// A read bundle with readable provenance, so the copier sends it through
    /// `FASTQBundleCopyImportWorkflow` rather than the native copy.
    private func makeReadBundleWithProvenance(_ relative: String) throws -> URL {
        let bundle = try makeBundle(relative, files: ["reads.fastq": "@r1\nACGT\n+\nIIII\n"])
        let reads = bundle.appendingPathComponent("reads.fastq")
        let output = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output)
        let argv = ["source-fastq-tool", reads.path]
        let step = ProvenanceStep(toolName: "source-fastq-tool", toolVersion: "1.0", argv: argv, outputs: [output], exitStatus: 0, wallTimeSeconds: 0.1)
        let envelope = ProvenanceEnvelope(
            workflowName: "source FASTQ bundle", workflowVersion: "1.0", toolName: "source-fastq-tool", toolVersion: "1.0",
            argv: argv, files: [output], output: output, outputs: [output], steps: [step], wallTimeSeconds: 0.1, exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundle)
        return bundle
    }

    private func relativePath(of url: URL, in project: URL) -> String {
        ProjectItemLinkRewriter.relative(
            path: url.standardizedFileURL.path,
            toAny: ProjectItemLinkRewriter.pathVariants(of: project)
        ) ?? url.path
    }

    // MARK: - Kinds and destinations

    func testKindsTheEveryKindTestSkipsLandWhereTheyLandToday() throws {
        let cases: [(source: URL, kind: CrossProjectItemCopier.ItemKind, destination: String)] = [
            (try makeBundle("Analyses/run.lungfishprimeranalysis"), .primerAnalysisBundle, "Analyses/run.lungfishprimeranalysis"),
            (try makeBundle("Analyses/run.lungfish12s"), .twelveSResultBundle, "Analyses/run.lungfish12s"),
            (try makeBundle("Databases/db.lungfish12sref"), .otherNativeBundle, "Databases/db.lungfish12sref"),
            (try makeBundle("Classifications/plain.lungfishtax"), .otherNativeBundle, "Classifications/plain.lungfishtax"),
            (try makeBundle("root-level.lungfishref"), .referenceBundle, "root-level.lungfishref"),
        ]
        for item in cases {
            XCTAssertEqual(CrossProjectItemCopier.kind(of: item.source), item.kind, item.source.lastPathComponent)
            let outcome = try CrossProjectItemCopier.copy(itemAt: item.source, intoProject: targetProject, now: fixedNow, identity: .neutral)
            XCTAssertEqual(outcome.kind, item.kind)
            XCTAssertEqual(relativePath(of: outcome.destinationURL, in: targetProject), item.destination)
            XCTAssertTrue(fm.fileExists(atPath: outcome.destinationURL.appendingPathComponent("manifest.json").path))
            XCTAssertNotNil(ProjectItemCopyRecord.load(from: outcome.destinationURL), item.destination)
        }
    }

    func testFinderDropFolderAndAnalysesRuleForEveryKind() {
        let expected: [(CrossProjectItemCopier.ItemKind, String, Bool)] = [
            (.fastqBundle, "Imports", false),
            (.referenceBundle, "Reference Sequences", false),
            (.multipleSequenceAlignmentBundle, "Analyses/Multiple Sequence Alignments", false),
            (.phylogeneticTreeBundle, "Phylogenetic Trees", false),
            (.primerSchemeBundle, "Primer Schemes", false),
            (.primerAnalysisBundle, "Analyses", false),
            (.genotypeResultBundle, "Analyses", true),
            (.twelveSResultBundle, "Analyses", false),
            (.czIdResult, "Classifications", false),
            (.workflowBundle, "Workflows", false),
            (.otherNativeBundle, "", false),
            (.analysisResult(tool: "kraken2", isBatch: false), "Analyses", true),
        ]
        for (kind, folder, underAnalyses) in expected {
            XCTAssertEqual(kind.defaultRelativeFolder, folder, kind.displayName)
            XCTAssertEqual(kind.mustLiveUnderAnalyses, underAnalyses, kind.displayName)
        }
    }

    func testUniqueNameSkipsTakenCountersAndKeepsInnerDots() throws {
        let folder = try XCTUnwrap(targetProject?.appendingPathComponent("Reference Sequences", isDirectory: true))
        try fm.createDirectory(at: folder.appendingPathComponent("sample.v2.lungfishref"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("sample.v2-2.lungfishref"), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: "/elsewhere/sample.v2.lungfishref", isDirectory: true)

        let unique = CrossProjectItemCopier.uniqueDestinationURL(for: source, in: folder)

        XCTAssertEqual(unique.lastPathComponent, "sample.v2-3.lungfishref")
        XCTAssertEqual(unique.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
    }

    // MARK: - Containment

    func testDestinationInsideTheSourceIsRefusedAndWritesNothing() throws {
        let ref = try makeBundle("Reference Sequences/NC_045512.lungfishref")
        let before = try fm.contentsOfDirectory(atPath: ref.path).sorted()

        XCTAssertThrowsError(try CrossProjectItemCopier.copy(itemAt: ref, intoProject: sourceProject, requestedFolder: ref, identity: .neutral)) { error in
            guard case CrossProjectItemCopier.CopyError.destinationInsideSource = error else {
                return XCTFail("expected destinationInsideSource, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "NC_045512.lungfishref cannot be copied into itself.")
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: ref.path).sorted(), before)
    }

    // MARK: - Records

    func testReadBundleCopyNamesTheCommandOfItsIdentityAndKeepsItsCopyRecord() throws {
        let bundle = try makeReadBundleWithProvenance("Imports/HG002.lungfishfastq")
        let source = bundle.standardizedFileURL

        let outcome = try CrossProjectItemCopier.copy(itemAt: bundle, intoProject: targetProject, now: fixedNow, identity: .neutral)

        let destination = outcome.destinationURL
        XCTAssertEqual(outcome.kind, .fastqBundle)
        XCTAssertEqual(relativePath(of: destination, in: targetProject), "Imports/HG002.lungfishfastq")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: destination.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        ))
        // The envelope names the command of the identity the copier was given, and the read bundle's copy adds
        // its source kind and copy mode to the options of that identity.
        let argv = [CLICommandIdentity.executableName, "project", "copy-item"]
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.durableReplayArgv, argv)
        XCTAssertEqual(envelope.workflowName, "lungfish project copy-item")
        XCTAssertEqual(envelope.toolName, "lungfish project copy-item")
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("cli"))
        XCTAssertEqual(envelope.options.resolvedDefaults["sourceKind"], .string("existing-fastq-bundle"))
        XCTAssertEqual(envelope.options.resolvedDefaults["copyMode"], .string("atomic-bundle-copy"))
        XCTAssertEqual(envelope.steps.map(\.toolName), ["source-fastq-tool", "lungfish project copy-item"])
        XCTAssertEqual(envelope.steps.last?.argv, argv)
        XCTAssertEqual(envelope.steps.last?.durableReplayArgv, argv)

        let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: destination))
        // Schema 2 since lane 12.18 M2 adds the source item's relative path and digests (BIO ruling, answer 4).
        XCTAssertEqual(record.schemaVersion, 2)
        XCTAssertEqual(record.sourceItemRelativePath, "Imports/HG002.lungfishfastq")
        XCTAssertEqual(record.sourceItemFiles?.map(\.path), [
            ".lungfish-provenance.json",
            "provenance/bundle.lungfish-provenance.json",
            "provenance/reads.fastq.lungfish-provenance.json",
            "reads.fastq",
        ])
        XCTAssertEqual(record.copiedAt, fixedNow)
        XCTAssertEqual(record.sourceItemPath, source.path)
        XCTAssertEqual(record.sourceProjectPath, sourceProject.standardizedFileURL.path)
        XCTAssertEqual(record.targetProjectPath, targetProject.standardizedFileURL.path)
        XCTAssertEqual(record.links, [])
    }
}

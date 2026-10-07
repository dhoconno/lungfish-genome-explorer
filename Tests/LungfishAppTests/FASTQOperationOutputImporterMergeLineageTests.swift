// FASTQOperationOutputImporterMergeLineageTests.swift - Every generation of dialog outputs from a merge bundle records its counts and pairing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 1.5 lane F8, re-review finding F6-S1. An output that the FASTQ
// operations dialog imports from a merge bundle inherits the merge in its
// lineage, and the layout scan reads that merge as proof of single reads, so
// only the counts the import records show what the file holds. The import
// recorded a count of only pairs for such a child but labelled it single-end,
// and the child's own count cleared the merge hint the import read when it
// decided whether to count the next output. A grandchild therefore had no
// counts. One that held only pairs planned as mixed, so EsViritu, TaxTriage
// and Viral Recon ran its mates single-end, and a mixed one lost its counts.
// These tests import the chain merge, then a filter that keeps only pairs,
// then a second filter, on the merge derivative of `ReadSetFixtures`.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQOperationOutputImporterMergeLineageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input
        // resolvers hand the CLI, so the paths the tests compare agree.
        let made = try TestTempDirectory.make(prefix: "fastq-importer-merge-lineage")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// What the stand-in filter writes for the child, two unmerged pairs and
    /// none of the merge bundle's merged reads.
    private static let childPairs: [(id: String, sequence: String)] = [
        (id: "u1/1", sequence: "ACGTACGTAC"), (id: "u1/2", sequence: "ACGTACGTAC"),
        (id: "u2/1", sequence: "ACGTACGTAC"), (id: "u2/2", sequence: "ACGTACGTAC"),
    ]

    /// Imports `records` as the dialog imports the output of Filter by Read
    /// Length on `source`, and returns the new bundle and its one file. Static,
    /// so a main-actor test can call it without sending the test case anywhere.
    private static func importFilterOutput(
        _ records: [(id: String, sequence: String)],
        named name: String,
        of source: URL,
        fixtures: ReadSetFixtures,
        root: URL,
        request: FASTQDerivativeRequest = .lengthFilter(min: 5, max: 40)
    ) async throws -> (bundle: URL, payload: URL) {
        let staging = root.appendingPathComponent("work-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(name).fastq")
        try FASTQOperationTestHelper.writeFASTQ(records: records, to: staged)
        let input = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: source))
        try DialogRowStagedProvenance.write(
            argv: ["fixture-tool", input.path, "-o", staged.path],
            inputURL: input,
            outputURL: staged,
            in: staging
        )
        let derived = fixtures.projectURL.appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let writer = AppFASTQOutputBundleWriter(
            ingestor: DialogRowCopyingIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
        let bundle = try await writer.importFASTQOutput(
            sourceURL: staged,
            bundleURL: derived.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: request,
                inputURLs: [source],
                outputMode: .perInput
            ),
            sourceInputURL: source
        )
        return (bundle, try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle)))
    }

    /// Relabels `generation` single-end in its sidecar and its manifest, the
    /// label a child of a merge bundle carried beside its count of only pairs
    /// before this lane.
    private static func labelSingleEnd(_ generation: (bundle: URL, payload: URL)) throws {
        var sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: generation.payload))
        sidecar.ingestion?.pairingMode = .singleEnd
        FASTQMetadataStore.save(sidecar, for: generation.payload)
        let manifestURL = generation.bundle.appendingPathComponent(FASTQBundle.derivedManifestFilename)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["pairingMode"] = IngestionMetadata.PairingMode.singleEnd.rawValue
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: generation.bundle)?.pairingMode, .singleEnd)
    }

    /// A grandchild that holds only pairs records them and the interleaved
    /// pairing, as the child does, and EsViritu, TaxTriage and Viral Recon run
    /// its mates as pairs. Before the fix the child was labelled single-end,
    /// which the Inspector's Pairing row showed, the grandchild got no count,
    /// and every one of these tools ran its mates single-end because its
    /// lineage records the merge.
    @MainActor
    func testAPairsOnlyGrandchildOfAMergeBundleRunsAsPairsInEsVirituTaxTriageAndViralRecon() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let child = try await Self.importFilterOutput(
            Self.childPairs, named: "merge-pairs", of: fixtures.mergeDerivative, fixtures: fixtures, root: root
        )
        let grandchild = try await Self.importFilterOutput(
            Array(Self.childPairs.prefix(2)), named: "merge-pairs-filtered", of: child.bundle, fixtures: fixtures, root: root
        )

        // Each generation inherits the merge, records its pairs with no single
        // role, and is labelled interleaved in its sidecar and its manifest.
        for (generation, pairs) in [(child, 2), (grandchild, 1)] {
            let name = generation.bundle.lastPathComponent
            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: generation.bundle), name)
            XCTAssertTrue(manifest.lineage.contains { $0.kind == .pairedEndMerge }, name)
            XCTAssertEqual(manifest.pairingMode, .interleaved, name)
            let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: generation.payload), name)
            XCTAssertEqual(sidecar.ingestion?.pairingMode, .interleaved, name)
            let roles = sidecar.readClassification?.files
            XCTAssertEqual(roles?.map(\.role), [.pairedR1, .pairedR2], name)
            XCTAssertEqual(roles?.map(\.readCount), [pairs, pairs], name)
            XCTAssertEqual(roles.map { Set($0.map(\.filename)) }, [generation.payload.lastPathComponent], name)
        }

        // EsViritu. The wizard, the app's launch and the pipeline's guard all
        // run the grandchild as one interleaved file.
        let sample = try XCTUnwrap(MetagenomicsSampleGrouper.group([grandchild.bundle]).first)
        let wizard = await EsVirituSampleReadPlan.planned(for: sample)
        XCTAssertEqual(wizard.format, .interleaved, wizard.label)
        var config = EsVirituConfig(
            inputFiles: sample.inputFiles,
            isPairedEnd: sample.isPairedEnd,
            sampleName: "sample",
            outputDirectory: root.appendingPathComponent("esviritu-out", isDirectory: true),
            databasePath: root.appendingPathComponent("db", isDirectory: true),
            readFormat: wizard.format,
            inputLayout: wizard.layout
        )
        config.plansReadSet = wizard.plansReadSet
        let launched = try await AppDelegate().resolvedEsVirituConfig(
            config,
            tempDirectory: root.appendingPathComponent("esviritu-inputs", isDirectory: true)
        ).verifyingInterleavedInput()
        XCTAssertEqual(launched.readFormat, .interleaved)
        XCTAssertEqual(launched.inputFiles.map(\.lastPathComponent), [grandchild.payload.lastPathComponent])

        // TaxTriage reads the pairs as pairs, with no single-read reason, and
        // the pipeline splits the interleaved file into R1 and R2.
        let taxTriage = try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: "sample", fastq1: grandchild.bundle),
            materializationDirectory: root.appendingPathComponent("taxtriage-inputs", isDirectory: true),
            materializer: fixtures.materializer
        )
        XCTAssertEqual(taxTriage.fastq1.lastPathComponent, grandchild.payload.lastPathComponent)
        XCTAssertEqual(taxTriage.readLayout, .strictlyInterleaved)
        XCTAssertNil(taxTriage.readSetPlan?.singleReadReason)
        XCTAssertTrue(TaxTriagePipeline.shouldSplitInterleaved(taxTriage))

        // Viral Recon splits the pair into an R1 and an R2 file.
        let viralRecon = try XCTUnwrap(
            ViralReconInputResolver.makeSamples(from: ViralReconInputResolver.resolveInputs(from: [grandchild.bundle])).first
        )
        XCTAssertEqual(ViralReconReadPairing.decision(for: viralRecon).handling, .splitToR1R2)
        let prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
            [viralRecon],
            splitRoot: root.appendingPathComponent("viralrecon-split", isDirectory: true)
        )
        XCTAssertEqual(prepared.decisions.first?.pairCount, 1)
        let mates = try XCTUnwrap(prepared.samples.first).fastqURLs
        XCTAssertEqual(try mates.map { try FASTQReadLayoutClassifier.readHeaders(from: $0).headers }, [["u1/1"], ["u1/2"]])
    }

    /// A grandchild that keeps one pair and one mate of the other holds a pair
    /// and a read without its mate. It records both counts, the lone mate as
    /// an orphan, keeps the single-end label, and plans as mixed from those
    /// counts in EsViritu, TaxTriage and Viral Recon. Before the fix it
    /// recorded no count, so its plan knew neither. A child labelled
    /// single-end beside its count of only pairs, as children were before this
    /// lane, passes the counting on too, because the import decides from the
    /// merge in the source's lineage.
    func testAMixedGrandchildOfAMergeBundleKeepsItsCountsAndStaysMixed() async throws {
        for childLabelledSingleEnd in [false, true] {
            let label = childLabelledSingleEnd ? "child relabelled single-end" : "child as imported"
            let caseRoot = root.appendingPathComponent(childLabelledSingleEnd ? "single-end" : "interleaved", isDirectory: true)
            let fixtures = try ReadSetFixtures(in: caseRoot.appendingPathComponent("fixtures", isDirectory: true))
            let child = try await Self.importFilterOutput(
                Self.childPairs, named: "merge-pairs", of: fixtures.mergeDerivative, fixtures: fixtures, root: caseRoot
            )
            if childLabelledSingleEnd { try Self.labelSingleEnd(child) }
            let grandchild = try await Self.importFilterOutput(
                Array(Self.childPairs.prefix(3)), named: "merge-mixed", of: child.bundle, fixtures: fixtures, root: caseRoot
            )

            let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: grandchild.payload), label)
            let roles = sidecar.readClassification?.files
            XCTAssertEqual(roles?.map(\.role), [.pairedR1, .pairedR2, .unpaired], label)
            XCTAssertEqual(roles?.map(\.readCount), [1, 1, 1], label)
            XCTAssertEqual(roles.map { Set($0.map(\.filename)) }, [grandchild.payload.lastPathComponent], label)
            XCTAssertEqual(sidecar.ingestion?.pairingMode, .singleEnd, label)
            XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: grandchild.bundle)?.pairingMode, .singleEnd, label)

            for consumerID in [EsVirituConfig.readPairingConsumerID, TaxTriageReadSetPlanner.consumerID] {
                let readSet = try await SamplesheetReadSetPlanner.plan(
                    input: grandchild.bundle,
                    consumerID: consumerID,
                    materializationDirectory: caseRoot.appendingPathComponent("plan-\(consumerID)", isDirectory: true),
                    materializer: fixtures.materializer
                )
                guard case .singleEnd(let file) = readSet.reads else {
                    XCTFail("\(label), \(consumerID): \(readSet.reads)")
                    continue
                }
                XCTAssertEqual(file.lastPathComponent, grandchild.payload.lastPathComponent, "\(label), \(consumerID)")
                XCTAssertNotNil(readSet.plan.singleReadReason, "\(label), \(consumerID)")
                XCTAssertTrue(readSet.plan.sampleHoldsPairsAndSingleReads, "\(label), \(consumerID)")
                XCTAssertEqual(readSet.plan.composition.pairedFragments, 1, "\(label), \(consumerID)")
                XCTAssertEqual(readSet.plan.composition.orphanReads, 1, "\(label), \(consumerID)")
            }
            let viralRecon = try XCTUnwrap(
                ViralReconInputResolver.makeSamples(from: ViralReconInputResolver.resolveInputs(from: [grandchild.bundle])).first,
                label
            )
            let decision = ViralReconReadPairing.decision(for: viralRecon)
            XCTAssertEqual(decision.layout, .mixedMergedAndPairs, label)
            XCTAssertEqual(decision.handling, .asSingle, label)
        }
    }

    /// The outputs of a single-end source and of an interleaved source, neither
    /// with a merge in its lineage, record what they recorded before this
    /// lane. A single-end output is not counted and stays single-end, and an
    /// output of only pairs records no roles and stays interleaved.
    func testOutputsOfSourcesWithoutAMergeInTheirLineageRecordNoCounts() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let single = try await Self.importFilterOutput(
            [(id: "s1", sequence: "ACGTACGTAC"), (id: "s2", sequence: "ACGTACGTAC")],
            named: "single-filtered", of: fixtures.singleRoot, fixtures: fixtures, root: root
        )
        let pairs = try await Self.importFilterOutput(
            [(id: "i1/1", sequence: "ACGTACGTAC"), (id: "i1/2", sequence: "ACGTACGTAC")],
            named: "interleaved-filtered", of: fixtures.interleavedRoot, fixtures: fixtures, root: root
        )
        for (output, pairing) in [(single, IngestionMetadata.PairingMode.singleEnd), (pairs, .interleaved)] {
            let name = output.bundle.lastPathComponent
            let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: output.payload), name)
            XCTAssertNil(sidecar.readClassification, name)
            XCTAssertEqual(sidecar.ingestion?.pairingMode, pairing, name)
            XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: output.bundle)?.pairingMode, pairing, name)
        }
    }

    // MARK: - Phase 2.1 lane L3

    /// The plan the read-set resolver makes for `bundle` for a tool that
    /// pairs reads only when every fragment of the sample is a pair.
    private static func pairsOnlyWhenAllPairedPlan(
        _ bundle: URL,
        fixtures: ReadSetFixtures,
        in directory: URL
    ) async throws -> ReadSetPlan {
        try await ReadSetResolver(materializationDirectory: directory, materializer: fixtures.materializer)
            .plan(for: bundle, capability: .pairsOnlyWhenAllPaired)
    }

    /// A grandchild that holds more pair records than the 100,000 the layout
    /// scan reads, then a read without its mate, scans as strict pairs. Its
    /// whole-file count shows the read without a mate, and its label follows
    /// that count, so it is recorded single-end beside its count of pairs and
    /// a single read, in its sidecar and in its manifest. Before, it was
    /// labelled interleaved beside that count, which the Inspector showed and
    /// bundle combine read (re-review F8-N1).
    func testAMixedGrandchildWhoseSingleReadLiesPastTheScanIsLabelledSingleEnd() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let child = try await Self.importFilterOutput(
            Self.childPairs, named: "merge-pairs", of: fixtures.mergeDerivative, fixtures: fixtures, root: root
        )
        let pairCount = FASTQReadLayoutClassifier.defaultRecordLimit / 2
        var records = (0..<pairCount).flatMap { index in
            [(id: "p\(index)/1", sequence: "ACGTACGTAC"), (id: "p\(index)/2", sequence: "ACGTACGTAC")]
        }
        records.append((id: "o1/1", sequence: "ACGTACGTAC"))
        let grandchild = try await Self.importFilterOutput(
            records, named: "merge-long-mixed", of: child.bundle, fixtures: fixtures, root: root
        )

        let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: grandchild.payload))
        let roles = sidecar.readClassification?.files
        XCTAssertEqual(roles?.map(\.role), [.pairedR1, .pairedR2, .unpaired])
        XCTAssertEqual(roles?.map(\.readCount), [pairCount, pairCount, 1])
        XCTAssertEqual(sidecar.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: grandchild.bundle)?.pairingMode, .singleEnd)

        let plan = try await Self.pairsOnlyWhenAllPairedPlan(
            grandchild.bundle, fixtures: fixtures, in: root.appendingPathComponent("plan", isDirectory: true)
        )
        XCTAssertTrue(plan.sampleHoldsPairsAndSingleReads)
        XCTAssertEqual(plan.composition.pairedFragments, pairCount)
        XCTAssertEqual(plan.composition.orphanReads, 1)
    }

    /// Every later generation of pairs from a merge bundle records its count
    /// of only pairs and the interleaved label, and runs as pairs. That holds
    /// for a grandchild of a child that still carries the single-end label F6
    /// wrote beside its count, and for the grandchild's own child. This
    /// closes the generations re-review F6-S1 named (F8-N4 listed both as
    /// untested).
    func testEveryLaterGenerationOfPairsFromAMergeBundleRunsAsPairs() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let child = try await Self.importFilterOutput(
            Self.childPairs, named: "merge-pairs", of: fixtures.mergeDerivative, fixtures: fixtures, root: root
        )
        try Self.labelSingleEnd(child)
        let onePair = Array(Self.childPairs.prefix(2))
        let grandchild = try await Self.importFilterOutput(
            onePair, named: "merge-pairs-2", of: child.bundle, fixtures: fixtures, root: root
        )
        let greatGrandchild = try await Self.importFilterOutput(
            onePair, named: "merge-pairs-3", of: grandchild.bundle, fixtures: fixtures, root: root
        )

        for generation in [grandchild, greatGrandchild] {
            let name = generation.bundle.lastPathComponent
            XCTAssertTrue(
                FASTQBundle.loadDerivedManifest(in: generation.bundle)?.lineage.contains { $0.kind == .pairedEndMerge } ?? false,
                name
            )
            let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: generation.payload), name)
            XCTAssertEqual(sidecar.readClassification?.files.map(\.role), [.pairedR1, .pairedR2], name)
            XCTAssertEqual(sidecar.readClassification?.files.map(\.readCount), [1, 1], name)
            XCTAssertEqual(sidecar.ingestion?.pairingMode, .interleaved, name)
            let plan = try await Self.pairsOnlyWhenAllPairedPlan(
                generation.bundle, fixtures: fixtures, in: root.appendingPathComponent("plan-\(name)", isDirectory: true)
            )
            XCTAssertEqual(plan.sourceLayout, .interleavedFile, name)
            XCTAssertNil(plan.singleReadReason, name)
            XCTAssertEqual(plan.matePairs.count, 1, name)
        }
    }

    /// A dialog repair writes the pairs it repaired, then every read without
    /// a mate, which are the source's merged reads and the orphans the repair
    /// made. Only the source's merged reads are merged reads. Before, the
    /// import named every single read of a repair of a merge bundle from the
    /// source's roles, so it recorded the new orphans as merged reads, and an
    /// assembler took them as merged reads.
    func testADialogRepairOfAMergeBundleRecordsTheOrphansItMadeAsOrphans() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let repaired = try await Self.importFilterOutput(
            [
                (id: "u1/1", sequence: "ACGTACGTAC"), (id: "u1/2", sequence: "ACGTACGTAC"),
                (id: "x1", sequence: "ACGTACGTACGTAC"), (id: "x2", sequence: "ACGTACGTACGTAC"),
                (id: "x3", sequence: "ACGTACGTACGTAC"), (id: "w1/1", sequence: "ACGTACGTAC"),
            ],
            named: "merge-repaired",
            of: fixtures.mergeDerivative,
            fixtures: fixtures,
            root: root,
            request: .pairedEndRepair
        )

        let roles = try XCTUnwrap(FASTQMetadataStore.load(for: repaired.payload)?.readClassification)
        XCTAssertEqual(roles.pairedReadCount, 2)
        XCTAssertEqual(roles.mergedReadCount, 3)
        XCTAssertEqual(roles.unpairedReadCount, 1)
        XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: repaired.bundle)?.pairingMode, .singleEnd)
    }

    /// A dialog merge writes the reads it merged, then the pairs it could not
    /// merge, then the reads its source held without a mate. Its single reads
    /// are therefore merged reads, except the orphans the source records.
    /// Before, the import named every single read from the source's roles,
    /// so a merge of a child that lists no merged read, or of an interleaved
    /// root, recorded the merged reads as orphans, and a merge of a repair
    /// derivative recorded the merged reads as orphans too (re-review F8-N3).
    func testADialogMergeRecordsTheReadsItMergedAsMergedReads() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let child = try await Self.importFilterOutput(
            Self.childPairs, named: "merge-pairs", of: fixtures.mergeDerivative, fixtures: fixtures, root: root
        )
        let merge = FASTQDerivativeRequest.pairedEndMerge(strictness: .normal, minOverlap: 12)
        let mergedOutput: [(id: String, sequence: String)] = [
            (id: "u1", sequence: "ACGTACGTACGTAC"),
            (id: "u2/1", sequence: "ACGTACGTAC"), (id: "u2/2", sequence: "ACGTACGTAC"),
        ]
        let cases: [(source: URL, name: String, records: [(id: String, sequence: String)], merged: Int, orphans: Int)] = [
            (child.bundle, "child-merged", mergedOutput, 1, 0),
            (fixtures.interleavedRoot, "interleaved-merged", mergedOutput, 1, 0),
            (fixtures.repairDerivative, "repair-merged", [
                (id: "r1", sequence: "ACGTACGTACGTAC"),
                (id: "r2/1", sequence: "ACGTACGTAC"), (id: "r2/2", sequence: "ACGTACGTAC"),
                (id: "o1", sequence: "ACGTACGTAC"),
            ], 1, 1),
        ]
        for testCase in cases {
            let output = try await Self.importFilterOutput(
                testCase.records, named: testCase.name, of: testCase.source, fixtures: fixtures, root: root, request: merge
            )
            let roles = try XCTUnwrap(FASTQMetadataStore.load(for: output.payload)?.readClassification, testCase.name)
            XCTAssertEqual(roles.pairedReadCount, 2, testCase.name)
            XCTAssertEqual(roles.mergedReadCount, testCase.merged, testCase.name)
            XCTAssertEqual(roles.unpairedReadCount, testCase.orphans, testCase.name)
            XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: output.bundle)?.pairingMode, .singleEnd, testCase.name)

            let plan = try await ReadSetResolver(
                materializationDirectory: root.appendingPathComponent("plan-\(testCase.name)", isDirectory: true),
                materializer: fixtures.materializer
            ).plan(for: output.bundle, capability: .bothInOneRunAsSeparateFiles)
            // Merged reads alone reach an assembler as merged reads. Merged
            // reads beside orphans in one file are merged or orphan reads.
            XCTAssertEqual(plan.composition.pairedFragments, 1, testCase.name)
            XCTAssertEqual(
                plan.singleReads.map(\.role),
                [testCase.orphans == 0 ? .merged : .mergedOrOrphan],
                testCase.name
            )
            XCTAssertEqual(plan.singleReads.map(\.readCount), [testCase.merged + testCase.orphans], testCase.name)
        }
    }
}

// LongReadLayoutConsumerPinTests.swift - The layout each FASTQ consumer gives a long-read bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M1 (row M846, BIO 2, QA 1). Pins, at the base, what each caller of
// `FASTQInputLayoutResolver` and of the long-read rule gives three bundles. An Oxford Nanopore root
// whose reads repeat ids, so the record scan reads them as mates by identical names, a PacBio root
// whose reads repeat ids the same way, and a derived child whose platform sits only on its Oxford
// Nanopore parent (the ancestor walk of `FASTQLongReadRule.recordedPlatform(of:)`). Each platform is
// recorded through `FASTQMetadataStore`. A consumer in LungfishApp, LungfishCLI or LungfishOperations,
// which this target does not link, is pinned through the resolver call it makes, with its arguments.
// `SCR/lanes/13.42/callers.md` gives one row for each. M2 flips only the pins the BIO ruling lists, the
// 17 of its section 3a, to single reads, once `FASTQInputLayoutResolver` reads the recorded platform. The
// copy outside every bundle with no hint keeps the scan's answer, a Known limit (Q5).

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class LongReadLayoutConsumerPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "long-read-layout-pins")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixtures

    /// One bundle of the table, with the file inside it that a consumer reads.
    private struct Fixture {
        let name: String
        let bundle: URL
        var reads: URL { bundle.appendingPathComponent("reads.fastq") }
    }

    private static let sequence = "ACGTACGTACGTACGTAC"

    /// Each id twice in a row, so the scan reads every two records as one mate pair.
    private static func repeatedIdFASTQ(_ headers: [String]) -> String {
        let quality = String(repeating: "I", count: sequence.count)
        return headers.flatMap { [$0, $0] }.map { "@\($0)\n\(sequence)\n+\n\(quality)\n" }.joined()
    }

    private static let ontText = repeatedIdFASTQ([
        "8f2e0c7a-0001-4f7a-9d1a-0123456789ab runid=abc",
        "8f2e0c7a-0002-4f7a-9d1a-0123456789ab runid=abc",
    ])

    private static let pacbioText = repeatedIdFASTQ([
        "m64011_190830_220126/101/ccs",
        "m64011_190830_220126/102/ccs",
    ])

    private func writeRoot(_ name: String, _ text: String, platform: SequencingPlatform, in imports: URL) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: reads)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: platform), for: reads)
        return bundle
    }

    /// A deduplicate child of `ont` whose own sidecar records nothing.
    private func writeChild(of parent: URL, in imports: URL) throws -> URL {
        let child = imports.appendingPathComponent("ont-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(Self.ontText.utf8).write(to: child.appendingPathComponent("reads.fastq"))
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-subset",
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 4, baseCount: 72),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: child
        )
        return child
    }

    private func makeFixtures() throws -> [Fixture] {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let ont = try writeRoot("ont", Self.ontText, platform: .oxfordNanopore, in: imports)
        let pacbio = try writeRoot("pacbio", Self.pacbioText, platform: .pacbio, in: imports)
        let child = try writeChild(of: ont, in: imports)
        XCTAssertNil(FASTQMetadataStore.load(for: child.appendingPathComponent("reads.fastq")))
        return [
            Fixture(name: "ont", bundle: ont),
            Fixture(name: "pacbio", bundle: pacbio),
            Fixture(name: "ont-child", bundle: child),
        ]
    }

    /// A copy of the reads away from every bundle, as a materialization or an operation's output is.
    private func scratchCopy(of fixture: Fixture) throws -> URL {
        let folder = root.appendingPathComponent("scratch-\(fixture.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("reads.fastq")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.copyItem(at: fixture.reads, to: copy)
        }
        return copy
    }

    private static func name(_ layout: FASTQInputLayout?) -> String {
        switch layout {
        case .strictlyInterleaved?: return "strictlyInterleaved"
        case .mixedMergedAndPairs?: return "mixedMergedAndPairs"
        case .singleEnd?: return "singleEnd"
        case .pairedFiles?: return "pairedFiles"
        case nil: return "nil"
        }
    }

    // MARK: - The table

    /// One consumer, its pins on `ont`, `pacbio` and `ont-child` in that order, and how to read them.
    private struct Row {
        let consumer: String
        let expected: [String]
        let pin: (Fixture) async throws -> String
    }

    private static let strict = Array(repeating: "strictlyInterleaved", count: 3)
    private static let single = Array(repeating: "singleEnd", count: 3)

    private func resolverRows() -> [Row] {
        [
            Row(consumer: "FASTQOperationCLIInvocationBuilder.swift:156 (LungfishApp), resolve(fastqURL: file, metadataFrom: bundle)",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(fastqURL: f.reads, metadataFrom: f.bundle).layout)
            },
            Row(consumer: "FASTQOperationOutputImporter.swift:227 (LungfishApp), resolve(fastqURL: output copy, metadataFrom: bundle)",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(fastqURL: try self.scratchCopy(of: f), metadataFrom: f.bundle).layout)
            },
            Row(consumer: "FastqDeinterleaveSubcommand.swift:61 (LungfishCLI), resolve(fastqURL: file, metadataFrom: bundle)",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(fastqURL: f.reads, metadataFrom: f.bundle).layout)
            },
            Row(consumer: "FastqMergeSubcommand.swift:53 (LungfishCLI), resolve(fastqURL: file, metadataFrom: bundle)",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(fastqURL: f.reads, metadataFrom: f.bundle).layout)
            },
            Row(consumer: "FastqTranslateSubcommand.swift:160 (LungfishCLI), whole-file scan, reached only past the :171 gate",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(fastqURL: f.reads, metadataFrom: f.bundle, recordLimit: Int.max).layout)
            },
            Row(consumer: "FASTQBundleMergeService+ReadRoles.swift:27 (LungfishOperations), resolve(inputURLs: [file]) past its own sidecar check",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.reads]).layout)
            },
            Row(consumer: "FASTQDerivativeService+Helpers.swift:25 (LungfishOperations), resolve(inputURLs: [bundle])",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.bundle]).layout)
            },
            Row(consumer: "ManagedMappingPipeline.swift:470, resolve(inputURLs: [staged file], pairedFiles: false)",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.reads], pairedFiles: false).layout)
            },
            Row(consumer: "MappingInputResolver.swift:169, resolve(inputURLs: [execution file], pairedFiles: false, explicit: nil)",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.reads], pairedFiles: false, explicit: nil).layout)
            },
            Row(consumer: "IlluminaAmpliconPairMerger.swift:213, resolve(inputURLs: [file])",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.reads]).layout)
            },
            Row(consumer: "ONTBarcodeDemuxGenotypingPipeline.swift:1882, resolve(inputURLs: [file])",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.reads]).layout)
            },
            Row(consumer: "RecipeEngine.swift:662, resolve(inputURLs: [file])",
                expected: Self.single) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [f.reads]).layout)
            },
            Row(consumer: "Any consumer handed a copy outside every bundle with no hint, resolve(inputURLs: [copy])",
                expected: Self.strict) { f in
                Self.name(FASTQInputLayoutResolver.resolve(inputURLs: [try self.scratchCopy(of: f)]).layout)
            },
        ]
    }

    private func workflowRows() -> [Row] {
        let resolver = ReadSetResolver(
            materializationDirectory: root.appendingPathComponent("work", isDirectory: true),
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
        )
        let output = root.appendingPathComponent("out", isDirectory: true)
        func viralRecon(_ f: Fixture, _ urls: [URL]) -> String {
            let sample = ViralReconSample(
                sampleName: f.name, sourceBundleURL: f.bundle, fastqURLs: urls, barcode: nil, sequencingSummaryURL: nil
            )
            return Self.name(ViralReconReadPairing.decision(for: sample).layout)
        }
        return [
            Row(consumer: "ReadSetResolver.plan(for:capability:), the rule at ReadSetResolver.swift:137 before :373",
                expected: Array(repeating: "single_end_file", count: 3)) { f in
                try await resolver.plan(for: f.bundle, capability: .bothInOneRunAsSeparateFiles).sourceLayout.rawValue
            },
            Row(consumer: "FASTQLongReadRule.recordedPlatform(of:) (LungfishIO, moved from ReadSetResolver+Sources.swift:152 in M2)",
                expected: ["oxfordNanopore", "pacbio", "oxfordNanopore"]) { f in
                FASTQLongReadRule.recordedPlatform(of: f.bundle)?.rawValue ?? "nil"
            },
            Row(consumer: "TaxTriageAnalysisRunTool.recordedPlatform(of:), TaxTriageAnalysisRunTool.swift:90 and :258",
                expected: ["oxford", "pacbio", "oxford"]) { f in
                TaxTriageAnalysisRunTool.recordedPlatform(of: f.bundle).map { String(describing: $0) } ?? "nil"
            },
            Row(consumer: "ViralReconReadPairing.decision(for:) naming the bundle, ViralReconReadPairing+Bundles.swift:119",
                expected: Array(repeating: "singleEnd", count: 3)) { f in
                viralRecon(f, [f.bundle])
            },
            Row(consumer: "ViralReconReadPairing.decision(for:) naming its file, ViralReconReadPairing.swift:186",
                expected: Self.single) { f in
                viralRecon(f, [f.reads])
            },
            Row(consumer: "TaxTriagePipeline.resolvedReadLayout(for:), TaxTriagePipeline+ReadLayout.swift:53",
                expected: Self.single) { f in
                Self.name(TaxTriagePipeline.resolvedReadLayout(for: TaxTriageSample(sampleId: f.name, fastq1: f.reads)))
            },
            Row(consumer: "ClassificationPipeline.reconcileInterleavedRequest(_:), ClassificationPipeline+ReadSets.swift:77",
                expected: Array(repeating: "singleEnd interleaved=false", count: 3)) { f in
                let config = ClassificationConfig(
                    inputFiles: [f.reads],
                    isPairedEnd: false,
                    interleavedInput: true,
                    databaseName: "Viral",
                    databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
                    outputDirectory: output
                )
                let reconciled = ClassificationPipeline.reconcileInterleavedRequest(config)
                return "\(Self.name(reconciled.resolution?.layout)) interleaved=\(reconciled.config.interleavedInput)"
            },
            Row(consumer: "AssemblyRunRequest.resolveInputLayout, AssemblyRunRequest.swift:249 (SPAdes, short reads)",
                expected: Self.single) { f in
                Self.name(AssemblyRunRequest.resolveInputLayout(
                    tool: .spades,
                    readType: .illuminaShortReads,
                    pairedEnd: false,
                    explicit: nil,
                    originalInputURLs: [f.bundle],
                    executionInputURLs: [f.reads]
                )?.layout)
            },
            Row(consumer: "FASTQPairingModeResolver.resolvePairing(inputURL:metadataFrom:), FASTQPairingModeResolver.swift:108",
                expected: Array(repeating: "singleEnd pairAware=false", count: 3)) { f in
                let decision = FASTQPairingModeResolver.resolvePairing(inputURL: try self.scratchCopy(of: f), metadataFrom: f.bundle)
                return "\(Self.name(decision.resolution.layout)) pairAware=\(decision.pairAware)"
            },
        ]
    }

    // MARK: - Pins

    /// Every consumer's pin on the three bundles, at the base. Prints the whole table so a failure shows every row.
    func testEveryConsumerLayoutOfALongReadBundleAtTheBase() async throws {
        let fixtures = try makeFixtures()
        var table: [String] = []
        for row in workflowRows() + resolverRows() {
            var actual: [String] = []
            for fixture in fixtures {
                actual.append(try await row.pin(fixture))
            }
            table.append("\(row.consumer) | \(actual.joined(separator: " | "))")
            XCTAssertEqual(actual, row.expected, row.consumer)
        }
        print("13.42 pins (ont | pacbio | ont-child)\n" + table.joined(separator: "\n"))
    }
}

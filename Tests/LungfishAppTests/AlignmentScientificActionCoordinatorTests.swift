import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor final class AlignmentScientificActionCoordinatorTests: XCTestCase {
    private func context(
        _ source: AlignmentSourceReadResolution = .bamFallback,
        outputCapability: AlignmentOutputCapability = .projectDerivedRoot(URL(fileURLWithPath: "/output"))
    ) throws -> AlignmentActionContext {
        let bam = URL(fileURLWithPath: "/evidence/a.bam"), index = URL(fileURLWithPath: "/evidence/a.bam.bai")
        return try .init(identity: .init(workflow: "map", resultID: "r", sampleID: "s", evidenceID: "e"), alignmentURL: bam, indexURL: index, decodingReferenceURL: nil, contig: "chrSynthetic", contigLength: 100, alignmentSnapshot: .init(url: bam, byteCount: 1, sha256: "a"), indexSnapshot: .init(url: index, byteCount: 1, sha256: "i"), decodingReferenceSnapshot: nil, filters: .init(minimumDepth: 1, minimumMapQ: 30, minimumBaseQuality: 20, excludedFlags: 0x904, readGroups: ["rg"]), outputCapability: outputCapability, sourceReads: source, presentationLabel: "evidence")
    }
    func testRegionUsesContextNotMappingResult() async throws {
        var got: BAMRegionExtractionConfig?
        let transaction = try makeTransaction()
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            regionStager: { config in got = config; return transaction },
            publisher: { request in self.publicationResult(for: request.transaction) }
        )
        _ = try await coordinator.extractRegion(
            context: try context(),
            region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9),
            destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")),
            outputBaseName: "x"
        )
        XCTAssertEqual(got?.regions, ["chrSynthetic:5-9"])
        XCTAssertEqual(got?.indexURL?.path, "/evidence/a.bam.bai")
        XCTAssertEqual(got?.minMapQ, 30)
    }

    func testConsensusGenerationUsesExactRequestValidatesTwiceAndPublishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("a.bam")
        let bai = directory.appendingPathComponent("a.bam.bai")
        try Data("bam".utf8).write(to: bam)
        try Data("bai".utf8).write(to: bai)
        let evidence = try AlignmentActionContext(
            identity: .init(workflow: "EsViritu", resultID: "run", sampleID: "S1", evidenceID: "virus"),
            alignmentURL: bam, indexURL: bai, decodingReferenceURL: nil,
            contig: "virus", contigLength: 40,
            alignmentSnapshot: .init(url: bam, byteCount: 3, sha256: "bam"),
            indexSnapshot: .init(url: bai, byteCount: 3, sha256: "bai"),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12, excludedFlags: 0xD04, readGroups: ["rg2", "rg1"]),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "S1 virus"
        )
        let region = ResolvedAlignmentRegion(scope: .selectedRegion, contig: "virus", start: 10, end: 15)
        let export = try MappingConsensusExportRequestBuilder.build(
            sampleName: "S1", context: evidence, region: region,
            consensusMode: .bayesian, useAmbiguity: true
        )
        var validations = 0
        var fetched: AlignmentConsensusRequest?
        var published: AlignmentConsensusPublicationRequest?
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in validations += 1 },
            consensusFetcher: { _, request in
                fetched = request
                return .init(sequence: "ANGNN", referenceLength: 5, allLowDepth: false)
            },
            consensusPublisher: { request in
                published = request
                return .init(finalURL: request.destination.finalURL, payloadURL: request.destination.finalURL, provenanceURL: request.destination.finalURL.appendingPathExtension("provenance.json"))
            }
        )

        let generation = try await coordinator.generateConsensus(context: evidence, exportRequest: export)
        XCTAssertEqual(fetched, export.consensusRequest)
        XCTAssertTrue(generation.summary.contains("Reference-fill policy: never"))
        XCTAssertTrue(generation.summary.contains("Read groups: rg1,rg2"))
        let destination = directory.appendingPathComponent("consensus.fasta")
        _ = try await coordinator.publishConsensus(generation, destination: .fasta(destination))
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(published?.consensusRequest, export.consensusRequest)
        XCTAssertEqual(published?.region, region)
    }

    func testAllLowDepthGenerationRequiresWarningButKeepsEvidenceOnlyNs() async throws {
        let evidence = try context()
        let region = ResolvedAlignmentRegion(scope: .wholeContig, contig: evidence.contig, start: 0, end: evidence.contigLength)
        let export = try MappingConsensusExportRequestBuilder.build(
            sampleName: "s", context: evidence, region: region,
            consensusMode: .simple, useAmbiguity: false
        )
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            consensusFetcher: { _, _ in
                .init(sequence: String(repeating: "N", count: evidence.contigLength), referenceLength: evidence.contigLength, allLowDepth: true)
            }
        )

        let generation = try await coordinator.generateConsensus(context: evidence, exportRequest: export)

        XCTAssertTrue(generation.requiresAllLowDepthWarning)
        XCTAssertTrue(generation.allLowDepthWarningMessage.contains("only N"))
        XCTAssertTrue(generation.allLowDepthWarningMessage.contains("without filling from the reference"))
        XCTAssertEqual(generation.result.sequence, String(repeating: "N", count: evidence.contigLength))
    }

    func testConsensusGenerationCooperativelyCancelsBeforeReturningAResult() async throws {
        let evidence = try context()
        let region = ResolvedAlignmentRegion(scope: .wholeContig, contig: evidence.contig, start: 0, end: evidence.contigLength)
        let export = try MappingConsensusExportRequestBuilder.build(
            sampleName: "s", context: evidence, region: region,
            consensusMode: .simple, useAmbiguity: false
        )
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            consensusFetcher: { _, _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return .init(sequence: "A", referenceLength: 1, allLowDepth: false)
            }
        )
        let task = Task {
            try await coordinator.generateConsensus(context: evidence, exportRequest: export)
        }

        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled consensus generation returned a result")
        } catch is CancellationError {
            // Expected: the operation cancellation callback can stop generation.
        }
    }

    func testConsensusCancellationAfterGenerationPreventsPublisherInvocation() async throws {
        let evidence = try context()
        let region = ResolvedAlignmentRegion(scope: .wholeContig, contig: evidence.contig, start: 0, end: evidence.contigLength)
        let export = try MappingConsensusExportRequestBuilder.build(sampleName: "s", context: evidence, region: region, consensusMode: .simple, useAmbiguity: false)
        var didPublish = false
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            consensusFetcher: { _, _ in .init(sequence: String(repeating: "N", count: 100), referenceLength: 100, allLowDepth: true) },
            consensusPublisher: { request in
                didPublish = true
                return .init(finalURL: request.destination.finalURL, payloadURL: request.destination.finalURL, provenanceURL: request.destination.finalURL)
            }
        )
        let generation = try await coordinator.generateConsensus(context: evidence, exportRequest: export)
        let task = Task {
            try await coordinator.publishConsensus(generation, destination: .fasta(URL(fileURLWithPath: "/out.fasta")))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled workflow published a result")
        } catch is CancellationError {}
        XCTAssertFalse(didPublish)
    }

    func testConsensusShareSessionCleansOnDismissAndSuccessExactlyOnce() {
        for outcome in [AlignmentConsensusShareSession.Outcome.cancelled, .shared] {
            var cleanupCount = 0
            var outcomes: [AlignmentConsensusShareSession.Outcome] = []
            let session = AlignmentConsensusShareSession(
                cleanup: { cleanupCount += 1 },
                finish: { outcomes.append($0) }
            )
            if outcome == .cancelled {
                session.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: nil)
            } else {
                let service = NSSharingService(title: "test", image: NSImage(), alternateImage: nil, handler: {})
                session.sharingService(service, didShareItems: [])
                session.sharingService(service, didShareItems: [])
            }
            XCTAssertEqual(cleanupCount, 1)
            XCTAssertEqual(outcomes, [outcome])
        }
    }

    func testRegionValidatesImmediatelyBeforeStagingAndImmediatelyBeforePublication() async throws {
        let transaction = try makeTransaction()
        var gates: [String] = []
        var stagedConfig: BAMRegionExtractionConfig?
        var didStage = false
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in gates.append(didStage ? "post-stage" : "pre-stage") },
            regionStager: { config in
                stagedConfig = config
                didStage = true
                return transaction
            },
            publisher: { request in
                return self.publicationResult(for: request.transaction)
            }
        )

        let result = try await coordinator.extractRegion(
            context: try context(),
            region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9),
            destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")),
            outputBaseName: "x"
        )

        XCTAssertEqual(gates, ["pre-stage", "post-stage"])
        XCTAssertEqual(stagedConfig?.regions, ["chrSynthetic:5-9"])
        XCTAssertEqual(stagedConfig?.indexURL?.path, "/evidence/a.bam.bai")
        XCTAssertEqual(result.finalURL.path, "/out/final.lungfishfastq")
    }

    func testStaleSecondValidationCleansTransactionAndNeverPublishes() async throws {
        let transaction = try makeTransaction()
        transaction.appendExecutionRecord(executionRecord(stderr: "staged evidence"))
        var validationCount = 0
        var didPublish = false
        let capturedIdentity = try context().identity
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in
                validationCount += 1
                if validationCount == 2 { throw AlignmentActionContext.EvidenceError.staleEvidence(URL(fileURLWithPath: "/evidence/a.bam")) }
            },
            regionStager: { _ in transaction },
            publisher: { _ in
                didPublish = true
                XCTFail("Publisher must not run after stale evidence validation")
                throw AlignmentScientificActionError.contextUnavailable
            }
        )

        do {
            _ = try await coordinator.extractRegion(
                context: try self.context(),
                region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9),
                destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")),
                outputBaseName: "x"
            )
            XCTFail("Expected stale evidence validation to fail before publication")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .staleInput)
            XCTAssertEqual(failure.executionRecords.count, 1)
            XCTAssertTrue(failure.message.contains("workflow=map;resultID=r;sampleID=s;evidenceID=e"))
            XCTAssertTrue(failure.message.contains("a.bam"))
        }

        XCTAssertEqual(capturedIdentity, try context().identity)
        XCTAssertEqual(validationCount, 2)
        XCTAssertFalse(didPublish)
        XCTAssertTrue(transaction.isCleanedUp)
    }

    func testLaunchReportsCapturedIdentityAndStagedRecordsWhenSecondGateIsStale() async throws {
        let transaction = try makeTransaction()
        transaction.appendExecutionRecord(executionRecord(stderr: "staged evidence"))
        var validationCount = 0
        var didPublish = false
        var logs: [String] = []
        var terminals: [AlignmentScientificActionReporter.Terminal] = []
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in
                validationCount += 1
                if validationCount == 2 {
                    throw AlignmentActionContext.EvidenceError.staleEvidence(URL(fileURLWithPath: "/evidence/a.bam"))
                }
            },
            regionStager: { _ in transaction },
            publisher: { _ in
                didPublish = true
                throw AlignmentScientificActionError.contextUnavailable
            }
        )
        let reporter = AlignmentScientificActionReporter(
            start: { _, _ in UUID() },
            installCancellation: { _, _ in },
            log: { _, message in logs.append(message) },
            finish: { _, terminal in terminals.append(terminal) }
        )

        let task = coordinator.launchRegion(
            context: try context(),
            region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9),
            destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")),
            outputBaseName: "x",
            reporter: reporter
        )
        _ = await task.result

        XCTAssertFalse(didPublish)
        XCTAssertTrue(transaction.isCleanedUp)
        XCTAssertTrue(logs.contains { $0.contains("workflow=map;resultID=r;sampleID=s;evidenceID=e") })
        XCTAssertTrue(logs.contains { $0.contains("samtools") && $0.contains("staged evidence") })
        guard case .failure(let message)? = terminals.first else {
            return XCTFail("Expected one stale-input failure")
        }
        XCTAssertEqual(terminals.count, 1)
        XCTAssertTrue(message.contains("workflow=map;resultID=r;sampleID=s;evidenceID=e"))
    }

    func testSelectedReadsPreferCapturedSourceFASTQsAndFallbackToCapturedBAM() async throws {
        let sourceTransaction = try makeTransaction()
        let bamTransaction = try makeTransaction()
        var sourceConfig: ReadIDExtractionConfig?
        var bamConfig: ReadIDBAMExtractionConfig?
        let read = AlignedRead(name: "qname", flag: 0, chromosome: "chrSynthetic", position: 4, mapq: 60, cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30])
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            sourceStager: { config, _, _ in sourceConfig = config; return sourceTransaction },
            bamStager: { config, _, _ in bamConfig = config; return bamTransaction },
            publisher: { request in self.publicationResult(for: request.transaction) }
        )

        _ = try await coordinator.extractSelectedReads(context: try context(.sourceFASTQs([URL(fileURLWithPath: "/source/R1.fastq.gz")])), records: [read], destination: .bundle(URL(fileURLWithPath: "/out/source.lungfishfastq")), outputBaseName: "source")
        _ = try await coordinator.extractSelectedReads(context: try context(), records: [read], destination: .bundle(URL(fileURLWithPath: "/out/bam.lungfishfastq")), outputBaseName: "bam")

        XCTAssertEqual(sourceConfig?.sourceFASTQs.map(\.path), ["/source/R1.fastq.gz"])
        XCTAssertEqual(sourceConfig?.readIDs, ["qname"])
        XCTAssertTrue(sourceConfig?.keepReadPairs == true)
        XCTAssertEqual(bamConfig?.bamURL.path, "/evidence/a.bam")
        XCTAssertEqual(bamConfig?.readIDs, ["qname"])
        XCTAssertFalse(bamConfig?.includeSecondary == true)
        XCTAssertFalse(bamConfig?.excludeDuplicates == true)
    }

    func testDestinationResolutionReturnsFinalProjectOrUserURLsBeforeStaging() throws {
        let coordinator = AlignmentScientificActionCoordinator(
            destinationResolver: { capability, basename in
                switch capability {
                case .projectDerivedRoot(let root): return .bundle(root.appendingPathComponent("derived/\(basename).lungfishfastq"))
                case .userSelectedDestination: return .file(URL(fileURLWithPath: "/chosen/\(basename).fastq"))
                }
            }
        )

        XCTAssertEqual(try coordinator.resolveDestination(for: try context().outputCapability, outputBaseName: "region").finalURL.path, "/output/derived/region.lungfishfastq")
        XCTAssertEqual(try coordinator.resolveDestination(for: .userSelectedDestination, outputBaseName: "reads").finalURL.path, "/chosen/reads.fastq")
    }

    func testAsyncUserDestinationChooserNormalizesBundleExtensionBeforeLaunch() async throws {
        let coordinator = AlignmentScientificActionCoordinator()

        let destination = try await coordinator.resolveDestination(
            for: .userSelectedDestination,
            outputBaseName: "selected reads",
            userDestinationChooser: { _ in URL(fileURLWithPath: "/chosen/selected reads") }
        )

        XCTAssertEqual(destination.finalURL.path, "/chosen/selected reads.lungfishfastq")

        let mixedCaseDestination = try await coordinator.resolveDestination(
            for: .userSelectedDestination,
            outputBaseName: "selected reads",
            userDestinationChooser: { _ in URL(fileURLWithPath: "/chosen/selected reads.LUNGFISHFASTQ") }
        )

        XCTAssertEqual(mixedCaseDestination.finalURL.path, "/chosen/selected reads.lungfishfastq")
    }

    func testAsyncUserDestinationCancellationIsTypedBeforeLaunch() async throws {
        let coordinator = AlignmentScientificActionCoordinator()
        do {
            _ = try await coordinator.resolveDestination(
                for: .userSelectedDestination,
                outputBaseName: "selected reads",
                userDestinationChooser: { _ in nil }
            )
            XCTFail("Expected destination cancellation")
        } catch let error as AlignmentScientificActionError {
            guard case .destinationCancelled = error else {
                return XCTFail("Expected typed destination cancellation, got \(error)")
            }
        }
    }

    func testProjectDestinationBypassesUserChooser() async throws {
        var chooserCalls = 0
        let coordinator = AlignmentScientificActionCoordinator()
        let destination = try await coordinator.resolveDestination(
            for: .projectDerivedRoot(URL(fileURLWithPath: "/project")),
            outputBaseName: "selected reads",
            userDestinationChooser: { _ in
                chooserCalls += 1
                return URL(fileURLWithPath: "/must-not-be-used")
            }
        )

        XCTAssertEqual(chooserCalls, 0)
        XCTAssertTrue(destination.finalURL.path.hasPrefix("/project/alignment-read-extractions/selected_reads-"))
        XCTAssertEqual(destination.finalURL.pathExtension, "lungfishfastq")
    }

    func testRealViewerRoutesCancelBeforeOperationOrScientificLaunch() async throws {
        let operationIDsBefore = Set(OperationCenter.shared.items.map(\.id))
        let read = AlignedRead(
            name: "qname",
            flag: 0,
            chromosome: "chrSynthetic",
            position: 4,
            mapq: 60,
            cigar: [],
            sequence: "ACGT",
            qualities: [30, 30, 30, 30]
        )

        for route in ["region", "reads"] {
            let viewer = ViewerViewController()
            let window = NSWindow()
            window.contentViewController = viewer
            _ = viewer.view
            viewer.alignmentActionContext = try context(outputCapability: .userSelectedDestination)
            viewer.setExplicitAlignmentSelection(contig: "chrSynthetic", start: 4, end: 9)
            let presenter = CancellingSavePanelPresenter()
            viewer.alignmentExtractionSavePanelPresenter = presenter

            if route == "region" {
                viewer.extractReadsInSelectedAlignmentRegion()
            } else {
                viewer.extractSelectedReads([read])
            }

            for _ in 0..<10 where presenter.callCount == 0 {
                await Task.yield()
            }

            XCTAssertEqual(presenter.callCount, 1, route)
            XCTAssertNil(viewer.activeSelectedReadsExtractionTask, route)
            XCTAssertEqual(Set(OperationCenter.shared.items.map(\.id)), operationIDsBefore, route)
            window.contentViewController = nil
        }
    }

    func testLaunchReportsOneSuccessWithFinalURLsAndExecutionArgv() async throws {
        let transaction = try makeTransaction()
        let record = executionRecord(stderr: "useful stderr")
        transaction.appendExecutionRecord(record)
        var terminals: [AlignmentScientificActionReporter.Terminal] = []
        var logs: [String] = []
        var cancellation: (() -> Void)?
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            regionStager: { _ in transaction },
            publisher: { request in
                .init(finalURL: URL(fileURLWithPath: "/out/final.lungfishfastq"), outputURLs: [URL(fileURLWithPath: "/out/final.lungfishfastq/reads.fastq")], provenanceURL: URL(fileURLWithPath: "/out/final.lungfishfastq/provenance.json"), readCount: 1, pairedEnd: false, executionRecords: request.transaction.executionRecords)
            }
        )
        let reporter = AlignmentScientificActionReporter(
            start: { _, _ in UUID() },
            installCancellation: { _, callback in cancellation = callback },
            log: { _, message in logs.append(message) },
            finish: { _, terminal in terminals.append(terminal) }
        )

        let task = coordinator.launchRegion(context: try context(), region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9), destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")), outputBaseName: "x", reporter: reporter)
        _ = await task.result

        XCTAssertNotNil(cancellation)
        XCTAssertEqual(terminals.count, 1)
        guard case .success(let result)? = terminals.first else {
            return XCTFail("Expected one final publication success")
        }
        XCTAssertEqual(result.finalURL.path, "/out/final.lungfishfastq")
        XCTAssertTrue(logs.contains { $0.contains("samtools") && $0.contains("useful stderr") })
    }

    func testLaunchReportsOneFailure() async throws {
        var terminals: [AlignmentScientificActionReporter.Terminal] = []
        let coordinator = AlignmentScientificActionCoordinator(validator: { _ in throw AlignmentScientificActionError.contextUnavailable })
        let reporter = AlignmentScientificActionReporter(start: { _, _ in UUID() }, installCancellation: { _, _ in }, log: { _, _ in }, finish: { _, terminal in terminals.append(terminal) })

        let task = coordinator.launchRegion(context: try context(), region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9), destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")), outputBaseName: "x", reporter: reporter)
        _ = await task.result

        XCTAssertEqual(terminals, [.failure(AlignmentScientificActionError.contextUnavailable.localizedDescription)])
    }

    func testLaunchCancellationCancelsTaskAndReportsOneCancelledTerminal() async throws {
        var cancellation: (() -> Void)?
        var terminals: [AlignmentScientificActionReporter.Terminal] = []
        let coordinator = AlignmentScientificActionCoordinator(
            validator: { _ in },
            regionStager: { _ in
                try await Task.sleep(for: .seconds(2))
                throw CancellationError()
            }
        )
        let reporter = AlignmentScientificActionReporter(start: { _, _ in UUID() }, installCancellation: { _, callback in cancellation = callback }, log: { _, _ in }, finish: { _, terminal in terminals.append(terminal) })

        let task = coordinator.launchRegion(context: try context(), region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9), destination: .bundle(URL(fileURLWithPath: "/out/final.lungfishfastq")), outputBaseName: "x", reporter: reporter)
        cancellation?()
        _ = await task.result

        XCTAssertEqual(terminals, [.cancelled("Alignment read extraction cancelled.")])
        XCTAssertEqual(terminals.count, 1)
    }

    func testViewerRoutesUseSharedFinalPublicationCoordinatorWithoutMappingResult() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/LungfishAppTests/AlignmentScientificActionCoordinatorTests.swift",
                with: "Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("resolveDestination(\n            for: context.outputCapability"))
        XCTAssertTrue(source.contains("resolveAlignmentExtractionDestination("))
        XCTAssertTrue(source.contains("alignmentExtractionSavePanelPresenter.present("))
        XCTAssertTrue(source.contains("catch AlignmentScientificActionError.destinationCancelled"))
        XCTAssertTrue(source.contains("AlignmentScientificActionCoordinator().launchRegion("))
        XCTAssertTrue(source.contains("AlignmentScientificActionCoordinator().launchSelectedReads("))
        XCTAssertFalse(source.contains("selectedReadsExtractionRunner"))
        XCTAssertFalse(source.contains("defaultSelectedReadsExtraction"))
        let selectedReadRoute = String(source[source.range(of: "func extractSelectedReads(_ reads: [AlignedRead])")!.lowerBound...])
        XCTAssertFalse(selectedReadRoute.contains("guard let result = activeMappingViewportController?.currentResult"))
        XCTAssertFalse(source.contains("selected-region.lungfishfastq"))
    }

    private func makeTransaction() throws -> AlignmentReadExtractionTransaction {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appendingPathComponent("reads.fastq")
        try "@read\nACGT\n+\n!!!!\n".write(to: payload, atomically: true, encoding: .utf8)
        return try .init(
            stagingDirectoryURL: directory,
            stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "reads.fastq", format: .fastq)],
            readCount: 1,
            pairedEnd: false
        )
    }

    private func publicationResult(for transaction: AlignmentReadExtractionTransaction) -> AlignmentReadExtractionPublicationResult {
        .init(
            finalURL: URL(fileURLWithPath: "/out/final.lungfishfastq"),
            outputURLs: [URL(fileURLWithPath: "/out/final.lungfishfastq/reads.fastq")],
            provenanceURL: URL(fileURLWithPath: "/out/final.lungfishfastq/provenance.json"),
            readCount: transaction.readCount,
            pairedEnd: transaction.pairedEnd,
            executionRecords: transaction.executionRecords
        )
    }

    private func executionRecord(stderr: String? = nil) -> AlignmentReadExtractionExecutionRecord {
        .init(stage: .payloadStaging, toolName: "samtools", toolVersion: "1", argv: ["samtools", "view"], inputs: [], outputs: [], exitStatus: 0, startedAt: Date(), completedAt: Date(), stderr: stderr)
    }

    private final class CancellingSavePanelPresenter: SavePanelPresenting {
        private(set) var callCount = 0

        func present(suggestedName: String, on window: NSWindow) async -> URL? {
            callCount += 1
            return nil
        }
    }
}

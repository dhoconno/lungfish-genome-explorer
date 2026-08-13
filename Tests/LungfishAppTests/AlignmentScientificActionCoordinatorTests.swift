import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor final class AlignmentScientificActionCoordinatorTests: XCTestCase {
    private func context(_ source: AlignmentSourceReadResolution = .bamFallback) throws -> AlignmentActionContext {
        let bam = URL(fileURLWithPath: "/evidence/a.bam"), index = URL(fileURLWithPath: "/evidence/a.bam.bai")
        return try .init(identity: .init(workflow: "map", resultID: "r", sampleID: "s", evidenceID: "e"), alignmentURL: bam, indexURL: index, decodingReferenceURL: nil, contig: "chrSynthetic", contigLength: 100, alignmentSnapshot: .init(url: bam, byteCount: 1, sha256: "a"), indexSnapshot: .init(url: index, byteCount: 1, sha256: "i"), decodingReferenceSnapshot: nil, filters: .init(minimumDepth: 1, minimumMapQ: 30, minimumBaseQuality: 20, excludedFlags: 0x904, readGroups: ["rg"]), outputCapability: .projectDerivedRoot(URL(fileURLWithPath: "/output")), sourceReads: source, presentationLabel: "evidence")
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
        } catch {
            XCTAssertEqual(error as? AlignmentActionContext.EvidenceError, .staleEvidence(URL(fileURLWithPath: "/evidence/a.bam")))
        }

        XCTAssertEqual(capturedIdentity, try context().identity)
        XCTAssertEqual(validationCount, 2)
        XCTAssertFalse(didPublish)
        XCTAssertTrue(transaction.isCleanedUp)
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
                try await Task.sleep(for: .seconds(5))
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

        XCTAssertTrue(source.contains("coordinator.resolveDestination(for: context.outputCapability"))
        XCTAssertTrue(source.contains("coordinator.launchRegion("))
        XCTAssertTrue(source.contains("coordinator.launchSelectedReads("))
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
}

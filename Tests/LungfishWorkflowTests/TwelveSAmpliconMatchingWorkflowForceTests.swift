import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import XCTest

/// An earlier 12S result must survive a run that fails or is refused, with
/// or without `--force`. The run may only remove the earlier output once
/// everything that can be refused has been accepted and every tool has
/// finished (Phase 2.1 lane L4, the "Added 17:45" item of the brief).
final class TwelveSAmpliconMatchingWorkflowForceTests: XCTestCase {

    private var root: URL!
    private var referenceURL: URL!
    private var fastqURL: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSForceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        referenceURL = root.appendingPathComponent("reference.fa")
        fastqURL = root.appendingPathComponent("sampleA.fastq")
        outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT

        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try Self.validReads.write(to: fastqURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let validReads = """
    @read1
    TTACGTACGTGG
    +
    IIIIIIIIIIII
    @read2
    TTAAAAAAAAGG
    +
    IIIIIIIIIIII

    """

    private func configuration(force: Bool) -> TwelveSAmpliconMatchingConfiguration {
        TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [fastqURL],
            referenceFASTA: referenceURL,
            outputDirectory: outputDirectory,
            outputName: "sampleA-12s",
            minimumSoftClipBases: 2,
            maximumIndelBases: 2,
            runChimeraReview: true,
            forceOverwrite: force
        )
    }

    /// Runs once with good inputs and returns the bundle the run wrote.
    private func writeEarlierOutput() async throws -> URL {
        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
            .run(configuration(force: false))
        return result.bundleURL
    }

    /// The earlier output is still a complete, loadable bundle with its counts.
    private func assertEarlierOutputSurvives(_ bundleURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path), "the earlier bundle is gone", file: file, line: line)
        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)
        XCTAssertEqual(loaded.readFate.totalReads, 2, file: file, line: line)
        XCTAssertEqual(loaded.readFate.exactMatchReads, 1, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.artifacts.provenanceURL.path), file: file, line: line)
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(bundleURL), "a run record was left behind", file: file, line: line)
    }

    /// Nothing but the bundle is left in the output folder.
    private func assertNoScratchBesideTheOutput(file: StaticString = #filePath, line: UInt = #line) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertEqual(contents.sorted(), ["sampleA-12s.lungfish12s"], file: file, line: line)
    }

    func testRunWithoutForceRefusesAnExistingOutputAndKeepsIt() async throws {
        let bundleURL = try await writeEarlierOutput()

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
                .run(configuration(force: false))
            XCTFail("a second run without --force must be refused")
        } catch let error as TwelveSAmpliconMatchingError {
            XCTAssertEqual(error, .outputExists(bundleURL.path))
        }

        try assertEarlierOutputSurvives(bundleURL)
        try assertNoScratchBesideTheOutput()
    }

    func testForcedRunReplacesAnEarlierOutputWhenItSucceeds() async throws {
        let bundleURL = try await writeEarlierOutput()
        let earlierCreatedAt = try TwelveSAmpliconResultBundle.loadManifest(from: bundleURL).createdAt

        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        @read2
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        @read3
        TTAAAAAAAAGG
        +
        IIIIIIIIIIII

        """.write(to: fastqURL, atomically: true, encoding: .utf8)
        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
            .run(configuration(force: true))

        XCTAssertEqual(result.bundleURL.path, bundleURL.path)
        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)
        XCTAssertEqual(loaded.readFate.totalReads, 3)
        XCTAssertEqual(loaded.readFate.exactMatchReads, 2)
        XCTAssertNotNil(earlierCreatedAt)
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(bundleURL))
        try assertNoScratchBesideTheOutput()
    }

    func testForcedRunWithAnEmptyReferenceKeepsTheEarlierOutput() async throws {
        let bundleURL = try await writeEarlierOutput()
        try "".write(to: referenceURL, atomically: true, encoding: .utf8)

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
                .run(configuration(force: true))
            XCTFail("an empty reference must be refused")
        } catch let error as TwelveSAmpliconMatchingError {
            XCTAssertEqual(error, .emptyReference(referenceURL.standardizedFileURL.path))
        }

        try assertEarlierOutputSurvives(bundleURL)
        try assertNoScratchBesideTheOutput()
    }

    func testForcedRunWithAnUnreadableInputKeepsTheEarlierOutput() async throws {
        let bundleURL = try await writeEarlierOutput()
        // A record cut after its sequence line is a truncated FASTQ.
        try "@read1\nTTACGTACGTGG\n+\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
                .run(configuration(force: true))
            XCTFail("a truncated input must fail the run")
        } catch {
            XCTAssertTrue(error is TwelveSFastqReaderError, "unexpected error \(error)")
        }

        try assertEarlierOutputSurvives(bundleURL)
        try assertNoScratchBesideTheOutput()
    }

    func testForcedRunWithAFailingChimeraReviewKeepsTheEarlierOutput() async throws {
        let bundleURL = try await writeEarlierOutput()

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: FailingChimeraReviewer())
                .run(configuration(force: true))
            XCTFail("a failed chimera review must fail the run")
        } catch let error as TwelveSChimeraReviewError {
            XCTAssertEqual(error, .vsearchFailed(exitCode: 1, stderr: "vsearch is not installed"))
        }

        try assertEarlierOutputSurvives(bundleURL)
        try assertNoScratchBesideTheOutput()
    }

    func testChimeraReviewFilesMoveIntoTheBundleAndItsRecordFollows() throws {
        let scratch = URL(fileURLWithPath: "/tmp/out/.lungfish-12s-scratch-abc/vsearch", isDirectory: true)
        let bundle = URL(fileURLWithPath: "/tmp/out/sampleA-12s.lungfish12s/vsearch", isDirectory: true)
        let review = TwelveSChimeraReviewResult(
            statusesBySequenceID: ["unresolved_1": .candidate],
            stderr: "vsearch v2",
            exitStatus: 0,
            argv: ["vsearch", "--uchime_denovo", scratch.appendingPathComponent("unresolved-for-vsearch.fasta").path, "--threads", "2"],
            inputs: [scratch.appendingPathComponent("unresolved-for-vsearch.fasta")],
            outputs: [scratch.appendingPathComponent("uchime-denovo.tsv"), URL(fileURLWithPath: "/elsewhere/kept.tsv")],
            toolVersion: "2"
        )

        let relocated = review.relocatingFiles(from: scratch, to: bundle)

        XCTAssertEqual(relocated.argv, ["vsearch", "--uchime_denovo", bundle.appendingPathComponent("unresolved-for-vsearch.fasta").path, "--threads", "2"])
        XCTAssertEqual(relocated.inputs.map(\.path), [bundle.appendingPathComponent("unresolved-for-vsearch.fasta").path])
        XCTAssertEqual(relocated.outputs.map(\.path), [bundle.appendingPathComponent("uchime-denovo.tsv").path, "/elsewhere/kept.tsv"])
        XCTAssertEqual(relocated.statusesBySequenceID, review.statusesBySequenceID)
        XCTAssertEqual(relocated.stderr, "vsearch v2")
        XCTAssertEqual(relocated.toolVersion, "2")
    }

    /// Review B, S3. Under `--force` the earlier output waits aside while the
    /// new bundle is written and comes back when writing fails. Here the
    /// reference, loaded before the earlier output is set aside, is gone when
    /// the bundle copies it, the first file the bundle writes.
    func testForcedRunWhoseBundleWriteFailsKeepsTheEarlierOutput() async throws {
        let bundleURL = try await writeEarlierOutput()
        let reference: URL = referenceURL

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
                .run(configuration(force: true)) { _, message in
                    if message == "Writing 12S result bundle tables." {
                        try? FileManager.default.removeItem(at: reference)
                    }
                }
            XCTFail("a bundle that cannot be written must fail the run")
        } catch {
            XCTAssertFalse(error is TwelveSAmpliconMatchingError, "unexpected refusal \(error)")
        }

        try assertEarlierOutputSurvives(bundleURL)
        try assertNoScratchBesideTheOutput()
    }

    /// Review A, N1. Two inputs that would be one sample, such as the
    /// `barcode01` bundles of two demultiplexed runs, are refused before
    /// anything is written, in one line that names both. Before, the run
    /// removed the earlier output and then trapped on the duplicate sample.
    func testTwoInputsThatAreOneSampleAreRefusedBeforeAnythingIsWritten() async throws {
        let bundleURL = try await writeEarlierOutput()
        let first = try demultiplexedBundle(inRun: "runA")
        let second = try demultiplexedBundle(inRun: "runB")

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
                TwelveSAmpliconMatchingConfiguration(
                    inputFASTQs: [first, second],
                    referenceFASTA: referenceURL,
                    outputDirectory: outputDirectory,
                    outputName: "sampleA-12s",
                    minimumSoftClipBases: 2,
                    maximumIndelBases: 2,
                    forceOverwrite: true
                )
            )
            XCTFail("two inputs that are one sample must be refused")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains(first.path), message)
            XCTAssertTrue(message.contains(second.path), message)
            XCTAssertTrue(message.contains("barcode01"), message)
            XCTAssertFalse(message.contains("\n"), message)
        }

        try assertEarlierOutputSurvives(bundleURL)
        try assertNoScratchBesideTheOutput()
    }

    /// A `barcode01` bundle as a demultiplexed run writes it, one file of reads.
    private func demultiplexedBundle(inRun run: String) throws -> URL {
        let bundle = root.appendingPathComponent("\(run)/demux/barcode01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.validReads.write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return bundle.standardizedFileURL
    }

    func testFailedFirstRunLeavesNothingBehind() async throws {
        try "".write(to: referenceURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        do {
            _ = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
                .run(configuration(force: false))
            XCTFail("an empty reference must be refused")
        } catch {}

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path), [])
    }
}

private struct FailingChimeraReviewer: TwelveSChimeraReviewing {
    func review(
        unresolvedSequences: [TwelveSUnresolvedSequence],
        outputDirectory: URL,
        threads: Int
    ) async throws -> TwelveSChimeraReviewResult {
        throw TwelveSChimeraReviewError.vsearchFailed(exitCode: 1, stderr: "vsearch is not installed")
    }
}

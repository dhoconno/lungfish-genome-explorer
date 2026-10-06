import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Tools must read a derived bundle's real reads, never the root bundle's
/// original reads (what the resolver returns) or the bundle's short preview.
final class DerivedFASTQBundleInputTests: XCTestCase {
    private var directory: URL!
    private var fixture: DerivedFASTQBundleFixture!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-input-\(UUID().uuidString)", isDirectory: true)
        fixture = try DerivedFASTQBundleFixture.make(in: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testResolverFlagsOnlyUnmaterializedDerivedBundles() {
        XCTAssertEqual(
            SequenceInputResolver.unmaterializedDerivedBundleURL(for: fixture.derivedBundleURL)?.standardizedFileURL,
            fixture.derivedBundleURL.standardizedFileURL)
        XCTAssertNil(SequenceInputResolver.unmaterializedDerivedBundleURL(for: fixture.rootBundleURL))
        XCTAssertNil(SequenceInputResolver.unmaterializedDerivedBundleURL(
            for: fixture.rootBundleURL.appendingPathComponent("pooled.fastq")))
    }

    func testReadableURLsMaterializeTheDerivedReads() async throws {
        let urls = try await DerivedFASTQBundleInput.readableURLs(
            for: fixture.derivedBundleURL, in: directory.appendingPathComponent("work"))
        XCTAssertEqual(urls.count, 1)
        let readableURL = try XCTUnwrap(urls.first)
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: readableURL), ["read1", "read3"])
        XCTAssertTrue(try String(contentsOf: readableURL, encoding: .utf8)
            .contains(DerivedFASTQBundleFixture.read3ReverseComplement))
    }

    func testReadableURLsLeaveRootBundlesAlone() async throws {
        let urls = try await DerivedFASTQBundleInput.readableURLs(
            for: fixture.rootBundleURL, in: directory.appendingPathComponent("work"),
            materializer: { _, _ in XCTFail("root bundles must not be materialized"); throw CancellationError() })
        XCTAssertEqual(urls.map(\.lastPathComponent), ["pooled.fastq"])
    }

    /// Every file of a bundle that holds several, in the order a tool reads
    /// them, and a file inside a bundle stands for its bundle.
    func testReadableURLsListEveryFileOfABundle() async throws {
        let readSets = try ReadSetFixtures(in: directory.appendingPathComponent("read-sets"))
        let work = directory.appendingPathComponent("work")
        let chunks = try await DerivedFASTQBundleInput.readableURLs(for: readSets.chunkedRoot, in: work)
        XCTAssertEqual(chunks.map(\.lastPathComponent), ["run_0.fastq", "run_1.fastq"])
        let chunkInside = try await DerivedFASTQBundleInput.readableURLs(
            for: readSets.chunkedRoot.appendingPathComponent("chunks/run_1.fastq"), in: work)
        XCTAssertEqual(chunkInside, chunks)
        let mates = try await DerivedFASTQBundleInput.readableURLs(for: readSets.pairedDerivative, in: work)
        XCTAssertEqual(mates.map(\.lastPathComponent), ["sample_R1.fastq", "sample_R2.fastq"])
    }

    // MARK: - ONT genotyping (lungfish-cli fastq ont-genotype)

    func testONTGenotypingMapsTheDerivedReads() async throws {
        let url = try await ONTGenotypingPipeline.executionInputFASTQ(
            for: fixture.derivedBundleURL, sampleDirectory: directory.appendingPathComponent("sample"))
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: url), ["read1", "read3"])
    }

    /// The hidden `fastq ont-genotype` maps every read a bundle holds, every
    /// chunk of a chunked root joined in import order and both mate files of
    /// a paired derivative, each read on its own. Before, it read the
    /// bundle's first file, chunk 0 or R1 (Phase 1 note N1).
    func testONTGenotypingMapsEveryFileOfABundle() async throws {
        let readSets = try ReadSetFixtures(in: directory.appendingPathComponent("read-sets"))
        let cases: [(bundle: URL, reads: [String])] = [
            (readSets.chunkedRoot, ["c1", "c2", "c3"]),
            (readSets.pairedDerivative, ["p1/1", "p2/1", "p1/2", "p2/2"]),
        ]
        for testCase in cases {
            let url = try await ONTGenotypingPipeline.executionInputFASTQ(
                for: testCase.bundle,
                sampleDirectory: directory.appendingPathComponent("sample-\(testCase.bundle.lastPathComponent)")
            )
            XCTAssertEqual(try ReadSetFixtures.readNames(in: url), testCase.reads, testCase.bundle.lastPathComponent)
        }
    }

    // MARK: - Full-length ONT MHC genotyping and Savont clustering

    func testFullLengthMaterializationUsesTheDerivedReadsNotThePreview() async throws {
        let output = directory.appendingPathComponent("sample/00-input.fastq")
        let result = try await FullLengthONTMHCFASTQMaterializer.materializeReadsAsPlainFASTQ(
            inputURL: fixture.derivedBundleURL, outputURL: output)
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: result.outputURL), ["read1", "read3"])
        XCTAssertTrue(result.step.inputs.contains { $0.path.hasSuffix("pooled-oriented.lungfishfastq/derived.manifest.json") },
            "the derived bundle must be recorded as an input")
    }

    func testSynchronousFullLengthMaterializationRefusesAVirtualBundle() {
        XCTAssertThrowsError(try FullLengthONTMHCFASTQMaterializer.materializePlainFASTQ(
            inputURL: fixture.derivedBundleURL,
            outputURL: directory.appendingPathComponent("out.fastq")))
    }

    func testFullLengthProvenanceDescribesTheRootReadsNotThePreview() throws {
        let descriptors = try FullLengthONTMHCFASTQMaterializer.provenanceSourceDescriptors(for: fixture.derivedBundleURL)
        let paths = descriptors.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("pooled.lungfishfastq/pooled.fastq") }, "\(paths)")
        XCTAssertFalse(paths.contains { $0.hasSuffix("preview.fastq") }, "\(paths)")
    }
}

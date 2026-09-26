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

    func testReadableURLMaterializesTheDerivedReads() async throws {
        let url = try await DerivedFASTQBundleInput.readableURL(
            for: fixture.derivedBundleURL, in: directory.appendingPathComponent("work"))
        let readableURL = try XCTUnwrap(url)
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: readableURL), ["read1", "read3"])
        XCTAssertTrue(try String(contentsOf: readableURL, encoding: .utf8)
            .contains(DerivedFASTQBundleFixture.read3ReverseComplement))
    }

    func testReadableURLLeavesRootBundlesAlone() async throws {
        let url = try await DerivedFASTQBundleInput.readableURL(
            for: fixture.rootBundleURL, in: directory.appendingPathComponent("work"),
            materializer: { _, _ in XCTFail("root bundles must not be materialized"); throw CancellationError() })
        XCTAssertEqual(url?.lastPathComponent, "pooled.fastq")
    }

    // MARK: - ONT genotyping (lungfish-cli fastq ont-genotype)

    func testONTGenotypingMapsTheDerivedReads() async throws {
        let url = try await ONTGenotypingPipeline.executionInputFASTQ(
            for: fixture.derivedBundleURL, sampleDirectory: directory.appendingPathComponent("sample"))
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: url), ["read1", "read3"])
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

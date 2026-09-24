import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

final class GenBankHumanReferenceDownloadTests: XCTestCase {
    func testHumanReferenceBuildPreservesVersionSourcesAndCompleteProvenance() async throws {
        let model = GenBankBundleDownloadViewModel(ncbiService: NCBIService(httpClient: HumanReferenceHTTPClient()))
        do { try await model.validateTools() }
        catch { throw XCTSkip("Managed bgzip and samtools are required: \(error)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try await model.downloadAndBuild(accession: "NM_000546.6", outputDirectory: root)
        XCTAssertTrue(bundle.lastPathComponent.contains("NM_000546.6"))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        XCTAssertEqual(envelope.options.resolvedDefaults["resolvedAccession"], .string("NM_000546.6"))
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertTrue(envelope.stderr?.contains("no usable annotation records") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("sources/record.gb").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("sources/record.gff3").path))
        for output in envelope.outputs {
            let url = URL(fileURLWithPath: output.path)
            XCTAssertEqual(output.checksumSHA256, try ProvenanceFileHasher.sha256(of: url))
            XCTAssertEqual(output.fileSize, try ProvenanceFileHasher.fileSize(of: url))
        }
        for name in ["bgzip", "samtools"] {
            let step = try XCTUnwrap(envelope.steps.first { $0.toolName == name })
            XCTAssertFalse(step.argv.isEmpty)
            XCTAssertNotEqual(step.toolVersion, "unknown")
            XCTAssertNotNil(step.runtimeIdentity?.condaEnvironment)
            XCTAssertNotNil(step.runtimeIdentity?.condaPrefix)
        }
        XCTAssertTrue(envelope.steps.contains { $0.toolName.contains("FASTAWriter") })
        XCTAssertTrue(envelope.steps.contains { $0.toolName.contains("createFromBED") })
        let copied = root.appendingPathComponent("stored.lungfishref")
        try FileManager.default.copyItem(at: bundle, to: copied)
        try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: bundle, to: copied)
        let relocated = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: copied))
        XCTAssertEqual(relocated.outputs.count, envelope.outputs.count)
        XCTAssertTrue(relocated.outputs.allSatisfy { $0.path.hasPrefix(copied.path + "/") })
    }
}

private actor HumanReferenceHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(parameters.first { $0.name == "id" }?.value, "NM_000546.6")
        let content: String
        if parameters.first(where: { $0.name == "rettype" })?.value == "gff3" {
            content = "##gff-version 3\n" // Exercise fallback without losing the response provenance.
        } else {
            // Deliberately shortened test data, not the biological TP53 sequence.
            content = """
            LOCUS       NM_000546                12 bp    mRNA    linear   PRI 01-JAN-2024
            DEFINITION  Human TP53 transcript, shortened test fixture.
            ACCESSION   NM_000546
            VERSION     NM_000546.6
            SOURCE      Homo sapiens
              ORGANISM  Homo sapiens
            FEATURES             Location/Qualifiers
                 gene            1..12
                                 /gene="TP53"
            ORIGIN
                    1 acgtacgtacgt
            //
            """
        }
        return (Data(content.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

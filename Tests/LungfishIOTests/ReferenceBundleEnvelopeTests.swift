import Foundation
import XCTest
@testable import LungfishIO

final class ReferenceBundleEnvelopeTests: XCTestCase {
    private func makeTempDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMHCBundleURLRequiresManifestPresence() throws {
        let root = try makeTempDirectory("ReferenceBundleEnvelopeTests-mhc-presence")
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Directory has the right extension but no manifest yet.
        XCTAssertFalse(MHCAmpliconReferenceBundle.isBundleURL(bundleURL))

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(bundleURL))
    }

    func testMHCManifestUsesSchemaVersionAndKind() throws {
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )

        XCTAssertEqual(manifest.kind, "mhc-reference")

        let data = try JSONEncoder().encode(manifest)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertTrue(json.keys.contains("schemaVersion"))
        XCTAssertEqual(json["kind"] as? String, "mhc-reference")
        XCTAssertFalse(json.keys.contains("formatVersion"))
    }

    func testValidationReportsMissingFASTA() throws {
        let root = try makeTempDirectory("ReferenceBundleEnvelopeTests-mhc-missing-fasta")
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "missing-reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertThrowsError(try MHCAmpliconReferenceBundle.validate(at: bundleURL)) { error in
            guard let validationError = error as? ReferenceBundleValidationError else {
                return XCTFail("Expected ReferenceBundleValidationError, got \(error)")
            }
            let expectedPath = bundleURL.appendingPathComponent("missing-reference.fa").path
            XCTAssertEqual(validationError.kind, .missingFile(expectedPath))
            let message = try? XCTUnwrap(validationError.errorDescription)
            XCTAssertTrue(
                (message ?? "").contains(expectedPath),
                "Validation message should name the missing path: \(message ?? "nil")"
            )
        }
    }

    func testEnvelopeHasBundleExtensionIgnoresManifestPresence() throws {
        let root = try makeTempDirectory("ReferenceBundleEnvelopeTests-extension")
        let bundleURL = root.appendingPathComponent("output.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // No manifest written, but extension matches.
        XCTAssertTrue(
            ReferenceBundleEnvelope.hasBundleExtension(bundleURL, directoryExtension: "lungfishmhcref")
        )
        XCTAssertFalse(
            ReferenceBundleEnvelope.isBundleURL(
                bundleURL,
                directoryExtension: "lungfishmhcref",
                manifestFilename: "mhc-reference.json"
            )
        )
    }
}

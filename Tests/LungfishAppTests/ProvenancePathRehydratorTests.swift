import XCTest
@testable import LungfishApp

final class ProvenancePathRehydratorTests: XCTestCase {
    func testRehydratesCopiedBundleInternalAndAdjacentProvenancePaths() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceBundle = temp.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let destinationBundle = temp.appendingPathComponent("Project/Source copy.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationBundle.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourcePayload = sourceBundle.appendingPathComponent("reads/SRR.fastq")
        try FileManager.default.createDirectory(at: sourcePayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@r\nACGT\n+\n!!!!\n".write(to: sourcePayload, atomically: true, encoding: .utf8)

        let internalProvenance = sourceBundle.appendingPathComponent(".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "bundle": sourceBundle.standardizedFileURL.path,
                "outputs": [
                    ["path": sourcePayload.standardizedFileURL.path]
                ],
                "argv": ["lungfish-cli", "import", "fastq", sourcePayload.standardizedFileURL.path],
                "command": "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)",
                "reproducibleCommand": "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: internalProvenance)

        let adjacentSidecar = URL(fileURLWithPath: sourceBundle.standardizedFileURL.path + ".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "outputs": [
                    ["path": sourceBundle.standardizedFileURL.path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: adjacentSidecar)

        try FileManager.default.copyItem(at: sourceBundle, to: destinationBundle)

        ProvenancePathRehydrator.rehydrate(from: sourceBundle, to: destinationBundle)

        let rewritten = try JSONSerialization.jsonObject(
            with: Data(contentsOf: destinationBundle.appendingPathComponent(".lungfish-provenance.json"))
        ) as? [String: Any]
        let outputs = rewritten?["outputs"] as? [[String: Any]]
        XCTAssertEqual(rewritten?["bundle"] as? String, destinationBundle.standardizedFileURL.path)
        XCTAssertEqual(
            outputs?.first?["path"] as? String,
            destinationBundle.appendingPathComponent("reads/SRR.fastq").standardizedFileURL.path
        )
        XCTAssertEqual(
            rewritten?["command"] as? String,
            "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)"
        )
        XCTAssertEqual(
            rewritten?["reproducibleCommand"] as? String,
            "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)"
        )
        XCTAssertEqual(
            rewritten?["argv"] as? [String],
            ["lungfish-cli", "import", "fastq", sourcePayload.standardizedFileURL.path]
        )

        let destinationSidecar = URL(fileURLWithPath: destinationBundle.standardizedFileURL.path + ".lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationSidecar.path))
    }

    func testWrappedFASTQSidecarIsRehydratedIntoBundleRootProvenance() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-FASTQ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceFASTQ = temp.appendingPathComponent("download.fastq")
        try "@r\nACGT\n+\n!!!!\n".write(to: sourceFASTQ, atomically: true, encoding: .utf8)
        let sourceSidecar = URL(fileURLWithPath: sourceFASTQ.standardizedFileURL.path + ".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "outputs": [
                    ["path": sourceFASTQ.standardizedFileURL.path]
                ],
                "command": "lungfish-cli fetch ncbi SRR123 --save-to \(sourceFASTQ.standardizedFileURL.path)",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: sourceSidecar)

        let bundleURL = temp.appendingPathComponent("download.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let bundledFASTQ = bundleURL.appendingPathComponent("download.fastq")
        try FileManager.default.copyItem(at: sourceFASTQ, to: bundledFASTQ)

        ProvenancePathRehydrator.rehydrate(from: sourceFASTQ, to: bundledFASTQ)

        let bundleProvenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleProvenanceURL.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: bundleProvenanceURL)) as? [String: Any]
        let outputs = json?["outputs"] as? [[String: Any]]
        XCTAssertEqual(outputs?.first?["path"] as? String, bundledFASTQ.standardizedFileURL.path)
        XCTAssertEqual(
            json?["command"] as? String,
            "lungfish-cli fetch ncbi SRR123 --save-to \(sourceFASTQ.standardizedFileURL.path)"
        )
    }

    func testRehydratesTypedFileParameterValuesWithoutChangingTypedStrings() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-Typed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceFASTQ = temp.appendingPathComponent("reads.fastq")
        let destinationFASTQ = temp.appendingPathComponent("Project/Downloads/reads.fastq")
        try FileManager.default.createDirectory(
            at: destinationFASTQ.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "@r\nACGT\n+\n!!!!\n".write(to: sourceFASTQ, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: sourceFASTQ, to: destinationFASTQ)

        let sourceSidecar = URL(fileURLWithPath: sourceFASTQ.standardizedFileURL.path + ".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "parameters": [
                    "input": [
                        "type": "file",
                        "value": sourceFASTQ.standardizedFileURL.path,
                    ],
                    "notes": [
                        "type": "string",
                        "value": sourceFASTQ.standardizedFileURL.path,
                    ],
                    "nestedInputs": [
                        "type": "array",
                        "value": [
                            [
                                "type": "file",
                                "value": sourceFASTQ.standardizedFileURL.path,
                            ],
                        ],
                    ],
                ],
                "command": "lungfish-cli import fastq \(sourceFASTQ.standardizedFileURL.path)",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: sourceSidecar)

        ProvenancePathRehydrator.rehydrate(from: sourceFASTQ, to: destinationFASTQ)

        let destinationSidecar = URL(fileURLWithPath: destinationFASTQ.standardizedFileURL.path + ".lungfish-provenance.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: destinationSidecar)) as? [String: Any]
        let parameters = json?["parameters"] as? [String: Any]
        let input = parameters?["input"] as? [String: Any]
        let notes = parameters?["notes"] as? [String: Any]
        let nestedInputs = parameters?["nestedInputs"] as? [String: Any]
        let nestedValue = nestedInputs?["value"] as? [[String: Any]]

        XCTAssertEqual(input?["value"] as? String, destinationFASTQ.standardizedFileURL.path)
        XCTAssertEqual(notes?["value"] as? String, sourceFASTQ.standardizedFileURL.path)
        XCTAssertEqual(nestedValue?.first?["value"] as? String, destinationFASTQ.standardizedFileURL.path)
        XCTAssertEqual(
            json?["command"] as? String,
            "lungfish-cli import fastq \(sourceFASTQ.standardizedFileURL.path)"
        )
    }
}

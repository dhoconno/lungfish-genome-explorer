import CryptoKit
import XCTest
@testable import LungfishIO

final class ONTMHCReferenceVisualizationTests: XCTestCase {
    func testAnnotatedKnownRecordRoundTripsAndIndexesByRawReferenceID() throws {
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [makeRecord()]
        )

        XCTAssertEqual(
            artifact.recordsByRawReferenceID["NHP00344"]?.alleleName,
            "Mafa-E*02:01:01"
        )
        XCTAssertEqual(
            artifact.recordsByKnownCallGenotype["NHP00344"]?.rawReferenceID,
            "NHP00344"
        )
        XCTAssertEqual(
            artifact.recordsByKnownCallGenotype["Mafa-E*02:01:01"]?.rawReferenceID,
            "NHP00344"
        )
        XCTAssertEqual(artifact.records[0].features[0].interval, 0..<4)

        let data = try JSONEncoder().encode(artifact)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["recordsByRawReferenceID"])
        XCTAssertNil(json["records_by_raw_reference_id"])
        XCTAssertNil(json["recordsByKnownCallGenotype"])
        XCTAssertNil(json["records_by_known_call_genotype"])

        let decoded = try JSONDecoder().decode(ONTMHCReferenceVisualizationArtifact.self, from: data)
        XCTAssertEqual(try decoded.validated(), artifact)
        XCTAssertEqual(decoded.recordsByRawReferenceID["NHP00344"], decoded.records[0])
        XCTAssertEqual(
            decoded.recordsByKnownCallGenotype["Mafa-E*02:01:01"],
            decoded.records[0]
        )
    }

    func testDuplicateRawReferenceIDsThrowFocusedValidationError() {
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [makeRecord(), makeRecord(alleleName: "Mafa-E*02:01:02")]
        )

        assertValidationError(
            .duplicateRawReferenceID("NHP00344"),
            from: try artifact.validated()
        )
        XCTAssertEqual(artifact.records.count, 2)
    }

    func testAmbiguousKnownCallAlleleAliasDoesNotConflateDistinctRawReferences() {
        let alleleName = "Mafa-E*02:01:01"
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [
                makeRecord(rawReferenceID: "NHP00344", alleleName: alleleName),
                makeRecord(rawReferenceID: "NHP00999", alleleName: alleleName),
            ]
        )

        XCTAssertEqual(
            artifact.recordsByKnownCallGenotype["NHP00344"]?.rawReferenceID,
            "NHP00344"
        )
        XCTAssertEqual(
            artifact.recordsByKnownCallGenotype["NHP00999"]?.rawReferenceID,
            "NHP00999"
        )
        XCTAssertNil(artifact.recordsByKnownCallGenotype[alleleName])
    }

    func testOutOfBoundsFeatureThrowsFocusedValidationError() {
        let feature = makeFeature(start: 0, end: 5)
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [makeRecord(features: [feature])]
        )

        assertValidationError(
            .featureOutOfBounds(
                rawReferenceID: "NHP00344",
                featureSourceOrdinal: 1,
                start: 0,
                end: 5,
                sequenceLength: 4
            ),
            from: try artifact.validated()
        )
    }

    func testFeatureBoundsUseSequenceCharacterCountRatherThanUTF8ByteCount() {
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [
                makeRecord(
                    sequence: "Aé",
                    features: [makeFeature(start: 2, end: 3)]
                )
            ]
        )

        assertValidationError(
            .featureOutOfBounds(
                rawReferenceID: "NHP00344",
                featureSourceOrdinal: 1,
                start: 2,
                end: 3,
                sequenceLength: 2
            ),
            from: try artifact.validated()
        )
    }

    func testMismatchedSequenceSHA256ThrowsFocusedValidationError() {
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [makeRecord(sequenceSHA256: String(repeating: "0", count: 64))]
        )

        assertValidationError(
            .sequenceChecksumMismatch(
                rawReferenceID: "NHP00344",
                expected: String(repeating: "0", count: 64),
                actual: Self.sha256(Data("ACGT".utf8))
            ),
            from: try artifact.validated()
        )
    }

    func testEmptyRoleListThrowsFocusedValidationError() {
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [makeRecord(roles: [])]
        )

        assertValidationError(
            .emptyRoles(rawReferenceID: "NHP00344"),
            from: try artifact.validated()
        )
    }

    func testEmptyRawReferenceIDThrowsFocusedValidationError() {
        let artifact = ONTMHCReferenceVisualizationArtifact(
            schemaVersion: 1,
            records: [makeRecord(rawReferenceID: "")]
        )

        assertValidationError(
            .emptyRawReferenceID(sourceOrdinal: 3),
            from: try artifact.validated()
        )
    }

    func testResultLoaderRetainsDeclaredJSONWithoutReadingCompanionArtifacts() throws {
        let fixture = try ResultBundleFixture(referenceArtifactData: encodedArtifact())
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(
            result.mhcReferenceVisualizations?.recordsByRawReferenceID["NHP00344"]?.alleleName,
            "Mafa-E*02:01:01"
        )
    }

    func testResultLoaderLeavesLegacyBundleReferenceVisualizationNil() throws {
        let fixture = try ResultBundleFixture(referenceArtifactData: nil)
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcReferenceVisualizations)
    }

    func testResultLoaderThrowsForMissingDeclaredReferenceVisualizationJSON() throws {
        let fixture = try ResultBundleFixture(referenceArtifactData: encodedArtifact())
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.referenceArtifactURL)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testResultLoaderThrowsForChecksumInvalidReferenceVisualizationJSON() throws {
        let fixture = try ResultBundleFixture(referenceArtifactData: encodedArtifact())
        defer { fixture.remove() }
        var damagedData = try Data(contentsOf: fixture.referenceArtifactURL)
        damagedData[damagedData.startIndex] ^= 0x01
        try damagedData.write(to: fixture.referenceArtifactURL)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
            XCTAssertTrue(
                error.localizedDescription.contains(fixture.referenceArtifactURL.lastPathComponent)
            )
        }
    }

    func testResultLoaderThrowsForMalformedReferenceVisualizationJSON() throws {
        let fixture = try ResultBundleFixture(referenceArtifactData: Data("{".utf8))
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testResultLoaderRejectsDescriptorRecordCountMismatchWithFocusedError() throws {
        let fixture = try ResultBundleFixture(
            referenceArtifactData: encodedArtifact(),
            declaredReferenceRecordCount: 2
        )
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) { error in
            XCTAssertEqual(
                error as? ONTMHCReferenceVisualizationError,
                .descriptorRecordCountMismatch(expected: 2, actual: 1)
            )
            XCTAssertTrue(
                error.localizedDescription.contains("declares 2 records, but the validated document contains 1"),
                error.localizedDescription
            )
        }
    }

    private func assertValidationError<T>(
        _ expected: ONTMHCReferenceVisualizationError,
        from expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ONTMHCReferenceVisualizationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func encodedArtifact() throws -> Data {
        try JSONEncoder().encode(
            ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: [makeRecord()])
        )
    }

    private func makeRecord(
        rawReferenceID: String = "NHP00344",
        alleleName: String = "Mafa-E*02:01:01",
        sequence: String = "ACGT",
        sequenceSHA256: String? = nil,
        features: [ONTMHCReferenceVisualizationFeature]? = nil,
        roles: [ONTMHCReferenceVisualizationRoleAssignment]? = nil
    ) -> ONTMHCReferenceVisualizationRecord {
        return ONTMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            sourceOrdinal: 3,
            alleleName: alleleName,
            locus: "Mafa-E",
            sequence: sequence,
            sequenceSHA256: sequenceSHA256 ?? Self.sha256(Data(sequence.utf8)),
            recordFields: ["definition": ["Mafa-E allele"]],
            features: features ?? [makeFeature()],
            annotatedTranslation: "T",
            genBankText: "LOCUS       NHP00344 4 bp DNA\n//\n",
            fastaText: ">NHP00344 Mafa-E*02:01:01\nACGT\n",
            roles: roles ?? [
                ONTMHCReferenceVisualizationRoleAssignment(
                    role: .exactKnownCall,
                    candidateStableClusterIDs: []
                )
            ]
        )
    }

    private func makeFeature(
        start: Int = 0,
        end: Int = 4
    ) -> ONTMHCReferenceVisualizationFeature {
        ONTMHCReferenceVisualizationFeature(
            type: "CDS",
            start: start,
            end: end,
            strand: "+",
            sourceOrdinal: 1,
            rawGenBankLocation: "1..4",
            qualifiers: ["translation": ["T"]]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class ResultBundleFixture {
        let rootURL: URL
        let bundleURL: URL
        let referenceArtifactURL: URL

        init(
            referenceArtifactData: Data?,
            declaredReferenceRecordCount: Int = 1
        ) throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MHCReferenceVisualizationFixture-\(UUID().uuidString)")
            bundleURL = rootURL.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let workbookURL = bundleURL.appendingPathComponent("result.xlsx")
            let callsURL = bundleURL.appendingPathComponent("calls.csv")
            let samplesURL = bundleURL.appendingPathComponent("samples.csv")
            let statsURL = bundleURL.appendingPathComponent("stats.json")
            let provenanceURL = bundleURL.appendingPathComponent("provenance.json")
            referenceArtifactURL = bundleURL.appendingPathComponent("mhc-reference-visualizations.json")

            try Data("workbook".utf8).write(to: workbookURL)
            try Data("sample,genotype,passed_alignments,passed_unique_reads\nSampleA,NHP00344,8,8\n".utf8)
                .write(to: callsURL)
            try Data("sample,passed_alignments,passed_unique_reads\nSampleA,8,8\n".utf8)
                .write(to: samplesURL)
            try Data("{}".utf8).write(to: statsURL)
            try Data("{}".utf8).write(to: provenanceURL)

            let descriptor: ONTMHCReferenceVisualizationArtifacts?
            if let referenceArtifactData {
                try referenceArtifactData.write(to: referenceArtifactURL)
                descriptor = ONTMHCReferenceVisualizationArtifacts(
                    schemaVersion: 1,
                    recordCount: 1,
                    recordsJSON: Self.reference(
                        path: referenceArtifactURL.lastPathComponent,
                        data: referenceArtifactData
                    ),
                    genBank: ONTMHCArtifactReference(
                        path: "not-loaded.gb",
                        sha256: String(repeating: "0", count: 64),
                        sizeBytes: 999
                    ),
                    fasta: ONTMHCArtifactReference(
                        path: "not-loaded.fasta",
                        sha256: String(repeating: "0", count: 64),
                        sizeBytes: 999
                    )
                )
            } else {
                descriptor = nil
            }

            let manifest = ONTGenotypeResultBundleManifest(
                outputName: "result",
                analysisName: "result",
                primaryWorkbookPath: workbookURL.lastPathComponent,
                longSummaryCSVPath: callsURL.lastPathComponent,
                sampleSummaryCSVPath: samplesURL.lastPathComponent,
                statsJSONPath: statsURL.lastPathComponent,
                provenancePath: provenanceURL.lastPathComponent,
                mhcReferenceVisualizations: descriptor
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
            if referenceArtifactData != nil {
                let manifestURL = ONTGenotypeResultBundle.manifestURL(in: bundleURL)
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
                )
                var visualizations = try XCTUnwrap(
                    object["mhcReferenceVisualizations"] as? [String: Any]
                )
                visualizations["record_count"] = declaredReferenceRecordCount
                object["mhcReferenceVisualizations"] = visualizations
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    .write(to: manifestURL, options: .atomic)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        private static func reference(path: String, data: Data) -> ONTMHCArtifactReference {
            ONTMHCArtifactReference(
                path: path,
                sha256: sha256(data),
                sizeBytes: Int64(data.count)
            )
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

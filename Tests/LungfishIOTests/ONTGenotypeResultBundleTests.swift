import CryptoKit
import Darwin
import Foundation
import LungfishCore
import XCTest
@testable import LungfishIO

final class ONTGenotypeResultBundleTests: XCTestCase {
    func testNativeGenotypeMatrixContentRecognizesConventionalCalls() {
        let result = makeResult(calls: [
            makeCall(sample: "S1", genotype: "Mafa-A1*001:01", uniqueReads: 7),
        ])

        XCTAssertTrue(result.hasNativeGenotypeMatrixContent)
    }

    func testNativeGenotypeMatrixContentRecognizesReviewableCatalogRows() {
        let result = makeResult(
            calls: [],
            reviewableRowCatalog: reviewableRowCatalog()
        )

        XCTAssertTrue(result.hasNativeGenotypeMatrixContent)
    }

    func testNativeGenotypeMatrixContentRejectsEmptyResults() {
        let result = makeResult(calls: [], reviewableRowCatalog: nil)

        XCTAssertFalse(result.hasNativeGenotypeMatrixContent)
    }

    func testReviewableRowCatalogRoundTripsAndResolvesReferenceAndCandidateExactly() throws {
        let catalog = reviewableRowCatalog()

        let decoded = try JSONDecoder().decode(
            GenotypeReviewableRowCatalog.self,
            from: JSONEncoder().encode(catalog)
        )
        XCTAssertEqual(try decoded.validated(), catalog)
        XCTAssertNotEqual(decoded.rows[0].callID, decoded.rows[0].displayName)

        let resolver = try GenotypeReviewableRowResolver(catalog: decoded)
        let reference = try resolver.resolveFalseNegative(
            target: .cell(
                locus: "A1",
                genotype: "Mafa-A1*001:01",
                sample: "S1"
            ),
            requiresCohortZero: true
        )
        XCTAssertEqual(reference.callID, "reference:MHC-A:Mafa-A1*001:01")
        XCTAssertNil(reference.stableID)

        let candidate = try resolver.resolveFalseNegative(
            target: .cell(
                locus: "MHC-B",
                genotype: "Mafa-B*999:01_nov",
                sample: "S1",
                stableClusterID: "candidate-1"
            ),
            requiresCohortZero: false
        )
        XCTAssertEqual(candidate.callID, "candidate:MHC-B:candidate-1")
        XCTAssertEqual(candidate.stableID, "candidate-1")

        XCTAssertThrowsError(
            try resolver.resolveFalseNegative(
                target: .cell(
                    locus: "MHC-A",
                    genotype: reference.callID,
                    sample: "S1"
                ),
                requiresCohortZero: true
            )
        )
        XCTAssertThrowsError(
            try resolver.resolveFalseNegative(
                target: .cell(
                    locus: "MHC-B",
                    genotype: candidate.displayName,
                    sample: "S1",
                    stableClusterID: "candidate-2"
                ),
                requiresCohortZero: false
            )
        )
    }

    func testReviewableRowCatalogRejectsDuplicateSemanticIdentity() throws {
        let catalog = reviewableRowCatalog()
        let duplicate = GenotypeReviewableRowCatalog(
            schemaID: catalog.schemaID,
            schemaVersion: catalog.schemaVersion,
            samples: catalog.samples,
            rows: catalog.rows + [
                .init(
                    kind: .reference,
                    callID: catalog.rows[0].callID,
                    displayName: "A different presentation label",
                    locus: catalog.rows[0].locus,
                    stableID: nil,
                    section: "reference",
                    sortKey: "different-sort-key",
                    supportBySample: ["S1": 0, "S2": 0]
                ),
            ]
        )

        XCTAssertThrowsError(try duplicate.validated())
    }

    func testReviewableRowCatalogRejectsInvalidRosterAndEvidenceAuthority() {
        let catalog = reviewableRowCatalog()

        XCTAssertThrowsError(
            try GenotypeReviewableRowCatalog(
                schemaID: catalog.schemaID,
                schemaVersion: catalog.schemaVersion,
                samples: ["S1", "S1"],
                rows: catalog.rows
            ).validated()
        )
        XCTAssertThrowsError(
            try catalog.replacingSupport(
                row: 0,
                with: ["S1": 0, "S2": 0, "S3": 0]
            ).validated()
        )
        XCTAssertThrowsError(
            try catalog.replacingSupport(
                row: 0,
                with: ["S1": 0]
            ).validated()
        )
        XCTAssertThrowsError(
            try catalog.replacingSupport(
                row: 0,
                with: ["S1": -1, "S2": 0]
            ).validated()
        )
    }

    func testReviewableRowCatalogRejectsLegacyDuplicateEvidenceObjectKeys() {
        let data = Data(
            #"""
            {
              "schema_id": "org.lungfish.genotype.reviewable-row-catalog",
              "schema_version": 1,
              "samples": ["S1", "S2"],
              "rows": [{
                "kind": "reference",
                "call_id": "reference:MHC-A:Mafa-A1*001:01",
                "display_name": "Mafa-A1*001:01",
                "locus": "MHC-A",
                "section": "reference",
                "sort_key": "MHC-A|Mafa-A1*001:01",
                "support_by_sample": {"S1": 0, "S1": 7, "S2": 0}
              }]
            }
            """#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder()
                .decode(GenotypeReviewableRowCatalog.self, from: data)
                .validated()
        )
    }

    func testReviewableRowCatalogRejectsDuplicateEvidenceArrayRecordsPrecisely() {
        let data = Data(
            #"""
            {
              "schema_id": "org.lungfish.genotype.reviewable-row-catalog",
              "schema_version": 1,
              "samples": ["S1", "S2"],
              "rows": [{
                "kind": "reference",
                "call_id": "reference:MHC-A:Mafa-A1*001:01",
                "display_name": "Mafa-A1*001:01",
                "locus": "MHC-A",
                "section": "reference",
                "sort_key": "MHC-A|Mafa-A1*001:01",
                "support_by_sample": [
                  {"sample": "S1", "support": 0},
                  {"sample": "S1", "support": 7},
                  {"sample": "S2", "support": 0}
                ]
              }]
            }
            """#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(GenotypeReviewableRowCatalog.self, from: data)
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected duplicate-evidence data corruption, found \(error)")
            }
            XCTAssertTrue(context.debugDescription.localizedCaseInsensitiveContains("duplicate"))
            XCTAssertTrue(context.debugDescription.contains("S1"))
        }
    }

    func testReviewableRowCatalogCanonicalEncodingUsesSortedEvidenceRecords() throws {
        let catalog = reviewableRowCatalog()

        let first = try catalog.encoded()
        let second = try catalog.encoded()
        XCTAssertEqual(first, second)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let firstSupport = try XCTUnwrap(
            rows[0]["support_by_sample"] as? [[String: Any]]
        )
        XCTAssertEqual(firstSupport.compactMap { $0["sample"] as? String }, ["S1", "S2"])
        XCTAssertEqual(firstSupport.compactMap { $0["support"] as? Int }, [0, 0])

        let encodedText = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(encodedText.hasPrefix(#"{"rows":"#))
        XCTAssertTrue(encodedText.contains(#""support_by_sample":[{"sample":"S1","support":0},{"sample":"S2","support":0}]"#))
    }

    func testReviewableRowCatalogRejectsUnsupportedSchemaAndInvalidRowIdentity() {
        let catalog = reviewableRowCatalog()
        XCTAssertThrowsError(
            try GenotypeReviewableRowCatalog(
                schemaID: "org.example.future",
                schemaVersion: catalog.schemaVersion,
                samples: catalog.samples,
                rows: catalog.rows
            ).validated()
        )
        XCTAssertThrowsError(
            try GenotypeReviewableRowCatalog(
                schemaID: catalog.schemaID,
                schemaVersion: 2,
                samples: catalog.samples,
                rows: catalog.rows
            ).validated()
        )

        let referenceWithStableID = catalog.replacingRow(
            0,
            with: .init(
                kind: .reference,
                callID: "reference:MHC-A:Mafa-A1*001:01",
                displayName: "Mafa-A1*001:01",
                locus: "MHC-A",
                stableID: "not-allowed",
                section: "reference",
                sortKey: "MHC-A|Mafa-A1*001:01",
                supportBySample: ["S1": 0, "S2": 0]
            )
        )
        XCTAssertThrowsError(try referenceWithStableID.validated())

        let candidateWithoutStableID = catalog.replacingRow(
            1,
            with: .init(
                kind: .candidate,
                callID: "candidate:MHC-B:candidate-1",
                displayName: "Mafa-B*999:01_nov",
                locus: "MHC-B",
                stableID: nil,
                section: "candidate",
                sortKey: "MHC-B|Mafa-B*999:01_nov",
                supportBySample: ["S1": 0, "S2": 7]
            )
        )
        XCTAssertThrowsError(try candidateWithoutStableID.validated())

        let nonCanonicalLocus = catalog.replacingRow(
            0,
            with: .init(
                kind: .reference,
                callID: "reference:MHC-A:Mafa-A1*001:01",
                displayName: "Mafa-A1*001:01",
                locus: "A1",
                stableID: nil,
                section: "reference",
                sortKey: "MHC-A|Mafa-A1*001:01",
                supportBySample: ["S1": 0, "S2": 0]
            )
        )
        XCTAssertThrowsError(try nonCanonicalLocus.validated())
    }

    func testReviewableRowResolverRejectsNonzeroFalseNegativeEvidence() throws {
        let resolver = try GenotypeReviewableRowResolver(catalog: reviewableRowCatalog())

        XCTAssertThrowsError(
            try resolver.resolveFalseNegative(
                target: .cell(
                    locus: "MHC-B",
                    genotype: "Mafa-B*999:01_nov",
                    sample: "S2",
                    stableClusterID: "candidate-1"
                ),
                requiresCohortZero: false
            )
        )
        XCTAssertThrowsError(
            try resolver.resolveFalseNegative(
                target: .cell(
                    locus: "MHC-B",
                    genotype: "Mafa-B*999:01_nov",
                    sample: "S1",
                    stableClusterID: "candidate-1"
                ),
                requiresCohortZero: true
            )
        )
    }

    func testManifestRoundTripsReviewableRowCatalogDescriptor() throws {
        let descriptor = ONTMHCArtifactReference(
            path: "artifacts/reviewable-rows.json",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 412
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "catalog",
            analysisName: "Catalog",
            primaryWorkbookPath: "catalog.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            reviewableRowCatalog: descriptor
        )

        let decoded = try JSONDecoder().decode(
            ONTGenotypeResultBundleManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded.reviewableRowCatalog, descriptor)
    }

    func testLoadsManifestAttestedReviewableRowCatalogIntoBundleData() throws {
        let fixture = try makeReviewableRowCatalogBundle()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.reviewableRowCatalog, fixture.catalog)
    }

    func testReviewableRowCatalogArtifactRejectsTraversalSymlinkSizeAndChecksum() throws {
        for corruption in ReviewableCatalogCorruption.allCases {
            let fixture = try makeReviewableRowCatalogBundle(corruption: corruption)
            defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }

            XCTAssertThrowsError(
                try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL),
                "Expected \(corruption) to fail closed"
            )
        }
    }

    func testManifestRoundTripsTypedWorkflowDeclaration() throws {
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: "typed",
            analysisName: "Typed",
            primaryWorkbookPath: "typed.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )

        let decoded = try JSONDecoder().decode(
            ONTGenotypeResultBundleManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded.workflowKind, .fullLengthONTMHCGenotype)
        XCTAssertEqual(decoded.workflowMode, .genotypeOnly)
    }

    func testLegacyManifestDecodesWithoutTypedWorkflowDeclaration() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "kind": "full-length-ont-mhc-genotype",
          "outputName": "legacy",
          "analysisName": "Legacy",
          "primaryWorkbookPath": "legacy.xlsx",
          "longSummaryCSVPath": "calls.csv",
          "sampleSummaryCSVPath": "samples.csv",
          "statsJSONPath": "stats.json",
          "provenancePath": "provenance.json"
        }
        """#.utf8)

        let manifest = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertNil(manifest.workflowKind)
        XCTAssertNil(manifest.workflowMode)
    }

    func testUnknownWorkflowKindRemainsLoadableAndRoundTripsLosslessly() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unknown-workflow-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("unknown.xlsx")
        try Data("workbook".utf8).write(to: workbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: "unknown")
        let manifestData = Data(#"""
        {
          "schemaVersion": 1,
          "kind": "full-length-ont-mhc-genotype",
          "workflowKind": "future-mhc-workflow",
          "workflowMode": "genotypeOnly",
          "outputName": "unknown",
          "analysisName": "Unknown workflow fixture",
          "primaryWorkbookPath": "unknown.xlsx",
          "longSummaryCSVPath": "\#(artifacts.genotypeCSV.lastPathComponent)",
          "sampleSummaryCSVPath": "\#(artifacts.sampleCSV.lastPathComponent)",
          "statsJSONPath": "\#(artifacts.statsJSON.lastPathComponent)",
          "provenancePath": "\#(artifacts.provenance.lastPathComponent)"
        }
        """#.utf8)
        try manifestData.write(
            to: bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.manifest.analysisName, "Unknown workflow fixture")
        XCTAssertNil(result.manifest.workflowKind)
        XCTAssertEqual(
            result.manifest.workflowKindDeclaration.originalValue,
            .string("future-mhc-workflow")
        )
        XCTAssertTrue(
            try XCTUnwrap(result.manifest.workflowKindDeclaration.issue)
                .localizedCaseInsensitiveContains("future-mhc-workflow")
        )
        let roundTripped = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(result.manifest)
        ) as? [String: Any]
        XCTAssertEqual(roundTripped?["workflowKind"] as? String, "future-mhc-workflow")
    }

    func testWrongJSONTypeWorkflowModeRemainsLoadableAndIsNotCoerced() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "kind": "full-length-ont-mhc-genotype",
          "workflowKind": "full-length-ont-mhc-genotype",
          "workflowMode": {"unexpected": true},
          "outputName": "malformed",
          "analysisName": "Malformed",
          "primaryWorkbookPath": "malformed.xlsx",
          "longSummaryCSVPath": "calls.csv",
          "sampleSummaryCSVPath": "samples.csv",
          "statsJSONPath": "stats.json",
          "provenancePath": "provenance.json"
        }
        """#.utf8)

        let manifest = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertNil(manifest.workflowMode)
        XCTAssertEqual(
            manifest.workflowModeDeclaration.originalValue,
            .object(["unexpected": .bool(true)])
        )
        XCTAssertTrue(
            try XCTUnwrap(manifest.workflowModeDeclaration.issue)
                .localizedCaseInsensitiveContains("string")
        )
        let roundTripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        XCTAssertEqual((roundTripped["workflowMode"] as? [String: Bool])?["unexpected"], true)
    }

    func testNullWorkflowModeRemainsLoadableAndRoundTripsLosslessly() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "kind": "full-length-ont-mhc-genotype",
          "workflowKind": "full-length-ont-mhc-genotype",
          "workflowMode": null,
          "outputName": "null-mode",
          "analysisName": "Null mode",
          "primaryWorkbookPath": "null-mode.xlsx",
          "longSummaryCSVPath": "calls.csv",
          "sampleSummaryCSVPath": "samples.csv",
          "statsJSONPath": "stats.json",
          "provenancePath": "provenance.json"
        }
        """#.utf8)

        let manifest = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertNil(manifest.workflowMode)
        XCTAssertEqual(manifest.workflowModeDeclaration.originalValue, .null)
        XCTAssertTrue(
            try XCTUnwrap(manifest.workflowModeDeclaration.issue)
                .localizedCaseInsensitiveContains("string")
        )
        let roundTripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        XCTAssertTrue(roundTripped["workflowMode"] is NSNull)
    }

    func testOverflowSizedIntegerWorkflowModeRoundTripsWithoutPrecisionLoss() throws {
        let exactInteger = Decimal(string: "9223372036854775809")!
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "kind": "full-length-ont-mhc-genotype",
          "workflowKind": "full-length-ont-mhc-genotype",
          "workflowMode": 9223372036854775809,
          "outputName": "overflow-mode",
          "analysisName": "Overflow mode",
          "primaryWorkbookPath": "overflow-mode.xlsx",
          "longSummaryCSVPath": "calls.csv",
          "sampleSummaryCSVPath": "samples.csv",
          "statsJSONPath": "stats.json",
          "provenancePath": "provenance.json"
        }
        """#.utf8)

        let manifest = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)
        let encoded = try JSONEncoder().encode(manifest)
        let decodedNumber = try JSONDecoder().decode(
            WorkflowModeDecimalEnvelope.self,
            from: encoded
        )

        XCTAssertEqual(decodedNumber.workflowMode, exactInteger)
        XCTAssertNil(manifest.workflowMode)
        XCTAssertTrue(
            try XCTUnwrap(manifest.workflowModeDeclaration.issue)
                .localizedCaseInsensitiveContains("string")
        )
    }

    func testMHCCandidateDisplaySettingsDefaultToAllVisibleAndFourCanonicalTints() {
        let settings = ONTMHCCandidateDisplaySettings.default

        XCTAssertTrue(settings.showKnown)
        XCTAssertTrue(settings.showSharedCandidates)
        XCTAssertTrue(settings.showSingletonCandidates)
        XCTAssertEqual(Set(settings.tints.keys), Set(ONTMHCCandidateTintCategory.allCases))
        XCTAssertEqual(settings.tints[.sharedNovel]?.hexString, "#F5D78E")
        XCTAssertEqual(settings.tints[.singletonNovel]?.hexString, "#F5B97A")
        XCTAssertEqual(settings.tints[.sharedExtension]?.hexString, "#A8D8D0")
        XCTAssertEqual(settings.tints[.singletonExtension]?.hexString, "#AFCBF2")
    }

    func testMHCCandidateDisplaySettingsRoundTripInAnnotationSidecar() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay.showKnown = false
        sidecar.settings.mhcCandidateDisplay.showSingletonCandidates = false
        sidecar.settings.mhcCandidateDisplay.tints[.sharedNovel] = AnnotationColor(
            red: 0.123456789012345,
            green: 0.234567890123456,
            blue: 0.345678901234567,
            alpha: 0.456789012345678
        )

        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())

        XCTAssertEqual(decoded.settings.mhcCandidateDisplay, sidecar.settings.mhcCandidateDisplay)
    }

    func testLegacyAnnotationSidecarSynthesizesCandidateDisplayDefaults() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-20T00:00:00Z",
          "settings": {
            "viewMode": "outline",
            "panelLayout": "aLeading",
            "cardDensity": "auto",
            "cardDensityThreshold": 30,
            "dropoutAbsolute": 50,
            "dropoutLocusFraction": 0.01
          }
        }
        """#.utf8)

        let decoded = try GenotypeAnnotationSidecar.decode(data)

        XCTAssertEqual(decoded.settings.mhcCandidateDisplay, .default)
    }

    func testCandidateDisplayTintDecodeFillsMissingAndInvalidEntriesIndividually() throws {
        let data = Data(#"""
        {
          "showKnown": false,
          "showSharedCandidates": true,
          "showSingletonCandidates": false,
          "tints": {
            "sharedNovel": "#123456",
            "singletonNovel": "not-a-color",
            "futureCandidateKind": "#010203"
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(ONTMHCCandidateDisplaySettings.self, from: data)

        XCTAssertFalse(decoded.showKnown)
        XCTAssertTrue(decoded.showSharedCandidates)
        XCTAssertFalse(decoded.showSingletonCandidates)
        XCTAssertEqual(decoded.tints[.sharedNovel]?.hexString, "#123456")
        XCTAssertEqual(decoded.tints[.singletonNovel]?.hexString, "#F5B97A")
        XCTAssertEqual(decoded.tints[.sharedExtension]?.hexString, "#A8D8D0")
        XCTAssertEqual(decoded.tints[.singletonExtension]?.hexString, "#AFCBF2")
        XCTAssertEqual(decoded.tints.count, ONTMHCCandidateTintCategory.allCases.count)
    }

    func testAnnotationSidecarWriteRejectsSymlinkInsteadOfReplacingOrFollowingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-sidecar-symlink-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        let outside = root.appendingPathComponent("outside.json")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("outside-must-not-change".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename),
            withDestinationURL: outside
        )
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")

        XCTAssertThrowsError(try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundle))

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside-must-not-change".utf8))
    }

    func testAnnotationSidecarWriteRejectsSymlinkBundleRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-bundle-symlink-\(UUID().uuidString)", isDirectory: true)
        let realBundle = root.appendingPathComponent("real.lungfishgenotype", isDirectory: true)
        let linkedBundle = root.appendingPathComponent("linked.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: realBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: linkedBundle, withDestinationURL: realBundle)
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")

        XCTAssertThrowsError(
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: linkedBundle)
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: realBundle.appendingPathComponent(GenotypeAnnotationSidecar.filename).path
            )
        )
    }

    func testAnnotationSidecarLoadRejectsSymlinkInsteadOfReadingOutsideBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-load-symlink-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        let outside = root.appendingPathComponent("outside.json")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GenotypeAnnotationSidecar.empty(generatedAt: "outside").encoded().write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        )
    }

    @MainActor
    func testAsyncCandidateLoaderYieldsMainActorBeforeCompleting() async throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        var heartbeatRan = false
        DispatchQueue.main.async { heartbeatRan = true }

        let result = try await ONTGenotypeResultBundle.loadResultAsync(from: fixture.bundleURL)

        XCTAssertTrue(heartbeatRan, "Async bundle validation must not hash candidate evidence on the main actor")
        XCTAssertEqual(result.calls.count, 1)
    }

    func testCancelledAsyncCandidateLoaderThrowsCancellation() async throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        let bundleURL = fixture.bundleURL
        let task = Task {
            try await ONTGenotypeResultBundle.loadResultAsync(from: bundleURL)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testLoadsValidMHCCandidateDocumentsAndChecksummedEvidence() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.map(\.genotype), ["known-allele"])
        XCTAssertEqual(result.mhcCandidates?.candidates.map(\.stableClusterID), [fixture.candidateID])
        XCTAssertEqual(result.mhcUnnameableClusters?.clusters.map(\.stableClusterID), [fixture.unnameableID])
        XCTAssertEqual(
            result.mhcAlignmentArtifactURLs,
            ONTMHCAlignmentArtifactURLs(
                genotypingBAM: fixture.bundleURL.appendingPathComponent(
                    "artifacts/alignments/genotyping.bam"
                ),
                genotypingBAI: fixture.bundleURL.appendingPathComponent(
                    "artifacts/alignments/genotyping.bam.bai"
                ),
                reciprocalBAM: fixture.bundleURL.appendingPathComponent(
                    "artifacts/alignments/reciprocal.bam"
                ),
                reciprocalBAI: fixture.bundleURL.appendingPathComponent(
                    "artifacts/alignments/reciprocal.bam.bai"
                )
            )
        )
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testNonFullLengthManifestDoesNotProjectMHCCandidateArtifacts() throws {
        let fixture = try CandidateBundleFixture(kind: "ont-barcode-genotype")
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertTrue(result.mhcCandidateSequencesByStableClusterID.isEmpty)
        XCTAssertEqual(result.mhcCandidateGenBankArtifactURLs, .empty)
        XCTAssertEqual(result.mhcAlignmentArtifactURLs, .empty)
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testLoadsValidatedGenericGenotypingEvidence() throws {
        let fixture = try ScientificArtifactBundleFixture()
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.alignmentArtifactURLs.genotypingBAM, fixture.bamURL.standardizedFileURL)
        XCTAssertEqual(result.alignmentArtifactURLs.genotypingBAI, fixture.baiURL.standardizedFileURL)
        XCTAssertNil(result.alignmentArtifactURLs.reciprocalBAM)
        XCTAssertNil(result.alignmentArtifactURLs.reciprocalBAI)
    }

    func testLoadsValidatedProvisionalExon2Catalog() throws {
        let fixture = try ScientificArtifactBundleFixture()
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        let sequence = try XCTUnwrap(
            result.provisionalExon2SequencesByGenotype[ScientificArtifactBundleFixture.provisionalGenotype]
        )

        XCTAssertEqual(sequence.designation, "Provisional exon 2")
        XCTAssertEqual(sequence.sequence, "ACGT")
        XCTAssertEqual(sequence.locus, "MHC-E")
        XCTAssertEqual(sequence.sampleSupport, [
            ONTGenotypeProvisionalExon2SampleSupport(
                sample: "SampleA",
                passedAlignments: 9,
                passedUniqueReads: 8
            ),
        ])
        XCTAssertEqual(
            result.provisionalExon2ArtifactURLs.catalogJSON,
            fixture.catalogURL.standardizedFileURL
        )
        XCTAssertEqual(
            result.provisionalExon2ArtifactURLs.sequencesFASTA,
            fixture.fastaURL.standardizedFileURL
        )
    }

    func testLoadsPublisherAggregatedProvisionalSupportFromRepeatedCallRows() throws {
        let fixture = try ScientificArtifactBundleFixture()
        defer { fixture.remove() }
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        SampleA,\(ScientificArtifactBundleFixture.provisionalGenotype),4,3
        SampleA,\(ScientificArtifactBundleFixture.provisionalGenotype),5,5
        """.write(
            to: fixture.bundleURL.appendingPathComponent("miseq-genotypes.csv"),
            atomically: true,
            encoding: .utf8
        )

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(
            result.provisionalExon2SequencesByGenotype[
                ScientificArtifactBundleFixture.provisionalGenotype
            ]?.sampleSupport,
            ScientificArtifactBundleFixture.defaultRecord.sampleSupport
        )
    }

    func testRejectsInvalidProvisionalExon2DuplicateGenotype() throws {
        let duplicate = ScientificArtifactBundleFixture.defaultRecord
        let fixture = try ScientificArtifactBundleFixture(records: [duplicate, duplicate])
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testRejectsProvisionalGenotypesSharingOneFASTARecord() throws {
        let secondGenotype = "Mafa-E_02_nov_18"
        let secondRecord = ONTGenotypeProvisionalExon2Record(
            genotype: secondGenotype,
            locus: "MHC-E",
            fastaRecordID: ScientificArtifactBundleFixture.provisionalGenotype,
            sequenceLength: 4,
            sequenceSHA256: ScientificArtifactBundleFixture.sequenceSHA256,
            sampleSupport: ScientificArtifactBundleFixture.defaultRecord.sampleSupport
        )
        let fixture = try ScientificArtifactBundleFixture(records: [
            ScientificArtifactBundleFixture.defaultRecord,
            secondRecord,
        ])
        defer { fixture.remove() }
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        SampleA,\(ScientificArtifactBundleFixture.provisionalGenotype),9,8
        SampleA,\(secondGenotype),9,8
        """.write(
            to: fixture.bundleURL.appendingPathComponent("miseq-genotypes.csv"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? ONTGenotypeScientificArtifactError,
                .duplicateFASTARecord(
                    ScientificArtifactBundleFixture.provisionalGenotype
                )
            )
        }
    }

    func testRejectsInvalidProvisionalExon2SequenceMismatch() throws {
        let fixture = try ScientificArtifactBundleFixture(fastaSequence: "TGCA")
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testRejectsInvalidProvisionalExon2NonNovelIdentifier() throws {
        let record = ONTGenotypeProvisionalExon2Record(
            genotype: "Mafa-E*02:01",
            locus: "MHC-E",
            fastaRecordID: "Mafa-E*02:01",
            sequenceLength: 4,
            sequenceSHA256: ScientificArtifactBundleFixture.sequenceSHA256,
            sampleSupport: ScientificArtifactBundleFixture.defaultRecord.sampleSupport
        )
        let fixture = try ScientificArtifactBundleFixture(
            genotype: "Mafa-E*02:01",
            records: [record],
            fastaRecordID: "Mafa-E*02:01"
        )
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testRejectsInvalidProvisionalExon2CatalogCallAbsentFromResults() throws {
        let fixture = try ScientificArtifactBundleFixture(genotype: "Mafa-E*02:01")
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testRejectsGenericAlignmentArtifactTraversal() throws {
        let fixture = try ScientificArtifactBundleFixture(alignmentBAMPath: "../outside.bam")
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testRejectsGenericAlignmentArtifactChecksumMismatch() throws {
        let fixture = try ScientificArtifactBundleFixture(corruptBAMChecksum: true)
        defer { fixture.remove() }

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL))
    }

    func testLoadsRepresentativeProvisionalCatalogAsynchronouslyWithinBudget() async throws {
        let fixture = try ScientificArtifactBundleFixture(
            bulkRecordCount: 100
        )
        defer { fixture.remove() }

        let startedAt = Date()
        let result = try await ONTGenotypeResultBundle.loadResultAsync(
            from: fixture.bundleURL
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.provisionalExon2SequencesByGenotype.count, 100)
        XCTAssertLessThan(
            elapsed,
            2.0,
            "Catalog and FASTA validation should remain a one-pass off-main load"
        )
    }

    func testRepeatedLoadsReuseValidatedUnchangedAlignmentArtifactDigests() throws {
        let fixture = try ScientificArtifactBundleFixture()
        defer { fixture.remove() }
        ONTGenotypeResultBundle.resetArtifactValidationCacheForTesting()

        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        let firstPassCount =
            ONTGenotypeResultBundle.artifactValidationHashingPassCountForTesting
        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(firstPassCount, 2)
        XCTAssertEqual(
            ONTGenotypeResultBundle.artifactValidationHashingPassCountForTesting,
            firstPassCount,
            "An unchanged BAM/BAI pair should not be hashed again on the next bundle load"
        )
    }

    func testAlignmentArtifactDigestCacheInvalidatesAfterSameSizeMutation() throws {
        let fixture = try ScientificArtifactBundleFixture()
        defer { fixture.remove() }
        ONTGenotypeResultBundle.resetArtifactValidationCacheForTesting()
        _ = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        let original = try Data(contentsOf: fixture.bamURL)
        try Data(repeating: 0x58, count: original.count).write(to: fixture.bamURL)

        XCTAssertThrowsError(
            try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        )
    }

    func testLoadsSchemaV2CandidateAndUnnameableDocuments() throws {
        let fixture = try CandidateBundleFixture(candidateSchemaVersion: 2)
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.mhcCandidates?.schemaVersion, 2)
        XCTAssertEqual(result.mhcUnnameableClusters?.schemaVersion, 2)
        XCTAssertEqual(result.mhcCandidates?.candidates.first?.reciprocalAlignmentCount, 1)
        XCTAssertEqual(result.mhcCandidates?.observations.first?.genotypingAlignmentCount, 1)
        XCTAssertEqual(result.mhcUnnameableClusters?.clusters.first?.reciprocalAlignmentCount, 0)
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testRejectsMismatchedCandidateAndUnnameableDocumentSchemaVersions() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 2,
            unnameableSchemaVersion: 1
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactSchemaUnsupported)
        XCTAssertTrue(result.integrityWarnings.first?.detail.contains("must match") == true)
    }

    func testSchemaV2RejectsCompactSummaryBAMRoleMismatches() throws {
        for fixture in [
            try CandidateBundleFixture(
                candidateSchemaVersion: 2,
                genotypingSummaryBAMPathOverride: "artifacts/alignments/reciprocal.bam"
            ),
            try CandidateBundleFixture(
                candidateSchemaVersion: 2,
                reciprocalSummaryBAMPathOverride: "artifacts/alignments/genotyping.bam"
            ),
        ] {
            defer { fixture.remove() }

            let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertNil(result.mhcCandidates)
            XCTAssertEqual(
                result.integrityWarnings.first?.code,
                .candidateArtifactDocumentReferenceMismatch
            )
        }
    }

    func testSchemaV2RejectsInvalidSummaryOwnershipAndSelectedClosestBinding() throws {
        let cases: [CandidateBundleFixture] = [
            try CandidateBundleFixture(
                candidateSchemaVersion: 2,
                reciprocalSummaryQueryOverride: "another-stable-id"
            ),
            try CandidateBundleFixture(
                candidateSchemaVersion: 2,
                genotypingSummaryTargetOverride: "AnotherSample|source-candidate"
            ),
            try CandidateBundleFixture(
                candidateSchemaVersion: 2,
                selectedClosestMismatch: true
            ),
        ]
        for fixture in cases {
            defer { fixture.remove() }

            let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertNil(result.mhcCandidates)
            XCTAssertEqual(
                result.integrityWarnings.first?.code,
                .candidateArtifactDocumentReferenceMismatch
            )
        }
    }

    func testSchemaV2RejectsCandidateRecordsMissingCompactReciprocalSummary() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 2,
            omitV2CandidateReciprocalSummary: true
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactMalformedJSON)
    }

    func testSchemaV2RejectsUnnameableSelectionOutsideClosestTargets() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 2,
            unnameableSelectedClosestMismatch: true
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertEqual(
            result.integrityWarnings.first?.code,
            .candidateArtifactDocumentReferenceMismatch
        )
    }

    func testCandidateArtifactManifestRejectsUnsupportedSchema() throws {
        let fixture = try CandidateBundleFixture(candidateArtifactManifestSchemaVersion: 3)
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(
            result.integrityWarnings.first?.code,
            .candidateArtifactManifestSchemaUnsupported
        )
    }

    func testLoaderRetainsNormalizedNamedCandidateSequenceOnly() throws {
        let fixture = try CandidateBundleFixture(
            candidateID: "cluster-a",
            candidateSequence: "acgt"
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.mhcCandidateSequencesByStableClusterID["cluster-a"], "ACGT")
        XCTAssertNil(result.mhcCandidateSequencesByStableClusterID[fixture.unnameableID])
        XCTAssertEqual(result.mhcCandidateSequencesByStableClusterID.count, 1)
    }

    func testCandidateSequenceIndexRoundTripsThroughCodable() throws {
        let fixture = try CandidateBundleFixture(candidateID: "cluster-a")
        defer { fixture.remove() }
        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        let decoded = try JSONDecoder().decode(
            ONTGenotypeResultBundleData.self,
            from: JSONEncoder().encode(result)
        )

        XCTAssertEqual(decoded.mhcCandidateSequencesByStableClusterID, ["cluster-a": "ACGT"])
    }

    func testCompatibilityInitializerDefaultsCandidateSequenceIndexToEmpty() {
        let result = makeResult(calls: [])

        XCTAssertEqual(result.mhcCandidateSequencesByStableClusterID, [:])
        XCTAssertEqual(result.mhcCandidateGenBankArtifactURLs, .empty)
    }

    func testStableLoaderRetriesWhenWriterPublishesANewManifestGeneration() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        let replacementCalls = fixture.bundleURL.appendingPathComponent("calls-v2.csv")
        try Data(
            "sample,genotype,passed_alignments,passed_unique_reads\nSampleA,new-generation-allele,9,9\n".utf8
        ).write(to: replacementCalls)
        var observedAttempts = 0

        let result = try ONTGenotypeResultBundle.loadResult(
            from: fixture.bundleURL,
            candidateArtifactByteBudget: Int64.max,
            stableReadObserver: { attempt in
                observedAttempts += 1
                guard attempt == 0 else { return }
                let manifestURL = ONTGenotypeResultBundle.manifestURL(in: fixture.bundleURL)
                var object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
                )
                object["longSummaryCSVPath"] = replacementCalls.lastPathComponent
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    .write(to: manifestURL, options: .atomic)
            }
        )

        XCTAssertEqual(observedAttempts, 2)
        XCTAssertEqual(result.manifest.longSummaryCSVPath, replacementCalls.lastPathComponent)
        XCTAssertEqual(result.calls.map(\.genotype), ["new-generation-allele"])
    }

    func testMarkerWithoutExistingPublicationLockRequiresRecoveryWithoutCreatingLock() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        let markerURL = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: fixture.bundleURL)
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL)
        try Data("{}".utf8).write(to: markerURL)
        try? FileManager.default.removeItem(at: lockURL)

        XCTAssertThrowsError(try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)) { error in
            guard case ONTGenotypeWorkbookUpdateRecoveryError.recoveryRequired(let path) = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
            XCTAssertEqual(path, lockURL.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testMissingCandidateJSONFailsSoftAndPreservesKnownCalls() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.candidateJSONURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.map(\.genotype), ["known-allele"])
        XCTAssertNil(result.mhcCandidates)
        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactMissing)
        XCTAssertEqual(result.integrityWarnings.first?.path, "candidate-alleles.json")
    }

    func testEscapingCandidatePathFailsSoftWithoutReadingOutsideBundle() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        try fixture.rewriteManifest { artifacts in
            ONTMHCCandidateArtifactManifest(
                schemaVersion: artifacts.schemaVersion,
                genotypingEvidence: artifacts.genotypingEvidence,
                reciprocalEvidence: artifacts.reciprocalEvidence,
                candidateJSON: ONTMHCArtifactReference(
                    path: "../candidate-alleles.json",
                    sha256: artifacts.candidateJSON!.sha256,
                    sizeBytes: artifacts.candidateJSON!.sizeBytes
                ),
                candidateFASTA: artifacts.candidateFASTA,
                unnameableJSON: artifacts.unnameableJSON,
                unnameableFASTA: artifacts.unnameableFASTA
            )
        }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactPathInvalid)
    }

    func testIntermediateSymlinkInCandidatePathFailsSoft() throws {
        let fixture = try CandidateBundleFixture(candidateDirectory: "candidate-data")
        defer { fixture.remove() }
        let realDirectory = fixture.rootURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.moveItem(
            at: fixture.bundleURL.appendingPathComponent("candidate-data", isDirectory: true),
            to: realDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.bundleURL.appendingPathComponent("candidate-data"),
            withDestinationURL: realDirectory
        )

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactPathInvalid)
    }

    func testCandidateArtifactSymlinkFailsSoftEvenWhenTargetBytesMatch() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        let realJSON = fixture.rootURL.appendingPathComponent("real-candidate.json")
        try FileManager.default.moveItem(at: fixture.candidateJSONURL, to: realJSON)
        try FileManager.default.createSymbolicLink(at: fixture.candidateJSONURL, withDestinationURL: realJSON)

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactPathInvalid)
    }

    func testChecksummedBAMEvidenceMismatchFailsSoftWithoutParsingBAM() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        try fixture.rewriteManifest { artifacts in
            let pair = artifacts.genotypingEvidence!
            return ONTMHCCandidateArtifactManifest(
                schemaVersion: artifacts.schemaVersion,
                genotypingEvidence: ONTMHCBAMArtifactPair(
                    bam: ONTMHCArtifactReference(
                        path: pair.bam.path,
                        sha256: String(repeating: "0", count: 64),
                        sizeBytes: pair.bam.sizeBytes
                    ),
                    bai: pair.bai
                ),
                reciprocalEvidence: artifacts.reciprocalEvidence,
                candidateJSON: artifacts.candidateJSON,
                candidateFASTA: artifacts.candidateFASTA,
                unnameableJSON: artifacts.unnameableJSON,
                unnameableFASTA: artifacts.unnameableFASTA
            )
        }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.mhcAlignmentArtifactURLs, .empty)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactChecksumMismatch)
        XCTAssertTrue(result.integrityWarnings.first?.path?.hasSuffix("genotyping.bam") == true)
    }

    func testCandidateFIFOIsRejectedPromptlyWithoutWaitingForAWriter() async throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        try fixture.replaceCandidateJSONWithFIFO()
        let bundleURL = fixture.bundleURL
        let candidateJSONURL = fixture.candidateJSONURL
        let start = Date()
        let task = Task.detached { try ONTGenotypeResultBundle.loadResult(from: bundleURL) }
        let emergencyUnblocker = Task.detached {
            try await Task.sleep(for: .milliseconds(200))
            let writerFD = candidateJSONURL.path.withCString {
                Darwin.open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            }
            if writerFD >= 0 { Darwin.close(writerFD) }
        }
        let result = try await task.value
        emergencyUnblocker.cancel()

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15, "FIFO validation must never block waiting for an external writer")
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactNotRegularFile)
    }

    func testAggregateParsedCandidateArtifactBudgetFailsSoft() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(
            from: fixture.bundleURL,
            candidateArtifactByteBudget: 32
        )

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactTooLarge)
        XCTAssertTrue(result.integrityWarnings.first?.detail.contains("aggregate") == true)
    }

    func testGenBankCompanionsAreValidatedWithoutCountingTowardParsedArtifactBudget() throws {
        let fixture = try CandidateBundleFixture(includeGenBankArtifacts: true)
        defer { fixture.remove() }
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let artifacts = try XCTUnwrap(manifest.mhcCandidateArtifacts)
        let parsedBytes = [
            artifacts.candidateJSON,
            artifacts.candidateFASTA,
            artifacts.unnameableJSON,
            artifacts.unnameableFASTA,
        ].compactMap { $0 }.reduce(Int64(0)) { $0 + $1.sizeBytes }

        let result = try ONTGenotypeResultBundle.loadResult(
            from: fixture.bundleURL,
            candidateArtifactByteBudget: parsedBytes
        )

        XCTAssertNotNil(result.mhcCandidates)
        XCTAssertNotNil(result.mhcUnnameableClusters)
        XCTAssertTrue(result.integrityWarnings.isEmpty)
        XCTAssertNotNil(artifacts.candidateGenBank)
        XCTAssertNotNil(artifacts.unnameableGenBank)
    }

    func testValidatedCandidateGenBankArtifactURLsResolveDeclaredRegularBundleMembers() throws {
        let fixture = try CandidateBundleFixture(includeGenBankArtifacts: true)
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        let urls = result.mhcCandidateGenBankArtifactURLs

        XCTAssertEqual(urls.candidateFASTA, fixture.candidateFASTAURL.standardizedFileURL)
        XCTAssertEqual(urls.unnameableFASTA, fixture.unnameableFASTAURL.standardizedFileURL)
        XCTAssertEqual(
            urls.candidateAlleles,
            fixture.bundleURL.appendingPathComponent("candidate_alleles.gb").standardizedFileURL
        )
        XCTAssertEqual(
            urls.unnameableClusters,
            fixture.bundleURL.appendingPathComponent("unnameable_unmatched_clusters.gb").standardizedFileURL
        )
        let decoded = try JSONDecoder().decode(
            ONTGenotypeResultBundleData.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded.mhcCandidateGenBankArtifactURLs, urls)
    }

    func testValidatedCandidateGenBankArtifactURLsRejectTraversalAndChecksumMismatchWithoutFallback() throws {
        let traversalFixture = try CandidateBundleFixture(includeGenBankArtifacts: true)
        defer { traversalFixture.remove() }
        let traversalManifest = try ONTGenotypeResultBundle.loadManifest(from: traversalFixture.bundleURL)
        let traversalArtifacts = try XCTUnwrap(traversalManifest.mhcCandidateArtifacts)
        let candidateReference = try XCTUnwrap(traversalArtifacts.candidateGenBank)
        try Data("LOCUS       \(traversalFixture.candidateID)\n//\n".utf8).write(
            to: traversalFixture.rootURL.appendingPathComponent("candidate_alleles.gb")
        )
        try traversalFixture.rewriteManifest { artifacts in
            ONTMHCCandidateArtifactManifest(
                schemaVersion: artifacts.schemaVersion,
                genotypingEvidence: artifacts.genotypingEvidence,
                reciprocalEvidence: artifacts.reciprocalEvidence,
                candidateJSON: artifacts.candidateJSON,
                candidateFASTA: artifacts.candidateFASTA,
                candidateGenBank: ONTMHCArtifactReference(
                    path: "../candidate_alleles.gb",
                    sha256: candidateReference.sha256,
                    sizeBytes: candidateReference.sizeBytes
                ),
                unnameableJSON: artifacts.unnameableJSON,
                unnameableFASTA: artifacts.unnameableFASTA,
                unnameableGenBank: artifacts.unnameableGenBank
            )
        }
        let traversalResult = try ONTGenotypeResultBundle.loadResult(from: traversalFixture.bundleURL)

        XCTAssertEqual(traversalResult.mhcCandidateGenBankArtifactURLs, .empty)
        XCTAssertEqual(traversalResult.integrityWarnings.first?.code, .candidateArtifactPathInvalid)

        let checksumFixture = try CandidateBundleFixture(includeGenBankArtifacts: true)
        defer { checksumFixture.remove() }
        try checksumFixture.rewriteManifest { artifacts in
            let unnameableReference = artifacts.unnameableGenBank!
            return ONTMHCCandidateArtifactManifest(
                schemaVersion: artifacts.schemaVersion,
                genotypingEvidence: artifacts.genotypingEvidence,
                reciprocalEvidence: artifacts.reciprocalEvidence,
                candidateJSON: artifacts.candidateJSON,
                candidateFASTA: artifacts.candidateFASTA,
                candidateGenBank: artifacts.candidateGenBank,
                unnameableJSON: artifacts.unnameableJSON,
                unnameableFASTA: artifacts.unnameableFASTA,
                unnameableGenBank: ONTMHCArtifactReference(
                    path: unnameableReference.path,
                    sha256: String(repeating: "0", count: 64),
                    sizeBytes: unnameableReference.sizeBytes
                )
            )
        }
        let checksumResult = try ONTGenotypeResultBundle.loadResult(from: checksumFixture.bundleURL)

        XCTAssertEqual(checksumResult.mhcCandidateGenBankArtifactURLs, .empty)
        XCTAssertEqual(checksumResult.integrityWarnings.first?.code, .candidateArtifactChecksumMismatch)
    }

    func testValidatedCandidateGenBankArtifactURLsReturnTheExactMemberThatWasValidated() throws {
        let fixture = try CandidateBundleFixture(includeGenBankArtifacts: true)
        defer { fixture.remove() }
        try fixture.rewriteManifest { artifacts in
            ONTMHCCandidateArtifactManifest(
                schemaVersion: artifacts.schemaVersion,
                genotypingEvidence: artifacts.genotypingEvidence,
                reciprocalEvidence: artifacts.reciprocalEvidence,
                candidateJSON: artifacts.candidateJSON,
                candidateFASTA: artifacts.candidateFASTA,
                candidateGenBank: artifacts.candidateGenBank.map {
                    ONTMHCArtifactReference(
                        path: "  \($0.path)  ",
                        sha256: $0.sha256,
                        sizeBytes: $0.sizeBytes
                    )
                },
                unnameableJSON: artifacts.unnameableJSON,
                unnameableFASTA: artifacts.unnameableFASTA,
                unnameableGenBank: artifacts.unnameableGenBank
            )
        }
        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(
            result.mhcCandidateGenBankArtifactURLs.candidateAlleles,
            fixture.bundleURL.appendingPathComponent("candidate_alleles.gb").standardizedFileURL
        )
    }

    func testRoleAwareEvidenceAcceptsTypedBAMPathsWithoutBAMExtensions() throws {
        let fixture = try CandidateBundleFixture(
            genotypingBAMPath: "artifacts/alignments/genotyping-evidence.data",
            reciprocalBAMPath: "artifacts/alignments/reciprocal-evidence.data"
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNotNil(result.mhcCandidates)
        XCTAssertNotNil(result.mhcUnnameableClusters)
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testRoleAwareEvidenceDoesNotTreatMisleadingBAMNamedBAIAsBAM() throws {
        let fixture = try CandidateBundleFixture(
            genotypingBAIPath: "artifacts/alignments/misleading-index.bam",
            reciprocalBAIPath: "artifacts/alignments/other-misleading-index.bam",
            reciprocalLocatorPathOverride: "artifacts/alignments/other-misleading-index.bam"
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactDocumentReferenceMismatch)
    }

    func testRoleAwareEvidenceRejectsSwappedGenotypingAndReciprocalLocators() throws {
        let fixture = try CandidateBundleFixture(swappedEvidenceRoles: true)
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactDocumentReferenceMismatch)
        XCTAssertTrue(result.integrityWarnings.first?.detail.contains("reciprocal") == true)
    }

    func testCandidateArtifactSizeAndChecksumMismatchesFailSoft() throws {
        let sizeFixture = try CandidateBundleFixture()
        defer { sizeFixture.remove() }
        let handle = try FileHandle(forWritingTo: sizeFixture.candidateFASTAURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed".utf8))

        let sizeResult = try ONTGenotypeResultBundle.loadResult(from: sizeFixture.bundleURL)
        XCTAssertEqual(sizeResult.calls.count, 1)
        XCTAssertEqual(sizeResult.integrityWarnings.first?.code, .candidateArtifactSizeMismatch)

        let checksumFixture = try CandidateBundleFixture()
        defer { checksumFixture.remove() }
        let original = try Data(contentsOf: checksumFixture.candidateFASTAURL)
        var changed = original
        changed[changed.startIndex] = changed[changed.startIndex] == 62 ? 59 : 62
        try changed.write(to: checksumFixture.candidateFASTAURL)

        let checksumResult = try ONTGenotypeResultBundle.loadResult(from: checksumFixture.bundleURL)
        XCTAssertEqual(checksumResult.calls.count, 1)
        XCTAssertEqual(checksumResult.integrityWarnings.first?.code, .candidateArtifactChecksumMismatch)
    }

    func testMalformedCandidateJSONAndUnsupportedSchemaFailSoft() throws {
        let malformedFixture = try CandidateBundleFixture()
        defer { malformedFixture.remove() }
        try malformedFixture.replaceCandidateJSON(Data("{".utf8))

        let malformed = try ONTGenotypeResultBundle.loadResult(from: malformedFixture.bundleURL)
        XCTAssertEqual(malformed.calls.count, 1)
        XCTAssertEqual(malformed.integrityWarnings.first?.code, .candidateArtifactMalformedJSON)

        let schemaFixture = try CandidateBundleFixture(candidateSchemaVersion: 6)
        defer { schemaFixture.remove() }
        let schema = try ONTGenotypeResultBundle.loadResult(from: schemaFixture.bundleURL)
        XCTAssertEqual(schema.calls.count, 1)
        XCTAssertEqual(schema.integrityWarnings.first?.code, .candidateArtifactSchemaUnsupported)

        let unnameableSchemaFixture = try CandidateBundleFixture(
            candidateSchemaVersion: 1,
            unnameableSchemaVersion: 6
        )
        defer { unnameableSchemaFixture.remove() }
        let unnameableSchema = try ONTGenotypeResultBundle.loadResult(
            from: unnameableSchemaFixture.bundleURL
        )
        XCTAssertEqual(unnameableSchema.calls.count, 1)
        XCTAssertEqual(
            unnameableSchema.integrityWarnings.first?.code,
            .candidateArtifactSchemaUnsupported
        )
    }

    func testSchemaV3RejectsMissingStructuralCandidateFields() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 3,
            unnameableSchemaVersion: 3
        )
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.candidateJSONURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        candidates[0].removeValue(forKey: "extension_interpretations")
        object["candidates"] = candidates
        try fixture.replaceCandidateJSON(try JSONSerialization.data(withJSONObject: object))

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactMalformedJSON)
    }

    func testSchemaV4AcceptsCanonicalCandidateBoundToRepresentativeRawEvidence() throws {
        let fixture = try CandidateBundleFixture(
            candidateArtifactManifestSchemaVersion: 2,
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            candidateID: "canonical-candidate",
            candidateSourceSequenceClusterIDs: ["raw-a", "raw-b"],
            candidateRepresentativeSourceSequenceClusterID: "raw-b",
            candidateObservationSourceSequenceClusterID: "raw-a"
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.mhcCandidates?.candidates.first?.stableClusterID, "canonical-candidate")
        XCTAssertEqual(
            result.mhcCandidates?.candidates.first?.representativeSourceSequenceClusterID,
            "raw-b"
        )
        XCTAssertEqual(
            result.mhcCandidates?.observations.first?.sourceSequenceClusterID,
            "raw-a"
        )
        XCTAssertEqual(
            result.mhcCandidates?.candidates.first?.selectedEvidence.queryName,
            "raw-b"
        )
        XCTAssertEqual(
            result.mhcCandidateSequencesByStableClusterID,
            ["canonical-candidate": "ACGT"]
        )
        XCTAssertNil(result.mhcCandidateSequencesByStableClusterID["raw-b"])
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testSchemaV5AcceptsPartialExtensionWithoutCDNAExtensionInterpretations() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 5,
            unnameableSchemaVersion: 5
        )
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.candidateJSONURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        candidates[0]["classification"] = "partial-extension"
        candidates[0]["provisional_name"] = "Mafa-A1*001:01_partial_ext"
        candidates[0]["extension_of"] = ["Mafa-A1*001:01"]
        candidates[0]["extension_interpretations"] = []
        object["candidates"] = candidates
        try fixture.replaceCandidateJSON(try JSONSerialization.data(withJSONObject: object))

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.mhcCandidates?.candidates.first?.classification, .partialExtension)
        XCTAssertEqual(
            result.mhcCandidates?.candidates.first?.extensionOf,
            ["Mafa-A1*001:01"]
        )
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testSchemaV4RejectsRepresentativeAndObservationRawBindingMismatches() throws {
        let representativeFixture = try CandidateBundleFixture(
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            candidateSourceSequenceClusterIDs: ["raw-a", "raw-b"],
            candidateRepresentativeSourceSequenceClusterID: "raw-b",
            candidateObservationSourceSequenceClusterID: "raw-a",
            candidateSelectedQueryOverride: "raw-a"
        )
        defer { representativeFixture.remove() }
        let representativeResult = try ONTGenotypeResultBundle.loadResult(
            from: representativeFixture.bundleURL
        )
        XCTAssertEqual(
            representativeResult.integrityWarnings.first?.code,
            .candidateArtifactDocumentReferenceMismatch
        )

        let observationFixture = try CandidateBundleFixture(
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            candidateSourceSequenceClusterIDs: ["raw-a", "raw-b"],
            candidateRepresentativeSourceSequenceClusterID: "raw-b",
            candidateObservationSourceSequenceClusterID: "raw-outside-record"
        )
        defer { observationFixture.remove() }
        let observationResult = try ONTGenotypeResultBundle.loadResult(
            from: observationFixture.bundleURL
        )
        XCTAssertEqual(
            observationResult.integrityWarnings.first?.code,
            .candidateArtifactDocumentReferenceMismatch
        )
    }

    func testSchemaV4RejectsRawSourceOwnedByMultipleCanonicalCandidates() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            candidateID: "canonical-a",
            candidateSourceSequenceClusterIDs: ["raw-shared"],
            candidateRepresentativeSourceSequenceClusterID: "raw-shared",
            candidateObservationSourceSequenceClusterID: "raw-shared"
        )
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.candidateJSONURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        var duplicateOwner = try XCTUnwrap(candidates.first)
        duplicateOwner["stable_cluster_id"] = "canonical-b"
        duplicateOwner["fasta_record_id"] = "canonical-b"
        candidates.append(duplicateOwner)
        object["candidates"] = candidates
        try fixture.replaceCandidateJSON(try JSONSerialization.data(withJSONObject: object))

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(
            result.integrityWarnings.first?.code,
            .candidateArtifactDocumentReferenceMismatch
        )
    }

    func testSchemaV4RejectsDuplicateRawUnnameableOwnersWithoutExternalIdentity() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            unnameableHasExternalSequence: false
        )
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.unnameableJSONURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var clusters = try XCTUnwrap(object["clusters"] as? [[String: Any]])
        clusters.append(try XCTUnwrap(clusters.first))
        object["clusters"] = clusters
        try fixture.replaceUnnameableJSON(try JSONSerialization.data(withJSONObject: object))

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertEqual(
            result.integrityWarnings.first?.code,
            .candidateArtifactDocumentReferenceMismatch
        )
    }

    func testSchemaV4RejectsCandidateAndUnnameableRawSourceCollision() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            candidateID: "canonical-a",
            candidateSourceSequenceClusterIDs: ["raw-shared"],
            candidateRepresentativeSourceSequenceClusterID: "raw-shared",
            candidateObservationSourceSequenceClusterID: "raw-shared"
        )
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.unnameableJSONURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var clusters = try XCTUnwrap(object["clusters"] as? [[String: Any]])
        clusters[0]["stable_cluster_id"] = "raw-shared"
        var reciprocalSummary = try XCTUnwrap(
            clusters[0]["reciprocal_hit_summary"] as? [String: Any]
        )
        reciprocalSummary["query_name"] = "raw-shared"
        clusters[0]["reciprocal_hit_summary"] = reciprocalSummary
        if var selectedEvidence = clusters[0]["selected_evidence"] as? [String: Any] {
            selectedEvidence["query_name"] = "raw-shared"
            clusters[0]["selected_evidence"] = selectedEvidence
        }
        object["clusters"] = clusters
        var observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
        observations[0]["stable_cluster_id"] = "raw-shared"
        observations[0]["source_sequence_cluster_id"] = "raw-shared"
        object["observations"] = observations
        try fixture.replaceUnnameableJSON(try JSONSerialization.data(withJSONObject: object))

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertNil(result.mhcCandidates)
        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertEqual(
            result.integrityWarnings.first?.code,
            .candidateArtifactDocumentReferenceMismatch
        )
    }

    func testSchemaV4UnnameableFASTAContainsExactlyExportableRecordsAndRejectsHalfIdentity() throws {
        let fixture = try CandidateBundleFixture(
            candidateSchemaVersion: 4,
            unnameableSchemaVersion: 4,
            unnameableHasExternalSequence: false
        )
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        XCTAssertNotNil(result.mhcUnnameableClusters)
        XCTAssertTrue(result.integrityWarnings.isEmpty)

        let data = try Data(contentsOf: fixture.unnameableJSONURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var records = try XCTUnwrap(object["clusters"] as? [[String: Any]])
        records[0]["fasta_record_id"] = fixture.unnameableID
        object["clusters"] = records
        try fixture.replaceUnnameableJSON(try JSONSerialization.data(withJSONObject: object))

        let halfIdentity = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        XCTAssertEqual(
            halfIdentity.integrityWarnings.first?.code,
            .candidateArtifactMalformedJSON
        )
    }

    func testMissingDuplicateAndExtraCandidateFASTARecordsFailSoft() throws {
        for (records, expectedCode) in [
            ([], ONTGenotypeIntegrityWarningCode.candidateArtifactMissingFASTARecord),
            (["candidate-sequence", "candidate-sequence"], .candidateArtifactDuplicateFASTARecord),
            (["candidate-sequence", "extra"], .candidateArtifactExtraFASTARecord),
        ] {
            let fixture = try CandidateBundleFixture(candidateFASTAIDs: records)
            defer { fixture.remove() }

            let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

            XCTAssertEqual(result.calls.count, 1)
            XCTAssertNil(result.mhcCandidates)
            XCTAssertEqual(result.integrityWarnings.first?.code, expectedCode)
        }
    }

    func testInconsistentDocumentFASTAReferenceFailsSoft() throws {
        let fixture = try CandidateBundleFixture(documentCandidateFASTAPath: "other.fasta")
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertEqual(result.integrityWarnings.first?.code, .candidateArtifactDocumentReferenceMismatch)
    }

    func testLegacyBundleLoadsWithEmptyCandidateProjectionAndNoWarnings() throws {
        let fixture = try CandidateBundleFixture(includeCandidateArtifacts: false)
        defer { fixture.remove() }

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertNil(result.mhcCandidates)
        XCTAssertNil(result.mhcUnnameableClusters)
        XCTAssertTrue(result.integrityWarnings.isEmpty)
    }

    func testDecodesLegacyManifestWithoutMHCCandidateArtifacts() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "kind": "ont-barcode-genotype",
              "outputName": "legacy",
              "analysisName": "Legacy",
              "primaryWorkbookPath": "legacy.xlsx",
              "longSummaryCSVPath": "legacy-genotypes.csv",
              "sampleSummaryCSVPath": "legacy-samples.csv",
              "statsJSONPath": "legacy-stats.json",
              "provenancePath": "provenance.json"
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertNil(manifest.mhcCandidateArtifacts)
        XCTAssertNil(manifest.alignmentArtifacts)
        XCTAssertNil(manifest.provisionalExon2Artifacts)
    }

    func testRoundTripsGenericAlignmentArtifacts() throws {
        let alignmentArtifacts = ONTGenotypeAlignmentArtifactManifest(
            genotypingEvidence: ONTMHCBAMArtifactPair(
                bam: ONTMHCArtifactReference(
                    path: "run.retained.demuxed.bam",
                    sha256: String(repeating: "a", count: 64),
                    sizeBytes: 3
                ),
                bai: ONTMHCArtifactReference(
                    path: "run.retained.demuxed.bam.bai",
                    sha256: String(repeating: "b", count: 64),
                    sizeBytes: 3
                )
            ),
            reciprocalEvidence: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "miseq",
            analysisName: "miSeq",
            primaryWorkbookPath: "miseq.xlsx",
            longSummaryCSVPath: "miseq-genotypes.csv",
            sampleSummaryCSVPath: "miseq-samples.csv",
            statsJSONPath: "miseq-stats.json",
            provenancePath: "provenance.json",
            alignmentArtifacts: alignmentArtifacts,
            provisionalExon2Artifacts: nil
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertEqual(decoded.alignmentArtifacts, alignmentArtifacts)
        XCTAssertNil(decoded.alignmentArtifacts?.reciprocalEvidence)
    }

    func testRoundTripsProvisionalExon2Artifacts() throws {
        let artifacts = ONTGenotypeProvisionalExon2ArtifactManifest(
            schemaVersion: 1,
            catalogJSON: ONTMHCArtifactReference(
                path: "artifacts/sequences/observed-provisional-exon2.json",
                sha256: String(repeating: "c", count: 64),
                sizeBytes: 17
            ),
            sequencesFASTA: ONTMHCArtifactReference(
                path: "artifacts/sequences/observed-provisional-exon2.fasta",
                sha256: String(repeating: "d", count: 64),
                sizeBytes: 23
            )
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "miseq",
            analysisName: "miSeq",
            primaryWorkbookPath: "miseq.xlsx",
            longSummaryCSVPath: "miseq-genotypes.csv",
            sampleSummaryCSVPath: "miseq-samples.csv",
            statsJSONPath: "miseq-stats.json",
            provenancePath: "provenance.json",
            alignmentArtifacts: nil,
            provisionalExon2Artifacts: artifacts
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertEqual(decoded.provisionalExon2Artifacts, artifacts)
    }

    func testRoundTripsMHCCandidateArtifactManifestWithChecksummedBAMPair() throws {
        let pair = ONTMHCBAMArtifactPair(
            bam: ONTMHCArtifactReference(
                path: "artifacts/candidates/genotyping-evidence.bam",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 12_345
            ),
            bai: ONTMHCArtifactReference(
                path: "artifacts/candidates/genotyping-evidence.bam.bai",
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 678
            )
        )
        let artifactManifest = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: pair,
            reciprocalEvidence: nil,
            candidateJSON: ONTMHCArtifactReference(
                path: "artifacts/candidates/candidates.json",
                sha256: String(repeating: "c", count: 64),
                sizeBytes: 1_024
            ),
            candidateFASTA: nil,
            unnameableJSON: nil,
            unnameableFASTA: nil
        )

        let data = try JSONEncoder().encode(artifactManifest)
        let decoded = try JSONDecoder().decode(ONTMHCCandidateArtifactManifest.self, from: data)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(decoded, artifactManifest)
        XCTAssertNotNil(encodedObject["schema_version"])
        XCTAssertNotNil(encodedObject["genotyping_evidence"])
        XCTAssertNotNil(encodedObject["candidate_json"])
    }

    func testRoundTripsCandidateArtifactManifestSchema2InternalRawReferences() throws {
        let rawFASTA = ONTMHCArtifactReference(
            path: "artifacts/candidates/raw-unmatched.fasta",
            sha256: String(repeating: "d", count: 64),
            sizeBytes: 4_096
        )
        let sourceIdentityMap = ONTMHCArtifactReference(
            path: "artifacts/candidates/source-identity.json",
            sha256: String(repeating: "e", count: 64),
            sizeBytes: 2_048
        )
        let candidateEMBL = ONTMHCArtifactReference(
            path: "candidate_alleles.embl",
            sha256: String(repeating: "f", count: 64),
            sizeBytes: 3_072
        )
        let unnameableEMBL = ONTMHCArtifactReference(
            path: "unnameable_unmatched_clusters.embl",
            sha256: String(repeating: "1", count: 64),
            sizeBytes: 5_120
        )
        let manifest = ONTMHCCandidateArtifactManifest(
            schemaVersion: 2,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: nil,
            candidateFASTA: nil,
            candidateEMBL: candidateEMBL,
            unnameableJSON: nil,
            unnameableFASTA: nil,
            unnameableEMBL: unnameableEMBL,
            rawUnmatchedFASTA: rawFASTA,
            sourceIdentityMap: sourceIdentityMap
        )

        let data = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(ONTMHCCandidateArtifactManifest.self, from: data)

        XCTAssertEqual(object["raw_unmatched_fasta"] as? [String: Any]? != nil, true)
        XCTAssertEqual(object["source_identity_map"] as? [String: Any]? != nil, true)
        XCTAssertEqual(object["candidate_embl"] as? [String: Any]? != nil, true)
        XCTAssertEqual(object["unnameable_embl"] as? [String: Any]? != nil, true)
        XCTAssertEqual(decoded.rawUnmatchedFASTA, rawFASTA)
        XCTAssertEqual(decoded.sourceIdentityMap, sourceIdentityMap)
        XCTAssertEqual(decoded.candidateEMBL, candidateEMBL)
        XCTAssertEqual(decoded.unnameableEMBL, unnameableEMBL)

        let schema1 = try JSONDecoder().decode(
            ONTMHCCandidateArtifactManifest.self,
            from: Data(#"{"schema_version":1}"#.utf8)
        )
        XCTAssertNil(schema1.rawUnmatchedFASTA)
        XCTAssertNil(schema1.sourceIdentityMap)
        XCTAssertNil(schema1.candidateEMBL)
        XCTAssertNil(schema1.unnameableEMBL)
    }

    func testRoundTripsManifestWithMHCCandidateArtifacts() throws {
        let artifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 1,
            genotypingEvidence: ONTMHCBAMArtifactPair(
                bam: ONTMHCArtifactReference(
                    path: "artifacts/candidates/genotyping-evidence.bam",
                    sha256: String(repeating: "a", count: 64),
                    sizeBytes: 12_345
                ),
                bai: ONTMHCArtifactReference(
                    path: "artifacts/candidates/genotyping-evidence.bam.bai",
                    sha256: String(repeating: "b", count: 64),
                    sizeBytes: 678
                )
            ),
            reciprocalEvidence: nil,
            candidateJSON: nil,
            candidateFASTA: nil,
            unnameableJSON: nil,
            unnameableFASTA: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "candidates",
            analysisName: "Candidates",
            primaryWorkbookPath: "candidates.xlsx",
            longSummaryCSVPath: "candidates-genotypes.csv",
            sampleSummaryCSVPath: "candidates-samples.csv",
            statsJSONPath: "candidates-stats.json",
            provenancePath: "provenance.json",
            mhcCandidateArtifacts: artifacts
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(decoded.mhcCandidateArtifacts, artifacts)
        XCTAssertNotNil(encodedObject["mhcCandidateArtifacts"])
    }

    func testLoadManifestRejectsDeclaredMHCBAMPairWithoutIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("invalid.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "kind": "ont-barcode-genotype",
              "outputName": "invalid",
              "analysisName": "Invalid",
              "primaryWorkbookPath": "invalid.xlsx",
              "longSummaryCSVPath": "invalid-genotypes.csv",
              "sampleSummaryCSVPath": "invalid-samples.csv",
              "statsJSONPath": "invalid-stats.json",
              "provenancePath": "provenance.json",
              "mhcCandidateArtifacts": {
                "schema_version": 1,
                "genotyping_evidence": {
                  "bam": {
                    "path": "artifacts/candidates/genotyping-evidence.bam",
                    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "size_bytes": 12345
                  }
                }
              }
            }
            """.utf8
        )
        try data.write(to: ONTGenotypeResultBundle.manifestURL(in: bundleURL))

        do {
            _ = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
            XCTFail("Expected a declared BAM pair without bai to fail decoding")
        } catch let DecodingError.keyNotFound(key, context) {
            XCTAssertEqual(key.stringValue, "bai")
            XCTAssertTrue(context.codingPath.contains { $0.stringValue == "genotyping_evidence" })
        } catch {
            XCTFail("Expected a missing bai decoding error, got \(error)")
        }
    }

    func testManifestRoundTripsAndLoadsEmbeddedGenBankReferenceMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("annotated.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("annotated.xlsx")
        try Data("workbook".utf8).write(to: workbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: "annotated")

        let info = try writeAnnotatedReferenceRecordStore(in: bundleURL)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "annotated",
            analysisName: "annotated",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent,
            referenceRecordStore: info
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: bundleURL).referenceRecordStore, info)
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        XCTAssertEqual(result.referenceMetadata?.alleleFieldKey, "feature.allele")
        XCTAssertEqual(
            result.referenceMetadata?.recordsBySequenceName["NHP01222"]?["feature.allele"],
            "Mafa-A1*006:01:02"
        )
        XCTAssertEqual(
            result.referenceMetadata?.fields.first(where: { $0.key == "feature.allele" })?.displayTitle,
            "Allele"
        )
    }

    func testLoadsCandidateArtifactsAndReferenceMetadataFromSameBundle() throws {
        let fixture = try CandidateBundleFixture()
        defer { fixture.remove() }
        let info = try writeAnnotatedReferenceRecordStore(in: fixture.bundleURL)
        let original = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let manifest = ONTGenotypeResultBundleManifest(
            schemaVersion: original.schemaVersion,
            kind: original.kind,
            outputName: original.outputName,
            analysisName: original.analysisName,
            primaryWorkbookPath: original.primaryWorkbookPath,
            currentWorkbookPath: original.currentWorkbookPath,
            workbookRevisions: original.workbookRevisions,
            longSummaryCSVPath: original.longSummaryCSVPath,
            sampleSummaryCSVPath: original.sampleSummaryCSVPath,
            statsJSONPath: original.statsJSONPath,
            provenancePath: original.provenancePath,
            deduplicatedUnmatchedClustersFASTAPath: original.deduplicatedUnmatchedClustersFASTAPath,
            haplotypeAnalysisPath: original.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: original.haplotypeDefinitionSetID,
            haplotypeAssayID: original.haplotypeAssayID,
            presetID: original.presetID,
            presetVersion: original.presetVersion,
            createdAt: original.createdAt,
            activeHaplotypeAnalysisRevisionID: original.activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: original.haplotypeAnalysisRevisions,
            mhcCandidateArtifacts: original.mhcCandidateArtifacts,
            referenceRecordStore: info
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: fixture.bundleURL)

        let roundTripped = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        XCTAssertEqual(roundTripped.mhcCandidateArtifacts, original.mhcCandidateArtifacts)
        XCTAssertEqual(roundTripped.referenceRecordStore, info)

        let result = try ONTGenotypeResultBundle.loadResult(from: fixture.bundleURL)
        XCTAssertNotNil(result.mhcCandidates)
        XCTAssertNotNil(result.mhcUnnameableClusters)
        XCTAssertTrue(result.integrityWarnings.isEmpty)
        XCTAssertEqual(
            result.referenceMetadata?.recordsBySequenceName["NHP01222"]?["feature.allele"],
            "Mafa-A1*006:01:02"
        )
    }

    func testWritesAndLoadsPrimaryWorkbookManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        try Data("workbook".utf8).write(to: workbookURL)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: "barcode08-mhc.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "barcode08-mhc.retained-demux-samples.csv",
            statsJSONPath: "barcode08-mhc.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertTrue(ONTGenotypeResultBundle.isBundleURL(bundleURL))
        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: bundleURL), manifest)
        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
    }

    func testLoadsCurrentWorkbookWhenManifestHasEditableWorkbookPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("cohort.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let generatedWorkbookURL = bundleURL.appendingPathComponent("cohort.xlsx")
        let currentWorkbookURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(
            at: currentWorkbookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generated".utf8).write(to: generatedWorkbookURL)
        try Data("current".utf8).write(to: currentWorkbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: "cohort")

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "cohort",
            analysisName: "cohort",
            primaryWorkbookPath: generatedWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            generatedWorkbookURL.standardizedFileURL
        )
        XCTAssertEqual(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL),
            currentWorkbookURL.standardizedFileURL
        )
        XCTAssertEqual(result.artifacts.primaryWorkbookURL, generatedWorkbookURL.standardizedFileURL)
        XCTAssertEqual(result.artifacts.workbookURL, currentWorkbookURL.standardizedFileURL)
    }

    func testCurrentWorkbookURLFallsBackToPrimaryWorkbookForOldBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("legacy.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("legacy.xlsx")
        try Data("legacy".utf8).write(to: workbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: "legacy")

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "legacy",
            analysisName: "legacy",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
        XCTAssertEqual(
            try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
        XCTAssertEqual(result.artifacts.primaryWorkbookURL, workbookURL.standardizedFileURL)
        XCTAssertEqual(result.artifacts.workbookURL, workbookURL.standardizedFileURL)
    }

    func testLoadsNativeResultSummariesFromBundleArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        AnimalA,01_M1_A_01,800,800,2000,1200,60.0,3000,1260,42.0
        AnimalA,02_M2_B_01,400,400,2000,1200,60.0,3000,1260,42.0
        AnimalB,13_M3_DRB1_10,12,4,90,4,4.444444,1000,60,6.0
        unassigned,noise_reference,7,7,,7,,1000,60,6.0
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        AnimalA,1200,1200,2000,60.0,3000,42.0
        AnimalB,12,4,90,4.444444,1000,6.0
        AnimalC,0,0,80,0.0,1000,6.0
        unassigned,7,7,,,
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 3000,
          "totalAlignments": 1274,
          "passedAlignments": 1219,
          "retainedUniqueReads": 1260,
          "retainedUniquePercentOfTotalReads": 42.0,
          "assignedUniqueRetainedReads": 1253,
          "unassignedUniqueRetainedReads": 7
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent,
            createdAt: "2026-05-21T21:00:00Z"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(result.artifacts.workbookURL, workbookURL.standardizedFileURL)
        XCTAssertEqual(result.stats.totalInputReads, 3000)
        XCTAssertEqual(result.stats.retainedUniqueReads, 1260)
        XCTAssertEqual(result.calls.count, 3, "Unassigned genotype rows should not be treated as sample calls")
        XCTAssertEqual(result.samples.map(\.sample), ["AnimalA", "AnimalB", "AnimalC"])
        XCTAssertEqual(result.samples[0].topCall?.genotype, "01_M1_A_01")
        XCTAssertEqual(result.samples[0].callCount, 2)
        XCTAssertEqual(result.samples[0].qcStatus, .ok)
        XCTAssertEqual(result.samples[1].qcStatus, .lowSupport)
        XCTAssertEqual(result.samples[2].qcStatus, .review)
        XCTAssertEqual(result.calls[0].haplotypeTokens, ["M1"])
        XCTAssertEqual(result.calls[0].locusToken, "A")
        XCTAssertEqual(result.calls[0].locusGroup, "MHC-A")
    }

    func testLoadResultIgnoresRepeatedCSVHeaderRowsInSampleSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        AnimalA,01_M1_A_01,42,39
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        AnimalA,42,39
        sample,passed_alignments,passed_unique_reads
        AnimalB,12,12
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: statsJSONURL)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.samples.map(\.sample), ["AnimalA", "AnimalB"])
        XCTAssertFalse(result.sampleNames.contains("sample"))
    }

    func testSampleQCFlagsLowAssignedReadCoverage() {
        let calls = [
            ONTGenotypeCall(
                sample: "LowCoverage",
                genotype: "05_M1_A1_063",
                passedAlignments: 750,
                passedUniqueReads: 750,
                sampleTotalReads: 50_000,
                sampleUniqueRetainedReads: 750,
                sampleUniqueRetainedPercent: 1.5,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        ]
        let sample = ONTGenotypeSampleResult(
            sample: "LowCoverage",
            passedAlignments: 750,
            passedUniqueReads: 750,
            sampleTotalReads: 50_000,
            sampleUniqueRetainedPercent: 1.5,
            calls: calls
        )

        XCTAssertEqual(sample.qcStatus, .lowSupport)
    }

    func testSummarizesSharedCallsByInferredLocus() {
        let dqb1Primary = ONTGenotypeCall(
            sample: "LF2874",
            genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34",
            passedAlignments: 2_945,
            passedUniqueReads: 2_945,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let dqb1Shared = ONTGenotypeCall(
            sample: "LF2875",
            genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34",
            passedAlignments: 1_200,
            passedUniqueReads: 1_200,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let bCall = ONTGenotypeCall(
            sample: "LF2874",
            genotype: "03_Mafa_B_075_01",
            passedAlignments: 148,
            passedUniqueReads: 148,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [dqb1Primary, dqb1Shared, bCall],
            samples: []
        )

        XCTAssertEqual(dqb1Primary.locusToken, "DQB1")
        XCTAssertEqual(dqb1Primary.locusGroup, "MHC-DQB1")
        XCTAssertEqual(bCall.locusToken, "B")
        XCTAssertEqual(bCall.locusGroup, "MHC-B")
        XCTAssertEqual(result.locusSummaries.map(\.locus), ["MHC-B", "MHC-DQB1"])
        XCTAssertEqual(result.locusSummaries.first { $0.locus == "MHC-DQB1" }?.sharedCalls.first?.sampleCount, 2)
        XCTAssertEqual(result.locusSummaries.first { $0.locus == "MHC-DQB1" }?.sharedCalls.first?.totalUniqueReads, 4_145)
    }

    func testSeparatesAGFromClassicalAInLocusSummaries() {
        let classicalA = ONTGenotypeCall(
            sample: "DW472",
            genotype: "01_Mafa_A1_063g|A1_063_01,_A1_063_02",
            passedAlignments: 148,
            passedUniqueReads: 148,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let ag = ONTGenotypeCall(
            sample: "DW472",
            genotype: "18_Mafa_AG_05_AG_06g|AG_05_02_01,_AG_06_04",
            passedAlignments: 204,
            passedUniqueReads: 204,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [classicalA, ag],
            samples: []
        )

        XCTAssertEqual(classicalA.locusGroup, "MHC-A")
        XCTAssertEqual(ag.locusGroup, "MHC-AG")
        XCTAssertEqual(result.locusSummaries.map(\.locus), ["MHC-A", "MHC-AG"])
    }

    func testKIRLocusParsingDoesNotDefaultToMHC() {
        let kir = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_KIR3DL01_001_01",
            passedAlignments: 84,
            passedUniqueReads: 84,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        XCTAssertEqual(kir.locusToken, "KIR3DL01")
        XCTAssertEqual(kir.locusGroup, "KIR-KIR3DL01")
    }

    func testAnchorSummariesGroupExplicitHaplotypeTokensAcrossLoci() {
        let a = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_M1_A_01",
            passedAlignments: 40,
            passedUniqueReads: 40,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let b = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "02_M1_B_01",
            passedAlignments: 30,
            passedUniqueReads: 30,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let unanchored = ONTGenotypeCall(
            sample: "AnimalB",
            genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01",
            passedAlignments: 20,
            passedUniqueReads: 20,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [a, b, unanchored],
            samples: []
        )

        let anchors = result.anchorSummaries()
        let m1 = anchors.first { $0.label == "M1" }
        let noToken = anchors.first { $0.label == "Unanchored" }

        XCTAssertEqual(m1?.source, .labelToken)
        XCTAssertEqual(m1?.loci, ["MHC-A", "MHC-B"])
        XCTAssertEqual(m1?.sampleCount, 1)
        XCTAssertEqual(m1?.totalUniqueReads, 70)
        XCTAssertEqual(m1?.sharedCalls.map(\.genotype).sorted(), ["01_M1_A_01", "02_M1_B_01"])
        XCTAssertEqual(noToken?.source, .unanchored)
        XCTAssertTrue(m1?.caveat.localizedCaseInsensitiveContains("not phased") ?? false)
    }

    func testFiltersSharedCallsByViewedLocusSupportPercent() {
        let highSupport = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 990,
            passedUniqueReads: 990,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let lowSupport = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_002_01",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let result = makeResult(calls: [highSupport, lowSupport])

        let filtered = result.locusSummaries(
            minimumSupportPercent: 1.0,
            denominator: .viewedLocus
        )

        XCTAssertEqual(filtered.flatMap(\.sharedCalls).map(\.genotype), ["01_Mafa_A1_001_01"])
        XCTAssertEqual(filtered.first?.sharedCalls.first?.sampleCount, 1)
        XCTAssertEqual(filtered.first?.sharedCalls.first?.totalUniqueReads, 990)
    }

    func testComputesSameLocusCoOccurrenceForSelectedGenotype() throws {
        let selectedA = makeCall(sample: "A", genotype: "13_Mafa_DQB1_01", uniqueReads: 50)
        let selectedB = makeCall(sample: "B", genotype: "13_Mafa_DQB1_01", uniqueReads: 50)
        let companionA = makeCall(sample: "A", genotype: "13_Mafa_DQB1_02", uniqueReads: 30)
        let companionC = makeCall(sample: "C", genotype: "13_Mafa_DQB1_02", uniqueReads: 30)
        let otherLocus = makeCall(sample: "A", genotype: "03_Mafa_B_001_01", uniqueReads: 30)
        let result = makeResult(calls: [selectedA, selectedB, companionA, companionC, otherLocus])

        let coOccurrences = result.sameLocusCoOccurrences(
            for: "13_Mafa_DQB1_01",
            minimumSupportPercent: 0,
            denominator: .viewedLocus
        )

        XCTAssertEqual(coOccurrences.map(\.candidateGenotype), ["13_Mafa_DQB1_02"])
        let first = try XCTUnwrap(coOccurrences.first)
        XCTAssertEqual(first.selectedSampleCount, 2)
        XCTAssertEqual(first.candidateSampleCount, 2)
        XCTAssertEqual(first.sharedSampleCount, 1)
        XCTAssertEqual(first.probabilityCandidateGivenSelected, 0.5, accuracy: 0.0001)
        XCTAssertEqual(first.probabilitySelectedGivenCandidate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(first.jaccard, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testSupportFilteringScalesForRetainedDemuxSizedBundles() {
        var calls: [ONTGenotypeCall] = []
        for sampleIndex in 0..<52 {
            let sample = "LF\(2800 + sampleIndex)"
            for genotypeIndex in 0..<120 {
                let locus = genotypeIndex.isMultiple(of: 2) ? "A1" : "DQB1"
                calls.append(ONTGenotypeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_%@_%03d_01", genotypeIndex % 20, locus, genotypeIndex),
                    passedAlignments: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    passedUniqueReads: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: 12_000,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                ))
            }
        }
        let result = makeResult(calls: calls)

        let start = Date()
        let summaries = result.locusSummaries(
            minimumSupportPercent: 1.0,
            denominator: .viewedLocus
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(summaries.isEmpty)
        XCTAssertLessThan(elapsed, 1.5, "Support filtering should use indexed denominators, not rescan every row for every call")
    }

    func testLoadsRetainedDemuxCSVsWithQuotedAliasesAndBlankOptionalFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode05-mhc.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent\r
        LF2823,"13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34",821,821,,3545,,11197546,260534,2.326706\r
        LF2823,13_Mafa_DQB1_06_08,387,387,,3545,,11197546,260534,2.326706\r
        LF2824,15_Mafa_DPB1_20_01,330,330,,6057,,11197546,260534,2.326706\r
        unassigned,noise_reference,7,7,,7,,11197546,260534,2.326706\r
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent\r
        LF2823,3576,3545,,,11197546,2.326706\r
        LF2824,6093,6057,,,11197546,2.326706\r
        unassigned,7,7,,,\r
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 11197546,
          "retainedUniqueReads": 260534,
          "assignedUniqueRetainedReads": 258326,
          "unassignedUniqueRetainedReads": 2208
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode05-mhc",
            analysisName: "barcode05-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.calls.count, 3)
        XCTAssertEqual(result.samples.map(\.sample), ["LF2823", "LF2824"])
        let firstSample = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(firstSample.passedAlignments, 3576)
        XCTAssertEqual(firstSample.passedUniqueReads, 3545)
        XCTAssertEqual(
            firstSample.topCall?.genotype,
            "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34"
        )
    }

    func testLoadsOptionalHaplotypeAnalysisArtifactFromManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc.xlsx")
        let genotypeCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("barcode08-mhc.retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let haplotypeURL = bundleURL.appendingPathComponent("barcode08-mhc.haplotype-analysis.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceURL)
        try Data("{}".utf8).write(to: statsJSONURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        DW472,05_M1M2M3_A1_063g,100,100
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        DW472,100,100
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "schemaVersion": 1,
          "assayID": "MHC-exon2-miSeq",
          "definitionSetID": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
          "definitionSetName": "Mauritian cynomolgus macaques",
          "speciesName": "Mauritian cynomolgus macaques",
          "generatedAt": "2026-05-22T19:45:00Z",
          "samples": [
            {
              "sample": "DW472",
              "calls": [
                {
                  "locus": "MHC-A",
                  "sourceLocus": "Mafa-A",
                  "haplotype1": "A1_063",
                  "haplotype2": "-",
                  "status": "specialCase",
                  "matchedHaplotypes": [],
                  "observedGenotypeCount": 1,
                  "observedGenotypes": ["05_M1M2M3_A1_063g"],
                  "notes": "Notebook-compatible MCM MHC-A special case"
                }
              ]
            }
          ]
        }
        """.write(to: haplotypeURL, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
            sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
            statsJSONPath: statsJSONURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent,
            haplotypeAnalysisPath: haplotypeURL.lastPathComponent,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            haplotypeAssayID: "MHC-exon2-miSeq"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        XCTAssertEqual(result.manifest.haplotypeDefinitionSetID, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertEqual(result.manifest.haplotypeAssayID, "MHC-exon2-miSeq")
        XCTAssertEqual(result.artifacts.haplotypeAnalysisURL, haplotypeURL.standardizedFileURL)
        XCTAssertEqual(result.haplotypeAnalysis?.definitionSetName, "Mauritian cynomolgus macaques")
        XCTAssertEqual(result.haplotypeAnalysis?.samples.first?.calls.first?.haplotype1, "A1_063")
    }

    private enum ReviewableCatalogCorruption: CaseIterable {
        case traversal
        case symlink
        case size
        case checksum
    }

    private func reviewableRowCatalog() -> GenotypeReviewableRowCatalog {
        GenotypeReviewableRowCatalog(
            schemaID: GenotypeReviewableRowCatalog.schemaID,
            schemaVersion: GenotypeReviewableRowCatalog.schemaVersion,
            samples: ["S1", "S2"],
            rows: [
                .init(
                    kind: .reference,
                    callID: "reference:MHC-A:Mafa-A1*001:01",
                    displayName: "Mafa-A1*001:01",
                    locus: "MHC-A",
                    stableID: nil,
                    section: "reference",
                    sortKey: "MHC-A|Mafa-A1*001:01",
                    supportBySample: ["S1": 0, "S2": 0]
                ),
                .init(
                    kind: .provisionalExon2,
                    callID: "candidate:MHC-B:candidate-1",
                    displayName: "Mafa-B*999:01_nov",
                    locus: "MHC-B",
                    stableID: "candidate-1",
                    section: "provisional-exon-2",
                    sortKey: "MHC-B|Mafa-B*999:01_nov",
                    supportBySample: ["S1": 0, "S2": 7]
                ),
            ]
        )
    }

    private func makeReviewableRowCatalogBundle(
        corruption: ReviewableCatalogCorruption? = nil
    ) throws -> (
        bundleURL: URL,
        catalog: GenotypeReviewableRowCatalog
    ) {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "reviewable-row-catalog-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("catalog.xlsx")
        let callURL = bundleURL.appendingPathComponent("calls.csv")
        let sampleURL = bundleURL.appendingPathComponent("samples.csv")
        let statsURL = bundleURL.appendingPathComponent("stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("provenance.json")
        try Data("workbook".utf8).write(to: workbookURL)
        try Data(
            """
            sample,genotype,passed_alignments,passed_unique_reads
            S1,Mafa-A1*001:01,0,0
            S2,Mafa-B*999:01_nov,7,7
            """.utf8
        ).write(to: callURL)
        try Data(
            """
            sample,passed_alignments,passed_unique_reads
            S1,0,0
            S2,7,7
            """.utf8
        ).write(to: sampleURL)
        try Data("{}".utf8).write(to: statsURL)
        try Data("{}".utf8).write(to: provenanceURL)

        let catalog = reviewableRowCatalog()
        let catalogData = try JSONEncoder().encode(catalog)
        let artifactDirectory = bundleURL.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let regularCatalogURL = artifactDirectory.appendingPathComponent("reviewable-rows-source.json")
        try catalogData.write(to: regularCatalogURL)
        let descriptorPath: String
        if corruption == .symlink {
            let symlinkURL = artifactDirectory.appendingPathComponent("reviewable-rows.json")
            try FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: regularCatalogURL
            )
            descriptorPath = "artifacts/reviewable-rows.json"
        } else if corruption == .traversal {
            descriptorPath = "../reviewable-rows.json"
        } else {
            descriptorPath = "artifacts/reviewable-rows-source.json"
        }
        let descriptor = ONTMHCArtifactReference(
            path: descriptorPath,
            sha256: corruption == .checksum
                ? String(repeating: "0", count: 64)
                : SHA256.hash(data: catalogData).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(catalogData.count) + (corruption == .size ? 1 : 0)
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "catalog",
            analysisName: "Catalog",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: callURL.lastPathComponent,
            sampleSummaryCSVPath: sampleURL.lastPathComponent,
            statsJSONPath: statsURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent,
            reviewableRowCatalog: descriptor
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, catalog)
    }

    private func makeCall(
        sample: String,
        genotype: String,
        uniqueReads: Int
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: uniqueReads,
            passedUniqueReads: uniqueReads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(
        calls: [ONTGenotypeCall],
        reviewableRowCatalog: GenotypeReviewableRowCatalog? = nil
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: [],
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: .empty,
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: nil,
            provisionalExon2SequencesByGenotype: [:],
            provisionalExon2ArtifactURLs: .empty,
            reviewableRowCatalog: reviewableRowCatalog
        )
    }

    private func writeMinimalNativeArtifacts(
        in bundleURL: URL,
        outputName: String
    ) throws -> (genotypeCSV: URL, sampleCSV: URL, statsJSON: URL, provenance: URL) {
        let genotypeCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        SampleA,allele1,1,1
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        SampleA,1,1
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1,
          "totalAlignments": 1,
          "passedAlignments": 1,
          "retainedUniqueReads": 1,
          "retainedUniquePercentOfTotalReads": 100.0,
          "assignedUniqueRetainedReads": 1,
          "unassignedUniqueRetainedReads": 0
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)
        return (genotypeCSVURL, sampleCSVURL, statsJSONURL, provenanceURL)
    }

    private struct ScientificArtifactBundleFixture {
        static let provisionalGenotype = "Mafa-E_02_nov_17"
        static let sequenceSHA256 = SHA256.hash(data: Data("ACGT".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        static let defaultRecord = ONTGenotypeProvisionalExon2Record(
            genotype: provisionalGenotype,
            locus: "MHC-E",
            fastaRecordID: provisionalGenotype,
            sequenceLength: 4,
            sequenceSHA256: sequenceSHA256,
            sampleSupport: [
                ONTGenotypeProvisionalExon2SampleSupport(
                    sample: "SampleA",
                    passedAlignments: 9,
                    passedUniqueReads: 8
                ),
            ]
        )

        let rootURL: URL
        let bundleURL: URL
        let bamURL: URL
        let baiURL: URL
        let catalogURL: URL
        let fastaURL: URL

        init(
            genotype: String = provisionalGenotype,
            records: [ONTGenotypeProvisionalExon2Record] = [defaultRecord],
            fastaRecordID: String = provisionalGenotype,
            fastaSequence: String = "ACGT",
            alignmentBAMPath: String = "run.retained.demuxed.bam",
            corruptBAMChecksum: Bool = false,
            bulkRecordCount: Int? = nil
        ) throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("scientific-artifacts-\(UUID().uuidString)", isDirectory: true)
            bundleURL = rootURL.appendingPathComponent("miseq.lungfishgenotype", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let workbookURL = bundleURL.appendingPathComponent("miseq.xlsx")
            let genotypeCSVURL = bundleURL.appendingPathComponent("miseq-genotypes.csv")
            let sampleCSVURL = bundleURL.appendingPathComponent("miseq-samples.csv")
            let statsURL = bundleURL.appendingPathComponent("miseq-stats.json")
            let provenanceURL = bundleURL.appendingPathComponent("provenance.json")
            try Data("workbook".utf8).write(to: workbookURL)
            try Data("{}".utf8).write(to: statsURL)
            try Data("{}".utf8).write(to: provenanceURL)
            let effectiveRecords: [ONTGenotypeProvisionalExon2Record]
            let genotypeCSV: String
            let fastaData: Data
            if let bulkRecordCount {
                effectiveRecords = (0..<bulkRecordCount).map { index in
                    let identifier = String(
                        format: "Mafa-E_02_nov_%03d",
                        index
                    )
                    return ONTGenotypeProvisionalExon2Record(
                        genotype: identifier,
                        locus: "MHC-E",
                        fastaRecordID: identifier,
                        sequenceLength: 4,
                        sequenceSHA256: Self.sequenceSHA256,
                        sampleSupport: Self.defaultRecord.sampleSupport
                    )
                }
                genotypeCSV = ([
                    "sample,genotype,passed_alignments,passed_unique_reads",
                ] + effectiveRecords.map {
                    "SampleA,\($0.genotype),9,8"
                }).joined(separator: "\n") + "\n"
                fastaData = Data(
                    (effectiveRecords.map {
                        ">\($0.fastaRecordID)\nACGT"
                    }.joined(separator: "\n") + "\n").utf8
                )
            } else {
                effectiveRecords = records
                genotypeCSV = """
                sample,genotype,passed_alignments,passed_unique_reads
                SampleA,\(genotype),9,8
                """
                fastaData = Data(
                    ">\(fastaRecordID)\n\(fastaSequence)\n".utf8
                )
            }
            try genotypeCSV.write(
                to: genotypeCSVURL,
                atomically: true,
                encoding: .utf8
            )
            try """
            sample,passed_alignments,passed_unique_reads
            SampleA,9,8
            """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)

            bamURL = bundleURL.appendingPathComponent("run.retained.demuxed.bam")
            baiURL = bundleURL.appendingPathComponent("run.retained.demuxed.bam.bai")
            let bamData = Data("bam".utf8)
            let baiData = Data("bai".utf8)
            try bamData.write(to: bamURL)
            try baiData.write(to: baiURL)

            let sequenceDirectory = bundleURL.appendingPathComponent("artifacts/sequences", isDirectory: true)
            try FileManager.default.createDirectory(at: sequenceDirectory, withIntermediateDirectories: true)
            catalogURL = sequenceDirectory.appendingPathComponent("observed-provisional-exon2.json")
            fastaURL = sequenceDirectory.appendingPathComponent("observed-provisional-exon2.fasta")
            let catalogData = try JSONEncoder().encode(
                ONTGenotypeProvisionalExon2Document(records: effectiveRecords)
            )
            try catalogData.write(to: catalogURL)
            try fastaData.write(to: fastaURL)

            let bamReference = ONTMHCArtifactReference(
                path: alignmentBAMPath,
                sha256: corruptBAMChecksum
                    ? String(repeating: "0", count: 64)
                    : Self.sha256(bamData),
                sizeBytes: Int64(bamData.count)
            )
            let manifest = ONTGenotypeResultBundleManifest(
                outputName: "miseq",
                analysisName: "miSeq",
                primaryWorkbookPath: workbookURL.lastPathComponent,
                longSummaryCSVPath: genotypeCSVURL.lastPathComponent,
                sampleSummaryCSVPath: sampleCSVURL.lastPathComponent,
                statsJSONPath: statsURL.lastPathComponent,
                provenancePath: provenanceURL.lastPathComponent,
                alignmentArtifacts: ONTGenotypeAlignmentArtifactManifest(
                    genotypingEvidence: ONTMHCBAMArtifactPair(
                        bam: bamReference,
                        bai: ONTMHCArtifactReference(
                            path: baiURL.lastPathComponent,
                            sha256: Self.sha256(baiData),
                            sizeBytes: Int64(baiData.count)
                        )
                    ),
                    reciprocalEvidence: nil
                ),
                provisionalExon2Artifacts: ONTGenotypeProvisionalExon2ArtifactManifest(
                    schemaVersion: 1,
                    catalogJSON: ONTMHCArtifactReference(
                        path: "artifacts/sequences/\(catalogURL.lastPathComponent)",
                        sha256: Self.sha256(catalogData),
                        sizeBytes: Int64(catalogData.count)
                    ),
                    sequencesFASTA: ONTMHCArtifactReference(
                        path: "artifacts/sequences/\(fastaURL.lastPathComponent)",
                        sha256: Self.sha256(fastaData),
                        sizeBytes: Int64(fastaData.count)
                    )
                )
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func writeAnnotatedReferenceRecordStore(
        in bundleURL: URL
    ) throws -> ONTGenotypeReferenceRecordStoreInfo {
        let databaseURL = bundleURL.appendingPathComponent("metadata/genbank_records.sqlite")
        let record = GenBankRecord(
            sequence: try Sequence(name: "NHP01222", alphabet: .dna, bases: "ACGT"),
            annotations: [
                SequenceAnnotation(
                    type: .gene,
                    name: "Mafa-A1*006:01:02",
                    start: 0,
                    end: 4,
                    qualifiers: [
                        "gene": AnnotationQualifier("A1"),
                        "allele": AnnotationQualifier("Mafa-A1*006:01:02"),
                    ]
                ),
            ],
            locus: LocusInfo(name: "NHP01222", length: 4, moleculeType: .dna, topology: .linear),
            definition: "Mafa-A1*006:01:02, A1 locus allele.",
            accession: "NHP01222"
        )
        let created = try GenBankRecordDatabase.create(records: [record], at: databaseURL)
        let bytes = try Data(contentsOf: databaseURL)
        return ONTGenotypeReferenceRecordStoreInfo(
            databasePath: "metadata/genbank_records.sqlite",
            recordCount: created.recordCount,
            fieldCount: created.fieldCount,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(bytes.count)
        )
    }

    private final class CandidateBundleFixture {
        let rootURL: URL
        let bundleURL: URL
        let candidateJSONURL: URL
        let candidateFASTAURL: URL
        let unnameableJSONURL: URL
        let unnameableFASTAURL: URL
        let candidateID: String
        let unnameableID = "unnameable-sequence"

        init(
            kind: String = "full-length-ont-mhc-genotype",
            includeCandidateArtifacts: Bool = true,
            includeGenBankArtifacts: Bool = false,
            candidateDirectory: String = "",
            candidateArtifactManifestSchemaVersion: Int = 1,
            candidateSchemaVersion: Int = 1,
            unnameableSchemaVersion: Int? = nil,
            candidateID: String = "candidate-sequence",
            candidateSequence: String = "ACGT",
            candidateSourceSequenceClusterIDs: [String]? = nil,
            candidateRepresentativeSourceSequenceClusterID: String? = nil,
            candidateObservationSourceSequenceClusterID: String? = nil,
            candidateSelectedQueryOverride: String? = nil,
            candidateFASTAIDs: [String]? = nil,
            unnameableHasExternalSequence: Bool = true,
            documentCandidateFASTAPath: String? = nil,
            genotypingBAMPath: String = "artifacts/alignments/genotyping.bam",
            genotypingBAIPath: String = "artifacts/alignments/genotyping.bam.bai",
            reciprocalBAMPath: String = "artifacts/alignments/reciprocal.bam",
            reciprocalBAIPath: String = "artifacts/alignments/reciprocal.bam.bai",
            swappedEvidenceRoles: Bool = false,
            reciprocalLocatorPathOverride: String? = nil,
            genotypingSummaryBAMPathOverride: String? = nil,
            reciprocalSummaryBAMPathOverride: String? = nil,
            reciprocalSummaryQueryOverride: String? = nil,
            genotypingSummaryTargetOverride: String? = nil,
            selectedClosestMismatch: Bool = false,
            omitV2CandidateReciprocalSummary: Bool = false,
            unnameableSelectedClosestMismatch: Bool = false
        ) throws {
            self.candidateID = candidateID
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ONTGenotypeCandidateFixture-\(UUID().uuidString)", isDirectory: true)
            bundleURL = rootURL.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let workbook = bundleURL.appendingPathComponent("result.xlsx")
            let calls = bundleURL.appendingPathComponent("calls.csv")
            let samples = bundleURL.appendingPathComponent("samples.csv")
            let stats = bundleURL.appendingPathComponent("stats.json")
            let provenance = bundleURL.appendingPathComponent("provenance.json")
            try Data("workbook".utf8).write(to: workbook)
            try Data("{}".utf8).write(to: stats)
            try Data("{}".utf8).write(to: provenance)
            try Data("sample,genotype,passed_alignments,passed_unique_reads\nSampleA,known-allele,8,8\n".utf8)
                .write(to: calls)
            try Data("sample,passed_alignments,passed_unique_reads\nSampleA,8,8\n".utf8)
                .write(to: samples)

            let candidateRoot = candidateDirectory.isEmpty
                ? bundleURL
                : bundleURL.appendingPathComponent(candidateDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
            candidateJSONURL = candidateRoot.appendingPathComponent("candidate-alleles.json")
            candidateFASTAURL = candidateRoot.appendingPathComponent("candidate_alleles.fasta")
            unnameableJSONURL = candidateRoot.appendingPathComponent("unnameable.json")
            unnameableFASTAURL = candidateRoot.appendingPathComponent("unnameable.fasta")
            let candidateGenBankURL = candidateRoot.appendingPathComponent("candidate_alleles.gb")
            let unnameableGenBankURL = candidateRoot.appendingPathComponent("unnameable_unmatched_clusters.gb")
            let genotypingBAM = bundleURL.appendingPathComponent(genotypingBAMPath)
            let genotypingBAI = bundleURL.appendingPathComponent(genotypingBAIPath)
            let reciprocalBAM = bundleURL.appendingPathComponent(reciprocalBAMPath)
            let reciprocalBAI = bundleURL.appendingPathComponent(reciprocalBAIPath)
            for url in [genotypingBAM, genotypingBAI, reciprocalBAM, reciprocalBAI] {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try Data("bam-one".utf8).write(to: genotypingBAM)
            try Data("bai-one".utf8).write(to: genotypingBAI)
            try Data("bam-two".utf8).write(to: reciprocalBAM)
            try Data("bai-two".utf8).write(to: reciprocalBAI)

            let unnameableSequence = "TGCA"
            let candidateFASTA = (candidateFASTAIDs ?? [candidateID])
                .map { ">\($0)\n\($0 == "extra" ? "AAAA" : candidateSequence)\n" }
                .joined()
            try Data(candidateFASTA.utf8).write(to: candidateFASTAURL)
            let unnameableFASTAData = unnameableHasExternalSequence
                ? Data(">\(unnameableID)\n\(unnameableSequence)\n".utf8)
                : Data()
            try unnameableFASTAData.write(to: unnameableFASTAURL)
            if includeGenBankArtifacts {
                try Data("LOCUS       \(candidateID)\n//\n".utf8).write(to: candidateGenBankURL)
                try Data("LOCUS       \(unnameableID)\n//\n".utf8).write(to: unnameableGenBankURL)
            }

            let candidateRelative = Self.relative("candidate-alleles.json", directory: candidateDirectory)
            let candidateFASTARelative = Self.relative("candidate_alleles.fasta", directory: candidateDirectory)
            let unnameableRelative = Self.relative("unnameable.json", directory: candidateDirectory)
            let unnameableFASTARelative = Self.relative("unnameable.fasta", directory: candidateDirectory)
            let genotypingPair = try Self.pair(
                bam: genotypingBAM, bamPath: genotypingBAMPath,
                bai: genotypingBAI, baiPath: genotypingBAIPath
            )
            let reciprocalPair = try Self.pair(
                bam: reciprocalBAM, bamPath: reciprocalBAMPath,
                bai: reciprocalBAI, baiPath: reciprocalBAIPath
            )
            let candidateFASTAReference = try Self.reference(
                candidateFASTAURL,
                path: documentCandidateFASTAPath ?? candidateFASTARelative
            )
            let actualCandidateFASTAReference = try Self.reference(candidateFASTAURL, path: candidateFASTARelative)
            let unnameableFASTAReference = try Self.reference(unnameableFASTAURL, path: unnameableFASTARelative)
            let evidence = [genotypingPair.bam, genotypingPair.bai, reciprocalPair.bam, reciprocalPair.bai]
            let reciprocalLocatorPath = reciprocalLocatorPathOverride
                ?? (swappedEvidenceRoles ? genotypingPair.bam.path : reciprocalPair.bam.path)
            let genotypingLocatorPath = swappedEvidenceRoles ? reciprocalPair.bam.path : genotypingPair.bam.path
            let sourceSequenceClusterIDs = candidateSourceSequenceClusterIDs ?? [candidateID]
            let representativeSourceSequenceClusterID =
                candidateRepresentativeSourceSequenceClusterID ?? candidateID
            let locator = ONTMHCEvidenceLocator(
                bamPath: reciprocalLocatorPath,
                queryName: candidateSelectedQueryOverride ?? representativeSourceSequenceClusterID,
                referenceName: "Mafa-A1*001:01",
                readGroupID: nil,
                referenceStart: 1,
                cigar: "4="
            )
            let candidateReciprocalSummary = try ONTMHCReciprocalQueryHitSummary(
                bamPath: reciprocalSummaryBAMPathOverride ?? reciprocalLocatorPath,
                queryName: reciprocalSummaryQueryOverride ?? representativeSourceSequenceClusterID,
                alignmentCount: selectedClosestMismatch ? 2 : 1,
                targetAlignmentCounts: selectedClosestMismatch
                    ? ["Mafa-A1*001:01": 1, "Mafa-A1*999:01": 1]
                    : ["Mafa-A1*001:01": 1],
                exactMatchTargetNames: [],
                closestMatchTargetNames: selectedClosestMismatch
                    ? ["Mafa-A1*999:01"]
                    : ["Mafa-A1*001:01"]
            )
            let candidateRecord = ONTMHCCandidateRecord(
                stableClusterID: candidateID,
                sourceSequenceClusterIDs: sourceSequenceClusterIDs,
                representativeSourceSequenceClusterID: representativeSourceSequenceClusterID,
                provisionalName: "Mafa-A1*001:01_1nt_nov",
                locus: "Mafa-A1",
                classification: .novel,
                supportClass: .singleton,
                closestReferenceName: "Mafa-A1*001:01",
                closestReferenceClass: .genomicDNA,
                snpCount: 1,
                insertedBases: 0,
                deletedBases: 0,
                longGapBases: 0,
                comparableBases: 4,
                shorterCoverage: 1,
                identity: 0.75,
                mappingQuality: 60,
                alignmentScore: 3,
                independentSampleCount: 1,
                occurrenceCount: 1,
                totalClusterReads: 8,
                supportingSampleIDs: ["SampleA"],
                fastaRecordID: candidateID,
                sequenceSHA256: Self.sha256(Data(candidateSequence.uppercased().utf8)),
                reciprocalHitSummary: candidateReciprocalSummary,
                selectedEvidence: locator
            )
            let candidateObservation: ONTMHCCandidateObservation
            if candidateSchemaVersion == 1 {
                candidateObservation = ONTMHCCandidateObservation(
                    stableClusterID: candidateID,
                    sourceSequenceClusterID: candidateObservationSourceSequenceClusterID ?? candidateID,
                    sampleID: "SampleA",
                    readGroupID: "SampleA",
                    sourceClusterIDs: ["source-candidate"],
                    sourceClusterReadCounts: ["source-candidate": 8],
                    aggregatedSampleReadCount: 8,
                    evidence: [ONTMHCEvidenceLocator(
                        bamPath: genotypingLocatorPath,
                        queryName: "Mafa-A1*001:01",
                        referenceName: "SampleA|source-candidate",
                        readGroupID: "SampleA",
                        referenceStart: 1,
                        cigar: "4="
                    )]
                )
            } else {
                candidateObservation = ONTMHCCandidateObservation(
                    stableClusterID: candidateID,
                    sourceSequenceClusterID: candidateObservationSourceSequenceClusterID ?? candidateID,
                    sampleID: "SampleA",
                    readGroupID: "SampleA",
                    sourceClusterIDs: ["source-candidate"],
                    sourceClusterReadCounts: ["source-candidate": 8],
                    aggregatedSampleReadCount: 8,
                    genotypingHitSummaries: [try ONTMHCGenotypingTargetHitSummary(
                        bamPath: genotypingSummaryBAMPathOverride ?? genotypingLocatorPath,
                        targetName: genotypingSummaryTargetOverride ?? "SampleA|source-candidate",
                        alignmentCount: 1,
                        queryAlignmentCounts: ["Mafa-A1*001:01": 1],
                        exactMatchQueryNames: ["Mafa-A1*001:01"],
                        closestMatchQueryNames: ["Mafa-A1*001:01"]
                    )]
                )
            }
            let candidateDocument = ONTMHCCandidateAllelesDocument(
                schemaVersion: candidateSchemaVersion,
                createdAt: "2026-07-19T00:00:00Z",
                thresholds: .defaults,
                inputs: [],
                evidence: evidence,
                sequenceFASTA: candidateFASTAReference,
                candidates: [candidateRecord],
                observations: [candidateObservation]
            )
            let unnameableReciprocalLocator = ONTMHCEvidenceLocator(
                bamPath: reciprocalLocatorPath,
                queryName: unnameableID,
                referenceName: "Mafa-A1*001:01",
                readGroupID: nil,
                referenceStart: 1,
                cigar: "4="
            )
            let resolvedUnnameableSchemaVersion = unnameableSchemaVersion ?? candidateSchemaVersion
            let unnameableRecord: ONTMHCUnnameableRecord
            let unnameableObservation: ONTMHCCandidateObservation
            if resolvedUnnameableSchemaVersion == 1 {
                unnameableRecord = ONTMHCUnnameableRecord(
                    stableClusterID: unnameableID,
                    reason: .insufficientIdentity,
                    failedMetrics: ["identity": 0.5],
                    supportClass: .singleton,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 4,
                    supportingSampleIDs: ["SampleB"],
                    fastaRecordID: unnameableHasExternalSequence ? unnameableID : nil,
                    sequenceSHA256: unnameableHasExternalSequence
                        ? Self.sha256(Data(unnameableSequence.utf8))
                        : nil,
                    evidence: [unnameableReciprocalLocator]
                )
                unnameableObservation = ONTMHCCandidateObservation(
                    stableClusterID: unnameableID,
                    sampleID: "SampleB",
                    readGroupID: "SampleB",
                    sourceClusterIDs: ["source-unnameable"],
                    sourceClusterReadCounts: ["source-unnameable": 4],
                    aggregatedSampleReadCount: 4,
                    evidence: [ONTMHCEvidenceLocator(
                        bamPath: genotypingLocatorPath,
                        queryName: "Mafa-A1*001:01",
                        referenceName: "SampleB|source-unnameable",
                        readGroupID: "SampleB",
                        referenceStart: 1,
                        cigar: "4="
                    )]
                )
            } else {
                unnameableRecord = ONTMHCUnnameableRecord(
                    stableClusterID: unnameableID,
                    reason: unnameableSelectedClosestMismatch ? .insufficientIdentity : .noAlignment,
                    failedMetrics: unnameableSelectedClosestMismatch ? ["identity": 0.5] : [:],
                    supportClass: .singleton,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 4,
                    supportingSampleIDs: ["SampleB"],
                    fastaRecordID: unnameableHasExternalSequence ? unnameableID : nil,
                    sequenceSHA256: unnameableHasExternalSequence
                        ? Self.sha256(Data(unnameableSequence.utf8))
                        : nil,
                    reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                        bamPath: reciprocalSummaryBAMPathOverride ?? reciprocalLocatorPath,
                        queryName: unnameableID,
                        alignmentCount: unnameableSelectedClosestMismatch ? 2 : 0,
                        targetAlignmentCounts: unnameableSelectedClosestMismatch
                            ? ["Mafa-A1*001:01": 1, "Mafa-A1*999:01": 1]
                            : [:],
                        exactMatchTargetNames: [],
                        closestMatchTargetNames: unnameableSelectedClosestMismatch
                            ? ["Mafa-A1*999:01"]
                            : []
                    ),
                    selectedEvidence: unnameableSelectedClosestMismatch
                        ? unnameableReciprocalLocator
                        : nil
                )
                unnameableObservation = ONTMHCCandidateObservation(
                    stableClusterID: unnameableID,
                    sampleID: "SampleB",
                    readGroupID: "SampleB",
                    sourceClusterIDs: ["source-unnameable"],
                    sourceClusterReadCounts: ["source-unnameable": 4],
                    aggregatedSampleReadCount: 4,
                    genotypingHitSummaries: [try ONTMHCGenotypingTargetHitSummary(
                        bamPath: genotypingSummaryBAMPathOverride ?? genotypingLocatorPath,
                        targetName: "SampleB|source-unnameable",
                        alignmentCount: 1,
                        queryAlignmentCounts: ["Mafa-A1*001:01": 1],
                        exactMatchQueryNames: ["Mafa-A1*001:01"],
                        closestMatchQueryNames: ["Mafa-A1*001:01"]
                    )]
                )
            }
            let unnameableDocument = ONTMHCUnnameableClustersDocument(
                schemaVersion: resolvedUnnameableSchemaVersion,
                createdAt: "2026-07-19T00:00:00Z",
                thresholds: .defaults,
                evidence: evidence,
                sequenceFASTA: unnameableFASTAReference,
                clusters: [unnameableRecord],
                observations: [unnameableObservation]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var candidateJSON = try encoder.encode(candidateDocument)
            if (candidateSchemaVersion == 1 || omitV2CandidateReciprocalSummary),
               var object = try JSONSerialization.jsonObject(with: candidateJSON) as? [String: Any],
               var records = object["candidates"] as? [[String: Any]] {
                for index in records.indices { records[index].removeValue(forKey: "reciprocal_hit_summary") }
                object["candidates"] = records
                candidateJSON = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
            }
            try candidateJSON.write(to: candidateJSONURL)
            try encoder.encode(unnameableDocument).write(to: unnameableJSONURL)

            let artifacts: ONTMHCCandidateArtifactManifest? = includeCandidateArtifacts
                ? try ONTMHCCandidateArtifactManifest(
                    schemaVersion: candidateArtifactManifestSchemaVersion,
                    genotypingEvidence: genotypingPair,
                    reciprocalEvidence: reciprocalPair,
                    candidateJSON: Self.reference(candidateJSONURL, path: candidateRelative),
                    candidateFASTA: actualCandidateFASTAReference,
                    candidateGenBank: includeGenBankArtifacts
                        ? Self.reference(
                            candidateGenBankURL,
                            path: Self.relative("candidate_alleles.gb", directory: candidateDirectory)
                        )
                        : nil,
                    unnameableJSON: Self.reference(unnameableJSONURL, path: unnameableRelative),
                    unnameableFASTA: unnameableFASTAReference,
                    unnameableGenBank: includeGenBankArtifacts
                        ? Self.reference(
                            unnameableGenBankURL,
                            path: Self.relative("unnameable_unmatched_clusters.gb", directory: candidateDirectory)
                        )
                        : nil
                )
                : nil
            let manifest = ONTGenotypeResultBundleManifest(
                kind: kind,
                outputName: "result",
                analysisName: "result",
                primaryWorkbookPath: workbook.lastPathComponent,
                longSummaryCSVPath: calls.lastPathComponent,
                sampleSummaryCSVPath: samples.lastPathComponent,
                statsJSONPath: stats.lastPathComponent,
                provenancePath: provenance.lastPathComponent,
                mhcCandidateArtifacts: artifacts
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func replaceCandidateJSON(_ data: Data) throws {
            try data.write(to: candidateJSONURL)
            try rewriteManifest { artifacts in
                ONTMHCCandidateArtifactManifest(
                    schemaVersion: artifacts.schemaVersion,
                    genotypingEvidence: artifacts.genotypingEvidence,
                    reciprocalEvidence: artifacts.reciprocalEvidence,
                    candidateJSON: try! Self.reference(candidateJSONURL, path: artifacts.candidateJSON!.path),
                    candidateFASTA: artifacts.candidateFASTA,
                    unnameableJSON: artifacts.unnameableJSON,
                    unnameableFASTA: artifacts.unnameableFASTA
                )
            }
        }

        func replaceUnnameableJSON(_ data: Data) throws {
            try data.write(to: unnameableJSONURL)
            try rewriteManifest { artifacts in
                ONTMHCCandidateArtifactManifest(
                    schemaVersion: artifacts.schemaVersion,
                    genotypingEvidence: artifacts.genotypingEvidence,
                    reciprocalEvidence: artifacts.reciprocalEvidence,
                    candidateJSON: artifacts.candidateJSON,
                    candidateFASTA: artifacts.candidateFASTA,
                    candidateGenBank: artifacts.candidateGenBank,
                    unnameableJSON: try! Self.reference(
                        unnameableJSONURL,
                        path: artifacts.unnameableJSON!.path
                    ),
                    unnameableFASTA: artifacts.unnameableFASTA,
                    unnameableGenBank: artifacts.unnameableGenBank,
                    rawUnmatchedFASTA: artifacts.rawUnmatchedFASTA,
                    sourceIdentityMap: artifacts.sourceIdentityMap
                )
            }
        }

        func replaceCandidateJSONWithFIFO() throws {
            try FileManager.default.removeItem(at: candidateJSONURL)
            let status = candidateJSONURL.path.withCString { Darwin.mkfifo($0, 0o600) }
            guard status == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try rewriteManifest { artifacts in
                ONTMHCCandidateArtifactManifest(
                    schemaVersion: artifacts.schemaVersion,
                    genotypingEvidence: artifacts.genotypingEvidence,
                    reciprocalEvidence: artifacts.reciprocalEvidence,
                    candidateJSON: ONTMHCArtifactReference(
                        path: artifacts.candidateJSON!.path,
                        sha256: Self.sha256(Data()),
                        sizeBytes: 0
                    ),
                    candidateFASTA: artifacts.candidateFASTA,
                    unnameableJSON: artifacts.unnameableJSON,
                    unnameableFASTA: artifacts.unnameableFASTA
                )
            }
        }

        func rewriteManifest(
            _ transform: (ONTMHCCandidateArtifactManifest) -> ONTMHCCandidateArtifactManifest
        ) throws {
            let old = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
            let artifacts = transform(try XCTUnwrap(old.mhcCandidateArtifacts))
            let updated = ONTGenotypeResultBundleManifest(
                kind: old.kind,
                outputName: old.outputName,
                analysisName: old.analysisName,
                primaryWorkbookPath: old.primaryWorkbookPath,
                currentWorkbookPath: old.currentWorkbookPath,
                workbookRevisions: old.workbookRevisions,
                longSummaryCSVPath: old.longSummaryCSVPath,
                sampleSummaryCSVPath: old.sampleSummaryCSVPath,
                statsJSONPath: old.statsJSONPath,
                provenancePath: old.provenancePath,
                deduplicatedUnmatchedClustersFASTAPath: old.deduplicatedUnmatchedClustersFASTAPath,
                haplotypeAnalysisPath: old.haplotypeAnalysisPath,
                haplotypeDefinitionSetID: old.haplotypeDefinitionSetID,
                haplotypeAssayID: old.haplotypeAssayID,
                presetID: old.presetID,
                presetVersion: old.presetVersion,
                createdAt: old.createdAt,
                activeHaplotypeAnalysisRevisionID: old.activeHaplotypeAnalysisRevisionID,
                haplotypeAnalysisRevisions: old.haplotypeAnalysisRevisions,
                mhcCandidateArtifacts: artifacts
            )
            try ONTGenotypeResultBundle.writeManifest(updated, to: bundleURL)
        }

        private static func relative(_ filename: String, directory: String) -> String {
            directory.isEmpty ? filename : "\(directory)/\(filename)"
        }

        private static func pair(
            bam: URL,
            bamPath: String,
            bai: URL,
            baiPath: String
        ) throws -> ONTMHCBAMArtifactPair {
            ONTMHCBAMArtifactPair(
                bam: try reference(bam, path: bamPath),
                bai: try reference(bai, path: baiPath)
            )
        }

        private static func reference(_ url: URL, path: String) throws -> ONTMHCArtifactReference {
            let data = try Data(contentsOf: url)
            return ONTMHCArtifactReference(
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

private extension GenotypeReviewableRowCatalog {
    func replacingSupport(row index: Int, with support: [String: Int]) -> Self {
        replacingRow(
            index,
            with: Row(
                kind: rows[index].kind,
                callID: rows[index].callID,
                displayName: rows[index].displayName,
                locus: rows[index].locus,
                stableID: rows[index].stableID,
                section: rows[index].section,
                sortKey: rows[index].sortKey,
                supportBySample: support
            )
        )
    }

    func replacingRow(_ index: Int, with row: Row) -> Self {
        var updatedRows = rows
        updatedRows[index] = row
        return Self(
            schemaID: schemaID,
            schemaVersion: schemaVersion,
            samples: samples,
            rows: updatedRows
        )
    }
}

private struct WorkflowModeDecimalEnvelope: Decodable {
    let workflowMode: Decimal
}

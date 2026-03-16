import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexPlanTests: XCTestCase {

    // MARK: - DemultiplexStep

    func testDemultiplexStepDefaults() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        XCTAssertEqual(step.label, "Test")
        XCTAssertEqual(step.barcodeKitID, "NBD114")
        XCTAssertEqual(step.barcodeLocation, .bothEnds)
        XCTAssertEqual(step.symmetryMode, .symmetric)
        XCTAssertEqual(step.errorRate, 0.15, accuracy: 0.001)
        XCTAssertEqual(step.minimumOverlap, 20)
        XCTAssertTrue(step.searchReverseComplement)
        XCTAssertTrue(step.sampleAssignments.isEmpty)
        XCTAssertEqual(step.ordinal, 0)
    }

    func testDemultiplexStepIdentifiable() {
        let step1 = DemultiplexStep(label: "A", barcodeKitID: "NBD114")
        let step2 = DemultiplexStep(label: "B", barcodeKitID: "NBD114")
        XCTAssertNotEqual(step1.id, step2.id)
    }

    func testDemultiplexStepCodableRoundTrip() throws {
        let step = DemultiplexStep(
            label: "Outer",
            barcodeKitID: "NBD114",
            barcodeLocation: .fivePrime,
            symmetryMode: .asymmetric,
            errorRate: 0.20,
            minimumOverlap: 20,
            searchReverseComplement: false,
            ordinal: 1
        )
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(DemultiplexStep.self, from: data)
        XCTAssertEqual(decoded.label, "Outer")
        XCTAssertEqual(decoded.barcodeKitID, "NBD114")
        XCTAssertEqual(decoded.barcodeLocation, .fivePrime)
        XCTAssertEqual(decoded.symmetryMode, .asymmetric)
        XCTAssertEqual(decoded.errorRate, 0.20, accuracy: 0.001)
        XCTAssertEqual(decoded.minimumOverlap, 20)
        XCTAssertFalse(decoded.searchReverseComplement)
        XCTAssertEqual(decoded.ordinal, 1)
    }

    // MARK: - DemultiplexPlan

    func testDemultiplexPlanIsSingleStep() {
        let empty = DemultiplexPlan()
        XCTAssertTrue(empty.isSingleStep)

        let single = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114"),
        ])
        XCTAssertTrue(single.isSingleStep)

        let multi = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114", ordinal: 0),
            DemultiplexStep(label: "Step 1", barcodeKitID: "RBK114", ordinal: 1),
        ])
        XCTAssertFalse(multi.isSingleStep)
    }

    func testDemultiplexPlanValidateEmptyThrows() {
        let plan = DemultiplexPlan()
        XCTAssertThrowsError(try plan.validate()) { error in
            guard case DemultiplexPlanError.noSteps = error else {
                XCTFail("Expected noSteps error, got \(error)")
                return
            }
        }
    }

    func testDemultiplexPlanValidateMissingKitThrows() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Bad Step", barcodeKitID: ""),
        ])
        XCTAssertThrowsError(try plan.validate()) { error in
            if case .missingKit(let step) = error as? DemultiplexPlanError {
                XCTAssertEqual(step, "Bad Step")
            } else {
                XCTFail("Expected missingKit error")
            }
        }
    }

    func testDemultiplexPlanValidateSucceeds() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114"),
        ])
        XCTAssertNoThrow(try plan.validate())
    }

    func testDemultiplexPlanCompositeSampleNames() {
        let plan = DemultiplexPlan(
            steps: [DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114")],
            compositeSampleNames: ["BC01/bc1003--bc1016": "Patient-042"]
        )
        XCTAssertEqual(plan.compositeSampleNames["BC01/bc1003--bc1016"], "Patient-042")
    }

    func testDemultiplexPlanCodableRoundTrip() throws {
        let plan = DemultiplexPlan(
            steps: [
                DemultiplexStep(label: "Outer", barcodeKitID: "NBD114", ordinal: 0),
                DemultiplexStep(label: "Inner", barcodeKitID: "RBK114", ordinal: 1),
            ],
            compositeSampleNames: ["BC01/BC02": "Sample-A"]
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(DemultiplexPlan.self, from: data)
        XCTAssertEqual(decoded.steps.count, 2)
        XCTAssertEqual(decoded.steps[0].label, "Outer")
        XCTAssertEqual(decoded.steps[1].label, "Inner")
        XCTAssertEqual(decoded.compositeSampleNames["BC01/BC02"], "Sample-A")
    }

    // MARK: - DemultiplexPlanError

    func testDemultiplexPlanErrorDescriptions() {
        XCTAssertNotNil(DemultiplexPlanError.noSteps.errorDescription)
        XCTAssertNotNil(DemultiplexPlanError.missingKit(step: "Test").errorDescription)
        XCTAssertTrue(
            DemultiplexPlanError.missingKit(step: "Outer").errorDescription?.contains("Outer") == true
        )
    }

    func testDemultiplexPlanErrorIsLocalizedError() {
        let error: Error = DemultiplexPlanError.noSteps
        XCTAssertNotNil(error.localizedDescription)
    }

    // MARK: - DemultiplexError

    func testDemultiplexErrorNoOutputResults() {
        let error = DemultiplexError.noOutputResults
        XCTAssertNotNil(error.errorDescription)
    }

    func testDemultiplexErrorBundleCreationFailed() {
        let error = DemultiplexError.bundleCreationFailed(barcode: "BC01", underlying: "disk full")
        XCTAssertTrue(error.errorDescription?.contains("BC01") == true)
        XCTAssertTrue(error.errorDescription?.contains("disk full") == true)
    }

    // MARK: - DemultiplexStep New Fields

    func testDemultiplexStepTrimBarcodesDefault() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        XCTAssertTrue(step.trimBarcodes)
    }

    func testDemultiplexStepUnassignedDispositionDefault() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        XCTAssertEqual(step.unassignedDisposition, .keep)
    }

    func testDemultiplexStepCustomTrimAndDisposition() {
        let step = DemultiplexStep(
            label: "No Trim",
            barcodeKitID: "NBD114",
            trimBarcodes: false,
            unassignedDisposition: .discard
        )
        XCTAssertFalse(step.trimBarcodes)
        XCTAssertEqual(step.unassignedDisposition, .discard)
    }

    func testDemultiplexStepCodableWithNewFields() throws {
        let step = DemultiplexStep(
            label: "Step",
            barcodeKitID: "NBD114",
            trimBarcodes: false,
            unassignedDisposition: .discard
        )
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(DemultiplexStep.self, from: data)
        XCTAssertFalse(decoded.trimBarcodes)
        XCTAssertEqual(decoded.unassignedDisposition, .discard)
    }

    func testDemultiplexStepEquatableWithNewFields() {
        let step1 = DemultiplexStep(
            id: UUID(),
            label: "A",
            barcodeKitID: "NBD114",
            trimBarcodes: true,
            unassignedDisposition: .keep
        )
        var step2 = step1
        XCTAssertEqual(step1, step2)

        step2.trimBarcodes = false
        XCTAssertNotEqual(step1, step2)
    }

    // MARK: - DemultiplexPlan Validation Edge Cases

    func testDemultiplexPlanMultipleStepsValidate() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Outer", barcodeKitID: "NBD114", ordinal: 0),
            DemultiplexStep(label: "Inner", barcodeKitID: "RBK114", ordinal: 1),
        ])
        XCTAssertNoThrow(try plan.validate())
    }

    func testDemultiplexPlanSecondStepMissingKit() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Outer", barcodeKitID: "NBD114", ordinal: 0),
            DemultiplexStep(label: "Inner", barcodeKitID: "", ordinal: 1),
        ])
        XCTAssertThrowsError(try plan.validate()) { error in
            if case .missingKit(let step) = error as? DemultiplexPlanError {
                XCTAssertEqual(step, "Inner")
            } else {
                XCTFail("Expected missingKit for Inner step")
            }
        }
    }

    func testDemultiplexPlanStepMutability() {
        var plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114"),
        ])
        plan.steps[0].trimBarcodes = false
        XCTAssertFalse(plan.steps[0].trimBarcodes)
    }

    // MARK: - StepResult

    func testStepResultWallClockSecondsDefault() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        let result = MultiStepDemultiplexResult.StepResult(step: step, perBinResults: [])
        XCTAssertEqual(result.wallClockSeconds, 0)
    }

    func testStepResultWallClockSecondsCustom() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        let result = MultiStepDemultiplexResult.StepResult(
            step: step, perBinResults: [], wallClockSeconds: 42.5
        )
        XCTAssertEqual(result.wallClockSeconds, 42.5, accuracy: 0.01)
    }

    // MARK: - MultiStepProvenance

    func testMultiStepProvenanceInit() {
        let provenance = MultiStepProvenance(
            totalSteps: 2,
            stepSummaries: [
                .init(
                    label: "Outer",
                    barcodeKitID: "NBD114",
                    symmetryMode: .symmetric,
                    errorRate: 0.15,
                    inputBinCount: 1,
                    outputBundleCount: 24,
                    totalReadsProcessed: 100_000,
                    wallClockSeconds: 30.0
                ),
                .init(
                    label: "Inner",
                    barcodeKitID: "RBK114",
                    symmetryMode: .singleEnd,
                    errorRate: 0.20,
                    inputBinCount: 24,
                    outputBundleCount: 384,
                    totalReadsProcessed: 90_000,
                    wallClockSeconds: 120.0
                ),
            ],
            compositeSampleNames: ["BC01/BC02": "Sample-A"],
            totalWallClockSeconds: 150.0
        )
        XCTAssertEqual(provenance.totalSteps, 2)
        XCTAssertEqual(provenance.stepSummaries.count, 2)
        XCTAssertEqual(provenance.stepSummaries[0].label, "Outer")
        XCTAssertEqual(provenance.stepSummaries[1].label, "Inner")
        XCTAssertEqual(provenance.compositeSampleNames["BC01/BC02"], "Sample-A")
        XCTAssertEqual(provenance.totalWallClockSeconds, 150.0, accuracy: 0.01)
    }

    func testMultiStepProvenanceCodableRoundTrip() throws {
        let provenance = MultiStepProvenance(
            totalSteps: 1,
            stepSummaries: [
                .init(
                    label: "Only Step",
                    barcodeKitID: "NBD114",
                    symmetryMode: .symmetric,
                    errorRate: 0.15,
                    inputBinCount: 1,
                    outputBundleCount: 12,
                    totalReadsProcessed: 50_000,
                    wallClockSeconds: 10.0
                ),
            ],
            compositeSampleNames: [:],
            totalWallClockSeconds: 10.0
        )
        let data = try JSONEncoder().encode(provenance)
        let decoded = try JSONDecoder().decode(MultiStepProvenance.self, from: data)
        XCTAssertEqual(decoded.totalSteps, 1)
        XCTAssertEqual(decoded.stepSummaries.count, 1)
        XCTAssertEqual(decoded.stepSummaries[0].barcodeKitID, "NBD114")
        XCTAssertEqual(decoded.stepSummaries[0].inputBinCount, 1)
        XCTAssertEqual(decoded.stepSummaries[0].outputBundleCount, 12)
    }

    func testMultiStepProvenanceEquatable() {
        let summary = MultiStepProvenance.StepSummary(
            label: "Step",
            barcodeKitID: "NBD114",
            symmetryMode: .symmetric,
            errorRate: 0.15,
            inputBinCount: 1,
            outputBundleCount: 12,
            totalReadsProcessed: 50_000,
            wallClockSeconds: 10.0
        )
        let prov1 = MultiStepProvenance(
            totalSteps: 1,
            stepSummaries: [summary],
            totalWallClockSeconds: 10.0
        )
        let prov2 = MultiStepProvenance(
            totalSteps: 1,
            stepSummaries: [summary],
            totalWallClockSeconds: 10.0
        )
        XCTAssertEqual(prov1, prov2)
    }

    func testMultiStepProvenanceDefaultCompositeSampleNames() {
        let provenance = MultiStepProvenance(
            totalSteps: 1,
            stepSummaries: []
        )
        XCTAssertTrue(provenance.compositeSampleNames.isEmpty)
        XCTAssertEqual(provenance.totalWallClockSeconds, 0)
    }

    // MARK: - DemultiplexManifest with Provenance

    func testManifestWithoutProvenance() {
        let manifest = DemultiplexManifest(
            barcodeKit: BarcodeKit(name: "NBD114", vendor: "ont", barcodeCount: 24),
            parameters: DemultiplexParameters(tool: "cutadapt"),
            barcodes: [],
            unassigned: UnassignedReadsSummary(readCount: 0, baseCount: 0),
            outputDirectoryRelativePath: "../output-demux/",
            inputReadCount: 0
        )
        XCTAssertNil(manifest.multiStepProvenance)
    }

    func testManifestWithProvenance() {
        let provenance = MultiStepProvenance(
            totalSteps: 2,
            stepSummaries: [
                .init(label: "Outer", barcodeKitID: "NBD114", symmetryMode: .symmetric,
                      errorRate: 0.15, inputBinCount: 1, outputBundleCount: 24,
                      totalReadsProcessed: 100_000, wallClockSeconds: 30.0),
            ],
            compositeSampleNames: ["BC01/BC02": "Patient-42"],
            totalWallClockSeconds: 30.0
        )
        let manifest = DemultiplexManifest(
            version: 2,
            barcodeKit: BarcodeKit(name: "NBD114", vendor: "ont", barcodeCount: 24),
            parameters: DemultiplexParameters(tool: "cutadapt"),
            barcodes: [],
            unassigned: UnassignedReadsSummary(readCount: 0, baseCount: 0),
            outputDirectoryRelativePath: "../output-demux/",
            inputReadCount: 100_000,
            multiStepProvenance: provenance
        )
        XCTAssertNotNil(manifest.multiStepProvenance)
        XCTAssertEqual(manifest.multiStepProvenance?.totalSteps, 2)
        XCTAssertEqual(manifest.version, 2)
    }

    func testManifestWithProvenanceCodableRoundTrip() throws {
        let provenance = MultiStepProvenance(
            totalSteps: 2,
            stepSummaries: [
                .init(label: "Outer", barcodeKitID: "NBD114", symmetryMode: .symmetric,
                      errorRate: 0.15, inputBinCount: 1, outputBundleCount: 12,
                      totalReadsProcessed: 50_000, wallClockSeconds: 15.0),
                .init(label: "Inner", barcodeKitID: "RBK114", symmetryMode: .singleEnd,
                      errorRate: 0.20, inputBinCount: 12, outputBundleCount: 96,
                      totalReadsProcessed: 45_000, wallClockSeconds: 60.0),
            ],
            compositeSampleNames: ["BC01/BC05": "SampleX"],
            totalWallClockSeconds: 75.0
        )
        let manifest = DemultiplexManifest(
            version: 2,
            barcodeKit: BarcodeKit(name: "NBD114", vendor: "ont", barcodeCount: 24),
            parameters: DemultiplexParameters(tool: "cutadapt"),
            barcodes: [
                BarcodeResult(barcodeID: "BC01", readCount: 5000, baseCount: 50_000_000, bundleRelativePath: "BC01.lungfishfastq"),
            ],
            unassigned: UnassignedReadsSummary(readCount: 1000, baseCount: 10_000_000),
            outputDirectoryRelativePath: "../output-demux/",
            inputReadCount: 50_000,
            multiStepProvenance: provenance
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DemultiplexManifest.self, from: data)

        XCTAssertNotNil(decoded.multiStepProvenance)
        XCTAssertEqual(decoded.multiStepProvenance?.totalSteps, 2)
        XCTAssertEqual(decoded.multiStepProvenance?.stepSummaries.count, 2)
        XCTAssertEqual(decoded.multiStepProvenance?.stepSummaries[0].label, "Outer")
        XCTAssertEqual(decoded.multiStepProvenance?.stepSummaries[1].label, "Inner")
        XCTAssertEqual(decoded.multiStepProvenance?.compositeSampleNames["BC01/BC05"], "SampleX")
        XCTAssertEqual(decoded.multiStepProvenance!.totalWallClockSeconds, 75.0, accuracy: 0.01)
        XCTAssertEqual(decoded.barcodes.count, 1)
        XCTAssertEqual(decoded.inputReadCount, 50_000)
    }

    func testManifestBackwardCompatibility() throws {
        // JSON without multiStepProvenance should decode fine (nil)
        let json = """
        {
            "version": 1,
            "runID": "12345678-1234-1234-1234-123456789012",
            "demultiplexedAt": "2026-01-01T00:00:00Z",
            "barcodeKit": {
                "name": "NBD114",
                "vendor": "ont",
                "barcodeCount": 24,
                "isDualIndexed": false,
                "barcodeType": "symmetric"
            },
            "parameters": {
                "tool": "cutadapt",
                "maxMismatches": 1,
                "requireBothEnds": false,
                "trimBarcodes": true
            },
            "barcodes": [],
            "unassigned": {
                "readCount": 0,
                "baseCount": 0,
                "disposition": "keep"
            },
            "outputDirectoryRelativePath": "../out/",
            "inputReadCount": 1000
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DemultiplexManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.multiStepProvenance)
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.inputReadCount, 1000)
    }

    // MARK: - StepSummary

    func testStepSummaryCodable() throws {
        let summary = MultiStepProvenance.StepSummary(
            label: "Outer",
            barcodeKitID: "NBD114",
            symmetryMode: .asymmetric,
            errorRate: 0.20,
            inputBinCount: 3,
            outputBundleCount: 36,
            totalReadsProcessed: 75_000,
            wallClockSeconds: 45.0
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(MultiStepProvenance.StepSummary.self, from: data)
        XCTAssertEqual(decoded.label, "Outer")
        XCTAssertEqual(decoded.symmetryMode, .asymmetric)
        XCTAssertEqual(decoded.errorRate, 0.20, accuracy: 0.001)
        XCTAssertEqual(decoded.inputBinCount, 3)
        XCTAssertEqual(decoded.outputBundleCount, 36)
        XCTAssertEqual(decoded.totalReadsProcessed, 75_000)
    }

    func testStepSummaryEquatable() {
        let s1 = MultiStepProvenance.StepSummary(
            label: "A", barcodeKitID: "NBD114", symmetryMode: .symmetric,
            errorRate: 0.15, inputBinCount: 1, outputBundleCount: 12,
            totalReadsProcessed: 50_000, wallClockSeconds: 10.0
        )
        let s2 = MultiStepProvenance.StepSummary(
            label: "A", barcodeKitID: "NBD114", symmetryMode: .symmetric,
            errorRate: 0.15, inputBinCount: 1, outputBundleCount: 12,
            totalReadsProcessed: 50_000, wallClockSeconds: 10.0
        )
        XCTAssertEqual(s1, s2)
    }

    // MARK: - Duplicate Ordinal Validation

    func testDemultiplexPlanDuplicateOrdinalsThrows() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step A", barcodeKitID: "NBD114", ordinal: 0),
            DemultiplexStep(label: "Step B", barcodeKitID: "RBK114", ordinal: 0),
        ])
        XCTAssertThrowsError(try plan.validate()) { error in
            guard case DemultiplexPlanError.duplicateOrdinals = error else {
                XCTFail("Expected duplicateOrdinals error, got \(error)")
                return
            }
        }
    }

    func testDemultiplexPlanNonContiguousOrdinalsValidates() {
        // Non-contiguous ordinals (0, 5) are valid — just sorted by ordinal
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114", ordinal: 0),
            DemultiplexStep(label: "Step 5", barcodeKitID: "RBK114", ordinal: 5),
        ])
        XCTAssertNoThrow(try plan.validate())
    }

    func testDuplicateOrdinalsErrorDescription() {
        XCTAssertNotNil(DemultiplexPlanError.duplicateOrdinals.errorDescription)
        XCTAssertTrue(DemultiplexPlanError.duplicateOrdinals.errorDescription?.contains("duplicate") == true)
    }

    // MARK: - DemultiplexPlan Codable with Non-Default Step Fields

    func testDemultiplexPlanCodableWithNonDefaultStepFields() throws {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(
                label: "Outer",
                barcodeKitID: "NBD114",
                trimBarcodes: false,
                unassignedDisposition: .discard,
                ordinal: 0
            ),
            DemultiplexStep(
                label: "Inner",
                barcodeKitID: "RBK114",
                trimBarcodes: true,
                unassignedDisposition: .keep,
                ordinal: 1
            ),
        ])
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(DemultiplexPlan.self, from: data)
        XCTAssertFalse(decoded.steps[0].trimBarcodes)
        XCTAssertEqual(decoded.steps[0].unassignedDisposition, .discard)
        XCTAssertTrue(decoded.steps[1].trimBarcodes)
        XCTAssertEqual(decoded.steps[1].unassignedDisposition, .keep)
    }

    // MARK: - MultiStepDemultiplexResult Construction

    func testMultiStepDemultiplexResultConstruction() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        let stepResult = MultiStepDemultiplexResult.StepResult(
            step: step, perBinResults: [], wallClockSeconds: 10.0
        )
        let manifest = DemultiplexManifest(
            barcodeKit: BarcodeKit(name: "NBD114", vendor: "ont", barcodeCount: 24),
            parameters: DemultiplexParameters(tool: "cutadapt"),
            barcodes: [],
            unassigned: UnassignedReadsSummary(readCount: 0, baseCount: 0),
            outputDirectoryRelativePath: "../out/",
            inputReadCount: 1000
        )
        let result = MultiStepDemultiplexResult(
            stepResults: [stepResult],
            outputBundleURLs: [URL(fileURLWithPath: "/tmp/BC01.lungfishfastq")],
            manifest: manifest,
            wallClockSeconds: 10.0
        )
        XCTAssertEqual(result.stepResults.count, 1)
        XCTAssertEqual(result.outputBundleURLs.count, 1)
        XCTAssertEqual(result.wallClockSeconds, 10.0, accuracy: 0.01)
        XCTAssertEqual(result.manifest.inputReadCount, 1000)
    }
}

import XCTest
@testable import LungfishIO

final class OperationChainTests: XCTestCase {

    // MARK: - OperationContract.input

    func testInputForPairedEndMergeRequiresInterleaved() {
        let input = OperationContract.input(for: .pairedEndMerge)
        XCTAssertEqual(input.acceptedFormats, [.fastq])
        XCTAssertEqual(input.requiredPairing, [.interleaved])
    }

    func testInputForQualityTrimAcceptsAnyPairing() {
        let input = OperationContract.input(for: .qualityTrim)
        XCTAssertEqual(input.acceptedFormats, [.fastq])
        XCTAssertNil(input.requiredPairing)
    }

    func testInputForLengthFilterAcceptsBothFormats() {
        let input = OperationContract.input(for: .lengthFilter)
        XCTAssertTrue(input.acceptedFormats.contains(.fastq))
        XCTAssertTrue(input.acceptedFormats.contains(.fasta))
    }

    func testInputForOrientAcceptsBothFormats() {
        let input = OperationContract.input(for: .orient)
        XCTAssertTrue(input.acceptedFormats.contains(.fastq))
        XCTAssertTrue(input.acceptedFormats.contains(.fasta))
    }

    func testInputCoversAllOperationKinds() {
        for kind in FASTQDerivativeOperationKind.allCases {
            let input = OperationContract.input(for: kind)
            XCTAssertFalse(input.acceptedFormats.isEmpty, "No accepted formats for \(kind)")
        }
    }

    // MARK: - OperationContract.output

    func testOutputForPairedEndMergeProducesMixed() {
        let output = OperationContract.output(for: .pairedEndMerge, inputPairing: .interleaved)
        XCTAssertEqual(output.format, .fastq)
        XCTAssertEqual(output.pairing, .mixed)
    }

    func testOutputForPairedEndRepairProducesInterleaved() {
        let output = OperationContract.output(for: .pairedEndRepair, inputPairing: .splitPaired)
        XCTAssertEqual(output.pairing, .interleaved)
    }

    func testOutputForInterleaveReformatToggles() {
        let output1 = OperationContract.output(for: .interleaveReformat, inputPairing: .interleaved)
        XCTAssertEqual(output1.pairing, .splitPaired)

        let output2 = OperationContract.output(for: .interleaveReformat, inputPairing: .splitPaired)
        XCTAssertEqual(output2.pairing, .interleaved)
    }

    func testOutputForDemultiplexProducesSingle() {
        let output = OperationContract.output(for: .demultiplex, inputPairing: .interleaved)
        XCTAssertEqual(output.pairing, .single)
    }

    func testOutputForQualityTrimPreservesPairing() {
        let output = OperationContract.output(for: .qualityTrim, inputPairing: .interleaved)
        XCTAssertEqual(output.pairing, .interleaved)
    }

    func testOutputCoversAllOperationKinds() {
        for kind in FASTQDerivativeOperationKind.allCases {
            let output = OperationContract.output(for: kind, inputPairing: .single)
            XCTAssertEqual(output.format, .fastq, "Unexpected format for \(kind)")
        }
    }

    // MARK: - Ordering Validation

    func testOrderingErrorMergeBeforeAdapterTrim() {
        let steps = [
            FASTQDerivativeOperation(kind: .pairedEndMerge),
            FASTQDerivativeOperation(kind: .adapterTrim),
        ]
        let issues = OperationContract.checkOrdering(steps)
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.stepIndex == 0 })
    }

    func testOrderingErrorMergeBeforeQualityTrim() {
        let steps = [
            FASTQDerivativeOperation(kind: .pairedEndMerge),
            FASTQDerivativeOperation(kind: .qualityTrim),
        ]
        let issues = OperationContract.checkOrdering(steps)
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.stepIndex == 0 })
    }

    func testOrderingWarningQualityTrimBeforePrimerRemoval() {
        let steps = [
            FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            FASTQDerivativeOperation(kind: .primerRemoval),
        ]
        let issues = OperationContract.checkOrdering(steps)
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.stepIndex == 0 })
    }

    func testOrderingWarningAdapterTrimBeforePrimerRemoval() {
        let steps = [
            FASTQDerivativeOperation(kind: .adapterTrim),
            FASTQDerivativeOperation(kind: .primerRemoval),
        ]
        let issues = OperationContract.checkOrdering(steps)
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.stepIndex == 0 })
    }

    func testCorrectOrderingHasNoIssues() {
        let steps = [
            FASTQDerivativeOperation(kind: .primerRemoval),
            FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            FASTQDerivativeOperation(kind: .adapterTrim),
            FASTQDerivativeOperation(kind: .pairedEndMerge),
        ]
        let issues = OperationContract.checkOrdering(steps)
        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - Recipe Validation

    func testValidRecipePassesValidation() {
        let recipe = ProcessingRecipe(
            name: "Valid Pipeline",
            steps: [
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
                FASTQDerivativeOperation(kind: .adapterTrim),
                FASTQDerivativeOperation(kind: .lengthFilter, minLength: 100),
            ]
        )
        let result = recipe.validate(inputPairing: .single)
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.error)
    }

    func testRecipeRejectsMergeOnSingleEndInput() {
        let recipe = ProcessingRecipe(
            name: "Bad PE Recipe",
            steps: [
                FASTQDerivativeOperation(kind: .pairedEndMerge),
            ]
        )
        let result = recipe.validate(inputPairing: .single)
        XCTAssertFalse(result.isValid)
        if case .incompatiblePairing(let idx, _, _) = result.error {
            XCTAssertEqual(idx, 0)
        } else {
            XCTFail("Expected incompatiblePairing error")
        }
    }

    func testRecipeRejectsDemultiplexNotTerminal() {
        let recipe = ProcessingRecipe(
            name: "Bad Demux Recipe",
            steps: [
                FASTQDerivativeOperation(kind: .demultiplex),
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            ]
        )
        let result = recipe.validate()
        XCTAssertFalse(result.isValid)
        if case .demultiplexNotTerminal(let idx) = result.error {
            XCTAssertEqual(idx, 0)
        } else {
            XCTFail("Expected demultiplexNotTerminal error")
        }
    }

    func testRecipeRejectsMergeBeforeAdapterTrim() {
        let recipe = ProcessingRecipe(
            name: "Bad Order Recipe",
            steps: [
                FASTQDerivativeOperation(kind: .pairedEndMerge),
                FASTQDerivativeOperation(kind: .adapterTrim),
            ]
        )
        let result = recipe.validate(inputPairing: .interleaved)
        XCTAssertFalse(result.isValid)
        if case .orderingError = result.error {
            // Expected
        } else {
            XCTFail("Expected ordering error, got \(String(describing: result.error))")
        }
    }

    func testRecipeWarnsQualityTrimBeforePrimerRemoval() {
        let recipe = ProcessingRecipe(
            name: "Suboptimal Recipe",
            steps: [
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
                FASTQDerivativeOperation(kind: .primerRemoval),
            ]
        )
        let result = recipe.validate()
        XCTAssertTrue(result.isValid, "Should be valid (warning only)")
        XCTAssertFalse(result.warnings.isEmpty, "Should have warnings")
    }

    func testEmptyRecipePassesValidation() {
        let recipe = ProcessingRecipe(name: "Empty", steps: [])
        let result = recipe.validate()
        XCTAssertTrue(result.isValid)
    }

    func testIlluminaWGSRecipeIsValid() {
        let result = ProcessingRecipe.illuminaWGS.validate(inputPairing: .interleaved)
        XCTAssertTrue(result.isValid, "Built-in Illumina WGS recipe should be valid: \(String(describing: result.error))")
    }

    func testTargetedAmpliconRecipeIsValid() {
        let result = ProcessingRecipe.targetedAmplicon.validate(inputPairing: .interleaved)
        XCTAssertTrue(result.isValid, "Built-in targeted amplicon recipe should be valid: \(String(describing: result.error))")
    }

    func testONTAmpliconRecipeIsValid() {
        let result = ProcessingRecipe.ontAmplicon.validate()
        XCTAssertTrue(result.isValid, "Built-in ONT amplicon recipe should be valid: \(String(describing: result.error))")
    }
}

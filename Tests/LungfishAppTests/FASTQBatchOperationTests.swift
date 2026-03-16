import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class FASTQBatchOperationTests: XCTestCase {

    // MARK: - FASTQDerivativeRequest.batchLabel

    func testBatchLabelLengthFilter() {
        let request = FASTQDerivativeRequest.lengthFilter(min: 500, max: 5000)
        XCTAssertTrue(request.batchLabel.contains("500"))
        XCTAssertTrue(request.batchLabel.contains("5000"))
    }

    func testBatchLabelLengthFilterMinOnly() {
        let request = FASTQDerivativeRequest.lengthFilter(min: 100, max: nil)
        XCTAssertTrue(request.batchLabel.contains("100"))
    }

    func testBatchLabelLengthFilterBothNil() {
        let request = FASTQDerivativeRequest.lengthFilter(min: nil, max: nil)
        XCTAssertEqual(request.batchLabel, "Filter by Length")
    }

    func testBatchLabelSubsampleProportion() {
        let request = FASTQDerivativeRequest.subsampleProportion(0.1)
        XCTAssertEqual(request.batchLabel, "Subsample 10%")
    }

    func testBatchLabelSubsampleCount() {
        let request = FASTQDerivativeRequest.subsampleCount(5000)
        XCTAssertEqual(request.batchLabel, "Subsample 5000 reads")
    }

    func testBatchLabelDefaultsToOperationLabel() {
        let request = FASTQDerivativeRequest.deduplicate(mode: .sequence, pairedAware: false)
        XCTAssertEqual(request.batchLabel, "Deduplicate")
    }

    // MARK: - FASTQDerivativeRequest.operationKindString

    func testOperationKindStringExhaustive() {
        // Verify each case returns the expected machine-readable string
        XCTAssertEqual(FASTQDerivativeRequest.subsampleProportion(0.5).operationKindString, "subsampleProportion")
        XCTAssertEqual(FASTQDerivativeRequest.subsampleCount(100).operationKindString, "subsampleCount")
        XCTAssertEqual(FASTQDerivativeRequest.lengthFilter(min: 100, max: 200).operationKindString, "lengthFilter")
        XCTAssertEqual(FASTQDerivativeRequest.searchText(query: "test", field: .id, regex: false).operationKindString, "searchText")
        XCTAssertEqual(FASTQDerivativeRequest.searchMotif(pattern: "ATG", regex: false).operationKindString, "searchMotif")
        XCTAssertEqual(FASTQDerivativeRequest.deduplicate(mode: .sequence, pairedAware: false).operationKindString, "deduplicate")
        XCTAssertEqual(FASTQDerivativeRequest.qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight).operationKindString, "qualityTrim")
        XCTAssertEqual(FASTQDerivativeRequest.adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil).operationKindString, "adapterTrim")
        XCTAssertEqual(FASTQDerivativeRequest.fixedTrim(from5Prime: 10, from3Prime: 5).operationKindString, "fixedTrim")
        XCTAssertEqual(FASTQDerivativeRequest.pairedEndRepair.operationKindString, "pairedEndRepair")
        XCTAssertEqual(FASTQDerivativeRequest.errorCorrection(kmerSize: 50).operationKindString, "errorCorrection")
    }

    // MARK: - FASTQDerivativeRequest.batchParameters

    func testBatchParametersLengthFilter() {
        let request = FASTQDerivativeRequest.lengthFilter(min: 200, max: 1000)
        let params = request.batchParameters
        XCTAssertEqual(params["minLength"], "200")
        XCTAssertEqual(params["maxLength"], "1000")
    }

    func testBatchParametersLengthFilterMinOnly() {
        let request = FASTQDerivativeRequest.lengthFilter(min: 500, max: nil)
        let params = request.batchParameters
        XCTAssertEqual(params["minLength"], "500")
        XCTAssertNil(params["maxLength"])
    }

    func testBatchParametersSubsampleProportion() {
        let request = FASTQDerivativeRequest.subsampleProportion(0.25)
        XCTAssertEqual(request.batchParameters["proportion"], "0.25")
    }

    func testBatchParametersSubsampleCount() {
        let request = FASTQDerivativeRequest.subsampleCount(1000)
        XCTAssertEqual(request.batchParameters["count"], "1000")
    }

    func testBatchParametersQualityTrim() {
        let request = FASTQDerivativeRequest.qualityTrim(threshold: 25, windowSize: 5, mode: .cutBoth)
        let params = request.batchParameters
        XCTAssertEqual(params["threshold"], "25")
        XCTAssertEqual(params["windowSize"], "5")
    }

    func testBatchParametersFixedTrim() {
        let request = FASTQDerivativeRequest.fixedTrim(from5Prime: 10, from3Prime: 5)
        let params = request.batchParameters
        XCTAssertEqual(params["from5Prime"], "10")
        XCTAssertEqual(params["from3Prime"], "5")
    }

    func testBatchParametersPairedEndRepairEmpty() {
        let request = FASTQDerivativeRequest.pairedEndRepair
        XCTAssertTrue(request.batchParameters.isEmpty)
    }

    func testBatchParametersErrorCorrection() {
        let request = FASTQDerivativeRequest.errorCorrection(kmerSize: 31)
        XCTAssertEqual(request.batchParameters["kmerSize"], "31")
    }

    // MARK: - Request Type Classification

    func testIsTrimOperation() {
        XCTAssertTrue(FASTQDerivativeRequest.qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight).isTrimOperation)
        XCTAssertTrue(FASTQDerivativeRequest.fixedTrim(from5Prime: 10, from3Prime: 5).isTrimOperation)
        XCTAssertFalse(FASTQDerivativeRequest.lengthFilter(min: 100, max: nil).isTrimOperation)
        XCTAssertFalse(FASTQDerivativeRequest.subsampleCount(100).isTrimOperation)
    }

    func testIsFullOperation() {
        XCTAssertTrue(FASTQDerivativeRequest.pairedEndRepair.isFullOperation)
        XCTAssertTrue(FASTQDerivativeRequest.errorCorrection(kmerSize: 50).isFullOperation)
        XCTAssertFalse(FASTQDerivativeRequest.lengthFilter(min: 100, max: nil).isFullOperation)
        XCTAssertFalse(FASTQDerivativeRequest.qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight).isFullOperation)
    }
}

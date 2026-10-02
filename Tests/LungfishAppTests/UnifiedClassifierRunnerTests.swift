import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class UnifiedClassifierRunnerTests: XCTestCase {
    func testRunnerReadinessIgnoresInactiveRunnerCallbacks() {
        var gate = UnifiedRunnerReadinessGate(initialSelection: .classification)

        XCTAssertEqual(gate.accept(canRun: true, for: .classification), true)

        gate.select(.viralDetection)

        XCTAssertNil(gate.accept(canRun: true, for: .classification))
        XCTAssertEqual(gate.accept(canRun: false, for: .viralDetection), false)
        XCTAssertEqual(gate.accept(canRun: true, for: .viralDetection), true)
    }

    func testEsVirituReadinessRequiresResolvedDatabasePath() {
        XCTAssertFalse(EsVirituRunReadiness.canRun(
            groupedSampleCount: 1,
            isBatchMode: false,
            sampleName: "sample-1",
            isDatabaseInstalled: true,
            databasePath: nil
        ))

        XCTAssertTrue(EsVirituRunReadiness.canRun(
            groupedSampleCount: 1,
            isBatchMode: false,
            sampleName: "sample-1",
            isDatabaseInstalled: true,
            databasePath: URL(fileURLWithPath: "/tmp/esviritu-db")
        ))
    }

    func testEsVirituReadinessRejectsUnparseableExtraArguments() {
        // Regression test for AS30: performRun() silently no-ops when
        // extraArgumentsText fails to parse (e.g. an unterminated quote),
        // but canRun previously never checked parseability, leaving Run
        // enabled with zero feedback.
        XCTAssertTrue(EsVirituRunReadiness.canRun(
            groupedSampleCount: 1,
            isBatchMode: false,
            sampleName: "sample-1",
            isDatabaseInstalled: true,
            databasePath: URL(fileURLWithPath: "/tmp/esviritu-db"),
            extraArgumentsText: "--flag value"
        ))

        XCTAssertFalse(EsVirituRunReadiness.canRun(
            groupedSampleCount: 1,
            isBatchMode: false,
            sampleName: "sample-1",
            isDatabaseInstalled: true,
            databasePath: URL(fileURLWithPath: "/tmp/esviritu-db"),
            extraArgumentsText: "--flag 'unterminated"
        ))
    }

    func testClassifierToolsUseEmbeddedFASTQOperationsRoutingContract() {
        for toolID in [FASTQOperationToolID.kraken2, .esViritu, .taxTriage] {
            let state = FASTQOperationDialogState(
                initialCategory: .classification,
                selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq")]
            )

            state.selectTool(toolID)

            XCTAssertEqual(state.selectedCategory, .classification)
            XCTAssertEqual(state.selectedToolID, toolID)
            XCTAssertEqual(state.outputMode, .fixedBatch)
            XCTAssertFalse(state.isRunEnabled)
            XCTAssertEqual(state.readinessText, "Complete the classifier settings to continue.")

            let initialTrigger = state.embeddedRunTrigger
            state.prepareForRun()

            XCTAssertEqual(state.embeddedRunTrigger, initialTrigger + 1)
            XCTAssertNil(state.pendingLaunchRequest)
            XCTAssertTrue(state.pendingClassificationConfigs.isEmpty)
            XCTAssertTrue(state.pendingEsVirituConfigs.isEmpty)
            XCTAssertNil(state.pendingTaxTriageConfig)
        }
    }

    func testOrientToolSelectionBuildsOperationsDialogLaunchRequest() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.fastq")
        let referenceURL = URL(fileURLWithPath: "/tmp/reference.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.orientReads)
        state.setAuxiliaryInput(referenceURL, for: .referenceSequence)
        state.prepareForRun()

        XCTAssertEqual(state.selectedCategory, .readProcessing)
        XCTAssertEqual(state.selectedToolID, .orientReads)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .orient(
                    referenceURL: referenceURL,
                    wordLength: 12,
                    dbMask: "dust",
                    saveUnoriented: false
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testEmbeddedClassifierCapturesRouteToRunnerSpecificPendingState() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.fastq")
        let databaseURL = URL(fileURLWithPath: "/tmp/classifier-db")
        let outputURL = URL(fileURLWithPath: "/tmp/classifier-output")

        let krakenState = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [inputURL]
        )
        krakenState.captureClassificationConfigs([
            ClassificationConfig(
                inputFiles: [inputURL],
                isPairedEnd: false,
                databaseName: "standard",
                databasePath: databaseURL,
                outputDirectory: outputURL
            )
        ])
        XCTAssertEqual(krakenState.pendingClassificationConfigs.count, 1)
        XCTAssertTrue(krakenState.pendingEsVirituConfigs.isEmpty)
        XCTAssertNil(krakenState.pendingTaxTriageConfig)
        XCTAssertEqual(
            krakenState.pendingLaunchRequest,
            .classify(tool: .kraken2, inputURLs: [inputURL], databaseName: "standard")
        )

        let esVirituState = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [inputURL]
        )
        esVirituState.captureEsVirituConfigs([
            EsVirituConfig(
                inputFiles: [inputURL],
                isPairedEnd: false,
                sampleName: "sample",
                outputDirectory: outputURL,
                databasePath: databaseURL
            )
        ])
        XCTAssertTrue(esVirituState.pendingClassificationConfigs.isEmpty)
        XCTAssertEqual(esVirituState.pendingEsVirituConfigs.count, 1)
        XCTAssertNil(esVirituState.pendingTaxTriageConfig)
        XCTAssertEqual(
            esVirituState.pendingLaunchRequest,
            .classify(tool: .esViritu, inputURLs: [inputURL], databaseName: "classifier-db")
        )

        let taxTriageState = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [inputURL]
        )
        taxTriageState.captureTaxTriageConfig(
            TaxTriageConfig(
                samples: [TaxTriageSample(sampleId: "sample", fastq1: inputURL)],
                outputDirectory: outputURL,
                kraken2DatabasePath: databaseURL
            )
        )
        XCTAssertTrue(taxTriageState.pendingClassificationConfigs.isEmpty)
        XCTAssertTrue(taxTriageState.pendingEsVirituConfigs.isEmpty)
        XCTAssertNotNil(taxTriageState.pendingTaxTriageConfig)
        XCTAssertEqual(
            taxTriageState.pendingLaunchRequest,
            .classify(tool: .taxTriage, inputURLs: [inputURL], databaseName: "classifier-db")
        )
    }

    private func loadSource(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

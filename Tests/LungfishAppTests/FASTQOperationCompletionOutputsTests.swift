import Foundation
import XCTest
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishApp

/// A completed FASTQ operation must record what it produced so the
/// Operations panel can enable its Results button and offer Reveal Output
/// Files. The FASTQ launch paths used to call `complete(id:detail:)` with no
/// URLs, so a fastp trim that created a new bundle looked like it made nothing.
@MainActor
final class FASTQOperationCompletionOutputsTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-completion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func makeProjectBundle(named name: String) throws -> (project: URL, bundle: URL) {
        let project = temporaryDirectory.appendingPathComponent("Demo.lungfish", isDirectory: true)
        let bundle = project
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return (project, bundle)
    }

    private func startOperation(in center: OperationCenter, project: URL) -> UUID {
        center.begin(
            title: "FASTQ: fastp Adapter + Quality Trim",
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: nil,
            routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        ).rowID
    }

    func testCompletedDerivativeOperationCarriesItsOutputBundle() throws {
        let (project, bundle) = try makeProjectBundle(named: "HG002-fastpTrim-2")
        let center = OperationCenter()
        let id = startOperation(in: center, project: project)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 20, max: 500),
                inputURLs: [project.appendingPathComponent("HG002.\(FASTQBundle.directoryExtension)")],
                outputMode: .perInput
            ),
            executedInvocations: [],
            importedURLs: [bundle],
            groupedContainerURL: nil
        )

        XCTAssertTrue(FASTQOperationCompletion.complete(
            id: id, detail: "Done in 1.0s", result: result, center: center
        ))

        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.outputURLs, [bundle])
        XCTAssertEqual(OperationResultNavigation.resultURL(for: item), bundle.standardizedFileURL)
    }

    func testCompletedDerivativeServiceRunCarriesItsOutputBundles() throws {
        let (project, bundle) = try makeProjectBundle(named: "HG002-qualityTrim")
        let center = OperationCenter()
        let id = startOperation(in: center, project: project)

        XCTAssertTrue(FASTQOperationCompletion.complete(
            id: id, detail: "Done", outputURLs: [bundle, bundle], center: center
        ))

        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.outputURLs, [bundle])
        XCTAssertTrue(OperationResultNavigation.canNavigate(to: item))
    }

    func testCompletedGroupedOperationCarriesItsContainerOnce() throws {
        let (project, bundle) = try makeProjectBundle(named: "sample-1")
        let container = bundle.deletingLastPathComponent()
        let center = OperationCenter()
        let id = startOperation(in: center, project: project)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 20, max: 500),
                inputURLs: [],
                outputMode: .groupedResult
            ),
            executedInvocations: [],
            importedURLs: [container],
            groupedContainerURL: container
        )

        XCTAssertTrue(FASTQOperationCompletion.complete(
            id: id, detail: "Done", result: result, center: center
        ))
        XCTAssertEqual(center.items.first { $0.id == id }?.outputURLs, [container])
    }

    /// Every FASTQ-operation launch path in the main window must hand its
    /// products to OperationCenter. Each `.fastqOperation` row is therefore
    /// finished through `FASTQOperationCompletion`, never a bare
    /// `OperationCenter.shared.complete(id:detail:)`.
    func testFASTQOperationLaunchPathsCompleteThroughOutputRecordingHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift",
            "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift",
        ]
        // A launch registers its row with a `start` call that names
        // `.fastqOperation`, or with a begin helper that registers one. The
        // helpers live in MainSplitViewController+GenomicsDisplayOperationBegin.swift
        // and MainSplitViewController+FASTQImportOperationBegin.swift, so the
        // launch-site file names the helper call instead.
        let launchMarkers = [
            "operationType: .fastqOperation",
            "Self.beginFASTQDerivativeOperation(",
            "Self.beginFASTQLaunchRequestOperation(",
            "Self.beginONTImportRecipeOperation(",
        ]
        var launchCount = 0
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for marker in launchMarkers {
                var cursor = source.startIndex
                while let launch = source.range(of: marker, range: cursor..<source.endIndex) {
                    launchCount += 1
                    let rest = launch.upperBound..<source.endIndex
                    let bare = source.range(of: "OperationCenter.shared.complete(", range: rest)
                    let helper = source.range(of: "FASTQOperationCompletion.complete(", range: rest)
                    let line = source[..<launch.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    XCTAssertNotNil(helper, "\(file):\(line) never completes its FASTQ operation")
                    if let bare, let helper {
                        XCTAssertLessThan(
                            helper.lowerBound, bare.lowerBound,
                            "\(file):\(line) completes a FASTQ operation without recording its outputs"
                        )
                    }
                    cursor = launch.upperBound
                }
            }
        }
        XCTAssertGreaterThanOrEqual(launchCount, 4)
    }
}

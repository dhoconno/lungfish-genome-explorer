import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class ResultExportCoordinatorTests: XCTestCase {
    private final class SpyExportFailurePresenter: ExportFailurePresenting {
        private(set) var presentations: [(title: String, message: String)] = []

        func presentExportFailure(title: String, message: String, in window: NSWindow?) {
            presentations.append((title: title, message: message))
        }
    }

    private struct UnwritableDestinationError: LocalizedError {
        var errorDescription: String? { "The destination is not writable." }
    }

    func testWriterFailureInvokesInjectedPresenter() {
        let spy = SpyExportFailurePresenter()

        func write() throws {
            throw UnwritableDestinationError()
        }

        do {
            try write()
        } catch {
            ResultExportCoordinator.reportFailure(
                fileName: "results.tsv",
                error: error,
                window: nil,
                presenter: spy
            )
        }

        XCTAssertEqual(spy.presentations.count, 1)
        XCTAssertEqual(spy.presentations.first?.title, ResultExportCoordinator.defaultFailureTitle)
        XCTAssertTrue(spy.presentations.first?.message.contains("results.tsv") ?? false)
        XCTAssertTrue(spy.presentations.first?.message.contains("not writable") ?? false)
    }

    func testWriterSuccessNeverInvokesPresenter() {
        let spy = SpyExportFailurePresenter()

        func write() throws {
            // succeeds
        }

        do {
            try write()
        } catch {
            ResultExportCoordinator.reportFailure(
                fileName: "results.tsv",
                error: error,
                window: nil,
                presenter: spy
            )
        }

        XCTAssertTrue(spy.presentations.isEmpty)
    }
}

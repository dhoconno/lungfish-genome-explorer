// AssemblyResultSurfaceTests.swift - The assembly result viewer as a ViewportHost surface (Phase 3.2 lane ASM)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishKit
@testable import LungfishAssemblyUI
@testable import LungfishWorkflow

@MainActor
final class AssemblyResultSurfaceTests: XCTestCase {
    /// Each tool's factory makes a surface of that tool's kind, and the host installs the adopted controller before `show` returns.
    func testEachToolsFactoryInstallsTheControllerBeforeShowReturns() throws {
        for tool in AssemblyTool.allCases {
            let kind = SurfaceKind.analysis(AnalysisToolID(rawValue: tool.rawValue))
            let (host, parent) = makeHost(kind, tool)
            let controller = AssemblyResultViewController()

            host.show(kind: kind, input: AssemblyResultSurface.Input(controller: controller, result: try makeAssemblyResult()))

            let surface = try XCTUnwrap(host.activeViewport as? AssemblyResultSurface, "\(tool.rawValue) did not install")
            XCTAssertEqual(surface.surfaceKind, kind)
            XCTAssertTrue(surface.controller === controller)
            XCTAssertTrue(surface.viewController === controller)
            XCTAssertTrue(surface.pinsTopToSafeArea, "the controller's first row sits at the top of its own view")
            XCTAssertTrue(controller.parent === parent)
            XCTAssertTrue(controller.view.superview === parent.view)
            host.clear()
        }
    }

    /// An input of another type is refused with words, and nothing is installed.
    func testAnInputOfAnotherTypeIsRefused() {
        let kind = AssemblyResultSurface.kind(of: .flye)
        let (host, parent) = makeHost(kind, .flye)

        host.show(kind: kind, input: "not a controller")

        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty)
        guard case .failed(let error) = host.lastOutcome else {
            return XCTFail("the show of a wrong input must fail, got \(String(describing: host.lastOutcome))")
        }
        XCTAssertEqual(error as? SurfaceError, .unexpectedInput(kind: kind, expected: "Input"))
    }

    func testAContigsFileThatIsGoneRefusesTheLoadAndConfiguresNothing() throws {
        let result = try makeAssemblyResult()
        try FileManager.default.removeItem(at: result.contigsPath)
        assertRefused(result, words: "contigs.fasta is no longer in this assembly's folder.")
    }

    func testAContigsFileThatIsLockedRefusesTheLoadAndConfiguresNothing() throws {
        let result = try makeAssemblyResult()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: result.contigsPath.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: result.contigsPath.path) }
        assertRefused(result, words: "This Mac does not allow contigs.fasta to be read.")
    }

    /// A run that made no contigs has no file to read.
    func testAResultWithNoContigsIsNotChecked() throws {
        let result = try makeEmptyAssemblyResult()
        try FileManager.default.removeItem(at: result.contigsPath)
        let kind = AssemblyResultSurface.kind(of: .spades)
        let (host, parent) = makeHost(kind, .spades)
        defer { withExtendedLifetime(parent) {} }

        host.show(kind: kind, input: AssemblyResultSurface.Input(controller: AssemblyResultViewController(), result: result))

        XCTAssertNotNil(host.activeViewport, "a result with no contigs did not open")
    }

    /// Every removal stops a load still reading, its own kind included, and a BLAST run's state is not touched.
    func testEveryRemovalStopsTheLoadAndLeavesARunningSearch() throws {
        let kind = AssemblyResultSurface.kind(of: .megahit)
        let (host, parent) = makeHost(kind, .megahit)
        defer { withExtendedLifetime(parent) {} }
        let first = AssemblyResultViewController()
        host.show(kind: kind, input: AssemblyResultSurface.Input(controller: first, result: try makeAssemblyResult()))
        let run = UUID()
        first.savedBlastRestorer.trackRun(operationID: run)

        host.show(kind: kind, input: AssemblyResultSurface.Input(controller: AssemblyResultViewController(), result: try makeAssemblyResult()))

        XCTAssertEqual(first.loadTask?.isCancelled, true, "a second assembly left the first one's load reading")
        XCTAssertTrue(first.savedBlastRestorer.runLands(operationID: run), "a removal took the search's run off its list")

        let second = try XCTUnwrap((host.activeViewport as? AssemblyResultSurface)?.controller)
        host.clear()
        XCTAssertEqual(second.loadTask?.isCancelled, true, "a clear left the load reading")
    }

    private func assertRefused(_ result: AssemblyResult, words: String, file: StaticString = #filePath, line: UInt = #line) {
        let kind = AssemblyResultSurface.kind(of: .spades)
        let (host, parent) = makeHost(kind, .spades)
        let controller = AssemblyResultViewController()

        host.show(kind: kind, input: AssemblyResultSurface.Input(controller: controller, result: result))

        XCTAssertNil(host.activeViewport, "a contigs file that does not read opened", file: file, line: line)
        XCTAssertTrue(parent.children.isEmpty, file: file, line: line)
        XCTAssertNil(controller.loadTask, "a refused load started the controller's read", file: file, line: line)
        guard case .failed(let error) = host.lastOutcome else {
            return XCTFail("the show must fail, got \(String(describing: host.lastOutcome))", file: file, line: line)
        }
        XCTAssertEqual((error as? LocalizedError)?.errorDescription, words, file: file, line: line)
        XCTAssertNotNil((error as? LocalizedError)?.recoverySuggestion, "the error gives no next step", file: file, line: line)
    }

    private func makeHost(_ kind: SurfaceKind, _ tool: AssemblyTool) -> (ViewportHost, NSViewController) {
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let registry = SurfaceRegistry()
        registry.register(kind, factory: AssemblyResultSurface.factory(for: tool))
        let host = ViewportHost(registry: registry, containerView: parent.view, parentController: parent)
        return (host, parent)
    }
}

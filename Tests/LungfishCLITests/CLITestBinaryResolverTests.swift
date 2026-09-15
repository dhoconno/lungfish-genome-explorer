import Foundation
import LungfishTestSupport
import XCTest

final class CLITestBinaryResolverTests: XCTestCase {
    func testInjectedCLIPathWinsOverBuildProductsSibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let injected = try executable(named: "injected-cli", in: root)
        _ = try executable(named: "lungfish-cli", in: root)

        let resolved = CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: root,
            environment: ["LUNGFISH_CLI": injected.path]
        )

        XCTAssertEqual(resolved, injected)
    }

    func testBuildProductsSiblingIsUsedWithoutAnInjectedPath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = try executable(named: "lungfish-cli", in: root)

        let resolved = CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: root,
            environment: [:]
        )

        XCTAssertEqual(resolved, sibling)
    }

    func testInvalidInjectedPathDoesNotFallBackToPossiblyStaleSibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executable(named: "lungfish-cli", in: root)

        let resolved = CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: root,
            environment: ["LUNGFISH_CLI": root.appendingPathComponent("missing-cli").path]
        )

        XCTAssertNil(resolved)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-test-binary-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func executable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

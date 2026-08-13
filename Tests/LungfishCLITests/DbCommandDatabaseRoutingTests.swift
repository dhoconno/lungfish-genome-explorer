import Foundation
import XCTest

final class DbCommandDatabaseRoutingTests: XCTestCase {
    func testDownloadSubcommandDelegatesOnceToTheRegistryWithoutRecipeDispatch() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishCLI/Commands/DbCommand.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "struct DbDownloadSubcommand"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - db remove", range: start.upperBound..<source.endIndex))
        let downloadSection = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(
            downloadSection.components(separatedBy: "registry.downloadDatabase(name: name)").count - 1,
            1
        )
        XCTAssertFalse(downloadSection.contains("kraken2-build"))
        XCTAssertFalse(downloadSection.contains("bracken-build"))
        XCTAssertFalse(downloadSection.contains("URLSession"))
        XCTAssertFalse(downloadSection.contains("installationRecipe"))
    }
}

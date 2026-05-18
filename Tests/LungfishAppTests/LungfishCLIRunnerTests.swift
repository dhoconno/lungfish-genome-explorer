import XCTest
@testable import LungfishApp

final class LungfishCLIRunnerTests: XCTestCase {
    func testLaunchFailureClosesCapturePipesBeforeThrowing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/LungfishApp/App/LungfishCLIRunner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let catchStart = try XCTUnwrap(source.range(of: "} catch {"))
        let throwRange = try XCTUnwrap(
            source.range(of: "throw RunError.launchFailed", range: catchStart.upperBound..<source.endIndex)
        )
        let catchBody = source[catchStart.upperBound..<throwRange.lowerBound]

        XCTAssertTrue(catchBody.contains("stdoutPipe.fileHandleForWriting.closeFile()"))
        XCTAssertTrue(catchBody.contains("stderrPipe.fileHandleForWriting.closeFile()"))
        XCTAssertTrue(catchBody.contains("outputGroup.wait()"))
    }

    func testRunThrowsLaunchFailedForUnlaunchableExecutable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-cli-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            _ = try LungfishCLIRunner.run(arguments: [], executableURL: tempDir)
            XCTFail("Expected unlaunchable executable to throw")
        } catch LungfishCLIRunner.RunError.launchFailed {
            // Expected.
        } catch {
            XCTFail("Expected launchFailed, got \(error)")
        }
    }
}

import XCTest

final class AssemblyConfigurationViewModelSourceTests: XCTestCase {
    func testAssemblyCompletionCopyHandlesNoContigsOutcome() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private static func completionDetail(for result: AssemblyResult) -> String"))
        XCTAssertTrue(source.contains(#""Assembly completed, but no contigs were generated.""#))
        XCTAssertTrue(source.contains(#""No Contigs Generated""#))
        XCTAssertTrue(source.contains(#"finished for \(projectName), but no contigs were generated."#))
        XCTAssertTrue(source.contains("detail: completionDetail(for: result)"))
        XCTAssertTrue(source.contains("detail: completionDetail(for: normalizedResult)"))
        XCTAssertTrue(source.contains("title: completionNotificationTitle(for: result)"))
        XCTAssertTrue(source.contains("title: completionNotificationTitle(for: normalizedResult)"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "completionNotificationBody(").count - 1, 3)
        XCTAssertTrue(source.contains("OperationCenter.shared.log(id: opID, level: .warning, message: completionDetail(for: result))"))
        XCTAssertTrue(source.contains("OperationCenter.shared.log(id: opID, level: .warning, message: completionDetail(for: normalizedResult))"))
        XCTAssertTrue(source.contains("result.outcome == .completedWithNoContigs"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

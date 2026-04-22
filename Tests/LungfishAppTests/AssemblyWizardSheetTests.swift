import XCTest

final class AssemblyWizardSheetTests: XCTestCase {
    func testUnknownReadTypeDefaultsAreTreatedAsCurrentManualSelection() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("_hasConfirmedManualReadType = State(initialValue: true)"))
        XCTAssertTrue(source.contains("if requiresManualReadTypeConfirmation"))
        XCTAssertTrue(
            source.contains(
                "&& !AssemblyCompatibility.isSupported(tool: newValue, for: selectedReadType) {"
            )
        )
        XCTAssertTrue(
            source.contains("No single read class detected. Review the selected read type below.")
        )
    }

    func testHifiasmProfilesDefaultToDiploidAndExposeHaploidViral() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"return "diploid""#))
        XCTAssertTrue(source.contains(#".init(id: "diploid", title: "Diploid""#))
        XCTAssertTrue(source.contains(#".init(id: "haploid-viral", title: "Haploid/Viral""#))
        XCTAssertFalse(source.contains(#"if selectedProfileID == "haploid-viral" {"#))
        XCTAssertFalse(source.contains(#""--n-hap""#))
        XCTAssertFalse(source.contains(#""-l0""#))
        XCTAssertFalse(source.contains(#""-f0""#))
        XCTAssertTrue(source.contains(#"if hifiasmPrimaryOnly {"#))
        XCTAssertTrue(source.contains(#"arguments.append("--primary")"#))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

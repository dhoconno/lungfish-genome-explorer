import XCTest
@testable import LungfishIO

final class ReferenceCandidateDisplayTests: XCTestCase {
    func testPickerDisplayNameUsesProjectRelativePathWhenAvailable() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let fastaURL = projectURL
            .appendingPathComponent("References/Human/ref.fasta")
        let candidate = ReferenceCandidate.standaloneFASTA(url: fastaURL)

        XCTAssertEqual(
            candidate.pickerDisplayName(relativeTo: projectURL),
            "References/Human/ref.fasta"
        )
    }

    func testPickerDisplayNameKeepsExternalAbsolutePath() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let fastaURL = URL(fileURLWithPath: "/Users/example/Downloads/ref.fasta")
        let candidate = ReferenceCandidate.standaloneFASTA(url: fastaURL)

        XCTAssertEqual(
            candidate.pickerDisplayName(relativeTo: projectURL),
            "/Users/example/Downloads/ref.fasta"
        )
    }
}

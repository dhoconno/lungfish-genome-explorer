import XCTest
@testable import LungfishIO

final class ReferenceCandidateDisplayTests: XCTestCase {
    func testPickerDisplayNamesUsesBundleNameWhenUnique() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let bundleURL = projectURL
            .appendingPathComponent("Reference Sequences/Dar_es_Salaam.lungfishref", isDirectory: true)
        let candidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: bundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: bundleURL,
            displayName: "Dar_es_Salaam"
        )

        let labels = ReferenceCandidate.pickerDisplayNames(
            for: [candidate],
            relativeTo: projectURL
        )

        XCTAssertEqual(labels[candidate.id], "Dar_es_Salaam")
    }

    func testPickerDisplayNamesAddsParentFoldersOnlyForDuplicateBundleNames() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let downloadsBundleURL = projectURL
            .appendingPathComponent("Downloads/NC_078297.lungfishref", isDirectory: true)
        let analysisBundleURL = projectURL
            .appendingPathComponent("Analyses/minimap2-2026-08-09/NC_078297.lungfishref", isDirectory: true)
        let downloadsCandidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: downloadsBundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: downloadsBundleURL,
            displayName: "NC_078297"
        )
        let analysisCandidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: analysisBundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: analysisBundleURL,
            displayName: "NC_078297"
        )

        let labels = ReferenceCandidate.pickerDisplayNames(
            for: [downloadsCandidate, analysisCandidate],
            relativeTo: projectURL
        )

        XCTAssertEqual(labels[downloadsCandidate.id], "NC_078297 (Downloads)")
        XCTAssertEqual(
            labels[analysisCandidate.id],
            "NC_078297 (Analyses/minimap2-2026-08-09)"
        )
    }

    func testPickerDisplayNamesUsesStandaloneFilenameWhenUnique() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let candidate = ReferenceCandidate.standaloneFASTA(
            url: projectURL.appendingPathComponent("References/Human/ref.fasta")
        )

        let labels = ReferenceCandidate.pickerDisplayNames(
            for: [candidate],
            relativeTo: projectURL
        )

        XCTAssertEqual(labels[candidate.id], "ref")
    }

    func testPickerDisplayNamesFallsBackToSourcePathsWhenDuplicateFoldersMatch() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let bundleURL = projectURL
            .appendingPathComponent("Data/ref.lungfishref", isDirectory: true)
        let bundleCandidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: bundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: bundleURL,
            displayName: "ref"
        )
        let fastaCandidate = ReferenceCandidate.standaloneFASTA(
            url: projectURL.appendingPathComponent("Data/ref.fasta")
        )

        let labels = ReferenceCandidate.pickerDisplayNames(
            for: [bundleCandidate, fastaCandidate],
            relativeTo: projectURL
        )

        XCTAssertEqual(labels[bundleCandidate.id], "ref (Data/ref.lungfishref)")
        XCTAssertEqual(labels[fastaCandidate.id], "ref (Data/ref.fasta)")
    }

    func testPickerDisplayNamesDoesNotTreatAUniqueNameAsARenderedLabelCollision() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let uniqueBundleURL = projectURL
            .appendingPathComponent("Reference Sequences/unique.lungfishref", isDirectory: true)
        let uniqueCandidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: uniqueBundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: uniqueBundleURL,
            displayName: "ref (Data)"
        )
        let dataBundleURL = projectURL
            .appendingPathComponent("Data/ref.lungfishref", isDirectory: true)
        let otherBundleURL = projectURL
            .appendingPathComponent("Other/ref.lungfishref", isDirectory: true)
        let dataCandidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: dataBundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: dataBundleURL,
            displayName: "ref"
        )
        let otherCandidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: otherBundleURL.appendingPathComponent("genome/sequence.fa.gz"),
            bundleURL: otherBundleURL,
            displayName: "ref"
        )

        let labels = ReferenceCandidate.pickerDisplayNames(
            for: [uniqueCandidate, dataCandidate, otherCandidate],
            relativeTo: projectURL
        )

        XCTAssertEqual(labels[uniqueCandidate.id], "ref (Data)")
        XCTAssertEqual(labels[dataCandidate.id], "ref (Data/ref.lungfishref)")
        XCTAssertEqual(labels[otherCandidate.id], "ref (Other)")
    }
}

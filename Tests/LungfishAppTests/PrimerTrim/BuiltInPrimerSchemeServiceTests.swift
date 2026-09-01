import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class BuiltInPrimerSchemeServiceTests: XCTestCase {
    func testListBuiltInSchemesReturnsBundledSchemes() throws {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes()
        XCTAssertFalse(schemes.isEmpty, "expected at least one built-in primer scheme")
        XCTAssertTrue(schemes.contains { $0.manifest.name == "QIASeqDIRECT-SARS2" })
    }

    /// Every scheme we ship must appear in the picker, so a bundle that fails to
    /// load (bad manifest, missing PROVENANCE.md) cannot ship unnoticed.
    func testAllExpectedViralReconSchemesAreBundled() throws {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes()
        let names = Set(schemes.map(\.manifest.name))
        let expected: Set<String> = [
            "QIASeqDIRECT-SARS2",
            "ARTIC-nCoV-2019-V3",
            "ARTIC-SARS-CoV-2-V4",
            "ARTIC-SARS-CoV-2-V4.1",
            "ARTIC-SARS-CoV-2-V5.3.2",
            "Midnight-1200-V1",
            "NEB-VarSkip-vss1",
            "NEB-VarSkip-Long-vsl1"
        ]
        XCTAssertTrue(expected.isSubset(of: names), "missing: \(expected.subtracting(names))")
    }

    /// Guards the manifest counts against the BED each bundle actually ships.
    func testBundledSchemeCountsMatchTheirBEDs() throws {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes()
        try XCTSkipIf(schemes.isEmpty, "no built-in schemes located in this environment")

        for scheme in schemes {
            let bed = try String(contentsOf: scheme.bedURL, encoding: .utf8)
            let rows = bed
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            XCTAssertEqual(
                rows.count,
                scheme.manifest.primerCount,
                "\(scheme.manifest.name): manifest primer_count disagrees with primers.bed"
            )
            XCTAssertGreaterThan(scheme.manifest.ampliconCount, 0, scheme.manifest.name)

            // Every row must be BED6 with a usable strand, since primer
            // derivation reads column 6 to reverse-complement RIGHT primers.
            for row in rows {
                let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
                XCTAssertGreaterThanOrEqual(columns.count, 6, "\(scheme.manifest.name): \(row)")
                XCTAssertTrue(
                    columns[5] == "+" || columns[5] == "-",
                    "\(scheme.manifest.name): bad strand in \(row)"
                )
                XCTAssertEqual(
                    String(columns[0]),
                    scheme.manifest.canonicalAccession,
                    "\(scheme.manifest.name): BED contig must match the canonical accession"
                )
            }
        }
    }

    /// Stages each bundled scheme against a real reference the way the Viral
    /// Recon wizard does, proving primer derivation succeeds for all of them.
    func testEveryBundledSchemeStagesPrimersAgainstCanonicalReference() throws {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes()
        try XCTSkipIf(schemes.isEmpty, "no built-in schemes located in this environment")

        for scheme in schemes {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("scheme-stage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            // A synthetic reference long enough to span the scheme's coordinates.
            let bed = try String(contentsOf: scheme.bedURL, encoding: .utf8)
            let maxEnd = bed.split(separator: "\n").compactMap { row -> Int? in
                let columns = row.split(separator: "\t")
                guard columns.count >= 3 else { return nil }
                return Int(columns[2])
            }.max() ?? 0
            let accession = scheme.manifest.canonicalAccession
            let referenceURL = directory.appendingPathComponent("reference.fasta")
            let body = String(repeating: "ACGT", count: maxEnd / 4 + 2)
            try ">\(accession)\n\(body)\n".write(to: referenceURL, atomically: true, encoding: .utf8)

            let staged = try ViralReconPrimerStager.stage(
                primerBundleURL: scheme.url,
                referenceFASTAURL: referenceURL,
                referenceName: accession,
                destinationDirectory: directory
            )

            let fasta = try String(contentsOf: staged.fastaURL, encoding: .utf8)
            let records = fasta.split(separator: "\n").filter { $0.hasPrefix(">") }.count
            XCTAssertEqual(records, scheme.manifest.primerCount, scheme.manifest.name)
            XCTAssertFalse(staged.leftSuffix.isEmpty, scheme.manifest.name)
            XCTAssertFalse(staged.rightSuffix.isEmpty, scheme.manifest.name)
        }
    }

    func testInjectedBundleOverrideRemainsAuthoritative() {
        let schemes = BuiltInPrimerSchemeService.listBuiltInSchemes(in: Bundle.module)
        XCTAssertTrue(schemes.isEmpty)
    }
}

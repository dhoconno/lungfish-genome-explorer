import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// The line the Inspector gives an output a Viral Recon run did not write (VR-INVENTORY).
///
/// Each decided string is asserted whole, so a changed word fails here and goes back to the panel that wrote it
/// (ux-text `codex/VR-INVENTORY-decided.md`, W1 to W8). The file reads no source. The sidecar the builder reads is
/// the one ingest writes, `viralrecon-result.json` with its `absentOutputs`.
@MainActor
final class ViralReconAbsentOutputNotesTests: XCTestCase {
    private static let decided: [(output: ViralReconAbsentOutput, section: String, line: String)] = [
        (.sampleFailed, "Variants",
         "Too few reads were left to call variants."),
        (.noVariantsNoConsensus, "Variants",
         "No variants found, so the run made no consensus sequence or lineage tables."),
        (.noVariants, "Variants",
         "No variants found."),
        (.variantsNotWritten, "Variants",
         "Variant file missing from its expected location."),
        (.consensusNotWritten, "Consensus",
         "Consensus sequence file missing from its expected location."),
        (.pangolinNotWritten, "Lineage",
         "Pangolin lineage table missing from its expected location."),
        (.nextcladeNotWritten, "Lineage",
         "Nextclade clade table missing from its expected location."),
        (.freyjaNotWritten, "Lineage",
         "Freyja variant mix table missing from its expected location."),
    ]

    private func makeRoot(_ prefix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// An analysis bundle as ingest leaves it, with `absentOutputs` written the way ingest writes it and left out
    /// when nil.
    private func makeBundle(
        absentOutputs: [String]? = nil,
        consensus: [String] = [],
        lineage: [String] = []
    ) throws -> URL {
        let root = makeRoot("viralrecon-absent-notes")
        for (role, names) in [("consensus", consensus), ("lineage", lineage), ("reports", [String]())] {
            let directory = root.appendingPathComponent(role, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names {
                try Data("x".utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        var sidecar: [String: Any] = ["schemaVersion": 1, "tool": "viralrecon", "sampleName": "S1"]
        if let absentOutputs { sidecar["absentOutputs"] = absentOutputs }
        try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("viralrecon-result.json"))
        return root
    }

    // MARK: - The decided lines

    func testEveryAbsentOutputGivesItsDecidedLineInItsSection() throws {
        XCTAssertEqual(Set(Self.decided.map { $0.output }), Set(ViralReconAbsentOutput.allCases),
                       "an absent output has no decided line")

        for entry in Self.decided {
            let bundle = try makeBundle(absentOutputs: [entry.output.rawValue])

            let state = try XCTUnwrap(
                ViralReconDocumentStateBuilder.state(forBundleAt: bundle, sampleName: "S1"),
                "\(entry.output.rawValue) gave no Inspector state")

            XCTAssertEqual(state.sections.map(\.title), [entry.section], entry.output.rawValue)
            XCTAssertEqual(state.sections.first?.notes, [entry.line], entry.output.rawValue)
            XCTAssertEqual(state.sections.first?.rows.isEmpty, true, entry.output.rawValue)
        }
    }

    func testAFullBundleGivesNoLine() throws {
        for absentOutputs in [nil, [String]()] {
            let bundle = try makeBundle(
                absentOutputs: absentOutputs,
                consensus: ["S1.consensus.fa"],
                lineage: ["S1.pangolin.csv", "S1.nextclade.csv"])

            let state = try XCTUnwrap(
                ViralReconDocumentStateBuilder.state(forBundleAt: bundle, sampleName: "S1"))

            XCTAssertEqual(state.sections.map(\.title), ["Consensus", "Lineage"])
            XCTAssertEqual(state.sections.flatMap(\.notes), [])
        }
    }

    // A line follows the rows of the section whose output it names, and is not counted as an output.
    func testALineStandsBesideTheRowsOfItsSection() throws {
        let bundle = try makeBundle(
            absentOutputs: ["nextcladeNotWritten", "freyjaNotWritten"],
            consensus: ["S1.consensus.fa"],
            lineage: ["S1.pangolin.csv"])

        let state = try XCTUnwrap(
            ViralReconDocumentStateBuilder.state(forBundleAt: bundle, sampleName: "S1"))

        XCTAssertEqual(state.sections.map(\.title), ["Consensus", "Lineage"])
        XCTAssertEqual(state.sections[0].notes, [])
        XCTAssertEqual(state.sections[1].rows.map(\.label), ["Pangolin Lineage"])
        XCTAssertEqual(state.sections[1].notes, [
            "Nextclade clade table missing from its expected location.",
            "Freyja variant mix table missing from its expected location.",
        ])
        XCTAssertEqual(state.subtitle, "Viral Recon • 2 outputs")
    }

    // A value a later version writes, or one written twice, adds no line of its own.
    func testAnUnknownOrRepeatedValueAddsNoLine() throws {
        let bundle = try makeBundle(
            absentOutputs: ["noVariants", "noVariants", "aValueFromALaterVersion"],
            consensus: ["S1.consensus.fa"])

        let state = try XCTUnwrap(
            ViralReconDocumentStateBuilder.state(forBundleAt: bundle, sampleName: "S1"))

        XCTAssertEqual(state.sections.flatMap(\.notes), ["No variants found."])
    }

    // MARK: - From ingest to the Inspector

    func testTheSidecarIngestWritesGivesTheInspectorItsLines() throws {
        let root = makeRoot("viralrecon-absent-ingest")
        let results = root.appendingPathComponent("results", isDirectory: true)
        // The caller reached the sample and its VCF was taken, and none of the tables the default run makes after it.
        for relative in ["variants/ivar/S1.tsv", "variants/ivar/S1.vcf.gz"] {
            let url = results.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let reference = root.appendingPathComponent("ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        let params = ["platform": "illumina", "protocol": "amplicon", "skip_freyja": "true"]

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results, sampleName: "S1", referenceBundleURL: reference,
            into: root.appendingPathComponent("Analyses/viralrecon-S1", isDirectory: true), params: params)
        let state = try XCTUnwrap(
            ViralReconDocumentStateBuilder.state(forBundleAt: ingested.bundleDirectory, sampleName: "S1"))

        XCTAssertEqual(state.sections.map(\.title), ["Consensus", "Lineage"])
        XCTAssertEqual(state.sections[0].notes, ["Consensus sequence file missing from its expected location."])
        XCTAssertEqual(state.sections[1].notes, [
            "Pangolin lineage table missing from its expected location.",
            "Nextclade clade table missing from its expected location.",
        ])
    }

    // MARK: - Placement

    // Each line takes room under the section's title, so it is laid out in the view and not dropped.
    func testAHostedSectionIsTallerForEachLine() {
        func hostedHeight(notes: [String]) -> CGFloat {
            let state = ViralReconDocumentState(
                title: "S1", subtitle: nil,
                sections: [ViralReconDocumentFileSection(title: "Lineage", rows: [], notes: notes)])
            let host = NSHostingView(rootView: ViralReconDocumentSection(state: state))
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let none = hostedHeight(notes: [])
        let one = hostedHeight(notes: ["Pangolin lineage table missing from its expected location."])
        let two = hostedHeight(notes: [
            "Pangolin lineage table missing from its expected location.",
            "Nextclade clade table missing from its expected location.",
        ])

        XCTAssertGreaterThan(one, none)
        XCTAssertGreaterThan(two, one)
    }
}

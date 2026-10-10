// AppProvenanceExportSourceResolverTests.swift - Which file or bundle File > Export > Provenance exports from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// The choice behind File > Export > Provenance.
///
/// In the 2026-10-10 GUI walk a GFF3 was viewed and README.md was then selected. The viewer
/// shows a README through a Quick Look style preview that never resets `currentDocument`, so
/// the export took the GFF3 as its source and offered `MN908947.3-provenance-json` while the
/// Provenance tab read Missing for README.md. The sidebar selection now decides, unless a
/// viewer candidate is the selection or a bundle that contains it.
///
/// The tests pass the lookup in, so no test reads a sidecar or needs a window.
final class AppProvenanceExportSourceResolverTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/Lungfish Resolver Tests/Walk.lungfish", isDirectory: true)
    private var gff3: URL { project.appendingPathComponent("Bare Run Check/MN908947.3.gff3") }
    private var variants: URL { project.appendingPathComponent("Bare Run Check/variants.vcf") }
    private var readme: URL { project.appendingPathComponent("README.md") }
    private var bundle: URL { project.appendingPathComponent("Reference Sequences/Genome.lungfishref", isDirectory: true) }
    private var fileInBundle: URL { bundle.appendingPathComponent("genome/sequence.fa.gz") }

    // MARK: - The sidebar selection wins

    func testSidebarSelectionWinsOverAStaleCurrentDocument() {
        let records = RecordTable()
        records.add(gff3, workflow: "gff3 record")
        records.add(variants, workflow: "vcf record")

        let resolution = resolve(viewer: [gff3], selection: variants, records)

        XCTAssertEqual(resolution, .resolved(records.source(for: variants)))
        XCTAssertEqual(records.lookups, [variants.standardizedFileURL])
    }

    func testSelectedItemWithoutARecordIsUnresolvedAndNoOtherRecordIsSubstituted() {
        // The case from the GUI walk. The stale GFF3 has a record and README.md has none.
        let records = RecordTable()
        records.add(gff3, workflow: "gff3 record")

        let resolution = resolve(viewer: [gff3], selection: readme, records)

        XCTAssertEqual(resolution, .unresolvedSelection(readme.standardizedFileURL))
        XCTAssertEqual(
            records.lookups, [readme.standardizedFileURL],
            "The stale document's record must not be consulted for a selected file that has none."
        )
    }

    func testSelectionWithoutARecordIsUnresolvedWhenTheViewerNamesNothing() {
        let records = RecordTable()

        XCTAssertEqual(
            resolve(viewer: [nil, nil], selection: readme, records),
            .unresolvedSelection(readme.standardizedFileURL)
        )
    }

    func testViewerFileInsideTheSelectedFolderDoesNotOverrideTheSelection() {
        let records = RecordTable()
        records.add(gff3, workflow: "gff3 record")
        let folder = gff3.deletingLastPathComponent()

        XCTAssertEqual(
            resolve(viewer: [gff3], selection: folder, records),
            .unresolvedSelection(folder.standardizedFileURL),
            "A folder that holds the viewed file is not that file's record."
        )
    }

    // MARK: - The viewer wins when it is the selection or contains it

    func testViewerBundleThatContainsTheSelectedFileIsExported() {
        let records = RecordTable()
        records.add(bundle, workflow: "bundle record")
        records.add(fileInBundle, workflow: "file record")

        let resolution = resolve(viewer: [bundle], selection: fileInBundle, records)

        XCTAssertEqual(resolution, .resolved(records.source(for: bundle)))
        XCTAssertEqual(records.lookups, [bundle.standardizedFileURL])
    }

    func testViewerAndSelectionNamingTheSameFileExportThatFile() {
        let records = RecordTable()
        records.add(gff3, workflow: "gff3 record")

        let resolution = resolve(viewer: [gff3], selection: gff3, records)

        XCTAssertEqual(resolution, .resolved(records.source(for: gff3)))
        XCTAssertEqual(records.lookups, [gff3.standardizedFileURL])
    }

    func testAViewerBundleReachedThroughASymlinkStillContainsTheSelectedFile() throws {
        let root = try TestTempDirectory.make(prefix: "export-source-symlink")
        defer { TestTempDirectory.cleanup(root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        let realBundle = real.appendingPathComponent("Genome.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: realBundle, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let bundleThroughLink = link.appendingPathComponent("Genome.lungfishref", isDirectory: true)
        let records = RecordTable()
        records.add(bundleThroughLink, workflow: "bundle record")

        let resolution = resolve(
            viewer: [bundleThroughLink],
            selection: realBundle.appendingPathComponent("sequence.fa.gz"),
            records
        )

        XCTAssertEqual(
            resolution, .resolved(records.source(for: bundleThroughLink)),
            "The two spellings name one physical bundle."
        )
    }

    func testSiblingWithTheSameNamePrefixDoesNotContainTheSelection() {
        let records = RecordTable()
        records.add(bundle, workflow: "bundle record")
        let sibling = bundle.deletingLastPathComponent().appendingPathComponent("Genome.lungfishref-copy/sequence.fa")

        XCTAssertEqual(
            resolve(viewer: [bundle], selection: sibling, records),
            .unresolvedSelection(sibling.standardizedFileURL)
        )
    }

    func testFirstViewerCandidateThatContainsTheSelectionIsUsed() {
        let records = RecordTable()
        let mappingResult = project.appendingPathComponent("Analyses/minimap2-2026-10-10", isDirectory: true)
        let renderedBundle = mappingResult.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        let selected = renderedBundle.appendingPathComponent("alignments/sample.bam")
        records.add(mappingResult, workflow: "mapping record")
        records.add(renderedBundle, workflow: "bundle record")

        // A stale candidate ahead of the result does not hide it, and of the two that contain
        // the selection the one the viewer lists first is used.
        let resolution = resolve(viewer: [gff3, mappingResult, renderedBundle], selection: selected, records)

        XCTAssertEqual(resolution, .resolved(records.source(for: mappingResult)))
    }

    // MARK: - Nothing selected

    func testViewerCandidatesAreUsedInOrderWhenNothingIsSelected() {
        let records = RecordTable()
        records.add(bundle, workflow: "bundle record")
        records.add(gff3, workflow: "gff3 record")

        let resolution = resolve(viewer: [nil, bundle, nil, gff3], selection: nil, records)

        XCTAssertEqual(resolution, .resolved(records.source(for: bundle)))
    }

    func testViewerCandidateWithoutARecordIsUnresolvedWhenNothingIsSelected() {
        let records = RecordTable()

        XCTAssertEqual(
            resolve(viewer: [gff3], selection: nil, records),
            .unresolvedSelection(gff3.standardizedFileURL)
        )
    }

    func testNothingToExportWhenNeitherTheViewerNorTheSidebarNamesASource() {
        let records = RecordTable()

        XCTAssertEqual(resolve(viewer: [], selection: nil, records), .noCurrentSource)
        XCTAssertEqual(resolve(viewer: [nil, nil, nil], selection: nil, records), .noCurrentSource)
        XCTAssertTrue(records.lookups.isEmpty)
    }

    // MARK: - Helpers

    private func resolve(
        viewer: [URL?],
        selection: URL?,
        _ records: RecordTable
    ) -> AppProvenanceExportResolution {
        AppProvenanceExportSourceResolver.resolve(
            viewerCandidates: viewer,
            sidebarSelection: selection,
            findRecord: records.lookup
        )
    }

    /// Records by physical path, with a log of the files the resolver asked about.
    private final class RecordTable {
        private var records: [String: (sidecarURL: URL, envelope: ProvenanceEnvelope)] = [:]
        private(set) var lookups: [URL] = []

        func add(_ url: URL, workflow: String) {
            records[CanonicalFilePath.path(for: url)] = (
                sidecarURL: URL(fileURLWithPath: url.path + ".lungfish-provenance.json"),
                envelope: ProvenanceEnvelope.fixture(workflowName: workflow)
            )
        }

        func lookup(_ url: URL) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
            lookups.append(url)
            return records[CanonicalFilePath.path(for: url)]
        }

        /// The source the resolver should return for `url`, with its sidecar and record.
        func source(for url: URL) -> AppProvenanceExportSource {
            let record = records[CanonicalFilePath.path(for: url)]!
            return AppProvenanceExportSource(
                selectedURL: url.standardizedFileURL,
                sourceSidecarURL: record.sidecarURL,
                envelope: record.envelope
            )
        }
    }
}

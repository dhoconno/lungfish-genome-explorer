// ProvenanceLegacyDisplayTests.swift - What the Provenance tab shows for each legacy record shape
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishTestSupport

/// Pins what the Inspector's Provenance tab shows a scientist for each real legacy
/// record shape, before any write-side change (Phase 2.4, finding R8, lane W1C).
///
/// Each case copies its record into a temporary `.lungfish` project, loads it through
/// `ProvenanceInspectorViewModel.load(item:)` and compares the audit status, the Run
/// Summary, the Warnings, the Lineage, the Files & Outputs and the Invocation & Options
/// with an expected file under `Tests/Fixtures/provenance-display/expected`. The
/// expected values were captured on the unchanged reader, so a later writer lane that
/// moves any of them has to say so in its diff.
///
/// The project holds only the record, so a file the record lists inside the project is
/// absent and reads `intermediate file, not kept`. Runtime rows are compared only for
/// the fields a record's bytes carry. For a record that omits them, the reader fills
/// Executable, Process ID, Architecture and Dependency Set from the Mac it runs on, so a
/// bare run, which carries only an app version and an OS, is compared on those two.
///
/// To review a changed display, run `diff` between the expected file and the actual
/// file the failure names. The actual file is written under the temporary directory.
@MainActor
final class ProvenanceLegacyDisplayTests: XCTestCase {

    // MARK: - Bare legacy run

    /// The real record `lungfish-cli` 0.4.0-alpha.11 wrote beside a fetched GFF3. It has no
    /// `createdAt` or `runtimeIdentity`, so the reader converts it from the legacy run.
    ///
    /// The tab reads Incomplete with a File metadata incomplete warning, because the NCBI
    /// address the step fetched from has no checksum or size. Both files read as outside the
    /// project.
    func testBareLegacyRunFetchedByLungfishCLIReadsAsConvertedRecord() async throws {
        let project = try makeProject()
        let sidecarName = "MN908947.3.gff3.lungfish-provenance.json"
        let gff3 = try copyFixture(
            ProvenanceDisplayFixtures.sarscov2Directory.appendingPathComponent("MN908947.3.gff3"),
            to: project.appendingPathComponent("Imports/MN908947.3.gff3")
        )
        try copyFixture(
            ProvenanceDisplayFixtures.sarscov2Directory.appendingPathComponent(sidecarName),
            to: project.appendingPathComponent("Imports/\(sidecarName)")
        )

        try await assertDisplay(
            of: ProvenanceInspectableItem(
                url: gff3, sidebarType: .annotation, contentMode: .genomics, displayName: "MN908947.3.gff3"
            ),
            in: project,
            matching: ProvenanceDisplayCase(
                name: "bare-legacy-run",
                recordsWorkflowVersion: true,
                recordedRuntimeLabels: ["App Version", "OS"]
            ),
            sidecarName: sidecarName
        )
    }

    // MARK: - Released envelope with an embedded run

    /// The record `lungfish import fasta` of Lungfish 2026.9.58 wrote for the MHC demo's
    /// reference bundle. It is a full envelope and also carries the nested `legacyWorkflowRun`.
    ///
    /// The tab reads Complete with three steps and no warnings. The record carries its whole
    /// runtime identity.
    func testReleasedEnvelopeWithEmbeddedRunKeepsItsRecordedDisplay() async throws {
        let project = try makeProject()
        let bundlePath = "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref"
        let bundle = project.appendingPathComponent(bundlePath, isDirectory: true)
        try copyFixture(
            ProvenanceDisplayFixtures.directory
                .appendingPathComponent("\(bundlePath)/.lungfish-provenance.json"),
            to: bundle.appendingPathComponent(".lungfish-provenance.json")
        )

        let model = try await assertDisplay(
            of: ProvenanceInspectableItem(
                url: bundle,
                sidebarType: .referenceBundle,
                contentMode: .genomics,
                displayName: "SIMULATED-MHC-annotated-reference"
            ),
            in: project,
            matching: ProvenanceDisplayCase(
                name: "embedded-run-envelope",
                recordsWorkflowVersion: true,
                recordedRuntimeLabels: [
                    "App Version", "Executable", "Process ID", "OS", "Architecture", "Dependency Set",
                ]
            ),
            sidecarName: ".lungfish-provenance.json"
        )
        XCTAssertNotNil(model.resolvedEnvelope?.legacyRun, "The record carries its embedded legacy run.")
    }

    // MARK: - Primitive records

    /// An MSA record whose `files` is a keyed map, which the primitive adapter reads.
    ///
    /// The tab reads Complete, with every file outside the project and no embedded run.
    func testPrimitiveMSARecordWithKeyedFileMapsReadsThroughTheAdapter() async throws {
        let project = try makeProject()
        let bundle = project.appendingPathComponent("Analyses/Aligned.lungfishmsa", isDirectory: true)
        try place(ProvenanceLegacyRecords.msa, at: bundle.appendingPathComponent(".lungfish-provenance.json"))

        try await assertDisplay(
            of: ProvenanceInspectableItem(
                url: bundle,
                sidebarType: .multipleSequenceAlignmentBundle,
                contentMode: .genomics,
                displayName: "Aligned"
            ),
            in: project,
            matching: ProvenanceDisplayCase(
                name: "primitive-msa",
                recordsWorkflowVersion: false,
                recordedRuntimeLabels: ["Executable", "Process ID", "OS"]
            ),
            sidecarName: ".lungfish-provenance.json"
        )
    }

    /// A tree record with no `createdAt`: the reader dates it by the sidecar's modification
    /// date, which the test sets so the date is the same on every Mac.
    func testPrimitiveTreeRecordWithoutCreatedAtIsDatedBySidecarModificationDate() async throws {
        let project = try makeProject()
        let bundle = project.appendingPathComponent("Analyses/Tree.lungfishtree", isDirectory: true)
        let sidecar = bundle.appendingPathComponent(".lungfish-provenance.json")
        try place(ProvenanceLegacyRecords.tree, at: sidecar)
        let modificationDate = Date(timeIntervalSince1970: 1_777_777_776)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: sidecar.path)

        let model = try await assertDisplay(
            of: ProvenanceInspectableItem(
                url: bundle,
                sidebarType: .phylogeneticTreeBundle,
                contentMode: .genomics,
                displayName: "Tree"
            ),
            in: project,
            matching: ProvenanceDisplayCase(
                name: "primitive-tree",
                recordsWorkflowVersion: false,
                recordedRuntimeLabels: ["Executable", "OS"]
            ),
            sidecarName: ".lungfish-provenance.json"
        )
        let createdAt = try XCTUnwrap(model.summary.createdAt)
        XCTAssertEqual(createdAt.timeIntervalSince1970, modificationDate.timeIntervalSince1970, accuracy: 0.001)
    }

    /// An assembler's own record, stored as `assembly/provenance.json` with no envelope.
    ///
    /// The tab reads Incomplete because the record has no exit status. The output row names
    /// the bundle, since the record lists no output of its own.
    func testPrimitiveAssemblyRecordStoredUnderAssemblyDirectoryReadsThroughTheAdapter() async throws {
        let project = try makeProject()
        let bundle = project.appendingPathComponent("Analyses/assembly-output.lungfishref", isDirectory: true)
        try place(ProvenanceLegacyRecords.assembly, at: bundle.appendingPathComponent("assembly/provenance.json"))

        try await assertDisplay(
            of: ProvenanceInspectableItem(
                url: bundle,
                sidebarType: .referenceBundle,
                contentMode: .assembly,
                displayName: "assembly-output"
            ),
            in: project,
            matching: ProvenanceDisplayCase(
                name: "primitive-assembly",
                recordsWorkflowVersion: true,
                recordedRuntimeLabels: ["App Version", "OS", "Architecture", "Conda Environment"]
            ),
            sidecarName: "provenance.json"
        )
    }

    // MARK: - Typed record

    /// A schema 3 `mapping-provenance.json`, which the reader turns into an envelope itself.
    /// It is also app state, so the file stays beside the mapping result.
    ///
    /// The tab reads Incomplete because the viewer bundle it lists has no checksum, and it
    /// collapses the two FASTQ files into one bundle row.
    func testSchema3MappingProvenanceReadsAsTypedRecord() async throws {
        let project = try makeProject()
        let analysis = project.appendingPathComponent("Analyses/minimap2-2026-07-14T15-20-00", isDirectory: true)
        try place(ProvenanceLegacyRecords.mappingSchema3, at: analysis.appendingPathComponent("mapping-provenance.json"))

        try await assertDisplay(
            of: ProvenanceInspectableItem(
                url: analysis,
                sidebarType: .analysisResult,
                contentMode: .mapping,
                displayName: "minimap2-2026-07-14T15-20-00"
            ),
            in: project,
            matching: ProvenanceDisplayCase(
                name: "typed-mapping-schema3",
                recordsWorkflowVersion: false,
                recordedRuntimeLabels: ["Executable", "Conda Environment"]
            ),
            sidecarName: "mapping-provenance.json"
        )
    }

    // MARK: - Harness

    /// Loads `item`, waits for the lookup, and compares what the tab shows with the
    /// expected file of `displayCase`. Returns the loaded model for a further check.
    @discardableResult
    private func assertDisplay(
        of item: ProvenanceInspectableItem,
        in project: URL,
        matching displayCase: ProvenanceDisplayCase,
        sidecarName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        model.load(item: item)
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.", file: file, line: line)

        // These guard the expected file: a lookup that found nothing must not be pinned.
        XCTAssertNotNil(model.resolvedEnvelope, "No record was found for \(displayCase.name).", file: file, line: line)
        XCTAssertNotNil(model.summary.createdAt, "The Run Summary must date \(displayCase.name).", file: file, line: line)
        XCTAssertEqual(
            model.resolvedSidecarURL?.lastPathComponent, sidecarName,
            "The record came from an unexpected file.", file: file, line: line
        )

        let snapshot = ProvenanceDisplaySnapshot.capture(
            model, for: displayCase, redaction: ProvenanceDisplayRedaction(projectURL: project)
        )
        let actual = try snapshot.canonicalJSON()
        XCTAssertEqual(
            try snapshot.privatePathLeaks(), [],
            "The snapshot of \(displayCase.name) names a private path, so it cannot be committed.",
            file: file, line: line
        )

        let expectedURL = ProvenanceDisplayFixtures.expectedDirectory
            .appendingPathComponent("\(displayCase.name).json")
        guard let expectedData = try? Data(contentsOf: expectedURL) else {
            let written = ProvenanceDisplaySnapshot.writeActual(actual, named: displayCase.name)
            XCTFail(
                "No expected display at \(expectedURL.path). The display now is in \(written?.path ?? "(not written)").",
                file: file, line: line
            )
            return model
        }
        let expected = try ProvenanceDisplaySnapshot.decode(expected: expectedData)
        if snapshot != expected {
            let written = ProvenanceDisplaySnapshot.writeActual(actual, named: displayCase.name)
            XCTFail(
                """
                The Provenance tab no longer shows \(displayCase.name) as it did.
                Compare \(expectedURL.path)
                with    \(written?.path ?? "(not written)")
                \(ProvenanceDisplaySnapshot.lineDifferences(expected: try expected.canonicalJSON(), actual: actual))
                """,
                file: file, line: line
            )
        }
        return model
    }

    /// A fresh `.lungfish` project inside a temporary folder that the test removes.
    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-legacy-display")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Legacy Records.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func place(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Copies a committed fixture into the temporary project, since some readers write.
    @discardableResult
    private func copyFixture(_ source: URL, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

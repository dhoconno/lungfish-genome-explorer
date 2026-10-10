// ProvenanceReadOnlyTests.swift - Reading a project never writes to it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Proves that selecting a result and reading its provenance leave the project as it was
/// (Phase 2.4, finding R8, lane W2C, ruling V6).
///
/// Each case builds a folder shaped like one that an older LGE rewrote or filled in on read.
/// It records every entry under the project, runs the coverage audit and the Inspector's lookup
/// on the folder, and requires the same entries afterwards. A result with no batch record shows
/// Missing provenance, because a record made at read time would name a date and a version that
/// did not run it.
@MainActor
final class ProvenanceReadOnlyTests: XCTestCase {

    // MARK: - TaxTriage

    /// A TaxTriage record written before the SQLite index existed, in a folder that now holds
    /// `taxtriage.sqlite`. The old audit added an index step with a `lungfish-app` command and
    /// cleared the signatures. Reading shows the record as recorded.
    func testTaxTriageRecordWithoutItsSQLiteOutputIsReadAndNotRewritten() async throws {
        let project = try makeProject()
        let result = project.appendingPathComponent("Analyses/taxtriage-2026-10-09T12-00-00", isDirectory: true)
        let fastq = result.appendingPathComponent("SampleE.fastq")
        let report = result.appendingPathComponent("SampleE.organisms.report.txt")
        try place(Data("@r\nACGT\n+\n!!!!\n".utf8), at: fastq)
        try place(Data("organism\treads\nExample virus\t4\n".utf8), at: report)
        try place(Data("SQLite format 3\u{0}".utf8), at: result.appendingPathComponent("taxtriage.sqlite"))

        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "SampleE", fastq1: fastq)],
            outputDirectory: result,
            maxCpus: 2,
            profile: "docker"
        )
        try TaxTriageResult(
            config: config,
            runtime: 3,
            exitCode: 0,
            outputDirectory: result,
            reportFiles: [report],
            allOutputFiles: [report]
        ).save()

        let input = try ProvenanceFileDescriptor.file(url: fastq, format: .fastq, role: .input)
        let reportOutput = try ProvenanceFileDescriptor.file(url: report, format: .text, role: .report)
        let step = ProvenanceStep(
            toolName: "TaxTriage",
            toolVersion: "2.0.0",
            argv: ["nextflow", "run", "TaxTriage", "--input", fastq.path],
            inputs: [input],
            outputs: [reportOutput],
            exitStatus: 0,
            wallTimeSeconds: 3,
            stderr: ""
        )
        let signature = ProvenanceSignatureReference(
            provider: "test-provider",
            provenanceSHA256: String(repeating: "c", count: 64),
            signaturePath: "provenance.sig",
            publicKeyPath: "provenance.pub"
        )
        let record = ProvenanceEnvelope(
            workflowName: "TaxTriage",
            workflowVersion: "2026.09.1",
            toolName: "TaxTriage",
            toolVersion: "2.0.0",
            argv: step.argv,
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [input, reportOutput],
            output: reportOutput,
            outputs: [reportOutput],
            steps: [step],
            wallTimeSeconds: 3,
            exitStatus: 0,
            stderr: "",
            signatures: [signature]
        )
        try place(
            ProvenanceJSON.encoder.encode(record),
            at: result.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        )

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: result, sidebarType: .taxTriageResult, contentMode: .metagenomics, displayName: "TaxTriage"
            ),
            in: project
        )

        XCTAssertEqual(model.audit.status, .present)
        XCTAssertEqual(model.summary.statusLabel, "Complete")
        XCTAssertEqual(model.summary.stepCount, 1, "The record has no index step, and reading adds none.")
        XCTAssertEqual(model.summary.signatureCount, 1, "The record's signature stays.")
        XCTAssertEqual(model.resolvedEnvelope?.steps.map(\.toolName), ["TaxTriage"])
    }

    /// A TaxTriage result that has no provenance record at all. Reading shows Missing
    /// provenance and writes none.
    func testTaxTriageResultWithoutARecordShowsMissingProvenance() async throws {
        let project = try makeProject()
        let result = project.appendingPathComponent("Analyses/taxtriage-2026-10-09T13-00-00", isDirectory: true)
        let fastq = result.appendingPathComponent("SampleF.fastq")
        let report = result.appendingPathComponent("SampleF.organisms.report.txt")
        try place(Data("@r\nACGT\n+\n!!!!\n".utf8), at: fastq)
        try place(Data("organism\treads\nExample virus\t4\n".utf8), at: report)
        try TaxTriageResult(
            config: TaxTriageConfig(
                samples: [TaxTriageSample(sampleId: "SampleF", fastq1: fastq)],
                outputDirectory: result,
                maxCpus: 2,
                profile: "docker"
            ),
            runtime: 3,
            exitCode: 0,
            outputDirectory: result,
            reportFiles: [report],
            allOutputFiles: [report]
        ).save()

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: result, sidebarType: .taxTriageResult, contentMode: .metagenomics, displayName: "TaxTriage"
            ),
            in: project
        )

        assertMissingProvenance(model, for: result)
    }

    // MARK: - EsViritu

    /// An EsViritu batch whose samples have records but whose root has none and no manifest.
    /// The old audit inferred a manifest and a summary table and then wrote a root record.
    func testEsVirituBatchWithoutARootRecordShowsMissingProvenance() async throws {
        let project = try makeProject()
        let batch = project.appendingPathComponent("Analyses/esviritu-batch-2026-10-09", isDirectory: true)
        try makeEsVirituSample("SampleC", in: batch)

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: batch, sidebarType: .esvirituResult, contentMode: .metagenomics, displayName: "EsViritu"
            ),
            in: project
        )

        assertMissingProvenance(model, for: batch)
        let written = ["esviritu-batch-result.json", "esviritu-batch-summary.tsv", ProvenanceRecorder.provenanceFilename]
        for name in written {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: batch.appendingPathComponent(name).path),
                "Reading must not write \(name)."
            )
        }
    }

    /// The same batch with its manifest saved but no summary table. The old audit wrote the
    /// table and the root record.
    func testEsVirituBatchWithAManifestButNoRootRecordShowsMissingProvenance() async throws {
        let project = try makeProject()
        let batch = project.appendingPathComponent("Analyses/esviritu-batch-2026-10-09T09-00-00", isDirectory: true)
        try makeEsVirituSample("SampleD", in: batch)
        try MetagenomicsBatchResultStore.saveEsViritu(
            EsVirituBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 1,
                    createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                    sampleCount: 1
                ),
                summaryTSV: "esviritu-batch-summary.tsv",
                samples: [
                    MetagenomicsBatchSampleRecord(
                        sampleId: "SampleD",
                        resultDirectory: "SampleD",
                        inputFiles: [batch.appendingPathComponent("SampleD/SampleD.fastq").path],
                        isPairedEnd: false
                    ),
                ]
            ),
            to: batch
        )

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: batch, sidebarType: .esvirituResult, contentMode: .metagenomics, displayName: "EsViritu"
            ),
            in: project
        )

        assertMissingProvenance(model, for: batch)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: batch.appendingPathComponent("esviritu-batch-summary.tsv").path),
            "Reading must not write the summary table."
        )
    }

    // MARK: - Records of earlier LGE versions

    /// The released MHC reference bundle's record, a full envelope that also holds the nested
    /// `legacyWorkflowRun`.
    func testReferenceBundleWhoseRecordHoldsANestedRunIsReadWithoutWriting() async throws {
        let project = try makeProject()
        let bundlePath = "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref"
        let bundle = project.appendingPathComponent(bundlePath, isDirectory: true)
        try copyFixture(
            ProvenanceDisplayFixtures.directory.appendingPathComponent("\(bundlePath)/.lungfish-provenance.json"),
            to: bundle.appendingPathComponent(".lungfish-provenance.json")
        )

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: bundle,
                sidebarType: .referenceBundle,
                contentMode: .genomics,
                displayName: "SIMULATED-MHC-annotated-reference"
            ),
            in: project
        )

        XCTAssertNotNil(model.resolvedEnvelope?.legacyRun, "The record carries its embedded legacy run.")
        XCTAssertEqual(model.summary.stepCount, 3)
    }

    /// A folder whose record is a bare legacy run, the shape older writers left in a result folder.
    func testFolderWithABareRunRecordIsReadWithoutWriting() async throws {
        let project = try makeProject()
        let folder = project.appendingPathComponent("Analyses/bare-run-result", isDirectory: true)
        try copyFixture(
            ProvenanceDisplayFixtures.sarscov2Directory
                .appendingPathComponent("MN908947.3.gff3.lungfish-provenance.json"),
            to: folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        )

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: folder, sidebarType: .analysisResult, contentMode: .genomics, displayName: "bare-run-result"
            ),
            in: project
        )

        XCTAssertNotNil(model.resolvedEnvelope, "The bare run reads as a converted record.")
        XCTAssertEqual(model.resolvedSidecarURL?.lastPathComponent, ProvenanceRecorder.provenanceFilename)
    }

    /// The real record `lungfish-cli` 0.4.0-alpha.11 wrote beside a fetched GFF3.
    func testFileWithABareRunSidecarBesideItIsReadWithoutWriting() async throws {
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

        let model = try await assertReadingLeavesProjectUnchanged(
            ProvenanceInspectableItem(
                url: gff3, sidebarType: .annotation, contentMode: .genomics, displayName: "MN908947.3.gff3"
            ),
            in: project
        )

        XCTAssertEqual(model.resolvedSidecarURL?.lastPathComponent, sidecarName)
    }

    // MARK: - The snapshot itself

    /// The byte-identical checks above are only as good as the snapshot, so this case changes a
    /// folder in each way a read could and requires the snapshot to name each change.
    func testTreeSnapshotNamesEveryKindOfChange() throws {
        let root = try TestTempDirectory.make(prefix: "provenance-tree-snapshot")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let kept = root.appendingPathComponent("kept.txt")
        let retargeted = root.appendingPathComponent("link")
        let dated = Date(timeIntervalSince1970: 1_700_000_000)
        try place(Data("kept".utf8), at: kept)
        try place(Data("same bytes".utf8), at: root.appendingPathComponent("dated.txt"))
        try place(Data("old".utf8), at: root.appendingPathComponent("edited.txt"))
        try place(Data("gone".utf8), at: root.appendingPathComponent("removed.txt"))
        try FileManager.default.createSymbolicLink(at: retargeted, withDestinationURL: kept)
        for name in ["kept.txt", "dated.txt", "edited.txt", "removed.txt"] {
            try FileManager.default.setAttributes(
                [.modificationDate: dated], ofItemAtPath: root.appendingPathComponent(name).path
            )
        }
        let before = try ProjectTreeSnapshot(of: root)
        XCTAssertEqual(try ProjectTreeSnapshot(of: root).differences(from: before), [], "Nothing changed yet.")

        try FileManager.default.setAttributes(
            [.modificationDate: dated.addingTimeInterval(60)],
            ofItemAtPath: root.appendingPathComponent("dated.txt").path
        )
        try place(Data("newer".utf8), at: root.appendingPathComponent("edited.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        try place(Data("new".utf8), at: root.appendingPathComponent(".hidden/added.txt"))
        try FileManager.default.removeItem(at: retargeted)
        try FileManager.default.createSymbolicLink(
            at: retargeted, withDestinationURL: root.appendingPathComponent("edited.txt")
        )

        let changes = try ProjectTreeSnapshot(of: root).differences(from: before)
        func named(_ verb: String, _ path: String) -> Bool { changes.contains { $0.hasPrefix("\(verb) \(path) ") } }
        XCTAssertTrue(named("changed", "dated.txt"), "A file with the same bytes and a new date: \(changes)")
        XCTAssertTrue(named("rewrote", "edited.txt"), "A file with new bytes: \(changes)")
        XCTAssertTrue(named("removed", "removed.txt"), "A removed file: \(changes)")
        XCTAssertTrue(named("added", ".hidden"), "A new hidden folder: \(changes)")
        XCTAssertTrue(named("added", ".hidden/added.txt"), "A new hidden file: \(changes)")
        XCTAssertTrue(named("changed", "link"), "A link that points elsewhere: \(changes)")
        XCTAssertFalse(
            changes.contains { $0.split(separator: " ").dropFirst().first == "kept.txt" },
            "An untouched file: \(changes)"
        )
        XCTAssertEqual(changes.count, 6, "\(changes)")
    }

    // MARK: - Harness

    /// Runs the coverage audit and the Inspector's lookup on `item` and requires `project` to hold
    /// exactly the entries it held before. Returns the loaded model for a further check.
    private func assertReadingLeavesProjectUnchanged(
        _ item: ProvenanceInspectableItem,
        in project: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ProvenanceInspectorViewModel {
        let before = try ProjectTreeSnapshot(of: project)

        let audited = ProvenanceCoverageMonitor().audit(item)
        let model = ProvenanceInspectorViewModel()
        model.load(item: item)
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.", file: file, line: line)

        let after = try ProjectTreeSnapshot(of: project)
        XCTAssertEqual(
            after.differences(from: before), [],
            "Reading the provenance of \(item.url?.lastPathComponent ?? "the item") changed the project.",
            file: file, line: line
        )
        XCTAssertEqual(audited, model.audit, "The audit and the lookup disagree.", file: file, line: line)
        return model
    }

    private func assertMissingProvenance(
        _ model: ProvenanceInspectorViewModel,
        for folder: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.audit.status, .missing, file: file, line: line)
        XCTAssertEqual(model.summary.statusLabel, "Missing provenance", file: file, line: line)
        XCTAssertNil(model.resolvedEnvelope, file: file, line: line)
        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: folder), file: file, line: line)
        XCTAssertTrue(
            model.warnings.contains { $0.title == "Missing provenance" },
            "\(model.warnings)", file: file, line: line
        )
    }

    /// A sample folder of an EsViritu batch with its own record, and no record at the batch root.
    private func makeEsVirituSample(_ sampleID: String, in batch: URL) throws {
        let sample = batch.appendingPathComponent(sampleID, isDirectory: true)
        let fastq = sample.appendingPathComponent("\(sampleID).fastq")
        let table = sample.appendingPathComponent("\(sampleID).detected_virus.info.tsv")
        try place(Data("@r\nACGT\n+\n!!!!\n".utf8), at: fastq)
        try place(Data("virus\treads\nExample virus\t3\n".utf8), at: table)

        let input = try ProvenanceFileDescriptor.file(url: fastq, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: table, format: .text, role: .output)
        let step = ProvenanceStep(
            toolName: "EsViritu",
            toolVersion: "2.0.0",
            argv: ["EsViritu", "--input", fastq.path],
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 2
        )
        let record = ProvenanceEnvelope(
            workflowName: "Viral Metagenomics Detection",
            workflowVersion: "2026.05",
            toolName: "EsViritu",
            toolVersion: "2.0.0",
            argv: step.argv,
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 2,
            exitStatus: 0,
            stderr: ""
        )
        try place(
            ProvenanceJSON.encoder.encode(record),
            at: sample.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        )
    }

    /// A fresh `.lungfish` project inside a temporary folder that the test removes.
    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-read-only")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Read Only.lungfish", isDirectory: true)
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

// MARK: - Tree snapshot

/// Every entry under a folder, with the bytes of each regular file, so a test can prove that
/// reading changed nothing. A file rewritten with the same bytes still shows, through its
/// modification date, and so does a folder or a link that appeared or vanished.
struct ProjectTreeSnapshot: Equatable {
    enum Entry: Equatable {
        case directory
        case file(Data, modified: Date)
        case symlink(destination: String)

        var summary: String {
            switch self {
            case .directory:
                return "folder"
            case .file(let bytes, let modified):
                return "file of \(bytes.count) bytes modified \(modified.timeIntervalSince1970)"
            case .symlink(let destination):
                return "link to \(destination)"
            }
        }
    }

    /// The entries by path relative to the folder, hidden files included.
    let entries: [String: Entry]

    init(of root: URL) throws {
        // The path-based walk yields paths relative to `root` and does not follow links.
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var found: [String: Entry] = [:]
        for case let relative as String in walker {
            let url = root.appendingPathComponent(relative)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                found[relative] = .symlink(destination: try fileManager.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory:
                found[relative] = .directory
            case .typeRegular:
                found[relative] = .file(
                    try Data(contentsOf: url),
                    modified: attributes[.modificationDate] as? Date ?? .distantPast
                )
            default:
                break
            }
        }
        entries = found
    }

    /// The bytes of the regular files by relative path, ignoring everything else.
    var fileBytes: [String: Data] {
        entries.compactMapValues { entry in
            if case .file(let bytes, _) = entry { return bytes }
            return nil
        }
    }

    /// What differs from `earlier`, one line per path, for a failure message.
    func differences(from earlier: ProjectTreeSnapshot) -> [String] {
        var report: [String] = []
        for path in Set(entries.keys).union(earlier.entries.keys).sorted() {
            switch (earlier.entries[path], entries[path]) {
            case (nil, let added?):
                report.append("added \(path) (\(added.summary))")
            case (let removed?, nil):
                report.append("removed \(path) (\(removed.summary))")
            case (.file(let oldBytes, _)?, .file(let newBytes, _)?) where oldBytes != newBytes:
                report.append("rewrote \(path) (\(oldBytes.count) bytes became \(newBytes.count) bytes)")
            case (let old?, let new?) where old != new:
                report.append("changed \(path) (\(old.summary) became \(new.summary))")
            default:
                break
            }
        }
        return report
    }
}

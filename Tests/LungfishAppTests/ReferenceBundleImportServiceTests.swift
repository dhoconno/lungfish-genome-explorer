// ReferenceBundleImportServiceTests.swift - Tests for reference import classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

private final class ReferenceImportVisibilityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.withLock {
            values.append(value)
        }
    }

    var observedFinalBundleBeforeCompletion: Bool {
        lock.withLock {
            values.contains(true)
        }
    }
}

final class ReferenceBundleImportServiceTests: XCTestCase {
    @MainActor
    func testImportAsReferenceBundleRecordsOriginalSourceInProvenance() async throws {
        if let missingInfo = await NativeBundleBuilder().checkRequiredTools() {
            throw XCTSkip("Native reference bundle tools are unavailable: \(missingInfo.description)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleImportServiceTests-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("References", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("source.fa")
        try ">chr1\nACGTACGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let expectedBundleURL = outputDirectory.appendingPathComponent("Imported_Ref.lungfishref", isDirectory: true)
        let visibility = ReferenceImportVisibilityCollector()

        let result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            preferredBundleName: "Imported Ref",
            progressHandler: { progress, _ in
                if progress < 1.0 {
                    visibility.append(FileManager.default.fileExists(atPath: expectedBundleURL.path))
                }
            }
        )

        XCTAssertEqual(result.bundleURL.standardizedFileURL, expectedBundleURL.standardizedFileURL)
        XCTAssertFalse(
            visibility.observedFinalBundleBeforeCompletion,
            "Reference import should not expose the final .lungfishref path before the staged bundle is complete."
        )
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        let expectedCommand = [
            LungfishAppIdentity.recordedToolName,
            "reference-bundle-import",
            sourceURL.standardizedFileURL.path,
            "--output-directory",
            outputDirectory.standardizedFileURL.path,
            "--name",
            "Imported Ref",
        ]
        XCTAssertEqual(provenance.workflowName, "lungfish reference import")
        XCTAssertEqual(provenance.argv, expectedCommand)
        XCTAssertEqual(provenance.steps.first?.argv, expectedCommand)
        XCTAssertTrue(provenance.files.contains {
            $0.path == sourceURL.standardizedFileURL.path && $0.role == .input && $0.checksumSHA256 != nil
        })
        XCTAssertFalse(provenance.steps.flatMap(\.inputs).contains {
            $0.path.contains("ref-import-")
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path.hasPrefix(result.bundleURL.path) && $0.checksumSHA256 != nil
        })
        XCTAssertFalse(provenance.outputs.contains { $0.path.contains(".building-") })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }

    @MainActor
    func testNativeBundleBuildCleansStagingAfterPostStructureFailure() async throws {
        if let missingInfo = await NativeBundleBuilder().checkRequiredTools() {
            throw XCTSkip("Native reference bundle tools are unavailable: \(missingInfo.description)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleImportServiceTests-failure-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("References", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("malformed.fa")
        try "not a fasta file\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let configuration = BuildConfiguration(
            name: "Broken Ref",
            identifier: "org.lungfish.tests.broken-ref",
            fastaURL: sourceURL,
            outputDirectory: outputDirectory,
            source: SourceInfo(organism: "Broken Ref", assembly: "Broken Ref"),
            compressFASTA: true
        )

        do {
            _ = try await NativeBundleBuilder().build(configuration: configuration)
            XCTFail("Malformed FASTA should fail after staging begins.")
        } catch {
            // Expected: malformed FASTA has no sequence headers.
        }

        let finalBundleURL = outputDirectory.appendingPathComponent("Broken_Ref.lungfishref", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalBundleURL.path))
        let residualEntries = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertFalse(
            residualEntries.contains { $0.contains(".building-") },
            "Failed native bundle builds should remove hidden staging directories."
        )
    }

    /// A SIGTERM cancels the task that awaits the import and not the builder's own flag, so the builder
    /// has to stop between its steps on the task's cancel and leave nothing behind (A48 M3 review,
    /// Fix 5, L4). The cancel comes when the manifest step starts, after the managed tools have run,
    /// so a stopped child process cannot end the build and only the builder's own check can.
    @MainActor
    func testACancelledTaskStopsTheBuildBetweenStepsAndLeavesNothing() async throws {
        if let missingInfo = await NativeBundleBuilder().checkRequiredTools() {
            try ToolAvailability.skipOrFail("Native reference bundle tools are unavailable: \(missingInfo.description)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleImportServiceTests-cancel-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let references = project.appendingPathComponent("Reference Sequences", isDirectory: true)
        let scratch = project.appendingPathComponent(".tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("source.fa")
        try ">chr1\nACGTACGTAC\n>chr2\nTTGGCCAATT\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let task = Task { () -> Result<ReferenceBundleImportResult, any Error> in
            do {
                return .success(try await ReferenceBundleImportService.shared.importAsReferenceBundle(
                    sourceURL: sourceURL,
                    outputDirectory: references,
                    progressHandler: { _, message in
                        guard message == "Generating manifest" else { return }
                        // The service's scratch folder is in place when the cancel comes, so the
                        // check that it is gone afterwards is not vacuous.
                        let scratchEntries = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
                        XCTAssertTrue(scratchEntries.contains { $0.hasPrefix("ref-import-") }, "\(scratchEntries)")
                        // The caller's task is what a SIGTERM cancels, and the builder's own flag stays unset.
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                ))
            } catch {
                return .failure(error)
            }
        }
        guard case .failure(let error) = await task.value else {
            return XCTFail("the build ignored the cancelled task")
        }
        switch error {
        case let build as BundleBuildError:
            if case .cancelled = build {} else { XCTFail("the build failed with \(build) and not as a cancel") }
        case is CancellationError:
            break
        default:
            XCTFail("the import ended with \(error) and not as a cancel")
        }

        let kept = try FileManager.default.contentsOfDirectory(atPath: references.path).filter {
            $0.hasSuffix(".lungfishref") || $0.contains(".building-") || $0.contains(".processing")
        }
        XCTAssertEqual(kept, [], "a cancelled import leaves no bundle, staging folder or marker")
        let scratchLeft = ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
            .filter { $0.hasPrefix("ref-import-") }
        XCTAssertEqual(scratchLeft, [], "a cancelled import removes its scratch folder")
    }

    func testClassifiesStandaloneReferenceExtensions() {
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fasta")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.gbff")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.embl")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.gz")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.bz2")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.xz")),
            .standaloneReferenceSequence
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/reference.fa.zst")),
            .standaloneReferenceSequence
        )
    }

    func testClassifiesTrackTypes() {
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/track.gff3")),
            .annotationTrack
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/variants.vcf.gz")),
            .variantTrack
        )
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/aln.bam")),
            .alignmentTrack
        )
    }

    func testClassifiesUnsupportedType() {
        XCTAssertEqual(
            ReferenceBundleImportService.classify(URL(fileURLWithPath: "/tmp/notes.txt")),
            .unsupported
        )
    }

    func testNormalizedExtensionStripsCompressionWrapper() {
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fa.gz")),
            "fa"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.gb.bgz")),
            "gb"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fna.bz2")),
            "fna"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fasta.xz")),
            "fasta"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.normalizedExtension(for: URL(fileURLWithPath: "/tmp/a.fna.zstd")),
            "fna"
        )
    }

    func testDefaultBundleNamePreservesVersionPunctuation() {
        XCTAssertEqual(
            ReferenceBundleImportService.defaultBundleName(
                for: URL(fileURLWithPath: "/tmp/IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2.gb")
            ),
            "IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.defaultBundleName(
                for: URL(fileURLWithPath: "/tmp/IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2.gb.gz")
            ),
            "IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2"
        )
        XCTAssertEqual(
            ReferenceBundleImportService.defaultBundleName(
                for: URL(fileURLWithPath: "/tmp/reference.release.2026.fa")
            ),
            "reference.release.2026"
        )
    }
}

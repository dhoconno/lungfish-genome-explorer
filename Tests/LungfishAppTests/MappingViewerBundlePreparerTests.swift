import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class MappingViewerBundlePreparerTests: XCTestCase {

    func testMaterializeItemRetriesWithoutXattrsAfterCloneEEXIST() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("MappingViewerBundlePreparerTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source", isDirectory: true)
        let destination = tempDir.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try "complete payload".write(
            to: source.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )

        var calls: [(source: URL, destination: URL, flags: copyfile_flags_t)] = []
        try MappingViewerBundlePreparer.materializeItem(
            from: source,
            to: destination,
            fileManager: fileManager,
            copyfile: { sourcePath, destinationPath, flags in
                calls.append((URL(fileURLWithPath: sourcePath), URL(fileURLWithPath: destinationPath), flags))

                if calls.count == 1 {
                    XCTAssertEqual(
                        flags,
                        copyfile_flags_t(COPYFILE_RECURSIVE | COPYFILE_CLONE)
                    )
                    do {
                        try fileManager.createDirectory(
                            at: URL(fileURLWithPath: destinationPath),
                            withIntermediateDirectories: true
                        )
                        try "partial".write(
                            to: URL(fileURLWithPath: destinationPath).appendingPathComponent("partial-marker.txt"),
                            atomically: true,
                            encoding: .utf8
                        )
                    } catch {
                        XCTFail("Synthetic clone collision setup failed: \(error)")
                        return EIO
                    }
                    XCTAssertTrue(fileManager.fileExists(atPath: destinationPath))
                    XCTAssertTrue(fileManager.fileExists(
                        atPath: URL(fileURLWithPath: destinationPath)
                            .appendingPathComponent("partial-marker.txt").path
                    ))
                    return EEXIST
                }

                XCTAssertEqual(calls.count, 2)
                XCTAssertFalse(fileManager.fileExists(atPath: destinationPath))
                XCTAssertFalse(fileManager.fileExists(
                    atPath: URL(fileURLWithPath: destinationPath)
                        .appendingPathComponent("partial-marker.txt").path
                ))
                XCTAssertEqual(
                    flags,
                    copyfile_flags_t(COPYFILE_RECURSIVE | COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC)
                )
                do {
                    try fileManager.copyItem(
                        at: URL(fileURLWithPath: sourcePath),
                        to: URL(fileURLWithPath: destinationPath)
                    )
                } catch {
                    XCTFail("Synthetic fallback copy failed: \(error)")
                    return EIO
                }
                return 0
            }
        )

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map { $0.source.path }, [source.path, source.path])
        XCTAssertEqual(calls.map { $0.destination.path }, [destination.path, destination.path])
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("payload.txt"), encoding: .utf8),
            "complete payload"
        )
        XCTAssertFalse(fileManager.fileExists(
            atPath: destination.appendingPathComponent("partial-marker.txt").path
        ))
    }

    func testMaterializeItemDoesNotRetryNonEEXIST() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("MappingViewerBundlePreparerTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source", isDirectory: true)
        let destination = tempDir.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        var callCount = 0
        XCTAssertThrowsError(
            try MappingViewerBundlePreparer.materializeItem(
                from: source,
                to: destination,
                fileManager: fileManager,
                copyfile: { _, _, _ in
                    callCount += 1
                    return EACCES
                }
            )
        ) { error in
            XCTAssertEqual(error as? POSIXError, POSIXError(.EACCES))
        }
        XCTAssertEqual(callCount, 1)
    }

    func testMaterializeItemPropagatesFallbackFailure() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("MappingViewerBundlePreparerTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source", isDirectory: true)
        let destination = tempDir.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        var callCount = 0
        XCTAssertThrowsError(
            try MappingViewerBundlePreparer.materializeItem(
                from: source,
                to: destination,
                fileManager: fileManager,
                copyfile: { _, destinationPath, _ in
                    callCount += 1
                    if callCount == 1 {
                        do {
                            try fileManager.createDirectory(
                                at: URL(fileURLWithPath: destinationPath),
                                withIntermediateDirectories: true
                            )
                        } catch {
                            XCTFail("Synthetic clone collision setup failed: \(error)")
                            return EIO
                        }
                        XCTAssertTrue(fileManager.fileExists(atPath: destinationPath))
                        return EEXIST
                    }
                    XCTAssertEqual(callCount, 2)
                    XCTAssertFalse(fileManager.fileExists(atPath: destinationPath))
                    return ENOSPC
                }
            )
        ) { error in
            XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC))
        }
        XCTAssertEqual(callCount, 2)
    }

    func testPrepareBaseBundleRecoversFromAppleDoubleCollisionOnExternalExFAT() throws {
        guard let testRootPath = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"],
              !testRootPath.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }

        let fileManager = FileManager.default
        let testDirectory = URL(fileURLWithPath: testRootPath, isDirectory: true)
            .appendingPathComponent(".lge-mapping-preparer-exfat-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: false)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: testDirectory)) }

        let sourceBundle = testDirectory.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let sourceGenome = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: sourceGenome, withIntermediateDirectories: true)

        let sourcePayload = sourceGenome.appendingPathComponent("sequence.fa.gz")
        let sourceIndex = sourceGenome.appendingPathComponent("sequence.fa.gz.fai")
        try "ACGT".write(to: sourcePayload, atomically: true, encoding: .utf8)
        try "chr1\t4\n".write(to: sourceIndex, atomically: true, encoding: .utf8)
        let attributeData = Data("external-volume-fixture".utf8)
        let setXattrResult = attributeData.withUnsafeBytes { bytes in
            Darwin.setxattr(
                sourcePayload.path,
                "com.lungfish.mapping-preparer-test",
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(setXattrResult, 0)

        let sourceAppleDouble = sourceGenome.appendingPathComponent("._sequence.fa.gz")
        XCTAssertTrue(
            fileManager.fileExists(atPath: sourceAppleDouble.path),
            "The ExFAT fixture must expose an AppleDouble sidecar before materialization."
        )

        let manifest = BundleManifest(
            name: "External Volume Fixture",
            identifier: "test.external-volume-fixture",
            source: SourceInfo(organism: "Test", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 4,
                chromosomes: []
            )
        )
        try manifest.save(to: sourceBundle)

        let viewerBundle = testDirectory.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle
        )

        let viewerManifest = try BundleManifest.load(from: viewerBundle)
        XCTAssertEqual(viewerManifest.genome?.path, "genome/sequence.fa.gz")
        XCTAssertEqual(viewerManifest.genome?.indexPath, "genome/sequence.fa.gz.fai")

        let viewerPayload = viewerBundle.appendingPathComponent("genome/sequence.fa.gz")
        let viewerIndex = viewerBundle.appendingPathComponent("genome/sequence.fa.gz.fai")
        let viewerAppleDouble = viewerBundle.appendingPathComponent("genome/._sequence.fa.gz")
        for item in [viewerPayload, viewerIndex, viewerAppleDouble] {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, "Expected regular file at \(item.path)")
            XCTAssertEqual(values.isSymbolicLink, false, "Expected non-symlink at \(item.path)")
        }
        XCTAssertEqual(try String(contentsOf: viewerPayload, encoding: .utf8), "ACGT")
        XCTAssertEqual(try String(contentsOf: viewerIndex, encoding: .utf8), "chr1\t4\n")
    }

    func testPrepareBaseBundleMaterializesManifestPayloadWithoutCopyingAlignments() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingViewerBundlePreparerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = tempDir.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let genomeDir = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = sourceBundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        try "ACGT".write(to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8)
        try "chr1\t4\n".write(to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"), atomically: true, encoding: .utf8)
        let indexesDir = sourceBundle.appendingPathComponent("indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexesDir, withIntermediateDirectories: true)
        try "gzip-index".write(to: indexesDir.appendingPathComponent("sequence.gzi"), atomically: true, encoding: .utf8)
        try "old".write(to: alignmentsDir.appendingPathComponent("old.bam"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            name: "Reference",
            identifier: "test.reference",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "indexes/sequence.gzi",
                totalLength: 4,
                chromosomes: []
            ),
            alignments: [
                AlignmentTrackInfo(id: "old", name: "Old", sourcePath: "alignments/old.bam", indexPath: "alignments/old.bam.bai")
            ]
        )
        try manifest.save(to: sourceBundle)

        let viewerBundle = tempDir.appendingPathComponent("Analysis/Reference.lungfishref", isDirectory: true)

        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle
        )

        let viewerGenomePath = viewerBundle.appendingPathComponent("genome").path
        let viewerGenomeAttributes = try FileManager.default.attributesOfItem(atPath: viewerGenomePath)
        XCTAssertEqual(viewerGenomeAttributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerBundle.appendingPathComponent("alignments/old.bam").path))

        let viewerManifest = try BundleManifest.load(from: viewerBundle)
        XCTAssertEqual(viewerManifest.alignments, [])
        XCTAssertNotNil(viewerManifest.originBundlePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewerBundle.appendingPathComponent("genome/sequence.fa.gz").path))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: viewerBundle.appendingPathComponent("indexes").path
            )[.type] as? FileAttributeType,
            .typeDirectory
        )
        XCTAssertEqual(
            try String(
                contentsOf: viewerBundle.appendingPathComponent("indexes/sequence.gzi"),
                encoding: .utf8
            ),
            "gzip-index"
        )
        XCTAssertEqual(
            try String(
                contentsOf: viewerBundle.appendingPathComponent("genome/sequence.fa.gz"),
                encoding: .utf8
            ),
            "ACGT"
        )
        let viewerPayload = viewerBundle.appendingPathComponent("genome/sequence.fa.gz")
        let handle = try FileHandle(forWritingTo: viewerPayload)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("VIEW".utf8))
        try handle.synchronize()
        XCTAssertEqual(
            try String(
                contentsOf: sourceBundle.appendingPathComponent("genome/sequence.fa.gz"),
                encoding: .utf8
            ),
            "ACGT",
            "Materialized viewer payload must not share writes with the source bundle."
        )
    }
}

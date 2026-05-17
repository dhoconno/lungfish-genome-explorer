import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class ReferenceBundleMergeServiceTests: XCTestCase {
    private enum FixtureError: Error {
        case provenanceWriteFailed
    }

    func testMergeCreatesSequenceOnlyReferenceBundle() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged Reference"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.name, "Merged Reference")
        XCTAssertEqual(manifest.annotations.count, 0)
        XCTAssertEqual(manifest.variants.count, 0)
        XCTAssertEqual(manifest.tracks.count, 0)
        XCTAssertNotNil(manifest.genome)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        XCTAssertEqual(provenance.workflowName, "lungfish reference merge")
        XCTAssertEqual(provenance.toolName, "lungfish-app")
        XCTAssertFalse(provenance.toolVersion.isEmpty)
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertNotNil(provenance.wallTimeSeconds)
        XCTAssertEqual(provenance.options.explicit["bundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["requestedBundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["resolvedBundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["outputBundle"]?.fileValue?.path, mergedURL.path)

        let genome = try XCTUnwrap(manifest.genome)
        let expectedGenomePath = mergedURL.appendingPathComponent(genome.path).path
        let outputPaths = provenance.outputs.map(\.path)
        XCTAssertTrue(outputPaths.contains(mergedURL.appendingPathComponent(BundleManifest.filename).path))
        XCTAssertTrue(outputPaths.contains(expectedGenomePath))
        XCTAssertTrue(provenance.outputs.allSatisfy { $0.path.hasPrefix(mergedURL.path) })
        for record in provenance.files {
            XCTAssertNotNil(record.checksumSHA256, "Missing checksum for \(record.path)")
            XCTAssertNotNil(record.fileSize, "Missing file size for \(record.path)")
        }
        XCTAssertTrue(
            provenance.steps.contains { $0.toolName == "NativeBundleBuilder.build" },
            "Reference merge provenance must preserve the nested builder step"
        )
        let builderStep = try XCTUnwrap(
            provenance.steps.first { $0.toolName == "NativeBundleBuilder.build" }
        )
        let builderReplayArgv = try XCTUnwrap(builderStep.durableReplayArgv)
        XCTAssertTrue(builderReplayArgv.contains("--identifier"))
        XCTAssertTrue(builderReplayArgv.contains("--output-directory"))
        let fastaFlagIndex = try XCTUnwrap(builderReplayArgv.firstIndex(of: "--fasta"))
        let replayFASTAPath = builderReplayArgv[builderReplayArgv.index(after: fastaFlagIndex)]
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayFASTAPath))
        XCTAssertFalse(replayFASTAPath.contains("reference-merge-"))
        XCTAssertFalse(replayFASTAPath.contains("ref-import-"))

        let sourceFASTAPaths = try [
            XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: bundleA)).path,
            XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: bundleB)).path,
        ]
        let builderInputPaths = Set(builderStep.inputs.map(\.path))
        for sourceFASTAPath in sourceFASTAPaths {
            XCTAssertTrue(builderInputPaths.contains(sourceFASTAPath))
        }
        XCTAssertNotEqual(builderStep.argv, builderReplayArgv)
        XCTAssertTrue(builderStep.argv.joined(separator: "\n").contains("reference-merge-"))
        XCTAssertTrue(
            provenance.steps.contains { $0.toolName == "lungfish reference merge" },
            "Reference merge provenance must include the wrapping merge workflow step"
        )

        var durableProvenanceLines = provenance.argv
        durableProvenanceLines.append(provenance.reproducibleCommand)
        durableProvenanceLines.append(contentsOf: provenance.files.map(\.path))
        for step in provenance.steps {
            durableProvenanceLines.append(contentsOf: step.durableReplayArgv ?? [])
            durableProvenanceLines.append(step.reproducibleCommand)
            durableProvenanceLines.append(contentsOf: step.inputs.map(\.path))
            durableProvenanceLines.append(contentsOf: step.outputs.map(\.path))
        }
        let durableProvenanceText = durableProvenanceLines.joined(separator: "\n")
        XCTAssertFalse(durableProvenanceText.contains("reference-merge-"))
        XCTAssertFalse(durableProvenanceText.contains("ref-import-"))
    }

    func testMergeProvenanceUsesResolvedReferenceNameWhenOutputNameIsUniquified() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingBundle = projectURL.appendingPathComponent("Merged_Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: existingBundle, withIntermediateDirectories: true)

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged Reference"
        )
        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.name, "Merged Reference 2")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        XCTAssertEqual(provenance.options.explicit["requestedBundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["resolvedBundleName"]?.stringValue, "Merged Reference 2")
        XCTAssertEqual(provenance.options.explicit["bundleName"]?.stringValue, "Merged Reference 2")
        XCTAssertTrue(provenance.argv.contains("Merged Reference 2"))
        XCTAssertFalse(provenance.argv.contains("Merged Reference.lungfishref"))
    }

    func testMergeRejectsSourceBundleWithNonSequenceTracks() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        let sequenceOnlyBundle = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let annotatedBundle = try makeAnnotatedReferenceBundle(in: projectURL)

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [sequenceOnlyBundle, annotatedBundle],
                outputDirectory: projectURL,
                bundleName: "Should Not Merge"
            )
            XCTFail("Expected annotated reference bundles to be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("contains annotations, variants, tracks, or alignments")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Should Not Merge.lungfishref").path
            )
        )
    }

    func testMergeRemovesPartialReferenceBundleWhenProvenanceWriteFails() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )
        let expectedOutput = projectURL.appendingPathComponent("Failed_Reference.lungfishref", isDirectory: true)

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [bundleA, bundleB],
                outputDirectory: projectURL,
                bundleName: "Failed Reference",
                provenanceWriter: BundleMergeProvenanceSidecarWriter { _, _ in
                    throw FixtureError.provenanceWriteFailed
                }
            )
            XCTFail("Expected merge to fail when provenance cannot be written")
        } catch FixtureError.provenanceWriteFailed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOutput.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeAnnotatedReferenceBundle(in projectURL: URL) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("Annotated.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDirectory = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)

        try ">chrB\nCCCC\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "placeholder\n".write(
            to: annotationsDirectory.appendingPathComponent("genes.bb"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: "Annotated",
            identifier: "org.lungfish.test.annotated",
            source: SourceInfo(organism: "Annotated", assembly: "Annotated"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chrB",
                        length: 4,
                        offset: 0,
                        lineBases: 4,
                        lineWidth: 5
                    )
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/genes.bb"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}

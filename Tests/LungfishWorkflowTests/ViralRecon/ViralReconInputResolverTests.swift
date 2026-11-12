import XCTest
@testable import LungfishWorkflow

final class ViralReconInputResolverTests: XCTestCase {
    func testResolverRejectsMixedIlluminaAndNanoporeSelections() throws {
        let illumina = ViralReconResolvedInput(
            bundleURL: URL(fileURLWithPath: "/tmp/I.lungfishfastq"),
            sampleName: "I",
            fastqURLs: [URL(fileURLWithPath: "/tmp/I_R1.fastq.gz")],
            platform: .illumina,
            barcode: nil,
            sequencingSummaryURL: nil
        )
        let nanopore = ViralReconResolvedInput(
            bundleURL: URL(fileURLWithPath: "/tmp/N.lungfishfastq"),
            sampleName: "N",
            fastqURLs: [URL(fileURLWithPath: "/tmp/N.fastq")],
            platform: .nanopore,
            barcode: "01",
            sequencingSummaryURL: nil
        )

        XCTAssertThrowsError(try ViralReconInputResolver.makeSamples(from: [illumina, nanopore])) { error in
            XCTAssertEqual(error as? ViralReconInputResolver.ResolveError, .mixedPlatforms)
        }
    }

    // Trust session FIX-VR (F1, S2). The wizard, `workflow run` with bundle
    // inputs and the app's Run all make their samples here, so a sample name
    // viralrecon refuses is refused here, before any read is split or staged.
    func testMakeSamplesRefusesASampleNameWithASpaceBeforeAnythingIsStaged() throws {
        let inputs = ["Sample_2", "Sample 1"].map { name in
            ViralReconResolvedInput(
                bundleURL: URL(fileURLWithPath: "/tmp/\(name).lungfishfastq"),
                sampleName: name,
                fastqURLs: [URL(fileURLWithPath: "/tmp/\(name).lungfishfastq")],
                platform: .illumina,
                barcode: nil,
                sequencingSummaryURL: nil
            )
        }

        XCTAssertThrowsError(try ViralReconInputResolver.makeSamples(from: inputs)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The sample name “Sample 1” holds a space, and viralrecon's samplesheet does not accept one. "
                    + "Rename the sample, for example to “Sample_1”, and run again."
            )
        }
    }

    func testResolverPrefersPersistedSequencingPlatformOverFastqHeader() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = try ViralReconWorkflowTestFixtures.writeFastqBundle(
            named: "PersistedONT",
            in: temp,
            fastqText: "@INST:1:FC:1:1101:1000:1000\nACGT\n+\n!!!!\n",
            metadataCSV: nil,
            sidecarJSON: #"{"sequencingPlatform":"oxfordNanopore"}"#
        )

        let resolved = try ViralReconInputResolver.resolveInputs(from: [bundle])

        XCTAssertEqual(resolved.first?.platform, .nanopore)
    }

    func testResolverUsesPersistedAssemblyReadTypeWhenPlatformIsMissing() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = try ViralReconWorkflowTestFixtures.writeFastqBundle(
            named: "AssemblyONT",
            in: temp,
            fastqText: "@INST:1:FC:1:1101:1000:1000\nACGT\n+\n!!!!\n",
            metadataCSV: nil,
            sidecarJSON: #"{"assemblyReadType":"ontReads"}"#
        )

        let resolved = try ViralReconInputResolver.resolveInputs(from: [bundle])

        XCTAssertEqual(resolved.first?.platform, .nanopore)
    }

    func testResolverPrefersSampleMetadataSampleNameBeforeBundleFilename() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = try ViralReconWorkflowTestFixtures.writeFastqBundle(
            named: "FilenameFallback",
            in: temp,
            fastqText: "@INST:1:FC:1:1101:1000:1000\nACGT\n+\n!!!!\n",
            metadataCSV: """
            sample_id,sample_name,sequencing_platform
            display-id,Clinical_Sample_42,illumina
            """,
            sidecarJSON: nil
        )

        let resolved = try ViralReconInputResolver.resolveInputs(from: [bundle])

        XCTAssertEqual(resolved.first?.sampleName, "Clinical_Sample_42")
    }
}

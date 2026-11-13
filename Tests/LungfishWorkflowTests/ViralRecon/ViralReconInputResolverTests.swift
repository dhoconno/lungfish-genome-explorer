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

    // Trust session VR-SAME-NAME (BIO-PROBES-F Q1, S1). viralrecon joins the
    // rows of one sample name into one sample, so two inputs that go by one
    // name were run as one sample, with no words. Two demultiplex runs each
    // give a `barcode01.lungfishfastq`, so both reach the resolver. It
    // refuses, never renames, and names both inputs the way a person tells
    // them apart (the shortest trailing path that differs).
    func testResolveInputsRefusesTwoBundlesOfOneNameInTwoRunFolders() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundles = try ["Run A", "Run B"].map { runFolder -> URL in
            let folder = temp.appendingPathComponent(runFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try ViralReconWorkflowTestFixtures.writeFastqBundle(
                named: "barcode01",
                in: folder,
                fastqText: "@INST:1:FC:1:1101:1000:1000\nACGT\n+\n!!!!\n",
                metadataCSV: nil,
                sidecarJSON: #"{"sequencingPlatform":"illumina"}"#
            )
        }

        XCTAssertThrowsError(try ViralReconInputResolver.resolveInputs(from: bundles)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The inputs “Run A/barcode01.lungfishfastq” and “Run B/barcode01.lungfishfastq” both have the "
                    + "sample name “barcode01”, and viralrecon would join their reads into one sample. "
                    + "Rename the sample of one of them in its metadata, and run again."
            )
        }
    }

    // Two names that differ only in letter case are one folder on a disk
    // that ignores case, where viralrecon's result files would replace each
    // other, so they are refused too, and the words show both names.
    func testMakeSamplesRefusesSampleNamesThatDifferOnlyInLetterCase() throws {
        let inputs = [("A", "Sample_1"), ("B", "sample_1")].map { folder, name in
            sharedNameInput(named: name, in: folder)
        }

        XCTAssertThrowsError(try ViralReconInputResolver.makeSamples(from: inputs)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The inputs “A/Sample_1.lungfishfastq” and “B/sample_1.lungfishfastq” have the sample names "
                    + "“Sample_1” and “sample_1”, which differ only in letter case, and viralrecon's result files "
                    + "for the two would replace each other on a disk that ignores case. "
                    + "Rename the sample of one of them in its metadata, and run again."
            )
        }
    }

    // The same name is refused wherever the two inputs sit in the list, and
    // names that differ in more than case stay samples of their own.
    func testMakeSamplesRefusesALaterInputWhoseNameRepeatsAnEarlierOne() throws {
        let inputs = [("A", "NTC"), ("B", "PC"), ("C", "ntc")].map { folder, name in
            sharedNameInput(named: name, in: folder)
        }

        XCTAssertThrowsError(try ViralReconInputResolver.makeSamples(from: inputs)) { error in
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("“A/NTC.lungfishfastq” and “C/ntc.lungfishfastq”"), words)
            XCTAssertFalse(words.contains("PC.lungfishfastq"), words)
        }

        let distinct = try ViralReconInputResolver.makeSamples(
            from: [("A", "NTC"), ("B", "PC"), ("C", "NTC2")].map { sharedNameInput(named: $1, in: $0) }
        )
        XCTAssertEqual(distinct.map(\.sampleName), ["NTC", "PC", "NTC2"])
    }

    private func sharedNameInput(named name: String, in folder: String) -> ViralReconResolvedInput {
        ViralReconResolvedInput(
            bundleURL: URL(fileURLWithPath: "/tmp/\(folder)/\(name).lungfishfastq"),
            sampleName: name,
            fastqURLs: [URL(fileURLWithPath: "/tmp/\(folder)/\(name).lungfishfastq")],
            platform: .illumina,
            barcode: nil,
            sequencingSummaryURL: nil
        )
    }
}

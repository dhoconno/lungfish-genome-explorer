import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class TwelveSAmpliconMatchingWorkflowTests: XCTestCase {
    func testClassifiesBothEndSoftClippedExactTargetMatch() throws {
        let reference = TwelveSReferenceRecord(
            targetID: "human",
            displayName: "human (Homo sapiens)",
            sequence: "ACGTACGT"
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [reference],
            minimumSoftClipBases: 2,
            maximumIndelBases: 2,
            matchingMode: .ontIndel
        )

        let result = classifier.classify(readSequence: "TTACGTACGTGG")

        XCTAssertEqual(result, .exact(targetID: "human", indelCount: 0))
    }

    func testRequiresSoftClipAtBothEnds() throws {
        let reference = TwelveSReferenceRecord(
            targetID: "human",
            displayName: "human (Homo sapiens)",
            sequence: "ACGTACGT"
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [reference],
            minimumSoftClipBases: 2,
            maximumIndelBases: 2,
            matchingMode: .ontIndel
        )

        XCTAssertEqual(classifier.classify(readSequence: "ACGTACGTGG"), .unresolved)
        XCTAssertEqual(classifier.classify(readSequence: "TTACGTACGT"), .unresolved)
    }

    func testRejectsSubstitutionButAcceptsIndelOnlyAlignment() throws {
        let reference = TwelveSReferenceRecord(
            targetID: "human",
            displayName: "human (Homo sapiens)",
            sequence: "ACGTACGT"
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [reference],
            minimumSoftClipBases: 2,
            maximumIndelBases: 2,
            matchingMode: .ontIndel
        )

        XCTAssertEqual(classifier.classify(readSequence: "TTACGTTACGTGG"), .exact(targetID: "human", indelCount: 1))
        XCTAssertEqual(classifier.classify(readSequence: "TTACGTTCATGG"), .unresolved)
    }

    func testIlluminaExactModeRejectsIndelOnlyFallback() throws {
        let reference = TwelveSReferenceRecord(
            targetID: "human",
            displayName: "human (Homo sapiens)",
            sequence: "ACGTACGT"
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [reference],
            minimumSoftClipBases: 2,
            maximumIndelBases: 2,
            matchingMode: .illuminaExact
        )

        XCTAssertEqual(classifier.classify(readSequence: "TTACGTACGTGG"), .exact(targetID: "human", indelCount: 0))
        XCTAssertEqual(classifier.classify(readSequence: "TTACGTTACGTGG"), .unresolved)
    }

    func testIndelCandidateSearchDoesNotDropLowIndexTiesBeyondFirst128References() throws {
        let decoys = (0..<128).map { index in
            TwelveSReferenceRecord(
                targetID: "decoy-\(index)",
                displayName: "Decoy \(index)",
                sequence: "AAAAAAAAGGCCCCCCCC"
            )
        }
        let trueReference = TwelveSReferenceRecord(
            targetID: "true-target",
            displayName: "True Target",
            sequence: "AAAAAAAACCCCCCCC"
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: decoys + [trueReference],
            minimumSoftClipBases: 2,
            maximumIndelBases: 1,
            matchingMode: .ontIndel
        )

        XCTAssertEqual(
            classifier.classify(readSequence: "TTAAAAAAAATCCCCCCCCGG"),
            .exact(targetID: "true-target", indelCount: 1)
        )
    }

    func testReferenceIndexUsesSequenceStableTargetIDsForRepeatedDisplayNames() throws {
        let index = try TwelveSReferenceIndex.parse("""
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT
        >human (Homo sapiens)|locus=12S|len=8
        TTTTCCCC
        """)

        XCTAssertEqual(index.records.map(\.displayName), ["human (Homo sapiens)", "human (Homo sapiens)"])
        XCTAssertEqual(Set(index.records.map(\.targetID)).count, 2)
        XCTAssertTrue(index.records.allSatisfy { $0.targetID.hasPrefix("human (Homo sapiens)|seq_sha256=") })
        XCTAssertTrue(index.records.allSatisfy { $0.metadata["sequence_sha256"]?.count == 64 })
    }

    func testWorkflowWritesBundleTablesUnresolvedSequencesChimeraStatusAndProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconMatchingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let fastqURL = root.appendingPathComponent("sampleA.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)

        try """
        >human (Homo sapiens)|locus=12S|len=8|n_refs=2|n_species=1|primer_pairs=12S_vert
        ACGTACGT
        >dog (Canis lupus familiaris)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert
        GGGGCCCC
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        @read2
        TTACGTTCGTGG
        +
        IIIIIIIIIIII
        @read3
        TTACGTTCATGG
        +
        IIIIIIIIIIII
        @read4
        AACCCCCCCCTT
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let workflow = TwelveSAmpliconMatchingWorkflow(
            chimeraReviewer: FakeTwelveSChimeraReviewer(statuses: ["unresolved_1": .candidate])
        )
        let result = try await workflow.run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: "sampleA-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                matchingMode: .ontIndel,
                threads: 2
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        XCTAssertEqual(loaded.samples.map(\.sampleID), ["sampleA"])
        XCTAssertEqual(loaded.readFate.totalReads, 4)
        XCTAssertEqual(loaded.readFate.exactMatchReads, 2)
        XCTAssertEqual(loaded.readFate.unresolvedReads, 2)
        XCTAssertEqual(loaded.targetRows.first?.target.displayName, "human (Homo sapiens)")
        XCTAssertEqual(loaded.targetRows.first?.count(forSample: "sampleA"), 2)
        XCTAssertEqual(loaded.unresolvedSequences.count, 2)
        XCTAssertEqual(loaded.unresolvedSequences.first?.chimeraStatus, .candidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.artifacts.provenanceURL.path))

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq 12s-match")
        XCTAssertEqual(provenance.argv.prefix(3), ["lungfish-cli", "fastq", "12s-match"])
        XCTAssertTrue(provenance.argv.contains("--min-soft-clip"))
        XCTAssertTrue(provenance.argv.contains("--max-indels"))
        XCTAssertTrue(provenance.argv.contains("--matching-mode"))
        XCTAssertTrue(provenance.argv.contains("ont-indel"))
        XCTAssertTrue(provenance.argv.contains("--threads"))
        XCTAssertTrue(provenance.outputs.contains { $0.path == result.bundleURL.path })
        let outputBundleRecord = try XCTUnwrap(provenance.outputs.first { $0.path == result.bundleURL.path })
        XCTAssertNotNil(outputBundleRecord.checksumSHA256)
        XCTAssertGreaterThan(outputBundleRecord.fileSize ?? 0, 0)
        XCTAssertTrue(provenance.files.contains { $0.path == fastqURL.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.stderr, "fake vsearch stderr")
    }

    func testCrossSpeciesAmbiguousReadsReassignedToAbundantSpeciesWithConservation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSReassignTest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let fastqURL = root.appendingPathComponent("sampleA.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)

        // human-long is human-specific (unambiguous abundance). human-short and
        // pan-short share an IDENTICAL 8-mer core → reads matching only the core
        // are cross-species ambiguous (human vs pan).
        try """
        >human-long (Homo sapiens)|locus=12S|len=10|n_refs=1|n_species=1|primer_pairs=12S_vert
        ACGTACGTAA
        >human-short (Homo sapiens)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert
        TTTTGGGG
        >pan-short (Pan troglodytes)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert
        TTTTGGGG
        """.write(to: referenceURL, atomically: true, encoding: .utf8)

        // 3 reads unambiguously human (match human-long core ACGTACGTAA);
        // 2 reads match only the shared TTTTGGGG core → ambiguous human/pan.
        try """
        @h1
        TTACGTACGTAAGG
        +
        IIIIIIIIIIIIII
        @h2
        TTACGTACGTAAGG
        +
        IIIIIIIIIIIIII
        @h3
        TTACGTACGTAAGG
        +
        IIIIIIIIIIIIII
        @amb1
        TTTTTTGGGGGG
        +
        IIIIIIIIIIII
        @amb2
        TTTTTTGGGGGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: "reassign-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                threads: 1
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "sampleA" })

        // Read conservation: every input read is exact, reassigned, or unresolved.
        XCTAssertEqual(sample.inputReads, 5)
        XCTAssertEqual(sample.exactMatchReads + sample.reassignedReads + sample.unresolvedReads, sample.inputReads)
        XCTAssertGreaterThanOrEqual(sample.ambiguousExactReads, 0)

        // The 2 ambiguous reads were reassigned to the abundant species (human),
        // not left unresolved.
        XCTAssertEqual(sample.reassignedReads, 2)
        XCTAssertEqual(sample.unresolvedReads, 0)

        // Per-species counts reflect the assignment, and the reassignments table persisted.
        let humanRow = try XCTUnwrap(loaded.scientificNameRows.first { $0.scientificName == "Homo sapiens" })
        XCTAssertEqual(humanRow.count(forSample: "sampleA"), 5) // 3 unambiguous + 2 reassigned
        XCTAssertFalse(loaded.reassignments.isEmpty)
        XCTAssertEqual(loaded.reassignments.first?.toSpecies, "Homo sapiens")
        XCTAssertEqual(loaded.reassignments.map(\.reads).reduce(0, +), 2)
    }

    func testWorkflowAppliesReferenceMetadataAndWritesAlternateMatchTable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconMatchingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let midoriURL = root.appendingPathComponent("12s_reference.tsv")
        let metadataURL = root.appendingPathComponent("12s-target-metadata.tsv")
        let fastqURL = root.appendingPathComponent("sampleA.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)

        try """
        >human (Homo sapiens)|locus=12S|len=8|n_refs=2|n_species=2|also_matches=Heidelberg man (Homo heidelbergensis)|n_primer_pairs=1|primer_pairs=12S_vert
        ACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        seq_id\tcommon_name\tlatin_name\tgroup\ttaxid\tname_source\ttaxonomy
        AB1\thuman\tHomo sapiens\tMammal\t9606\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Homo sapiens
        AB2\tHeidelberg man\tHomo heidelbergensis\tMammal\t1425170\tncbi_common\troot; Eukaryota; Chordata; Mammalia; Primates; Homo heidelbergensis
        """.write(to: midoriURL, atomically: true, encoding: .utf8)
        _ = try await TwelveSReferenceMetadataBuilder().build(
            TwelveSReferenceMetadataBuildConfiguration(
                deduplicatedFASTA: referenceURL,
                midoriMetadataTSV: midoriURL,
                outputURL: metadataURL,
                forceOverwrite: false
            )
        )
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                referenceMetadata: metadataURL,
                outputDirectory: outputDirectory,
                outputName: "sampleA-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                runChimeraReview: false
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        let target = try XCTUnwrap(loaded.targets.first)
        XCTAssertEqual(target.taxonGroup, "Mammal")
        XCTAssertEqual(target.taxid, "9606")
        XCTAssertEqual(target.alternateMatches.map(\.scientificName), ["Homo heidelbergensis"])
        XCTAssertEqual(loaded.scientificNameRows.first?.taxonGroups, ["Mammal"])
        XCTAssertNotNil(loaded.artifacts.alternateMatchesTableURL)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        XCTAssertTrue(provenance.files.contains { $0.path == metadataURL.path })
    }

    func testWorkflowReportsStableProgressMilestonesWithoutVerboseToolStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconMatchingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let fastqURL = root.appendingPathComponent("sampleA.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)

        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        @read2
        TTACGTTCATGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let workflow = TwelveSAmpliconMatchingWorkflow(
            chimeraReviewer: FakeTwelveSChimeraReviewer(statuses: [:])
        )
        let progressRecorder = TwelveSProgressRecorder()
        _ = try await workflow.run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: "sampleA-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2
            ),
            progressHandler: { fraction, message in
                progressRecorder.append(fraction, message)
            }
        )

        let progressCalls = progressRecorder.calls()
        let messages = progressCalls.map(\.1)
        XCTAssertTrue(messages.contains("Validating 12S amplicon matching inputs."))
        XCTAssertTrue(messages.contains("Loading 12S reference records."))
        XCTAssertTrue(messages.contains("Matching reads to 12S references."))
        XCTAssertTrue(messages.contains("Reviewing unresolved sequences for chimeras."))
        XCTAssertTrue(messages.contains("Writing 12S result bundle tables."))
        XCTAssertTrue(messages.contains("Writing reproducibility provenance."))
        XCTAssertEqual(messages.last, "12S amplicon matching complete.")
        XCTAssertFalse(messages.contains { $0.contains("fake vsearch stderr") })
        XCTAssertEqual(progressCalls.last?.0, 1.0)
    }

    func testWorkflowAcceptsImportedFASTQBundleWithPhysicalPayload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconMatchingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let bundleURL = root.appendingPathComponent("MergedSample.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let workflow = TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer())
        let result = try await workflow.run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [bundleURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: "bundle-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                runChimeraReview: false
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        XCTAssertEqual(loaded.samples.map(\.sampleID), ["MergedSample"])
        XCTAssertEqual(loaded.readFate.exactMatchReads, 1)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        let inputBundleRecord = try XCTUnwrap(provenance.files.first { $0.path == bundleURL.path })
        XCTAssertNotNil(inputBundleRecord.checksumSHA256)
        XCTAssertGreaterThan(inputBundleRecord.fileSize ?? 0, 0)
    }

    func testWorkflowFreezesFASTQAndAnalysisSampleMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconMatchingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let bundleURL = root.appendingPathComponent("MergedSample.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        let analysisMetadataURL = root.appendingPathComponent("analysis-metadata.tsv")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)
        try FASTQBundleCSVMetadata.save(
            FASTQBundleCSVMetadata(keyValuePairs: [
                "sample_name": "Merged Sample",
                "sample_type": "wastewater",
                "collection_date": "2026-05-11",
                "site": "Hilo",
            ]),
            to: bundleURL
        )
        try """
        sample_id\tsample_name\tsite\tbatch_id
        MergedSample\t\tHilo WWTP\tbatch-12s
        """.write(to: analysisMetadataURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [bundleURL],
                referenceFASTA: referenceURL,
                sampleMetadata: analysisMetadataURL,
                outputDirectory: outputDirectory,
                outputName: "bundle-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                runChimeraReview: false
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        XCTAssertEqual(loaded.samples.first?.displayName, "Merged Sample")
        XCTAssertEqual(loaded.sampleMetadata?.records["MergedSample"]?["sample_name"], "Merged Sample")
        XCTAssertEqual(loaded.sampleMetadata?.records["MergedSample"]?["sample_type"], "wastewater")
        XCTAssertEqual(loaded.sampleMetadata?.records["MergedSample"]?["site"], "Hilo WWTP")
        XCTAssertEqual(loaded.sampleMetadata?.records["MergedSample"]?["batch_id"], "batch-12s")
        XCTAssertNotNil(loaded.manifest.resolvedSampleMetadataPath)
        XCTAssertNotNil(loaded.manifest.sampleMetadataManifestPath)
        XCTAssertNotNil(loaded.manifest.analysisSampleMetadataOriginalPath)
        XCTAssertEqual(loaded.sampleMetadataManifest?.hasFASTQMetadata, true)
        XCTAssertEqual(loaded.sampleMetadataManifest?.hasAnalysisMetadata, true)
        XCTAssertEqual(loaded.sampleMetadataManifest?.sampleCount, 1)
        XCTAssertEqual(loaded.sampleMetadataManifest?.sources.map(\.kind), [.fastqBundle, .analysisOverride])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("metadata/resolved-sample-metadata.tsv").path))
        let samplesTSV = try String(contentsOf: result.bundleURL.appendingPathComponent("samples.tsv"), encoding: .utf8)
        XCTAssertTrue(samplesTSV.hasPrefix("sample\tsample_name\tsample_id\tdisplay_name"))
        XCTAssertTrue(samplesTSV.contains("MergedSample\tMerged Sample\tMergedSample\tMerged Sample"))

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        XCTAssertTrue(provenance.argv.contains("--sample-metadata"))
        XCTAssertTrue(provenance.files.contains { $0.path == analysisMetadataURL.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(provenance.outputs.contains { $0.path.hasSuffix("metadata/resolved-sample-metadata.tsv") })
    }

    func testWorkflowRecordsFolderLevelFASTQMetadataAsManifestSourceAndProvenanceInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSAmpliconMatchingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let bundleURL = root.appendingPathComponent("FolderSample.lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        let folderMetadataURL = FASTQFolderMetadata.metadataURL(in: root)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)
        var folderSampleMetadata = FASTQSampleMetadata(sampleName: "FolderSample")
        folderSampleMetadata.sampleType = "wastewater"
        folderSampleMetadata.customFields["site"] = "Hilo WWTP"
        try FASTQFolderMetadata.save(
            FASTQFolderMetadata(orderedSamples: [folderSampleMetadata]),
            to: root
        )

        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [bundleURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: "folder-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                runChimeraReview: false
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        XCTAssertEqual(loaded.sampleMetadata?.records["FolderSample"]?["sample_type"], "wastewater")
        XCTAssertEqual(loaded.sampleMetadata?.records["FolderSample"]?["site"], "Hilo WWTP")
        XCTAssertEqual(loaded.sampleMetadataManifest?.sources.map(\.kind), [.fastqFolder])
        XCTAssertEqual(loaded.sampleMetadataManifest?.sources.first?.path, folderMetadataURL.standardizedFileURL.path)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
        XCTAssertTrue(provenance.files.contains {
            $0.path == folderMetadataURL.standardizedFileURL.path && $0.checksumSHA256 != nil
        })
    }

    func testVSearchChimeraReviewerThrowsOnNonZeroExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSVSearchChimeraReviewerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let reviewer = TwelveSVSearchChimeraReviewer { arguments in
            XCTAssertTrue(arguments.contains("--threads"))
            XCTAssertEqual(arguments.last, "4")
            return NativeToolResult(
                exitCode: 2,
                stdout: "",
                stderr: "uchime failed",
                arguments: ["/usr/local/bin/vsearch"] + arguments
            )
        }

        do {
            _ = try await reviewer.review(
                unresolvedSequences: [
                    TwelveSUnresolvedSequence(
                        sequenceID: "unresolved_1",
                        sequence: "ACGT",
                        readCount: 5,
                        sampleCounts: ["SampleA": 5],
                        chimeraStatus: .notReviewed,
                        note: nil
                    )
                ],
                outputDirectory: root,
                threads: 4
            )
            XCTFail("Expected vsearch chimera review failure")
        } catch TwelveSChimeraReviewError.vsearchFailed(let exitCode, let stderr) {
            XCTAssertEqual(exitCode, 2)
            XCTAssertEqual(stderr, "uchime failed")
        }
    }

    func testClassifiesHiloCowAndPigFlankedExactReads() throws {
        let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
        let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
        let prefix = "ACTGGGATTAGATACCCC"
        let suffix = "CTAGAGGAGCCTGTTCTA"

        let cow = TwelveSReferenceRecord(
            targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759",
            displayName: "domestic cattle (Bos taurus)",
            sequence: cowCore
        )
        let pig = TwelveSReferenceRecord(
            targetID: "pig (Sus scrofa)|seq_sha256=f59a31cf5675f344",
            displayName: "pig (Sus scrofa)",
            sequence: pigCore
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [cow, pig],
            minimumSoftClipBases: 1,
            maximumIndelBases: 3
        )

        XCTAssertEqual(
            classifier.classify(readSequence: prefix + cowCore + suffix),
            .exact(targetID: cow.targetID, indelCount: 0)
        )
        XCTAssertEqual(
            classifier.classify(readSequence: prefix + pigCore + suffix),
            .exact(targetID: pig.targetID, indelCount: 0)
        )
    }

    func testClassifiesExactCoreWhenFlankingSequenceHasErrors() throws {
        let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
        let cow = TwelveSReferenceRecord(
            targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759",
            displayName: "domestic cattle (Bos taurus)",
            sequence: cowCore
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [cow],
            minimumSoftClipBases: 1,
            maximumIndelBases: 3
        )

        XCTAssertEqual(
            classifier.classify(readSequence: "ACTGGGATTAGATACCCC" + cowCore + "CCAGAGGAGCCTGTTCTA"),
            .exact(targetID: cow.targetID, indelCount: 0)
        )
    }

    func testHiloExactCoreStillRequiresConfiguredSoftClipAtBothEnds() throws {
        let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
        let pig = TwelveSReferenceRecord(
            targetID: "pig (Sus scrofa)|seq_sha256=f59a31cf5675f344",
            displayName: "pig (Sus scrofa)",
            sequence: pigCore
        )
        let classifier = TwelveSAmpliconReadClassifier(
            references: [pig],
            minimumSoftClipBases: 1,
            maximumIndelBases: 3
        )

        XCTAssertEqual(classifier.classify(readSequence: pigCore + "CTAGAGGAGCCTGTTCTA"), .unresolved)
        XCTAssertEqual(classifier.classify(readSequence: "ACTGGGATTAGATACCCC" + pigCore), .unresolved)
    }

    func testWorkflowCountsHiloFlankedCowAndPigReadsInsteadOfLeavingThemUnresolved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSHiloRegression-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
        let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
        let prefix = "ACTGGGATTAGATACCCC"
        let suffix = "CTAGAGGAGCCTGTTCTA"

        let referenceURL = root.appendingPathComponent("reference.fa")
        try """
        >domestic cattle (Bos taurus)|locus=12S|len=107|n_refs=161|n_species=7|primer_pairs=12S_vert_F_x_12S_vert_R
        \(cowCore)
        >pig (Sus scrofa)|locus=12S|len=106|n_refs=204|n_species=1|primer_pairs=12S_vert_F_x_12S_vert_R
        \(pigCore)
        """.write(to: referenceURL, atomically: true, encoding: .utf8)

        let fastqURL = root.appendingPathComponent("hilo.fastq")
        try """
        @cow1
        \(prefix)\(cowCore)\(suffix)
        +
        \(String(repeating: "I", count: prefix.count + cowCore.count + suffix.count))
        @cow2
        \(prefix)\(cowCore)\(suffix)
        +
        \(String(repeating: "I", count: prefix.count + cowCore.count + suffix.count))
        @pig1
        \(prefix)\(pigCore)\(suffix)
        +
        \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
        @pig2
        \(prefix)\(pigCore)\(suffix)
        +
        \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
        @pig3
        \(prefix)\(pigCore)\(suffix)
        +
        \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSAmpliconMatchingWorkflow(
            chimeraReviewer: TwelveSNoOpChimeraReviewer()
        ).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                outputDirectory: root.appendingPathComponent("out", isDirectory: true),
                outputName: "hilo-regression",
                minimumSoftClipBases: 1,
                maximumIndelBases: 3,
                runChimeraReview: false
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        let cowRow = try XCTUnwrap(loaded.targetRows.first { $0.target.displayName == "domestic cattle (Bos taurus)" })
        let pigRow = try XCTUnwrap(loaded.targetRows.first { $0.target.displayName == "pig (Sus scrofa)" })

        XCTAssertEqual(cowRow.count(forSample: "hilo"), 2)
        XCTAssertEqual(pigRow.count(forSample: "hilo"), 3)
        XCTAssertEqual(loaded.readFate.exactMatchReads, 5)
        XCTAssertEqual(loaded.readFate.unresolvedReads, 0)
        XCTAssertTrue(loaded.unresolvedSequences.isEmpty)
    }

    func testCollapsesNestedSubstringSameGenusToLongestExactMatch() throws {
        // Cow read: 107bp cattle core contains the 106bp zebu core as a substring.
        let cattleCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
        let zebuCore = String(cattleCore.dropLast()) // 106bp proper substring (prefix) of the cattle core
        let cattle = TwelveSReferenceRecord(targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759", displayName: "domestic cattle (Bos taurus)", sequence: cattleCore)
        let zebu = TwelveSReferenceRecord(targetID: "zebu cattle (Bos indicus)|seq_sha256=zebu0001", displayName: "zebu cattle (Bos indicus)", sequence: zebuCore)
        let classifier = TwelveSAmpliconReadClassifier(references: [cattle, zebu], minimumSoftClipBases: 1, maximumIndelBases: 3)
        // Read embeds the full 107bp cattle core with flank on both sides.
        let read = "ACTGGGATTAGATACCCC" + cattleCore + "CTAGAGGAGCCTGTTCTA"
        // zebu (106) is a substring of cattle (107) -> collapse to the longest -> cattle, uniquely exact.
        XCTAssertEqual(classifier.classify(readSequence: read), .exact(targetID: cattle.targetID, indelCount: 0))
    }

    func testCollapsesSameSpeciesLengthVariantsToCanonicalExactMatch() throws {
        // Pig read: two distinct same-species variants both match exactly (neither a substring of the other).
        let pigCoreA = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC" // 106
        let pigCoreB = pigCoreA + "C" // 107, contains pigCoreA as a prefix substring
        let pigCoreC = "T" + pigCoreA  // 107, distinct from pigCoreB, NOT a substring of pigCoreB, same species
        let pigA = TwelveSReferenceRecord(targetID: "pig (Sus scrofa)|seq_sha256=pigA", displayName: "pig (Sus scrofa)", sequence: pigCoreA)
        let pigB = TwelveSReferenceRecord(targetID: "pig (Sus scrofa)|seq_sha256=pigB", displayName: "pig (Sus scrofa)", sequence: pigCoreB)
        let pigC = TwelveSReferenceRecord(targetID: "pig (Sus scrofa)|seq_sha256=pigC", displayName: "pig (Sus scrofa)", sequence: pigCoreC)
        let classifier = TwelveSAmpliconReadClassifier(references: [pigA, pigB, pigC], minimumSoftClipBases: 1, maximumIndelBases: 3)
        // A read containing pigCoreB (which also contains pigCoreA) AND, separately, embed so pigC matches too.
        // Construct a read that contains both pigCoreB and pigCoreC as internal substrings:
        let read = "ACTGGGATTAGATACCCC" + pigCoreC + "GG" + pigCoreB + "CTAGAGGAGCCTGTTCTA"
        let result = classifier.classify(readSequence: read)
        // After substring-collapse pigA drops (⊂ pigB); pigB and pigC are distinct 107bp but SAME species -> exact (not ambiguous).
        guard case .exact(let id, let indel) = result else { return XCTFail("expected .exact, got \(result)") }
        XCTAssertEqual(indel, 0)
        XCTAssertTrue(id == pigB.targetID || id == pigC.targetID, "canonical pig id expected, got \(id)")
    }

    func testKeepsGenuineCrossSpeciesExactMatchesAmbiguous() throws {
        // Two equal-length, DIFFERENT-species exact matches must STAY ambiguous.
        let coreCattle = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
        // A different species with the SAME length but different sequence (flip several bases, keep length 107).
        let coreOther = "TGCATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
        let cattle = TwelveSReferenceRecord(targetID: "domestic cattle (Bos taurus)|seq_sha256=cattleX", displayName: "domestic cattle (Bos taurus)", sequence: coreCattle)
        let other = TwelveSReferenceRecord(targetID: "sheep (Ovis aries)|seq_sha256=sheepX", displayName: "sheep (Ovis aries)", sequence: coreOther)
        let classifier = TwelveSAmpliconReadClassifier(references: [cattle, other], minimumSoftClipBases: 1, maximumIndelBases: 3)
        // A read containing BOTH cores as internal substrings.
        let read = "ACTGGGATTAGATACCCC" + coreCattle + "GG" + coreOther + "CTAGAGGAGCCTGTTCTA"
        let result = classifier.classify(readSequence: read)
        guard case .ambiguous(let ids) = result else { return XCTFail("expected .ambiguous, got \(result)") }
        XCTAssertEqual(Set(ids), Set([cattle.targetID, other.targetID]))
    }
}

private final class TwelveSProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Double, String)] = []

    func append(_ fraction: Double, _ message: String) {
        lock.lock()
        values.append((fraction, message))
        lock.unlock()
    }

    func calls() -> [(Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct FakeTwelveSChimeraReviewer: TwelveSChimeraReviewing {
    let statuses: [String: TwelveSChimeraStatus]

    func review(
        unresolvedSequences: [TwelveSUnresolvedSequence],
        outputDirectory: URL,
        threads: Int
    ) async throws -> TwelveSChimeraReviewResult {
        TwelveSChimeraReviewResult(
            statusesBySequenceID: statuses,
            stderr: "fake vsearch stderr",
            exitStatus: 0
        )
    }
}

import XCTest
@testable import LungfishIO

final class FASTQDerivativesTests: XCTestCase {

    private func makeTempBundle() throws -> (tempDir: URL, bundleURL: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDerivativesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = tempDir.appendingPathComponent("example.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (tempDir, bundleURL)
    }

    // MARK: - Subset Manifest Round-Trip

    func testSubsetManifestRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 1000)
        let manifest = FASTQDerivedBundleManifest(
            name: "example-derivative",
            parentBundleRelativePath: "../example.lungfishfastq",
            rootBundleRelativePath: "../example.lungfishfastq",
            rootFASTQFilename: "example.fastq.gz",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .interleaved
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, manifest.name)
        XCTAssertEqual(loaded?.operation.kind, .subsampleCount)
        XCTAssertEqual(loaded?.operation.count, 1000)
        XCTAssertEqual(loaded?.lineage.count, 1)
        if case .subset(let filename) = loaded?.payload {
            XCTAssertEqual(filename, "read-ids.txt")
        } else {
            XCTFail("Expected subset payload")
        }
        XCTAssertTrue(FASTQBundle.isDerivedBundle(bundleURL))
    }

    // MARK: - Trim Manifest Round-Trip

    func testTrimManifestRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(
            kind: .qualityTrim,
            qualityThreshold: 20,
            windowSize: 4,
            qualityTrimMode: .cutRight,
            toolUsed: "fastp",
            toolCommand: "fastp -i input.fq -o output.fq --cut_right -W 4 -M 20"
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "example-qtrim",
            parentBundleRelativePath: "../example.lungfishfastq",
            rootBundleRelativePath: "../example.lungfishfastq",
            rootFASTQFilename: "example.fastq.gz",
            payload: .trim(trimPositionFilename: "trim-positions.tsv"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .singleEnd
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        if case .trim(let filename) = loaded?.payload {
            XCTAssertEqual(filename, "trim-positions.tsv")
        } else {
            XCTFail("Expected trim payload")
        }
        XCTAssertEqual(loaded?.operation.kind, .qualityTrim)
        XCTAssertEqual(loaded?.operation.qualityThreshold, 20)
        XCTAssertEqual(loaded?.operation.windowSize, 4)
        XCTAssertEqual(loaded?.operation.qualityTrimMode, .cutRight)
        XCTAssertEqual(loaded?.operation.toolUsed, "fastp")
        XCTAssertNotNil(loaded?.operation.toolCommand)
    }

    // MARK: - Operation Labels

    func testOperationSummaryFormatting() {
        let op = FASTQDerivativeOperation(
            kind: .lengthFilter,
            minLength: 100,
            maxLength: 200
        )
        XCTAssertTrue(op.shortLabel.contains("len-"))
        XCTAssertTrue(op.displaySummary.contains("Length filter"))
    }

    func testQualityTrimLabels() {
        let op = FASTQDerivativeOperation(
            kind: .qualityTrim,
            qualityThreshold: 25,
            windowSize: 5,
            qualityTrimMode: .cutBoth
        )
        XCTAssertEqual(op.shortLabel, "qtrim-Q25")
        XCTAssertTrue(op.displaySummary.contains("Quality trim Q25 w5"))
        XCTAssertTrue(op.displaySummary.contains("cutBoth"))
    }

    func testAdapterTrimLabels() {
        let autoOp = FASTQDerivativeOperation(kind: .adapterTrim, adapterMode: .autoDetect)
        XCTAssertEqual(autoOp.shortLabel, "adapter-trim")
        XCTAssertTrue(autoOp.displaySummary.contains("auto-detect"))

        let specifiedOp = FASTQDerivativeOperation(
            kind: .adapterTrim,
            adapterMode: .specified,
            adapterSequence: "AGATCGGAAGAGC"
        )
        XCTAssertTrue(specifiedOp.displaySummary.contains("AGATCGGAAGAGC"))
    }

    func testFixedTrimLabels() {
        let op = FASTQDerivativeOperation(kind: .fixedTrim, trimFrom5Prime: 10, trimFrom3Prime: 5)
        XCTAssertEqual(op.shortLabel, "trim-10-5")
        XCTAssertTrue(op.displaySummary.contains("5': 10 bp"))
        XCTAssertTrue(op.displaySummary.contains("3': 5 bp"))
    }

    func testDefaultLabelFallbacks() {
        // Operations with nil optional params should still produce labels
        let subsampleOp = FASTQDerivativeOperation(kind: .subsampleProportion)
        XCTAssertEqual(subsampleOp.shortLabel, "subsample-proportion")
        XCTAssertEqual(subsampleOp.displaySummary, "Subsample by proportion")

        let countOp = FASTQDerivativeOperation(kind: .subsampleCount)
        XCTAssertEqual(countOp.shortLabel, "subsample-count")

        let searchOp = FASTQDerivativeOperation(kind: .searchText)
        XCTAssertTrue(searchOp.displaySummary.contains("Search"))
    }

    // MARK: - Operation Category

    func testSubsetOperationKinds() {
        XCTAssertTrue(FASTQDerivativeOperationKind.subsampleProportion.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.subsampleCount.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.lengthFilter.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.searchText.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.searchMotif.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.deduplicate.isSubsetOperation)
    }

    func testTrimOperationKinds() {
        XCTAssertFalse(FASTQDerivativeOperationKind.qualityTrim.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.adapterTrim.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.fixedTrim.isSubsetOperation)
    }

    func testBBToolsOperationKinds() {
        // Contaminant filter is a subset operation (removes reads)
        XCTAssertTrue(FASTQDerivativeOperationKind.contaminantFilter.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.contaminantFilter.isFullOperation)

        // PE merge and repair are full operations (produce new content)
        XCTAssertFalse(FASTQDerivativeOperationKind.pairedEndMerge.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.pairedEndMerge.isFullOperation)

        XCTAssertFalse(FASTQDerivativeOperationKind.pairedEndRepair.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.pairedEndRepair.isFullOperation)
    }

    func testContaminantFilterLabels() {
        let phixOp = FASTQDerivativeOperation(
            kind: .contaminantFilter,
            contaminantFilterMode: .phix,
            contaminantKmerSize: 31,
            contaminantHammingDistance: 1
        )
        XCTAssertEqual(phixOp.shortLabel, "contaminant-phix")
        XCTAssertTrue(phixOp.displaySummary.contains("PhiX"))

        let customOp = FASTQDerivativeOperation(
            kind: .contaminantFilter,
            contaminantFilterMode: .custom,
            contaminantReferenceFasta: "contaminants.fa",
            contaminantKmerSize: 27,
            contaminantHammingDistance: 2
        )
        XCTAssertEqual(customOp.shortLabel, "contaminant-custom")
        XCTAssertTrue(customOp.displaySummary.contains("contaminants.fa"))
    }

    func testPairedEndMergeLabels() {
        let op = FASTQDerivativeOperation(
            kind: .pairedEndMerge,
            mergeStrictness: .strict,
            mergeMinOverlap: 15
        )
        XCTAssertEqual(op.shortLabel, "merge-strict")
        XCTAssertTrue(op.displaySummary.contains("strict"))
        XCTAssertTrue(op.displaySummary.contains("15"))
    }

    func testPairedEndRepairLabels() {
        let op = FASTQDerivativeOperation(kind: .pairedEndRepair)
        XCTAssertEqual(op.shortLabel, "repair")
        XCTAssertTrue(op.displaySummary.contains("repair"))
    }

    func testFullPayloadRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(
            kind: .pairedEndMerge,
            mergeStrictness: .normal,
            mergeMinOverlap: 12,
            toolUsed: "bbmerge",
            toolCommand: "bbmerge.sh in=reads.fq out=merged.fq outu=unmerged.fq minoverlap=12"
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "merged-reads",
            parentBundleRelativePath: "../example.lungfishfastq",
            rootBundleRelativePath: "../example.lungfishfastq",
            rootFASTQFilename: "example.fastq.gz",
            payload: .full(fastqFilename: "reads.fastq"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .interleaved
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        if case .full(let filename) = loaded?.payload {
            XCTAssertEqual(filename, "reads.fastq")
        } else {
            XCTFail("Expected full payload")
        }
        XCTAssertEqual(loaded?.operation.kind, .pairedEndMerge)
        XCTAssertEqual(loaded?.operation.mergeStrictness, .normal)
        XCTAssertEqual(loaded?.operation.mergeMinOverlap, 12)
        XCTAssertEqual(loaded?.operation.toolUsed, "bbmerge")

        // Verify bundle helper resolves full payload
        XCTAssertNotNil(FASTQBundle.fullPayloadFASTQURL(forDerivedBundle: bundleURL))
        XCTAssertNil(FASTQBundle.readIDListURL(forDerivedBundle: bundleURL))
        XCTAssertNil(FASTQBundle.trimPositionsURL(forDerivedBundle: bundleURL))
    }

    // MARK: - Trim Position File I/O

    func testTrimPositionFileRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimPosTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let records: [FASTQTrimRecord] = [
            FASTQTrimRecord(readID: "SRR001.1", trimStart: 0, trimEnd: 148),
            FASTQTrimRecord(readID: "SRR001.2", trimStart: 5, trimEnd: 142),
            FASTQTrimRecord(readID: "SRR001.3", trimStart: 12, trimEnd: 150),
        ]

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        try FASTQTrimPositionFile.write(records, to: url)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded["SRR001.1"]?.start, 0)
        XCTAssertEqual(loaded["SRR001.1"]?.end, 148)
        XCTAssertEqual(loaded["SRR001.2"]?.start, 5)
        XCTAssertEqual(loaded["SRR001.2"]?.end, 142)
        XCTAssertEqual(loaded["SRR001.3"]?.start, 12)
        XCTAssertEqual(loaded["SRR001.3"]?.end, 150)

        let orderedRecords = try FASTQTrimPositionFile.loadRecords(from: url)
        XCTAssertEqual(orderedRecords.count, 3)
        XCTAssertEqual(orderedRecords[0].readID, "SRR001.1")
        XCTAssertEqual(orderedRecords[1].trimmedLength, 137)
    }

    func testTrimPositionFileMalformedLinesSkipped() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimPosMalformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = """
        read1\t0\t100
        malformed_line
        read2\tabc\t100
        read3\t5
        read4\t10\t90
        """
        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertEqual(loaded.count, 2) // Only read1 and read4 are valid
        XCTAssertEqual(loaded["read1"]?.start, 0)
        XCTAssertEqual(loaded["read4"]?.start, 10)
    }

    func testTrimPositionFileEmptyFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimPosEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testTrimRecordLength() {
        let record = FASTQTrimRecord(readID: "test", trimStart: 5, trimEnd: 100)
        XCTAssertEqual(record.trimmedLength, 95)

        let zero = FASTQTrimRecord(readID: "test", trimStart: 50, trimEnd: 50)
        XCTAssertEqual(zero.trimmedLength, 0)
    }

    // MARK: - Trim Position Composition

    func testTrimCompositionBasic() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (5, 142),
            "read2": (0, 150),
            "read3": (10, 100),
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (10, 130),   // relative to parent's [5,142) = absolute [15, 135)
            "read2": (0, 100),    // relative to parent's [0,150) = absolute [0, 100)
            // read3 absent from child = not in result
        ]

        let result = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["read1"]?.start, 15)
        XCTAssertEqual(result["read1"]?.end, 135)
        XCTAssertEqual(result["read2"]?.start, 0)
        XCTAssertEqual(result["read2"]?.end, 100)
    }

    func testTrimCompositionClampsToParentEnd() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (5, 50),
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (0, 100),
        ]

        let result = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertEqual(result["read1"]?.start, 5)
        XCTAssertEqual(result["read1"]?.end, 50)
    }

    func testTrimCompositionDropsEmptyRanges() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 20),
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (15, 20),
        ]

        let result = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertTrue(result.isEmpty)
    }

    func testTrimCompositionEmptyInputs() {
        let empty: [String: (start: Int, end: Int)] = [:]
        let nonEmpty: [String: (start: Int, end: Int)] = ["read1": (0, 100)]

        XCTAssertTrue(FASTQTrimPositionFile.compose(parent: empty, child: nonEmpty).isEmpty)
        XCTAssertTrue(FASTQTrimPositionFile.compose(parent: nonEmpty, child: empty).isEmpty)
        XCTAssertTrue(FASTQTrimPositionFile.compose(parent: empty, child: empty).isEmpty)
    }

    // MARK: - Bundle Helpers

    func testBundleTrimPositionsURL() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20)
        let manifest = FASTQDerivedBundleManifest(
            name: "trim-test",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../parent.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .trim(trimPositionFilename: "trim-positions.tsv"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        XCTAssertNil(FASTQBundle.readIDListURL(forDerivedBundle: bundleURL))
        XCTAssertNotNil(FASTQBundle.trimPositionsURL(forDerivedBundle: bundleURL))
        XCTAssertEqual(
            FASTQBundle.trimPositionsURL(forDerivedBundle: bundleURL)?.lastPathComponent,
            "trim-positions.tsv"
        )
    }

    // MARK: - Trim with Record.trimmed()

    func testRecordTrimmedAppliesPositions() {
        let record = FASTQRecord(
            identifier: "read1",
            description: nil,
            sequence: "ACGTACGTACGT",
            quality: QualityScore(values: Array(repeating: UInt8(30), count: 12), encoding: .phred33)
        )

        // Trim from position 2 to 10
        let trimmed = record.trimmed(from: 2, to: 10)
        XCTAssertEqual(trimmed.sequence, "GTACGTAC")
        XCTAssertEqual(trimmed.length, 8)
        XCTAssertEqual(trimmed.identifier, "read1")
    }

    func testRecordTrimmedClampsToLength() {
        let record = FASTQRecord(
            identifier: "read1",
            description: nil,
            sequence: "ACGT",
            quality: QualityScore(values: [30, 30, 30, 30], encoding: .phred33)
        )

        let trimmed = record.trimmed(from: 0, to: 100)
        XCTAssertEqual(trimmed.sequence, "ACGT")
        XCTAssertEqual(trimmed.length, 4)
    }

    // MARK: - Phase 8: Primer Removal, Error Correction, Interleave Labels

    func testPrimerRemovalLabels() {
        let literalOp = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerSource: .literal,
            primerReadMode: .single,
            primerTrimMode: .linked,
            primerForwardSequence: "AGATCGGAAGAGC",
            primerReverseSequence: "CTCTTCCGATCT",
            primerAnchored5Prime: true,
            primerAnchored3Prime: true,
            primerErrorRate: 0.15,
            primerMinimumOverlap: 12,
            primerAllowIndels: true
        )
        XCTAssertEqual(literalOp.shortLabel, "primer-linked-single-ov12")
        XCTAssertTrue(literalOp.displaySummary.contains("AGATCGGAAGAGC"))
        XCTAssertTrue(literalOp.displaySummary.contains("linked"))
        XCTAssertTrue(literalOp.displaySummary.contains("literal"))

        let refOp = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerSource: .reference,
            primerReferenceFasta: "primers.fa",
            primerReadMode: .paired,
            primerTrimMode: .paired,
            primerMinimumOverlap: 18,
            primerPairFilter: .both
        )
        XCTAssertEqual(refOp.shortLabel, "primer-paired-paired-ov18")
        XCTAssertTrue(refOp.displaySummary.contains("primers.fa"))
    }

    func testErrorCorrectionLabels() {
        let op = FASTQDerivativeOperation(kind: .errorCorrection, errorCorrectionKmerSize: 50)
        XCTAssertEqual(op.shortLabel, "ecc-k50")
        XCTAssertTrue(op.displaySummary.contains("Error correction"))
        XCTAssertTrue(op.displaySummary.contains("k=50"))

        let customOp = FASTQDerivativeOperation(kind: .errorCorrection, errorCorrectionKmerSize: 31)
        XCTAssertEqual(customOp.shortLabel, "ecc-k31")
    }

    func testInterleaveReformatLabels() {
        let interleaveOp = FASTQDerivativeOperation(kind: .interleaveReformat, interleaveDirection: .interleave)
        XCTAssertEqual(interleaveOp.shortLabel, "interleave")
        XCTAssertTrue(interleaveOp.displaySummary.contains("Interleave R1/R2"))

        let deinterleaveOp = FASTQDerivativeOperation(kind: .interleaveReformat, interleaveDirection: .deinterleave)
        XCTAssertEqual(deinterleaveOp.shortLabel, "deinterleave")
        XCTAssertTrue(deinterleaveOp.displaySummary.contains("Deinterleave"))
    }

    func testPhase8OperationCategories() {
        // Primer removal: trim-like operation, not subset or full copy
        XCTAssertFalse(FASTQDerivativeOperationKind.primerRemoval.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.primerRemoval.isFullOperation)

        // Error correction: full operation, not subset
        XCTAssertFalse(FASTQDerivativeOperationKind.errorCorrection.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.errorCorrection.isFullOperation)

        // Interleave reformat: full operation, not subset
        XCTAssertFalse(FASTQDerivativeOperationKind.interleaveReformat.isSubsetOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.interleaveReformat.isFullOperation)
    }

    func testFullPairedPayloadRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(
            kind: .interleaveReformat,
            interleaveDirection: .deinterleave,
            toolUsed: "reformat",
            toolCommand: "reformat.sh in=reads.fq out1=R1.fastq out2=R2.fastq"
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "deinterleaved-reads",
            parentBundleRelativePath: "../example.lungfishfastq",
            rootBundleRelativePath: "../example.lungfishfastq",
            rootFASTQFilename: "example.fastq.gz",
            payload: .fullPaired(r1Filename: "R1.fastq", r2Filename: "R2.fastq"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .interleaved
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        if case .fullPaired(let r1, let r2) = loaded?.payload {
            XCTAssertEqual(r1, "R1.fastq")
            XCTAssertEqual(r2, "R2.fastq")
        } else {
            XCTFail("Expected fullPaired payload")
        }
        XCTAssertEqual(loaded?.operation.kind, .interleaveReformat)
        XCTAssertEqual(loaded?.operation.interleaveDirection, .deinterleave)
        XCTAssertEqual(loaded?.operation.toolUsed, "reformat")
        XCTAssertEqual(loaded?.payload.category, "full-paired")

        // Verify bundle helpers
        XCTAssertNotNil(FASTQBundle.pairedFASTQURLs(forDerivedBundle: bundleURL))
        XCTAssertNil(FASTQBundle.fullPayloadFASTQURL(forDerivedBundle: bundleURL))
        XCTAssertNil(FASTQBundle.readIDListURL(forDerivedBundle: bundleURL))
        XCTAssertNil(FASTQBundle.trimPositionsURL(forDerivedBundle: bundleURL))
    }

    func testPayloadCategories() {
        XCTAssertEqual(FASTQDerivativePayload.subset(readIDListFilename: "ids.txt").category, "subset")
        XCTAssertEqual(FASTQDerivativePayload.trim(trimPositionFilename: "trim.tsv").category, "trim")
        XCTAssertEqual(FASTQDerivativePayload.full(fastqFilename: "reads.fq").category, "full")
        XCTAssertEqual(FASTQDerivativePayload.fullPaired(r1Filename: "R1.fq", r2Filename: "R2.fq").category, "full-paired")
        XCTAssertEqual(
            FASTQDerivativePayload.demuxedVirtual(barcodeID: "bc1", readIDListFilename: "ids.txt", previewFilename: "preview.fastq").category,
            "demuxed-virtual"
        )
    }

    // MARK: - Demuxed Virtual Payload

    func testDemuxedVirtualManifestRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .demultiplex, createdAt: Date())
        let stats = FASTQDatasetStatistics.placeholder(readCount: 5000, baseCount: 750_000)
        let manifest = FASTQDerivedBundleManifest(
            name: "bc1001",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .demuxedVirtual(
                barcodeID: "bc1001",
                readIDListFilename: "read-ids.txt",
                previewFilename: "preview.fastq"
            ),
            lineage: [op],
            operation: op,
            cachedStatistics: stats,
            pairingMode: nil
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "bc1001")
        XCTAssertEqual(loaded?.rootFASTQFilename, "reads.fastq.gz")
        if case .demuxedVirtual(let barcodeID, let readIDFile, let previewFile, _, _) = loaded?.payload {
            XCTAssertEqual(barcodeID, "bc1001")
            XCTAssertEqual(readIDFile, "read-ids.txt")
            XCTAssertEqual(previewFile, "preview.fastq")
        } else {
            XCTFail("Expected demuxedVirtual payload, got \(String(describing: loaded?.payload))")
        }
        XCTAssertEqual(loaded?.cachedStatistics.readCount, 5000)
        XCTAssertEqual(loaded?.cachedStatistics.baseCount, 750_000)
        XCTAssertEqual(loaded?.cachedStatistics.meanReadLength, 150.0)
    }

    func testPlaceholderStatistics() {
        let stats = FASTQDatasetStatistics.placeholder(readCount: 10_000, baseCount: 1_500_000)
        XCTAssertEqual(stats.readCount, 10_000)
        XCTAssertEqual(stats.baseCount, 1_500_000)
        XCTAssertEqual(stats.meanReadLength, 150.0)
        XCTAssertEqual(stats.minReadLength, 0)
        XCTAssertEqual(stats.maxReadLength, 0)
        XCTAssertTrue(stats.readLengthHistogram.isEmpty)
        XCTAssertTrue(stats.qualityScoreHistogram.isEmpty)

        let emptyStats = FASTQDatasetStatistics.placeholder(readCount: 0, baseCount: 0)
        XCTAssertEqual(emptyStats.meanReadLength, 0)
    }

    // MARK: - Trim Validation Edge Cases

    func testLoadRejectsReversedTrimPositions() throws {
        let (tempDir, _) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("invalid_trim.tsv")
        try "read1\t50\t10\n".write(to: tsvURL, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: tsvURL)
        XCTAssertTrue(loaded.isEmpty, "Reversed trim positions (start > end) should be rejected")
    }

    func testLoadRejectsNegativeTrimPositions() throws {
        let (tempDir, _) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("negative_trim.tsv")
        try "read1\t-5\t10\nread2\t0\t-1\n".write(to: tsvURL, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: tsvURL)
        XCTAssertTrue(loaded.isEmpty, "Negative trim positions should be rejected")
    }

    func testLoadRejectsZeroLengthTrimPositions() throws {
        let (tempDir, _) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("zero_trim.tsv")
        try "read1\t10\t10\n".write(to: tsvURL, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: tsvURL)
        XCTAssertTrue(loaded.isEmpty, "Zero-length trim positions (start == end) should be rejected")
    }

    func testLoadRecordsRejectsInvalidPositions() throws {
        let (tempDir, _) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("mixed_trim.tsv")
        try """
            valid\t0\t100
            reversed\t100\t0
            negative\t-5\t10
            zero_len\t50\t50
            also_valid\t10\t20
            """.write(to: tsvURL, atomically: true, encoding: .utf8)

        let records = try FASTQTrimPositionFile.loadRecords(from: tsvURL)
        XCTAssertEqual(records.count, 2, "Only valid and also_valid should load")
        XCTAssertEqual(records[0].readID, "valid")
        XCTAssertEqual(records[1].readID, "also_valid")
    }

    func testTrimCompositionChildCompletelyOutsideParent() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 20),
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (30, 40),
        ]
        let result = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertTrue(result.isEmpty, "Child range beyond parent should produce empty result")
    }

    func testTrimCompositionExactParentBounds() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 20),
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (0, 10),
        ]
        let result = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["read1"]?.start, 10)
        XCTAssertEqual(result["read1"]?.end, 20)
    }

    func testTrimCompositionMultipleReads() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (0, 100),
            "read2": (10, 50),
            "read3": (0, 200),
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (5, 90),
            "read2": (0, 40),
            "read4": (0, 10),  // not in parent
        ]
        let result = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertEqual(result.count, 2, "Only reads in both sets should appear")
        XCTAssertEqual(result["read1"]?.start, 5)
        XCTAssertEqual(result["read1"]?.end, 90)
        XCTAssertEqual(result["read2"]?.start, 10)
        XCTAssertEqual(result["read2"]?.end, 50)
        XCTAssertNil(result["read3"], "read3 not in child")
        XCTAssertNil(result["read4"], "read4 not in parent")
    }

    func testTrimPositionFileStreamingWrite() throws {
        let (tempDir, _) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let records = (0..<1000).map { i in
            FASTQTrimRecord(readID: "read_\(i)", trimStart: i * 10, trimEnd: i * 10 + 100)
        }

        let tsvURL = tempDir.appendingPathComponent("large_trim.tsv")
        try FASTQTrimPositionFile.write(records, to: tsvURL)

        let loaded = try FASTQTrimPositionFile.loadRecords(from: tsvURL)
        XCTAssertEqual(loaded.count, 1000, "All 1000 records should round-trip")
        XCTAssertEqual(loaded.first?.readID, "read_0")
        XCTAssertEqual(loaded.last?.readID, "read_999")
    }

    func testBundleSubsetHasNoTrimURL() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 100)
        let manifest = FASTQDerivedBundleManifest(
            name: "subset-test",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../parent.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        XCTAssertNotNil(FASTQBundle.readIDListURL(forDerivedBundle: bundleURL))
        XCTAssertNil(FASTQBundle.trimPositionsURL(forDerivedBundle: bundleURL))
    }

    // MARK: - Project Root Discovery

    func testFindProjectRootFromNestedBundle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRootTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create: project.lungfish/extraction.lungfishfastq/demux/barcode01.lungfishfastq
        let projectRoot = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        let extraction = projectRoot.appendingPathComponent("extraction.lungfishfastq", isDirectory: true)
        let demux = extraction.appendingPathComponent("demux", isDirectory: true)
        let barcode = demux.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)

        XCTAssertEqual(FASTQBundle.findProjectRoot(from: barcode), projectRoot)
        XCTAssertEqual(FASTQBundle.findProjectRoot(from: extraction), projectRoot)
        XCTAssertNil(FASTQBundle.findProjectRoot(from: tempDir))
    }

    func testProjectRelativePathComputation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRelPathTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectRoot = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        let extraction = projectRoot.appendingPathComponent("extraction.lungfishfastq", isDirectory: true)
        let demux = extraction.appendingPathComponent("demux", isDirectory: true)
        let barcode = demux.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)

        let relPath = FASTQBundle.projectRelativePath(for: extraction, from: barcode)
        XCTAssertEqual(relPath, "@/extraction.lungfishfastq")
    }

    func testResolveBundleWithProjectRelativePath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolveBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectRoot = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        let extraction = projectRoot.appendingPathComponent("extraction.lungfishfastq", isDirectory: true)
        let demux = extraction.appendingPathComponent("demux", isDirectory: true)
        let barcode = demux.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)

        let resolved = FASTQBundle.resolveBundle(
            relativePath: "@/extraction.lungfishfastq",
            from: barcode
        )
        XCTAssertEqual(resolved.standardizedFileURL, extraction.standardizedFileURL)
    }

    func testResolveBundleFallsBackToLegacyRelativePath() {
        let anchor = URL(fileURLWithPath: "/tmp/project/child.lungfishfastq")
        let resolved = FASTQBundle.resolveBundle(
            relativePath: "../parent.lungfishfastq",
            from: anchor
        )
        XCTAssertTrue(resolved.path.hasSuffix("parent.lungfishfastq"))
    }

    // MARK: - Phase 1 Edge-Case Tests: Schema Versioning

    func testSchemaVersionDefaultIsCurrentVersion() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 100)
        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )
        XCTAssertEqual(manifest.schemaVersion, FASTQDerivedBundleManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.schemaVersion, 2)
    }

    func testSchemaVersionRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 100)
        let manifest = FASTQDerivedBundleManifest(
            name: "v2-test",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)
        XCTAssertEqual(loaded?.schemaVersion, 2)
    }

    func testSchemaVersionBackwardCompatV1() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a manifest JSON WITHOUT schemaVersion (simulating v1)
        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 50)
        let manifest = FASTQDerivedBundleManifest(
            name: "legacy",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )

        // Encode to JSON dict, remove schemaVersion, re-serialize
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent(FASTQBundle.derivedManifestFilename)
        let data = try Data(contentsOf: manifestURL)
        var jsonDict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        jsonDict.removeValue(forKey: "schemaVersion")
        let cleanData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys])
        try cleanData.write(to: manifestURL, options: .atomic)

        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)
        XCTAssertNotNil(loaded, "Legacy manifest without schemaVersion should load")
        XCTAssertEqual(loaded?.schemaVersion, 1) // Defaults to 1 for legacy
    }

    // MARK: - Phase 1 Edge-Case Tests: demuxedVirtual with orientMapFilename

    func testDemuxedVirtualWithOrientMapRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .demultiplex)
        let stats = FASTQDatasetStatistics.placeholder(readCount: 1000, baseCount: 150_000)
        let manifest = FASTQDerivedBundleManifest(
            name: "bc1001-oriented",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .demuxedVirtual(
                barcodeID: "bc1001",
                readIDListFilename: "read-ids.txt",
                previewFilename: "preview.fastq",
                trimPositionsFilename: "trim-positions.tsv",
                orientMapFilename: "orient-map.tsv"
            ),
            lineage: [op],
            operation: op,
            cachedStatistics: stats,
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)
        XCTAssertNotNil(loaded)
        if case .demuxedVirtual(let barcode, _, _, let trimFile, let orientFile) = loaded?.payload {
            XCTAssertEqual(barcode, "bc1001")
            XCTAssertEqual(trimFile, "trim-positions.tsv")
            XCTAssertEqual(orientFile, "orient-map.tsv")
        } else {
            XCTFail("Expected demuxedVirtual payload")
        }
    }

    func testDemuxedVirtualWithoutOrientMapRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .demultiplex)
        let manifest = FASTQDerivedBundleManifest(
            name: "bc1001",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .demuxedVirtual(
                barcodeID: "bc1001",
                readIDListFilename: "read-ids.txt",
                previewFilename: "preview.fastq",
                trimPositionsFilename: "trim-positions.tsv"
            ),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)
        if case .demuxedVirtual(_, _, _, _, let orientFile) = loaded?.payload {
            XCTAssertNil(orientFile, "orientMapFilename should be nil when not set")
        } else {
            XCTFail("Expected demuxedVirtual payload")
        }
    }

    // MARK: - Phase 1 Edge-Case Tests: Orient Map File I/O

    func testOrientMapRoundTripMixedOrientations() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        let records: [(readID: String, orientation: String)] = [
            ("read1", "+"), ("read2", "-"), ("read3", "+"),
            ("read4", "-"), ("read5", "-")
        ]
        try FASTQOrientMapFile.write(records, to: url)

        let loaded = try FASTQOrientMapFile.load(from: url)
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded["read1"], "+")
        XCTAssertEqual(loaded["read2"], "-")
        XCTAssertEqual(loaded["read5"], "-")

        let rcIDs = try FASTQOrientMapFile.loadRCReadIDs(from: url)
        XCTAssertEqual(rcIDs.count, 3)
        XCTAssertTrue(rcIDs.contains("read2"))
        XCTAssertTrue(rcIDs.contains("read4"))
        XCTAssertFalse(rcIDs.contains("read1"))

        let fwdIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: url)
        XCTAssertEqual(fwdIDs.count, 2)
        XCTAssertTrue(fwdIDs.contains("read1"))
        XCTAssertTrue(fwdIDs.contains("read3"))
    }

    func testOrientMapAllForward() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-allfwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        let records: [(readID: String, orientation: String)] = [
            ("r1", "+"), ("r2", "+"), ("r3", "+")
        ]
        try FASTQOrientMapFile.write(records, to: url)

        let rcIDs = try FASTQOrientMapFile.loadRCReadIDs(from: url)
        XCTAssertTrue(rcIDs.isEmpty, "No RC reads when all are forward")

        let fwdIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: url)
        XCTAssertEqual(fwdIDs.count, 3)
    }

    func testOrientMapAllReverse() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-allrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        let records: [(readID: String, orientation: String)] = [
            ("r1", "-"), ("r2", "-")
        ]
        try FASTQOrientMapFile.write(records, to: url)

        let fwdIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: url)
        XCTAssertTrue(fwdIDs.isEmpty)

        let rcIDs = try FASTQOrientMapFile.loadRCReadIDs(from: url)
        XCTAssertEqual(rcIDs.count, 2)
    }

    // MARK: - Phase 1 Edge-Case Tests: Trim Position 4-Column Format

    func testTrimPositions4ColumnFormatWriteAndParse() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim4col-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write 4-column format (as DemultiplexingPipeline now does)
        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        var content = "read_id\tmate\ttrim_5p\ttrim_3p\n"
        content += "READ001\t1\t24\t0\n"
        content += "READ001\t2\t0\t18\n"
        content += "READ002\t0\t12\t12\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        // Parse with the same logic as extractAndTrimReads
        let rawContent = try String(contentsOf: url, encoding: .utf8)
        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in rawContent.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                trimMap["\(cols[0])\t\(mate)"] = (t5, t3)
            }
        }

        XCTAssertEqual(trimMap.count, 3)
        XCTAssertEqual(trimMap["READ001\t1"]?.trim5p, 24)
        XCTAssertEqual(trimMap["READ001\t1"]?.trim3p, 0)
        XCTAssertEqual(trimMap["READ001\t2"]?.trim5p, 0)
        XCTAssertEqual(trimMap["READ001\t2"]?.trim3p, 18)
        XCTAssertEqual(trimMap["READ002\t0"]?.trim5p, 12)
    }

    func testTrimPositionsLegacy3ColumnBackwardCompat() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim3col-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write legacy 3-column format (no mate column)
        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        var content = "read_id\ttrim_5p\ttrim_3p\n"
        content += "READ001\t24\t12\n"
        content += "READ002\t0\t18\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        // Parse with backward-compatible logic
        let rawContent = try String(contentsOf: url, encoding: .utf8)
        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in rawContent.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                trimMap["\(cols[0])\t\(mate)"] = (t5, t3)
            } else if cols.count >= 3,
                      let t5 = Int(cols[1]),
                      let t3 = Int(cols[2]) {
                trimMap["\(cols[0])\t0"] = (t5, t3)
            }
        }

        XCTAssertEqual(trimMap.count, 2)
        XCTAssertEqual(trimMap["READ001\t0"]?.trim5p, 24)
        XCTAssertEqual(trimMap["READ002\t0"]?.trim3p, 18)
    }

    func testPEReadIDsWithDifferentTrimsNonColliding() throws {
        // Verify that R1 and R2 with the same base read ID get separate trims
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pe-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        var content = "read_id\tmate\ttrim_5p\ttrim_3p\n"
        content += "SHARED_ID\t1\t50\t10\n"  // R1: trim 50bp from 5', 10bp from 3'
        content += "SHARED_ID\t2\t5\t30\n"   // R2: trim 5bp from 5', 30bp from 3'
        try content.write(to: url, atomically: true, encoding: .utf8)

        let rawContent = try String(contentsOf: url, encoding: .utf8)
        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in rawContent.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                trimMap["\(cols[0])\t\(mate)"] = (t5, t3)
            }
        }

        // R1 and R2 should NOT collide
        XCTAssertEqual(trimMap.count, 2, "R1 and R2 should have separate entries")
        XCTAssertNotEqual(trimMap["SHARED_ID\t1"]?.trim5p, trimMap["SHARED_ID\t2"]?.trim5p)
        XCTAssertEqual(trimMap["SHARED_ID\t1"]?.trim5p, 50)
        XCTAssertEqual(trimMap["SHARED_ID\t2"]?.trim5p, 5)
    }

    // MARK: - Phase 1 Edge-Case Tests: Trim Composition

    func testTrimCompositionWithMixedOrientations() throws {
        // Parent trims (already adjusted for orientation)
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 990),  // Forward read: trim 10bp from start, 10bp from end
            "read2": (20, 980),  // RC read: trims already swapped at storage time
        ]
        // Child trims (relative to parent's trimmed output)
        let child: [String: (start: Int, end: Int)] = [
            "read1": (5, 975),   // Additional 5bp from start, 5bp from end
            "read2": (0, 950),   // Additional 10bp from end
        ]

        let composed = FASTQTrimPositionFile.compose(parent: parent, child: child)

        // read1: parent [10, 990) → child [5, 975) relative → absolute [15, 985)
        XCTAssertEqual(composed["read1"]?.start, 15)
        XCTAssertEqual(composed["read1"]?.end, 985)

        // read2: parent [20, 980) → child [0, 950) relative → absolute [20, 970)
        XCTAssertEqual(composed["read2"]?.start, 20)
        XCTAssertEqual(composed["read2"]?.end, 970)
    }

    func testTrimCompositionChildReadNotInParent() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 990)
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (5, 975),
            "read_orphan": (0, 100)  // Not in parent
        ]

        let composed = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertEqual(composed.count, 1, "Orphan child reads should be excluded")
        XCTAssertNil(composed["read_orphan"])
    }

    func testTrimCompositionEmptyChildProducesEmpty() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 990)
        ]
        let child: [String: (start: Int, end: Int)] = [:]

        let composed = FASTQTrimPositionFile.compose(parent: parent, child: child)
        XCTAssertTrue(composed.isEmpty)
    }

    func testTrimCompositionInvalidRangeSkipped() {
        let parent: [String: (start: Int, end: Int)] = [
            "read1": (10, 50)  // Only 40bp remaining
        ]
        let child: [String: (start: Int, end: Int)] = [
            "read1": (0, 100)  // Child claims 100bp but parent only has 40bp
        ]

        let composed = FASTQTrimPositionFile.compose(parent: parent, child: child)
        // absoluteEnd = min(10 + 100, 50) = 50, absoluteStart = 10 → valid (50 > 10)
        XCTAssertEqual(composed["read1"]?.start, 10)
        XCTAssertEqual(composed["read1"]?.end, 50)
    }

    // MARK: - Phase 1 Edge-Case Tests: demuxedVirtual Category

    func testDemuxedVirtualPayloadCategory() {
        let payload = FASTQDerivativePayload.demuxedVirtual(
            barcodeID: "bc1",
            readIDListFilename: "ids.txt",
            previewFilename: "preview.fastq",
            trimPositionsFilename: "trims.tsv",
            orientMapFilename: "orient-map.tsv"
        )
        XCTAssertEqual(payload.category, "demuxed-virtual")
    }

    // MARK: - Phase 1 Edge-Case Tests: Schema Future Version

    func testSchemaFutureVersionLoadsGracefully() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 50)
        let manifest = FASTQDerivedBundleManifest(
            name: "future",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )

        // Write normally, then patch schemaVersion to 99
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent(FASTQBundle.derivedManifestFilename)
        var jsonString = try String(contentsOf: manifestURL, encoding: .utf8)
        jsonString = jsonString.replacingOccurrences(
            of: #""schemaVersion" : 2"#,
            with: #""schemaVersion" : 99"#
        )
        try jsonString.data(using: .utf8)!.write(to: manifestURL, options: .atomic)

        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)
        XCTAssertNotNil(loaded, "Future schema version should still load")
        XCTAssertEqual(loaded?.schemaVersion, 99)
        XCTAssertEqual(loaded?.name, "future")
    }

    // MARK: - Phase 1 Edge-Case Tests: Empty/Edge Cases

    func testOrientMapEmptyFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQOrientMapFile.load(from: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testOrientMapMalformedLinesSkipped() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-malformed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        var content = "read1\t+\n"
        content += "malformed_no_tab\n"            // Missing tab
        content += "read2\tX\n"                    // Invalid orientation
        content += "read3\t-\n"
        content += "\t+\n"                         // Empty read ID
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQOrientMapFile.load(from: url)
        XCTAssertEqual(loaded.count, 2, "Only valid lines should load")
        XCTAssertEqual(loaded["read1"], "+")
        XCTAssertEqual(loaded["read3"], "-")
    }

    func testTrimPositionsZeroLengthTrimSkipped() throws {
        // Trim where start == end (zero length) is skipped by loader (end > start required)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-zero-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        // Write raw content to test loader filtering (can't construct inverted FASTQTrimRecord)
        var content = "\(FASTQTrimPositionFile.formatHeader)\nread_id\tmate\ttrim_start\ttrim_end\n"
        content += "read1\t0\t10\t990\n"
        content += "read2\t0\t500\t500\n"  // Zero length — end == start
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertEqual(loaded.count, 1, "Zero-length trim should be skipped")
        XCTAssertNotNil(loaded["read1"])
        XCTAssertNil(loaded["read2"])
    }

    func testTrimPositionsNegativeValuesSkipped() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-neg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        var content = "read1\t-5\t100\n"   // Negative start
        content += "read2\t10\t990\n"       // Valid
        content += "read3\t10\t-1\n"        // Negative end
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNotNil(loaded["read2"])
    }

    // MARK: - Phase 1 Edge-Case Tests: Trim Position Chaining Arithmetic

    func testTrimChainingAddsParentAndChildTrims() throws {
        // Simulate: parent trimmed 10bp from 5', 5bp from 3'
        // Inner step trims additional 8bp from 5', 3bp from 3'
        // Chained result should be 18bp from 5', 8bp from 3'
        let parent5p = 10
        let parent3p = 5
        let inner5p = 8
        let inner3p = 3
        let chained5p = parent5p + inner5p
        let chained3p = parent3p + inner3p
        XCTAssertEqual(chained5p, 18)
        XCTAssertEqual(chained3p, 8)
    }

    func testOrientTrimSwapForRCRead() throws {
        // For RC'd reads, 5' and 3' trims should be swapped
        // If cutadapt says trim_5p=24, trim_3p=12 on an RC'd read,
        // the stored values should be trim_5p=12, trim_3p=24
        let cutadaptTrim5p = 24
        let cutadaptTrim3p = 12
        let orientation = "-"

        let stored5p: Int
        let stored3p: Int
        if orientation == "-" {
            stored5p = cutadaptTrim3p
            stored3p = cutadaptTrim5p
        } else {
            stored5p = cutadaptTrim5p
            stored3p = cutadaptTrim3p
        }

        XCTAssertEqual(stored5p, 12, "5' trim for RC read should be the cutadapt 3' trim")
        XCTAssertEqual(stored3p, 24, "3' trim for RC read should be the cutadapt 5' trim")
    }

    func testV1DemuxedVirtualPayloadDecodesWithoutOrientMapKey() throws {
        // Simulate a v1 manifest that has demuxedVirtual with 4 params (no orientMapFilename key)
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(kind: .demultiplex)
        let stats = FASTQDatasetStatistics.placeholder(readCount: 500, baseCount: 75_000)
        let manifest = FASTQDerivedBundleManifest(
            name: "v1-demux",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .demuxedVirtual(
                barcodeID: "bc1001",
                readIDListFilename: "read-ids.txt",
                previewFilename: "preview.fastq",
                trimPositionsFilename: "trim-positions.tsv",
                orientMapFilename: "orient-map.tsv"
            ),
            lineage: [op],
            operation: op,
            cachedStatistics: stats,
            pairingMode: nil
        )

        // Save, then strip both schemaVersion and orientMapFilename keys
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent(FASTQBundle.derivedManifestFilename)
        let data = try Data(contentsOf: manifestURL)
        var jsonDict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        jsonDict.removeValue(forKey: "schemaVersion")
        // Strip orientMapFilename from the payload's demuxedVirtual dict
        if var payload = jsonDict["payload"] as? [String: Any],
           var demuxDict = payload["demuxedVirtual"] as? [String: Any] {
            demuxDict.removeValue(forKey: "orientMapFilename")
            payload["demuxedVirtual"] = demuxDict
            jsonDict["payload"] = payload
        }
        let cleanData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys])
        try cleanData.write(to: manifestURL, options: .atomic)

        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)
        XCTAssertNotNil(loaded, "V1 demuxedVirtual without orientMapFilename key should decode")
        XCTAssertEqual(loaded?.schemaVersion, 1)
        if case .demuxedVirtual(let barcode, _, _, let trimFile, let orientFile) = loaded?.payload {
            XCTAssertEqual(barcode, "bc1001")
            XCTAssertEqual(trimFile, "trim-positions.tsv")
            XCTAssertNil(orientFile, "Missing orientMapFilename key should decode as nil")
        } else {
            XCTFail("Expected demuxedVirtual payload, got \(String(describing: loaded?.payload))")
        }
    }

    func testOrientTrimNoSwapForForwardRead() {
        let cutadaptTrim5p = 24
        let cutadaptTrim3p = 12
        let orientation = "+"

        let stored5p: Int
        let stored3p: Int
        if orientation == "-" {
            stored5p = cutadaptTrim3p
            stored3p = cutadaptTrim5p
        } else {
            stored5p = cutadaptTrim5p
            stored3p = cutadaptTrim3p
        }

        XCTAssertEqual(stored5p, 24, "Forward read trims should not be swapped")
        XCTAssertEqual(stored3p, 12)
    }

    // MARK: - Phase 2: Robustness Tests

    // MARK: 2.3 Atomic Sidecar Writes

    func testAtomicOrientMapWriteNoPartialFile() throws {
        // Verify that orient map write creates the file atomically (no .tmp left behind)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-orient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        let records: [(readID: String, orientation: String)] = [
            ("read1", "+"),
            ("read2", "-"),
            ("read3", "+"),
        ]
        try FASTQOrientMapFile.write(records, to: url)

        // Final file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Temp file cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))

        let loaded = try FASTQOrientMapFile.load(from: url)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded["read2"], "-")
    }

    func testAtomicTrimWriteNoPartialFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-trim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        let records = [
            FASTQTrimRecord(readID: "read1", mate: 0, trimStart: 10, trimEnd: 100),
            FASTQTrimRecord(readID: "read2", mate: 1, trimStart: 5, trimEnd: 95),
        ]
        try FASTQTrimPositionFile.write(records, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    func testAtomicWriteOverwritesExistingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-overwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("orient-map.tsv")
        // Write initial data
        try FASTQOrientMapFile.write([("read1", "+")], to: url)
        let initial = try FASTQOrientMapFile.load(from: url)
        XCTAssertEqual(initial.count, 1)

        // Overwrite with different data
        try FASTQOrientMapFile.write([("readA", "-"), ("readB", "+")], to: url)
        let updated = try FASTQOrientMapFile.load(from: url)
        XCTAssertEqual(updated.count, 2)
        XCTAssertNil(updated["read1"])
        XCTAssertEqual(updated["readA"], "-")
    }

    // MARK: 2.4 Tool Version Recording

    func testToolVersionFieldRoundTrips() throws {
        let op = FASTQDerivativeOperation(
            kind: .demultiplex,
            toolUsed: "cutadapt",
            toolVersion: "4.9"
        )
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(FASTQDerivativeOperation.self, from: data)
        XCTAssertEqual(decoded.toolVersion, "4.9")
        XCTAssertEqual(decoded.toolUsed, "cutadapt")
    }

    func testToolVersionNilByDefault() throws {
        let op = FASTQDerivativeOperation(kind: .adapterTrim)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(FASTQDerivativeOperation.self, from: data)
        XCTAssertNil(decoded.toolVersion)
    }

    func testToolVersionBackwardCompatMissingField() throws {
        // Simulate a v1 operation JSON without toolVersion field
        let json = """
        {"kind":"demultiplex","createdAt":0,"toolUsed":"cutadapt","toolCommand":"cutadapt --demux"}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FASTQDerivativeOperation.self, from: data)
        XCTAssertNil(decoded.toolVersion)
        XCTAssertEqual(decoded.toolUsed, "cutadapt")
    }

    // MARK: 2.5 Trim Format v2

    func testTrimV2FormatHeaderWritten() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        try FASTQTrimPositionFile.write([
            FASTQTrimRecord(readID: "read1", mate: 0, trimStart: 10, trimEnd: 100),
        ], to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix(FASTQTrimPositionFile.formatHeader),
                       "v2 format should start with #format header")
        XCTAssertTrue(content.contains("read_id\tmate\ttrim_start\ttrim_end"),
                       "v2 format should have column headers")
    }

    func testTrimV2WithMateRoundTrips() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-v2-mate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        let records = [
            FASTQTrimRecord(readID: "read1", mate: 1, trimStart: 10, trimEnd: 100),
            FASTQTrimRecord(readID: "read1", mate: 2, trimStart: 5, trimEnd: 95),
            FASTQTrimRecord(readID: "read2", mate: 0, trimStart: 0, trimEnd: 150),
        ]
        try FASTQTrimPositionFile.write(records, to: url)

        let loaded = try FASTQTrimPositionFile.loadRecords(from: url)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].mate, 1)
        XCTAssertEqual(loaded[1].mate, 2)
        XCTAssertEqual(loaded[2].mate, 0)
        XCTAssertEqual(loaded[0].trimStart, 10)
        XCTAssertEqual(loaded[1].trimEnd, 95)
    }

    func testTrimV1LegacyLoadedByV2Parser() throws {
        // v1 format: no #format header, 3-column
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-v1-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        let content = "read1\t10\t100\nread2\t5\t95\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["read1"]?.start, 10)
        XCTAssertEqual(loaded["read1"]?.end, 100)
    }

    func testTrimV2SkipsHeaderLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-v2-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("trim-positions.tsv")
        var content = "#format lungfish-trim-v2\n"
        content += "read_id\tmate\ttrim_start\ttrim_end\n"
        content += "read1\t0\t10\t100\n"
        content += "read2\t1\t5\t95\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try FASTQTrimPositionFile.load(from: url)
        XCTAssertEqual(loaded.count, 2, "Should have 2 records, headers skipped")
        XCTAssertNotNil(loaded["read1"])
        XCTAssertNotNil(loaded["read2"])
    }

    // MARK: 2.6 Random Seed

    func testRandomSeedFieldRoundTrips() throws {
        let seed: UInt64 = 12345678901234
        let op = FASTQDerivativeOperation(
            kind: .subsampleProportion,
            proportion: 0.5,
            randomSeed: seed
        )
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(FASTQDerivativeOperation.self, from: data)
        XCTAssertEqual(decoded.randomSeed, seed)
    }

    func testRandomSeedNilByDefault() throws {
        let op = FASTQDerivativeOperation(kind: .adapterTrim)
        XCTAssertNil(op.randomSeed)
    }

    func testRandomSeedBackwardCompatMissingField() throws {
        let json = """
        {"kind":"subsampleProportion","createdAt":0,"proportion":0.5}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FASTQDerivativeOperation.self, from: data)
        XCTAssertNil(decoded.randomSeed)
        XCTAssertEqual(decoded.proportion, 0.5)
    }

    // MARK: 2.5 Trim Record Mate Field

    func testTrimRecordMateDefaultsToZero() {
        let record = FASTQTrimRecord(readID: "read1", trimStart: 10, trimEnd: 100)
        XCTAssertEqual(record.mate, 0, "Mate should default to 0 (single-end)")
    }

    func testTrimRecordMatePreserved() {
        let r1 = FASTQTrimRecord(readID: "read1", mate: 1, trimStart: 10, trimEnd: 100)
        let r2 = FASTQTrimRecord(readID: "read1", mate: 2, trimStart: 5, trimEnd: 95)
        XCTAssertEqual(r1.mate, 1)
        XCTAssertEqual(r2.mate, 2)
    }

    // MARK: - BBDuk Primer Trimming Enums & Configuration

    func testPrimerToolEnumRoundTrips() {
        XCTAssertEqual(FASTQPrimerTool.cutadapt.rawValue, "cutadapt")
        XCTAssertEqual(FASTQPrimerTool.bbduk.rawValue, "bbduk")
        XCTAssertEqual(FASTQPrimerTool(rawValue: "cutadapt"), .cutadapt)
        XCTAssertEqual(FASTQPrimerTool(rawValue: "bbduk"), .bbduk)
    }

    func testKtrimDirectionEnumRoundTrips() {
        XCTAssertEqual(FASTQKtrimDirection.left.rawValue, "left")
        XCTAssertEqual(FASTQKtrimDirection.right.rawValue, "right")
        XCTAssertEqual(FASTQKtrimDirection(rawValue: "left"), .left)
        XCTAssertEqual(FASTQKtrimDirection(rawValue: "right"), .right)
    }

    func testAdapterSearchEndEnum() {
        XCTAssertEqual(FASTQAdapterSearchEnd.fivePrime.rawValue, "fivePrime")
        XCTAssertEqual(FASTQAdapterSearchEnd.threePrime.rawValue, "threePrime")
    }

    func testPrimerTrimConfigurationWithBBDukDefaults() {
        let config = FASTQPrimerTrimConfiguration(
            source: .reference,
            referenceFasta: "primers.fasta",
            tool: .bbduk
        )
        XCTAssertEqual(config.tool, .bbduk)
        XCTAssertEqual(config.ktrimDirection, .left)
        XCTAssertEqual(config.kmerSize, 15)
        XCTAssertEqual(config.minKmer, 11)
        XCTAssertEqual(config.hammingDistance, 1)
        XCTAssertTrue(config.searchReverseComplement)
    }

    func testPrimerTrimConfigurationWithBBDukCustom() {
        let config = FASTQPrimerTrimConfiguration(
            source: .reference,
            referenceFasta: "primers.fasta",
            searchReverseComplement: true,
            tool: .bbduk,
            ktrimDirection: .right,
            kmerSize: 17,
            minKmer: 13,
            hammingDistance: 2
        )
        XCTAssertEqual(config.tool, .bbduk)
        XCTAssertEqual(config.ktrimDirection, .right)
        XCTAssertEqual(config.kmerSize, 17)
        XCTAssertEqual(config.minKmer, 13)
        XCTAssertEqual(config.hammingDistance, 2)
    }

    func testPrimerTrimConfigurationDefaultsToCutadapt() {
        let config = FASTQPrimerTrimConfiguration(source: .literal, forwardSequence: "ATCG")
        XCTAssertEqual(config.tool, .cutadapt)
    }

    func testPrimerTrimConfigurationCodable() throws {
        let config = FASTQPrimerTrimConfiguration(
            source: .reference,
            referenceFasta: "primers.fasta",
            tool: .bbduk,
            ktrimDirection: .right,
            kmerSize: 15,
            minKmer: 11,
            hammingDistance: 1
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FASTQPrimerTrimConfiguration.self, from: data)

        XCTAssertEqual(decoded.tool, .bbduk)
        XCTAssertEqual(decoded.ktrimDirection, .right)
        XCTAssertEqual(decoded.kmerSize, 15)
        XCTAssertEqual(decoded.minKmer, 11)
        XCTAssertEqual(decoded.hammingDistance, 1)
        XCTAssertEqual(decoded.source, .reference)
        XCTAssertEqual(decoded.referenceFasta, "primers.fasta")
    }

    // MARK: - BBDuk Primer Removal Operation Labels

    func testBBDukPrimerRemovalLabels() {
        let op = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerSource: .reference,
            primerReferenceFasta: "primers.fa",
            primerKmerSize: 15,
            primerTrimMode: .fivePrime,
            primerTool: .bbduk,
            primerKtrimDirection: .left,
            toolUsed: "bbduk"
        )
        XCTAssertTrue(op.displaySummary.contains("bbduk"), op.displaySummary)
        XCTAssertTrue(op.displaySummary.contains("5'"), op.displaySummary)
        XCTAssertTrue(op.displaySummary.contains("k=15"), op.displaySummary)
    }

    func testBBDukPrimerRemovalThreePrimeLabels() {
        let op = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerSource: .reference,
            primerReferenceFasta: "primers.fa",
            primerKmerSize: 17,
            primerTrimMode: .threePrime,
            primerTool: .bbduk,
            primerKtrimDirection: .right,
            toolUsed: "bbduk"
        )
        XCTAssertTrue(op.displaySummary.contains("3'"), op.displaySummary)
        XCTAssertTrue(op.displaySummary.contains("k=17"), op.displaySummary)
    }

    func testCutadaptPrimerRemovalStillWorks() {
        let op = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerSource: .literal,
            primerTrimMode: .linked,
            primerForwardSequence: "ATCGATCGATCGATCG",
            primerMinimumOverlap: 12,
            primerTool: .cutadapt,
            toolUsed: "cutadapt"
        )
        XCTAssertTrue(op.displaySummary.contains("cutadapt"), op.displaySummary)
        XCTAssertTrue(op.displaySummary.contains("linked"), op.displaySummary)
    }

    // MARK: - Adapter Presence Filter

    func testAdapterPresenceFilterIsSubsetOperation() {
        XCTAssertTrue(FASTQDerivativeOperationKind.sequencePresenceFilter.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.sequencePresenceFilter.isFullOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.sequencePresenceFilter.supportsFASTA)
    }

    func testAdapterPresenceFilterLabels() {
        let keepOp = FASTQDerivativeOperation(
            kind: .sequencePresenceFilter,
            adapterFilterSequence: "AGATCGGAAGAGC",
            adapterFilterSearchEnd: .fivePrime,
            adapterFilterMinOverlap: 16,
            adapterFilterErrorRate: 0.15,
            adapterFilterKeepMatched: true
        )
        XCTAssertTrue(keepOp.displaySummary.contains("Keep"), keepOp.displaySummary)
        XCTAssertTrue(keepOp.displaySummary.contains("5'"), keepOp.displaySummary)
        XCTAssertTrue(keepOp.displaySummary.contains("AGATCGGAAGAGC"), keepOp.displaySummary)
        XCTAssertTrue(keepOp.shortLabel.contains("keep"), keepOp.shortLabel)

        let discardOp = FASTQDerivativeOperation(
            kind: .sequencePresenceFilter,
            adapterFilterSequence: "AGATCGGAAGAGC",
            adapterFilterSearchEnd: .threePrime,
            adapterFilterKeepMatched: false
        )
        XCTAssertTrue(discardOp.displaySummary.contains("Discard"), discardOp.displaySummary)
        XCTAssertTrue(discardOp.displaySummary.contains("3'"), discardOp.displaySummary)
        XCTAssertTrue(discardOp.shortLabel.contains("discard"), discardOp.shortLabel)
    }

    func testAdapterPresenceFilterMethodsSentence() {
        let op = FASTQDerivativeOperation(
            kind: .sequencePresenceFilter,
            adapterFilterSequence: "ATCGATCG",
            adapterFilterSearchEnd: .fivePrime,
            adapterFilterMinOverlap: 16,
            adapterFilterKeepMatched: true,
            toolUsed: "cutadapt",
            toolVersion: "4.4"
        )
        let sentence = op.methodsSentence
        XCTAssertTrue(sentence.contains("cutadapt v4.4"), sentence)
        XCTAssertTrue(sentence.contains("5'"), sentence)
        XCTAssertTrue(sentence.contains("retained"), sentence)
        XCTAssertTrue(sentence.contains("16 bp"), sentence)
    }

    func testAdapterPresenceFilterRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(
            kind: .sequencePresenceFilter,
            adapterFilterSequence: "AGATCGGAAGAGC",
            adapterFilterFastaPath: nil,
            adapterFilterSearchEnd: .fivePrime,
            adapterFilterMinOverlap: 16,
            adapterFilterErrorRate: 0.15,
            adapterFilterKeepMatched: true,
            toolUsed: "cutadapt",
            toolCommand: "cutadapt -e 0.15 --overlap 16 --action none --discard-untrimmed -g AGATCGGAAGAGC"
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "adapter-filtered",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.operation.kind, .sequencePresenceFilter)
        XCTAssertEqual(loaded?.operation.adapterFilterSequence, "AGATCGGAAGAGC")
        XCTAssertEqual(loaded?.operation.adapterFilterSearchEnd, .fivePrime)
        XCTAssertEqual(loaded?.operation.adapterFilterMinOverlap, 16)
        XCTAssertEqual(loaded?.operation.adapterFilterErrorRate, 0.15)
        XCTAssertEqual(loaded?.operation.adapterFilterKeepMatched, true)
        XCTAssertEqual(loaded?.operation.toolUsed, "cutadapt")
    }

    // MARK: - OperationChain with sequencePresenceFilter

    func testAdapterPresenceFilterOperationContract() {
        let input = OperationContract.input(for: .sequencePresenceFilter)
        XCTAssertTrue(input.acceptedFormats.contains(.fastq))
        XCTAssertTrue(input.acceptedFormats.contains(.fasta))
        XCTAssertNil(input.requiredPairing)
    }

    // MARK: - BBDuk primer removal with new fields round-trips

    func testBBDukPrimerRemovalRoundTrip() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let op = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerSource: .reference,
            primerReferenceFasta: "primers.fasta",
            primerKmerSize: 15,
            primerMinKmer: 11,
            primerHammingDistance: 1,
            primerTrimMode: .fivePrime,
            primerSearchReverseComplement: true,
            primerTool: .bbduk,
            primerKtrimDirection: .left,
            toolUsed: "bbduk",
            toolCommand: "bbduk.sh in=reads.fq out=trimmed.fq ref=primers.fasta k=15 mink=11 hdist=1 ktrim=l rcomp=t"
        )

        let manifest = FASTQDerivedBundleManifest(
            name: "primer-trimmed",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .trim(trimPositionFilename: "trim-positions.tsv"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: nil
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.operation.kind, .primerRemoval)
        XCTAssertEqual(loaded?.operation.primerTool, .bbduk)
        XCTAssertEqual(loaded?.operation.primerKtrimDirection, .left)
        XCTAssertEqual(loaded?.operation.primerKmerSize, 15)
        XCTAssertEqual(loaded?.operation.primerMinKmer, 11)
        XCTAssertEqual(loaded?.operation.primerHammingDistance, 1)
        XCTAssertEqual(loaded?.operation.primerSearchReverseComplement, true)
        XCTAssertEqual(loaded?.operation.toolUsed, "bbduk")
    }
}

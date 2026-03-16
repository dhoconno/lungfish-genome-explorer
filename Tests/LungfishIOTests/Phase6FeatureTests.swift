import XCTest
@testable import LungfishIO

final class Phase6FeatureTests: XCTestCase {

    // MARK: - Methods Text Export

    func testMethodsSentenceForQualityTrim() {
        let op = FASTQDerivativeOperation(
            kind: .qualityTrim,
            qualityThreshold: 25,
            windowSize: 5,
            qualityTrimMode: .cutBoth,
            toolUsed: "fastp",
            toolVersion: "0.23.4"
        )
        let sentence = op.methodsSentence
        XCTAssertTrue(sentence.contains("Quality trimming"), sentence)
        XCTAssertTrue(sentence.contains("fastp v0.23.4"), sentence)
        XCTAssertTrue(sentence.contains("Q25"), sentence)
        XCTAssertTrue(sentence.contains("window size 5"), sentence)
    }

    func testMethodsSentenceForAdapterTrimAutoDetect() {
        let op = FASTQDerivativeOperation(kind: .adapterTrim, adapterMode: .autoDetect)
        XCTAssertTrue(op.methodsSentence.contains("auto-detection"))
    }

    func testMethodsSentenceForPrimerRemoval() {
        let op = FASTQDerivativeOperation(
            kind: .primerRemoval,
            primerTrimMode: .paired,
            primerErrorRate: 0.15,
            primerMinimumOverlap: 10,
            toolUsed: "cutadapt",
            toolVersion: "4.4"
        )
        let sentence = op.methodsSentence
        XCTAssertTrue(sentence.contains("cutadapt v4.4"), sentence)
        XCTAssertTrue(sentence.contains("15%"), sentence)
        XCTAssertTrue(sentence.contains("10 bp"), sentence)
    }

    func testMethodsSentenceForContaminantFilter() {
        let op = FASTQDerivativeOperation(
            kind: .contaminantFilter,
            contaminantFilterMode: .phix,
            toolUsed: "bbduk"
        )
        XCTAssertTrue(op.methodsSentence.contains("PhiX"))
        XCTAssertTrue(op.methodsSentence.contains("bbduk"))
    }

    func testGenerateMethodsTextMultiStep() {
        let stats = FASTQDatasetStatistics(
            readCount: 150000, baseCount: 30_000_000,
            meanReadLength: 200, minReadLength: 50, maxReadLength: 301,
            medianReadLength: 200, n50ReadLength: 200,
            meanQuality: 32.5, q20Percentage: 95.0, q30Percentage: 88.0,
            gcContent: 0.45,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )

        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20, toolUsed: "fastp"),
            ],
            operation: FASTQDerivativeOperation(kind: .adapterTrim, adapterMode: .autoDetect, toolUsed: "fastp"),
            cachedStatistics: stats,
            pairingMode: nil
        )

        let text = manifest.generateMethodsText()
        XCTAssertTrue(text.contains("Raw reads were processed"), text)
        XCTAssertTrue(text.contains("Quality trimming"), text)
        XCTAssertTrue(text.contains("Adapter sequences"), text)
        XCTAssertTrue(text.contains("150,000"), text)
        XCTAssertTrue(text.contains("32.5"), text)
    }

    func testGenerateMethodsTextWithoutStats() {
        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .lengthFilter, minLength: 100, maxLength: 500),
            cachedStatistics: .empty,
            pairingMode: nil
        )

        let text = manifest.generateMethodsText(includeStats: false)
        XCTAssertTrue(text.contains("filtered by length"), text)
        XCTAssertFalse(text.contains("retained after processing"), text)
    }

    // MARK: - Staleness Detection

    func testIsStaleDetectsModifiedRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create root bundle with FASTQ
        let rootBundle = tempDir.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFASTQ = rootBundle.appendingPathComponent("reads.fastq")
        try "@seq\nACGT\n+\nIIII\n".write(to: rootFASTQ, atomically: true, encoding: .utf8)

        // Wait a moment, then create the derivative (so createdAt > root mod date)
        Thread.sleep(forTimeInterval: 0.1)

        let derivBundle = tempDir.appendingPathComponent("deriv.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: derivBundle, withIntermediateDirectories: true)

        let manifest = FASTQDerivedBundleManifest(
            name: "deriv",
            parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .qualityTrim),
            cachedStatistics: .empty,
            pairingMode: nil
        )

        // Initially not stale (derivative created after root)
        XCTAssertEqual(manifest.isStale(bundleURL: derivBundle), false)

        // Touch the root FASTQ to make it newer
        Thread.sleep(forTimeInterval: 0.1)
        try "@seq2\nTTTT\n+\nIIII\n".write(to: rootFASTQ, atomically: true, encoding: .utf8)

        XCTAssertEqual(manifest.isStale(bundleURL: derivBundle), true)
    }

    func testIsStaleReturnsNilForMissingRoot() {
        let manifest = FASTQDerivedBundleManifest(
            name: "orphan",
            parentBundleRelativePath: "../nonexistent.lungfishfastq",
            rootBundleRelativePath: "../nonexistent.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .qualityTrim),
            cachedStatistics: .empty,
            pairingMode: nil
        )
        let result = manifest.isStale(bundleURL: URL(fileURLWithPath: "/tmp/fake.lungfishfastq"))
        XCTAssertNil(result)
    }

    // MARK: - Recipe Placeholders

    func testRecipePlaceholderRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaceholderTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let recipe = ProcessingRecipe(
            name: "Amplicon with Primers",
            steps: [
                FASTQDerivativeOperation(kind: .primerRemoval, primerTrimMode: .paired),
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
            ],
            placeholders: [
                RecipePlaceholder(key: "forwardPrimer", label: "Forward Primer", valueType: .sequence),
                RecipePlaceholder(key: "reversePrimer", label: "Reverse Primer", valueType: .sequence),
            ]
        )

        XCTAssertTrue(recipe.requiresPlaceholderValues)
        XCTAssertEqual(recipe.unfilledPlaceholderKeys, ["forwardPrimer", "reversePrimer"])

        // Round-trip through JSON
        let url = tempDir.appendingPathComponent("test.\(ProcessingRecipe.fileExtension)")
        try recipe.save(to: url)
        let loaded = ProcessingRecipe.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.placeholders.count, 2)
        XCTAssertEqual(loaded?.placeholders.first?.key, "forwardPrimer")
        XCTAssertEqual(loaded?.placeholders.first?.valueType, .sequence)
    }

    func testRecipeWithoutPlaceholdersDecodesFromOldJSON() throws {
        // Simulate an old-format JSON without "placeholders" key
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OldRecipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let oldRecipe = ProcessingRecipe(
            name: "Old Recipe",
            steps: [FASTQDerivativeOperation(kind: .qualityTrim)]
        )
        let url = tempDir.appendingPathComponent("old.recipe.json")
        try oldRecipe.save(to: url)

        // Verify it loads correctly (placeholders defaults to [])
        let loaded = ProcessingRecipe.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded!.placeholders.isEmpty)
        XCTAssertFalse(loaded!.requiresPlaceholderValues)
    }

    func testResolveRecipeWithPlaceholders() {
        let recipe = ProcessingRecipe(
            name: "Template",
            steps: [
                FASTQDerivativeOperation(
                    kind: .primerRemoval,
                    primerForwardSequence: "PLACEHOLDER",
                    primerReverseSequence: "PLACEHOLDER"
                ),
            ],
            placeholders: [
                RecipePlaceholder(key: "forwardPrimer", label: "Fwd", valueType: .sequence),
                RecipePlaceholder(key: "reversePrimer", label: "Rev", valueType: .sequence),
            ]
        )

        let resolved = recipe.resolved(with: [
            "forwardPrimer": "ATCGATCG",
            "reversePrimer": "GCTAGCTA",
        ])

        XCTAssertFalse(resolved.requiresPlaceholderValues)
        XCTAssertEqual(resolved.steps.first?.primerForwardSequence, "ATCGATCG")
        XCTAssertEqual(resolved.steps.first?.primerReverseSequence, "GCTAGCTA")
    }

    // MARK: - Before/After Comparison

    func testComparisonResultMetrics() {
        let before = FASTQDatasetStatistics(
            readCount: 200000, baseCount: 40_000_000,
            meanReadLength: 200, minReadLength: 50, maxReadLength: 301,
            medianReadLength: 200, n50ReadLength: 200,
            meanQuality: 28.0, q20Percentage: 90.0, q30Percentage: 75.0,
            gcContent: 0.45,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )

        let after = FASTQDatasetStatistics(
            readCount: 180000, baseCount: 36_000_000,
            meanReadLength: 200, minReadLength: 100, maxReadLength: 301,
            medianReadLength: 200, n50ReadLength: 200,
            meanQuality: 32.0, q20Percentage: 98.0, q30Percentage: 92.0,
            gcContent: 0.44,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )

        let comparison = FASTQComparisonResult(
            before: before,
            after: after,
            operation: FASTQDerivativeOperation(kind: .qualityTrim)
        )

        XCTAssertEqual(comparison.retentionPercentage, 90.0)
        XCTAssertEqual(comparison.qualityDelta, 4.0)
        XCTAssertEqual(comparison.lengthDelta, 0.0)
        XCTAssertEqual(comparison.readsRemoved, 20000)
    }

    func testComparisonSummaryText() {
        let before = FASTQDatasetStatistics(
            readCount: 100000, baseCount: 20_000_000,
            meanReadLength: 200, minReadLength: 50, maxReadLength: 301,
            medianReadLength: 200, n50ReadLength: 200,
            meanQuality: 25.0, q20Percentage: 85.0, q30Percentage: 60.0,
            gcContent: 0.45,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )

        let after = FASTQDatasetStatistics(
            readCount: 95000, baseCount: 19_000_000,
            meanReadLength: 200, minReadLength: 100, maxReadLength: 301,
            medianReadLength: 200, n50ReadLength: 200,
            meanQuality: 30.0, q20Percentage: 97.0, q30Percentage: 90.0,
            gcContent: 0.44,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )

        let comparison = FASTQComparisonResult(
            before: before,
            after: after,
            operation: FASTQDerivativeOperation(kind: .qualityTrim)
        )

        let text = comparison.summaryText
        XCTAssertTrue(text.contains("100,000"), text)
        XCTAssertTrue(text.contains("95,000"), text)
        XCTAssertTrue(text.contains("5,000 removed"), text)
        XCTAssertTrue(text.contains("95.0% retained"), text)
    }

    // MARK: - FASTQWriter Statistics Collector

    func testWriterCollectsStatistics() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterStats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let outputURL = tempDir.appendingPathComponent("test.fastq")
        let writer = FASTQWriter(url: outputURL)
        writer.statisticsCollector = FASTQStatisticsCollector()
        try writer.open()

        let records = [
            FASTQRecord(identifier: "read1", sequence: "ACGTACGT", quality: QualityScore(ascii: "IIIIIIII")),
            FASTQRecord(identifier: "read2", sequence: "TTTTAAAA", quality: QualityScore(ascii: "HHHHHHHH")),
            FASTQRecord(identifier: "read3", sequence: "GGGGCCCC", quality: QualityScore(ascii: "FFFFFFFF")),
        ]

        for record in records {
            try writer.write(record)
        }
        try writer.close()

        let stats = writer.finalizeStatistics()
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.readCount, 3)
        XCTAssertEqual(stats?.baseCount, 24)
        XCTAssertEqual(stats?.minReadLength, 8)
        XCTAssertEqual(stats?.maxReadLength, 8)
    }

    func testWriterWithoutCollectorReturnsNil() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterNoStats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let outputURL = tempDir.appendingPathComponent("test.fastq")
        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        try writer.write(FASTQRecord(identifier: "r1", sequence: "ACGT", quality: QualityScore(ascii: "IIII")))
        try writer.close()

        XCTAssertNil(writer.finalizeStatistics())
    }
}

import Foundation
import LungfishIO
@testable import LungfishWorkflow
import XCTest

/// 12S matching counts fragments, not records (Phase 2.1 lane L4, owner
/// decision of 2026-10-05). A merged read counts once. An unmerged pair
/// counts once when both mates give the identical call, with R2 read as the
/// reverse complement, and a pair whose mates disagree is left out of every
/// abundance figure and tallied.
///
/// Reference `human ACCTTGAC` and `dog GGGACCCT`, neither its own reverse
/// complement. Merged reads m1 and m2 are human, m3 is dog, m4 matches
/// nothing. Pair p1 is human on both mates, p2 is human on R1 and dog on R2,
/// p3 is human on R1 and nothing on R2, p4 matches nothing on either mate.
final class TwelveSFragmentCountingTests: XCTestCase {

    private var root: URL!
    private var referenceURL: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSFragmentCountingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        referenceURL = root.appendingPathComponent("reference.fa")
        outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACCTTGAC
        >dog (Canis lupus familiaris)|locus=12S|len=8
        GGGACCCT

        """.write(to: referenceURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Reads

    static let merged: [(name: String, sequence: String)] = [
        ("m1", "TTACCTTGACGG"),
        ("m2", "TTACCTTGACGG"),
        ("m3", "TTGGGACCCTGG"),
        ("m4", "TTAAAAAAAAGG"),
    ]

    /// R2 is written as sequenced, the reverse strand of the fragment.
    static let pairs: [(name: String, r1: String, r2: String)] = [
        ("p1", "CCACCTTGACAA", "AAGTCAAGGTCC"),
        ("p2", "CCACCTTGACAA", "AAAGGGTCCCCC"),
        ("p3", "CCACCTTGACAA", "CCTTTTTTTTAA"),
        ("p4", "CCAAAAAAAACC", "GGTTTTTTTTGG"),
    ]

    static func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    static func fastq(_ records: [(name: String, sequence: String)]) -> String {
        records.map { record($0.name, $0.sequence) }.joined()
    }

    // MARK: - Bundles

    private func bundle(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveDerivedManifest(
        in bundle: URL,
        payload: FASTQDerivativePayload,
        kind: FASTQDerivativeOperationKind,
        pairing: IngestionMetadata.PairingMode,
        classification: ReadClassification? = nil
    ) throws {
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: bundle.deletingPathExtension().lastPathComponent,
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "reads.fastq",
                payload: payload,
                lineage: [FASTQDerivativeOperation(kind: kind)],
                operation: FASTQDerivativeOperation(kind: kind),
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: pairing,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }

    /// L5c, a merge derivative with merged reads and the unmerged pairs as R1 and R2 files.
    private func writeMergeDerivative(
        named name: String = "SampleA",
        merged: [(name: String, sequence: String)] = TwelveSFragmentCountingTests.merged,
        pairs: [(name: String, r1: String, r2: String)] = TwelveSFragmentCountingTests.pairs,
        r1Records: String? = nil,
        r2Records: String? = nil
    ) throws -> URL {
        let url = try bundle(name)
        try Self.fastq(merged).write(to: url.appendingPathComponent("merged.fastq"), atomically: true, encoding: .utf8)
        let r1 = r1Records ?? pairs.map { Self.record($0.name, $0.r1) }.joined()
        let r2 = r2Records ?? pairs.map { Self.record($0.name, $0.r2) }.joined()
        try r1.write(to: url.appendingPathComponent("unmerged_R1.fastq"), atomically: true, encoding: .utf8)
        try r2.write(to: url.appendingPathComponent("unmerged_R2.fastq"), atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: merged.count),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: pairs.count),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: pairs.count),
        ])
        try saveDerivedManifest(
            in: url, payload: .fullMixed(classification), kind: .pairedEndMerge, pairing: .pairedEnd,
            classification: classification
        )
        return url
    }

    /// L5b, a `fullPaired` derivative, the pairs as R1 and R2 files.
    private func writePairedDerivative(named name: String = "Pairs") throws -> URL {
        let url = try bundle(name)
        try Self.pairs.map { Self.record($0.name, $0.r1) }.joined()
            .write(to: url.appendingPathComponent("sample_R1.fastq"), atomically: true, encoding: .utf8)
        try Self.pairs.map { Self.record($0.name, $0.r2) }.joined()
            .write(to: url.appendingPathComponent("sample_R2.fastq"), atomically: true, encoding: .utf8)
        try saveDerivedManifest(
            in: url, payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
            kind: .interleaveReformat, pairing: .pairedEnd
        )
        return url
    }

    /// L2, a root whose one file holds every pair as R1 then R2.
    private func writeInterleavedRoot(named name: String = "Interleaved") throws -> URL {
        let url = try bundle(name)
        let file = url.appendingPathComponent("reads.fastq")
        try Self.pairs.map { Self.record("\($0.name)/1", $0.r1) + Self.record("\($0.name)/2", $0.r2) }.joined()
            .write(to: file, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected)),
            for: file
        )
        return url
    }

    /// L3, a root whose one file holds the merged reads then the pairs, with
    /// the sidecar classification every role naming that file.
    private func writeMixedRoot(named name: String = "Mixed") throws -> URL {
        let url = try bundle(name)
        let file = url.appendingPathComponent("reads.fastq")
        let text = Self.fastq(Self.merged)
            + Self.pairs.map { Self.record("\($0.name)/1", $0.r1) + Self.record("\($0.name)/2", $0.r2) }.joined()
        try text.write(to: file, atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "reads.fastq", role: .merged, readCount: Self.merged.count),
            .init(filename: "reads.fastq", role: .pairedR1, readCount: Self.pairs.count),
            .init(filename: "reads.fastq", role: .pairedR2, readCount: Self.pairs.count),
        ])
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected),
                readClassification: classification
            ),
            for: file
        )
        return url
    }

    // MARK: - Running

    private func run(
        _ inputs: [URL],
        outputName: String = "fragments-12s",
        threads: Int = 2,
        progress: TwelveSAmpliconMatchingWorkflow.ProgressHandler? = nil
    ) async throws -> TwelveSAmpliconResultBundleData {
        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: inputs,
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: outputName,
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                matchingMode: .illuminaExact,
                threads: threads,
                runChimeraReview: false
            ),
            progressHandler: progress
        )
        return try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
    }

    private func count(_ loaded: TwelveSAmpliconResultBundleData, _ species: String, sample: String) -> Int? {
        loaded.scientificNameRows.first { $0.scientificName == species }?.count(forSample: sample)
    }

    // MARK: - Tests

    func testMergeDerivativeCountsEachFragmentOnce() async throws {
        let bundleURL = try writeMergeDerivative()

        let loaded = try await run([bundleURL])

        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "SampleA" })
        XCTAssertEqual(sample.inputReads, 8, "four merged reads and four pairs are eight fragments")
        XCTAssertEqual(sample.exactMatchReads, 4, "m1, m2, m3 and the concordant pair p1")
        XCTAssertEqual(sample.unresolvedReads, 2, "m4 and the pair p4, unresolved on both mates")
        XCTAssertEqual(sample.ambiguousExactReads, 0)
        XCTAssertEqual(sample.reassignedReads, 0)
        XCTAssertEqual(sample.exactMatchPercent, 50, accuracy: 0.0001)
        XCTAssertEqual(count(loaded, "Homo sapiens", sample: "SampleA"), 3)
        XCTAssertEqual(count(loaded, "Canis lupus familiaris", sample: "SampleA"), 1)
        XCTAssertEqual(loaded.readFate.totalReads, 8)
        XCTAssertEqual(loaded.readFate.exactMatchReads, 4)
        XCTAssertEqual(loaded.readFate.unresolvedReads, 2)
        XCTAssertEqual(sample.discordantPairs, 2, "p2 names two targets and p3 has one mate unresolved")
        XCTAssertEqual(
            sample.exactMatchReads + sample.reassignedReads + sample.unresolvedReads + sample.discordantPairs,
            sample.inputReads,
            "every fragment is exact, reassigned, unresolved or left out"
        )
        XCTAssertEqual(loaded.readFate.discordantPairs, 2)
        XCTAssertEqual(loaded.readFate.discordantPairsByReason, ["different_targets": 1, "one_mate_unresolved": 1])

        XCTAssertEqual(
            Set(loaded.unresolvedSequences.map(\.sequence)),
            ["TTAAAAAAAAGG", "CCAAAAAAAACC"],
            "a discordant pair is listed nowhere, and an unresolved pair is listed under its R1 sequence"
        )
        let pairRow = try XCTUnwrap(loaded.unresolvedSequences.first { $0.sequence == "CCAAAAAAAACC" })
        XCTAssertEqual(pairRow.readCount, 1)
        XCTAssertEqual(pairRow.sampleCounts, ["SampleA": 1])
        XCTAssertEqual(pairRow.note, "unmerged pairs, R1 shown")
        let mergedRow = try XCTUnwrap(loaded.unresolvedSequences.first { $0.sequence == "TTAAAAAAAAGG" })
        XCTAssertNil(mergedRow.note)
    }

    func testPairedDerivativeInterleavedRootAndMixedRootAgreeWithTheMergeDerivative() async throws {
        let paired = try await run([try writePairedDerivative()], outputName: "paired-12s")
        let interleaved = try await run([try writeInterleavedRoot()], outputName: "interleaved-12s")
        let mixed = try await run([try writeMixedRoot()], outputName: "mixed-12s")

        for (loaded, sampleID) in [(paired, "Pairs"), (interleaved, "Interleaved")] {
            let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == sampleID }, sampleID)
            XCTAssertEqual(sample.inputReads, 4, sampleID)
            XCTAssertEqual(sample.exactMatchReads, 1, sampleID)
            XCTAssertEqual(sample.unresolvedReads, 1, sampleID)
            XCTAssertEqual(count(loaded, "Homo sapiens", sample: sampleID), 1, sampleID)
            XCTAssertEqual(count(loaded, "Canis lupus familiaris", sample: sampleID), 0, sampleID)
            XCTAssertEqual(loaded.unresolvedSequences.map(\.sequence), ["CCAAAAAAAACC"], sampleID)
        }

        let mixedSample = try XCTUnwrap(mixed.samples.first { $0.sampleID == "Mixed" })
        XCTAssertEqual(mixedSample.inputReads, 8)
        XCTAssertEqual(mixedSample.exactMatchReads, 4)
        XCTAssertEqual(mixedSample.unresolvedReads, 2)
        XCTAssertEqual(count(mixed, "Homo sapiens", sample: "Mixed"), 3)
        XCTAssertEqual(count(mixed, "Canis lupus familiaris", sample: "Mixed"), 1)
        XCTAssertEqual(Set(mixed.unresolvedSequences.map(\.sequence)), ["TTAAAAAAAAGG", "CCAAAAAAAACC"])
    }

    func testMixedRootRecordsTheSplitByNameAsAProvenanceStep() async throws {
        let bundleURL = try writeMixedRoot()

        let loaded = try await run([bundleURL], outputName: "mixed-step-12s")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: loaded.bundleURL))
        let split = try XCTUnwrap(provenance.steps.first { $0.toolName == "Lungfish Read-Set Split" })
        XCTAssertEqual(split.argv.first, "Lungfish Read-Set Split")
        XCTAssertTrue(split.inputs.contains { $0.path == bundleURL.appendingPathComponent("reads.fastq").path })
        XCTAssertEqual(split.outputs.count, 3, "R1, R2 and the merged reads")
        XCTAssertEqual(split.resolvedOptions["intermediateOutputs"], .boolean(true))
        XCTAssertEqual(split.resolvedOptions["outputsRemovedAfterRun"], .boolean(true))
        XCTAssertTrue(split.outputs.allSatisfy { $0.checksumSHA256 != nil }, "the step keeps its historically true record")
        XCTAssertFalse(
            provenance.files.contains { $0.path.contains("12s-scratch") },
            "the run-level roll-up does not advertise files the run removed"
        )
        XCTAssertEqual(provenance.argv.prefix(3), ["lungfish-cli", "fastq", "12s-match"])
        XCTAssertTrue(provenance.argv.contains(bundleURL.path), "the replay names the bundle the user chose")
        XCTAssertFalse(provenance.argv.contains { $0.contains("12s-scratch") }, "the replay never names a scratch file")

        guard case let .array(plans)? = provenance.options.resolvedDefaults["readSetPlans"],
              case let .dictionary(plan)? = plans.first else {
            return XCTFail("the run that read pairs records how each input was read")
        }
        XCTAssertEqual(plan["sourceLayout"], .string("mixed_file"))
        XCTAssertEqual(plan["steps"], .integer(1))
        guard case let .dictionary(fragmentCounts)? = provenance.options.resolvedDefaults["fragmentCounts"],
              case let .dictionary(mixedCounts)? = fragmentCounts["Mixed"] else {
            return XCTFail("the run that read pairs records what became of each sample's fragments")
        }
        XCTAssertEqual(mixedCounts["inputFragments"], .integer(8))
        XCTAssertEqual(mixedCounts["singleReadFragments"], .integer(4))
        XCTAssertEqual(mixedCounts["pairedFragments"], .integer(4))
        XCTAssertEqual(mixedCounts["discordantPairs"], .integer(2))
        XCTAssertEqual(
            mixedCounts["discordantPairsByReason"],
            .dictionary(["different_targets": .integer(1), "one_mate_unresolved": .integer(1)])
        )
    }

    func testRootHoldingOnlyAPreviewIsRefusedWithOneLineThatSaysWhatToDo() async throws {
        let bundleURL = try bundle("PreviewOnly")
        try Self.fastq(Array(Self.merged.prefix(1))).write(
            to: bundleURL.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8
        )

        do {
            _ = try await run([bundleURL], outputName: "preview-only-12s")
            XCTFail("a root that holds only its preview must be refused")
        } catch let error as TwelveSAmpliconMatchingError {
            XCTAssertEqual(error, .noReadsInInput(bundleURL.standardizedFileURL.path))
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(message.contains("\n"))
            XCTAssertTrue(message.contains("Re-import the FASTQ file"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("preview-only-12s.lungfish12s").path))
    }

    func testPairWeightComesFromTheSizeTokenOfR1() async throws {
        let pair = Self.pairs[0]
        let bundleURL = try writeMergeDerivative(
            named: "Counted",
            merged: [],
            pairs: [pair],
            r1Records: Self.record("\(pair.name);size=3", pair.r1),
            r2Records: Self.record("\(pair.name);size=3", pair.r2)
        )

        let loaded = try await run([bundleURL], outputName: "counted-pairs-12s")

        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "Counted" })
        XCTAssertEqual(sample.inputReads, 3)
        XCTAssertEqual(sample.exactMatchReads, 3)
        XCTAssertEqual(count(loaded, "Homo sapiens", sample: "Counted"), 3)
    }

    func testUnequalMateFilesAreRefused() async throws {
        let bundleURL = try writeMergeDerivative(
            named: "Short",
            r2Records: Self.pairs.dropLast().map { Self.record($0.name, $0.r2) }.joined()
        )

        do {
            _ = try await run([bundleURL], outputName: "short-12s")
            XCTFail("an R2 file with fewer records than R1 must stop the run")
        } catch let error as TwelveSAmpliconMatchingError {
            guard case let .mateMismatch(detail) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(detail.contains("different numbers of records"), detail)
        }
    }

    func testMateNameMismatchIsRefused() async throws {
        let bundleURL = try writeMergeDerivative(
            named: "Misnamed",
            r2Records: Self.pairs.map { Self.record("other-\($0.name)", $0.r2) }.joined()
        )

        do {
            _ = try await run([bundleURL], outputName: "misnamed-12s")
            XCTFail("mates whose names do not match must stop the run")
        } catch let error as TwelveSAmpliconMatchingError {
            guard case let .mateMismatch(detail) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(detail.contains("same fragments in the same order"), detail)
        }
    }

    func testProgressNamesTheFragmentsAndTheLeftOutPairs() async throws {
        let bundleURL = try writeMergeDerivative()
        let recorder = FragmentProgressRecorder()

        _ = try await run([bundleURL], outputName: "progress-12s") { _, message in recorder.append(message) }

        let line = try XCTUnwrap(recorder.messages().first { $0.hasPrefix("Counted 8 fragments") })
        XCTAssertTrue(line.contains("4 merged or single reads and 4 pairs"), line)
        XCTAssertTrue(line.contains("Left out 2 discordant pairs"), line)
        XCTAssertTrue(line.contains("1 different targets"), line)
        XCTAssertTrue(line.contains("1 one mate unresolved"), line)
    }

    func testLooseMergedFileStaysOneReadPerRecord() async throws {
        let fastqURL = root.appendingPathComponent("loose.fastq")
        try Self.fastq(Self.merged).write(to: fastqURL, atomically: true, encoding: .utf8)

        let loaded = try await run([fastqURL], outputName: "loose-12s")

        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "loose" })
        XCTAssertEqual(sample.inputReads, 4)
        XCTAssertEqual(sample.exactMatchReads, 3)
        XCTAssertEqual(sample.unresolvedReads, 1)
        XCTAssertEqual(sample.discordantPairs, 0)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: loaded.bundleURL))
        XCTAssertNil(provenance.options.resolvedDefaults["readSetPlans"], "a sample of single reads records nothing new")
        XCTAssertNil(provenance.options.resolvedDefaults["fragmentCounts"])
        XCTAssertFalse(provenance.steps.contains { $0.toolName.hasPrefix("Lungfish Read-Set") })
    }
}

private final class FragmentProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ message: String) {
        lock.lock()
        values.append(message)
        lock.unlock()
    }

    func messages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

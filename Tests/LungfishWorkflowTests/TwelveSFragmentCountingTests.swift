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

    /// `read-fate.json` as written, so a key the models do not read yet is seen.
    private func readFateJSON(_ loaded: TwelveSAmpliconResultBundleData) throws -> [String: Any] {
        let data = try Data(contentsOf: loaded.artifacts.readFateURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The `readSetPlans` entry the run recorded for `input`.
    private func recordedPlan(for input: URL, in loaded: TwelveSAmpliconResultBundleData) throws -> [String: ParameterValue] {
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: loaded.bundleURL))
        guard case let .array(plans)? = provenance.options.resolvedDefaults["readSetPlans"] else {
            return try XCTUnwrap(nil, "the run recorded no read-set plans")
        }
        for case let .dictionary(plan) in plans {
            if case let .file(url)? = plan["input"], url.standardizedFileURL.path == input.standardizedFileURL.path {
                return plan
            }
        }
        return try XCTUnwrap(nil, "no plan recorded for \(input.lastPathComponent)")
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
            try readFateJSON(loaded)["pairedFragments"] as? Int, 4,
            "the read fate records the pairs read, so the viewport can name its counts fragments (review B, N1)"
        )

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

    /// Mates whose names carry mate numbers that say they are not one
    /// fragment show R1 and R2 files out of step, the only names the owner's
    /// N2 rule refuses (`FASTQPairInterleaver.recordedMates`). Names with no
    /// mate number are paired by position instead (review A, S2).
    func testMateNumbersThatContradictAreRefused() async throws {
        let bundleURL = try writeMergeDerivative(
            named: "Misnumbered",
            r1Records: Self.pairs.map { Self.record("\($0.name)/1", $0.r1) }.joined(),
            r2Records: Self.pairs.reversed().map { Self.record("\($0.name)/2", $0.r2) }.joined()
        )

        do {
            _ = try await run([bundleURL], outputName: "misnumbered-12s")
            XCTFail("mates whose mate numbers contradict must stop the run")
        } catch let error as TwelveSAmpliconMatchingError {
            guard case let .mateMismatch(detail) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(detail.contains("p1/1"), detail)
            XCTAssertTrue(detail.contains("p4/2"), detail)
            XCTAssertTrue(detail.contains("same fragments in the same order"), detail)
        }
    }

    func testProgressNamesTheFragmentsAndTheLeftOutPairs() async throws {
        let bundleURL = try writeMergeDerivative()
        let recorder = FragmentProgressRecorder()

        _ = try await run([bundleURL], outputName: "progress-12s") { _, message in recorder.append(message) }

        let line = try XCTUnwrap(recorder.messages().first { $0.hasPrefix("Counted 8 fragments") })
        XCTAssertEqual(
            line,
            "Counted 8 fragments, 4 merged or single reads and 4 pairs. "
                + "Left out 2 discordant pairs (1 pair with different targets, 1 pair with one mate unresolved).",
            "each reason names its pairs (review B, N1)"
        )
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
        XCTAssertEqual(try readFateJSON(loaded)["pairedFragments"] as? Int, 0, "a run of merged reads read no pair")
    }

    // MARK: - Review fixes (Phase 2.1 round F4)

    /// Review A, S1. A file named inside a bundle is read as that file alone,
    /// as the FASTQ subcommands and TaxTriage read it, so naming the merged
    /// file of a merge derivative counts its merged reads and none of the
    /// pairs beside it. Naming the bundle still counts every fragment.
    func testNamingTheMergedFileOfABundleCountsThatFileAlone() async throws {
        let bundleURL = try writeMergeDerivative()
        let mergedURL = bundleURL.appendingPathComponent("merged.fastq")

        let loaded = try await run([bundleURL, mergedURL], outputName: "named-file-12s")

        let merged = try XCTUnwrap(loaded.samples.first { $0.sampleID == "merged" })
        XCTAssertEqual(merged.inputReads, 4, "the four merged reads and none of the unmerged pairs")
        XCTAssertEqual(merged.exactMatchReads, 3)
        XCTAssertEqual(merged.unresolvedReads, 1)
        XCTAssertEqual(merged.discordantPairs, 0)
        XCTAssertEqual(count(loaded, "Homo sapiens", sample: "merged"), 2)
        XCTAssertEqual(count(loaded, "Canis lupus familiaris", sample: "merged"), 1)

        let whole = try XCTUnwrap(loaded.samples.first { $0.sampleID == "SampleA" })
        XCTAssertEqual(whole.inputReads, 8, "the bundle is still four merged reads and four pairs")
        XCTAssertEqual(whole.exactMatchReads, 4)
        XCTAssertEqual(whole.discordantPairs, 2)
        XCTAssertEqual(count(loaded, "Homo sapiens", sample: "SampleA"), 3)

        XCTAssertEqual(try recordedPlan(for: mergedURL, in: loaded)["sourceLayout"], .string("single_end_file"))
        XCTAssertEqual(try recordedPlan(for: bundleURL, in: loaded)["sourceLayout"], .string("mixed_derivative"))
        let provenanceText = try String(contentsOf: loaded.artifacts.provenanceURL, encoding: .utf8)
        XCTAssertFalse(provenanceText.contains("lungfish-12s-named-input"), "no record names a link the run made")
    }

    /// Review A, S1. A bundle and a loose file are planned as named, a file
    /// inside a bundle as that file alone, and the preview of a virtual
    /// bundle, a few reads of the sample, as its bundle (the rule of
    /// `TaxTriageReadSetPlanner.bundleToPlan`).
    func testANamedInputIsPlannedByWhereItLies() throws {
        let merge = try writeMergeDerivative()
        let subset = try bundle("Subset")
        try Self.fastq(Self.merged)
            .write(to: subset.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try saveDerivedManifest(
            in: subset, payload: .subset(readIDListFilename: "read-ids.txt"), kind: .subsampleCount, pairing: .singleEnd
        )
        let loose = root.appendingPathComponent("loose.fastq")
        try Self.fastq(Self.merged).write(to: loose, atomically: true, encoding: .utf8)
        let merged = merge.appendingPathComponent("merged.fastq")
        let preview = subset.appendingPathComponent("preview.fastq")

        XCTAssertEqual(ReadSetNamedInput(merge), .asNamed(merge.standardizedFileURL))
        XCTAssertEqual(ReadSetNamedInput(loose), .asNamed(loose.standardizedFileURL))
        XCTAssertEqual(ReadSetNamedInput(merged), .fileAlone(merged.standardizedFileURL))
        XCTAssertEqual(
            ReadSetNamedInput(merge.appendingPathComponent("unmerged_R2.fastq")),
            .fileAlone(merge.appendingPathComponent("unmerged_R2.fastq").standardizedFileURL)
        )
        guard case let .previewOf(bundleURL, previewURL) = ReadSetNamedInput(preview) else {
            return XCTFail("the preview of a virtual bundle names its bundle")
        }
        XCTAssertEqual(bundleURL.standardizedFileURL.path, subset.standardizedFileURL.path)
        XCTAssertEqual(previewURL, preview.standardizedFileURL)
    }

    /// Review A, S1. The one file of a root that mixes merged reads and
    /// pairs, named inside its bundle, is split by name as that file, and
    /// the split step names the file itself.
    func testNamingTheFileOfAMixedRootSplitsThatFile() async throws {
        let fileURL = try writeMixedRoot().appendingPathComponent("reads.fastq")

        let loaded = try await run([fileURL], outputName: "named-mixed-12s")

        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "reads" })
        XCTAssertEqual(sample.inputReads, 8)
        XCTAssertEqual(sample.exactMatchReads, 4)
        XCTAssertEqual(sample.unresolvedReads, 2)
        XCTAssertEqual(sample.discordantPairs, 2)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: loaded.bundleURL))
        let split = try XCTUnwrap(provenance.steps.first { $0.toolName == "Lungfish Read-Set Split" })
        XCTAssertEqual(split.inputs.map(\.path), [fileURL.path])
        XCTAssertTrue(split.argv.contains(fileURL.path), "\(split.argv)")
        let provenanceText = try String(contentsOf: loaded.artifacts.provenanceURL, encoding: .utf8)
        XCTAssertFalse(provenanceText.contains("lungfish-12s-named-input"), "no record names a link the run made")
    }

    /// Review A, S2. Mates of a recorded pair named `x.1` and `x.2`, or
    /// `x_1` and `x_2`, as legacy merge bundles name them, are the two mates
    /// of one fragment, as the materializer, Kraken2 and the assemblers read
    /// them (`FASTQPairInterleaver.recordedMates`).
    func testRecordedMatesNumberedWithDotsOrUnderscoresAreCounted() async throws {
        let dotted = try writeMergeDerivative(
            named: "Dotted",
            r1Records: Self.pairs.enumerated().map { Self.record("SRR1.\($0.offset + 1).1", $0.element.r1) }.joined(),
            r2Records: Self.pairs.enumerated().map { Self.record("SRR1.\($0.offset + 1).2", $0.element.r2) }.joined()
        )
        let underscored = try writeMergeDerivative(
            named: "Underscored",
            r1Records: Self.pairs.map { Self.record("\($0.name)_1", $0.r1) }.joined(),
            r2Records: Self.pairs.map { Self.record("\($0.name)_2", $0.r2) }.joined()
        )

        let loaded = try await run([dotted, underscored], outputName: "numbered-12s")

        for sampleID in ["Dotted", "Underscored"] {
            let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == sampleID }, sampleID)
            XCTAssertEqual(sample.inputReads, 8, sampleID)
            XCTAssertEqual(sample.exactMatchReads, 4, sampleID)
            XCTAssertEqual(sample.unresolvedReads, 2, sampleID)
            XCTAssertEqual(sample.discordantPairs, 2, sampleID)
            XCTAssertEqual(count(loaded, "Homo sapiens", sample: sampleID), 3, sampleID)
        }
    }

    /// Review A, S2. Mates whose names carry no mate number are paired by
    /// position, as the materializer pairs them, with the same warning.
    func testRecordedMatesWithoutMateNumbersArePairedByPositionWithAWarning() async throws {
        let bundleURL = try writeMergeDerivative(
            named: "Unmarked",
            r1Records: Self.pairs.map { Self.record("left-\($0.name)", $0.r1) }.joined(),
            r2Records: Self.pairs.map { Self.record("right-\($0.name)", $0.r2) }.joined()
        )
        let recorder = FragmentProgressRecorder()

        let loaded = try await run([bundleURL], outputName: "unmarked-12s") { _, message in recorder.append(message) }

        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "Unmarked" })
        XCTAssertEqual(sample.inputReads, 8)
        XCTAssertEqual(sample.discordantPairs, 2)
        XCTAssertEqual(count(loaded, "Homo sapiens", sample: "Unmarked"), 3)
        let warning = try XCTUnwrap(recorder.messages().first { $0.contains("paired by position") })
        XCTAssertEqual(
            warning,
            "Warning: 4 of the 4 record pairs of unmerged_R1.fastq and unmerged_R2.fastq carry no mate number "
                + "in their names, the first being 'left-p1' and 'right-p1', so they were paired by position."
        )
    }

    /// Review A, N2. The split runs in process and its files live in the
    /// scratch folder the run removes, so its step keeps the argv that
    /// describes it and records no durable replay, as the Kraken2 read-set
    /// steps do.
    func testReadSetSplitStepRecordsNoDurableReplay() async throws {
        let loaded = try await run([try writeMixedRoot()], outputName: "mixed-replay-12s")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: loaded.bundleURL))
        let split = try XCTUnwrap(provenance.steps.first { $0.toolName == "Lungfish Read-Set Split" })
        XCTAssertEqual(Array(split.argv.prefix(2)), ["Lungfish Read-Set Split", "split_by_name"])
        XCTAssertNil(split.durableReplayArgv, "the step is not a command, and its files are gone after the run")
        XCTAssertEqual(split.reproducibleCommand, split.argv.map(shellEscape).joined(separator: " "))
    }

    /// Review A, N5. An orphan R2, a single read whose name marks it as mate
    /// 2 (`/2` or a Casava ` 2:` comment), is the reverse strand of its
    /// fragment, so it is read as its reverse complement, as the R2 of a pair
    /// is. An orphan R1, an orphan with no mate mark and a merged read are
    /// read as sequenced.
    func testOrphanR2IsReadAsItsReverseComplement() async throws {
        let url = try bundle("Repaired")
        let humanForward = "TTACCTTGACGG"
        let humanReverse = "CCGTCAAGGTAA"
        try Self.record("m9/2", humanForward)
            .write(to: url.appendingPathComponent("merged.fastq"), atomically: true, encoding: .utf8)
        try Self.record("p1", Self.pairs[0].r1)
            .write(to: url.appendingPathComponent("unmerged_R1.fastq"), atomically: true, encoding: .utf8)
        try Self.record("p1", Self.pairs[0].r2)
            .write(to: url.appendingPathComponent("unmerged_R2.fastq"), atomically: true, encoding: .utf8)
        try (Self.record("o1/2", humanReverse)
            + Self.record("o2 2:N:0:1", humanReverse)
            + Self.record("o3/1", humanForward)
            + Self.record("o4", humanReverse))
            .write(to: url.appendingPathComponent("orphans.fastq"), atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 1),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
            .init(filename: "orphans.fastq", role: .unpaired, readCount: 4),
        ])
        try saveDerivedManifest(
            in: url, payload: .fullMixed(classification), kind: .pairedEndMerge, pairing: .pairedEnd,
            classification: classification
        )

        let loaded = try await run([url], outputName: "orphans-12s")

        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "Repaired" })
        XCTAssertEqual(sample.inputReads, 6, "one pair, one merged read and four orphans")
        XCTAssertEqual(
            count(loaded, "Homo sapiens", sample: "Repaired"), 5,
            "the pair, the merged read, the two orphan R2 reads and the orphan R1"
        )
        XCTAssertEqual(sample.exactMatchReads, 5)
        XCTAssertEqual(sample.unresolvedReads, 1, "the orphan without a mate mark is read as sequenced")
        XCTAssertEqual(loaded.unresolvedSequences.map(\.sequence), [humanReverse])
        XCTAssertEqual(sample.discordantPairs, 0)
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

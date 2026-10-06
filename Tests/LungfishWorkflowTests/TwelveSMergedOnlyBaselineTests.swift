import Foundation
import LungfishIO
@testable import LungfishWorkflow
import XCTest

/// Pins every result file a merged-only 12S run writes, byte for byte,
/// to the output captured at commit b14dabdb0, before fragment counting
/// (Phase 2.1 lane L4). A merged read is one fragment before and after that
/// change, so these four fixtures must keep their tables. The only allowed
/// differences are the fragment-counting additions, the `discordant_pairs`
/// column of `samples.tsv` and the `discordantPairs*` keys of
/// `read-fate.json`, which the comparison removes before it compares.
///
/// Set `LUNGFISH_TWELVES_BASELINE_CAPTURE_DIR` to write the files instead of
/// comparing them. That is how the literals below were captured.
final class TwelveSMergedOnlyBaselineTests: XCTestCase {

    private struct Fixture: Sendable {
        let name: String
        let reference: String
        let reads: String
        let reviewer: any TwelveSChimeraReviewing
        let configure: @Sendable (URL, URL, URL) -> TwelveSAmpliconMatchingConfiguration
    }

    private static let plainReference = """
    >human (Homo sapiens)|locus=12S|len=8|n_refs=2|n_species=1|primer_pairs=12S_vert
    ACGTACGT
    >dog (Canis lupus familiaris)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert
    GGGGCCCC

    """

    private static let plainReads = """
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

    """

    private static let countedReference = """
    >human (Homo sapiens)|locus=12S|len=8
    ACGTACGT

    """

    private static let countedReads = """
    @exact;size=7
    TTACGTACGTGG
    +
    IIIIIIIIIIII
    @unresolved;size=3
    TTAAAAAAAAAGG
    +
    IIIIIIIIIIII

    """

    private static let reassignReference = """
    >human-long (Homo sapiens)|locus=12S|len=10|n_refs=1|n_species=1|primer_pairs=12S_vert
    ACGTACGTAA
    >human-short (Homo sapiens)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert
    TTTTGGGG
    >pan-short (Pan troglodytes)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert
    TTTTGGGG

    """

    private static let reassignReads = """
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

    """

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "plain",
            reference: plainReference,
            reads: plainReads,
            reviewer: BaselineChimeraReviewer(statuses: ["unresolved_1": .candidate]),
            configure: { fastq, reference, outputDirectory in
                TwelveSAmpliconMatchingConfiguration(
                    inputFASTQs: [fastq],
                    referenceFASTA: reference,
                    outputDirectory: outputDirectory,
                    outputName: "sampleA-12s",
                    minimumSoftClipBases: 2,
                    maximumIndelBases: 2,
                    matchingMode: .ontIndel,
                    threads: 2
                )
            }
        ),
        Fixture(
            name: "counted",
            reference: countedReference,
            reads: countedReads,
            reviewer: TwelveSNoOpChimeraReviewer(),
            configure: { fastq, reference, outputDirectory in
                TwelveSAmpliconMatchingConfiguration(
                    inputFASTQs: [fastq],
                    referenceFASTA: reference,
                    outputDirectory: outputDirectory,
                    outputName: "sampleA-counted-12s",
                    minimumSoftClipBases: 2,
                    maximumIndelBases: 2,
                    matchingMode: .illuminaExact,
                    runChimeraReview: false
                )
            }
        ),
        Fixture(
            name: "reassign",
            reference: reassignReference,
            reads: reassignReads,
            reviewer: TwelveSNoOpChimeraReviewer(),
            configure: { fastq, reference, outputDirectory in
                TwelveSAmpliconMatchingConfiguration(
                    inputFASTQs: [fastq],
                    referenceFASTA: reference,
                    outputDirectory: outputDirectory,
                    outputName: "reassign-12s",
                    minimumSoftClipBases: 2,
                    maximumIndelBases: 2,
                    threads: 1
                )
            }
        ),
        Fixture(
            name: "reassign-conservative",
            reference: reassignReference,
            reads: reassignReads,
            reviewer: TwelveSNoOpChimeraReviewer(),
            configure: { fastq, reference, outputDirectory in
                TwelveSAmpliconMatchingConfiguration(
                    inputFASTQs: [fastq],
                    referenceFASTA: reference,
                    outputDirectory: outputDirectory,
                    outputName: "reassign-conservative-12s",
                    minimumSoftClipBases: 2,
                    maximumIndelBases: 2,
                    threads: 1,
                    ambiguityResolution: .conservative(minFoldRatio: 2.0, absoluteFloor: 10)
                )
            }
        ),
    ]

    /// Files that record the run itself rather than its result, and so differ
    /// between runs. The `provenance/` sidecars and the `vsearch/` folder are
    /// skipped by prefix.
    private static let volatileFiles: Set<String> = [
        ".lungfish-provenance.json",
    ]

    /// JSON keys that hold a time of writing.
    private static let volatileJSONKeys: Set<String> = ["createdAt"]

    func testMergedOnlyResultFilesMatchTheBaseline() async throws {
        let captureDirectory = ProcessInfo.processInfo.environment["LUNGFISH_TWELVES_BASELINE_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        for fixture in Self.fixtures {
            let files = try await Self.resultFiles(for: fixture)
            if let captureDirectory {
                try Self.capture(files, fixture: fixture.name, into: captureDirectory)
                continue
            }
            let expected = try XCTUnwrap(Self.baseline[fixture.name], "no baseline for \(fixture.name)")
            XCTAssertEqual(
                files.keys.sorted(), expected.keys.sorted(),
                "\(fixture.name): the result bundle holds a different set of files"
            )
            for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                guard let expectedContent = expected[path] else { continue }
                if path.hasSuffix(".json") {
                    XCTAssertEqual(
                        try Self.normalizedJSON(content), try Self.normalizedJSON(expectedContent),
                        "\(fixture.name)/\(path) differs from the baseline"
                    )
                } else {
                    XCTAssertEqual(
                        Self.normalizedText(content, path: path), Self.normalizedText(expectedContent, path: path),
                        "\(fixture.name)/\(path) differs from the baseline"
                    )
                }
            }
        }
        if captureDirectory != nil {
            throw XCTSkip("Baseline captured, nothing compared.")
        }
    }

    // MARK: - Running a fixture

    private static func resultFiles(for fixture: Fixture) async throws -> [String: String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSMergedOnlyBaseline-\(fixture.name)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let fastqURL = root.appendingPathComponent("sampleA.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try fixture.reference.write(to: referenceURL, atomically: true, encoding: .utf8)
        try fixture.reads.write(to: fastqURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: fixture.reviewer)
            .run(fixture.configure(fastqURL, referenceURL, outputDirectory))

        var files: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: result.bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relativePath = url.standardizedFileURL.path
                .replacingOccurrences(of: result.bundleURL.standardizedFileURL.path + "/", with: "")
            guard !volatileFiles.contains(relativePath),
                  !relativePath.hasPrefix("vsearch/"),
                  !relativePath.hasPrefix("provenance/") else { continue }
            files[relativePath] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    private static func capture(_ files: [String: String], fixture: String, into directory: URL) throws {
        for (path, content) in files {
            let url = directory.appendingPathComponent(fixture, isDirectory: true).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Normalization

    /// `samples.tsv` without the fragment-counting column, every other text
    /// file as it is.
    static func normalizedText(_ content: String, path: String) -> String {
        guard path == "samples.tsv" else { return content }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return content }
        let columns = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard let dropped = columns.firstIndex(where: { $0 == "discordant_pairs" }) else { return content }
        lines = lines.map { line in
            guard !line.isEmpty else { return line }
            var fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if dropped < fields.count { fields.remove(at: dropped) }
            return fields.joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    /// The JSON object without times of writing and without the
    /// fragment-counting keys.
    static func normalizedJSON(_ content: String) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(content.utf8))
        guard var dictionary = object as? [String: Any] else {
            throw XCTSkip("not a JSON object")
        }
        for key in dictionary.keys where volatileJSONKeys.contains(key) || key.hasPrefix("discordantPairs") {
            dictionary.removeValue(forKey: key)
        }
        return dictionary as NSDictionary
    }

    // MARK: - Baseline captured at b14dabdb0

    private static let baseline: [String: [String: String]] = [
        "plain": [
            "12s-result.json": "{\n  \"alternateMatchesTablePath\" : \"target-alternate-matches.tsv\",\n  \"analysisName\" : \"sampleA-12s\",\n  \"countMatrixPath\" : \"sample-target-counts.tsv\",\n  \"createdAt\" : \"2026-10-06T23:01:18Z\",\n  \"kind\" : \"12s-amplicon-match\",\n  \"outputName\" : \"sampleA-12s\",\n  \"provenancePath\" : \".lungfish-provenance.json\",\n  \"readFatePath\" : \"read-fate.json\",\n  \"referencePath\" : \"reference.fa\",\n  \"resolvedSampleMetadataPath\" : \"metadata\\/resolved-sample-metadata.tsv\",\n  \"sampleMetadataManifestPath\" : \"metadata\\/sample-metadata-manifest.json\",\n  \"sampleTablePath\" : \"samples.tsv\",\n  \"schemaVersion\" : 1,\n  \"targetTablePath\" : \"targets.tsv\",\n  \"unresolvedFastaPath\" : \"unresolved-sequences.fasta\",\n  \"unresolvedTablePath\" : \"unresolved-sequences.tsv\"\n}",
            "metadata/resolved-sample-metadata.tsv": "sample_id\nsampleA\n",
            "metadata/sample-metadata-manifest.json": "{\n  \"columns\" : [\n    \"sample_id\"\n  ],\n  \"emptyOverrideCells\" : \"empty analysis metadata cells do not clear lower-precedence values\",\n  \"precedence\" : [\n    \"analysisOverride\",\n    \"fastqBundle\",\n    \"fastqFolder\",\n    \"intrinsic\"\n  ],\n  \"sampleCount\" : 1,\n  \"schemaVersion\" : 1,\n  \"sources\" : [\n\n  ],\n  \"warnings\" : [\n\n  ]\n}",
            "read-fate.json": "{\n  \"ambiguousExactReads\" : 0,\n  \"chimeraCandidateReads\" : 1,\n  \"exactMatchReads\" : 2,\n  \"totalReads\" : 4,\n  \"unresolvedReads\" : 2\n}",
            "reference.fa": ">human (Homo sapiens)|locus=12S|len=8|n_refs=2|n_species=1|primer_pairs=12S_vert\nACGTACGT\n>dog (Canis lupus familiaris)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\nGGGGCCCC\n",
            "sample-target-counts.tsv": "target_id\tsampleA\nhuman (Homo sapiens)|seq_sha256=b28b7e7e6b70661d\t2\ndog (Canis lupus familiaris)|seq_sha256=2da551e351ce2615\t0\n",
            "samples.tsv": "sample\tsample_name\tsample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent\treassigned_reads\nsampleA\tsampleA\tsampleA\tsampleA\t4\t2\t2\t0\t1\t50.000000\t50.000000\t0\n",
            "target-alternate-matches.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason\n",
            "targets.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header\nhuman (Homo sapiens)|seq_sha256=b28b7e7e6b70661d\thuman (Homo sapiens)\tHomo sapiens\thuman\t\t\t\t\t12S\t8\t2\t1\t12S_vert\thuman (Homo sapiens)|locus=12S|len=8|n_refs=2|n_species=1|primer_pairs=12S_vert\ndog (Canis lupus familiaris)|seq_sha256=2da551e351ce2615\tdog (Canis lupus familiaris)\tCanis lupus familiaris\tdog\t\t\t\t\t12S\t8\t1\t1\t12S_vert\tdog (Canis lupus familiaris)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\n",
            "unresolved-sequences.fasta": ">unresolved_1 read_count=1 chimera_status=candidate\nAACCCCCCCCTT\n>unresolved_2 read_count=1 chimera_status=not_reviewed\nTTACGTTCATGG\n",
            "unresolved-sequences.tsv": "sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote\nunresolved_1\tAACCCCCCCCTT\t1\tsampleA:1\tcandidate\t\nunresolved_2\tTTACGTTCATGG\t1\tsampleA:1\tnot_reviewed\t\n",
        ],
        "counted": [
            "12s-result.json": "{\n  \"alternateMatchesTablePath\" : \"target-alternate-matches.tsv\",\n  \"analysisName\" : \"sampleA-counted-12s\",\n  \"countMatrixPath\" : \"sample-target-counts.tsv\",\n  \"createdAt\" : \"2026-10-06T23:01:18Z\",\n  \"kind\" : \"12s-amplicon-match\",\n  \"outputName\" : \"sampleA-counted-12s\",\n  \"provenancePath\" : \".lungfish-provenance.json\",\n  \"readFatePath\" : \"read-fate.json\",\n  \"referencePath\" : \"reference.fa\",\n  \"resolvedSampleMetadataPath\" : \"metadata\\/resolved-sample-metadata.tsv\",\n  \"sampleMetadataManifestPath\" : \"metadata\\/sample-metadata-manifest.json\",\n  \"sampleTablePath\" : \"samples.tsv\",\n  \"schemaVersion\" : 1,\n  \"targetTablePath\" : \"targets.tsv\",\n  \"unresolvedFastaPath\" : \"unresolved-sequences.fasta\",\n  \"unresolvedTablePath\" : \"unresolved-sequences.tsv\"\n}",
            "metadata/resolved-sample-metadata.tsv": "sample_id\nsampleA\n",
            "metadata/sample-metadata-manifest.json": "{\n  \"columns\" : [\n    \"sample_id\"\n  ],\n  \"emptyOverrideCells\" : \"empty analysis metadata cells do not clear lower-precedence values\",\n  \"precedence\" : [\n    \"analysisOverride\",\n    \"fastqBundle\",\n    \"fastqFolder\",\n    \"intrinsic\"\n  ],\n  \"sampleCount\" : 1,\n  \"schemaVersion\" : 1,\n  \"sources\" : [\n\n  ],\n  \"warnings\" : [\n\n  ]\n}",
            "read-fate.json": "{\n  \"ambiguousExactReads\" : 0,\n  \"chimeraCandidateReads\" : 0,\n  \"exactMatchReads\" : 7,\n  \"totalReads\" : 10,\n  \"unresolvedReads\" : 3\n}",
            "reference.fa": ">human (Homo sapiens)|locus=12S|len=8\nACGTACGT\n",
            "sample-target-counts.tsv": "target_id\tsampleA\nhuman (Homo sapiens)|seq_sha256=b28b7e7e6b70661d\t7\n",
            "samples.tsv": "sample\tsample_name\tsample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent\treassigned_reads\nsampleA\tsampleA\tsampleA\tsampleA\t10\t7\t3\t0\t0\t70.000000\t30.000000\t0\n",
            "target-alternate-matches.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason\n",
            "targets.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header\nhuman (Homo sapiens)|seq_sha256=b28b7e7e6b70661d\thuman (Homo sapiens)\tHomo sapiens\thuman\t\t\t\t\t12S\t8\t\t\t\thuman (Homo sapiens)|locus=12S|len=8\n",
            "unresolved-sequences.fasta": ">unresolved_1 read_count=3 chimera_status=not_reviewed\nTTAAAAAAAAAGG\n",
            "unresolved-sequences.tsv": "sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote\nunresolved_1\tTTAAAAAAAAAGG\t3\tsampleA:3\tnot_reviewed\t\n",
        ],
        "reassign": [
            "12s-result.json": "{\n  \"alternateMatchesTablePath\" : \"target-alternate-matches.tsv\",\n  \"analysisName\" : \"reassign-12s\",\n  \"countMatrixPath\" : \"sample-target-counts.tsv\",\n  \"createdAt\" : \"2026-10-06T23:01:18Z\",\n  \"kind\" : \"12s-amplicon-match\",\n  \"outputName\" : \"reassign-12s\",\n  \"provenancePath\" : \".lungfish-provenance.json\",\n  \"readFatePath\" : \"read-fate.json\",\n  \"reassignmentsTablePath\" : \"reassignments.tsv\",\n  \"referencePath\" : \"reference.fa\",\n  \"resolvedSampleMetadataPath\" : \"metadata\\/resolved-sample-metadata.tsv\",\n  \"sampleMetadataManifestPath\" : \"metadata\\/sample-metadata-manifest.json\",\n  \"sampleTablePath\" : \"samples.tsv\",\n  \"schemaVersion\" : 1,\n  \"targetTablePath\" : \"targets.tsv\",\n  \"unresolvedFastaPath\" : \"unresolved-sequences.fasta\",\n  \"unresolvedTablePath\" : \"unresolved-sequences.tsv\"\n}",
            "metadata/resolved-sample-metadata.tsv": "sample_id\nsampleA\n",
            "metadata/sample-metadata-manifest.json": "{\n  \"columns\" : [\n    \"sample_id\"\n  ],\n  \"emptyOverrideCells\" : \"empty analysis metadata cells do not clear lower-precedence values\",\n  \"precedence\" : [\n    \"analysisOverride\",\n    \"fastqBundle\",\n    \"fastqFolder\",\n    \"intrinsic\"\n  ],\n  \"sampleCount\" : 1,\n  \"schemaVersion\" : 1,\n  \"sources\" : [\n\n  ],\n  \"warnings\" : [\n\n  ]\n}",
            "read-fate.json": "{\n  \"ambiguousExactReads\" : 0,\n  \"chimeraCandidateReads\" : 0,\n  \"exactMatchReads\" : 3,\n  \"totalReads\" : 5,\n  \"unresolvedReads\" : 0\n}",
            "reassignments.tsv": "sequence_id\tsample_id\tto_species\tto_target_id\treads\tdecided_by\tcandidate_species\nTTTTTTGGGGGG\tsampleA\tHomo sapiens\thuman-long (Homo sapiens)|seq_sha256=3e586940b4873883\t2\tperSample\tHomo sapiens;Pan troglodytes\n",
            "reference.fa": ">human-long (Homo sapiens)|locus=12S|len=10|n_refs=1|n_species=1|primer_pairs=12S_vert\nACGTACGTAA\n>human-short (Homo sapiens)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\nTTTTGGGG\n>pan-short (Pan troglodytes)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\nTTTTGGGG\n",
            "sample-target-counts.tsv": "target_id\tsampleA\nhuman-long (Homo sapiens)|seq_sha256=3e586940b4873883\t5\nhuman-short (Homo sapiens)|seq_sha256=310745898c2db13f\t0\npan-short (Pan troglodytes)|seq_sha256=310745898c2db13f\t0\n",
            "samples.tsv": "sample\tsample_name\tsample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent\treassigned_reads\nsampleA\tsampleA\tsampleA\tsampleA\t5\t3\t0\t0\t0\t60.000000\t0.000000\t2\n",
            "target-alternate-matches.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason\n",
            "targets.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header\nhuman-long (Homo sapiens)|seq_sha256=3e586940b4873883\thuman-long (Homo sapiens)\tHomo sapiens\thuman-long\t\t\t\t\t12S\t10\t1\t1\t12S_vert\thuman-long (Homo sapiens)|locus=12S|len=10|n_refs=1|n_species=1|primer_pairs=12S_vert\nhuman-short (Homo sapiens)|seq_sha256=310745898c2db13f\thuman-short (Homo sapiens)\tHomo sapiens\thuman-short\t\t\t\t\t12S\t8\t1\t1\t12S_vert\thuman-short (Homo sapiens)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\npan-short (Pan troglodytes)|seq_sha256=310745898c2db13f\tpan-short (Pan troglodytes)\tPan troglodytes\tpan-short\t\t\t\t\t12S\t8\t1\t1\t12S_vert\tpan-short (Pan troglodytes)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\n",
            "unresolved-sequences.fasta": "",
            "unresolved-sequences.tsv": "sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote\n",
        ],
        "reassign-conservative": [
            "12s-result.json": "{\n  \"alternateMatchesTablePath\" : \"target-alternate-matches.tsv\",\n  \"analysisName\" : \"reassign-conservative-12s\",\n  \"countMatrixPath\" : \"sample-target-counts.tsv\",\n  \"createdAt\" : \"2026-10-06T23:01:18Z\",\n  \"kind\" : \"12s-amplicon-match\",\n  \"outputName\" : \"reassign-conservative-12s\",\n  \"provenancePath\" : \".lungfish-provenance.json\",\n  \"readFatePath\" : \"read-fate.json\",\n  \"referencePath\" : \"reference.fa\",\n  \"resolvedSampleMetadataPath\" : \"metadata\\/resolved-sample-metadata.tsv\",\n  \"sampleMetadataManifestPath\" : \"metadata\\/sample-metadata-manifest.json\",\n  \"sampleTablePath\" : \"samples.tsv\",\n  \"schemaVersion\" : 1,\n  \"targetTablePath\" : \"targets.tsv\",\n  \"unresolvedFastaPath\" : \"unresolved-sequences.fasta\",\n  \"unresolvedTablePath\" : \"unresolved-sequences.tsv\"\n}",
            "metadata/resolved-sample-metadata.tsv": "sample_id\nsampleA\n",
            "metadata/sample-metadata-manifest.json": "{\n  \"columns\" : [\n    \"sample_id\"\n  ],\n  \"emptyOverrideCells\" : \"empty analysis metadata cells do not clear lower-precedence values\",\n  \"precedence\" : [\n    \"analysisOverride\",\n    \"fastqBundle\",\n    \"fastqFolder\",\n    \"intrinsic\"\n  ],\n  \"sampleCount\" : 1,\n  \"schemaVersion\" : 1,\n  \"sources\" : [\n\n  ],\n  \"warnings\" : [\n\n  ]\n}",
            "read-fate.json": "{\n  \"ambiguousExactReads\" : 2,\n  \"chimeraCandidateReads\" : 0,\n  \"exactMatchReads\" : 3,\n  \"totalReads\" : 5,\n  \"unresolvedReads\" : 2\n}",
            "reference.fa": ">human-long (Homo sapiens)|locus=12S|len=10|n_refs=1|n_species=1|primer_pairs=12S_vert\nACGTACGTAA\n>human-short (Homo sapiens)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\nTTTTGGGG\n>pan-short (Pan troglodytes)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\nTTTTGGGG\n",
            "sample-target-counts.tsv": "target_id\tsampleA\nhuman-long (Homo sapiens)|seq_sha256=3e586940b4873883\t3\nhuman-short (Homo sapiens)|seq_sha256=310745898c2db13f\t0\npan-short (Pan troglodytes)|seq_sha256=310745898c2db13f\t0\n",
            "samples.tsv": "sample\tsample_name\tsample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent\treassigned_reads\nsampleA\tsampleA\tsampleA\tsampleA\t5\t3\t2\t2\t0\t60.000000\t40.000000\t0\n",
            "target-alternate-matches.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason\n",
            "targets.tsv": "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header\nhuman-long (Homo sapiens)|seq_sha256=3e586940b4873883\thuman-long (Homo sapiens)\tHomo sapiens\thuman-long\t\t\t\t\t12S\t10\t1\t1\t12S_vert\thuman-long (Homo sapiens)|locus=12S|len=10|n_refs=1|n_species=1|primer_pairs=12S_vert\nhuman-short (Homo sapiens)|seq_sha256=310745898c2db13f\thuman-short (Homo sapiens)\tHomo sapiens\thuman-short\t\t\t\t\t12S\t8\t1\t1\t12S_vert\thuman-short (Homo sapiens)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\npan-short (Pan troglodytes)|seq_sha256=310745898c2db13f\tpan-short (Pan troglodytes)\tPan troglodytes\tpan-short\t\t\t\t\t12S\t8\t1\t1\t12S_vert\tpan-short (Pan troglodytes)|locus=12S|len=8|n_refs=1|n_species=1|primer_pairs=12S_vert\n",
            "unresolved-sequences.fasta": ">unresolved_1 read_count=2 chimera_status=not_reviewed\nTTTTTTGGGGGG\n",
            "unresolved-sequences.tsv": "sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote\nunresolved_1\tTTTTTTGGGGGG\t2\tsampleA:2\tnot_reviewed\t\n",
        ],
    ]
}

private struct BaselineChimeraReviewer: TwelveSChimeraReviewing {
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

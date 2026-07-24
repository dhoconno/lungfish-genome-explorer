import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeCurrentWorkbookInputFingerprintTests: XCTestCase {
    func testMakeUsesLastCallForDuplicateCanonicalSampleLocusKey() throws {
        let first = call(
            sample: "Animal",
            locus: "MHC-DQA",
            haplotype1: "DQA*01",
            haplotype2: "DQA*02"
        )
        let winner = call(
            sample: "Animal",
            locus: "MHC-DQ",
            haplotype1: "DQA*03",
            haplotype2: "DQA*04"
        )

        let duplicates = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [first, winner],
            includedLoci: ["MHC-DQ"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )
        let retainedWinner = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [winner],
            includedLoci: ["MHC-DQ"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )

        XCTAssertEqual(duplicates, retainedWinner)
    }

    func testMakeChangesWhenConflictingDuplicateCallOrderChanges() throws {
        let first = call(
            sample: "Animal",
            locus: "MHC-DQA",
            haplotype1: "DQA*01",
            haplotype2: "DQA*02"
        )
        let second = call(
            sample: "Animal",
            locus: "MHC-DQ",
            haplotype1: "DQA*03",
            haplotype2: "DQA*04"
        )

        let forward = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [first, second],
            includedLoci: ["MHC-DQ"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )
        let reversed = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [second, first],
            includedLoci: ["MHC-DQ"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )

        XCTAssertNotEqual(forward, reversed)
    }

    func testMakeCollapsesIdenticalDuplicateCalls() throws {
        let duplicate = call(
            sample: "Animal",
            locus: "MHC-A",
            haplotype1: "A*01",
            haplotype2: "A*02"
        )

        XCTAssertEqual(
            try GenotypeCurrentWorkbookInputFingerprint.make(
                calls: [duplicate, duplicate],
                includedLoci: ["MHC-A"],
                annotationSidecar: nil,
                candidateArtifacts: nil
            ),
            try GenotypeCurrentWorkbookInputFingerprint.make(
                calls: [duplicate],
                includedLoci: ["MHC-A"],
                annotationSidecar: nil,
                candidateArtifacts: nil
            )
        )
    }

    func testMakeCanonicalizesIncludedLocusAliasesAndWhitespace() throws {
        let first = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [" MHC-DQA ", "MHC-A"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )
        let canonical = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: ["MHC-A", "MHC-DQ"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )

        XCTAssertEqual(first, canonical)
    }

    func testMakeIsDeterministicAcrossCallAndLocusOrdering() throws {
        let calls = [
            call(sample: "Beta", locus: " MHC-DQA ", haplotype1: "DQA*02", haplotype2: "DQA*03"),
            call(sample: "Alpha", locus: "MHC-A", haplotype1: "A*01", haplotype2: "A*02"),
        ]
        let references = [
            artifact(path: "candidate/candidates.json", checksum: "a", size: 10),
            artifact(path: "candidate/candidates.fasta", checksum: "b", size: 20),
        ]
        let firstArtifacts = candidateArtifacts(candidateJSON: references[0], candidateFASTA: references[1])

        let first = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: calls,
            includedLoci: ["MHC-DQ", "MHC-A", "MHC-A"],
            annotationSidecar: nil,
            candidateArtifacts: firstArtifacts
        )
        let second = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [
                calls[1],
                call(
                    sample: "Beta",
                    locus: "MHC-DQ",
                    haplotype1: "DQA*02",
                    haplotype2: "DQA*03"
                ),
            ],
            includedLoci: ["MHC-A", "MHC-DQ"],
            annotationSidecar: nil,
            candidateArtifacts: firstArtifacts
        )

        XCTAssertEqual(first, second)
    }

    func testMakeChangesWhenCandidateJSONAndFASTARolesAreSwapped() throws {
        let json = artifact(path: "candidate/candidates.json", checksum: "a", size: 10)
        let fasta = artifact(path: "candidate/candidates.fasta", checksum: "b", size: 20)

        let first = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: candidateArtifacts(candidateJSON: json, candidateFASTA: fasta)
        )
        let swapped = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: candidateArtifacts(candidateJSON: fasta, candidateFASTA: json)
        )

        XCTAssertNotEqual(first, swapped)
    }

    func testMakeChangesWhenGenotypingBAMAndBAIRolesAreSwapped() throws {
        let bam = artifact(path: "alignments/genotyping.bam", checksum: "d", size: 30)
        let bai = artifact(path: "alignments/genotyping.bam.bai", checksum: "e", size: 31)

        let first = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: candidateArtifacts(
                candidateJSON: nil,
                genotypingEvidence: ONTMHCBAMArtifactPair(bam: bam, bai: bai)
            )
        )
        let swapped = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: candidateArtifacts(
                candidateJSON: nil,
                genotypingEvidence: ONTMHCBAMArtifactPair(bam: bai, bai: bam)
            )
        )

        XCTAssertNotEqual(first, swapped)
    }

    func testMakeCanonicalizesArtifactsByPathBeforeRole() throws {
        let artifacts = ONTMHCCandidateArtifactManifest(
            schemaVersion: 4,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: artifact(path: "a.json", checksum: "a", size: 10),
            candidateFASTA: artifact(path: "z.fasta", checksum: "b", size: 20),
            candidateGenBank: nil,
            unnameableJSON: nil,
            unnameableFASTA: nil,
            unnameableGenBank: nil,
            rawUnmatchedFASTA: nil,
            sourceIdentityMap: nil
        )

        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: artifacts
        )

        XCTAssertEqual(
            fingerprint.sha256,
            "acbb3314eab176852c4e354dbcf836470e94722b8d7aee5b493394e322b90d71"
        )
    }

    func testMakeChangesWhenAnySemanticInputChanges() throws {
        let baseCall = call(
            sample: "Animal-1",
            locus: "MHC-A",
            haplotype1: "A*01",
            haplotype2: "A*02"
        )
        let baseSidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        let baseArtifacts = candidateArtifacts(
            candidateJSON: artifact(path: "candidate/candidates.json", checksum: "a", size: 10)
        )
        let base = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [baseCall],
            includedLoci: ["MHC-A"],
            annotationSidecar: baseSidecar,
            candidateArtifacts: baseArtifacts
        )

        let changedCall = call(
            sample: "Animal-1",
            locus: "MHC-A",
            haplotype1: "A*99",
            haplotype2: "A*02"
        )
        var changedSidecar = baseSidecar
        changedSidecar.lastEditor = "reviewer"
        let changedArtifacts = candidateArtifacts(
            candidateJSON: artifact(path: "candidate/candidates.json", checksum: "c", size: 11)
        )

        XCTAssertNotEqual(
            base,
            try GenotypeCurrentWorkbookInputFingerprint.make(
                calls: [changedCall],
                includedLoci: ["MHC-A"],
                annotationSidecar: baseSidecar,
                candidateArtifacts: baseArtifacts
            )
        )
        XCTAssertNotEqual(
            base,
            try GenotypeCurrentWorkbookInputFingerprint.make(
                calls: [baseCall],
                includedLoci: ["MHC-A", "MHC-B"],
                annotationSidecar: baseSidecar,
                candidateArtifacts: baseArtifacts
            )
        )
        XCTAssertNotEqual(
            base,
            try GenotypeCurrentWorkbookInputFingerprint.make(
                calls: [baseCall],
                includedLoci: ["MHC-A"],
                annotationSidecar: changedSidecar,
                candidateArtifacts: baseArtifacts
            )
        )
        XCTAssertNotEqual(
            base,
            try GenotypeCurrentWorkbookInputFingerprint.make(
                calls: [baseCall],
                includedLoci: ["MHC-A"],
                annotationSidecar: baseSidecar,
                candidateArtifacts: changedArtifacts
            )
        )
    }

    func testDigestHasVersionedCodableLowercaseSHA256Shape() throws {
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [],
            includedLoci: [],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )

        XCTAssertEqual(GenotypeCurrentWorkbookInputFingerprint.schemaVersion, 1)
        XCTAssertEqual(fingerprint.schemaVersion, 1)
        XCTAssertEqual(fingerprint.sha256.count, 64)
        XCTAssertNotNil(fingerprint.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
        XCTAssertEqual(
            try JSONDecoder().decode(
                GenotypeCurrentWorkbookInputFingerprint.self,
                from: JSONEncoder().encode(fingerprint)
            ),
            fingerprint
        )
    }

    func testRecordedUsesLatestAppendOrderedRevisionMatchingCurrentWorkbook() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let old = try fingerprint(haplotype: "A*01")
        let latest = try fingerprint(haplotype: "A*02")
        let unrelated = try fingerprint(haplotype: "A*03")
        try writeProvenance(old, to: "provenance/old.json", in: bundleURL)
        try writeProvenance(latest, to: "provenance/latest.json", in: bundleURL)
        try writeProvenance(unrelated, to: "provenance/unrelated.json", in: bundleURL)
        let revisions = [
            revision(id: "old", path: "current.xlsx", provenancePath: "provenance/old.json"),
            revision(id: "latest", path: "current.xlsx", provenancePath: "provenance/latest.json"),
            revision(id: "other", path: "history.xlsx", provenancePath: "provenance/unrelated.json"),
        ]

        let recorded = try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(currentWorkbookPath: "current.xlsx", revisions: revisions),
            bundleURL: bundleURL
        )

        XCTAssertEqual(recorded, latest)
    }

    func testRecordedReturnsNilForMissingUnsupportedMalformedOrUnsafeProvenance() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let valid = try fingerprint(haplotype: "A*01")
        try writeProvenance(valid, schemaVersion: 2, to: "unsupported.json", in: bundleURL)
        try writeProvenance(valid, digest: String(repeating: "A", count: 64), to: "malformed.json", in: bundleURL)
        let outsidePath = "fingerprint-escape-\(UUID().uuidString).json"
        let outsideURL = bundleURL.deletingLastPathComponent().appendingPathComponent(outsidePath)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try writeProvenance(valid, to: outsidePath, in: bundleURL.deletingLastPathComponent())

        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(currentWorkbookPath: nil, revisions: []),
            bundleURL: bundleURL
        ))
        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [revision(id: "missing", path: "current.xlsx", provenancePath: nil)]
            ),
            bundleURL: bundleURL
        ))
        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [revision(id: "unsupported", path: "current.xlsx", provenancePath: "unsupported.json")]
            ),
            bundleURL: bundleURL
        ))
        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [revision(id: "malformed", path: "current.xlsx", provenancePath: "malformed.json")]
            ),
            bundleURL: bundleURL
        ))
        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [revision(id: "unsafe", path: "current.xlsx", provenancePath: "../\(outsidePath)")]
            ),
            bundleURL: bundleURL
        ))
    }

    func testRecordedRejectsDirectoryProvenance() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("provenance-directory"),
            withIntermediateDirectories: false
        )

        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [
                    revision(
                        id: "directory",
                        path: "current.xlsx",
                        provenancePath: "provenance-directory"
                    ),
                ]
            ),
            bundleURL: bundleURL
        ))
    }

    func testRecordedRejectsFIFOWithoutBlocking() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let fifoURL = bundleURL.appendingPathComponent("provenance.fifo")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)
        let valid = try fingerprint(haplotype: "A*01")
        let bytes = try provenanceData(valid)
        let writer = Darwin.open(fifoURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(writer, 0)
        XCTAssertEqual(
            bytes.withUnsafeBytes {
                Darwin.write(writer, $0.baseAddress, $0.count)
            },
            bytes.count
        )
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerClosed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = releaseWriter.wait(timeout: .now() + .seconds(2))
            Darwin.close(writer)
            writerClosed.signal()
        }
        let started = Date()

        let recorded = try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [
                    revision(id: "fifo", path: "current.xlsx", provenancePath: "provenance.fifo"),
                ]
            ),
            bundleURL: bundleURL
        )

        releaseWriter.signal()
        XCTAssertEqual(writerClosed.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertNil(recorded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testRecordedRejectsFinalSymlinkProvenance() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let valid = try fingerprint(haplotype: "A*01")
        try writeProvenance(valid, to: "valid.json", in: bundleURL)
        try FileManager.default.createSymbolicLink(
            at: bundleURL.appendingPathComponent("linked.json"),
            withDestinationURL: bundleURL.appendingPathComponent("valid.json")
        )

        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [
                    revision(id: "symlink", path: "current.xlsx", provenancePath: "linked.json"),
                ]
            ),
            bundleURL: bundleURL
        ))
    }

    func testRecordedRejectsIntermediateSymlinkProvenance() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let valid = try fingerprint(haplotype: "A*01")
        let realDirectory = bundleURL.appendingPathComponent("real-provenance")
        try writeProvenance(valid, to: "valid.json", in: realDirectory)
        try FileManager.default.createSymbolicLink(
            at: bundleURL.appendingPathComponent("linked-provenance"),
            withDestinationURL: realDirectory
        )

        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [
                    revision(
                        id: "intermediate-symlink",
                        path: "current.xlsx",
                        provenancePath: "linked-provenance/valid.json"
                    ),
                ]
            ),
            bundleURL: bundleURL
        ))
    }

    func testRecordedRejectsProvenanceLargerThanSixteenMiB() throws {
        let bundleURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let valid = try fingerprint(haplotype: "A*01")
        var oversized = try provenanceData(valid)
        oversized.append(Data(
            repeating: 0x20,
            count: (16 * 1024 * 1024 + 1) - oversized.count
        ))
        try oversized.write(to: bundleURL.appendingPathComponent("oversized.json"))

        XCTAssertNil(try GenotypeCurrentWorkbookInputFingerprint.recorded(
            in: manifest(
                currentWorkbookPath: "current.xlsx",
                revisions: [
                    revision(id: "oversized", path: "current.xlsx", provenancePath: "oversized.json"),
                ]
            ),
            bundleURL: bundleURL
        ))
    }

    private func call(
        sample: String,
        locus: String,
        haplotype1: String,
        haplotype2: String,
        status: String = "reviewed",
        notes: String = "note"
    ) -> GenotypeWorkbookHaplotypeCall {
        GenotypeWorkbookHaplotypeCall(
            sample: sample,
            locus: locus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: status,
            notes: notes
        )
    }

    private func artifact(path: String, checksum: Character, size: Int64) -> ONTMHCArtifactReference {
        ONTMHCArtifactReference(
            path: path,
            sha256: String(repeating: String(checksum), count: 64),
            sizeBytes: size
        )
    }

    private func candidateArtifacts(
        candidateJSON: ONTMHCArtifactReference?,
        candidateFASTA: ONTMHCArtifactReference? = nil,
        genotypingEvidence: ONTMHCBAMArtifactPair? = nil
    ) -> ONTMHCCandidateArtifactManifest {
        ONTMHCCandidateArtifactManifest(
            schemaVersion: 4,
            genotypingEvidence: genotypingEvidence ?? ONTMHCBAMArtifactPair(
                bam: artifact(path: "alignments/genotyping.bam", checksum: "d", size: 30),
                bai: artifact(path: "alignments/genotyping.bam.bai", checksum: "e", size: 31)
            ),
            reciprocalEvidence: ONTMHCBAMArtifactPair(
                bam: artifact(path: "alignments/reciprocal.bam", checksum: "f", size: 40),
                bai: artifact(path: "alignments/reciprocal.bam.bai", checksum: "1", size: 41)
            ),
            candidateJSON: candidateJSON,
            candidateFASTA: candidateFASTA,
            candidateGenBank: artifact(path: "candidate/candidates.gb", checksum: "2", size: 21),
            unnameableJSON: artifact(path: "candidate/unnameable.json", checksum: "3", size: 22),
            unnameableFASTA: artifact(path: "candidate/unnameable.fasta", checksum: "4", size: 23),
            unnameableGenBank: artifact(path: "candidate/unnameable.gb", checksum: "5", size: 24),
            rawUnmatchedFASTA: artifact(path: "candidate/raw.fasta", checksum: "6", size: 25),
            sourceIdentityMap: artifact(path: "candidate/source-map.json", checksum: "7", size: 26)
        )
    }

    private func fingerprint(haplotype: String) throws -> GenotypeCurrentWorkbookInputFingerprint {
        try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: [call(sample: "Animal", locus: "MHC-A", haplotype1: haplotype, haplotype2: "")],
            includedLoci: ["MHC-A"],
            annotationSidecar: nil,
            candidateArtifacts: nil
        )
    }

    private func writeProvenance(
        _ fingerprint: GenotypeCurrentWorkbookInputFingerprint,
        schemaVersion: Int = GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
        digest: String? = nil,
        to path: String,
        in bundleURL: URL
    ) throws {
        let url = bundleURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try provenanceData(
            fingerprint,
            schemaVersion: schemaVersion,
            digest: digest
        ).write(to: url)
    }

    private func provenanceData(
        _ fingerprint: GenotypeCurrentWorkbookInputFingerprint,
        schemaVersion: Int = GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
        digest: String? = nil
    ) throws -> Data {
        let envelope = ProvenanceEnvelope(
            workflowName: "test",
            toolName: "test",
            options: ProvenanceOptions(explicit: [
                "currentWorkbookInputFingerprint": .string(digest ?? fingerprint.sha256),
                "currentWorkbookInputFingerprintSchemaVersion": .integer(schemaVersion),
            ])
        )
        return try ProvenanceJSON.encoder.encode(envelope)
    }

    private func revision(
        id: String,
        path: String,
        provenancePath: String?
    ) -> ONTGenotypeWorkbookRevision {
        ONTGenotypeWorkbookRevision(
            id: id,
            role: .aiRefinement,
            path: path,
            label: id,
            createdAt: "2026-07-24T00:00:00Z",
            sha256: String(repeating: "0", count: 64),
            sizeBytes: 1,
            provenancePath: provenancePath
        )
    }

    private func manifest(
        currentWorkbookPath: String?,
        revisions: [ONTGenotypeWorkbookRevision]
    ) -> ONTGenotypeResultBundleManifest {
        ONTGenotypeResultBundleManifest(
            outputName: "test",
            analysisName: "test",
            primaryWorkbookPath: "primary.xlsx",
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "sample.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCurrentWorkbookInputFingerprintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

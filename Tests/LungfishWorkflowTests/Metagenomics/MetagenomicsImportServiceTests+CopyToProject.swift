// MetagenomicsImportServiceTests+CopyToProject.swift - An imported result copies to another project, or is refused in words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, ruling BIO-COPY-DIGESTLESS section 5. The import writers list the result folder itself in
// the record with no digest, and a copy of the imported folder has to pass that entry while it compares every file with
// the original. These tests run the real importers, copy the folder they made to another project through the real
// copier, and flip or delete a listed file to show that the copy is refused in the person's words with nothing left
// behind and the original unchanged.

import Foundation
import Darwin
import Testing
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension MetagenomicsImportServiceTests {
    @Test func testImportedKraken2CopiesToAnotherProject() async throws { try await cpExpectCopies(.kraken2) }
    @Test func testImportedEsVirituCopiesToAnotherProject() async throws { try await cpExpectCopies(.esViritu) }
    @Test func testImportedNvdCopiesToAnotherProject() async throws { try await cpExpectCopies(.nvd) }
    @Test(ManagedSamtoolsGate.enabled)
    func testImportedNaoMgsCopiesToAnotherProject() async throws { try await cpExpectCopies(.naoMgs) }

    @Test func testImportedKraken2WithAChangedFileIsRefused() async throws { try await cpExpectRefused(.kraken2, .flip) }
    @Test func testImportedEsVirituWithAChangedFileIsRefused() async throws { try await cpExpectRefused(.esViritu, .flip) }
    @Test func testImportedTaxTriageWithAChangedFileIsRefused() async throws { try await cpExpectRefused(.taxTriage, .flip) }
    @Test func testImportedNvdWithAChangedFileIsRefused() async throws { try await cpExpectRefused(.nvd, .flip) }
    @Test(ManagedSamtoolsGate.enabled)
    func testImportedNaoMgsWithAChangedFileIsRefused() async throws { try await cpExpectRefused(.naoMgs, .flip) }

    @Test func testImportedKraken2WithAMissingFileIsRefused() async throws { try await cpExpectRefused(.kraken2, .delete) }
    @Test func testImportedEsVirituWithAMissingFileIsRefused() async throws { try await cpExpectRefused(.esViritu, .delete) }
    @Test func testImportedTaxTriageWithAMissingFileIsRefused() async throws { try await cpExpectRefused(.taxTriage, .delete) }
    @Test func testImportedNvdWithAMissingFileIsRefused() async throws { try await cpExpectRefused(.nvd, .delete) }
    @Test(ManagedSamtoolsGate.enabled)
    func testImportedNaoMgsWithAMissingFileIsRefused() async throws { try await cpExpectRefused(.naoMgs, .delete) }

    /// The copy exists, names itself in its record with the folder entry still free of a digest, holds every file of the
    /// original as it was outside the record, and leaves the original alone.
    private func cpExpectCopies(_ kind: CopyImportKind, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let scenario = try await CopyScenario.make(kind)
        defer { scenario.cleanUp() }
        let before = try scenario.digests(of: scenario.folder)

        let outcome = try scenario.copy()

        let record = try #require(ProvenanceRecorder.loadEnvelope(from: outcome.destinationURL), sourceLocation: sourceLocation)
        let output = try #require(record.output, sourceLocation: sourceLocation)
        #expect(cpCanonical(output.path) == cpCanonical(outcome.destinationURL.path), sourceLocation: sourceLocation)
        #expect(output.checksumSHA256 == nil, sourceLocation: sourceLocation)
        let after = try scenario.digests(of: outcome.destinationURL)
        // The copier rewrites the project paths that a JSON file holds, on purpose, so such a file is compared with the
        // source project and the target project named the same. Every other file is compared byte for byte.
        // The rewrite also serializes the file again, so the two are compared as parsed JSON.
        func parsed(_ url: URL) throws -> NSObject? {
            let text = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: #"[^"\s]*/[QR]\.lungfish"#, with: "@", options: .regularExpression)
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? NSObject
        }
        for (relative, digest) in before where relative != ProvenanceRecorder.provenanceFilename {
            if relative.lowercased().hasSuffix(".json") {
                let first = try parsed(scenario.folder.appendingPathComponent(relative))
                let second = try parsed(outcome.destinationURL.appendingPathComponent(relative))
                #expect(first == second, Comment(rawValue: "\(relative) differs in the copy"), sourceLocation: sourceLocation)
            } else {
                #expect(after[relative] == digest, Comment(rawValue: "\(relative) differs in the copy"), sourceLocation: sourceLocation)
            }
        }
        #expect(try scenario.digests(of: scenario.folder) == before, "the original is untouched", sourceLocation: sourceLocation)
        #expect(scenario.stages() == [], sourceLocation: sourceLocation)
    }

    /// A listed file changed by one byte, or deleted. The copy is refused naming that file, and the target's `.tmp` and
    /// `Analyses` hold nothing of it. The original is as the damage left it.
    private func cpExpectRefused(
        _ kind: CopyImportKind, _ damage: CopyDamage, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let scenario = try await CopyScenario.make(kind)
        defer { scenario.cleanUp() }
        let file = try scenario.listedFile(preferring: kind.preferredSuffixes)
        let url = scenario.folder.appendingPathComponent(file)
        switch damage {
        case .flip:
            var data = try Data(contentsOf: url)
            try #require(!data.isEmpty, sourceLocation: sourceLocation)
            data[data.count - 1] ^= 0xFF
            try data.write(to: url)
        case .delete:
            try FileManager.default.removeItem(at: url)
        }
        let before = try scenario.digests(of: scenario.folder)

        do {
            _ = try scenario.copy()
            Issue.record("the copy was made although \(file) is \(damage)", sourceLocation: sourceLocation)
        } catch let error as CrossProjectItemCopier.CopyError {
            switch (damage, error) {
            case (.flip, .recordDoesNotMatch(_, let named)), (.delete, .recordFileMissing(_, let named)):
                #expect(named == file, sourceLocation: sourceLocation)
            default:
                Issue.record("wrong refusal for \(file): \(error.localizedDescription)", sourceLocation: sourceLocation)
            }
            #expect(error.localizedDescription.contains("was not copied"), sourceLocation: sourceLocation)
        } catch {
            Issue.record("a raw error reached the person: \(error)", sourceLocation: sourceLocation)
        }
        #expect(scenario.stages() == [], "a failed copy leaves its stage", sourceLocation: sourceLocation)
        #expect(scenario.targetAnalyses().isEmpty, "a failed copy leaves part of the item", sourceLocation: sourceLocation)
        #expect(try scenario.digests(of: scenario.folder) == before, "the refused original is untouched", sourceLocation: sourceLocation)
    }
}

enum CopyDamage: CustomStringConvertible {
    case flip, delete
    var description: String { self == .flip ? "changed" : "missing" }
}

enum CopyImportKind {
    case kraken2, esViritu, taxTriage, nvd, naoMgs

    /// File name endings to try, in order, for the listed file that the tests damage.
    var preferredSuffixes: [String] {
        switch self {
        case .kraken2: return ["classification.kreport", ".kreport"]
        case .esViritu: return [".detected_virus.info.tsv"]
        case .taxTriage: return [".odr.txt", ".tsv", ".txt"]
        case .nvd, .naoMgs: return ["hits.sqlite"]
        }
    }
}

func cpCanonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

/// A source project with one real import in its `Analyses` folder, and an empty target project beside it.
struct CopyScenario {
    let workspace: URL
    let folder: URL
    let target: URL

    static func make(_ kind: CopyImportKind) async throws -> CopyScenario {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("copy-imported-\(UUID().uuidString)", isDirectory: true)
        let analyses = workspace.appendingPathComponent("Q.lungfish/Analyses", isDirectory: true)
        let target = workspace.appendingPathComponent("R.lungfish", isDirectory: true)
        try fm.createDirectory(at: analyses, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
        let folder: URL
        switch kind {
        case .kraken2:
            let report = workspace.appendingPathComponent("input.kreport")
            try "0.00\t0\t0\tU\t0\tunclassified\n100.00\t10\t0\tR\t1\troot\n50.00\t5\t5\tS\t12345\t  Example species\n"
                .write(to: report, atomically: true, encoding: .utf8)
            folder = try MetagenomicsImportService.importKraken2(kreportURL: report, outputDirectory: analyses).resultDirectory
        case .esViritu:
            folder = try MetagenomicsImportService.importEsViritu(
                inputURL: fixtures.appendingPathComponent("esviritu-mini/SRR35517705", isDirectory: true),
                outputDirectory: analyses
            ).resultDirectory
        case .taxTriage:
            folder = try MetagenomicsImportService.importTaxTriage(
                inputURL: fixtures.appendingPathComponent("taxtriage-mini", isDirectory: true), outputDirectory: analyses
            ).resultDirectory
        case .nvd:
            folder = try await MetagenomicsImportService.importNvd(
                inputURL: try nvdRun(in: workspace), outputDirectory: analyses, samtoolsPath: nil
            ).resultDirectory
        case .naoMgs:
            folder = try await naoMgsImport(in: workspace, outputDirectory: analyses)
        }
        return CopyScenario(workspace: workspace, folder: folder, target: target)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: workspace) }

    func copy() throws -> CrossProjectItemCopier.Outcome {
        try CrossProjectItemCopier.copy(itemAt: folder, intoProject: target, identity: .neutral)
    }

    func stages() -> [String] {
        let temp = ProjectTempDirectory.tempRoot(for: target)
        return ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    func targetAnalyses() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("Analyses").path)) ?? []
    }

    /// Every regular file under `root` (hidden ones too) with its digest, by path inside `root`.
    func digests(of root: URL) throws -> [String: String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(prefix) { result[String(path.dropFirst(prefix.count))] = try ProvenanceFileHasher.sha256(of: url) }
        }
        return result
    }

    /// A file inside the folder that the import's record lists with a digest, the first that ends as `suffixes` say.
    func listedFile(preferring suffixes: [String]) throws -> String {
        let record = try #require(ProvenanceRecorder.loadEnvelope(from: folder), "the import wrote no record")
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        let listed = Set((record.outputs + record.steps.flatMap(\.outputs) + record.files.filter { $0.role == .output })
            .filter { $0.checksumSHA256 != nil && $0.path.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
            .filter { $0.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0) }
            .map { String($0.dropFirst(prefix.count)) }).sorted()
        for suffix in suffixes { if let match = listed.first(where: { $0.hasSuffix(suffix) }) { return match } }
        return try #require(listed.first, "the record lists no file with a digest")
    }

    // MARK: - Importer inputs

    private static func nvdRun(in workspace: URL) throws -> URL {
        let fm = FileManager.default
        let run = workspace.appendingPathComponent("nvd-run", isDirectory: true)
        let labkey = run.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        let virus = run.appendingPathComponent("02_human_viruses/03_human_virus_results", isDirectory: true)
        let mapped = virus.appendingPathComponent("mapped_reads", isDirectory: true)
        try fm.createDirectory(at: labkey, withIntermediateDirectories: true)
        try fm.createDirectory(at: mapped, withIntermediateDirectories: true)
        try """
        experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
        EXP001,blastn,S1,contig-1,120,gb|NC_001|,Example virus species,S,118,99.2,1e-20,250.5,Example virus,12345,nt-2026,run-001,42,100000,stat-1,12345,unchanged,Example virus,species

        """.write(to: labkey.appendingPathComponent("sample_blast_concatenated.csv"), atomically: true, encoding: .utf8)
        try "synthetic bam payload\n".write(to: mapped.appendingPathComponent("S1.filtered.bam"), atomically: true, encoding: .utf8)
        try "synthetic bai payload\n".write(to: mapped.appendingPathComponent("S1.filtered.bam.bai"), atomically: true, encoding: .utf8)
        try ">contig-1\nACGTACGT\n".write(to: virus.appendingPathComponent("S1.human_virus.fasta"), atomically: true, encoding: .utf8)
        return run
    }

    private static func naoMgsImport(in workspace: URL, outputDirectory: URL) async throws -> URL {
        let source = workspace.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        SAMPLE_A\tread2\t111\tACGTACGA\tFFFFFFFF\tACCN0002\t20\t8M\t8\t1\tFalse
        SAMPLE_A\tread3\t222\tACGTACGG\tFFFFFFFF\tACCN0003\t30\t8M\t8\t0\tTrue
        """.write(to: source, atomically: true, encoding: .utf8)
        // A registry with a fixture taxdump keeps the taxonomy install off the network and out of managed storage.
        let managed = workspace.appendingPathComponent("managed-databases", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: managed,
            catalog: MetagenomicsDatabaseInfo.builtInCatalog.filter { $0.tool == MetagenomicsTool.ncbiTaxonomy.rawValue },
            databaseInstaller: NCBITaxonomyFixture.installer(
                archive: managed.appendingPathComponent("taxdump.tar.gz"),
                scientificNames: [111: "Fixture virus alpha", 222: "Fixture virus beta"]
            )
        )
        // The machine-wide lock the other NAO-MGS import tests take.
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-naomgs-import-tests.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try await MetagenomicsImportService.importNaoMgs(
            inputURL: source, outputDirectory: outputDirectory, sampleName: "SAMPLE_A", minIdentity: 90,
            fetchReferences: false, preferredName: nil, taxonomyRegistry: registry, progress: nil
        ).resultDirectory
    }
}

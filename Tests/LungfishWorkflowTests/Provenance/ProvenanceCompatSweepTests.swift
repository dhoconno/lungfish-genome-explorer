import Foundation
import Testing
import LungfishCore
import LungfishTestSupport

/// The sweep applies the corpus projection to every provenance sidecar under folders an operator
/// names, and writes a report that two commits can be compared by. The sweep test itself runs only
/// when `LUNGFISH_PROVENANCE_SWEEP_ROOTS` and `LUNGFISH_PROVENANCE_SWEEP_OUT` are both set, because
/// it reads real data on one Mac. The other tests run in the gate and check the machinery on the
/// corpus itself, so the report an operator diffs can be trusted.
@Suite("Provenance compatibility sweep")
struct ProvenanceCompatSweepTests {
    // MARK: The sweep an operator runs

    @Test(
        "sweeps the folders named by the environment and writes the report outside the repository",
        .enabled(if: ProvenanceCompatSweep.isRequested)
    )
    func sweepsTheConfiguredFolders() throws {
        let configuration = try ProvenanceCompatSweep.configuration()
        let report = ProvenanceCompatSweep.run(roots: configuration.roots, labels: configuration.labels)
        let url = try ProvenanceCompatSweep.write(report, to: configuration.outputFolder, roots: configuration.roots)
        print(
            "provenance sweep: \(report.summary.total) sidecar(s), \(report.summary.read) read, "
                + "\(report.summary.unreadable) unreadable, report at \(url.path)"
        )
        #expect(report.summary.total == report.entries.count)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: The machinery, checked on the corpus

    @Test("a sweep of the materialized corpus finds every case and agrees with the expected facts")
    func sweepOfTheCorpusAgreesWithTheExpectedFacts() throws {
        let cases = try ProvenanceCompatCorpus.cases()
        var materialized: [ProvenanceCompatMaterialized] = []
        defer { materialized.forEach { $0.cleanup() } }
        for item in cases { materialized.append(try ProvenanceCompatCorpus.materialize(item.id)) }

        let report = ProvenanceCompatSweep.run(roots: materialized.map(\.projectRoot), labels: cases.map(\.id))

        #expect(report.roots == cases.map(\.id))
        #expect(report.entries.count == cases.count)
        #expect(report.summary.total == cases.count)
        #expect(report.summary.read == cases.count)
        #expect(report.summary.unreadable == 0)
        #expect(report.summary.byDecoder.values.reduce(0, +) == cases.count)
        for (index, item) in cases.enumerated() {
            let entry = try #require(report.entries.first { $0.root == index }, "no entry for \(item.id)")
            #expect(entry.path == item.layoutPath)
            let isFolderSidecar = (item.layoutPath as NSString).lastPathComponent == ProvenanceCompatCorpus.sidecarFilename
            #expect(entry.kind == (isFolderSidecar ? "folder" : "file"))
            #expect(entry.outcome == "read")
            // The digest of the facts equals the digest of the reviewed expected facts file.
            let expected = try #require(ProvenanceCompatCorpus.expectedFactsData(for: item.id))
            #expect(entry.factsSHA256 == ProvenanceCompatCorpus.sha256Hex(expected), "facts of \(item.id) differ from the reviewed file")
            let facts = try ProvenanceCompatFacts.decode(expected)
            #expect(entry.decodedBy == facts.decodedBy.rawValue)
            #expect(entry.strictAccepts == facts.strictAccepts)
            #expect(entry.readStatus == facts.readStatus)
            #expect(entry.stepCount == facts.steps.count)
        }
    }

    @Test("two sweeps of unchanged data write identical bytes, sorted, and hold no absolute path")
    func reportIsDeterministicAndHoldsNoAbsolutePath() throws {
        var materialized: [ProvenanceCompatMaterialized] = []
        defer { materialized.forEach { $0.cleanup() } }
        for id in ProvenanceCompatCorpus.caseIDs().reversed() { materialized.append(try ProvenanceCompatCorpus.materialize(id)) }
        let roots = materialized.map(\.projectRoot)
        let labels = (0..<roots.count).map { "root\($0)" }

        let first = ProvenanceCompatSweep.run(roots: roots, labels: labels)
        let second = ProvenanceCompatSweep.run(roots: roots, labels: labels)
        let bytes = try first.canonicalJSON()
        #expect(bytes == (try second.canonicalJSON()))
        #expect(bytes.last == 0x0A)

        // Entries are ordered by root and then by path.
        let keys = first.entries.map { (root: $0.root, path: $0.path) }
        #expect(keys.sorted { ($0.root, $0.path) < ($1.root, $1.path) }.map { "\($0.root)|\($0.path)" } == keys.map { "\($0.root)|\($0.path)" })

        // Nothing in the report names the Mac, the temporary folders or the account.
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(ProvenanceCompatCorpus.machinePathMarkers(in: bytes).isEmpty)
        #expect(ProvenanceCompatCorpus.accountNameFindings(in: bytes).isEmpty)
        #expect(!text.contains(NSHomeDirectory()))
        for item in materialized { #expect(!text.contains(item.temporaryRoot.path)) }
    }

    @Test("a sweep leaves every swept file and folder as it found them")
    func sweepOnlyReads() throws {
        var materialized: [ProvenanceCompatMaterialized] = []
        defer { materialized.forEach { $0.cleanup() } }
        for id in ProvenanceCompatCorpus.caseIDs() { materialized.append(try ProvenanceCompatCorpus.materialize(id)) }
        let roots = materialized.map(\.projectRoot)

        let before = try roots.map { try Self.snapshot(of: $0) }
        let report = ProvenanceCompatSweep.run(roots: roots, labels: roots.map { $0.lastPathComponent })
        let after = try roots.map { try Self.snapshot(of: $0) }

        #expect(report.summary.total == roots.count)
        #expect(before == after)
        #expect(before.allSatisfy { !$0.isEmpty })
    }

    @Test("files no reader accepts are reported as unreadable, and version control folders are skipped")
    func unreadableFilesAreReportedNotThrown() throws {
        // The tolerant reader accepts any JSON object, because the primitive adapter has no required
        // key, so only text that is not JSON and JSON that is not an object are unreadable.
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        try ProvenanceCompatScenarios.write("this is not json", to: project.root.appendingPathComponent("a/.lungfish-provenance.json"))
        try ProvenanceCompatScenarios.write("[1, 2]", to: project.root.appendingPathComponent("b/x.lungfish-provenance.json"))
        try ProvenanceCompatScenarios.write("{\"unrelated\": true}", to: project.root.appendingPathComponent("c/.lungfish-provenance.json"))
        try ProvenanceCompatScenarios.write("{}", to: project.root.appendingPathComponent(".git/y/.lungfish-provenance.json"))
        try ProvenanceCompatScenarios.write("{}", to: project.root.appendingPathComponent("e/notes.json"))
        let valid = try ProvenanceCompatCorpus.materialize("s2-analysis-kraken2-fixture")
        defer { valid.cleanup() }
        let target = project.root.appendingPathComponent("d/.lungfish-provenance.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: valid.sidecar, to: target)

        let report = ProvenanceCompatSweep.run(roots: [project.root], labels: ["project"])

        #expect(report.entries.map(\.path) == [
            "a/.lungfish-provenance.json", "b/x.lungfish-provenance.json",
            "c/.lungfish-provenance.json", "d/.lungfish-provenance.json",
        ])
        #expect(report.entries.map(\.outcome) == ["unreadable", "unreadable", "read", "read"])
        #expect(report.entries.map(\.kind) == ["folder", "file", "folder", "folder"])
        #expect(report.entries.map(\.decodedBy) == [nil, nil, "primitive", "envelope"])
        for entry in report.entries where entry.outcome == "unreadable" {
            let error = try #require(entry.error)
            #expect(!error.isEmpty)
            #expect(!error.contains(project.root.path), "the error names a path: \(error)")
            #expect(entry.factsSHA256 == nil)
            #expect(!entry.sha256.isEmpty)
        }
        #expect(report.summary.total == 4)
        #expect(report.summary.read == 2)
        #expect(report.summary.unreadable == 2)
        #expect(report.summary.byDecoder == ["primitive": 1, "envelope": 1])
    }

    @Test("a root may be one sidecar")
    func aRootMayBeOneSidecar() throws {
        let valid = try ProvenanceCompatCorpus.materialize("s2-analysis-kraken2-fixture")
        defer { valid.cleanup() }
        let report = ProvenanceCompatSweep.run(roots: [valid.sidecar], labels: ["one"])
        #expect(report.entries.count == 1)
        #expect(report.entries.first?.path == ProvenanceCompatCorpus.sidecarFilename)
        #expect(report.entries.first?.outcome == "read")
        #expect(ProvenanceCompatSweep.run(roots: [valid.projectRoot.appendingPathComponent("Analyses")], labels: ["a"]).entries.count == 1)
    }

    // MARK: The report folder and the roots

    @Test("the report folder must lie outside the repository, every git work tree and every swept folder")
    func outputFolderIsValidated() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let root = project.root

        let insideRepository = ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("sweep-report-must-not-exist", isDirectory: true)
        #expect(throws: ProvenanceCompatSweep.SweepError.outputInsideRepository(CanonicalFilePath.path(for: insideRepository))) {
            try ProvenanceCompatSweep.validateOutputFolder(insideRepository, roots: [root])
        }

        // Another git work tree counts as well, wherever it is.
        let tree = project.temporaryRoot.appendingPathComponent("other-work-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let insideTree = tree.appendingPathComponent("reports", isDirectory: true)
        #expect(throws: ProvenanceCompatSweep.SweepError.outputInsideRepository(CanonicalFilePath.path(for: insideTree))) {
            try ProvenanceCompatSweep.validateOutputFolder(insideTree, roots: [root])
        }

        let insideRoot = root.appendingPathComponent("reports", isDirectory: true)
        #expect(throws: ProvenanceCompatSweep.SweepError.outputInsideRoot(CanonicalFilePath.path(for: insideRoot))) {
            try ProvenanceCompatSweep.validateOutputFolder(insideRoot, roots: [root])
        }

        // A refused folder is not created, and a fresh sibling folder is accepted and written.
        let report = ProvenanceCompatSweep.run(roots: [], labels: [])
        #expect(throws: ProvenanceCompatSweep.SweepError.self) {
            try ProvenanceCompatSweep.write(report, to: insideRepository, roots: [root])
        }
        #expect(!FileManager.default.fileExists(atPath: insideRepository.path))
        let accepted = project.temporaryRoot.appendingPathComponent("reports-elsewhere", isDirectory: true)
        let written = try ProvenanceCompatSweep.write(report, to: accepted, roots: [root])
        #expect(written.lastPathComponent == ProvenanceCompatSweep.reportFilename)
        #expect(try Data(contentsOf: written) == (try report.canonicalJSON()))
    }

    @Test("the roots variable splits on colons, expands the home folder and rejects a missing root")
    func rootsVariableIsParsed() throws {
        #expect(ProvenanceCompatSweep.splitRoots("a: b ::c:") == ["a", "b", "c"])
        #expect(ProvenanceCompatSweep.splitRoots("").isEmpty)

        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let home = try project.folder("home")
        let research = home.appendingPathComponent("Research", isDirectory: true)
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let output = project.temporaryRoot.appendingPathComponent("out", isDirectory: true)
        let environment = [
            ProvenanceCompatSweep.rootsVariable: "~/Research:\(research.path)",
            ProvenanceCompatSweep.outputVariable: output.path,
        ]

        let configuration = try ProvenanceCompatSweep.configuration(environment: environment, homeDirectory: home.path)
        #expect(configuration.labels == ["~/Research", research.path])
        #expect(configuration.roots.map { CanonicalFilePath.path(for: $0) } == [CanonicalFilePath.path(for: research), CanonicalFilePath.path(for: research)])
        #expect(configuration.outputFolder.path == output.path)

        var missing = environment
        missing[ProvenanceCompatSweep.rootsVariable] = "~/Nope"
        #expect(throws: ProvenanceCompatSweep.SweepError.missingRoot("~/Nope")) {
            try ProvenanceCompatSweep.configuration(environment: missing, homeDirectory: home.path)
        }
        var empty = environment
        empty[ProvenanceCompatSweep.rootsVariable] = " : "
        #expect(throws: ProvenanceCompatSweep.SweepError.noRoots) {
            try ProvenanceCompatSweep.configuration(environment: empty, homeDirectory: home.path)
        }
    }

    // MARK: Helpers

    /// Every file and folder under `root` with its size, modification time and content digest.
    private static func snapshot(of root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return [] }
        var lines: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let relative = CanonicalFilePath.relativePath(of: url, within: root) ?? url.path
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if values.isDirectory == true {
                lines.append("dir|\(relative)|\(modified)")
            } else {
                let digest = ProvenanceCompatCorpus.sha256Hex(try Data(contentsOf: url))
                lines.append("file|\(relative)|\(values.fileSize ?? -1)|\(modified)|\(digest)")
            }
        }
        return lines.sorted()
    }
}

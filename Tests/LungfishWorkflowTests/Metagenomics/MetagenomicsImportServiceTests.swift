// MetagenomicsImportServiceTests.swift - Shared import service regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import Testing
import LungfishIO
@testable import LungfishWorkflow

@Suite(.serialized)
struct MetagenomicsImportServiceTests {
    @Test
    func kraken2ImportCreatesCanonicalResultDirectory() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-kraken2-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceKreport = workspace.appendingPathComponent("input.kreport")
        try """
        0.00\t0\t0\tU\t0\tunclassified
        100.00\t10\t0\tR\t1\troot
        50.00\t5\t5\tS\t12345\t  Example species
        """.write(to: sourceKreport, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importKraken2(
            kreportURL: sourceKreport,
            outputDirectory: outputDirectory
        )

        #expect(FileManager.default.fileExists(atPath: result.resultDirectory.path))
        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("classification.kreport").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("classification.kraken").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("classification-result.json").path
        ))
        try expectImportProvenance(
            in: result.resultDirectory,
            workflowName: "lungfish import kraken2",
            inputURLs: [sourceKreport],
            outputNames: ["classification.kreport", "classification.kraken", "classification-result.json"]
        )
        #expect(result.totalReads == 10)
        #expect(result.speciesCount == 1)
    }

    @Test
    func kraken2ImportCompactsSuppliedReadClassifications() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-kraken2-compact-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceKreport = workspace.appendingPathComponent("input.kreport")
        try """
        0.00\t1\t1\tU\t0\tunclassified
        100.00\t3\t0\tR\t1\troot
        66.67\t2\t2\tS\t12345\t  Example species
        """.write(to: sourceKreport, atomically: true, encoding: .utf8)

        let sourceOutput = workspace.appendingPathComponent("classification.kraken")
        try """
        C\tread-1\t12345\t150\t12345:150
        U\tread-2\t0\t150\t0:150
        C\tread-3\t12345\t150\t12345:150
        """.write(to: sourceOutput, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importKraken2(
            kreportURL: sourceKreport,
            outputDirectory: outputDirectory,
            outputFileURL: sourceOutput
        )

        let rawOutput = result.resultDirectory.appendingPathComponent("classification.kraken")
        let compressedOutput = rawOutput.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedOutput)

        #expect(!FileManager.default.fileExists(atPath: rawOutput.path))
        #expect(FileManager.default.fileExists(atPath: compressedOutput.path))
        #expect(FileManager.default.fileExists(atPath: indexURL.path))

        let loaded = try ClassificationResult.load(from: result.resultDirectory)
        #expect(loaded.outputURL.lastPathComponent == "classification.kraken.gz")
        try expectImportProvenance(
            in: result.resultDirectory,
            workflowName: "lungfish import kraken2",
            inputURLs: [sourceKreport, sourceOutput],
            outputNames: [
                "classification.kreport",
                "classification.kraken.gz",
                "classification.kraken.gz.idx.sqlite",
                "classification-result.json",
            ]
        )

        let index = try KrakenIndexDatabase(url: indexURL)
        #expect(index.isClassifiedOnly)
        #expect(index.canResolve(taxIds: [12345]))
        #expect(!index.canResolve(taxIds: [0]))
    }

    @Test
    func kraken2ImportRemovesPartialResultDirectoryOnParseFailure() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-kraken2-failure-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceKreport = workspace.appendingPathComponent("invalid.kreport")
        try "not-a-kreport\n".write(to: sourceKreport, atomically: true, encoding: .utf8)
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        do {
            _ = try MetagenomicsImportService.importKraken2(
                kreportURL: sourceKreport,
                outputDirectory: outputDirectory
            )
            Issue.record("Expected invalid Kraken2 import to throw")
        } catch {
            let visibleResults = try visibleResultDirectories(in: outputDirectory)
            #expect(visibleResults.isEmpty)
        }
    }

    @Test
    func esVirituImportCreatesSidecar() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-esviritu-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = workspace.appendingPathComponent("esv-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let detectionURL = sourceDirectory.appendingPathComponent("SampleA.detected_virus.info.tsv")
        try esVirituDetectionFixture().write(to: detectionURL, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importEsViritu(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory
        )

        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("esviritu-result.json").path
        ))
        try expectImportProvenance(
            in: result.resultDirectory,
            workflowName: "lungfish import esviritu",
            inputURLs: [sourceDirectory],
            outputNames: ["SampleA.detected_virus.info.tsv", "esviritu-result.json"]
        )
        #expect(result.importedFileCount >= 1)
        #expect(result.virusCount >= 1)
    }

    /// A detection file that carries an EsViritu header but is missing a
    /// required column is an upstream format change: the import must fail rather
    /// than substituting a raw row count that looks like a plausible virus count.
    @Test
    func esVirituImportThrowsWhenHeaderIsMissingRequiredColumn() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-esviritu-badheader-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = workspace.appendingPathComponent("esv-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        // Same fixture, with the read_count column dropped from header and row.
        let columns = EsVirituDetectionParser.requiredColumns.filter { $0 != "read_count" }
        let header = columns.joined(separator: "\t")
        let row = columns.map { name -> String in
            switch name {
            case "Length", "Asm_length": return "1000"
            case "sample_ID": return "SampleA"
            default: return "x"
            }
        }.joined(separator: "\t")

        let detectionURL = sourceDirectory.appendingPathComponent("SampleA.detected_virus.info.tsv")
        try [header, row].joined(separator: "\n")
            .write(to: detectionURL, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        do {
            _ = try MetagenomicsImportService.importEsViritu(
                inputURL: sourceDirectory,
                outputDirectory: outputDirectory
            )
            Issue.record("Expected EsViritu import to throw on a header missing read_count")
        } catch let error as MetagenomicsImportError {
            // Must be a parse failure naming the missing column, not some
            // unrelated import error that would make this test vacuous.
            guard case .parseFailed(_, let reason) = error else {
                Issue.record("Expected .parseFailed, got \(error)")
                return
            }
            #expect(reason.contains("read_count"), "Reason should name the missing column, got: \(reason)")
        }
    }

    /// A partial export with no recognisable header keeps the raw row-count
    /// fallback, so importing a fragment still succeeds.
    @Test
    func esVirituImportFallsBackToRowCountWhenNoHeaderPresent() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-esviritu-noheader-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = workspace.appendingPathComponent("esv-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let detectionURL = sourceDirectory.appendingPathComponent("SampleA.detected_virus.info.tsv")
        try """
        not-a-header\tsome\tother\tcolumns
        row-one\tvalue\tvalue\tvalue
        row-two\tvalue\tvalue\tvalue
        """.write(to: detectionURL, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importEsViritu(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory
        )
        #expect(result.virusCount == 2)
    }

    @Test
    func taxTriageImportCreatesSidecar() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-taxtriage-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = workspace.appendingPathComponent("taxtriage-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let reportURL = sourceDirectory.appendingPathComponent("top_report.tsv")
        try """
        taxid\tname\treads
        111\tVirus A\t12
        222\tVirus B\t8
        """.write(to: reportURL, atomically: true, encoding: .utf8)

        let logURL = sourceDirectory.appendingPathComponent("nextflow.log")
        try """
        NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR35517992.SRR35517992.dwnld.references)` terminated with an error exit status (1) -- Error is ignored
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importTaxTriage(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory
        )

        let sidecar = try TaxTriageResult.load(from: result.resultDirectory)

        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("taxtriage-result.json").path
        ))
        #expect(result.importedFileCount >= 1)
        #expect(result.reportEntryCount == 2)
        #expect(sidecar.ignoredFailures.count == 1)
        #expect(sidecar.ignoredFailures.first?.sampleID == "SRR35517992")
        try expectImportProvenance(
            in: result.resultDirectory,
            workflowName: "lungfish import taxtriage",
            inputURLs: [sourceDirectory],
            outputNames: ["top_report.tsv", "nextflow.log", "taxtriage-result.json"]
        )
    }

    @Test
    func naoMgsImportCreatesCanonicalBundle() async throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-naomgs-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        SAMPLE_A\tread2\t111\tACGTACGA\tFFFFFFFF\tACCN0002\t20\t8M\t8\t1\tFalse
        SAMPLE_A\tread3\t222\tACGTACGG\tFFFFFFFF\tACCN0003\t30\t8M\t8\t0\tTrue
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "SAMPLE_A",
            minIdentity: 90,
            fetchReferences: false
        )

        let bundle = result.resultDirectory
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("hits.sqlite").path))
        #expect(result.sampleName == "SAMPLE_A")
        #expect(result.taxonCount == 2)
        let provenance = try expectImportProvenance(
            in: result.resultDirectory,
            workflowName: "lungfish import nao-mgs",
            inputURLs: [sourceFile],
            outputNames: ["manifest.json", "hits.sqlite"]
        )
        if result.createdBAM {
            let materializationSteps = provenance.steps.filter { $0.toolName == "lungfish nao-mgs materialize-bam" }
            #expect(!materializationSteps.isEmpty)
            #expect(materializationSteps.contains { step in
                step.inputs.contains { descriptor in
                    descriptor.path == bundle.appendingPathComponent("hits.sqlite").path
                        && descriptor.path.contains(result.resultDirectory.path)
                        && !descriptor.path.contains(".naomgs-import-staging")
                }
            })
            #expect(materializationSteps.allSatisfy { step in
                !step.inputs.contains { descriptor in
                    descriptor.path == sourceFile.path
                        || descriptor.path.contains(".naomgs-import-staging")
                }
            })
            #expect(materializationSteps.contains { step in
                guard let durableReplayArgv = step.durableReplayArgv else { return false }
                return durableReplayArgv.prefix(3).elementsEqual(["lungfish-cli", "import", "nao-mgs"])
                    && durableReplayArgv.contains(sourceFile.path)
                    && !durableReplayArgv.contains { $0.contains(".naomgs-import-staging") }
            })
            #expect(materializationSteps.allSatisfy { step in
                !step.reproducibleCommand.contains(".naomgs-import-staging")
            })
            let samtoolsSteps = provenance.steps.filter { $0.toolName == "samtools" }
            #expect(!samtoolsSteps.isEmpty)
            #expect(samtoolsSteps.contains { step in
                step.outputs.contains { descriptor in
                    descriptor.path.hasSuffix(".bam") && descriptor.originPath != nil
                }
            })
            #expect(samtoolsSteps.contains { step in
                step.inputs.contains { descriptor in
                    descriptor.path.hasSuffix(".bam")
                        && descriptor.path.contains("/bams/")
                        && !descriptor.path.contains(".naomgs-import-staging")
                }
            })
            #expect(samtoolsSteps.allSatisfy { step in
                step.durableReplayArgv?.allSatisfy { !$0.contains(".naomgs-import-staging") } == true
                    && !step.reproducibleCommand.contains(".naomgs-import-staging")
            })
            #expect(samtoolsSteps.allSatisfy { $0.exitStatus != nil })
        }
    }

    @Test
    func naoMgsImportRemovesPartialResultDirectoryOnMalformedInput() async throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-naomgs-failure-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try """
        this\tis\tnot\tthe\texpected\theader
        bad\trow
        """.write(to: sourceFile, atomically: true, encoding: .utf8)
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        do {
            _ = try await importNaoMgsForTesting(
                inputURL: sourceFile,
                outputDirectory: outputDirectory,
                fetchReferences: false
            )
            Issue.record("Expected malformed NAO-MGS import to throw")
        } catch {
            let visibleResults = try visibleResultDirectories(in: outputDirectory)
            #expect(visibleResults.isEmpty)
        }
    }

    @Test
    func nvdImportCreatesDatabaseAssetsAndProvenance() async throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-nvd-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = try makeNvdRunDirectory(in: workspace)
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await MetagenomicsImportService.importNvd(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory,
            samtoolsPath: nil
        )

        let bundle = result.resultDirectory
        #expect(bundle.lastPathComponent == "nvd-EXP001")
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("hits.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("bam/S1.bam").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("bam/S1.bam.bai").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("fasta/S1.human_virus.fasta").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent(".processing").path))
        #expect(result.sampleCount == 1)
        #expect(result.hitCount == 1)
        #expect(result.copiedBAMCount == 1)
        #expect(result.copiedFASTACount == 1)

        let database = try NvdDatabase(at: bundle.appendingPathComponent("hits.sqlite"))
        #expect(try database.totalHitCount() == 1)
        #expect(try database.bamPath(forSample: "S1") == "bam/S1.bam")
        #expect(try database.bamIndexPath(forSample: "S1") == "bam/S1.bam.bai")
        #expect(try database.fastaPath(forSample: "S1") == "fasta/S1.human_virus.fasta")

        try expectImportProvenance(
            in: bundle,
            workflowName: "lungfish import nvd",
            inputURLs: [sourceDirectory],
            outputNames: [
                "manifest.json",
                "hits.sqlite",
                "S1.bam",
                "S1.bam.bai",
                "S1.human_virus.fasta",
            ]
        )
    }

    @Test
    func nvdImportWithSamtoolsRecordsAuxiliaryProvenanceSteps() async throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-nvd-samtools-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = try makeNvdRunDirectory(in: workspace)
        let samtoolsURL = try makeFakeSamtools(in: workspace)
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await MetagenomicsImportService.importNvd(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory,
            samtoolsPath: samtoolsURL.path
        )

        #expect(result.markdupBAMCount == 1)
        #expect(result.uniqueReadRowsUpdated == 1)

        let provenance = try expectImportProvenance(
            in: result.resultDirectory,
            workflowName: "lungfish import nvd",
            inputURLs: [sourceDirectory],
            outputNames: [
                "manifest.json",
                "hits.sqlite",
                "S1.bam",
                "S1.bam.bai",
                "S1.human_virus.fasta",
            ]
        )
        let samtoolsSteps = provenance.steps.filter { $0.toolName == "samtools" }
        #expect(!samtoolsSteps.isEmpty)
        #expect(samtoolsSteps.allSatisfy { $0.toolVersion == "samtools fake 1.0" })
        #expect(samtoolsSteps.contains { $0.argv.first == "/bin/sh" && $0.reproducibleCommand.contains("markdup") })
        #expect(samtoolsSteps.contains { $0.argv.contains("view") && $0.argv.contains("-c") })
        #expect(samtoolsSteps.flatMap(\.outputs).contains { $0.path.hasSuffix("hits.sqlite") })
        #expect(samtoolsSteps.flatMap(\.inputs).allSatisfy { descriptor in
            descriptor.path.contains(result.resultDirectory.path)
                && !descriptor.path.contains(".lungfish-nvd-import-")
        })
        #expect(samtoolsSteps.flatMap(\.outputs).allSatisfy { descriptor in
            descriptor.path.contains(result.resultDirectory.path)
                && !descriptor.path.contains(".lungfish-nvd-import-")
        })
        #expect(samtoolsSteps.allSatisfy { step in
            step.durableReplayArgv?.allSatisfy { !$0.contains(".lungfish-nvd-import-") } == true
                && !step.reproducibleCommand.contains(".lungfish-nvd-import-")
        })
    }

    @Test
    func managedSamtoolsExecutableURLUsesSamtoolsEnvironmentLayout() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "samtools-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let samtoolsURL = binDir.appendingPathComponent("samtools")
        try "#!/bin/sh\nexit 0\n".write(to: samtoolsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsURL.path)

        let resolved = MetagenomicsImportService.managedSamtoolsExecutableURL(homeDirectory: home)

        #expect(resolved?.path == samtoolsURL.path)
    }
}

private func makeTemporaryDirectory(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func visibleResultDirectories(in outputDirectory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: outputDirectory.path) else {
        return []
    }
    return try FileManager.default
        .contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        .filter { url in
            guard !url.lastPathComponent.hasPrefix(".") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
}

private func makeNvdRunDirectory(in workspace: URL) throws -> URL {
    let nvdDir = workspace.appendingPathComponent("nvd-run", isDirectory: true)
    let labkeyDir = nvdDir.appendingPathComponent("05_labkey_bundling", isDirectory: true)
    let humanVirusDir = nvdDir
        .appendingPathComponent("02_human_viruses", isDirectory: true)
        .appendingPathComponent("03_human_virus_results", isDirectory: true)
    let mappedReadsDir = humanVirusDir.appendingPathComponent("mapped_reads", isDirectory: true)

    try FileManager.default.createDirectory(at: labkeyDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: mappedReadsDir, withIntermediateDirectories: true)

    try nvdCSVFixture.write(
        to: labkeyDir.appendingPathComponent("sample_blast_concatenated.csv"),
        atomically: true,
        encoding: .utf8
    )
    try "synthetic bam payload\n".write(
        to: mappedReadsDir.appendingPathComponent("S1.filtered.bam"),
        atomically: true,
        encoding: .utf8
    )
    try "synthetic bai payload\n".write(
        to: mappedReadsDir.appendingPathComponent("S1.filtered.bam.bai"),
        atomically: true,
        encoding: .utf8
    )
    try ">contig-1\nACGTACGT\n".write(
        to: humanVirusDir.appendingPathComponent("S1.human_virus.fasta"),
        atomically: true,
        encoding: .utf8
    )
    return nvdDir
}

private func makeFakeSamtools(in workspace: URL) throws -> URL {
    let samtoolsURL = workspace.appendingPathComponent("fake-samtools")
    try """
    #!/bin/sh
    set -eu
    command="${1:-}"
    if [ "$command" = "--version" ]; then
      echo "samtools fake 1.0"
      exit 0
    fi
    case "$command" in
      view)
        if [ "${2:-}" = "-H" ]; then
          exit 0
        fi
        if [ "${2:-}" = "-c" ]; then
          echo "7"
          exit 0
        fi
        exit 0
        ;;
      sort|fixmate)
        cat >/dev/null || true
        echo "fake-bam-stream"
        exit 0
        ;;
      markdup)
        output=""
        for arg in "$@"; do
          output="$arg"
        done
        cat >/dev/null || true
        printf "fake markdup bam\\n" > "$output"
        exit 0
        ;;
      index)
        printf "fake index\\n" > "$2.bai"
        exit 0
        ;;
      *)
        echo "unsupported fake samtools command: $command" >&2
        exit 2
        ;;
    esac
    """.write(to: samtoolsURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsURL.path)
    return samtoolsURL
}

private let nvdCSVFixture = """
experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
EXP001,blastn,S1,contig-1,120,gb|NC_001|,Example virus species,S,118,99.2,1e-20,250.5,Example virus,12345,nt-2026,run-001,42,100000,stat-1,12345,unchanged,Example virus,species

"""

@discardableResult
private func expectImportProvenance(
    in resultDirectory: URL,
    workflowName: String,
    inputURLs: [URL],
    outputNames: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ProvenanceEnvelope {
    let sidecarURL = resultDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    #expect(FileManager.default.fileExists(atPath: sidecarURL.path), sourceLocation: sourceLocation)

    let envelope = try #require(
        try ProvenanceEnvelopeReader.load(from: resultDirectory),
        sourceLocation: sourceLocation
    )
    #expect(envelope.workflowName == workflowName, sourceLocation: sourceLocation)
    #expect(envelope.toolName == "lungfish import", sourceLocation: sourceLocation)
    #expect(envelope.exitStatus == 0, sourceLocation: sourceLocation)
    #expect(envelope.wallTimeSeconds != nil, sourceLocation: sourceLocation)
    #expect(envelope.options.resolvedDefaults["outputDirectory"]?.fileValue?.path == resultDirectory.path, sourceLocation: sourceLocation)
    #expect(envelope.argv.first == "lungfish-cli", sourceLocation: sourceLocation)

    let inputPaths = Set(envelope.files.filter { $0.role == .input }.map(\.path))
    for inputURL in inputURLs {
        var inputPathCandidates = Set([
            inputURL.path,
            inputURL.standardizedFileURL.path,
            inputURL.resolvingSymlinksInPath().path,
        ])
        for candidate in inputPathCandidates {
            if candidate.hasPrefix("/var/") {
                inputPathCandidates.insert("/private" + candidate)
            } else if candidate.hasPrefix("/private/var/") {
                inputPathCandidates.insert(String(candidate.dropFirst("/private".count)))
            }
        }
        #expect(!inputPaths.isDisjoint(with: inputPathCandidates), sourceLocation: sourceLocation)
        let descriptor = try #require(
            envelope.files.first { inputPathCandidates.contains($0.path) },
            sourceLocation: sourceLocation
        )
        if isRegularFileForProvenanceTest(inputURL) {
            #expect(descriptor.checksumSHA256 != nil, sourceLocation: sourceLocation)
            #expect(descriptor.fileSize != nil, sourceLocation: sourceLocation)
        } else {
            let childInputs = envelope.files.filter {
                let descriptorPath = $0.path
                return $0.role == .input && inputPathCandidates.contains { candidate in
                    descriptorPath.hasPrefix(candidate + "/")
                }
            }
            #expect(!childInputs.isEmpty, sourceLocation: sourceLocation)
            #expect(childInputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil }, sourceLocation: sourceLocation)
        }
    }

    let outputBasenames = Set(envelope.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent })
    for outputName in outputNames {
        #expect(outputBasenames.contains(outputName), sourceLocation: sourceLocation)
    }

    let resultOutput = try #require(envelope.output, sourceLocation: sourceLocation)
    #expect(resultOutput.path == resultDirectory.path, sourceLocation: sourceLocation)
    #expect(resultOutput.role == .output, sourceLocation: sourceLocation)
    return envelope
}

private func isRegularFileForProvenanceTest(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private func importNaoMgsForTesting(
    inputURL: URL,
    outputDirectory: URL,
    sampleName: String? = nil,
    minIdentity: Double = 0,
    fetchReferences: Bool = true,
    preferredName: String? = nil,
    progress: (@Sendable (Double, String) -> Void)? = nil
) async throws -> NaoMgsImportResult {
    try await withNaoMgsImportLock {
        try await MetagenomicsImportService.importNaoMgs(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            minIdentity: minIdentity,
            fetchReferences: fetchReferences,
            preferredName: preferredName,
            progress: progress
        )
    }
}

private func withNaoMgsImportLock<T>(_ body: () async throws -> T) async throws -> T {
    let lockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lungfish-naomgs-import-tests.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }

    guard flock(descriptor, LOCK_EX) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(descriptor, LOCK_UN) }

    return try await body()
}

private func esVirituDetectionFixture() -> String {
    [
        "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample",
        "SampleA\tExample virus\tExample description\t1000\t\tACCN0001\tGCF_000001\t1000\tViruses\t\t\t\tExampleviridae\tExamplevirus\tExample virus species\t\t1.5\t42\t900\t12.4\t97.2\t0.01\t10000",
    ].joined(separator: "\n")
}

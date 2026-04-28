import Foundation

enum ViralReconWorkflowTestFixtures {
    static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writeReferenceFASTA(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("MN908947.3.fasta")
        let sequence = String(repeating: "ACGT", count: 20)
        try ">MN908947.3\n\(sequence)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writeReferenceFASTA(in directory: URL, contents: String) throws -> URL {
        let url = directory.appendingPathComponent("MN908947.3.fasta")
        try (contents.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writePrimerBundleWithoutFasta(in directory: URL) throws -> URL {
        let bed = """
        MN908947.3\t0\t8\tamplicon_1_LEFT\t1\t+
        MN908947.3\t12\t20\tamplicon_1_RIGHT\t1\t-
        """
        return try writePrimerBundleWithoutFasta(in: directory, bed: bed)
    }

    static func writePrimerBundleWithoutFasta(in directory: URL, bed: String) throws -> URL {
        let bundleURL = directory.appendingPathComponent("QIASeqDIRECT-SARS2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = """
        {
          "schema_version": 1,
          "name": "qiaseq-direct-sars2",
          "display_name": "QIASeq DIRECT SARS-CoV-2",
          "description": "Viral Recon test fixture",
          "organism": "SARS-CoV-2",
          "reference_accessions": [
            { "accession": "MN908947.3", "canonical": true }
          ],
          "primer_count": 2,
          "amplicon_count": 1
        }
        """
        try manifest.write(to: bundleURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try (bed.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            .write(to: bundleURL.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
        try "Test fixture.\n".write(to: bundleURL.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
        return bundleURL
    }

    static func writeFastqBundle(
        named name: String,
        in directory: URL,
        fastqText: String,
        metadataCSV: String?,
        sidecarJSON: String?
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("\(name).fastq")
        try fastqText.write(to: fastqURL, atomically: true, encoding: .utf8)
        if let metadataCSV {
            try (metadataCSV.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
                .write(to: bundleURL.appendingPathComponent("metadata.csv"), atomically: true, encoding: .utf8)
        }
        if let sidecarJSON {
            try sidecarJSON.write(
                to: fastqURL.appendingPathExtension("lungfish-meta.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return bundleURL
    }
}

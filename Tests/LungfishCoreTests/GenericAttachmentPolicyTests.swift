import Foundation
import Testing
@testable import LungfishCore

@Suite("GenericAttachmentPolicy")
struct GenericAttachmentPolicyTests {
    @Test("Allows ordinary document attachment names")
    func allowsOrdinaryDocuments() throws {
        for filename in ["notes.pdf", "photo.jpg", "run-summary.txt", "metadata.csv", "sample-sheet.tsv"] {
            #expect(GenericAttachmentPolicy.scientificFormatDescription(forFilename: filename) == nil)
            try GenericAttachmentPolicy.validateNonScientificAttachmentSource(URL(fileURLWithPath: "/tmp/\(filename)"))
        }
    }

    @Test("Classifies known scientific payload and index names")
    func classifiesScientificPayloads() {
        let filenames = [
            "reads.fastq.gz",
            "reads.fq",
            "reference.fa.gz.fai",
            "variants.vcf.gz",
            "variants.vcf.gz.tbi",
            "alignments.bam",
            "alignments.bam.bai",
            "features.gff3",
            "regions.bed",
            "report.kreport",
            "profile.bracken",
            "tree.nwk",
            "result.sqlite",
            "Sample.lungfishfastq",
        ]

        for filename in filenames {
            #expect(
                GenericAttachmentPolicy.scientificFormatDescription(forFilename: filename) != nil,
                "\(filename) should be treated as scientific data"
            )
        }
    }

    @Test("Rejects known scientific payloads when validating non-scientific attachments")
    func rejectsScientificPayloadsForPlainAttachments() {
        #expect(throws: GenericAttachmentValidationError.self) {
            try GenericAttachmentPolicy.validateNonScientificAttachmentSource(
                URL(fileURLWithPath: "/tmp/reads.fastq.gz")
            )
        }
    }
}

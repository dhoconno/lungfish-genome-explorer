// SequencingPlatformPinTests.swift - Pins LungfishIO.SequencingPlatform parameters and spellings (R15)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Pins every read-processing parameter, header detection result and persisted
/// spelling of `LungfishIO.SequencingPlatform`, the canonical platform written
/// to FASTQ sidecars, barcode kits and demultiplex plans.
///
/// These expectations record what the code does today, not a scientific
/// ruling. They were written before the R15 reconciliation with the
/// LungfishWorkflow import platform and must pass unchanged after it. A change
/// here alters demultiplexing parameters, adapter specs or the bytes of files
/// on disk, so update an expectation only with a ruling from the owner.
final class SequencingPlatformPinTests: XCTestCase {

    // MARK: - Cases and read-processing parameters

    private struct ParameterRow {
        let platform: SequencingPlatform
        let rawValue: String
        let displayName: String
        let readsCanBeReverseComplemented: Bool
        let indexesInSeparateReads: Bool
        let mayNeedPolyGTrimming: Bool
        let defaultPolyGTrimQuality: Int?
        let recommendedErrorRate: Double
        let recommendedMinimumOverlap: Int
    }

    private let parameterRows: [ParameterRow] = [
        ParameterRow(
            platform: .illumina, rawValue: "illumina", displayName: "Illumina",
            readsCanBeReverseComplemented: false, indexesInSeparateReads: true,
            mayNeedPolyGTrimming: true, defaultPolyGTrimQuality: 20,
            recommendedErrorRate: 0.10, recommendedMinimumOverlap: 5
        ),
        ParameterRow(
            platform: .oxfordNanopore, rawValue: "oxfordNanopore", displayName: "Oxford Nanopore",
            readsCanBeReverseComplemented: true, indexesInSeparateReads: false,
            mayNeedPolyGTrimming: false, defaultPolyGTrimQuality: nil,
            recommendedErrorRate: 0.15, recommendedMinimumOverlap: 20
        ),
        ParameterRow(
            platform: .pacbio, rawValue: "pacbio", displayName: "PacBio",
            readsCanBeReverseComplemented: true, indexesInSeparateReads: false,
            mayNeedPolyGTrimming: false, defaultPolyGTrimQuality: nil,
            recommendedErrorRate: 0.10, recommendedMinimumOverlap: 14
        ),
        ParameterRow(
            platform: .element, rawValue: "element", displayName: "Element Biosciences",
            readsCanBeReverseComplemented: false, indexesInSeparateReads: true,
            mayNeedPolyGTrimming: true, defaultPolyGTrimQuality: 20,
            recommendedErrorRate: 0.10, recommendedMinimumOverlap: 5
        ),
        ParameterRow(
            platform: .ultima, rawValue: "ultima", displayName: "Ultima Genomics",
            readsCanBeReverseComplemented: false, indexesInSeparateReads: true,
            mayNeedPolyGTrimming: false, defaultPolyGTrimQuality: nil,
            recommendedErrorRate: 0.10, recommendedMinimumOverlap: 5
        ),
        ParameterRow(
            platform: .mgi, rawValue: "mgi", displayName: "MGI / DNBSEQ",
            readsCanBeReverseComplemented: false, indexesInSeparateReads: true,
            mayNeedPolyGTrimming: false, defaultPolyGTrimQuality: nil,
            recommendedErrorRate: 0.10, recommendedMinimumOverlap: 5
        ),
        ParameterRow(
            platform: .unknown, rawValue: "unknown", displayName: "Unknown",
            readsCanBeReverseComplemented: false, indexesInSeparateReads: false,
            mayNeedPolyGTrimming: false, defaultPolyGTrimQuality: nil,
            recommendedErrorRate: 0.10, recommendedMinimumOverlap: 5
        ),
    ]

    func testCaseListAndOrder() {
        XCTAssertEqual(SequencingPlatform.allCases, parameterRows.map(\.platform))
    }

    func testReadProcessingParametersPerPlatform() {
        for row in parameterRows {
            let platform = row.platform
            XCTAssertEqual(platform.rawValue, row.rawValue, "rawValue of \(row.rawValue)")
            XCTAssertEqual(platform.displayName, row.displayName, "displayName of \(row.rawValue)")
            XCTAssertEqual(
                platform.readsCanBeReverseComplemented, row.readsCanBeReverseComplemented,
                "readsCanBeReverseComplemented of \(row.rawValue)"
            )
            XCTAssertEqual(
                platform.indexesInSeparateReads, row.indexesInSeparateReads,
                "indexesInSeparateReads of \(row.rawValue)"
            )
            XCTAssertEqual(
                platform.mayNeedPolyGTrimming, row.mayNeedPolyGTrimming,
                "mayNeedPolyGTrimming of \(row.rawValue)"
            )
            XCTAssertEqual(
                platform.defaultPolyGTrimQuality, row.defaultPolyGTrimQuality,
                "defaultPolyGTrimQuality of \(row.rawValue)"
            )
            XCTAssertEqual(
                platform.recommendedErrorRate, row.recommendedErrorRate,
                "recommendedErrorRate of \(row.rawValue)"
            )
            XCTAssertEqual(
                platform.recommendedMinimumOverlap, row.recommendedMinimumOverlap,
                "recommendedMinimumOverlap of \(row.rawValue)"
            )
        }
    }

    func testEachCaseEncodesAsItsRawValueString() throws {
        for row in parameterRows {
            let encoded = try JSONEncoder().encode(row.platform)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(row.rawValue)\"")
            let decoded = try JSONDecoder().decode(SequencingPlatform.self, from: Data("\"\(row.rawValue)\"".utf8))
            XCTAssertEqual(decoded, row.platform)
        }
    }

    func testImportSubsetSpellingsAreNotRawValues() {
        // The LungfishWorkflow import platform spells Oxford Nanopore "ont".
        // That spelling is a vendor alias here, never a raw value.
        XCTAssertNil(SequencingPlatform(rawValue: "ont"))
        XCTAssertNil(SequencingPlatform(rawValue: "ONT"))
        XCTAssertNil(SequencingPlatform(rawValue: "Illumina"))
        XCTAssertEqual(SequencingPlatform(vendor: "ont"), .oxfordNanopore)
    }

    // MARK: - Vendor aliases

    func testVendorAliases() {
        let aliases: [(String, SequencingPlatform)] = [
            ("illumina", .illumina),
            ("ILLUMINA", .illumina),
            ("oxford-nanopore", .oxfordNanopore),
            ("oxford_nanopore", .oxfordNanopore),
            ("oxfordnanopore", .oxfordNanopore),
            ("oxfordNanopore", .oxfordNanopore),
            ("ont", .oxfordNanopore),
            ("pacbio", .pacbio),
            ("pacific-biosciences", .pacbio),
            ("pacific_biosciences", .pacbio),
            ("element", .element),
            ("element-biosciences", .element),
            ("ultima", .ultima),
            ("ultima-genomics", .ultima),
            ("mgi", .mgi),
            ("bgi", .mgi),
            ("dnbseq", .mgi),
            ("mgi-tech", .mgi),
            ("nanopore", .unknown),
            ("oxford nanopore", .unknown),
            ("pacbio-hifi", .unknown),
            ("hifi", .unknown),
            ("ilmn", .unknown),
            ("unknown", .unknown),
            ("", .unknown),
        ]
        for (vendor, expected) in aliases {
            XCTAssertEqual(SequencingPlatform(vendor: vendor), expected, "vendor \"\(vendor)\"")
        }
    }

    // MARK: - Header detection

    /// Representative headers with today's `detect(fromHeader:)` result. The
    /// LungfishWorkflow import platform has its own detector, pinned against
    /// the same headers in LungfishWorkflowTests (WorkflowPlatformPinTests).
    static let headerDetections: [(label: String, header: String, expected: SequencingPlatform?)] = [
        (
            "MinKNOW header with every key",
            "@0a1b2c3d-4e5f-6789-abcd-ef0123456789 runid=8a9b0c1d2e3f405162738495a6b7c8d9e0f1a2b3 sampleid=s1 read=12 ch=34 start_time=2023-05-01T10:20:30Z flow_cell_id=FAW12345 protocol_group_id=run1 sample_id=s1 barcode=barcode01 basecall_model_version_id=dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
            .oxfordNanopore
        ),
        (
            "Guppy header with start_time and flow_cell_id",
            "@0a1b2c3d-4e5f-6789-abcd-ef0123456789 runid=8a9b0c1d read=12 ch=34 start_time=2019-05-01T10:20:30Z flow_cell_id=FAK12345",
            .oxfordNanopore
        ),
        ("ONT header with runid only", "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1", nil),
        ("basecall_gpu key only", "@read1 basecall_gpu=Tesla_V100", .oxfordNanopore),
        ("start_time without flow_cell_id", "@read1 start_time=2019-05-01T10:20:30Z", nil),
        (
            "dorado SAM tags in the header",
            "@0a1b2c3d-4e5f-6789-abcd-ef0123456789\tqs:f:12.5\tdu:f:3.2\tns:i:16000\tch:i:123\tst:Z:2023-05-01T10:20:30.000+00:00\tRG:Z:8a9b0c1d_dna_r10.4.1_e8.2_400bps_sup@v4.2.0",
            .illumina
        ),
        ("PacBio Sequel CCS", "@m64011_190830_220126/101/ccs", .pacbio),
        ("PacBio Revio CCS", "@m84011_220902_175841_s1/12345/ccs", .pacbio),
        ("PacBio by-strand CCS", "@m64011_190830_220126/101/ccs/fwd", .pacbio),
        ("PacBio subread", "@m54006_160504_020705/4194370/0_3920", nil),
        ("zmw anywhere in the header", "@read_zmw_123", .pacbio),
        ("Illumina CASAVA 1.8 with comment", "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT", .illumina),
        ("Illumina CASAVA 1.8 without @", "A00488:61:HMLGNDSXX:4:1101:1234:5678", .illumina),
        ("Illumina MiSeq flow cell with a dash", "@M00123:45:000000000-ABCDE:1:1101:15589:1333 1:N:0:1", .illumina),
        ("Illumina pre-1.8", "@HWUSI-EAS100R:6:73:941:1973#0/1", nil),
        ("SRA spot name", "@SRR12345678.1 1 length=150", nil),
        ("SRA spot with original Illumina name", "@SRR6750055.1 A00123:8:H5YNKDSXX:1:1101:1000:1000 length=151", .illumina),
        ("seven non-numeric colon fields", "@a:b:c:d:e:f:g", .illumina),
        ("six colon fields", "@a:b:c:d:e:f", nil),
        ("MGI DNBSEQ", "@V350012345L1C001R00100000001/1", nil),
        ("generic read name", "@read1 some random format", nil),
        ("empty", "", nil),
        ("bare @", "@", nil),
    ]

    func testHeaderDetection() {
        for row in Self.headerDetections {
            XCTAssertEqual(SequencingPlatform.detect(fromHeader: row.header), row.expected, row.label)
        }
    }

    // MARK: - FASTQ file detection

    /// `@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT` record, gzip with mtime 0.
    private static let gzippedIlluminaRecord = "H4sIAAAAAAAC/3NwNDAwsbCwMjO08vD1cfdzCY6IsDKxMjQ0MLQyNDI2sTI1M7dQMLTyszKwcnR2DwFhLjChzeUJBFwAkoffTUEAAAA="

    /// Guppy-style ONT record with runid, start_time and flow_cell_id, gzip with mtime 0.
    private static let gzippedONTRecord = "H4sIAAAAAAAC/x2NSwrCMBQA9zlF9hJ4L2m0LQQsguK+ILgJ+dJCqpJEvL7RWQ4McwSDljvhWRdkZPtDPzBjnWchAnLRyZ+h+f1YverNYMGhp8VsrxSaKUhzMF4hp25RoqOlmlx1XbegOHDBQDLAGWHkMAq405ieH+1CSrrV5+n2X5DpdJnJjlwb5AsI1wpNkQAAAA=="

    func testFASTQFileDetectionReadsOnlyTheFirstHeader() throws {
        let root = try TestTempDirectory.make(prefix: "sequencing-platform-pin")
        defer { TestTempDirectory.cleanup(root) }

        let plainONT = root.appendingPathComponent("ont.fastq")
        try "@read1 basecall_gpu=Tesla_V100\nACGT\n+\nIIII\n@A00488:61:HMLGNDSXX:4:1101:1234:5678\nACGT\n+\nIIII\n"
            .write(to: plainONT, atomically: true, encoding: .utf8)
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQ: plainONT), .oxfordNanopore)

        let plainPacBio = root.appendingPathComponent("pacbio.fq")
        try "@m64011_190830_220126/101/ccs\nACGT\n+\nIIII\n".write(to: plainPacBio, atomically: true, encoding: .utf8)
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQ: plainPacBio), .pacbio)

        let gzippedIllumina = root.appendingPathComponent("illumina.fastq.gz")
        try XCTUnwrap(Data(base64Encoded: Self.gzippedIlluminaRecord)).write(to: gzippedIllumina)
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQ: gzippedIllumina), .illumina)

        let gzippedONT = root.appendingPathComponent("ont.fastq.gz")
        try XCTUnwrap(Data(base64Encoded: Self.gzippedONTRecord)).write(to: gzippedONT)
        XCTAssertEqual(SequencingPlatform.detect(fromFASTQ: gzippedONT), .oxfordNanopore)

        let generic = root.appendingPathComponent("generic.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: generic, atomically: true, encoding: .utf8)
        XCTAssertNil(SequencingPlatform.detect(fromFASTQ: generic))

        let empty = root.appendingPathComponent("empty.fastq")
        try Data().write(to: empty)
        XCTAssertNil(SequencingPlatform.detect(fromFASTQ: empty))

        XCTAssertNil(SequencingPlatform.detect(fromFASTQ: root.appendingPathComponent("missing.fastq")))
    }

    // MARK: - Adapter context selection

    private static let pinBarcode = "ACGTTGCAAGGT"

    /// The adapter context `adapterContext(kitType:)` returns today for each
    /// platform and kit type, built explicitly so the specs can be compared.
    private func expectedAdapterContext(
        platform: SequencingPlatform,
        kitType: BarcodeKitType
    ) -> any PlatformAdapterContext {
        switch (platform, kitType) {
        case (.oxfordNanopore, .fluidigmAccessArray): return BareAdapterContext()
        case (.oxfordNanopore, .rapidBarcoding): return ONTRapidAdapterContext()
        case (.oxfordNanopore, _): return ONTNativeAdapterContext()
        case (.pacbio, .pacbioM13Amplicon): return PacBioM13AdapterContext(includePrimerInSpec: false)
        case (.pacbio, _): return PacBioAdapterContext()
        case (.illumina, .nextera): return IlluminaNexteraAdapterContext()
        case (.illumina, _), (.element, _), (.ultima, _): return IlluminaTruSeqAdapterContext()
        case (.mgi, _): return MGIAdapterContext()
        case (.unknown, _): return BareAdapterContext()
        }
    }

    func testAdapterContextPerPlatformAndKitType() {
        let barcode = Self.pinBarcode
        for platform in SequencingPlatform.allCases {
            for kitType in BarcodeKitType.allCases {
                let actual = platform.adapterContext(kitType: kitType)
                let expected = expectedAdapterContext(platform: platform, kitType: kitType)
                let label = "\(platform.rawValue) with \(kitType.rawValue)"
                XCTAssertEqual(
                    String(describing: type(of: actual)), String(describing: type(of: expected)), label
                )
                XCTAssertEqual(
                    actual.fivePrimeSpec(barcodeSequence: barcode),
                    expected.fivePrimeSpec(barcodeSequence: barcode), label
                )
                XCTAssertEqual(
                    actual.threePrimeSpec(barcodeSequence: barcode, readDirection: .read1),
                    expected.threePrimeSpec(barcodeSequence: barcode, readDirection: .read1), label
                )
                XCTAssertEqual(
                    actual.threePrimeSpec(barcodeSequence: barcode, readDirection: .read2),
                    expected.threePrimeSpec(barcodeSequence: barcode, readDirection: .read2), label
                )
                XCTAssertEqual(
                    actual.linkedSpec(barcodeSequence: barcode),
                    expected.linkedSpec(barcodeSequence: barcode), label
                )
            }
        }
        // The default kit type is custom.
        XCTAssertEqual(
            SequencingPlatform.oxfordNanopore.adapterContext().linkedSpec(barcodeSequence: barcode),
            ONTNativeAdapterContext().linkedSpec(barcodeSequence: barcode)
        )
    }

    // MARK: - Persisted spellings

    func testFASTQSidecarSpellsEachPlatformByRawValue() throws {
        let root = try TestTempDirectory.make(prefix: "sequencing-platform-sidecar-pin")
        defer { TestTempDirectory.cleanup(root) }

        for row in parameterRows {
            // Old sidecars decode.
            let literal = Data("{\"sequencingPlatform\":\"\(row.rawValue)\"}".utf8)
            let decoded = try JSONDecoder().decode(PersistedFASTQMetadata.self, from: literal)
            XCTAssertEqual(decoded.sequencingPlatform, row.platform, row.rawValue)

            // New sidecars encode the same spelling.
            let fastqURL = root.appendingPathComponent("\(row.rawValue).fastq")
            try "@r1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
            FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: row.platform), for: fastqURL)
            let sidecar = try Data(contentsOf: FASTQMetadataStore.metadataURL(for: fastqURL))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
            XCTAssertEqual(object["sequencingPlatform"] as? String, row.rawValue, row.rawValue)
            XCTAssertEqual(FASTQMetadataStore.load(for: fastqURL)?.sequencingPlatform, row.platform)
        }

        // A sidecar that spells the import subset ("ont") does not decode.
        XCTAssertThrowsError(
            try JSONDecoder().decode(PersistedFASTQMetadata.self, from: Data("{\"sequencingPlatform\":\"ont\"}".utf8))
        )
    }

    func testAssemblyReadTypeFromPlatform() {
        let expected: [(SequencingPlatform, FASTQAssemblyReadType?)] = [
            (.illumina, .illuminaShortReads),
            (.oxfordNanopore, .ontReads),
            (.pacbio, nil),
            (.element, nil),
            (.ultima, nil),
            (.mgi, nil),
            (.unknown, nil),
        ]
        XCTAssertEqual(expected.map(\.0), SequencingPlatform.allCases)
        for (platform, readType) in expected {
            XCTAssertEqual(FASTQAssemblyReadType(sequencingPlatform: platform), readType, platform.rawValue)
        }
        XCTAssertEqual(FASTQAssemblyReadType.allCases.map(\.rawValue), ["illuminaShortReads", "ontReads", "pacBioHiFi"])
    }

    func testBarcodeKitDefinitionSpellsEachPlatformByRawValue() throws {
        for row in parameterRows {
            let kit = BarcodeKitDefinition(
                id: "pin-\(row.rawValue)",
                displayName: "Pin \(row.rawValue)",
                vendor: "custom",
                platform: row.platform,
                barcodes: [BarcodeEntry(id: "bc01", i7Sequence: "ACGTACGT")]
            )
            let encoded = try JSONEncoder().encode(kit)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["platform"] as? String, row.rawValue, row.rawValue)

            let literal = Data(
                "{\"id\":\"k\",\"displayName\":\"K\",\"vendor\":\"custom\",\"platform\":\"\(row.rawValue)\",\"barcodes\":[]}".utf8
            )
            XCTAssertEqual(try JSONDecoder().decode(BarcodeKitDefinition.self, from: literal).platform, row.platform)
        }

        // Kits saved before the platform key existed fall back to the vendor.
        let vendorOnly: [(String, SequencingPlatform)] = [
            ("oxford_nanopore", .oxfordNanopore),
            ("pacbio", .pacbio),
            ("illumina", .illumina),
            ("custom", .unknown),
        ]
        for (vendor, expected) in vendorOnly {
            let literal = Data("{\"id\":\"k\",\"displayName\":\"K\",\"vendor\":\"\(vendor)\",\"barcodes\":[]}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(BarcodeKitDefinition.self, from: literal).platform, expected, vendor)
        }
        let noVendor = Data("{\"id\":\"k\",\"displayName\":\"K\",\"barcodes\":[]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(BarcodeKitDefinition.self, from: noVendor).platform, .illumina)
    }
}

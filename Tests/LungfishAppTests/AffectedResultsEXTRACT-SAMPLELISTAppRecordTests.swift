// AffectedResultsEXTRACT-SAMPLELISTAppRecordTests.swift - The kind of EXTRACT-SCAN-EXTENDED-ID against the file record of the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17, lane EXTRACT-SAMPLELIST, fix round 1 (BIO review B2). The File destination of the Extract Reads sheet
// records its extraction as "lungfish app classifier read extraction" (`TaxonomyReadExtractionAction.swift:690`) and names
// the classifier in the `tool` option (`:627`), as `lungfish extract reads` does. This test builds that record the way the
// app does and reads the kind from the sidecar that the writer made. The bundle record of the app is held by
// `AffectedResultsExtractSampleListTests`, which needs no app code.

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class AffectedResultsExtractSampleListAppRecordTests: XCTestCase {
    /// The options of the action carry the file provenance, and `ClassifierReadResolver.swift:737-761` turns it into the
    /// request of the sidecar writer, which this test repeats. Red at the base, where the kind knows no such record.
    func testTheFileRecordOfTheAppForATaxTriageExtractionIsTheKind() throws {
        let cases: [(ClassifierTool, AffectedResultKind?)] = [(.taxtriage, .taxTriageReadExtraction), (.esviritu, nil)]
        for (tool, expected) in cases {
            let root = try TestTempDirectory.make(prefix: "AffectedExtractFile")
            defer { TestTempDirectory.cleanup(root) }
            let source = root.appendingPathComponent("source.bam")
            try Data("BAM".utf8).write(to: source)
            let out = root.appendingPathComponent("extract.fastq")
            try "@r1\nACGT\n+\nIIII\n".write(to: out, atomically: true, encoding: .utf8)

            let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
            let context = TaxonomyReadExtractionAction.Context(
                tool: tool, resultPath: root,
                selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001"], taxIds: [])],
                suggestedName: "x"
            )
            let recorded = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
                options, context: context, destination: .file(out)
            )
            let provenance = try XCTUnwrap(recorded.fileProvenance)
            let request = ScientificFileExportProvenance.Request(
                workflowName: provenance.workflowName, toolName: provenance.toolName, toolKind: "gui",
                sourceURLs: [source], outputURL: out, outputFormat: options.format.fileFormat,
                argv: provenance.argv, durableReplayArgv: provenance.durableReplayArgv,
                explicitOptions: provenance.explicitOptions, defaults: provenance.defaults,
                resolved: provenance.resolved, startedAt: Date(), completedAt: Date()
            )
            _ = try ScientificFileExportProvenance.write(request)
            let record = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: out))
            )
            XCTAssertEqual(record.workflowName, AffectedResults.RecordName.appClassifierReadExtraction, "\(tool)")
            XCTAssertEqual(AffectedResults.kind(of: record), expected, "\(tool)")
        }
    }
}

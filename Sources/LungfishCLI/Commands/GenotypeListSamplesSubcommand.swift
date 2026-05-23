import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// List samples in an ONT genotype result bundle with per-locus top calls.
///
/// Output is tab-separated and one row per sample. Columns:
///   1. animal id (sample id with `--no-strip-prefix` semantics; defaults to
///      stripped variant when available, falling back to the gs id)
///   2. gs id (raw bundle sample identifier)
///   3. qc status (raw value, e.g. `ok`, `lowSupport`, `review`)
///   4. total reads (sample-level passed alignment count)
///   5. top genotype per locus, joined by `;` in canonical locus order (e.g.
///      `MHC-A=Mafa-A1*063:02_M1A;MHC-B=Mafa-B*012:01_M3B`)
struct GenotypeListSamplesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-samples",
        abstract: "List samples and their top genotype call per locus from a genotype bundle"
    )

    @Option(name: .customLong("bundle"), help: "Path to a `.lungfishgenotype` result bundle")
    var bundle: String

    func validate() throws {
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
    }

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)

        let header = ["animal_id", "gs_id", "qc_status", "total_reads", "top_calls_by_locus"]
        var lines: [String] = []
        lines.append(header.joined(separator: "\t"))

        for sample in result.samples {
            let topCallsByLocus = topCallsByLocus(for: sample, in: result)
            let topCallsColumn = topCallsByLocus.isEmpty
                ? "-"
                : topCallsByLocus
                    .map { "\($0.locus)=\($0.genotype)" }
                    .joined(separator: ";")

            let animalId = sample.sample
            let gsId = sample.sample
            let totalReads = sample.passedAlignments

            let row = [
                animalId,
                gsId,
                sample.qcStatus.rawValue,
                String(totalReads),
                topCallsColumn,
            ]
            lines.append(row.joined(separator: "\t"))
        }

        let output = lines.joined(separator: "\n") + "\n"
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    private struct LocusTopCall {
        let locus: String
        let genotype: String
    }

    /// Picks the top call per locus group for the sample.
    ///
    /// `ONTGenotypeSampleResult.calls` is already sorted by `passedAlignments`
    /// descending so we just take the first call seen per locus.
    private func topCallsByLocus(
        for sample: ONTGenotypeSampleResult,
        in result: ONTGenotypeResultBundleData
    ) -> [LocusTopCall] {
        var seen: Set<String> = []
        var picks: [LocusTopCall] = []
        for call in sample.calls {
            let locus = call.locusGroup
            if seen.insert(locus).inserted {
                picks.append(LocusTopCall(locus: locus, genotype: call.genotype))
            }
        }
        return picks.sorted { lhs, rhs in
            lhs.locus.localizedStandardCompare(rhs.locus) == .orderedAscending
        }
    }
}

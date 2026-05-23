import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// List the smart-cohort filters stored in a genotype bundle's annotation sidecar.
///
/// Output is tab-separated, one row per cohort, with these columns:
///   1. starred flag (`*` if `isStarred`, else `-`)
///   2. cohort name
///   3. scope (e.g. `bundle`, `cross-bundle`)
///   4. matching subject count (predicate evaluated over each sample as a
///      minimal `GenotypeCohortSubject` derived from the bundle data)
///   5. description (or `-` if absent)
struct GenotypeListCohortsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-cohorts",
        abstract: "List smart cohorts defined in a genotype bundle's annotation sidecar"
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
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )

        // Build per-sample subjects for predicate evaluation. We only need to
        // populate the subset of fields that the CLI surface can derive from
        // the bundle without the App-side classifier; richer Smart Cohort
        // dimensions (highlights, manual flags) come from the sidecar.
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        let subjects = makeSubjects(from: result, sidecar: sidecar)

        let header = ["starred", "name", "scope", "matches", "description"]
        var lines: [String] = [header.joined(separator: "\t")]
        for cohort in sidecar.smartCohorts {
            let matchCount = subjects.reduce(into: 0) { count, subject in
                if cohort.predicate.evaluate(subject) {
                    count += 1
                }
            }
            let row = [
                cohort.isStarred ? "*" : "-",
                cohort.name,
                cohort.scope,
                String(matchCount),
                cohort.description?.isEmpty == false ? cohort.description! : "-",
            ]
            lines.append(row.joined(separator: "\t"))
        }

        let output = lines.joined(separator: "\n") + "\n"
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    /// Build minimal cohort subjects from bundle samples + sidecar status flags.
    private func makeSubjects(
        from result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar
    ) -> [GenotypeCohortSubject] {
        let statusBySample = Dictionary(
            uniqueKeysWithValues: sidecar.sampleStatusFlags.map { ($0.sample, $0.value) }
        )
        let commentsBySample = Dictionary(grouping: sidecar.sampleNotes, by: \.sample)
        let cellCommentsBySample = Dictionary(grouping: sidecar.cellComments, by: \.sample)
        let highlightFillsBySample = Dictionary(grouping: sidecar.cellHighlights, by: \.sample)
            .mapValues { hits in hits.compactMap(\.fillColor) }
        let highlightBordersBySample = Dictionary(grouping: sidecar.cellHighlights, by: \.sample)
            .mapValues { hits in hits.compactMap(\.borderColor) }

        return result.samples.map { sample in
            let sampleCommentBodies = (commentsBySample[sample.sample] ?? []).map(\.body)
            let cellCommentBodies = (cellCommentsBySample[sample.sample] ?? []).map(\.body)
            let commentsJoined = (sampleCommentBodies + cellCommentBodies).joined(separator: "\n")

            let calls = sample.calls.flatMap { call -> [GenotypeCohortSubject.Call] in
                let locus = call.locusGroup
                return [HaplotypeSlot.h1, HaplotypeSlot.h2].map { slot in
                    GenotypeCohortSubject.Call(
                        locus: locus,
                        slot: slot,
                        name: call.genotype,
                        isHomozygous: false,
                        isError: false,
                        isRecombinant: false,
                        readCount: call.passedUniqueReads
                    )
                }
            }

            return GenotypeCohortSubject(
                animalId: sample.sample,
                gsId: sample.sample,
                qcStatus: sample.qcStatus,
                totalReads: sample.passedAlignments,
                unmappedPercent: 0,
                comments: commentsJoined,
                calls: calls,
                hasAnyComment: !commentsJoined.isEmpty,
                hasErrorAtAnyLocus: false,
                isHomozygousAcrossAll: false,
                hasRegionalRecombinant: false,
                hasAtypicalPattern: false,
                statusValue: statusBySample[sample.sample] ?? .unflagged,
                highlightFills: highlightFillsBySample[sample.sample] ?? [],
                highlightBorders: highlightBordersBySample[sample.sample] ?? []
            )
        }
    }
}

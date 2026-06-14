import ArgumentParser
import Foundation

/// Parent command for genotype-bundle inspector operations.
///
/// Provides read-only inspection of `.lungfishgenotype` result bundles and
/// merge-style write access to the annotation sidecar that lives peer to
/// `genotype-result.json` inside each bundle.
struct GenotypeCommandGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genotype",
        abstract: "Inspect and annotate ONT genotype result bundles",
        discussion: """
            Operate on `.lungfishgenotype` bundles produced by the genotype
            pipelines. All subcommands take `--bundle <path>` and either print
            to stdout (read-only inspection) or merge into the annotation
            sidecar (`annotations.json`) that lives next to the bundle's
            primary `genotype-result.json` manifest. The `ai-haplotyping`
            subcommand is a scientific write workflow: it appends a versioned
            AI haplotype analysis revision with provenance and review metadata.
            """,
        subcommands: [
            GenotypeListSamplesSubcommand.self,
            GenotypeListCohortsSubcommand.self,
            GenotypeAIHaplotypingSubcommand.self,
            GenotypeApplyAnnotationsSubcommand.self,
            GenotypeExportSubcommand.self,
            GenotypeExportXlsxSubcommand.self,
            GenotypeExportPivotXlsxSubcommand.self,
            GenotypeExportLabKeySubcommand.self,
        ]
    )
}

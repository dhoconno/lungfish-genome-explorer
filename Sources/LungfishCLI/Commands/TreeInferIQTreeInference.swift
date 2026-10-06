import Foundation
import LungfishIO

/// The support labels for the "/"-joined values IQ-TREE writes on internal nodes, in IQ-TREE's
/// order: SH-aLRT, aBayes, UFBoot (ruling C8). Nil when the run asked for no branch support.
func iqtreeSupportLabels(alrt: Int?, bootstrap: Int?, advancedArguments: [String]) -> [String]? {
    var labels: [String] = []
    if alrt != nil {
        labels.append(PhylogeneticTreeSupportLabel.shALRT)
    }
    if advancedArguments.contains(where: { $0 == "--abayes" || $0 == "-abayes" }) {
        labels.append(PhylogeneticTreeSupportLabel.aBayes)
    }
    if bootstrap != nil {
        labels.append(PhylogeneticTreeSupportLabel.ufBoot)
    }
    return labels.isEmpty ? nil : labels
}

/// True when the IQ-TREE `-m` value asks ModelFinder to pick the model (MFP, TEST and their
/// +MERGE forms), false for a fixed model such as "GTR+F+G4".
func iqtreeModelRunsModelSelection(_ model: String) -> Bool {
    let base = model.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "+", maxSplits: 1)
        .first
        .map { $0.uppercased() } ?? ""
    return base.hasPrefix("MF") || base.hasPrefix("TEST")
}

/// What the run asked for and the scope it ran on, for the tree manifest's inference summary.
struct IQTreeInferenceRunDetails {
    let programVersion: String
    let requestedModel: String
    let sequenceType: String?
    let effectiveSeed: String?
    let threads: Int?
    let ufBootReplicates: Int?
    let shALRTReplicates: Int?
    let outgroupRows: [IQTreeStagedRow]
    let outgroupWarning: String?
    let msaBundleURL: URL
    let msaManifest: MultipleSequenceAlignmentBundle.Manifest
    let selectedRowCount: Int
    let selectedColumns: String?
    let selectedAlignedLength: Int
}

/// Builds the ruling C8 summary from run.iqtree and the run details. A fixed model has no
/// best-fit model, and its criterion reads "fixed".
func iqtreeInferenceSummary(report: String, run: IQTreeInferenceRunDetails) -> PhylogeneticTreeInferenceSummary {
    let fields = IQTreeReportParser.parse(report)
    let selectsModel = iqtreeModelRunsModelSelection(run.requestedModel)
    let columns = run.selectedColumns?.trimmingCharacters(in: .whitespacesAndNewlines)
    return PhylogeneticTreeInferenceSummary(
        program: "IQ-TREE",
        programVersion: run.programVersion,
        requestedModel: run.requestedModel,
        bestFitModel: selectsModel ? fields.bestFitModel : nil,
        modelSelectionCriterion: selectsModel ? fields.modelSelectionCriterion : "fixed",
        substitutionModel: fields.substitutionModel,
        logLikelihood: fields.logLikelihood,
        logLikelihoodStandardError: fields.logLikelihoodStandardError,
        freeParameters: fields.freeParameters,
        ufBootReplicates: run.ufBootReplicates,
        shALRTReplicates: run.shALRTReplicates,
        sequenceType: run.sequenceType ?? "auto",
        seed: run.effectiveSeed.flatMap { Int($0) },
        threads: run.threads,
        outgroup: run.outgroupRows.isEmpty ? nil : run.outgroupRows.map(\.displayName),
        outgroupWarning: run.outgroupWarning,
        sourceAlignmentName: run.msaManifest.name,
        sourceAlignmentPath: run.msaBundleURL.path,
        selectedRowCount: run.selectedRowCount,
        totalRowCount: run.msaManifest.rowCount,
        selectedColumns: (columns?.isEmpty ?? true) ? nil : columns,
        alignedLength: run.selectedAlignedLength
    )
}

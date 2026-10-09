import LungfishIO

extension PrimerDesignDialogState {
  /// What the chosen grouping does for the chosen engine. The engines share
  /// the word "combined" but not its meaning: Olivar tiles each alignment
  /// separately and only optimizes primer dimers across them, while
  /// PrimalScheme builds one panel against every alignment's primers.
  var groupingDescription: String {
    switch (grouping, engine) {
    case (.combined, .olivar):
      return "Olivar tiles each alignment separately, so amplicon positions match one-scheme-per-MSA runs. "
        + "It then chooses each tile's primers to minimize predicted dimers across all alignments that share a pool. "
        + "Expect the same tiles with some primers shifted."
    case (.combined, .primalScheme):
      return "PrimalScheme builds one panel, adding amplicons to each alignment in turn and rejecting any primer "
        + "that would dimerize with primers already in its pool. With many alignments the pools fill up, "
        + "coverage drops and run time grows quickly. Raise the pool count or split the targets into smaller panels."
    default:
      return "Each alignment is designed in its own run and keeps its input identity. "
        + "Primers from different schemes are never checked against each other, "
        + "so pooling them later can create cross-scheme primer dimers."
    }
  }
}

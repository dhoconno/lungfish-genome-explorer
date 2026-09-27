import AppKit
import SwiftUI
import LungfishWorkflow

struct PrimerSchemeAdvancedOptionsView: View {
  @Bindable var state: PrimerDesignDialogState
  @State private var rejectedScreeningNames: [String]?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      field("CPU workers", $state.schemeWorkers)
      if state.engine == .olivar { olivar }
      if state.engine == .varVAMP { varVAMP }
    }
  }

  private var olivar: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Olivar native settings").font(.subheadline.weight(.medium))
      HStack {
        field("Minimum variant frequency (--min-var)", $state.olivarMinimumVariantFrequency)
        field("Maximum primer length", $state.olivarMaximumPrimerLength)
        field("Minimum complexity", $state.olivarMinimumComplexity)
      }
      Toggle("Design degenerate oligos", isOn: $state.olivarDegenerate)
      Toggle("Avoid variants at binding sites", isOn: $state.olivarCheckVariants)
      HStack {
        field("Minimum GC fraction", $state.olivarMinimumGC)
        field("Maximum GC fraction", $state.olivarMaximumGC)
      }
      HStack {
        field("Temperature (°C)", $state.olivarTemperatureC)
        field("Salinity (M)", $state.olivarSalinityM)
        // Olivar's dG_max bounds how tightly a primer may bind its own target,
        // which is what limits primer length and stability. It is not a dimer
        // threshold, and calling it one sent readers looking for the wrong effect.
        field("Maximum primer-target binding ΔG (--dG-max)", $state.olivarMaximumDimerDeltaG)
      }
      Text("Maximum primer-target binding ΔG bounds each primer's own binding free energy, which is how Olivar limits primer length and stability. It is not a primer-dimer threshold.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        field("Random seed", $state.olivarSeed)
        field("Search effort", $state.olivarEffort)
      }
      Text("Native risk weights").font(.subheadline.weight(.medium))
      HStack {
        field("Extreme GC", $state.olivarRiskExtremeGC)
        field("Low complexity", $state.olivarRiskLowComplexity)
        field("Non-specificity", $state.olivarRiskNonSpecificity)
      }
      HStack {
        field("Variation", $state.olivarRiskVariation)
        field("Sensitivity", $state.olivarRiskSensitivity)
        field("Combination", $state.olivarRiskCombination)
      }
      offTargetScreening
      Text("Olivar minimum variant frequency keeps upstream --min-var semantics. The target size is nominal; requested minimum and maximum are the enforced full-span bounds.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var varVAMP: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("varVAMP native settings").font(.subheadline.weight(.medium))
      HStack {
        field("Maximum primer ambiguities", $state.varVAMPMaximumPrimerAmbiguities)
        if state.schemeMode == .qpcr {
          field("Maximum probe ambiguities (blank = native)", $state.varVAMPMaximumProbeAmbiguities)
        }
      }
      if state.schemeMode == .tiled {
        field("Tiled overlap (bp)", $state.varVAMPTiledOverlap)
      } else if state.schemeMode == .single {
        field("Reported assays (blank = native)", $state.varVAMPReportCount)
      } else {
        HStack {
          field("qPCR test count", $state.varVAMPQPCRTestCount)
          field("qPCR ΔG setting", $state.varVAMPQPCRDeltaG)
        }
      }
      HStack {
        field("Scheme name", $state.varVAMPSchemeName)
        field("Compatible-primer input path (optional)", $state.varVAMPCompatiblePrimersPath)
      }
      offTargetScreening
      Text("Primer constraints").font(.subheadline.weight(.medium))
      HStack {
        field("Length minimum", $state.varVAMPPrimerSizeMinimum)
        field("Length optimum", $state.varVAMPPrimerSizeOptimum)
        field("Length maximum", $state.varVAMPPrimerSizeMaximum)
      }
      HStack {
        field("Tm minimum", $state.varVAMPPrimerTmMinimum)
        field("Tm optimum", $state.varVAMPPrimerTmOptimum)
        field("Tm maximum", $state.varVAMPPrimerTmMaximum)
      }
      HStack {
        field("GC minimum (%)", $state.varVAMPPrimerGCMinimum)
        field("GC optimum (%)", $state.varVAMPPrimerGCOptimum)
        field("GC maximum (%)", $state.varVAMPPrimerGCMaximum)
      }
      HStack {
        field("Maximum homopolymer", $state.varVAMPPrimerMaximumPolyX)
        field("Maximum dinucleotide repeats", $state.varVAMPPrimerMaximumDinucleotideRepeats)
        field("Hairpin threshold", $state.varVAMPPrimerHairpin)
      }
      HStack {
        field("Maximum dimer Tm", $state.varVAMPPrimerMaximumDimerTemperature)
        field("Maximum dimer ΔG", $state.varVAMPPrimerMaximumDimerDeltaG)
        field("Unambiguous 3′ bases", $state.varVAMPPrimerMinimum3PrimeWithoutAmbiguity)
      }
      HStack {
        field("GC bases at primer 3′ minimum", $state.varVAMPPrimerGCEndMinimum)
        field("GC bases at primer 3′ maximum", $state.varVAMPPrimerGCEndMaximum)
        field("End overlap", $state.varVAMPEndOverlap)
      }
      if state.schemeMode == .qpcr { probe }
      DisclosureGroup("Chemistry and masking defaults") {
        VStack(alignment: .leading, spacing: 10) {
          field("Terminal masking threshold", $state.varVAMPTerminalMaskingThreshold)
          HStack {
            field("Monovalent cation", $state.varVAMPMonovalentCationConcentration)
            field("Divalent cation", $state.varVAMPDivalentCationConcentration)
            field("dNTP", $state.varVAMPDNTPConcentration)
            field("DNA", $state.varVAMPDNAConcentration)
          }
        }.padding(.top, 8)
      }
    }
  }

  private var probe: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("qPCR probe constraints").font(.subheadline.weight(.medium))
      HStack {
        field("Probe length minimum", $state.varVAMPProbeSizeMinimum)
        field("Probe length optimum", $state.varVAMPProbeSizeOptimum)
        field("Probe length maximum", $state.varVAMPProbeSizeMaximum)
      }
      HStack {
        field("Probe Tm minimum", $state.varVAMPProbeTmMinimum)
        field("Probe Tm optimum", $state.varVAMPProbeTmOptimum)
        field("Probe Tm maximum", $state.varVAMPProbeTmMaximum)
      }
      HStack {
        field("Probe GC minimum (%)", $state.varVAMPProbeGCMinimum)
        field("Probe GC optimum (%)", $state.varVAMPProbeGCOptimum)
        field("Probe GC maximum (%)", $state.varVAMPProbeGCMaximum)
      }
      HStack {
        field("GC bases at probe end minimum", $state.varVAMPProbeGCEndMinimum)
        field("GC bases at probe end maximum", $state.varVAMPProbeGCEndMaximum)
      }
      HStack {
        field("Probe/primer Tm difference minimum", $state.varVAMPProbeTemperatureDifferenceMinimum)
        field("Probe/primer Tm difference maximum", $state.varVAMPProbeTemperatureDifferenceMaximum)
      }
      HStack {
        field("Probe distance minimum", $state.varVAMPProbeDistanceMinimum)
        field("Probe distance maximum", $state.varVAMPProbeDistanceMaximum)
        field("Amplicon deletion cutoff", $state.varVAMPAmpliconDeletionCutoff)
      }
      HStack {
        field("Amplicon GC minimum (%)", $state.varVAMPAmpliconGCMinimum)
        field("Amplicon GC maximum (%)", $state.varVAMPAmpliconGCMaximum)
        field("qPCR primer difference", $state.varVAMPQPrimerDifference)
      }
    }
  }

  /// Off-target screening by chosen sequences. LGE builds the BLAST database, so
  /// the user picks project documents instead of needing a database of their own.
  /// An existing database prefix stays available as an advanced alternative.
  private var offTargetScreening: some View {
    let usesExistingPrefix = !existingPrefix.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
    return VStack(alignment: .leading, spacing: 8) {
      Text("Off-target screening").font(.subheadline.weight(.medium))
      Text("Choose sequences that primers must not amplify. LGE builds a nucleotide BLAST database from them with makeblastdb and records the sequences in provenance.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if state.screeningSources.isEmpty {
        Text("No screening sequences chosen. Candidates are not checked for off-targets.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(state.screeningSources, id: \.url) { source in
            HStack(spacing: 6) {
              Image(systemName: icon(for: source.kind)).foregroundStyle(.secondary)
              Text(source.displayName).font(.callout)
              Spacer(minLength: 8)
              Button {
                state.removeScreeningSource(source)
              } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(source.displayName) from off-target screening")
            }
          }
        }
        .accessibilityIdentifier("primerDesign.screeningSources")
      }
      HStack(spacing: 8) {
        Button("Add Sequences to Screen Against…") { chooseScreeningSources() }
          .disabled(usesExistingPrefix)
        if !state.screeningSources.isEmpty {
          Text("\(state.screeningSources.count) source\(state.screeningSources.count == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let rejected = rejectedScreeningNames, !rejected.isEmpty {
        Text("Skipped \(rejected.joined(separator: ", ")): choose an alignment bundle, reference bundle, or nucleotide FASTA.")
          .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      DisclosureGroup("Use an existing BLAST database instead") {
        VStack(alignment: .leading, spacing: 6) {
          field("Local nucleotide BLAST database prefix", existingPrefix)
            .disabled(!state.screeningSources.isEmpty)
          Text(state.screeningSources.isEmpty
            ? "Advanced alternative for a database you already built outside LGE. Its component files are snapshotted into the analysis."
            : "Remove the chosen screening sequences to use an existing database prefix instead.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 6)
      }
    }
  }

  private var existingPrefix: Binding<String> {
    state.engine == .olivar ? $state.olivarBlastDatabasePath : $state.varVAMPBlastDatabasePath
  }

  private func icon(for kind: PrimerScreeningSource.Kind) -> String {
    switch kind {
    case .alignmentBundle: "square.stack.3d.up"
    case .referenceBundle: "text.book.closed"
    case .fasta: "doc.plaintext"
    }
  }

  private func chooseScreeningSources() {
    let panel = NSOpenPanel()
    panel.title = "Choose sequences to screen against"
    panel.message = "Pick alignment bundles, reference bundles, or nucleotide FASTA files."
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.treatsFilePackagesAsDirectories = false
    if let projectURL = state.projectURL { panel.directoryURL = projectURL }
    // begin(completionHandler:) keeps AppKit responsive; runModal would block the
    // app on a nested run loop. See the macOS API rules.
    panel.begin { response in
      guard response == .OK else { return }
      let rejected = state.addScreeningSources(panel.urls)
      rejectedScreeningNames = rejected.isEmpty ? nil : rejected
    }
  }

  private func field(_ title: String, _ value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(title, text: value).textFieldStyle(.roundedBorder)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

import SwiftUI
import LungfishWorkflow

struct PrimerSchemeAdvancedOptionsView: View {
  @Bindable var state: PrimerDesignDialogState

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
        field("Maximum dimer ΔG", $state.olivarMaximumDimerDeltaG)
      }
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
      field("Local nucleotide BLAST database prefix (optional)", $state.olivarBlastDatabasePath)
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
      field("Local nucleotide BLAST database prefix (optional)", $state.varVAMPBlastDatabasePath)
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

  private func field(_ title: String, _ value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(title, text: value).textFieldStyle(.roundedBorder)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

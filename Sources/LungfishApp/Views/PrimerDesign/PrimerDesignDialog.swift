import AppKit
import SwiftUI
import LungfishIO
import LungfishKit
import LungfishWorkflow

struct PrimerDesignDialog: View {
  private struct InputLoadIdentity: Hashable {
    let urls: [URL]
    let revision: UInt64
  }
  @Bindable var state: PrimerDesignDialogState
  let onRun: () -> Void
  let onClose: () -> Void
  @State private var choosingExecutable = false
  @State private var choosingGapParent = false

  var body: some View {
    DatasetOperationsDialog(
      title: "PCR Primer Design",
      subtitle: "Primer pairs, probes and tiled pools",
      datasetLabel: "\(state.inputURLs.count) input files · Results saved in this project",
      tools: PrimerDesignEngine.allCases.map { engine in
        DatasetOperationToolSidebarItem(id: engine.rawValue, title: engine.rawValue,
          subtitle: toolSubtitle(engine),
          availability: .available)
      },
      selectedToolID: state.engine.rawValue,
      statusText: state.errorMessage ?? state.validationMessage ?? state.inputReadinessMessage ?? "Ready. Progress will appear in Operations.",
      isRunEnabled: state.isRunEnabled,
      primaryActionTitle: "Run", accessibilityNamespace: "primer-design",
      onSelectTool: { if let engine = PrimerDesignEngine(rawValue: $0) { state.engine = engine } },
      onCancel: onClose, onRun: onRun
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text(state.engine.rawValue).font(.title2.weight(.semibold))
            Spacer()
            Button("Manage Tools…") { PluginManagerWindowController.show(packID: "pcr-primer-design") }
          }
          inputSection
          if state.engine == .primer3 { primer3Section } else { schemeSection }
          advancedSection
          outputSection
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 840, minHeight: 640)
    .task(id: InputLoadIdentity(urls: state.inputURLs, revision: state.inspectionRevision)) {
      await state.inspectInputs()
    }
    .fileImporter(isPresented: $choosingExecutable, allowedContentTypes: [.item]) { result in
      if case .success(let url) = result {
        state.primalschemeExecutablePath = url.standardizedFileURL.path
      }
    }
    .fileImporter(isPresented: $choosingGapParent, allowedContentTypes: [.data, .folder]) { result in
      if case .success(let url) = result {
        state.gapCompletionParentPath = url.standardizedFileURL.path
        state.legacySalvageEnabled = false
        state.gapExpansionEnabled = false
      }
    }
  }

  private var inputSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Selected project inputs").font(.headline)
      if state.inputURLs.isEmpty {
        Text("Select sequence or alignment bundles in the project sidebar, then reopen PCR Primer Design.")
          .foregroundStyle(.secondary)
      }
      ForEach(state.inputURLs, id: \.self) { url in
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 10) {
          Image(systemName: "doc.text").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text(url.deletingPathExtension().lastPathComponent).font(.body.weight(.medium))
            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Spacer()
          Button { state.removeInput(url) } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).accessibilityLabel("Remove \(url.lastPathComponent)")
          }
          if let error = state.inputErrors[url] {
            Text(error).font(.caption).foregroundStyle(Color.lungfishDangerFallback)
          } else if let summary = state.inputSummaries[url] {
            if state.engine == .primer3 {
              if summary.isAlignment {
                Picker("Template row", selection: Binding<Int?>(
                  get: { state.templateRowIndices[url] },
                  set: { state.templateRowIndices[url] = $0 })) {
                  Text("Choose a row…").tag(nil as Int?)
                  ForEach(Array(summary.recordTitles.enumerated()), id: \.offset) { index, title in
                    Text("\(index + 1). \(title)").tag(Optional(index))
                  }
                }
              } else {
                DisclosureGroup("Records: \(state.selectedRecordIndices[url, default: []].count) of \(summary.recordTitles.count) selected") {
                  VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.recordTitles.enumerated()), id: \.offset) { index, title in
                      Toggle("\(index + 1). \(title)", isOn: Binding(
                        get: { state.selectedRecordIndices[url, default: []].contains(index) },
                        set: { checked in
                          if checked { state.selectedRecordIndices[url, default: []].insert(index) }
                          else { state.selectedRecordIndices[url, default: []].remove(index) }
                        }))
                    }
                  }.padding(.top, 6)
                }
              }
            } else {
              Text("\(summary.recordTitles.count) alignment rows included").font(.caption).foregroundStyle(.secondary)
            }
          } else { Text("Reading records…").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
      }
      if !state.inputURLs.isEmpty {
        Text("\(state.inputURLs.count) input \(state.inputURLs.count == 1 ? "file" : "files"). Record numbers distinguish repeated names.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var primer3Section: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Design settings").font(.headline)
      Picker("Assay", selection: $state.chemistry) {
        ForEach(PrimerDesignChemistry.allCases) { Text($0.rawValue).tag($0) }
      }
      if state.chemistry == .hydrolysisProbe {
        Text("Pick an internal oligo with each pair. Reporter, quencher and vendor modifications are assigned after sequence design.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        numberField("Product minimum (bp)", $state.productSizeMin)
        numberField("Product maximum (bp)", $state.productSizeMax)
        numberField("Candidate pairs", $state.pairCount)
      }
      Toggle("Amplify a specific region", isOn: $state.targetEnabled)
      if state.targetEnabled {
        HStack {
          numberField("Target start", $state.targetStart)
          numberField("Target end", $state.targetEnd)
        }
        Text("Coordinates are 1-based and inclusive on each ungapped template. Primers must flank the region.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if state.inputSummaries.values.contains(where: \.isAlignment) {
        Toggle("Require binding sites conserved across all alignment rows", isOn: $state.conservedBindingSites)
        Text("Exclude variable and gapped columns from primer and probe binding sites on the chosen template.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var schemeSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Scheme settings").font(.headline)
      if state.engine == .varVAMP {
        Picker("Design mode", selection: $state.schemeMode) {
          Text("Single amplicon").tag(PrimerSchemeMode.single)
          Text("Tiled amplicons").tag(PrimerSchemeMode.tiled)
          Text("qPCR / dPCR primers + probe").tag(PrimerSchemeMode.qpcr)
        }
        Text(state.schemeMode == .qpcr
          ? "varVAMP uses its qPCR optimizer for primer-and-probe assays. There is no separate dPCR optimizer."
          : state.schemeMode == .single ? "Design one primer pair per reported assay." : "Design a tiled two-pool amplicon scheme.")
          .font(.caption).foregroundStyle(.secondary)
      } else if state.engine == .olivar {
        Text("Mode: tiled amplicons").font(.callout.weight(.medium))
      }
      if state.engine == .varVAMP {
        numberField(state.schemeMode == .qpcr
          ? "Cumulative consensus threshold (required)"
          : "Cumulative consensus threshold (blank = native automatic)",
          $state.varVAMPConsensusThreshold)
        Text("Controls cumulative base support when building the consensus; this differs from PrimalScheme’s frequency filter.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Picker("Output grouping", selection: $state.grouping) {
        Text("One scheme per MSA").tag(PrimerAnalysisGrouping.independent)
        Text("Combined scheme from selected MSAs").tag(PrimerAnalysisGrouping.combined)
      }.disabled(state.engine == .varVAMP)
      Text(state.grouping == .independent
        ? "Each alignment produces a separate scheme and retains its input identity."
        : "Design a combined panel from all selected alignments.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        numberField("Minimum amplicon size (bp)", $state.ampliconSizeMinimum)
        numberField("Target amplicon size (bp)", $state.ampliconSize)
        numberField("Maximum amplicon size (bp)", $state.ampliconSizeMaximum)
      }
      Text(state.ampliconSpanDescription).font(.caption).foregroundStyle(.secondary)
      Text("The target sets default bounds until you edit them. It is nominal; selection does not favor the closest size.")
        .font(.caption).foregroundStyle(.secondary)
      if state.engine == .primalScheme {
        numberField("Primer pools", $state.poolCount)
      } else if state.engine == .olivar || (state.engine == .varVAMP && state.schemeMode == .tiled) {
        Text("Native pool behavior: two tiled pools").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Assays are unpooled.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var advancedSection: some View {
    DisclosureGroup("Advanced settings", isExpanded: $state.advancedExpanded) {
      VStack(alignment: .leading, spacing: 14) {
        if state.engine == .primer3 {
          Text("Primer length (nt)").font(.subheadline.weight(.medium))
          HStack {
            numberField("Minimum", $state.primerMinSize)
            numberField("Optimum", $state.primerOptSize)
            numberField("Maximum", $state.primerMaxSize)
          }
          Text("Primer melting temperature (°C)").font(.subheadline.weight(.medium))
          HStack {
            numberField("Minimum", $state.primerMinTm)
            numberField("Optimum", $state.primerOptTm)
            numberField("Maximum", $state.primerMaxTm)
          }
          HStack {
            numberField("Minimum GC (%)", $state.primerMinGC)
            numberField("Maximum GC (%)", $state.primerMaxGC)
          }
        } else if state.engine == .primalScheme {
          numberField("Minimum base frequency", $state.minimumBaseFrequency)
          Text("PrimalScheme's native per-base minimum frequency. The historical GUI default remains 0.")
            .font(.caption).foregroundStyle(.secondary)
          numberField("CPU cores", $state.coreCount)
          numberField("Dimer score threshold", $state.dimerScore)
          Toggle("Check the primer mispriming database", isOn: $state.useMatchDB)
          if state.grouping == .independent {
            numberField("Minimum overlap (bp)", $state.minOverlap)
            Toggle("Backtrack when extending the scheme", isOn: $state.backtrack)
            Toggle("Ignore unknown bases (N)", isOn: $state.ignoreN)
          } else {
            Picker("Panel selection", selection: $state.panelMode) {
              Text("Uniform position weighting").tag(PrimalScheme3PanelMode.equal)
              Text("Prioritize variable regions (entropy)").tag(PrimalScheme3PanelMode.entropy)
            }
            Text(state.panelMode == .equal
              ? "Every target position has equal weight, supporting broad coverage of conserved and variable regions."
              : "Amplicons containing more sequence variation receive greater weight. Entropy measures variation between the primers, not at their binding sites.")
              .font(.caption).foregroundStyle(.secondary)
            Text("Both modes take turns across the selected MSAs. These weights do not guarantee equal amplification or allele representation and do not filter primer variants.")
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              numberField("Maximum panel amplicons (optional)", $state.maxAmplicons)
              numberField("Maximum per MSA (optional)", $state.maxAmpliconsPerMSA)
            }
            Text("Leave limits blank to use PrimalScheme's unrestricted panel selection.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Toggle("Use high-GC design settings", isOn: $state.highGC)
          Text("Mapping reference: first alignment row. Original allele names are retained in the analysis.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle(state.gapCompletionParentPath.isEmpty ? "Treat uncovered alignment ends as missing observations" : "Follow-up uses legacy alignment-end policy", isOn: Binding(
            get: { state.gapCompletionParentPath.isEmpty && state.excludeUncoveredEnds },
            set: { if state.gapCompletionParentPath.isEmpty { state.excludeUncoveredEnds = $0 } }))
            .disabled(!state.gapCompletionParentPath.isEmpty)
          Text(state.gapCompletionParentPath.isEmpty ? "Missing terminal observations are excluded at each candidate site while available internal sequence is retained. Missing data does not count as a match." : "The selected parent follow-up requires the native legacy alignment-end policy.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Text(state.primalschemeExecutablePath.isEmpty ? "Managed runtime (legacy defaults)" : state.primalschemeExecutablePath)
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(); Button("Choose verified executable…") { choosingExecutable = true }
            if !state.primalschemeExecutablePath.isEmpty { Button("Clear") { state.primalschemeExecutablePath = "" } }
          }
          if state.grouping == .combined {
            Toggle("Allow bounded dimer salvage", isOn: $state.legacySalvageEnabled)
              .disabled(!state.gapCompletionParentPath.isEmpty)
            Text("Runs the strict legacy panel first, then a bounded heuristic salvage tier. Interaction limits are search budgets, not experimentally established safety thresholds.")
              .font(.caption).foregroundStyle(.secondary)
            if state.legacySalvageEnabled {
              HStack { numberField("Thresholds (comma-separated)", $state.legacySalvageThresholds); numberField("Floor", $state.legacySalvageFloor) }
              HStack { numberField("Allowed relaxed primer interactions per pool", $state.legacySalvageMaxEdgesPerPool); numberField("Primers with relaxed interactions per pool", $state.legacySalvageMaxIncidentSpeciesPerPool) }
              HStack { numberField("Minimum added reference bases", $state.legacySalvageMinReferenceGain); numberField("Maximum candidate evaluations", $state.legacySalvageMaxCandidateEvaluations) }
            }
            HStack {
              Text(state.gapCompletionParentPath.isEmpty ? "No gap-completion parent selected" : state.gapCompletionParentPath)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              Spacer(); Button("Choose parent output…") { choosingGapParent = true }
              if !state.gapCompletionParentPath.isEmpty { Button("Clear") { state.gapCompletionParentPath = ""; state.gapExpansionEnabled = false } }
            }
            Text("A selected parent starts a separate PCR follow-up scheme; its pools are not additions to the parent reactions.")
              .font(.caption).foregroundStyle(.secondary)
            Toggle("Generate bounded candidates for uncovered regions", isOn: $state.gapExpansionEnabled)
              .disabled(state.gapCompletionParentPath.isEmpty)
            if state.gapExpansionEnabled {
              HStack { numberField("Max anchors / MSA", $state.gapExpansionMaxAnchorsPerMSA); numberField("Max pair checks / MSA", $state.gapExpansionMaxPairsPerMSA) }
              Text("Defaults are 2,000 anchors and 1,000 pair checks per MSA. Larger limits do not guarantee better coverage.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        } else {
          PrimerSchemeAdvancedOptionsView(state: state)
        }
      }.padding(.top, 12)
    }
  }

  private var outputSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Save analysis").font(.headline)
      TextField("Analysis name", text: $state.analysisName).textFieldStyle(.roundedBorder)
      Label(state.projectURL?.lastPathComponent ?? "No project open", systemImage: "folder")
        .font(.callout)
      Text("Saved in this project's Analyses folder as a Lungfish primer analysis bundle.")
        .font(.caption).foregroundStyle(.secondary)
      Text("The bundle preserves inputs, native outputs, result links, settings and reproducibility provenance.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func numberField(_ title: String, _ value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(title, text: value).textFieldStyle(.roundedBorder)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func toolSubtitle(_ engine: PrimerDesignEngine) -> String {
    switch engine {
    case .primer3: "Primer pairs & qPCR probes"
    case .primalScheme: "Tiled primer pool schemes"
    case .olivar: "Tiled MSA primer schemes"
    case .varVAMP: "Single, tiled & qPCR/probe assays"
    }
  }

}

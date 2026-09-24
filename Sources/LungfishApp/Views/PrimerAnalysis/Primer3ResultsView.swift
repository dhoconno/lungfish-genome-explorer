import AppKit
import SwiftUI
import LungfishKit
import LungfishWorkflow

/// Coordinates in the file are zero-based, half-open; labels are one-based inclusive.
struct Primer3ResultsView: View {
  let results: Primer3NormalizedResults
  let bundleURL: URL
  var reviewTargets: [PrimerTargetDesignReview] = []
  var selection: Binding<PrimerReviewSelection?> = .constant(nil)
  var onInspectSelection: () -> Void = {}
  @State private var localSelection: PrimerReviewSelection?
  @State private var selectedResultID: UUID?
  @State private var selectedPairIDs: [UUID: UUID] = [:]
  @State private var isCreatingReference = false
  @State private var referenceMessage: String?
  @State private var createdReferenceURL: URL?

  private var targets: [PrimerTargetDesignReview] {
    reviewTargets.isEmpty ? PrimerDesignReview.primer3(results) : reviewTargets
  }

  private var activeSelection: Binding<PrimerReviewSelection?> {
    Binding(get: { selection.wrappedValue ?? localSelection }, set: { selection.wrappedValue = $0; localSelection = $0 })
  }

  private var selectedTarget: PrimerTargetDesignReview? {
    targets.first { $0.id == activeSelection.wrappedValue?.targetID }
  }

  private var selectedResult: Primer3TemplateResult? {
    results.results.first { $0.resultID.uuidString == selectedTarget?.sourceResultID }
      ?? results.results.first { $0.resultID == selectedResultID } ?? results.results.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Primer3 results").font(.title2.weight(.semibold))
      if results.results.isEmpty {
        Text("No template results were returned.").foregroundStyle(.secondary)
      } else {
        Picker("Template", selection: Binding(
          get: { selectedResult?.resultID }, set: { selectedResultID = $0; activeSelection.wrappedValue = nil })) {
          ForEach(results.results, id: \.resultID) { result in
            Text("\(result.sourceIndex + 1). \(result.title)").tag(Optional(result.resultID))
          }
        }
        .disabled(isCreatingReference)
        .onChange(of: selectedResultID) {
          referenceMessage = nil
          createdReferenceURL = nil
        }
        if let result = selectedResult { templateResults(result) }
      }
    }
  }

  private func templateResults(_ result: Primer3TemplateResult) -> some View {
    let pair = result.pairs.first { $0.id.uuidString == selectedTarget?.id }
      ?? result.pairs.first { $0.id == selectedPairIDs[result.resultID] } ?? result.pairs.first
    return VStack(alignment: .leading, spacing: 16) {
      Text("\(result.templateSequence.utf8.count) bp • \(result.pairs.count) candidate pairs • coordinates are 1-based inclusive")
        .font(.caption).foregroundStyle(.secondary)
      if let error = result.error, !error.isEmpty {
        Text(error).foregroundStyle(Color.lungfishDangerFallback).textSelection(.enabled)
      }
      if result.pairs.isEmpty {
        Text("No primer pairs met the requested constraints.").foregroundStyle(.secondary)
      }
      if !result.pairs.isEmpty {
        HStack {
          Button("Create Annotated Reference…") { createReference(for: result) }
            .disabled(isCreatingReference)
          if isCreatingReference { ProgressView().controlSize(.small) }
          if let url = createdReferenceURL {
            Button("Open Annotated Reference") { _ = (NSApp.delegate as? AppDelegate)?.openDocument(at: url) }
          }
        }
        Text("Create a native reference with all candidate primers and probes as linked annotations.")
          .font(.caption).foregroundStyle(.secondary)
        if let referenceMessage { Text(referenceMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 20) {
            candidateList(result, selectedPair: pair).frame(width: 160)
            if let pair { candidateDetails(result, pair: pair).frame(minWidth: 460) }
          }
          VStack(alignment: .leading, spacing: 16) {
            candidateList(result, selectedPair: pair)
            if let pair { candidateDetails(result, pair: pair) }
          }
        }

      }
      if let explanation = result.explanation, !explanation.isEmpty {
        DisclosureGroup("Primer3 explanation") {
          Text(explanation).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
      }
    }
  }

  private func candidateList(_ result: Primer3TemplateResult, selectedPair: Primer3Pair?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Candidates").font(.headline)
      ForEach(Array(result.pairs.enumerated()), id: \.element.id) { index, candidate in
        Button {
          selectedPairIDs[result.resultID] = candidate.id
          activeSelection.wrappedValue = .init(targetID: candidate.id.uuidString, primerID: nil, ampliconID: candidate.id.uuidString)
          onInspectSelection()
        } label: {
          HStack {
            Text("Pair \(index + 1)")
            Spacer()
            Text("\(candidate.productSize) bp").foregroundStyle(.secondary)
          }.padding(10)
            .background(selectedPair?.id == candidate.id ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
          .contextMenu {
            if let target = targets.first(where: { $0.id == candidate.id.uuidString }),
              let interval = target.intervals.first(where: { $0.id == candidate.id.uuidString }) {
              PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: activeSelection)
            }
          }
      }
    }
  }

  private func candidateDetails(_ result: Primer3TemplateResult, pair: Primer3Pair) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if let target = targets.first(where: { $0.id == pair.id.uuidString }) {
        PrimerTargetReviewCard(target: target, selection: activeSelection)
          .id(PrimerReviewSelection.selectedDesignAnchor)
      }
      Text("Primer properties").font(.headline)
      oligoRow("Forward primer", pair.left, color: .blue, pair: pair)
      oligoRow("Reverse primer", pair.right, color: .orange, pair: pair)
      if let probe = pair.internalOligo { oligoRow("Internal probe", probe, color: .purple, pair: pair) }
      DisclosureGroup("Template sequence with selected binding sites") {
        annotatedSequence(result.templateSequence, pair: pair)
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func createReference(for result: Primer3TemplateResult) {
    let panel = NSOpenPanel()
    panel.title = "Choose a folder for the annotated reference"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = bundleURL.deletingLastPathComponent()
    // runModal() blocks the whole app on its own nested run loop instead of
    // yielding control back to AppKit; begin(completionHandler:) presents
    // the same non-sheet panel without blocking. See macOS API rules /
    // AppKitConcurrencyModalSafetyTests.
    panel.begin { response in
      guard response == .OK, let directory = panel.url else { return }
      isCreatingReference = true
      referenceMessage = "Creating annotated reference…"
      createdReferenceURL = nil
      Task {
        do {
          let url = try await PrimerAnalysisAnnotatedReferenceService().createReference(
            analysisURL: bundleURL, resultID: result.resultID,
            outputDirectory: directory, invocationArgv: CommandLine.arguments)
          createdReferenceURL = url
          referenceMessage = "Saved \(url.lastPathComponent)."
        } catch { referenceMessage = error.localizedDescription }
        isCreatingReference = false
      }
    }
  }

  private func oligoRow(_ title: String, _ oligo: Primer3Oligo, color: Color, pair: Primer3Pair) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        activeSelection.wrappedValue = .init(targetID: pair.id.uuidString, primerID: oligo.id.uuidString, ampliconID: pair.id.uuidString)
        onInspectSelection()
      } label: {
        HStack {
          Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
          Text("\(oligo.start + 1)–\(oligo.end)").font(.caption).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      Text(String(format: "%d nt · Tm %.1f °C · GC %.1f%%", oligo.sequence.utf8.count, oligo.meltingTemperature, oligo.gcPercent))
        .font(.caption).foregroundStyle(.secondary)
    }
    .contextMenu {
      if let target = targets.first(where: { $0.id == pair.id.uuidString }),
        let primer = target.primers.first(where: { $0.id == oligo.id.uuidString }) {
        PrimerReviewContextMenu(target: target, item: .primer(primer), selection: activeSelection)
      }
    }
  }

  private func annotatedSequence(_ sequence: String, pair: Primer3Pair) -> Text {
    let bytes = Array(sequence.utf8)
    var text = AttributedString()
    for start in stride(from: 0, to: bytes.count, by: 60) {
      text.append(AttributedString(String(format: "%6d  ", start + 1)))
      for index in start..<min(start + 60, bytes.count) {
        var base = AttributedString(String(UnicodeScalar(bytes[index])))
        if (pair.left.start..<pair.left.end).contains(index) { base.foregroundColor = .blue }
        if (pair.right.start..<pair.right.end).contains(index) { base.foregroundColor = .orange }
        if let probe = pair.internalOligo, (probe.start..<probe.end).contains(index) { base.foregroundColor = .purple }
        text.append(base)
      }
      text.append(AttributedString("\n"))
    }
    return Text(text)
  }
}

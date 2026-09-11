import AppKit
import SwiftUI
import LungfishWorkflow

/// Coordinates in the file are zero-based, half-open; labels are one-based inclusive.
struct Primer3ResultsView: View {
  let results: Primer3NormalizedResults
  let bundleURL: URL
  @State private var selectedResultID: UUID?
  @State private var selectedPairIDs: [UUID: UUID] = [:]
  @State private var isCreatingReference = false
  @State private var referenceMessage: String?
  @State private var createdReferenceURL: URL?

  private var selectedResult: Primer3TemplateResult? {
    results.results.first { $0.resultID == selectedResultID } ?? results.results.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Primer3 results").font(.title2.weight(.semibold))
      if results.results.isEmpty {
        Text("No template results were returned.").foregroundStyle(.secondary)
      } else {
        Picker("Template", selection: Binding(
          get: { selectedResult?.resultID }, set: { selectedResultID = $0 })) {
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
    let pair = result.pairs.first { $0.id == selectedPairIDs[result.resultID] } ?? result.pairs.first
    return VStack(alignment: .leading, spacing: 16) {
      Text("\(result.templateSequence.utf8.count) bp • \(result.pairs.count) candidate pairs • coordinates are 1-based inclusive")
        .font(.caption).foregroundStyle(.secondary)
      if let error = result.error, !error.isEmpty {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
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
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Candidates").font(.headline)
            ForEach(Array(result.pairs.enumerated()), id: \.element.id) { index, candidate in
              Button { selectedPairIDs[result.resultID] = candidate.id } label: {
                HStack {
                  Text("Pair \(index + 1)")
                  Spacer()
                  Text("\(candidate.productSize) bp").foregroundStyle(.secondary)
                }.padding(10)
                  .background(pair?.id == candidate.id ? Color.accentColor.opacity(0.15) : .clear,
                              in: RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain)
            }
          }.frame(width: 160)
          if let pair {
            VStack(alignment: .leading, spacing: 14) {
              Text("Annotated template").font(.headline)
              Primer3TemplateTrack(templateLength: result.templateSequence.utf8.count, pair: pair)
                .frame(height: pair.internalOligo == nil ? 85 : 110)
              oligoRow("Forward primer", pair.left, color: .blue)
              oligoRow("Reverse primer", pair.right, color: .orange)
              if let probe = pair.internalOligo { oligoRow("Internal probe", probe, color: .purple) }
              DisclosureGroup("Template sequence with selected binding sites") {
                annotatedSequence(result.templateSequence, pair: pair)
                  .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
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

  private func createReference(for result: Primer3TemplateResult) {
    let panel = NSOpenPanel()
    panel.title = "Choose a folder for the annotated reference"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = bundleURL.deletingLastPathComponent()
    guard panel.runModal() == .OK, let directory = panel.url else { return }
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

  private func oligoRow(_ title: String, _ oligo: Primer3Oligo, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
        Text("\(oligo.start + 1)–\(oligo.end)").font(.caption).foregroundStyle(.secondary)
      }
      Text("5′ \(oligo.sequence) 3′").font(.system(.body, design: .monospaced)).textSelection(.enabled)
      Text(String(format: "%d nt · Tm %.1f °C · GC %.1f%%", oligo.sequence.utf8.count, oligo.meltingTemperature, oligo.gcPercent))
        .font(.caption).foregroundStyle(.secondary)
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

private struct Primer3TemplateTrack: View {
  let templateLength: Int
  let pair: Primer3Pair

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - 12)
      let scale = width / CGFloat(max(1, templateLength))
      ZStack(alignment: .topLeading) {
        Rectangle().fill(.secondary.opacity(0.4)).frame(width: width, height: 2).offset(y: 16)
        Text("1").font(.caption2).offset(y: 0)
        Text("\(templateLength)").font(.caption2).frame(width: width, alignment: .trailing)
        arrow(pair.left, color: .blue, scale: scale).offset(y: 30)
        arrow(pair.right, color: .orange, scale: scale).offset(y: 55)
        if let probe = pair.internalOligo { arrow(probe, color: .purple, scale: scale).offset(y: 80) }
      }
    }.accessibilityLabel("Forward primer \(pair.left.start + 1) to \(pair.left.end); reverse primer \(pair.right.start + 1) to \(pair.right.end)")
  }

  private func arrow(_ oligo: Primer3Oligo, color: Color, scale: CGFloat) -> some View {
    let width = max(4, CGFloat(oligo.end - oligo.start) * scale)
    return ZStack {
      Capsule().fill(color).frame(width: width, height: 6)
      Image(systemName: oligo.orientation == .forward ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
        .font(.system(size: 10)).foregroundStyle(color)
        .offset(x: (oligo.orientation == .forward ? 1 : -1) * max(0, width / 2 - 3))
    }.offset(x: CGFloat(oligo.start) * scale)
  }
}

import AppKit
import SwiftUI

/// Opens the published order only after its recorded output checksums have been verified.
struct PrimerOrderResultView: View {
    private struct LoadIdentity: Hashable {
        let orderURL: URL
        let retryGeneration: UInt64
    }

    let orderURL: URL
    var onLoaded: @MainActor (PrimerOrderViewerSnapshot) -> Void = { _ in }
    var onLoadFailed: @MainActor (String) -> Void = { _ in }
    @State private var document: PrimerOrderDocument?
    @State private var errorMessage: String?
    @State private var retryGeneration: UInt64 = 0

    var body: some View {
        Group {
            if let document {
                PrimerOrderResultContent(document: document, orderURL: orderURL)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Open Primer Order", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage).textSelection(.enabled)
                } actions: {
                    Button("Retry") { retryGeneration &+= 1 }
                }
                .accessibilityIdentifier("primerOrderResult.error")
            } else {
                ProgressView("Verifying saved primer order…")
                    .accessibilityIdentifier("primerOrderResult.loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: LoadIdentity(orderURL: orderURL, retryGeneration: retryGeneration)) {
            document = nil
            errorMessage = nil
            let url = orderURL
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let result = try PrimerOrderExportService.loadSnapshot(from: url)
                try Task.checkCancellation()
                return result
            }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                document = loaded.document
                onLoaded(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                onLoadFailed(error.localizedDescription)
            }
        }
    }
}

struct PrimerOrderResultContent: View {
    let document: PrimerOrderDocument
    let orderURL: URL

    private var poolNames: [String] {
        var seen: Set<String> = []
        return document.oligos.compactMap { seen.insert($0.poolName).inserted ? $0.poolName : nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(document.metadata.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("\(document.oligos.count) oligos · \(poolNames.count) pools · \(Set(document.oligos.map(\.sourceResultID)).count) schemes")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text("This order preserves the displayed oligos captured at export. The source design and original full ordering sheet remain unchanged.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { outputActions }
                        VStack(alignment: .leading, spacing: 8) { outputActions }
                    }
                    Text("The order workbook includes Order metadata. The IDT upload copy contains only the supplied template sheet.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pools in this order").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(poolNames, id: \.self) { poolName in
                            HStack(alignment: .firstTextBaseline) {
                                Text(poolName).textSelection(.enabled)
                                Spacer(minLength: 10)
                                Text("\(document.oligos.filter { $0.poolName == poolName }.count) oligos")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.caption)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exported oligos").font(.headline)
                    Text("All \(document.oligos.count) saved order entries · sequences 5′–3′")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(document.oligos) { oligo in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(oligo.name).fontWeight(.medium).textSelection(.enabled)
                                Spacer(minLength: 12)
                                Text(oligo.poolName).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }.font(.callout)
                            Text("Reference: \(oligo.referenceID) · \(oligo.start + 1)–\(oligo.end) (\(oligo.strand))")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(oligo.sequence).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("primerOrderResult.oligo.\(oligo.id)")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("primerOrderResult.content")
    }

    @ViewBuilder
    private var outputActions: some View {
        Button("Open order workbook") { open("primer-order.xlsx") }
            .help("Open primer-order.xlsx, including the IDT template and Order metadata.")
        Button("Open IDT upload copy") { open("IDT-oPools.xlsx") }
            .help("Open IDT-oPools.xlsx with the template sheet only.")
        Button("Open CSV") { open("ordering.csv") }
            .help("Open ordering.csv with every saved oligo identity and sequence.")
    }

    private func open(_ name: String) {
        NSWorkspace.shared.open(orderURL.appendingPathComponent(name))
    }
}

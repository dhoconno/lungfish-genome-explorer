import SwiftUI

/// Presentation controls for a verified saved scheme; the session retains every source oligo.
struct PrimerAnalysisDisplaySection: View {
    @Bindable var session: PrimerAnalysisDisplaySession
    @State private var selectedTargetID: String?
    @State private var searchText = ""
    @State private var orderDraft: PrimerOrderDraft?
    @State private var orderExportError: String?

    private var target: PrimerTargetDesignReview? {
        session.targets.first { $0.id == selectedTargetID } ?? session.targets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Primer display").font(LungfishInspectorStyle.sectionTitleFont)
                Spacer(minLength: 8)
                Button("Show all") { session.reset(); searchText = "" }
                    .accessibilityIdentifier("primerAnalysisDisplay.reset")
            }
            Text("\(session.visibleCount) of \(session.totalCount) oligos displayed")
                .monospacedDigit()
                .accessibilityIdentifier("primerAnalysisDisplay.count")
            Text("Display options for this saved run. Saved coverage and the original full ordering sheet stay unchanged. Export the displayed set below; design settings require a new run.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Export displayed primer order…") {
                do {
                    orderExportError = nil
                    orderDraft = try session.makeOrderDraft()
                } catch {
                    orderExportError = error.localizedDescription
                }
            }
            .disabled(session.orderExportUnavailableReason != nil)
            .accessibilityIdentifier("primerAnalysisDisplay.exportOrder")
            Text(session.orderExportUnavailableReason
                ?? "Includes displayed oligos across all schemes and references in this analysis.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = orderExportError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Divider()
            Toggle("Forward oligos (+)", isOn: $session.settings.showForward)
                .accessibilityIdentifier("primerAnalysisDisplay.forward")
            Toggle("Reverse oligos (−)", isOn: $session.settings.showReverse)
                .accessibilityIdentifier("primerAnalysisDisplay.reverse")
            Toggle("Saved amplicon spans", isOn: $session.settings.showAmplicons)
                .accessibilityIdentifier("primerAnalysisDisplay.amplicons")
            if session.hasBindingContexts {
                Toggle("Matching observed bases as dots", isOn: $session.settings.showIdentityDots)
                    .help("Applies within the selected primer footprint in Binding inspection.")
                    .accessibilityIdentifier("primerAnalysisDisplay.identityDots")
                Divider()
                compatibilityControls
            }

            if let target {
                Divider()
                referenceControls(target)
            }
        }
        .font(LungfishInspectorStyle.controlFont)
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("primerAnalysisDisplay.section")
        .sheet(item: $orderDraft) { draft in
            PrimerOrderExportSheet(draft: draft, onCancel: { orderDraft = nil }, onExport: { frozenDraft, metadata in
                guard let export = session.onOrderExportRequested else {
                    orderExportError = "The originating project is no longer available for this order."
                    orderDraft = nil
                    return
                }
                orderDraft = nil
                export(frozenDraft, metadata)
            })
        }
    }

    private var compatibilityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Observed MSA compatibility").font(LungfishInspectorStyle.sectionTitleFont)
            Text("Compatible rows divided by assessable rows in the saved alignment. Gaps and ambiguous target bases are unassessed. This sequence comparison does not measure amplification.")
                .font(.caption).foregroundStyle(.secondary)
            if session.isComputingCompatibility {
                ProgressView("Calculating MSA compatibility…").controlSize(.small)
                Button("Cancel calculation") { session.cancel() }
            } else if !session.compatibilityReady {
                Button("Calculate MSA compatibility") { session.computeCompatibility() }
                    .accessibilityIdentifier("primerAnalysisDisplay.calculateCompatibility")
            }
            if let error = session.compatibilityError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if session.compatibilityReady {
                Toggle("Filter by observed MSA compatibility", isOn: $session.settings.filterByCompatibility)
                    .accessibilityIdentifier("primerAnalysisDisplay.compatibilityFilter")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum compatibility")
                        Spacer(minLength: 6)
                        Text("\(session.settings.minimumCompatibilityPercent, specifier: "%.0f")%")
                            .monospacedDigit()
                    }
                    Slider(value: $session.settings.minimumCompatibilityPercent, in: 0...100, step: 1)
                        .accessibilityLabel("Minimum observed MSA compatibility percent")
                        .accessibilityIdentifier("primerAnalysisDisplay.minimumCompatibility")
                    Toggle("Keep oligos without assessable rows", isOn: $session.settings.showUnassessed)
                        .accessibilityIdentifier("primerAnalysisDisplay.unassessed")
                }
                .disabled(!session.settings.filterByCompatibility)
            } else if session.settings.filterByCompatibility {
                Text("The saved compatibility filter resumes after calculation. Other visibility choices apply now.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Optional display filter; off until you enable it after calculation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func referenceControls(_ target: PrimerTargetDesignReview) -> some View {
        let pools = Set(target.primers.map(\.pool) + target.intervals.map(\.pool))
            .sorted { ($0 ?? Int.min) < ($1 ?? Int.min) }
        let members = target.primers.filter { primer in
            searchText.isEmpty || "\(primer.name) \(primer.sequence) \(primer.start + 1)–\(primer.end)"
                .localizedCaseInsensitiveContains(searchText)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Reference", selection: Binding(get: { target.id }, set: {
                selectedTargetID = $0
                searchText = ""
            })) {
                ForEach(session.targets) { Text($0.label).tag($0.id) }
            }
            .accessibilityIdentifier("primerAnalysisDisplay.reference")
            .help(target.label)

            Text("Pools in this scheme").font(LungfishInspectorStyle.sectionTitleFont)
            ForEach(pools, id: \.self) { pool in
                let id = PrimerAnalysisDisplaySettings.poolID(resultID: target.sourceResultID, pool: pool)
                Toggle(pool.map { "Pool \($0)" } ?? "Unpooled", isOn: Binding(
                    get: { !session.settings.hiddenPoolIDs.contains(id) },
                    set: { session.setPoolShown(pool, resultID: target.sourceResultID, shown: $0) }))
                    .accessibilityIdentifier("primerAnalysisDisplay.pool.\(id)")
            }
            Text("Pool choices apply to every reference in the same saved scheme.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Individual oligos").font(LungfishInspectorStyle.sectionTitleFont)
            TextField("Find oligo name, sequence or position", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("primerAnalysisDisplay.search")
            Text("\(target.primers.filter { session.isVisible($0, in: target) }.count) of \(target.primers.count) displayed on this reference")
                .font(.caption).foregroundStyle(.secondary)
            if members.isEmpty {
                Text(target.primers.isEmpty ? "No saved oligos on this reference." : "No oligos match this search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(members) { primer in
                oligoControl(primer, in: target)
            }
        }
    }

    private func oligoControl(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { !session.settings.hiddenPrimerIDs.contains(primer.id) },
                set: { session.setPrimerShown(primer.id, shown: $0) })) {
                Text(primer.name).lineLimit(2).help(primer.name)
            }
            .accessibilityIdentifier("primerAnalysisDisplay.primer.\(primer.id)")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(primer.start + 1)–\(primer.end) · \(primer.strand) · \(primer.pool.map { "Pool \($0)" } ?? "Unpooled")")
                if !session.settings.hiddenPrimerIDs.contains(primer.id), !session.isVisible(primer, in: target) {
                    Text("Hidden by another display filter")
                }
                if let summary = session.compatibilitySummaries[primer.id] {
                    Text(summary.label)
                } else if session.compatibilityReady {
                    Text("MSA compatibility unavailable")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

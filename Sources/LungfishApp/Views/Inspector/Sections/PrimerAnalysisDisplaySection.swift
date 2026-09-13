import SwiftUI

/// Presentation controls for a verified saved scheme; the session retains every source oligo.
struct PrimerAnalysisDisplaySection: View {
    @Bindable var session: PrimerAnalysisDisplaySession
    @State private var selectedTargetID: String?
    @State private var searchText = ""
    @State private var areIndividualControlsExpanded = false
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
                .help("Counts oligos currently shown after all display filters.")
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
            .help(session.orderExportUnavailableReason
                ?? "Exports the oligos currently displayed across all schemes and references.")
            if let error = orderExportError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            Divider()
            Toggle("Forward oligos (+)", isOn: $session.settings.showForward)
                .accessibilityIdentifier("primerAnalysisDisplay.forward")
                .help("Show or hide all forward-strand oligos.")
            Toggle("Reverse oligos (−)", isOn: $session.settings.showReverse)
                .accessibilityIdentifier("primerAnalysisDisplay.reverse")
                .help("Show or hide all reverse-strand oligos.")
            Toggle("Amplicon marks", isOn: $session.settings.showAmplicons)
                .accessibilityIdentifier("primerAnalysisDisplay.amplicons")
                .help("Show or hide amplicon track marks. Details remain available for the selected primer.")
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
            Text("MSA matches").font(LungfishInspectorStyle.sectionTitleFont)
                .help("Compares each oligo with assessable rows in the saved alignment. This sequence comparison does not measure amplification.")
            if session.isComputingCompatibility {
                ProgressView("Calculating MSA matches…").controlSize(.small)
                Button("Cancel calculation") { session.cancel() }
            } else if !session.compatibilityReady {
                Button("Calculate MSA matches") { session.computeCompatibility() }
                    .accessibilityIdentifier("primerAnalysisDisplay.calculateCompatibility")
                    .help("Compare oligos with assessable rows in the saved alignment.")
            }
            if let error = session.compatibilityError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if session.compatibilityReady {
                Toggle("Filter by MSA matches", isOn: $session.settings.filterByCompatibility)
                    .accessibilityIdentifier("primerAnalysisDisplay.compatibilityFilter")
                    .help("Show only oligos meeting the minimum match percentage.")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum MSA matches")
                        Spacer(minLength: 6)
                        Text("\(session.settings.minimumCompatibilityPercent, specifier: "%.0f")%")
                            .monospacedDigit()
                    }
                    Slider(value: $session.settings.minimumCompatibilityPercent, in: 0...100, step: 1)
                        .accessibilityLabel("Minimum MSA match percent")
                        .accessibilityIdentifier("primerAnalysisDisplay.minimumCompatibility")
                        .help("Minimum percentage of assessable alignment rows that must match exactly.")
                    Toggle("Keep primers without match data", isOn: $session.settings.showUnassessed)
                        .accessibilityIdentifier("primerAnalysisDisplay.unassessed")
                        .help("Keep oligos that cannot be assessed against any alignment row.")
                }
                .disabled(!session.settings.filterByCompatibility)
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

            Text("Pools").font(LungfishInspectorStyle.sectionTitleFont)
                .help("Pool choices apply to every reference in this saved scheme.")
            ForEach(pools, id: \.self) { pool in
                let id = PrimerAnalysisDisplaySettings.poolID(resultID: target.sourceResultID, pool: pool)
                Toggle(pool.map { "Pool \($0)" } ?? "Unpooled", isOn: Binding(
                    get: { !session.settings.hiddenPoolIDs.contains(id) },
                    set: { session.setPoolShown(pool, resultID: target.sourceResultID, shown: $0) }))
                    .accessibilityIdentifier("primerAnalysisDisplay.pool.\(id)")
                    .help("Show or hide this pool on every reference in the saved scheme.")
            }

            Divider()
            DisclosureGroup("Advanced: individual oligos", isExpanded: $areIndividualControlsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search individual oligo controls", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("primerAnalysisDisplay.search")
                        .help("Searches this list by oligo name, sequence, or position. It does not filter the display.")
                    Text("\(target.primers.filter { session.isVisible($0, in: target) }.count) of \(target.primers.count) displayed on this reference")
                        .font(.caption).foregroundStyle(.secondary)
                    if members.isEmpty {
                        Text(target.primers.isEmpty ? "No saved oligos on this reference." : "No individual controls match this search.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(members) { primer in
                        oligoControl(primer, in: target)
                    }
                }
                .padding(.top, 6)
            }
            .help("Fine-tune individual oligos after applying strand, pool, and MSA match filters.")
        }
    }

    private func oligoControl(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> some View {
        let exclusionReason = otherFilterExclusionReason(for: primer, in: target)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { session.isVisible(primer, in: target) },
                set: { session.setPrimerShown(primer.id, shown: $0) })) {
                Text(primer.name).lineLimit(2).help(primer.name)
            }
            .disabled(exclusionReason != nil)
            .help(exclusionReason ?? "Show or hide this oligo manually.")
            .accessibilityIdentifier("primerAnalysisDisplay.primer.\(primer.id)")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(primer.start + 1)–\(primer.end) · \(primer.strand) · \(primer.pool.map { "Pool \($0)" } ?? "Unpooled")")
                if let summary = session.compatibilitySummaries[primer.id] {
                    Text(summary.label)
                        .help(summary.help)
                } else if session.compatibilityReady {
                    Text("MSA matches unavailable")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func otherFilterExclusionReason(for primer: PrimerReviewPrimer,
                                            in target: PrimerTargetDesignReview) -> String? {
        var visibility = session.visibility
        visibility.settings.hiddenPrimerIDs.remove(primer.id)
        guard !visibility.isVisible(primer, in: target) else { return nil }
        if !visibility.isPoolVisible(primer.pool, resultID: target.sourceResultID) {
            return "Unavailable while \(primer.pool.map { "Pool \($0)" } ?? "Unpooled") is hidden."
        }
        if primer.strand == "+", !visibility.settings.showForward {
            return "Unavailable while forward oligos are hidden."
        }
        if primer.strand == "-", !visibility.settings.showReverse {
            return "Unavailable while reverse oligos are hidden."
        }
        return "Unavailable because the MSA match filter excludes this oligo."
    }
}

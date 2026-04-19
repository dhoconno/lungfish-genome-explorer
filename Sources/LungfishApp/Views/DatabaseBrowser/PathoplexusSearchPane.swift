import SwiftUI
import LungfishCore

struct PathoplexusSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    var body: some View {
        if viewModel.isShowingPathoplexusConsent {
            PathoplexusConsentPanel(
                onCancel: {
                    viewModel.onCancel?()
                },
                onAccept: {
                    viewModel.acceptPathoplexusConsent()
                }
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pathoplexus supports consent-aware browsing and organism targeting.")
                    .font(.callout)
                    .foregroundStyle(Color.lungfishSecondaryText)

                DatabaseBrowserPane(
                    viewModel: viewModel,
                    title: "Pathoplexus",
                    summary: "Search open pathogen records and surveillance metadata."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Organism")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        PathoplexusChipFlowLayout(spacing: 8) {
                            ForEach(viewModel.pathoplexusOrganisms) { organism in
                                let isSelected = viewModel.pathoplexusOrganism?.id == organism.id
                                PathoplexusOrganismChip(organism: organism, isSelected: isSelected) {
                                    selectOrganism(organism)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func selectOrganism(_ organism: PathoplexusOrganism) {
        if viewModel.pathoplexusOrganism?.id == organism.id {
            viewModel.pathoplexusOrganism = nil
        } else {
            viewModel.pathoplexusOrganism = organism
        }

        viewModel.results = []
        viewModel.selectedRecords = []
        viewModel.selectedRecord = nil
        viewModel.totalResultCount = 0
        viewModel.hasMoreResults = false
        viewModel.searchPhase = .idle
        viewModel.errorMessage = nil
    }
}

private struct PathoplexusConsentPanel: View {
    let onCancel: () -> Void
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pathoplexus Access and Benefit Sharing")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Pathoplexus requires consent-aware browsing. You can proceed only after acknowledging the data use expectations for pathogen records.")
                    .font(.callout)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("About Pathoplexus")
                        .font(.headline)
                    Text("Pathoplexus is an open pathogen database that supports browsing across viral records while respecting access and benefit sharing obligations.")

                    Text("Before proceeding")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        consentBullet("Use the data in accordance with the stated terms")
                        consentBullet("Respect provenance and submitter contributions")
                        consentBullet("Cite the source records and original data generators")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("database-search-pathoplexus-consent-cancel")
                Spacer()
                Button("I Understand and Agree", action: onAccept)
                    .accessibilityIdentifier("database-search-pathoplexus-consent-accept")
                    .buttonStyle(.borderedProminent)
                    .tint(.lungfishCreamsicleFallback)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.lungfishCanvasBackground)
    }

    private func consentBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.lungfishCreamsicleFallback)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            Text(text)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
    }
}

private struct PathoplexusOrganismChip: View {
    let organism: PathoplexusOrganism
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                }

                Text(organism.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.lungfishCreamsicleFallback.opacity(0.18) : Color.lungfishCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.lungfishCreamsicleFallback.opacity(0.35) : Color.lungfishStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.lungfishSecondaryText)
    }
}

private struct PathoplexusChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangeSubviews(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in arrangement.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return (
            size: CGSize(width: totalWidth, height: currentY + lineHeight),
            positions: positions
        )
    }
}

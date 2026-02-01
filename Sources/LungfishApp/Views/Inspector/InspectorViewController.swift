// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore

/// Controller for the inspector panel showing selection details.
///
/// Uses SwiftUI via NSHostingView for modern, declarative UI.
@MainActor
public class InspectorViewController: NSViewController {

    /// The SwiftUI hosting view
    private var hostingView: NSHostingView<InspectorView>!

    /// View model for the inspector
    private var viewModel = InspectorViewModel()

    public override func loadView() {
        let inspectorView = InspectorView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: inspectorView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Listen for selection changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: .sidebarSelectionChanged,
            object: nil
        )
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        // Update inspector content based on selection
        if let item = notification.userInfo?["item"] as? SidebarItem {
            viewModel.selectedItem = item.title
            viewModel.selectedType = item.type.description
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - InspectorViewModel

/// View model for the inspector panel
@MainActor
public class InspectorViewModel: ObservableObject {
    @Published var selectedItem: String?
    @Published var selectedType: String?
    @Published var properties: [(String, String)] = []
    @Published var statistics: [(String, String)] = []
}

// MARK: - InspectorView (SwiftUI)

/// SwiftUI view for the inspector panel content
public struct InspectorView: View {
    @ObservedObject var viewModel: InspectorViewModel

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Selection Info Section
                InspectorSection(title: "Selection") {
                    if let item = viewModel.selectedItem {
                        LabeledContent("Name", value: item)
                        if let type = viewModel.selectedType {
                            LabeledContent("Type", value: type)
                        }
                    } else {
                        Text("No selection")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }

                // Properties Section (placeholder)
                InspectorSection(title: "Properties") {
                    Text("Select an item to view properties")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                // Statistics Section (placeholder)
                InspectorSection(title: "Statistics") {
                    Text("Select a sequence to view statistics")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                // Actions Section
                InspectorSection(title: "Actions") {
                    Button(action: {}) {
                        Label("Export Selection", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)

                    Button(action: {}) {
                        Label("Copy Sequence", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)

                    Button(action: {}) {
                        Label("Find in Sequence", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - InspectorSection

/// A collapsible section in the inspector
public struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var isExpanded = true

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
                .padding(.leading, 16)
            }
        }
    }
}

// MARK: - SidebarItemType Extension

extension SidebarItemType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .group: return "Group"
        case .folder: return "Folder"
        case .sequence: return "Sequence"
        case .annotation: return "Annotation"
        case .alignment: return "Alignment"
        case .coverage: return "Coverage"
        case .project: return "Project"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct InspectorView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = InspectorViewModel()
        viewModel.selectedItem = "chr1.fa"
        viewModel.selectedType = "Sequence"

        return InspectorView(viewModel: viewModel)
            .frame(width: 280, height: 500)
    }
}
#endif
